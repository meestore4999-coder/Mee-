-- MEE V38: automatically link manual-name invoices to customer records and ledger.
begin;
create or replace function public.create_mee_invoice(
 p_store_id uuid,p_customer_id uuid,p_customer_name text,p_customer_phone text,
 p_items jsonb,p_discount numeric default 0,p_bill_status public.document_status default 'draft',
 p_method public.payment_method default 'credit',p_amount_received numeric default 0,
 p_payment_reference text default null,p_upi_confirmed boolean default false,p_notes text default null
) returns uuid language plpgsql security definer set search_path=public as $$
declare
 v_store public.stores%rowtype; v_invoice uuid; v_invoice_no text; v_item jsonb; v_customer_id uuid;
 v_product public.products%rowtype; v_product_id uuid; v_name text; v_unit text;
 v_qty numeric; v_price numeric; v_tax_rate numeric; v_sub numeric:=0; v_tax numeric:=0;
 v_total numeric:=0; v_line numeric; v_line_tax numeric; v_paid numeric:=0; v_balance numeric;
 v_method public.payment_method; v_status public.document_status;
begin
 if not public.can_manage_store(p_store_id) then raise exception 'Not authorized for this store'; end if;
 select * into v_store from public.stores where id=p_store_id and is_active;
 if not found then raise exception 'Store not found or inactive'; end if;

 -- Resolve a selected customer or automatically create/find a real customer for manual name/phone entry.
 v_customer_id := p_customer_id;
 if v_customer_id is not null then
   if not exists(select 1 from public.customers c where c.id=v_customer_id and c.business_id=v_store.business_id) then
     raise exception 'Selected customer does not belong to this business';
   end if;
 elsif coalesce(nullif(trim(p_customer_name),''),'Walk-in Customer') not ilike 'walk-in customer'
       and coalesce(trim(p_customer_name),'')<>'' then
   if nullif(trim(p_customer_phone),'') is not null then
     select c.id into v_customer_id from public.customers c
       where c.business_id=v_store.business_id and regexp_replace(coalesce(c.phone,''),'[^0-9]','','g')=regexp_replace(trim(p_customer_phone),'[^0-9]','','g')
       order by c.created_at asc limit 1;
   end if;
   if v_customer_id is null then
     select c.id into v_customer_id from public.customers c
       where c.business_id=v_store.business_id and lower(trim(c.full_name))=lower(trim(p_customer_name))
         and (nullif(trim(p_customer_phone),'') is null or c.phone is null or regexp_replace(coalesce(c.phone,''),'[^0-9]','','g')=regexp_replace(trim(p_customer_phone),'[^0-9]','','g'))
       order by c.created_at asc limit 1;
   end if;
   if v_customer_id is null then
     insert into public.customers(business_id,full_name,phone)
     values(v_store.business_id,trim(p_customer_name),nullif(trim(p_customer_phone),''))
     returning id into v_customer_id;
   else
     update public.customers set
       phone=coalesce(nullif(trim(phone),''),nullif(trim(p_customer_phone),'')),
       updated_at=now()
     where id=v_customer_id;
   end if;
 end if;
 if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Add at least one item'; end if;
 if coalesce(p_discount,0)<0 then raise exception 'Discount cannot be negative'; end if;
 v_status:=coalesce(p_bill_status,'draft'); v_method:=coalesce(p_method,'credit');
 if coalesce(p_amount_received,0)<0 then raise exception 'Received amount cannot be negative'; end if;
 if v_status='draft' and coalesce(p_amount_received,0)>0 then raise exception 'Record payments after finalizing the invoice'; end if;
 if v_status='final' and v_method='upi' and not p_upi_confirmed then raise exception 'UPI payment must be verified before final invoice'; end if;

 for v_item in select * from jsonb_array_elements(p_items) loop
   v_qty:=coalesce((v_item->>'quantity')::numeric,0);
   v_price:=coalesce((v_item->>'unit_price')::numeric,0);
   v_tax_rate:=coalesce((v_item->>'tax_rate')::numeric,0);
   v_product_id:=nullif(v_item->>'product_id','')::uuid;
   v_name:=nullif(trim(v_item->>'manual_name'),'');
   v_unit:=coalesce(nullif(trim(v_item->>'unit'),''),'piece');
   if v_qty<=0 then raise exception 'Quantity must be greater than zero'; end if;
   if v_price<0 or v_tax_rate<0 or v_tax_rate>100 then raise exception 'Price or GST rate is invalid'; end if;
   if v_product_id is not null then
     select * into v_product from public.products where id=v_product_id and store_id=p_store_id and is_active;
     if not found then raise exception 'Product is unavailable in selected store'; end if;
     v_name:=v_product.name; v_unit:=coalesce(nullif(v_item->>'unit',''),v_product.unit);
     if v_status='final' and coalesce((select sum(quantity) from public.inventory_balances where store_id=p_store_id and product_id=v_product.id and variant_id is null),0)<v_qty then
       raise exception 'Insufficient stock for %',v_product.name;
     end if;
   elsif coalesce(v_name,'')='' then
     raise exception 'Manual item name is required';
   end if;
   v_line:=round(v_price*v_qty,2); v_line_tax:=round(v_line*v_tax_rate/100,2);
   v_sub:=v_sub+v_line; v_tax:=v_tax+v_line_tax;
 end loop;
 if p_discount>v_sub+v_tax then raise exception 'Discount cannot exceed subtotal plus tax'; end if;
 v_total:=greatest(0,round(v_sub+v_tax-p_discount,2));
 if v_status='final' then
   if v_method='credit' then v_paid:=0; else v_paid:=coalesce(p_amount_received,0); end if;
   if v_paid>v_total then raise exception 'Received amount exceeds invoice total'; end if;
 else v_paid:=0; end if;
 v_balance:=greatest(0,v_total-v_paid);
 v_invoice_no:='MEE-'||v_store.code||'-'||to_char(now(),'YYMMDD')||'-'||upper(substr(encode(gen_random_bytes(4),'hex'),1,6));
 insert into public.invoices(business_id,store_id,customer_id,invoice_no,status,payment_status,customer_name_snapshot,customer_phone_snapshot,subtotal,discount_amount,tax_amount,total_amount,amount_paid,balance_due,notes,created_by,finalized_at)
 values(v_store.business_id,p_store_id,v_customer_id,v_invoice_no,v_status,
 case when v_status='draft' then 'unpaid'::public.payment_status when v_paid=0 then 'unpaid'::public.payment_status when v_paid<v_total then 'partial'::public.payment_status else 'paid'::public.payment_status end,
 coalesce(nullif(trim(p_customer_name),''),'Walk-in Customer'),p_customer_phone,v_sub,p_discount,v_tax,v_total,v_paid,v_balance,p_notes,auth.uid(),case when v_status='final' then now() else null end)
 returning id into v_invoice;

 for v_item in select * from jsonb_array_elements(p_items) loop
   v_qty:=(v_item->>'quantity')::numeric; v_price:=coalesce((v_item->>'unit_price')::numeric,0);
   v_tax_rate:=coalesce((v_item->>'tax_rate')::numeric,0); v_product_id:=nullif(v_item->>'product_id','')::uuid;
   v_name:=nullif(trim(v_item->>'manual_name'),''); v_unit:=coalesce(nullif(trim(v_item->>'unit'),''),'piece');
   if v_product_id is not null then
     select * into v_product from public.products where id=v_product_id and store_id=p_store_id;
     v_name:=v_product.name; v_unit:=coalesce(nullif(v_item->>'unit',''),v_product.unit);
   end if;
   v_line:=round(v_price*v_qty,2); v_line_tax:=round(v_line*v_tax_rate/100,2);
   insert into public.invoice_items(invoice_id,product_id,product_name_snapshot,sku_snapshot,unit,quantity,unit_price,tax_rate,tax_amount,line_total)
   values(v_invoice,v_product_id,v_name,case when v_product_id is not null then v_product.sku else null end,v_unit,v_qty,v_price,v_tax_rate,v_line_tax,v_line+v_line_tax);
   if v_status='final' and v_product_id is not null then
     update public.inventory_balances set quantity=quantity-v_qty,updated_at=now() where store_id=p_store_id and product_id=v_product_id and variant_id is null;
     insert into public.inventory_movements(store_id,product_id,movement_type,quantity_delta,unit_cost,reference_type,reference_id,notes,created_by)
     values(p_store_id,v_product_id,'sale',-v_qty,v_product.purchase_price,'invoice',v_invoice,'POS sale',auth.uid());
   end if;
 end loop;
 if v_status='final' and v_paid>0 then
   insert into public.payments(business_id,store_id,customer_id,invoice_id,method,status,amount,transaction_reference,paid_at,notes,received_by)
   values(v_store.business_id,p_store_id,v_customer_id,v_invoice,v_method,'paid',v_paid,p_payment_reference,now(),'POS invoice payment',auth.uid());
 end if;
 if v_status='final' and v_customer_id is not null then
   insert into public.customer_ledger_entries(business_id,store_id,customer_id,entry_type,reference_type,reference_id,debit,credit,description,created_by)
   values(v_store.business_id,p_store_id,v_customer_id,'invoice','invoice',v_invoice,v_total,0,'Invoice '||v_invoice_no,auth.uid());
   if v_paid>0 then insert into public.customer_ledger_entries(business_id,store_id,customer_id,entry_type,reference_type,reference_id,debit,credit,description,created_by)
   values(v_store.business_id,p_store_id,v_customer_id,'payment','invoice',v_invoice,0,v_paid,'Payment received for '||v_invoice_no,auth.uid()); end if;
 end if;
 insert into public.audit_logs(business_id,store_id,actor_id,action,entity_type,entity_id,details)
 values(v_store.business_id,p_store_id,auth.uid(),case when v_status='final' then 'invoice_finalized' else 'invoice_draft_created' end,'invoice',v_invoice::text,jsonb_build_object('invoice_no',v_invoice_no,'total',v_total,'payment_method',v_method));
 return v_invoice;
end; $$;

revoke all on function public.create_mee_invoice(uuid,uuid,text,text,jsonb,numeric,public.document_status,public.payment_method,numeric,text,boolean,text) from public,anon;
grant execute on function public.create_mee_invoice(uuid,uuid,text,text,jsonb,numeric,public.document_status,public.payment_method,numeric,text,boolean,text) to authenticated;

-- Backfill finalized invoices that have a customer name but no customer_id (e.g. bills created by older versions).
do $$
declare r record; v_customer_id uuid;
begin
 for r in
   select i.* from public.invoices i
   where i.status='final'
     and coalesce(nullif(trim(i.customer_name_snapshot),''),'Walk-in Customer') not ilike 'walk-in customer'
     and i.customer_id is null
 loop
   v_customer_id := null;
   if nullif(trim(r.customer_phone_snapshot),'') is not null then
     select c.id into v_customer_id from public.customers c
     where c.business_id=r.business_id
       and regexp_replace(coalesce(c.phone,''),'[^0-9]','','g')=regexp_replace(trim(r.customer_phone_snapshot),'[^0-9]','','g')
     order by c.created_at asc limit 1;
   end if;
   if v_customer_id is null then
     select c.id into v_customer_id from public.customers c
     where c.business_id=r.business_id and lower(trim(c.full_name))=lower(trim(r.customer_name_snapshot))
     order by c.created_at asc limit 1;
   end if;
   if v_customer_id is null then
     insert into public.customers(business_id,full_name,phone)
     values(r.business_id,trim(r.customer_name_snapshot),nullif(trim(r.customer_phone_snapshot),'')) returning id into v_customer_id;
   end if;
   update public.invoices set customer_id=v_customer_id where id=r.id;
 end loop;
end $$;

-- Create any missing invoice debit and payment credit ledger entries for finalized customer invoices.
insert into public.customer_ledger_entries(business_id,store_id,customer_id,entry_type,reference_type,reference_id,debit,credit,description,created_by)
select i.business_id,i.store_id,i.customer_id,'invoice','invoice',i.id,i.total_amount,0,'Invoice '||i.invoice_no,i.created_by
from public.invoices i
where i.status='final' and i.customer_id is not null and i.total_amount>0
and not exists(select 1 from public.customer_ledger_entries le where le.customer_id=i.customer_id and le.reference_type='invoice' and le.reference_id=i.id and le.entry_type='invoice');

insert into public.customer_ledger_entries(business_id,store_id,customer_id,entry_type,reference_type,reference_id,debit,credit,description,created_by)
select i.business_id,i.store_id,i.customer_id,'payment','invoice',i.id,0,i.amount_paid,'Payment received for '||i.invoice_no,i.created_by
from public.invoices i
where i.status='final' and i.customer_id is not null and i.amount_paid>0
and not exists(select 1 from public.customer_ledger_entries le where le.customer_id=i.customer_id and le.reference_type='invoice' and le.reference_id=i.id and le.entry_type='payment');

commit;
