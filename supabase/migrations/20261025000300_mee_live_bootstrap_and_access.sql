-- Live onboarding + missing policies for MEE. Apply after migrations 001 and 002.
begin;
create or replace function public.bootstrap_mee_business(p_business_name text, p_full_name text)
returns uuid language plpgsql security definer set search_path=public,auth as $$
declare v_user uuid := auth.uid(); v_business uuid; v_store uuid;
begin
 if v_user is null then raise exception 'Authentication required'; end if;
 if exists(select 1 from public.business_members where user_id=v_user) then raise exception 'This user already belongs to a business'; end if;
 if nullif(trim(p_business_name),'') is null or nullif(trim(p_full_name),'') is null then raise exception 'Business name and full name are required'; end if;
 insert into public.profiles(id,full_name) values(v_user,trim(p_full_name)) on conflict(id) do update set full_name=excluded.full_name,updated_at=now();
 insert into public.businesses(name) values(trim(p_business_name)) returning id into v_business;
 insert into public.business_members(business_id,user_id,role) values(v_business,v_user,'super_admin');
 insert into public.stores(business_id,name,slug,code,category,theme) values
 (v_business,'Clothes Store','clothes','CL001','clothes','{"accent":"#e92f69"}'::jsonb),
 (v_business,'Mahesh Bartan & Hardware Store','bartan-hardware','BARTAN','utensils_hardware','{"accent":"#e98118"}'::jsonb),
 (v_business,'Electrical & Electronics Store','electrical-electronics','EE001','electrical_electronics','{"accent":"#087bd9"}'::jsonb);
 return v_business;
end; $$;
revoke all on function public.bootstrap_mee_business(text,text) from public,anon;
grant execute on function public.bootstrap_mee_business(text,text) to authenticated;

-- Allow authenticated business owners to create and manage tenant records only within their business.
create policy "business admin inserts own business" on public.businesses for insert with check (auth.uid() is not null and not exists(select 1 from public.business_members bm where bm.user_id=auth.uid()));
create policy "business admin deletes own business" on public.businesses for delete using (public.is_business_admin(id));
create policy "business admin manages profiles in business" on public.profiles for select using (id=auth.uid() or exists(select 1 from public.store_members sm where sm.user_id=profiles.id and public.has_store_access(sm.store_id)));
create policy "business admin inserts categories" on public.categories for insert with check (public.can_manage_store(store_id));
create policy "business admin updates categories" on public.categories for update using (public.can_manage_store(store_id)) with check (public.can_manage_store(store_id));
create policy "business admin deletes categories" on public.categories for delete using (public.can_manage_store(store_id));
create policy "business member reads purchase invoices" on public.purchase_invoices for select using (public.has_store_access(store_id));
create policy "authorized inserts purchase invoices" on public.purchase_invoices for insert with check (public.can_manage_store(store_id));
create policy "authorized updates purchase invoices" on public.purchase_invoices for update using (public.can_manage_store(store_id)) with check (public.can_manage_store(store_id));
create policy "authorized deletes purchase invoices" on public.purchase_invoices for delete using (public.can_manage_store(store_id));
create policy "authorized reads payments" on public.payments for select using (public.has_store_access(store_id));
create policy "authorized inserts payments" on public.payments for insert with check (public.can_manage_store(store_id));
create policy "authorized updates payments" on public.payments for update using (public.can_manage_store(store_id)) with check (public.can_manage_store(store_id));
create policy "authorized deletes customers" on public.customers for delete using (public.is_business_admin(business_id));
create policy "authorized deletes suppliers" on public.suppliers for delete using (public.is_business_admin(business_id));
create policy "authorized deletes expenses" on public.expenses for delete using (public.is_business_admin(business_id) or (store_id is not null and public.can_manage_store(store_id)));
create policy "authorized reads storefront settings" on public.storefront_settings for select using (public.has_store_access(store_id));
create policy "authorized inserts storefront settings" on public.storefront_settings for insert with check (public.can_manage_store(store_id));
create policy "authorized updates storefront settings" on public.storefront_settings for update using (public.can_manage_store(store_id)) with check (public.can_manage_store(store_id));
commit;
