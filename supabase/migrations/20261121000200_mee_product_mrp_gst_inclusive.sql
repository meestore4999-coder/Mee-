-- Store MRP separately; both MRP and selling_price are GST-inclusive final prices.
begin;
alter table public.products add column if not exists mrp numeric(14,2) not null default 0;
do $$ begin
  if not exists (select 1 from pg_constraint where conname='products_mrp_nonnegative' and conrelid='public.products'::regclass) then
    alter table public.products add constraint products_mrp_nonnegative check (mrp >= 0);
  end if;
end $$;
commit;
