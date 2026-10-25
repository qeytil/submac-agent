-- v1.13.37: the app logs the region that actually ran the cloud proxy (x-sb-edge-region), once per app run,
-- as event kind 'edge_region' (props: from = region, v = 'pinned' | 'other'). Allow the new kind.
alter table public.events drop constraint if exists events_kind_check;
alter table public.events add constraint events_kind_check
  check (kind in ('hired','first_result','replied','ignored','kept_7d','shared','hired_from_share','edge_region'));

create or replace function public.log_events(p_events jsonb)
 returns integer
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  uid uuid := auth.uid();
  e jsonb; k text; b text; pr jsonb; t timestamptz; n int := 0; key text; val jsonb;
begin
  if uid is null then raise exception 'sign in first'; end if;
  if jsonb_typeof(p_events) <> 'array' then return 0; end if;
  for e in select * from jsonb_array_elements(p_events) limit 50 loop
    if jsonb_typeof(e) <> 'object' then continue; end if;
    k := e->>'kind';
    if k is null or k not in ('hired','first_result','replied','ignored','kept_7d','shared','hired_from_share','edge_region') then continue; end if;
    b := nullif(left(e->>'bot_id', 64), '');
    if b is not null and b !~ '^[A-Za-z0-9_:.-]+$' then b := null; end if;
    pr := '{}'::jsonb;
    if jsonb_typeof(e->'props') = 'object' then
      for key, val in select * from jsonb_each(e->'props') loop
        if key not in ('from','kind','how','mins','v') then continue; end if;
        if jsonb_typeof(val) = 'number' or jsonb_typeof(val) = 'boolean' then pr := pr || jsonb_build_object(key, val);
        elsif jsonb_typeof(val) = 'string' then pr := pr || jsonb_build_object(key, left(val #>> '{}', 24));
        end if;
      end loop;
    end if;
    begin t := (e->>'at')::timestamptz; exception when others then t := null; end;
    if t is null or t > now() + interval '5 minutes' or t < now() - interval '3 days' then t := now(); end if;
    insert into events(user_id, kind, bot_id, props, at) values (uid, k, b, pr, t);
    n := n + 1;
  end loop;
  return n;
end $function$;
