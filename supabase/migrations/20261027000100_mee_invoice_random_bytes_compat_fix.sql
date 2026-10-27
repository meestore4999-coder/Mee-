-- Compatibility fix for environments where pgcrypto gen_random_bytes(integer) is not exposed.
-- Invoice generation uses this helper for a short unique invoice-number suffix.
create or replace function public.gen_random_bytes(p_size integer)
returns bytea language plpgsql volatile set search_path=public,pg_catalog as $$
declare v_hex text := replace(gen_random_uuid()::text, '-', '');
begin
 if p_size is null or p_size < 1 or p_size > 16 then raise exception 'Requested random byte length must be between 1 and 16'; end if;
 return decode(substr(v_hex,1,p_size*2),'hex');
end; $$;
revoke all on function public.gen_random_bytes(integer) from public,anon;
grant execute on function public.gen_random_bytes(integer) to authenticated;
