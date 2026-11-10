-- v2.4 public bot pages (telesia.site/b/<code>). PROPOSED, not applied: anon may read one bot's card fields by code/id/name.
-- bot_store itself stays closed to anon; this returns no instructions, knowledge text, persona or author_id.
-- Agent project moeemacbvsueekuvfjbo. Card fields only: never instructions, knowledge text, persona or author_id.
create or replace function public.bot_store_public(key text)
returns table (code text, name text, role text, icon text, blurb text, author_name text, hires integer,
               example text, published boolean, includes jsonb)
language sql security definer stable set search_path = public as $$
  with k as (select trim(coalesce(key, '')) as raw,
                    upper(regexp_replace(coalesce(key, ''), '[^A-Za-z0-9]', '', 'g')) as code,
                    lower(trim(coalesce(key, ''))) as low)
  select coalesce(b.share_code, b.id::text), b.name, b.role, b.icon, b.blurb,
         case when b.published then b.author_name else '' end, b.hires,
         left(coalesce(b.package->>'example', b.package->>'sample_output', ''), 4000),
         b.published,
         jsonb_build_object(
           'skills',    coalesce(jsonb_array_length(case when jsonb_typeof(b.package->'skills') = 'array' then b.package->'skills' end), 0),
           'knowledge', coalesce(jsonb_array_length(case when jsonb_typeof(b.package->'knowledge') = 'array' then b.package->'knowledge' end), 0),
           'routines',  coalesce(jsonb_array_length(case when jsonb_typeof(b.package->'routines') = 'array' then b.package->'routines' end), 0),
           'apps', coalesce((select jsonb_agg(a->>'name') from jsonb_array_elements(
                     case when jsonb_typeof(b.package->'apps') = 'array' then b.package->'apps' else '[]'::jsonb end) a), '[]'::jsonb))
  from bot_store b, k
  where (length(k.code) = 8 and b.share_code = k.code)
     or (b.published and b.id::text = k.low)
     or (b.published and trim(both '-' from lower(regexp_replace(b.name, '[^A-Za-z0-9]+', '-', 'g'))) = k.low)
  order by (b.share_code = k.code) desc nulls last, b.hires desc, b.created_at
  limit 1
$$;
revoke all on function public.bot_store_public(text) from public;
grant execute on function public.bot_store_public(text) to anon, authenticated;