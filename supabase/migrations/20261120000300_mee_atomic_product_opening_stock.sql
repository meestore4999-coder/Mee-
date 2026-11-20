create or replace function public.create_mee_product_with_opening_stock(
  p_product jsonb,
  p_opening_stock numeric default 0
) returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_store_id uuid;
  v_category_id uuid;
  v_product_id uuid;
  v_name text;
  v_barcode text;
  v_sku text;
  v_mrp numeric;
  v_selling numeric;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  v_store_id := nullif(p_product->>'store_id','')::uuid;
  if v_store_id is null or not public.can_manage_store(v_store_id) then
    raise exception 'Not authorized to add products to this store';
  end if;
  if not exists(select 1 from public.stores where id=v_store_id and is_active) then
    raise exception 'Selected store is inactive or unavailable';
  end if;
  v_name := nullif(btrim(p_product->>'name'),'');
  if v_name is null then raise exception 'Product name is required'; end if;
  if p_opening_stock is null or p_opening_stock < 0 then raise exception 'Opening stock cannot be negative'; end if;
  if coalesce((p_product->>'min_stock')::numeric,0) < 0 then raise exception 'Minimum stock cannot be negative'; end if;
  if coalesce((p_product->>'purchase_price')::numeric,0) < 0 or coalesce((p_product->>'selling_price')::numeric,0) < 0 then
    raise exception 'Product prices cannot be negative';
  end if;
  v_mrp := coalesce((p_product->>'mrp_price')::numeric,0);
  v_selling := coalesce((p_product->>'selling_price')::numeric,0);
  if v_mrp < 0 or (v_mrp > 0 and v_selling > v_mrp) then
    raise exception 'GST-inclusive selling price cannot exceed MRP';
  end if;
  v_barcode := nullif(btrim(p_product->>'barcode'),'');
  v_sku := nullif(btrim(p_product->>'sku'),'');
  v_category_id := nullif(p_product->>'category_id','')::uuid;
  if v_category_id is not null and not exists(select 1 from public.categories where id=v_category_id and store_id=v_store_id) then
    raise exception 'Selected category does not belong to this store';
  end if;
  if v_barcode is not null and exists(select 1 from public.products where store_id=v_store_id and barcode=v_barcode) then
    raise exception 'Barcode already exists in this store. Use a unique barcode.' using errcode='23505';
  end if;
  insert into public.products(
    store_id,category_id,name,description,sku,barcode,brand,unit,
    purchase_price,selling_price,mrp_price,wholesale_price,tax_rate,
    image_url,attributes,min_stock,is_active
  ) values (
    v_store_id,v_category_id,v_name,nullif(btrim(p_product->>'description'),''),v_sku,v_barcode,
    nullif(btrim(p_product->>'brand'),''),coalesce(nullif(p_product->>'unit',''),'piece'),
    coalesce((p_product->>'purchase_price')::numeric,0),v_selling,v_mrp,
    nullif(p_product->>'wholesale_price','')::numeric,coalesce((p_product->>'tax_rate')::numeric,0),
    nullif(p_product->>'image_url',''),coalesce(p_product->'attributes','{}'::jsonb),
    coalesce((p_product->>'min_stock')::numeric,0),true
  ) returning id into v_product_id;
  if p_opening_stock > 0 then
    perform public.adjust_mee_stock(v_store_id,v_product_id,p_opening_stock,'Opening stock at product creation');
  end if;
  return v_product_id;
exception
  when unique_violation then
    raise exception 'This barcode or SKU is already used in this store. Check the existing product list.' using errcode='23505';
end;
$$;
revoke all on function public.create_mee_product_with_opening_stock(jsonb,numeric) from public, anon;
grant execute on function public.create_mee_product_with_opening_stock(jsonb,numeric) to authenticated;
notify pgrst, 'reload schema';
