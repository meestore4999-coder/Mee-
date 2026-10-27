-- MEE: idempotently ensure the three intended store records exist.
-- Does not insert demo products or categories; those are entered by the owner.
begin;
do $$
declare
  v_business uuid;
  v_store record;
begin
  -- Use the business that already owns the existing electronics store.
  select business_id into v_business
  from public.stores
  where category = 'electrical_electronics'
  order by created_at
  limit 1;

  if v_business is null then
    raise exception 'No business with an electrical/electronics store was found. Complete Super Admin business setup first.';
  end if;

  insert into public.stores(business_id,name,slug,code,category,theme,is_active)
  values
    (v_business,'Mahesh Clothes Store','clothes-store','CLOTHES','clothes','{"accent":"#e92f69"}'::jsonb,true),
    (v_business,'Mahesh Bartan & Hardware Store','bartan-hardware','BARTAN','utensils_hardware','{"accent":"#e98118"}'::jsonb,true)
  on conflict (business_id,slug) do nothing;

  -- Give all three stores a private/unpublished storefront configuration.
  for v_store in
    select id,slug,category from public.stores where business_id=v_business
  loop
    insert into public.storefront_settings(store_id,public_slug,is_published,headline,description,accent_color,allow_guest_checkout,allow_cod,allow_upi)
    values(v_store.id,v_store.slug,false,'Welcome to MEE','Storefront setup pending',
      case v_store.category when 'clothes' then '#e92f69' when 'utensils_hardware' then '#e98118' else '#087bd9' end,
      true,false,false)
    on conflict (store_id) do nothing;
  end loop;
end $$;
commit;
