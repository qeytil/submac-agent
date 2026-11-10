-- Rebuild week 1 (Dev 1, 2026-10-23): one public model (`telesia`) and a sticky chat router. PLAN.md 1.1, timing.md 5.4.
--
-- 1. Alias `telesia`: the one route list. Seeded from the current telesia-smart routes (same order) plus every Gemini
--    route of the other chat aliases (telesia-somali first), appended after them. Old alias rows are NOT deleted yet
--    (older ai-chat versions and the dashboard still read them); edit the order of `telesia` from the dashboard.
-- 2. ai_router_state: the shared "current route" pointer (one row). ai_route_rest: per-route rest with backoff.
-- 3. ai_router_snapshot(): pointer + active rests, returned inside ai_gate (no extra round trip).
-- 4. ai_router_report(route, kind, next): counts a failure of the current route inside a 60 s window and swaps the
--    pointer with a compare-and-set at 3 hard failures or 2 first-byte timeouts; the old route rests 1/2/4/8/15 min.
--    Called only on failures (never on success), so the router writes only when its state changes.
-- 5. ai_gate(): same signature and answer as 20261021_ai_gate, plus `router`; the cold-start keys are now those of the
--    current route's provider.
-- All functions are service-role only. Safe to re-run.

-- ---------------------------------------------------------------- 1. alias `telesia`
insert into public.ai_aliases (alias, description, max_output_tokens, system_hint, enabled)
select 'telesia', 'Telesia: the one public model (sticky router)', coalesce((select max_output_tokens from public.ai_aliases where alias = 'telesia-smart'), 8192), null, true
on conflict (alias) do nothing;

-- telesia-smart routes, same priorities.
insert into public.ai_routes (alias, model_ref, priority, enabled)
select 'telesia', r.model_ref, r.priority, r.enabled
  from public.ai_routes r where r.alias = 'telesia-smart'
on conflict (alias, model_ref) do nothing;

-- Gemini routes from the other chat aliases (Somali first), after the smart ones. Gemini models see pictures, so this
-- also gives the one list its vision routes.
insert into public.ai_routes (alias, model_ref, priority, enabled)
select 'telesia', x.model_ref, 1000 + row_number() over (order by x.rank, x.priority, x.model_ref) * 10, true
  from (
    select distinct on (r.model_ref) r.model_ref, r.priority,
           case r.alias when 'telesia-somali' then 0 when 'telesia-think' then 1 when 'telesia-vision' then 2 else 3 end as rank
      from public.ai_routes r
      join public.ai_models m on m.id = r.model_ref
      join public.ai_providers p on p.id = m.provider_id
     where r.alias in ('telesia-somali', 'telesia-think', 'telesia-vision', 'telesia-fast', 'telesia-lite')
       and r.enabled and (p.name ilike '%gemini%' or m.model_id ilike 'gemini%')
     order by r.model_ref, case r.alias when 'telesia-somali' then 0 when 'telesia-think' then 1 when 'telesia-vision' then 2 else 3 end, r.priority
  ) x
on conflict (alias, model_ref) do nothing;

-- ---------------------------------------------------------------- 2. router state
create table if not exists public.ai_router_state (
  id int primary key default 1 check (id = 1),
  alias text not null default 'telesia',
  current_route_id uuid references public.ai_routes(id) on delete set null,
  since timestamptz not null default now(),
  fail_count int not null default 0,      -- hard failures of the current route in this window
  fb_timeouts int not null default 0,     -- first-byte timeouts of the current route in this window
  window_start timestamptz,
  swaps int not null default 0,
  last_swap_reason text,
  updated_at timestamptz not null default now()
);
insert into public.ai_router_state (id) values (1) on conflict (id) do nothing;

create table if not exists public.ai_route_rest (
  route_id uuid primary key references public.ai_routes(id) on delete cascade,
  rested_until timestamptz not null,
  level int not null default 0,           -- 0..4 -> 1, 2, 4, 8, 15 min
  last_reason text,
  updated_at timestamptz not null default now()
);

alter table public.ai_router_state enable row level security;
alter table public.ai_route_rest enable row level security;
revoke all on public.ai_router_state from anon, authenticated;
revoke all on public.ai_route_rest from anon, authenticated;

-- ---------------------------------------------------------------- 3. snapshot (read inside ai_gate)
create or replace function public.ai_router_snapshot()
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select jsonb_build_object(
    -- Only a pointer to an enabled `telesia` route counts; anything else reads as "no pointer" (first healthy route).
    'current_route_id', (select s.current_route_id from ai_router_state s join ai_routes r on r.id = s.current_route_id
                          where s.id = 1 and r.enabled and r.alias = s.alias),
    'since', (select since from ai_router_state where id = 1),
    'rest', coalesce((select jsonb_object_agg(route_id::text, rested_until) from ai_route_rest where rested_until > now()), '{}'::jsonb)
  );
$function$;

-- ---------------------------------------------------------------- 4. report a failure; compare-and-set swap
create or replace function public.ai_router_report(p_route_id uuid, p_kind text, p_next_route_id uuid default null)
 returns jsonb
 language plpgsql
 volatile security definer
 set search_path to 'public'
as $function$
declare
  st ai_router_state;
  cur uuid;
  ladder int[] := array[1, 2, 4, 8, 15];
  lvl int;
  prev ai_route_rest;
  swap boolean := false;
begin
  if p_route_id is null or p_kind not in ('hard', 'fb_timeout') then
    return jsonb_build_object('swapped', false, 'ignored', true);
  end if;
  -- One row lock: concurrent reports are serialised, so 200 users failing at once make one swap, not 200.
  select * into st from ai_router_state where id = 1 for update;
  if not found then
    insert into ai_router_state (id) values (1) on conflict (id) do nothing;
    select * into st from ai_router_state where id = 1 for update;
  end if;
  -- The pointer's route, if it is still an enabled route of this alias; else the reporter's route is taken as current.
  select r.id into cur from ai_routes r where r.id = st.current_route_id and r.enabled and r.alias = st.alias;
  if cur is null then
    cur := p_route_id;
    update ai_router_state set current_route_id = p_route_id, since = now(), fail_count = 0, fb_timeouts = 0, window_start = now(), updated_at = now() where id = 1;
    select * into st from ai_router_state where id = 1;
  end if;
  -- Compare-and-set: a failure of a route that is no longer current (someone already swapped) changes nothing.
  if cur <> p_route_id then
    return jsonb_build_object('swapped', false, 'current_route_id', cur, 'stale', true);
  end if;
  if st.window_start is null or st.window_start < now() - interval '60 seconds' then
    st.fail_count := 0; st.fb_timeouts := 0; st.window_start := now();
  end if;
  if p_kind = 'hard' then st.fail_count := st.fail_count + 1; else st.fb_timeouts := st.fb_timeouts + 1; end if;
  swap := (st.fail_count >= 3 or st.fb_timeouts >= 2)
          and p_next_route_id is not null and p_next_route_id <> p_route_id
          and exists (select 1 from ai_routes r where r.id = p_next_route_id and r.enabled and r.alias = st.alias);
  if not swap then
    update ai_router_state set fail_count = st.fail_count, fb_timeouts = st.fb_timeouts, window_start = st.window_start, updated_at = now()
     where id = 1 and current_route_id = p_route_id;
    return jsonb_build_object('swapped', false, 'current_route_id', cur, 'fail_count', st.fail_count, 'fb_timeouts', st.fb_timeouts);
  end if;
  -- Backoff: a route that rested in the last 30 min goes one step up the ladder, otherwise it starts again at 1 min.
  select * into prev from ai_route_rest where route_id = p_route_id;
  lvl := case when prev.route_id is not null and prev.rested_until > now() - interval '30 minutes' then least(prev.level + 1, 4) else 0 end;
  insert into ai_route_rest (route_id, rested_until, level, last_reason, updated_at)
  values (p_route_id, now() + make_interval(mins => ladder[lvl + 1]), lvl, p_kind, now())
  on conflict (route_id) do update set rested_until = excluded.rested_until, level = excluded.level, last_reason = excluded.last_reason, updated_at = now();
  update ai_router_state
     set current_route_id = p_next_route_id, since = now(), fail_count = 0, fb_timeouts = 0, window_start = now(),
         swaps = swaps + 1, last_swap_reason = p_kind, updated_at = now()
   where id = 1 and current_route_id = p_route_id;
  return jsonb_build_object('swapped', true, 'current_route_id', p_next_route_id, 'rested_route_id', p_route_id, 'rest_seconds', ladder[lvl + 1] * 60);
end $function$;

-- ---------------------------------------------------------------- 5. ai_gate + router
create or replace function public.ai_gate(p_uid uuid, p_want_config boolean default false, p_alias text default null, p_need_tools boolean default false)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare
  rpm int;
  burst int := 0;
  u record;
  first_pid uuid;
  router jsonb := ai_router_snapshot();
  cur uuid := nullif(router ->> 'current_route_id', '')::uuid;
begin
  begin rpm := coalesce((select (value #>> '{}')::int from ai_settings where key = 'user_rpm'), 40); exception when others then rpm := 40; end;
  if rpm > 0 then
    select count(*) into burst from ai_usage
     where user_id = p_uid and status = 200 and created_at >= now() - interval '60 seconds';
  end if;
  select tokens, requests, bg_tokens into u from ai_user_daily where user_id = p_uid and day = (now() at time zone 'utc')::date;
  if p_alias is not null then
    -- Cold start: the keys of the route this request will try first (the current route when it fits).
    select p.id into first_pid
      from ai_routes r join ai_models m on m.id = r.model_ref join ai_providers p on p.id = m.provider_id
     where r.alias = p_alias and r.enabled and m.enabled and p.enabled and (not p_need_tools or m.tools)
       and exists (select 1 from ai_keys k where k.provider_id = p.id and k.enabled)
     order by (r.id = cur) desc nulls last, m.healthy desc, r.priority, r.id limit 1;
  end if;
  return jsonb_build_object(
    'blocked', exists (select 1 from ai_blocked_users b where b.user_id = p_uid),
    'burst', burst,
    'usage', jsonb_build_object('tokens', coalesce(u.tokens, 0), 'requests', coalesce(u.requests, 0), 'bg', coalesce(u.bg_tokens, 0)),
    'cap', ai_user_cap(p_uid),
    'config', case when p_want_config then ai_config_lite() else null end,
    'keys', case when first_pid is not null then ai_provider_keys(array[first_pid]) else null end,
    'router', router
  );
end $function$;

revoke all on function public.ai_router_snapshot() from public, anon, authenticated;
revoke all on function public.ai_router_report(uuid, text, uuid) from public, anon, authenticated;
revoke all on function public.ai_gate(uuid, boolean, text, boolean) from public, anon, authenticated;
grant execute on function public.ai_router_snapshot() to service_role;
grant execute on function public.ai_router_report(uuid, text, uuid) to service_role;
grant execute on function public.ai_gate(uuid, boolean, text, boolean) to service_role;

-- Undo: redeploying the previous ai-chat is enough (it ignores `router` in the gate answer and never reads the new
-- tables). The full manual undo is in the Dev 1 PR notes.
