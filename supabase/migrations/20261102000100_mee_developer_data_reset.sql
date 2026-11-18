-- MEE developer-only operational data reset with selectable cleanup groups.
-- Preserves business/store masters, storefront configuration and all login/access records.
begin;

create or replace function public.mee_developer_reset_operational_data(
  p_business_id uuid,
  p_groups text[]
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_store_ids uuid[];
  v_store_count integer;
  v_deleted bigint;
  v_result jsonb := '{}'::jsonb;
  v_allowed text[] := array['catalog_inventory','sales_customers','purchasing_suppliers','expenses','marketing','audit'];
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'Service role only';
  end if;
  if p_groups is null or cardinality(p_groups) = 0 or exists(select 1 from unnest(p_groups) g where not (g = any(v_allowed))) then
    raise exception 'Invalid cleanup selection';
  end if;

  select array_agg(id), count(*) into v_store_ids, v_store_count
  from public.stores where business_id = p_business_id;
  if p_business_id is null or v_store_count <> 3 then
    raise exception 'Reset blocked: expected exactly 3 preserved stores for this business; found %', coalesce(v_store_count,0);
  end if;

  if 'sales_customers' = any(p_groups) then
    delete from public.invoice_items where invoice_id in (select id from public.invoices where business_id = p_business_id);
    get diagnostics v_deleted = row_count; v_result := v_result || jsonb_build_object('invoice_items',v_deleted);

    delete from public.customer_order_items where order_id in (select id from public.customer_orders where business_id = p_business_id);
    get diagnostics v_deleted = row_count; v_result := v_result || jsonb_build_object('customer_order_items',v_deleted);

    delete from public.customer_ledger_entries where business_id = p_business_id;
    get diagnostics v_deleted = row_count; v_result := v_result || jsonb_build_object('customer_ledger_entries',v_deleted);

    delete from public.payments where business_id = p_business_id;
    get diagnostics v_deleted = row_count; v_result := v_result || jsonb_build_object('payments',v_deleted);

    delete from public.invoices where business_id = p_business_id;
    get diagnostics v_deleted = row_count; v_result := v_result || jsonb_build_object('invoices',v_deleted);

    delete from public.customer_orders where business_id = p_business_id;
    get diagnostics v_deleted = row_count; v_result := v_result || jsonb_build_object('customer_orders',v_deleted);

    delete from public.customers where business_id = p_business_id;
    get diagnostics v_deleted = row_count; v_result := v_result || jsonb_build_object('customers',v_deleted);
  end if;

  if 'purchasing_suppliers' = any(p_groups) then
    delete from public.purchase_items where purchase_invoice_id in (select id from public.purchase_invoices where business_id = p_business_id);
    get diagnostics v_deleted = row_count; v_result := v_result || jsonb_build_object('purchase_items',v_deleted);

    delete from public.supplier_ledger_entries where business_id = p_business_id;
    get diagnostics v_deleted = row_count; v_result := v_result || jsonb_build_object('supplier_ledger_entries',v_deleted);

    delete from public.purchase_invoices where business_id = p_business_id;
    get diagnostics v_deleted = row_count; v_result := v_result || jsonb_build_object('purchase_invoices',v_deleted);

    delete from public.suppliers where business_id = p_business_id;
    get diagnostics v_deleted = row_count; v_result := v_result || jsonb_build_object('suppliers',v_deleted);
  end if;

  if 'catalog_inventory' = any(p_groups) then
    delete from public.inventory_movements where store_id = any(v_store_ids);
    get diagnostics v_deleted = row_count; v_result := v_result || jsonb_build_object('inventory_movements',v_deleted);

    delete from public.inventory_balances where store_id = any(v_store_ids);
    get diagnostics v_deleted = row_count; v_result := v_result || jsonb_build_object('inventory_balances',v_deleted);

    delete from public.product_variants where product_id in (select id from public.products where store_id = any(v_store_ids));
    get diagnostics v_deleted = row_count; v_result := v_result || jsonb_build_object('product_variants',v_deleted);

    delete from public.products where store_id = any(v_store_ids);
    get diagnostics v_deleted = row_count; v_result := v_result || jsonb_build_object('products',v_deleted);

    delete from public.categories where store_id = any(v_store_ids);
    get diagnostics v_deleted = row_count; v_result := v_result || jsonb_build_object('categories',v_deleted);
  end if;

  if 'expenses' = any(p_groups) then
    delete from public.expenses where business_id = p_business_id;
    get diagnostics v_deleted = row_count; v_result := v_result || jsonb_build_object('expenses',v_deleted);
  end if;

  if 'marketing' = any(p_groups) then
    if to_regclass('public.store_banners') is not null then
      execute 'delete from public.store_banners where store_id = any($1)' using v_store_ids;
      get diagnostics v_deleted = row_count; v_result := v_result || jsonb_build_object('store_banners',v_deleted);
    end if;
    if to_regclass('public.store_offers') is not null then
      execute 'delete from public.store_offers where store_id = any($1)' using v_store_ids;
      get diagnostics v_deleted = row_count; v_result := v_result || jsonb_build_object('store_offers',v_deleted);
    end if;
  end if;

  if 'audit' = any(p_groups) then
    delete from public.audit_logs where business_id = p_business_id;
    get diagnostics v_deleted = row_count; v_result := v_result || jsonb_build_object('audit_logs',v_deleted);
  end if;

  return jsonb_build_object(
    'ok', true,
    'business_id', p_business_id,
    'selected_groups', p_groups,
    'preserved_store_count', v_store_count,
    'deleted', v_result,
    'preserved', jsonb_build_array('businesses','stores','storefront_settings','auth.users','profiles','business_members','store_members')
  );
end;
$$;

revoke all on function public.mee_developer_reset_operational_data(uuid,text[]) from public, anon, authenticated;
grant execute on function public.mee_developer_reset_operational_data(uuid,text[]) to service_role;

commit;
