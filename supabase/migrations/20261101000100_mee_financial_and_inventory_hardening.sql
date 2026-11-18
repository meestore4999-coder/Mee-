-- MEE operational hardening: strict customer payment validation and atomic inventory controls.
begin;


-- Idempotent opening-balance backfill for legacy master records.
insert into public.customer_ledger_entries(business_id,store_id,customer_id,entry_type,reference_type,reference_id,debit,credit,description)
select c.business_id,null,c.id,'opening','customer_opening',c.id,
       greatest(c.opening_balance,0),greatest(-c.opening_balance,0),'Opening balance (migration backfill)'
from public.customers c
where coalesce(c.opening_balance,0)<>0
  and not exists(select 1 from public.customer_ledger_entries l where l.customer_id=c.id and l.entry_type='opening');

insert into public.supplier_ledger_entries(business_id,store_id,supplier_id,entry_type,reference_type,reference_id,debit,credit,description)
select s.business_id,st.id,s.id,'opening','supplier_opening',s.id,
       greatest(-s.opening_balance,0),greatest(s.opening_balance,0),'Opening balance (migration backfill)'
from public.suppliers s
join lateral (select id from public.stores where business_id=s.business_id order by created_at limit 1) st on true
where coalesce(s.opening_balance,0)<>0
  and not exists(select 1 from public.supplier_ledger_entries l where l.supplier_id=s.id and l.entry_type='opening');

create or replace function public.adjust_mee_customer_ledger(
 p_store_id uuid,p_customer_id uuid,p_direction text,p_amount numeric,p_reason text
) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare v_store public.stores%rowtype; v_customer public.customers%rowtype; v_entry uuid;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 if not public.can_manage_store(p_store_id) then raise exception 'Not authorized for this store'; end if;
 if p_amount is null or p_amount<=0 then raise exception 'Adjustment amount must be greater than zero'; end if;
 if p_direction not in ('debit','credit') then raise exception 'Direction must be debit or credit'; end if;
 if nullif(trim(p_reason),'') is null then raise exception 'Adjustment reason is required'; end if;
 select * into v_store from public.stores where id=p_store_id and is_active;
 select * into v_customer from public.customers where id=p_customer_id and business_id=v_store.business_id;
 if v_store.id is null or v_customer.id is null then raise exception 'Store or customer not found for this business'; end if;
 insert into public.customer_ledger_entries(business_id,store_id,customer_id,entry_type,reference_type,debit,credit,description,created_by)
 values(v_store.business_id,p_store_id,p_customer_id,'adjustment','manual_adjustment',case when p_direction='debit' then p_amount else 0 end,case when p_direction='credit' then p_amount else 0 end,trim(p_reason),auth.uid()) returning id into v_entry;
 insert into public.audit_logs(business_id,store_id,actor_id,action,entity_type,entity_id,details)
 values(v_store.business_id,p_store_id,auth.uid(),'customer_ledger_adjusted','customer_ledger_entry',v_entry::text,jsonb_build_object('customer_id',p_customer_id,'direction',p_direction,'amount',p_amount,'reason',trim(p_reason)));
 return v_entry;
end $$;
revoke all on function public.adjust_mee_customer_ledger(uuid,uuid,text,numeric,text) from public,anon;
grant execute on function public.adjust_mee_customer_ledger(uuid,uuid,text,numeric,text) to authenticated;

create index if not exists customer_ledger_business_customer_date_idx
  on public.customer_ledger_entries (business_id, customer_id, entry_date desc);
create index if not exists invoice_customer_date_idx
  on public.invoices (customer_id, invoice_date desc) where customer_id is not null;
create index if not exists inventory_movements_store_product_date_idx
  on public.inventory_movements (store_id, product_id, created_at desc);

drop function if exists public.record_customer_payment(uuid,uuid,uuid,numeric,public.payment_method,text,text);
create or replace function public.record_customer_payment(
 p_store_id uuid, p_customer_id uuid, p_invoice_id uuid, p_amount numeric,
 p_method public.payment_method, p_reference text default null, p_notes text default null, p_upi_confirmed boolean default false
) returns uuid
language plpgsql security definer set search_path=public,pg_temp as $$
declare
 v_store public.stores%rowtype;
 v_customer public.customers%rowtype;
 v_payment_id uuid;
 v_invoice public.invoices%rowtype;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 if not public.can_manage_store(p_store_id) then raise exception 'Not authorized for this store'; end if;
 if p_amount is null or p_amount<=0 then raise exception 'Payment amount must be greater than zero'; end if;
 if p_method is null or p_method='credit' then raise exception 'Choose an actual received payment method'; end if;
 if p_method='upi' and not coalesce(p_upi_confirmed,false) then raise exception 'UPI receipt must be verified by the cashier before posting'; end if;
 select * into v_store from public.stores where id=p_store_id and is_active;
 if not found then raise exception 'Store not found or inactive'; end if;
 if p_customer_id is null then raise exception 'Select a customer for this receipt'; end if;
 select * into v_customer from public.customers where id=p_customer_id and business_id=v_store.business_id;
 if not found then raise exception 'Customer does not belong to this business'; end if;
 if p_invoice_id is not null then
   select * into v_invoice from public.invoices where id=p_invoice_id and store_id=p_store_id for update;
   if not found then raise exception 'Invoice not found for this store'; end if;
   if v_invoice.status<>'final' then raise exception 'Payments can only be posted to final invoices'; end if;
   if v_invoice.customer_id is distinct from p_customer_id then raise exception 'Selected customer does not match this invoice'; end if;
   if p_amount > greatest(v_invoice.total_amount-v_invoice.amount_paid,0) then raise exception 'Payment exceeds invoice balance'; end if;
 end if;
 insert into public.payments(business_id,store_id,customer_id,invoice_id,method,status,amount,transaction_reference,paid_at,notes,received_by)
 values(v_store.business_id,p_store_id,p_customer_id,p_invoice_id,p_method,'paid',p_amount,nullif(trim(p_reference),''),now(),p_notes,auth.uid()) returning id into v_payment_id;
 if p_invoice_id is not null then
   update public.invoices set amount_paid=amount_paid+p_amount,
     balance_due=greatest(total_amount-(amount_paid+p_amount),0),
     payment_status=case when amount_paid+p_amount>=total_amount then 'paid'::public.payment_status else 'partial'::public.payment_status end,
     updated_at=now() where id=p_invoice_id;
 end if;
 insert into public.customer_ledger_entries(business_id,store_id,customer_id,entry_type,reference_type,reference_id,credit,description,created_by)
 values(v_store.business_id,p_store_id,p_customer_id,'payment','payment',v_payment_id,p_amount,coalesce(nullif(trim(p_notes),''),'Customer payment received'),auth.uid());
 insert into public.audit_logs(business_id,store_id,actor_id,action,entity_type,entity_id,details)
 values(v_store.business_id,p_store_id,auth.uid(),'payment_recorded','payment',v_payment_id::text,jsonb_build_object('amount',p_amount,'method',p_method,'invoice_id',p_invoice_id,'customer_id',p_customer_id,'reference',p_reference));
 return v_payment_id;
end $$;
revoke all on function public.record_customer_payment(uuid,uuid,uuid,numeric,public.payment_method,text,text,boolean) from public,anon;
grant execute on function public.record_customer_payment(uuid,uuid,uuid,numeric,public.payment_method,text,text,boolean) to authenticated;

drop function if exists public.record_mee_supplier_payment(uuid,uuid,numeric,public.payment_method,text,text);
create or replace function public.record_mee_supplier_payment(
 p_store_id uuid,p_supplier_id uuid,p_amount numeric,p_method public.payment_method,
 p_reference text default null,p_notes text default null,p_upi_confirmed boolean default false
) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare v_store public.stores%rowtype; v_supplier public.suppliers%rowtype; v_entry uuid;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 if not public.can_manage_store(p_store_id) then raise exception 'Not authorized for this store'; end if;
 if p_amount is null or p_amount<=0 then raise exception 'Payment amount must be greater than zero'; end if;
 if p_method is null or p_method='credit' then raise exception 'Choose an actual payment method'; end if;
 if p_method='upi' and not coalesce(p_upi_confirmed,false) then raise exception 'UPI payment must be verified before posting'; end if;
 select * into v_store from public.stores where id=p_store_id and is_active;
 if not found then raise exception 'Store not found or inactive'; end if;
 select * into v_supplier from public.suppliers where id=p_supplier_id and business_id=v_store.business_id;
 if not found then raise exception 'Supplier does not belong to this business'; end if;
 insert into public.supplier_ledger_entries(business_id,store_id,supplier_id,entry_type,reference_type,debit,description,payment_method,transaction_reference,created_by)
 values(v_store.business_id,p_store_id,p_supplier_id,'payment','supplier_payment',p_amount,coalesce(p_notes,'Supplier payment'),p_method,nullif(trim(p_reference),''),auth.uid()) returning id into v_entry;
 insert into public.audit_logs(business_id,store_id,actor_id,action,entity_type,entity_id,details)
 values(v_store.business_id,p_store_id,auth.uid(),'supplier_payment_recorded','supplier_payment',v_entry::text,jsonb_build_object('supplier_id',p_supplier_id,'amount',p_amount,'method',p_method,'reference',p_reference));
 return v_entry;
end $$;
revoke all on function public.record_mee_supplier_payment(uuid,uuid,numeric,public.payment_method,text,text,boolean) from public,anon;
grant execute on function public.record_mee_supplier_payment(uuid,uuid,numeric,public.payment_method,text,text,boolean) to authenticated;

create or replace function public.adjust_mee_stock(
 p_store_id uuid, p_product_id uuid, p_quantity_delta numeric, p_reason text
) returns uuid
language plpgsql security definer set search_path=public,pg_temp as $$
declare
 v_store public.stores%rowtype;
 v_product public.products%rowtype;
 v_current numeric;
 v_movement_id uuid;
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
 values(v_store.business_id,p_store_id,auth.uid(),'stock_adjusted','inventory_movement',v_movement_id::text,jsonb_build_object('product_id',p_product_id,'delta',p_quantity_delta,'before',v_current,'after',v_current+p_quantity_delta,'reason',trim(p_reason)));
 return v_movement_id;
end $$;
revoke all on function public.adjust_mee_stock(uuid,uuid,numeric,text) from public,anon;
grant execute on function public.adjust_mee_stock(uuid,uuid,numeric,text) to authenticated;

create or replace function public.transfer_mee_stock(
 p_from_store_id uuid, p_to_store_id uuid, p_product_id uuid, p_quantity numeric, p_notes text default null
) returns uuid
language plpgsql security definer set search_path=public,pg_temp as $$
declare
 v_from public.stores%rowtype;
 v_to public.stores%rowtype;
 v_source public.products%rowtype;
 v_target public.products%rowtype;
 v_current numeric;
 v_transfer_id uuid:=gen_random_uuid();
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
 update public.inventory_balances set quantity=quantity-p_quantity,updated_at=now() where store_id=p_from_store_id and product_id=p_product_id and variant_id is null;
 insert into public.inventory_balances(store_id,product_id,variant_id,quantity,updated_at) values(p_to_store_id,v_target.id,null,p_quantity,now())
 on conflict (store_id,product_id,(coalesce(variant_id,'00000000-0000-0000-0000-000000000000'::uuid)))
 do update set quantity=public.inventory_balances.quantity+excluded.quantity,updated_at=now();
 insert into public.inventory_movements(store_id,product_id,movement_type,quantity_delta,unit_cost,reference_type,reference_id,notes,created_by)
 values(p_from_store_id,p_product_id,'transfer_out',-p_quantity,v_source.purchase_price,'stock_transfer',v_transfer_id,coalesce(p_notes,'Transfer to '||v_to.name),auth.uid());
 insert into public.inventory_movements(store_id,product_id,movement_type,quantity_delta,unit_cost,reference_type,reference_id,notes,created_by)
 values(p_to_store_id,v_target.id,'transfer_in',p_quantity,v_target.purchase_price,'stock_transfer',v_transfer_id,coalesce(p_notes,'Transfer from '||v_from.name),auth.uid());
 insert into public.audit_logs(business_id,store_id,actor_id,action,entity_type,entity_id,details)
 values(v_from.business_id,p_from_store_id,auth.uid(),'stock_transferred','stock_transfer',v_transfer_id::text,jsonb_build_object('from_store',p_from_store_id,'to_store',p_to_store_id,'source_product',p_product_id,'destination_product',v_target.id,'sku',v_source.sku,'quantity',p_quantity,'notes',p_notes));
 return v_transfer_id;
end $$;
revoke all on function public.transfer_mee_stock(uuid,uuid,uuid,numeric,text) from public,anon;
grant execute on function public.transfer_mee_stock(uuid,uuid,uuid,numeric,text) to authenticated;

notify pgrst, 'reload schema';
commit;
