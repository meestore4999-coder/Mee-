-- Draft invoices keep customer details as invoice snapshots; they do not create customer master rows.
CREATE OR REPLACE FUNCTION public.create_mee_invoice(p_store_id uuid,p_customer_id uuid,p_customer_name text,p_customer_phone text,p_items jsonb,p_discount numeric DEFAULT 0,p_bill_status public.document_status DEFAULT 'draft'::public.document_status,p_method public.payment_method DEFAULT 'credit'::public.payment_method,p_amount_received numeric DEFAULT 0,p_payment_reference text DEFAULT NULL,p_upi_confirmed boolean DEFAULT false,p_notes text DEFAULT NULL) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $function$
DECLARE v_invoice_id uuid; v_item record; v_available numeric; v_draft boolean;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;
 IF NOT public.can_manage_store(p_store_id) THEN RAISE EXCEPTION 'Not authorized for this store'; END IF;
 v_draft:=coalesce(p_bill_status,'draft'::public.document_status)='draft';
 IF v_draft THEN
  FOR v_item IN SELECT (j.item->>'product_id')::uuid AS product_id,sum(coalesce((j.item->>'quantity')::numeric,0)) AS qty FROM jsonb_array_elements(p_items) AS j(item) WHERE nullif(j.item->>'product_id','') IS NOT NULL GROUP BY (j.item->>'product_id')::uuid ORDER BY (j.item->>'product_id')::uuid LOOP
   PERFORM pg_advisory_xact_lock(hashtextextended(p_store_id::text||':'||v_item.product_id::text,0)); v_available:=NULL;
   SELECT quantity INTO v_available FROM public.inventory_balances WHERE store_id=p_store_id AND product_id=v_item.product_id AND variant_id IS NULL FOR UPDATE;
   IF coalesce(v_available,0)<v_item.qty THEN RAISE EXCEPTION 'Insufficient stock for draft bill. Available: %, required: %',coalesce(v_available,0),v_item.qty; END IF;
  END LOOP;
 END IF;
 v_invoice_id:=public.create_mee_invoice_before_draft_stock(p_store_id,p_customer_id,CASE WHEN v_draft AND p_customer_id IS NULL THEN 'Walk-in Customer' ELSE p_customer_name END,CASE WHEN v_draft AND p_customer_id IS NULL THEN NULL ELSE p_customer_phone END,p_items,p_discount,p_bill_status,p_method,p_amount_received,p_payment_reference,p_upi_confirmed,p_notes);
 IF v_draft THEN
  FOR v_item IN SELECT ii.product_id,sum(ii.quantity) AS qty,max(p.purchase_price) AS unit_cost FROM public.invoice_items ii JOIN public.products p ON p.id=ii.product_id WHERE ii.invoice_id=v_invoice_id AND ii.product_id IS NOT NULL GROUP BY ii.product_id ORDER BY ii.product_id LOOP
   UPDATE public.inventory_balances SET quantity=quantity-v_item.qty,updated_at=now() WHERE store_id=p_store_id AND product_id=v_item.product_id AND variant_id IS NULL;
   IF NOT FOUND THEN RAISE EXCEPTION 'Stock balance disappeared while reserving draft inventory'; END IF;
   INSERT INTO public.inventory_movements(store_id,product_id,movement_type,quantity_delta,unit_cost,reference_type,reference_id,notes,created_by) VALUES(p_store_id,v_item.product_id,'order_hold',-v_item.qty,v_item.unit_cost,'invoice',v_invoice_id,'POS draft bill stock reservation',auth.uid());
  END LOOP;
  UPDATE public.invoices SET stock_deducted=true,customer_name_snapshot=coalesce(nullif(trim(p_customer_name),''),'Walk-in Customer'),customer_phone_snapshot=p_customer_phone,updated_at=now() WHERE id=v_invoice_id;
 ELSE
  UPDATE public.invoices SET stock_deducted=true,updated_at=now() WHERE id=v_invoice_id;
 END IF;
 RETURN v_invoice_id;
END; $function$;
