-- S-1 (CB-15): timed swap-back of the shared router pointer to the preferred route.
-- ai_router_report only ever moved the pointer AWAY on failures, so after a bad minute it stayed on a fallback route
-- for days. ai-chat v42 probes the preferred (first healthy) route on the next request once that route's rest has
-- expired and the pointer has been where it is for >= router_home_after_s (default 900 s), and reports the probe here.
--   p_ok = true : compare-and-set the pointer p_from -> p_home (only if it still points at p_from, p_home is an
--                 enabled route of the alias, is not resting, and the pointer has been there long enough).
--   p_ok = false: the probe failed hard / first-byte timeout -> p_home rests one step up the same 1-2-4-8-15 min
--                 ladder ai_router_report uses, so isolates stop probing it until the rest expires.
-- Idempotent: create or replace + revoke/grant. Rollback: srvfix/sql/rollback_ai_router_home.sql.
create or replace function public.ai_router_home(p_home uuid, p_from uuid, p_ok boolean default true, p_kind text default null)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  st ai_router_state;
  ladder int[] := array[1, 2, 4, 8, 15];
  lvl int;
  prev ai_route_rest;
  min_secs int;
begin
  if p_home is null or p_from is null or p_home = p_from then
    return jsonb_build_object('swapped', false, 'ignored', true);
  end if;
  begin
    min_secs := coalesce((select (value #>> '{}')::int from ai_settings where key = 'router_home_after_s'), 900);
  exception when others then min_secs := 900;
  end;
  select * into st from ai_router_state where id = 1 for update;
  if not found or st.current_route_id is distinct from p_from then
    return jsonb_build_object('swapped', false, 'current_route_id', st.current_route_id, 'stale', true);
  end if;
  if not exists (select 1 from ai_routes r where r.id = p_home and r.enabled and r.alias = st.alias) then
    return jsonb_build_object('swapped', false, 'current_route_id', st.current_route_id, 'ignored', true);
  end if;
  if not p_ok then
    if coalesce(p_kind, '') not in ('hard', 'fb_timeout') then
      return jsonb_build_object('swapped', false, 'current_route_id', st.current_route_id, 'ignored', true);
    end if;
    select * into prev from ai_route_rest where route_id = p_home;
    if prev.route_id is not null and prev.rested_until > now() then
      return jsonb_build_object('swapped', false, 'current_route_id', st.current_route_id, 'rested', false);
    end if;
    lvl := case when prev.route_id is not null and prev.rested_until > now() - interval '30 minutes' then least(prev.level + 1, 4) else 0 end;
    insert into ai_route_rest (route_id, rested_until, level, last_reason, updated_at)
    values (p_home, now() + make_interval(mins => ladder[lvl + 1]), lvl, 'home_probe_' || p_kind, now())
    on conflict (route_id) do update set rested_until = excluded.rested_until, level = excluded.level, last_reason = excluded.last_reason, updated_at = now();
    return jsonb_build_object('swapped', false, 'current_route_id', st.current_route_id, 'rested', true, 'rest_seconds', ladder[lvl + 1] * 60);
  end if;
  if exists (select 1 from ai_route_rest x where x.route_id = p_home and x.rested_until > now()) then
    return jsonb_build_object('swapped', false, 'current_route_id', st.current_route_id, 'resting', true);
  end if;
  if st.since is not null and st.since > now() - make_interval(secs => min_secs) then
    return jsonb_build_object('swapped', false, 'current_route_id', st.current_route_id, 'too_soon', true);
  end if;
  update ai_router_state
     set current_route_id = p_home, since = now(), fail_count = 0, fb_timeouts = 0, window_start = now(),
         swaps = swaps + 1, last_swap_reason = 'home', updated_at = now()
   where id = 1 and current_route_id = p_from;
  return jsonb_build_object('swapped', true, 'current_route_id', p_home, 'from_route_id', p_from);
end $function$;
revoke all on function public.ai_router_home(uuid, uuid, boolean, text) from public, anon, authenticated;
grant execute on function public.ai_router_home(uuid, uuid, boolean, text) to service_role;
