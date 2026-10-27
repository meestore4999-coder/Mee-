-- MEE V32: ensure every store has settings and return campaign data to the public storefront.
insert into public.storefront_settings(store_id,public_slug,is_published,headline,description,accent_color,allow_guest_checkout,allow_cod,allow_upi)
select s.id,s.slug,false,'Welcome to MEE','Storefront setup pending',case s.category::text when 'clothes' then '#e92f69' when 'utensils_hardware' then '#e98118' else '#087bd9' end,true,false,false
from public.stores s where not exists(select 1 from public.storefront_settings fs where fs.store_id=s.id)
on conflict (store_id) do nothing;

create or replace function public.get_mee_public_store(p_slug text)
returns jsonb language sql stable security definer set search_path=public as $$
 select jsonb_build_object(
 'store',jsonb_build_object('id',s.id,'name',s.name,'slug',fs.public_slug,'category',s.category,'headline',fs.headline,'description',fs.description,'accent_color',fs.accent_color,'allow_guest_checkout',fs.allow_guest_checkout,'allow_cod',fs.allow_cod,'allow_upi',fs.allow_upi,'logo_url',fs.logo_url),
 'products',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'description',p.description,'sku',p.sku,'brand',p.brand,'unit',p.unit,'selling_price',p.selling_price,'tax_rate',p.tax_rate,'image_url',p.image_url,'category_id',p.category_id,'stock',coalesce((select sum(ib.quantity) from public.inventory_balances ib where ib.store_id=p.store_id and ib.product_id=p.id and ib.variant_id is null),0)) order by p.name) from public.products p where p.store_id=s.id and p.is_active), '[]'::jsonb),
 'categories',coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'name',c.name,'parent_id',c.parent_id,'image_url',c.image_url) order by c.name) from public.categories c where c.store_id=s.id),'[]'::jsonb),
 'banners',coalesce((select jsonb_agg(jsonb_build_object('id',b.id,'title',b.title,'subtitle',b.subtitle,'image_url',b.image_url,'overlay_color',b.overlay_color,'overlay_opacity',b.overlay_opacity,'text_color',b.text_color,'cta_text',b.cta_text,'cta_link',b.cta_link,'sort_order',b.sort_order) order by b.sort_order) from public.store_banners b where b.store_id=s.id and b.is_active and (b.starts_at is null or b.starts_at<=now()) and (b.ends_at is null or b.ends_at>=now())),'[]'::jsonb),
 'offers',coalesce((select jsonb_agg(jsonb_build_object('id',o.id,'title',o.title,'description',o.description,'offer_type',o.offer_type,'discount_type',o.discount_type,'discount_value',o.discount_value,'product_ids',o.product_ids,'coupon_code',o.coupon_code) order by o.created_at desc) from public.store_offers o where o.store_id=s.id and o.is_active and (o.starts_at is null or o.starts_at<=now()) and (o.ends_at is null or o.ends_at>=now())),'[]'::jsonb)
 )
 from public.storefront_settings fs join public.stores s on s.id=fs.store_id
 where fs.public_slug=p_slug and fs.is_published=true and s.is_active=true limit 1
$$;
revoke all on function public.get_mee_public_store(text) from public;
grant execute on function public.get_mee_public_store(text) to anon,authenticated;

-- Requested: publish active stores now; each can be deactivated from Settings.
update public.storefront_settings fs set is_published=true,updated_at=now() from public.stores s where s.id=fs.store_id and s.is_active=true;
