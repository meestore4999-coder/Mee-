-- MEE: Draft bills reserve stock but remain outside all financial/GST registers.
-- Preserve the existing validated billing function and wrap it with draft stock reservation.
ALTER TABLE public.invoices
  ADD COLUMN IF NOT EXISTS stock_deducted boolean NOT NULL DEFAULT false;

ALTER FUNCTION public.create_mee_invoice(
  uuid, uuid, text, text, jsonb, numeric,
  public.document_status, public.payment_method, numeric, text, boolean, text
) RENAME TO create_mee_invoice_before_draft_stock;

CREATE FUNCTION public.create_mee_invoice(
  p_store_id uuid,
  p_customer_id uuid,
  p_customer_name text,
  p_customer_phone text,
  p_items jsonb,
  p_discount numeric DEFAULT 0,
  p_bill_status public.document_status DEFAULT 'draft'::public.document_status,
  p_method public.payment_method DEFAULT 'credit'::public.payment_method,
  p_amount_received numeric DEFAULT 0,
  p_payment_reference text DEFAULT NULL,
  p_upi_confirmed boolean DEFAULT false,
  p_notes text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_invoice_id uuid;
  v_item record;
  v_available numeric;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  IF NOT public.can_manage_store(p_store_id) THEN RAISE EXCEPTION 'Not authorized for this store'; END IF;

  -- Serialize and validate draft stock before creating any invoice rows.
  IF coalesce(p_bill_status, 'draft'::public.document_status) = 'draft' THEN
    FOR v_item IN
      SELECT (x->>'product_id')::uuid AS product_id,
             sum(coalesce((x->>'quantity')::numeric, 0)) AS qty
      FROM jsonb_array_elements(p_items) AS j(item)
      WHERE nullif(item->>'product_id','') IS NOT NULL
      GROUP BY (item->>'product_id')::uuid
      ORDER BY (item->>'product_id')::uuid
    LOOP
      PERFORM pg_advisory_xact_lock(hashtextextended(p_store_id::text || ':' || v_item.product_id::text, 0));
      v_available := NULL;
      SELECT quantity INTO v_available
      FROM public.inventory_balances
      WHERE store_id=p_store_id AND product_id=v_item.product_id AND variant_id IS NULL
      FOR UPDATE;
      IF coalesce(v_available,0) < v_item.qty THEN
        RAISE EXCEPTION 'Insufficient stock for draft bill. Available: %, required: %', coalesce(v_available,0), v_item.qty;
      END IF;
    END LOOP;
  END IF;

  -- Existing routine performs all invoice validation, GST math and final-only accounting.
  v_invoice_id := public.create_mee_invoice_before_draft_stock(
    p_store_id, p_customer_id, p_customer_name, p_customer_phone, p_items,
    p_discount, p_bill_status, p_method, p_amount_received,
    p_payment_reference, p_upi_confirmed, p_notes
  );

  IF coalesce(p_bill_status, 'draft'::public.document_status) = 'draft' THEN
    FOR v_item IN
      SELECT ii.product_id, sum(ii.quantity) AS qty, max(p.purchase_price) AS unit_cost
      FROM public.invoice_items ii
      JOIN public.products p ON p.id=ii.product_id
      WHERE ii.invoice_id=v_invoice_id AND ii.product_id IS NOT NULL
      GROUP BY ii.product_id
      ORDER BY ii.product_id
    LOOP
      UPDATE public.inventory_balances
      SET quantity=quantity-v_item.qty, updated_at=now()
      WHERE store_id=p_store_id AND product_id=v_item.product_id AND variant_id IS NULL;
      IF NOT FOUND THEN RAISE EXCEPTION 'Stock balance disappeared while reserving draft inventory'; END IF;
      INSERT INTO public.inventory_movements(
        store_id,product_id,movement_type,quantity_delta,unit_cost,
        reference_type,reference_id,notes,created_by
      ) VALUES (
        p_store_id,v_item.product_id,'sale',-v_item.qty,v_item.unit_cost,
        'invoice',v_invoice_id,'POS draft bill stock deduction',auth.uid()
      );
    END LOOP;
  END IF;

  UPDATE public.invoices SET stock_deducted=true, updated_at=now() WHERE id=v_invoice_id;
  RETURN v_invoice_id;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.create_mee_invoice_before_draft_stock(
  uuid, uuid, text, text, jsonb, numeric,
  public.document_status, public.payment_method, numeric, text, boolean, text
) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.create_mee_invoice(
  uuid, uuid, text, text, jsonb, numeric,
  public.document_status, public.payment_method, numeric, text, boolean, text
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_mee_invoice(
  uuid, uuid, text, text, jsonb, numeric,
  public.document_status, public.payment_method, numeric, text, boolean, text
) TO authenticated;

CREATE OR REPLACE FUNCTION public.delete_mee_draft_invoice(p_invoice_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_invoice public.invoices%rowtype;
  v_item record;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
  SELECT * INTO v_invoice FROM public.invoices WHERE id=p_invoice_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Draft bill not found'; END IF;
  IF v_invoice.status <> 'draft' THEN RAISE EXCEPTION 'Only draft bills can be deleted here'; END IF;
  IF NOT public.can_manage_store(v_invoice.store_id) THEN RAISE EXCEPTION 'Not authorized for this store'; END IF;

  -- Reverse only actual draft deductions. Legacy drafts created before this migration
  -- have no matching sale movements and therefore do not inflate stock on deletion.
  FOR v_item IN
    SELECT product_id, sum(-quantity_delta) AS qty, max(unit_cost) AS unit_cost
    FROM public.inventory_movements
    WHERE reference_type='invoice' AND reference_id=p_invoice_id
      AND movement_type='sale' AND quantity_delta<0
    GROUP BY product_id ORDER BY product_id
  LOOP
    PERFORM pg_advisory_xact_lock(hashtextextended(v_invoice.store_id::text || ':' || v_item.product_id::text, 0));
    UPDATE public.inventory_balances
    SET quantity=quantity+v_item.qty, updated_at=now()
    WHERE store_id=v_invoice.store_id AND product_id=v_item.product_id AND variant_id IS NULL;
    IF NOT FOUND THEN
      INSERT INTO public.inventory_balances(store_id,product_id,variant_id,quantity,updated_at)
      VALUES(v_invoice.store_id,v_item.product_id,NULL,v_item.qty,now());
    END IF;
    INSERT INTO public.inventory_movements(
      store_id,product_id,movement_type,quantity_delta,unit_cost,
      reference_type,reference_id,notes,created_by
    ) VALUES (
      v_invoice.store_id,v_item.product_id,'sale_return',v_item.qty,v_item.unit_cost,
      'draft_invoice_delete',p_invoice_id,'Draft bill deleted; reserved stock restored',auth.uid()
    );
  END LOOP;

  INSERT INTO public.audit_logs(business_id,store_id,actor_id,action,entity_type,entity_id,details)
  VALUES(v_invoice.business_id,v_invoice.store_id,auth.uid(),'draft_invoice_deleted','invoice',p_invoice_id::text,
    jsonb_build_object('invoice_no',v_invoice.invoice_no,'stock_deducted',v_invoice.stock_deducted));
  DELETE FROM public.invoices WHERE id=p_invoice_id;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.delete_mee_draft_invoice(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.delete_mee_draft_invoice(uuid) TO authenticated;
