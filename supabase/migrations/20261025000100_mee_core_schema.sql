-- MEE Multi-Store Billing & Inventory: foundational schema
-- Apply to a NEW Supabase project after reviewing policies and business requirements.
begin;
create extension if not exists pgcrypto;

create type public.store_category as enum ('clothes','utensils_hardware','electrical_electronics','other');
create type public.app_role as enum ('super_admin','store_admin','cashier','inventory_manager','viewer');
create type public.document_status as enum ('draft','final','cancelled');
create type public.payment_method as enum ('cash','upi','card','bank_transfer','credit','other');
create type public.payment_status as enum ('pending','paid','partial','unpaid','refunded','failed');
create type public.order_status as enum ('placed','accepted','packed','dispatched','delivered','cancelled','returned');

create table public.businesses (
 id uuid primary key default gen_random_uuid(), name text not null default 'MEE', legal_name text,
 phone text, email text, address text, gstin text, currency_code char(3) not null default 'INR',
 timezone text not null default 'Asia/Kolkata', settings jsonb not null default '{}'::jsonb,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table public.profiles (
 id uuid primary key references auth.users(id) on delete cascade, full_name text not null default '',
 phone text, is_active boolean not null default true, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table public.business_members (
 id uuid primary key default gen_random_uuid(), business_id uuid not null references public.businesses(id) on delete cascade,
 user_id uuid not null references public.profiles(id) on delete cascade, role public.app_role not null default 'viewer',
 created_at timestamptz not null default now(), unique(business_id,user_id)
);
create table public.stores (
 id uuid primary key default gen_random_uuid(), business_id uuid not null references public.businesses(id) on delete cascade,
 name text not null, slug text not null, code text not null, category public.store_category not null,
 address text, phone text, gstin text, logo_url text, theme jsonb not null default '{}'::jsonb,
 is_active boolean not null default true, settings jsonb not null default '{}'::jsonb,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 unique(business_id,slug), unique(business_id,code)
);
create table public.store_members (
 id uuid primary key default gen_random_uuid(), store_id uuid not null references public.stores(id) on delete cascade,
 user_id uuid not null references public.profiles(id) on delete cascade, role public.app_role not null default 'store_admin',
 created_at timestamptz not null default now(), unique(store_id,user_id)
);
create table public.customers (
 id uuid primary key default gen_random_uuid(), business_id uuid not null references public.businesses(id) on delete cascade,
 customer_code text, full_name text not null, phone text, email text, address text, city text, state text,
 pincode text, gstin text, opening_balance numeric(14,2) not null default 0, notes text,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 unique(business_id,customer_code)
);
create table public.suppliers (
 id uuid primary key default gen_random_uuid(), business_id uuid not null references public.businesses(id) on delete cascade,
 supplier_code text, name text not null, phone text, email text, address text, gstin text,
 opening_balance numeric(14,2) not null default 0, notes text, created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(), unique(business_id,supplier_code)
);
create table public.categories (
 id uuid primary key default gen_random_uuid(), store_id uuid not null references public.stores(id) on delete cascade,
 parent_id uuid references public.categories(id) on delete set null, name text not null, slug text not null,
 created_at timestamptz not null default now(), unique(store_id,slug)
);
create table public.products (
 id uuid primary key default gen_random_uuid(), store_id uuid not null references public.stores(id) on delete cascade,
 category_id uuid references public.categories(id) on delete set null, name text not null, description text,
 sku text, barcode text, brand text, unit text not null default 'piece', purchase_price numeric(14,2) not null default 0 check(purchase_price>=0),
 selling_price numeric(14,2) not null default 0 check(selling_price>=0), wholesale_price numeric(14,2), tax_rate numeric(6,3) not null default 0 check(tax_rate>=0),
 image_url text, attributes jsonb not null default '{}'::jsonb, min_stock numeric(14,3) not null default 0,
 is_active boolean not null default true, created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 unique(store_id,sku), unique(store_id,barcode)
);
create table public.product_variants (
 id uuid primary key default gen_random_uuid(), product_id uuid not null references public.products(id) on delete cascade,
 sku text, barcode text, size text, color text, model_number text, serial_number text, warranty_months integer,
 attributes jsonb not null default '{}'::jsonb, created_at timestamptz not null default now(), unique(product_id,sku)
);
create table public.inventory_balances (
 id uuid primary key default gen_random_uuid(), store_id uuid not null references public.stores(id) on delete cascade, product_id uuid not null references public.products(id) on delete cascade,
 variant_id uuid references public.product_variants(id) on delete cascade, quantity numeric(14,3) not null default 0,
 updated_at timestamptz not null default now()
);
create unique index inventory_balance_variant_unique on public.inventory_balances(store_id,product_id,coalesce(variant_id,'00000000-0000-0000-0000-000000000000'::uuid));
create table public.inventory_movements (
 id uuid primary key default gen_random_uuid(), store_id uuid not null references public.stores(id) on delete cascade,
 product_id uuid not null references public.products(id) on delete restrict, variant_id uuid references public.product_variants(id) on delete set null,
 movement_type text not null check(movement_type in ('opening','purchase','sale','sale_return','purchase_return','adjustment','transfer_in','transfer_out','order_hold','order_release')),
 quantity_delta numeric(14,3) not null, unit_cost numeric(14,2) not null default 0, reference_type text, reference_id uuid,
 notes text, created_by uuid references public.profiles(id) on delete set null, created_at timestamptz not null default now()
);
create table public.invoices (
 id uuid primary key default gen_random_uuid(), business_id uuid not null references public.businesses(id) on delete cascade,
 store_id uuid not null references public.stores(id) on delete restrict, customer_id uuid references public.customers(id) on delete set null,
 invoice_no text not null, status public.document_status not null default 'draft', payment_status public.payment_status not null default 'unpaid',
 invoice_date timestamptz not null default now(), due_date date, customer_name_snapshot text, customer_phone_snapshot text,
 subtotal numeric(14,2) not null default 0, discount_amount numeric(14,2) not null default 0, tax_amount numeric(14,2) not null default 0,
 total_amount numeric(14,2) not null default 0, amount_paid numeric(14,2) not null default 0, balance_due numeric(14,2) not null default 0,
 notes text, finalized_at timestamptz, created_by uuid references public.profiles(id) on delete set null,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(), unique(store_id,invoice_no),
 check(subtotal>=0 and discount_amount>=0 and tax_amount>=0 and total_amount>=0 and amount_paid>=0 and balance_due>=0)
);
create table public.invoice_items (
 id uuid primary key default gen_random_uuid(), invoice_id uuid not null references public.invoices(id) on delete cascade,
 product_id uuid references public.products(id) on delete set null, variant_id uuid references public.product_variants(id) on delete set null,
 product_name_snapshot text not null, sku_snapshot text, unit text not null default 'piece', quantity numeric(14,3) not null check(quantity>0),
 unit_price numeric(14,2) not null check(unit_price>=0), discount_amount numeric(14,2) not null default 0,
 tax_rate numeric(6,3) not null default 0, tax_amount numeric(14,2) not null default 0, line_total numeric(14,2) not null check(line_total>=0),
 created_at timestamptz not null default now()
);
create table public.payments (
 id uuid primary key default gen_random_uuid(), business_id uuid not null references public.businesses(id) on delete cascade,
 store_id uuid not null references public.stores(id) on delete restrict, customer_id uuid references public.customers(id) on delete set null,
 invoice_id uuid references public.invoices(id) on delete set null, method public.payment_method not null,
 status public.payment_status not null default 'pending', amount numeric(14,2) not null check(amount>0),
 transaction_reference text, paid_at timestamptz, notes text, received_by uuid references public.profiles(id) on delete set null,
 created_at timestamptz not null default now()
);
create table public.customer_ledger_entries (
 id uuid primary key default gen_random_uuid(), business_id uuid not null references public.businesses(id) on delete cascade,
 store_id uuid references public.stores(id) on delete set null, customer_id uuid not null references public.customers(id) on delete restrict,
 entry_date timestamptz not null default now(), entry_type text not null check(entry_type in ('opening','invoice','payment','credit_note','debit_note','adjustment','refund')),
 reference_type text, reference_id uuid, debit numeric(14,2) not null default 0, credit numeric(14,2) not null default 0,
 description text, created_by uuid references public.profiles(id) on delete set null, created_at timestamptz not null default now(),
 check(debit>=0 and credit>=0 and not(debit>0 and credit>0))
);
create table public.purchase_invoices (
 id uuid primary key default gen_random_uuid(), business_id uuid not null references public.businesses(id) on delete cascade,
 store_id uuid not null references public.stores(id) on delete restrict, supplier_id uuid references public.suppliers(id) on delete set null,
 purchase_no text not null, supplier_invoice_no text, status public.document_status not null default 'final', purchase_date timestamptz not null default now(),
 subtotal numeric(14,2) not null default 0, tax_amount numeric(14,2) not null default 0, total_amount numeric(14,2) not null default 0,
 amount_paid numeric(14,2) not null default 0, balance_due numeric(14,2) not null default 0, notes text,
 created_by uuid references public.profiles(id) on delete set null, created_at timestamptz not null default now(), unique(store_id,purchase_no)
);
create table public.purchase_items (
 id uuid primary key default gen_random_uuid(), purchase_invoice_id uuid not null references public.purchase_invoices(id) on delete cascade,
 product_id uuid references public.products(id) on delete set null, product_name_snapshot text not null,
 quantity numeric(14,3) not null check(quantity>0), unit_cost numeric(14,2) not null check(unit_cost>=0), tax_rate numeric(6,3) not null default 0,
 line_total numeric(14,2) not null check(line_total>=0), created_at timestamptz not null default now()
);
create table public.expenses (
 id uuid primary key default gen_random_uuid(), business_id uuid not null references public.businesses(id) on delete cascade,
 store_id uuid references public.stores(id) on delete set null, category text not null, description text not null,
 amount numeric(14,2) not null check(amount>0), method public.payment_method not null default 'cash', expense_date date not null default current_date,
 receipt_url text, created_by uuid references public.profiles(id) on delete set null, created_at timestamptz not null default now()
);
create table public.storefront_settings (
 store_id uuid primary key references public.stores(id) on delete cascade, is_published boolean not null default false,
 public_slug text not null unique, headline text, description text, accent_color text, logo_url text,
 allow_guest_checkout boolean not null default true, allow_cod boolean not null default false, allow_upi boolean not null default false,
 delivery_settings jsonb not null default '{}'::jsonb, updated_at timestamptz not null default now()
);
create table public.customer_orders (
 id uuid primary key default gen_random_uuid(), business_id uuid not null references public.businesses(id) on delete cascade,
 store_id uuid not null references public.stores(id) on delete restrict, customer_id uuid references public.customers(id) on delete set null,
 order_no text not null, status public.order_status not null default 'placed', customer_name text not null, customer_phone text not null,
 delivery_address jsonb not null default '{}'::jsonb, subtotal numeric(14,2) not null default 0, delivery_fee numeric(14,2) not null default 0,
 tax_amount numeric(14,2) not null default 0, total_amount numeric(14,2) not null default 0, payment_method public.payment_method,
 payment_status public.payment_status not null default 'pending', payment_reference text, notes text, created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(), unique(store_id,order_no)
);
create table public.customer_order_items (
 id uuid primary key default gen_random_uuid(), order_id uuid not null references public.customer_orders(id) on delete cascade,
 product_id uuid references public.products(id) on delete set null, product_name_snapshot text not null,
 quantity numeric(14,3) not null check(quantity>0), unit_price numeric(14,2) not null check(unit_price>=0), line_total numeric(14,2) not null check(line_total>=0)
);
create table public.audit_logs (
 id bigint generated always as identity primary key, business_id uuid references public.businesses(id) on delete set null,
 store_id uuid references public.stores(id) on delete set null, actor_id uuid references public.profiles(id) on delete set null,
 action text not null, entity_type text not null, entity_id text, details jsonb not null default '{}'::jsonb,
 created_at timestamptz not null default now()
);

create index stores_business_idx on public.stores(business_id);
create index store_members_user_idx on public.store_members(user_id,store_id);
create index business_members_user_idx on public.business_members(user_id,business_id);
create index products_store_active_idx on public.products(store_id,is_active);
create index products_name_search_idx on public.products using gin(to_tsvector('simple',name));
create index inventory_movements_product_date_idx on public.inventory_movements(store_id,product_id,created_at desc);
create index invoices_store_date_idx on public.invoices(store_id,invoice_date desc);
create index invoices_customer_idx on public.invoices(customer_id,invoice_date desc);
create index payments_store_date_idx on public.payments(store_id,created_at desc);
create index ledger_customer_date_idx on public.customer_ledger_entries(customer_id,entry_date desc);
create index orders_store_status_idx on public.customer_orders(store_id,status,created_at desc);
create index audit_logs_business_date_idx on public.audit_logs(business_id,created_at desc);

create or replace function public.is_business_member(p_business_id uuid) returns boolean
language sql stable security definer set search_path=public as $$
 select exists(select 1 from public.business_members bm where bm.business_id=p_business_id and bm.user_id=auth.uid())
 $$;
create or replace function public.is_business_admin(p_business_id uuid) returns boolean
language sql stable security definer set search_path=public as $$
 select exists(select 1 from public.business_members bm where bm.business_id=p_business_id and bm.user_id=auth.uid() and bm.role='super_admin')
 $$;
create or replace function public.has_store_access(p_store_id uuid) returns boolean
language sql stable security definer set search_path=public as $$
 select exists(select 1 from public.stores s join public.business_members bm on bm.business_id=s.business_id and bm.user_id=auth.uid() where s.id=p_store_id)
 or exists(select 1 from public.store_members sm where sm.store_id=p_store_id and sm.user_id=auth.uid())
 $$;
create or replace function public.can_manage_store(p_store_id uuid) returns boolean
language sql stable security definer set search_path=public as $$
 select exists(select 1 from public.stores s join public.business_members bm on bm.business_id=s.business_id and bm.user_id=auth.uid() and bm.role='super_admin' where s.id=p_store_id)
 or exists(select 1 from public.store_members sm where sm.store_id=p_store_id and sm.user_id=auth.uid() and sm.role in ('store_admin','inventory_manager'))
 $$;

-- RLS is enabled for tenant-scoped records. Public storefront reads are handled by a carefully scoped server endpoint/RPC, not broad table access.
do $$ declare t text; begin
 foreach t in array array['businesses','profiles','business_members','stores','store_members','customers','suppliers','categories','products','product_variants','inventory_balances','inventory_movements','invoices','invoice_items','payments','customer_ledger_entries','purchase_invoices','purchase_items','expenses','storefront_settings','customer_orders','customer_order_items','audit_logs'] loop
 execute format('alter table public.%I enable row level security',t);
 end loop;
end $$;

create policy "business member reads business" on public.businesses for select using (public.is_business_member(id));
create policy "business admin updates business" on public.businesses for update using (public.is_business_admin(id)) with check (public.is_business_admin(id));
create policy "users read own profile" on public.profiles for select using (id=auth.uid() or exists(select 1 from public.business_members bm where bm.user_id=auth.uid() and bm.role='super_admin'));
create policy "users update own profile" on public.profiles for update using (id=auth.uid()) with check (id=auth.uid());
create policy "members see same business membership" on public.business_members for select using (public.is_business_member(business_id));
create policy "super admin manages business members" on public.business_members for all using (public.is_business_admin(business_id)) with check (public.is_business_admin(business_id));
create policy "members read stores" on public.stores for select using (public.is_business_member(business_id) or public.has_store_access(id));
create policy "super admin manages stores" on public.stores for all using (public.is_business_admin(business_id)) with check (public.is_business_admin(business_id));
create policy "store members read memberships" on public.store_members for select using (public.has_store_access(store_id));
create policy "business admins manage store memberships" on public.store_members for all using (exists(select 1 from public.stores s where s.id=store_id and public.is_business_admin(s.business_id))) with check (exists(select 1 from public.stores s where s.id=store_id and public.is_business_admin(s.business_id)));

create policy "customers scoped by business" on public.customers for select using (public.is_business_member(business_id) or exists(select 1 from public.stores s where s.business_id=customers.business_id and public.has_store_access(s.id)));
create policy "authorized users insert customers" on public.customers for insert with check (public.is_business_member(business_id) or exists(select 1 from public.stores s where s.business_id=customers.business_id and public.can_manage_store(s.id)));
create policy "authorized users update customers" on public.customers for update using (public.is_business_member(business_id) or exists(select 1 from public.stores s where s.business_id=customers.business_id and public.can_manage_store(s.id))) with check (public.is_business_member(business_id) or exists(select 1 from public.stores s where s.business_id=customers.business_id and public.can_manage_store(s.id)));
create policy "suppliers scoped by business" on public.suppliers for select using (public.is_business_member(business_id) or exists(select 1 from public.stores s where s.business_id=suppliers.business_id and public.has_store_access(s.id)));
create policy "authorized users insert suppliers" on public.suppliers for insert with check (public.is_business_member(business_id) or exists(select 1 from public.stores s where s.business_id=suppliers.business_id and public.can_manage_store(s.id)));
create policy "authorized users update suppliers" on public.suppliers for update using (public.is_business_member(business_id) or exists(select 1 from public.stores s where s.business_id=suppliers.business_id and public.can_manage_store(s.id))) with check (public.is_business_member(business_id) or exists(select 1 from public.stores s where s.business_id=suppliers.business_id and public.can_manage_store(s.id)));

-- Store-scoped CRUD policies for operational tables.
do $$ declare t text; begin
 foreach t in array array['categories','products','inventory_balances','inventory_movements','invoices','payments','purchase_invoices','storefront_settings','customer_orders'] loop
 execute format('create policy %I on public.%I for select using (public.has_store_access(store_id))',t||'_read_store',t);
 execute format('create policy %I on public.%I for insert with check (public.can_manage_store(store_id))',t||'_insert_store',t);
 execute format('create policy %I on public.%I for update using (public.can_manage_store(store_id)) with check (public.can_manage_store(store_id))',t||'_update_store',t);
 execute format('create policy %I on public.%I for delete using (public.can_manage_store(store_id))',t||'_delete_store',t);
 end loop;
end $$;
create policy "variants read through product store" on public.product_variants for select using (exists(select 1 from public.products p where p.id=product_id and public.has_store_access(p.store_id)));
create policy "variants insert through product store" on public.product_variants for insert with check (exists(select 1 from public.products p where p.id=product_id and public.can_manage_store(p.store_id)));
create policy "variants update through product store" on public.product_variants for update using (exists(select 1 from public.products p where p.id=product_id and public.can_manage_store(p.store_id))) with check (exists(select 1 from public.products p where p.id=product_id and public.can_manage_store(p.store_id)));
create policy "variants delete through product store" on public.product_variants for delete using (exists(select 1 from public.products p where p.id=product_id and public.can_manage_store(p.store_id)));
create policy "invoice items read through invoice store" on public.invoice_items for select using (exists(select 1 from public.invoices i where i.id=invoice_id and public.has_store_access(i.store_id)));
create policy "invoice items insert through invoice store" on public.invoice_items for insert with check (exists(select 1 from public.invoices i where i.id=invoice_id and public.can_manage_store(i.store_id)));
create policy "invoice items update through invoice store" on public.invoice_items for update using (exists(select 1 from public.invoices i where i.id=invoice_id and public.can_manage_store(i.store_id))) with check (exists(select 1 from public.invoices i where i.id=invoice_id and public.can_manage_store(i.store_id)));
create policy "invoice items delete through invoice store" on public.invoice_items for delete using (exists(select 1 from public.invoices i where i.id=invoice_id and public.can_manage_store(i.store_id)));
create policy "purchase items read through purchase store" on public.purchase_items for select using (exists(select 1 from public.purchase_invoices i where i.id=purchase_invoice_id and public.has_store_access(i.store_id)));
create policy "purchase items insert through purchase store" on public.purchase_items for insert with check (exists(select 1 from public.purchase_invoices i where i.id=purchase_invoice_id and public.can_manage_store(i.store_id)));
create policy "purchase items update through purchase store" on public.purchase_items for update using (exists(select 1 from public.purchase_invoices i where i.id=purchase_invoice_id and public.can_manage_store(i.store_id))) with check (exists(select 1 from public.purchase_invoices i where i.id=purchase_invoice_id and public.can_manage_store(i.store_id)));
create policy "purchase items delete through purchase store" on public.purchase_items for delete using (exists(select 1 from public.purchase_invoices i where i.id=purchase_invoice_id and public.can_manage_store(i.store_id)));
create policy "order items read through order store" on public.customer_order_items for select using (exists(select 1 from public.customer_orders o where o.id=order_id and public.has_store_access(o.store_id)));
create policy "order items insert through order store" on public.customer_order_items for insert with check (exists(select 1 from public.customer_orders o where o.id=order_id and public.can_manage_store(o.store_id)));
create policy "order items update through order store" on public.customer_order_items for update using (exists(select 1 from public.customer_orders o where o.id=order_id and public.can_manage_store(o.store_id))) with check (exists(select 1 from public.customer_orders o where o.id=order_id and public.can_manage_store(o.store_id)));
create policy "order items delete through order store" on public.customer_order_items for delete using (exists(select 1 from public.customer_orders o where o.id=order_id and public.can_manage_store(o.store_id)));

create policy "ledger read by authorized store" on public.customer_ledger_entries for select using (public.is_business_member(business_id) or (store_id is not null and public.has_store_access(store_id)));
create policy "ledger insert by authorized store" on public.customer_ledger_entries for insert with check (public.is_business_member(business_id) or (store_id is not null and public.can_manage_store(store_id)));
create policy "expenses read by business member" on public.expenses for select using (public.is_business_member(business_id) or (store_id is not null and public.has_store_access(store_id)));
create policy "expenses insert by authorized user" on public.expenses for insert with check (public.is_business_member(business_id) or (store_id is not null and public.can_manage_store(store_id)));
create policy "expenses update by authorized user" on public.expenses for update using (public.is_business_member(business_id) or (store_id is not null and public.can_manage_store(store_id))) with check (public.is_business_member(business_id) or (store_id is not null and public.can_manage_store(store_id)));
create policy "audit logs read by business admin" on public.audit_logs for select using (business_id is not null and public.is_business_admin(business_id));
create policy "audit logs insert by business member" on public.audit_logs for insert with check (business_id is null or public.is_business_member(business_id));

-- updated_at helper
create or replace function public.set_updated_at() returns trigger language plpgsql as $$ begin new.updated_at=now(); return new; end $$;
do $$ declare t text; begin foreach t in array array['businesses','profiles','stores','customers','suppliers','products','invoices','customer_orders','storefront_settings'] loop execute format('create trigger %I before update on public.%I for each row execute function public.set_updated_at()',t||'_set_updated_at',t); end loop; end $$;

-- Seed product categories only when a business/store is created separately by the owner.
-- Do not seed sample stores into a live business without confirming its tenant/business id.
commit;
