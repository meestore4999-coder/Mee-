-- Recover older finalized invoices into the customer master and ledger.
-- Exact phone match takes priority; name matching is only used when the invoice has no phone snapshot.
begin;

with invoice_matches as (
  select i.id as invoice_id, min(c.id::text)::uuid as customer_id
  from public.invoices i
  join public.customers c on c.business_id = i.business_id
  where i.customer_id is null
    and i.status = 'final'
    and (
      (nullif(trim(i.customer_phone_snapshot), '') is not null
        and regexp_replace(coalesce(i.customer_phone_snapshot, ''), '\D', '', 'g') = regexp_replace(coalesce(c.phone, ''), '\D', '', 'g')
        and length(regexp_replace(coalesce(i.customer_phone_snapshot, ''), '\D', '', 'g')) >= 7)
      or
      (nullif(trim(i.customer_phone_snapshot), '') is null
        and nullif(trim(i.customer_name_snapshot), '') is not null
        and lower(trim(i.customer_name_snapshot)) = lower(trim(c.full_name)))
    )
  group by i.id
  having count(distinct c.id) = 1
)
update public.invoices i
set customer_id = m.customer_id,
    updated_at = now()
from invoice_matches m
where i.id = m.invoice_id;
insert into public.customer_ledger_entries
  (business_id, store_id, customer_id, entry_type, reference_type, reference_id, debit, credit, description, created_by, entry_date)
select i.business_id, i.store_id, i.customer_id, 'invoice', 'invoice', i.id,
       i.total_amount, 0, 'Final invoice ' || i.invoice_no, i.created_by, coalesce(i.finalized_at, i.invoice_date)
from public.invoices i
where i.status = 'final'
  and i.customer_id is not null
  and not exists (
    select 1 from public.customer_ledger_entries le
    where le.customer_id = i.customer_id
      and le.reference_type = 'invoice'
      and le.reference_id = i.id
      and le.entry_type = 'invoice'
  );

insert into public.customer_ledger_entries
  (business_id, store_id, customer_id, entry_type, reference_type, reference_id, debit, credit, description, created_by, entry_date)
select i.business_id, i.store_id, i.customer_id, 'payment', 'invoice', i.id,
       0, i.amount_paid, 'Payment received on invoice ' || i.invoice_no, i.created_by, coalesce(i.finalized_at, i.invoice_date)
from public.invoices i
where i.status = 'final'
  and i.customer_id is not null
  and i.amount_paid > 0
  and not exists (
    select 1 from public.customer_ledger_entries le
    where le.customer_id = i.customer_id
      and le.reference_type = 'invoice'
      and le.reference_id = i.id
      and le.entry_type = 'payment'
  );

commit;
