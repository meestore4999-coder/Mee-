-- Atomic purchase receiving: validates store/product ownership, writes invoice/items,
-- updates inventory and movements, and posts supplier payable ledger in one transaction.
begin;
create table if not exists public.supplier_ledger_entries (
 id uuid primary key default gen_random_uuid(), business_id uuid not null references public.businesses(id) on delete cascade,
 store_id uuid not null references public.stores(id) on delete restrict,
 supplier_id uuid not null references public.suppliers(id) on delete restrict,
 entry_date timestamptz not null default now(), entry_type text not null check(entry_type in ('opening','purchase','payment','purchase_return','adjustment')),
 reference_type text, reference_id uuid, debit numeric(14,2) not null default 0, credit numeric(14,2) not null default 0,
 description text, payment_method public.payment_method, transaction_reference text, created_by uuid references public.profiles(id) on delete set null,
 created_at timestamptz not null default now(), check(debit>=0 and credit>=0 and not(debit>0 and credit>0))
);
alter table public.supplier_ledger_entries enable row level security;
drop policy if exists "supplier ledger scoped by store" on public.supplier_ledger_entries;
create policy "supplier ledger scoped by store" on public.supplier_ledger_entries for select using (public.has_store_access(store_id));
drop policy if exists "supplier ledger insert by store manager" on public.supplier_ledger_entries;
create policy "supplier ledger insert by store manager" on public.supplier_ledger_entries for insert with check (public.can_manage_store(store_id));
create index if not exists supplier_ledger_store_supplier_date_idx on public.supplier_ledger_entries(store_id,supplier_id,entry_date);

create or replace function public.create_mee_purchase(
 p_store_id uuid, p_supplier_id uuid, p_supplier_invoice_no text, p_items jsonb,
 p_status public.document_status default 'final', p_amount_paid numeric default 0, p_notes text default null
) returns uuid language plpgsql security definer set search_path=public as $$
declare v_store public.stores%rowtype; v_supplier public.suppliers%rowtype; v_purchase uuid; v_no text; v_item jsonb; v_product public.products%rowtype; v_qty numeric; v_cost numeric; v_sub numeric:=0; v_tax numeric:=0; v_line numeric; v_total numeric:=0; v_paid numeric:=0; v_status public.document_status;
begin
 if not public.can_manage_store(p_store_id) then raise exception 'Not authorized for this store'; end if;
 select * into v_store from public.stores where id=p_store_id and is_active;
 if not found then raise exception 'Store not found or inactive'; end if;
 if p_supplier_id is not null then select * into v_supplier from public.suppliers where id=p_supplier_id and business_id=v_store.business_id; if not found then raise exception 'Supplier does not belong to this business'; end if; end if;
 if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Add at least one purchase item'; end if;
 v_status:=coalesce(p_status,'final'); if v_status not in ('draft','final') then raise exception 'Purchase status must be draft or final'; end if;
 if coalesce(p_amount_paid,0)<0 then raise exception 'Paid amount cannot be negative'; end if;
 for v_item in select * from jsonb_array_elements(p_items) loop
  v_qty:=coalesce((v_item->>'quantity')::numeric,0); v_cost:=coalesce((v_item->>'unit_cost')::numeric,0);
  if v_qty<=0 or v_cost<0 then raise exception 'Quantity must be positive and cost cannot be negative'; end if;
  select * into v_product from public.products where id=(v_item->>'product_id')::uuid and store_id=p_store_id and is_active;
  if not found then raise exception 'Product not found or belongs to another store'; end if;
  v_line:=round(v_qty*v_cost,2); v_sub:=v_sub+v_line; v_tax:=v_tax+round(v_line*coalesce(v_product.tax_rate,0)/100,2);
 end loop;
 v_total:=round(v_sub+v_tax,2);
 if v_status='draft' and coalesce(p_amount_paid,0)>0 then raise exception 'Draft purchase cannot record payment'; end if;
 if v_status='final' and coalesce(p_amount_paid,0)>v_total then raise exception 'Paid amount exceeds purchase total'; end if;
 v_paid:=case when v_status='final' then coalesce(p_amount_paid,0) else 0 end;
 v_no:='PUR-'||v_store.code||'-'||to_char(now(),'YYMMDD')||'-'||upper(substr(encode(gen_random_bytes(4),'hex'),1,6));
 insert into public.purchase_invoices(business_id,store_id,supplier_id,purchase_no,supplier_invoice_no,status,purchase_date,subtotal,tax_amount,total_amount,amount_paid,balance_due,notes,created_by)
 values(v_store.business_id,p_store_id,p_supplier_id,v_no,nullif(trim(p_supplier_invoice_no),''),v_status,now(),v_sub,v_tax,v_total,v_paid,greatest(0,v_total-v_paid),p_notes,auth.uid()) returning id into v_purchase;
 for v_item in select * from jsonb_array_elements(p_items) loop
  v_qty:=(v_item->>'quantity')::numeric; v_cost:=(v_item->>'unit_cost')::numeric;
  select * into v_product from public.products where id=(v_item->>'product_id')::uuid and store_id=p_store_id;
  v_line:=round(v_qty*v_cost,2);
  insert into public.purchase_items(purchase_invoice_id,product_id,product_name_snapshot,quantity,unit_cost,tax_rate,line_total)
  values(v_purchase,v_product.id,v_product.name,v_qty,v_cost,coalesce(v_product.tax_rate,0),v_line+round(v_line*coalesce(v_product.tax_rate,0)/100,2));
  if v_status='final' then
   insert into public.inventory_balances(store_id,product_id,variant_id,quantity) values(p_store_id,v_product.id,null,v_qty)
   on conflict (store_id,product_id,(coalesce(variant_id,'00000000-0000-0000-0000-000000000000'::uuid))) do update set quantity=public.inventory_balances.quantity+excluded.quantity,updated_at=now();
   insert into public.inventory_movements(store_id,product_id,movement_type,quantity_delta,unit_cost,reference_type,reference_id,notes,created_by)
   values(p_store_id,v_product.id,'purchase',v_qty,v_cost,'purchase',v_purchase,'Received purchase '||v_no,auth.uid());
  end if;
 end loop;
 if v_status='final' and p_supplier_id is not null then
  insert into public.supplier_ledger_entries(business_id,store_id,supplier_id,entry_type,reference_type,reference_id,credit,description,created_by)
  values(v_store.business_id,p_store_id,p_supplier_id,'purchase','purchase',v_purchase,v_total,'Purchase '||v_no,auth.uid());
  if v_paid>0 then insert into public.supplier_ledger_entries(business_id,store_id,supplier_id,entry_type,reference_type,reference_id,debit,description,created_by)
  values(v_store.business_id,p_store_id,p_supplier_id,'payment','purchase',v_purchase,v_paid,'Payment recorded on purchase '||v_no,auth.uid()); end if;
 end if;
 insert into public.audit_logs(business_id,store_id,actor_id,action,entity_type,entity_id,details)
 values(v_store.business_id,p_store_id,auth.uid(),case when v_status='final' then 'purchase_received' else 'purchase_draft_created' end,'purchase',v_purchase::text,jsonb_build_object('purchase_no',v_no,'total',v_total,'paid',v_paid));
 return v_purchase;
end; $$;

create or replace function public.record_mee_supplier_payment(
 p_store_id uuid, p_supplier_id uuid, p_amount numeric, p_method public.payment_method,
 p_reference text default null, p_notes text default null
) returns uuid language plpgsql security definer set search_path=public as $$
declare v_store public.stores%rowtype; v_supplier public.suppliers%rowtype; v_entry uuid;
begin
 if not public.can_manage_store(p_store_id) then raise exception 'Not authorized for this store'; end if;
 if p_amount is null or p_amount<=0 then raise exception 'Payment amount must be greater than zero'; end if;
 if p_method is null or p_method='credit' then raise exception 'Choose an actual payment method'; end if;
 select * into v_store from public.stores where id=p_store_id and is_active;
 if not found then raise exception 'Store not found or inactive'; end if;
 select * into v_supplier from public.suppliers where id=p_supplier_id and business_id=v_store.business_id;
 if not found then raise exception 'Supplier does not belong to this business'; end if;
 insert into public.supplier_ledger_entries(business_id,store_id,supplier_id,entry_type,reference_type,debit,description,payment_method,transaction_reference,created_by)
 values(v_store.business_id,p_store_id,p_supplier_id,'payment','supplier_payment',p_amount,coalesce(p_notes,'Supplier payment'),p_method,nullif(trim(p_reference),''),auth.uid()) returning id into v_entry;
 insert into public.audit_logs(business_id,store_id,actor_id,action,entity_type,entity_id,details)
 values(v_store.business_id,p_store_id,auth.uid(),'supplier_payment_recorded','supplier_payment',v_entry::text,jsonb_build_object('supplier_id',p_supplier_id,'amount',p_amount,'method',p_method,'reference',p_reference));
 return v_entry;
end; $$;
revoke all on function public.record_mee_supplier_payment(uuid,uuid,numeric,public.payment_method,text,text) from public,anon;
grant execute on function public.record_mee_supplier_payment(uuid,uuid,numeric,public.payment_method,text,text) to authenticated;

revoke all on function public.create_mee_purchase(uuid,uuid,text,jsonb,public.document_status,numeric,text) from public,anon;
grant execute on function public.create_mee_purchase(uuid,uuid,text,jsonb,public.document_status,numeric,text) to authenticated;
commit;
