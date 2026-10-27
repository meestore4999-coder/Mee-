-- MEE workflow helpers. These functions are a foundation; invoice posting still requires
-- application-level transaction orchestration and tests before production use.
begin;

create or replace function public.get_invoice_balance(p_invoice_id uuid)
returns table(total_amount numeric, amount_paid numeric, balance_due numeric, payment_status public.payment_status)
language sql stable security definer set search_path=public as $$
 select i.total_amount, i.amount_paid, greatest(i.total_amount-i.amount_paid,0),
   case when i.amount_paid<=0 then 'unpaid'::public.payment_status
        when i.amount_paid<i.total_amount then 'partial'::public.payment_status
        else 'paid'::public.payment_status end
 from public.invoices i
 where i.id=p_invoice_id and public.has_store_access(i.store_id)
$$;

create or replace function public.record_customer_payment(
 p_store_id uuid, p_customer_id uuid, p_invoice_id uuid, p_amount numeric,
 p_method public.payment_method, p_reference text default null, p_notes text default null
) returns uuid
language plpgsql security definer set search_path=public as $$
declare v_business_id uuid; v_payment_id uuid; v_invoice public.invoices%rowtype;
begin
 if not public.can_manage_store(p_store_id) then raise exception 'Not authorized for this store'; end if;
 if p_amount is null or p_amount<=0 then raise exception 'Payment amount must be greater than zero'; end if;
 if p_method='credit' then raise exception 'Credit is a sale/payment term, not a received payment method'; end if;
 select business_id into v_business_id from public.stores where id=p_store_id;
 if v_business_id is null then raise exception 'Store not found'; end if;
 if p_invoice_id is not null then
   select * into v_invoice from public.invoices where id=p_invoice_id and store_id=p_store_id for update;
   if not found then raise exception 'Invoice not found for this store'; end if;
   if v_invoice.status<>'final' then raise exception 'Payments can only be posted to final invoices'; end if;
   if p_amount > greatest(v_invoice.total_amount-v_invoice.amount_paid,0) then raise exception 'Payment exceeds invoice balance'; end if;
 end if;
 insert into public.payments(business_id,store_id,customer_id,invoice_id,method,status,amount,transaction_reference,paid_at,notes,received_by)
 values(v_business_id,p_store_id,p_customer_id,p_invoice_id,p_method,'paid',p_amount,p_reference,now(),p_notes,auth.uid()) returning id into v_payment_id;
 if p_invoice_id is not null then
   update public.invoices set amount_paid=amount_paid+p_amount,
     balance_due=greatest(total_amount-(amount_paid+p_amount),0),
     payment_status=case when amount_paid+p_amount>=total_amount then 'paid'::public.payment_status else 'partial'::public.payment_status end,
     updated_at=now() where id=p_invoice_id;
 end if;
 if p_customer_id is not null then
   insert into public.customer_ledger_entries(business_id,store_id,customer_id,entry_type,reference_type,reference_id,credit,description,created_by)
   values(v_business_id,p_store_id,p_customer_id,'payment','payment',v_payment_id,p_amount,coalesce(p_notes,'Customer payment received'),auth.uid());
 end if;
 insert into public.audit_logs(business_id,store_id,actor_id,action,entity_type,entity_id,details)
 values(v_business_id,p_store_id,auth.uid(),'payment_recorded','payment',v_payment_id::text,jsonb_build_object('amount',p_amount,'method',p_method,'invoice_id',p_invoice_id));
 return v_payment_id;
end $$;

revoke all on function public.record_customer_payment(uuid,uuid,uuid,numeric,public.payment_method,text,text) from public;
grant execute on function public.record_customer_payment(uuid,uuid,uuid,numeric,public.payment_method,text,text) to authenticated;
revoke all on function public.get_invoice_balance(uuid) from public;
grant execute on function public.get_invoice_balance(uuid) to authenticated;
commit;
