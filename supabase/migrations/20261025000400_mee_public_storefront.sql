-- Public customer storefront: only published store and active products are exposed.
begin;
create or replace function public.get_mee_public_store(p_slug text)
returns jsonb language sql stable security definer set search_path=public as $$
 select jsonb_build_object('store',jsonb_build_object('id',s.id,'name',s.name,'slug',fs.public_slug,'category',s.category,'headline',fs.headline,'description',fs.description,'accent_color',fs.accent_color,'allow_guest_checkout',fs.allow_guest_checkout,'allow_cod',fs.allow_cod,'allow_upi',fs.allow_upi),
 'products',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'description',p.description,'sku',p.sku,'brand',p.brand,'unit',p.unit,'selling_price',p.selling_price,'tax_rate',p.tax_rate,'image_url',p.image_url,'stock',coalesce((select sum(ib.quantity) from public.inventory_balances ib where ib.store_id=p.store_id and ib.product_id=p.id and ib.variant_id is null),0)) order by p.name) from public.products p where p.store_id=s.id and p.is_active), '[]'::jsonb))
 from public.storefront_settings fs join public.stores s on s.id=fs.store_id
 where fs.public_slug=p_slug and fs.is_published=true and s.is_active=true limit 1
$$;
revoke all on function public.get_mee_public_store(text) from public;
grant execute on function public.get_mee_public_store(text) to anon,authenticated;

create or replace function public.place_mee_public_order(p_slug text,p_customer_name text,p_customer_phone text,p_address jsonb,p_items jsonb,p_payment_method public.payment_method default 'cash')
returns uuid language plpgsql security definer set search_path=public as $$
declare v_store public.stores%rowtype; v_fs public.storefront_settings%rowtype; v_business uuid; v_order uuid; v_no text; v_item jsonb; v_product public.products%rowtype; v_qty numeric; v_subtotal numeric:=0; v_tax numeric:=0; v_line numeric; v_method public.payment_method;
begin
 if nullif(trim(p_customer_name),'') is null or nullif(trim(p_customer_phone),'') is null then raise exception 'Customer name and phone are required'; end if;
 if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Cart is empty'; end if;
 select s.* into v_store from public.stores s join public.storefront_settings fs on fs.store_id=s.id where fs.public_slug=p_slug and fs.is_published and s.is_active limit 1;
 if v_store.id is null then raise exception 'Storefront not found or unpublished'; end if;
 select * into v_fs from public.storefront_settings where store_id=v_store.id;
 v_method:=coalesce(p_payment_method,'cash');
 if v_method='upi' and not v_fs.allow_upi then raise exception 'UPI checkout is not enabled for this store'; end if;
 if v_method='cash' and not v_fs.allow_cod then raise exception 'Cash on delivery is not enabled for this store'; end if;
 if not v_fs.allow_guest_checkout and auth.uid() is null then raise exception 'Login is required for checkout'; end if;
 for v_item in select * from jsonb_array_elements(p_items) loop
   v_qty:=greatest(0,coalesce((v_item->>'quantity')::numeric,0));
   if v_qty<=0 then raise exception 'Invalid product quantity'; end if;
   select * into v_product from public.products where id=(v_item->>'product_id')::uuid and store_id=v_store.id and is_active for share;
   if not found then raise exception 'Product unavailable'; end if;
   if coalesce((select sum(quantity) from public.inventory_balances where store_id=v_store.id and product_id=v_product.id and variant_id is null),0)<v_qty then raise exception 'Insufficient stock for %',v_product.name; end if;
   v_line:=round(v_product.selling_price*v_qty,2); v_subtotal:=v_subtotal+v_line; v_tax:=v_tax+round(v_line*v_product.tax_rate/100,2);
 end loop;
 v_no:='WEB-'||to_char(now(),'YYMMDD')||'-'||upper(substr(encode(gen_random_bytes(4),'hex'),1,8));
 insert into public.customer_orders(business_id,store_id,order_no,status,customer_name,customer_phone,delivery_address,subtotal,tax_amount,total_amount,payment_method,payment_status)
 values(v_store.business_id,v_store.id,v_no,'placed',trim(p_customer_name),trim(p_customer_phone),coalesce(p_address,'{}'::jsonb),v_subtotal,v_tax,v_subtotal+v_tax,v_method,'pending') returning id into v_order;
 for v_item in select * from jsonb_array_elements(p_items) loop
   v_qty:=(v_item->>'quantity')::numeric; select * into v_product from public.products where id=(v_item->>'product_id')::uuid and store_id=v_store.id;
   v_line:=round(v_product.selling_price*v_qty,2);
   insert into public.customer_order_items(order_id,product_id,product_name_snapshot,quantity,unit_price,line_total) values(v_order,v_product.id,v_product.name,v_qty,v_product.selling_price,v_line);
 end loop;
 insert into public.audit_logs(business_id,store_id,action,entity_type,entity_id,details) values(v_store.business_id,v_store.id,'public_order_created','customer_order',v_order::text,jsonb_build_object('order_no',v_no,'total',v_subtotal+v_tax));
 return v_order;
end; $$;
revoke all on function public.place_mee_public_order(text,text,text,jsonb,jsonb,public.payment_method) from public;
grant execute on function public.place_mee_public_order(text,text,text,jsonb,jsonb,public.payment_method) to anon,authenticated;

-- Bootstrap creates empty, editable public storefront settings, not fake products or sales.
create or replace function public.bootstrap_mee_business(p_business_name text, p_full_name text)
returns uuid language plpgsql security definer set search_path=public,auth as $$
declare v_user uuid := auth.uid(); v_business uuid;
begin
 if v_user is null then raise exception 'Authentication required'; end if;
 if exists(select 1 from public.business_members where user_id=v_user) then raise exception 'This user already belongs to a business'; end if;
 if nullif(trim(p_business_name),'') is null or nullif(trim(p_full_name),'') is null then raise exception 'Business name and full name are required'; end if;
 insert into public.profiles(id,full_name) values(v_user,trim(p_full_name)) on conflict(id) do update set full_name=excluded.full_name,updated_at=now();
 insert into public.businesses(name) values(trim(p_business_name)) returning id into v_business;
 insert into public.business_members(business_id,user_id,role) values(v_business,v_user,'super_admin');
 insert into public.stores(business_id,name,slug,code,category,theme) values
 (v_business,'Clothes Store','clothes','CL001','clothes','{"accent":"#e92f69"}'::jsonb),
 (v_business,'Burton / Hardware Store','burton-hardware','BH001','utensils_hardware','{"accent":"#e98118"}'::jsonb),
 (v_business,'Electrical & Electronics Store','electrical-electronics','EE001','electrical_electronics','{"accent":"#087bd9"}'::jsonb);
 insert into public.storefront_settings(store_id,public_slug,is_published,headline,description,accent_color,allow_guest_checkout,allow_cod,allow_upi)
 select id,slug,false,'Welcome to MEE','Storefront setup pending',case category when 'clothes' then '#e92f69' when 'utensils_hardware' then '#e98118' else '#087bd9' end,true,false,false from public.stores where business_id=v_business;
 return v_business;
end; $$;
revoke all on function public.bootstrap_mee_business(text,text) from public,anon;
grant execute on function public.bootstrap_mee_business(text,text) to authenticated;
commit;
