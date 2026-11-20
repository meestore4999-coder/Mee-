begin;

create or replace function public.adjust_mee_stock(
 p_store_id uuid, p_product_id uuid, p_quantity_delta numeric, p_reason text
) returns uuid
language plpgsql security definer set search_path=public,pg_temp as $$
declare v_store public.stores%rowtype; v_product public.products%rowtype; v_current numeric; v_movement_id uuid;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 if not public.can_manage_store(p_store_id) then raise exception 'Not authorized for this store'; end if;
 if p_quantity_delta is null or p_quantity_delta=0 then raise exception 'Adjustment quantity cannot be zero'; end if;
 if nullif(trim(p_reason),'') is null then raise exception 'Adjustment reason is required'; end if;
 select * into v_store from public.stores where id=p_store_id and is_active;
 if not found then raise exception 'Store not found or inactive'; end if;
 select * into v_product from public.products where id=p_product_id and store_id=p_store_id and is_active;
 if not found then raise exception 'Product not found in selected store'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_store_id::text||':'||p_product_id::text,0));
 select quantity into v_current from public.inventory_balances where store_id=p_store_id and product_id=p_product_id and variant_id is null for update;
 v_current:=coalesce(v_current,0);
 if v_current+p_quantity_delta<0 then raise exception 'Insufficient stock. Current stock: %',v_current; end if;
 insert into public.inventory_balances(store_id,product_id,variant_id,quantity,updated_at)
 values(p_store_id,p_product_id,null,v_current+p_quantity_delta,now())
 on conflict (store_id,product_id,(coalesce(variant_id,'00000000-0000-0000-0000-000000000000'::uuid)))
 do update set quantity=excluded.quantity,updated_at=now();
 insert into public.inventory_movements(store_id,product_id,movement_type,quantity_delta,unit_cost,reference_type,notes,created_by)
 values(p_store_id,p_product_id,'adjustment',p_quantity_delta,v_product.purchase_price,'manual_adjustment',trim(p_reason),auth.uid()) returning id into v_movement_id;
 insert into public.audit_logs(business_id,store_id,actor_id,action,entity_type,entity_id,details)
 values(v_store.business_id,p_store_id,auth.uid(),'stock_adjusted','inventory_movement',v_movement_id::text,
 jsonb_build_object('product_id',p_product_id,'delta',p_quantity_delta,'before',v_current,'after',v_current+p_quantity_delta,'reason',trim(p_reason)));
 return v_movement_id;
end $$;
revoke all on function public.adjust_mee_stock(uuid,uuid,numeric,text) from public,anon;
grant execute on function public.adjust_mee_stock(uuid,uuid,numeric,text) to authenticated;

create or replace function public.transfer_mee_stock(
 p_from_store_id uuid, p_to_store_id uuid, p_product_id uuid, p_quantity numeric, p_notes text default null
) returns uuid
language plpgsql security definer set search_path=public,pg_temp as $$
declare v_from public.stores%rowtype; v_to public.stores%rowtype; v_source public.products%rowtype; v_target public.products%rowtype; v_current numeric; v_transfer_id uuid:=gen_random_uuid();
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 if p_from_store_id=p_to_store_id then raise exception 'Source and destination stores must be different'; end if;
 if p_quantity is null or p_quantity<=0 then raise exception 'Transfer quantity must be greater than zero'; end if;
 if not public.can_manage_store(p_from_store_id) or not public.can_manage_store(p_to_store_id) then raise exception 'You need manage access to both stores'; end if;
 select * into v_from from public.stores where id=p_from_store_id and is_active;
 select * into v_to from public.stores where id=p_to_store_id and is_active;
 if v_from.id is null or v_to.id is null or v_from.business_id<>v_to.business_id then raise exception 'Stores must be active and belong to the same business'; end if;
 select * into v_source from public.products where id=p_product_id and store_id=p_from_store_id and is_active;
 if not found then raise exception 'Source product not found'; end if;
 if nullif(trim(v_source.sku),'') is null then raise exception 'A SKU is required to match the product in destination store'; end if;
 select * into v_target from public.products where store_id=p_to_store_id and sku=v_source.sku and is_active;
 if not found then raise exception 'Destination store does not have an active product with the same SKU'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_from_store_id::text||':'||p_product_id::text,0));
 perform pg_advisory_xact_lock(hashtextextended(p_to_store_id::text||':'||v_target.id::text,0));
 select quantity into v_current from public.inventory_balances where store_id=p_from_store_id and product_id=p_product_id and variant_id is null for update;
 v_current:=coalesce(v_current,0);
 if v_current<p_quantity then raise exception 'Insufficient source stock. Available: %',v_current; end if;
 insert into public.inventory_balances(store_id,product_id,variant_id,quantity,updated_at) values(p_from_store_id,p_product_id,null,v_current-p_quantity,now())
 on conflict (store_id,product_id,(coalesce(variant_id,'00000000-0000-0000-0000-000000000000'::uuid))) do update set quantity=excluded.quantity,updated_at=now();
 insert into public.inventory_balances(store_id,product_id,variant_id,quantity,updated_at) values(p_to_store_id,v_target.id,null,p_quantity,now())
 on conflict (store_id,product_id,(coalesce(variant_id,'00000000-0000-0000-0000-000000000000'::uuid))) do update set quantity=public.inventory_balances.quantity+excluded.quantity,updated_at=now();
 insert into public.inventory_movements(store_id,product_id,movement_type,quantity_delta,unit_cost,reference_type,reference_id,notes,created_by)
 values(p_from_store_id,p_product_id,'transfer_out',-p_quantity,v_source.purchase_price,'stock_transfer',v_transfer_id,coalesce(p_notes,'Transfer to '||v_to.name),auth.uid());
 insert into public.inventory_movements(store_id,product_id,movement_type,quantity_delta,unit_cost,reference_type,reference_id,notes,created_by)
 values(p_to_store_id,v_target.id,'transfer_in',p_quantity,v_target.purchase_price,'stock_transfer',v_transfer_id,coalesce(p_notes,'Transfer from '||v_from.name),auth.uid());
 insert into public.audit_logs(business_id,store_id,actor_id,action,entity_type,entity_id,details)
 values(v_from.business_id,p_from_store_id,auth.uid(),'stock_transferred','stock_transfer',v_transfer_id::text,
 jsonb_build_object('from_store',p_from_store_id,'to_store',p_to_store_id,'source_product',p_product_id,'destination_product',v_target.id,'sku',v_source.sku,'quantity',p_quantity,'notes',p_notes));
 return v_transfer_id;
end $$;
revoke all on function public.transfer_mee_stock(uuid,uuid,uuid,numeric,text) from public,anon;
grant execute on function public.transfer_mee_stock(uuid,uuid,uuid,numeric,text) to authenticated;
notify pgrst, 'reload schema';
commit;
