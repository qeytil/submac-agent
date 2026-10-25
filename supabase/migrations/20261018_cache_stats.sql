-- Plan 1 step 4: cache-hit stats. Records the prompt tokens each provider served from its cache
-- and adds them to ai_stats (per route `pcached`, totals `cached_tokens`) for the dashboard.
-- Safe in any order with the ai-chat deploy: an older proxy just records 0.
-- Applied to production 2026-10-18.
alter table public.ai_usage add column if not exists cached_tokens int not null default 0;

create or replace function public.ai_record_usage(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare tot int := coalesce((p->>'quota_tokens')::int, coalesce((p->>'prompt_tokens')::int,0) + coalesce((p->>'completion_tokens')::int,0));
begin
  insert into ai_usage(user_id, source, alias, provider, model, key_id, status, prompt_tokens, completion_tokens, cached_tokens, ttft_ms, total_ms, tps, attempts, error)
  values ((p->>'user_id')::uuid, coalesce(p->>'source','app'), p->>'alias', p->>'provider', p->>'model', (p->>'key_id')::uuid,
          (p->>'status')::int, coalesce((p->>'prompt_tokens')::int,0), coalesce((p->>'completion_tokens')::int,0), coalesce((p->>'cached_tokens')::int,0),
          (p->>'ttft_ms')::int, (p->>'total_ms')::int, (p->>'tps')::numeric, coalesce((p->>'attempts')::int,1), left(p->>'error',300));
  if (p->>'user_id') is not null and coalesce(p->>'source','app') <> 'bench' and coalesce((p->>'status')::int, 0) = 200 then
    insert into ai_user_daily(user_id, day, tokens, requests) values ((p->>'user_id')::uuid, (now() at time zone 'utc')::date, tot, 1)
    on conflict (user_id, day) do update set tokens = ai_user_daily.tokens + excluded.tokens, requests = ai_user_daily.requests + 1;
  end if;
end $$;

create or replace function public.ai_stats(p_hours int default 24) returns jsonb
language sql security definer set search_path = public as $$
  select jsonb_build_object(
    'routes', coalesce((select jsonb_agg(x) from (
      select provider, model, source, count(*) n,
        count(*) filter (where status = 200) ok,
        percentile_cont(0.5) within group (order by ttft_ms) filter (where status = 200) ttft_p50,
        percentile_cont(0.95) within group (order by ttft_ms) filter (where status = 200) ttft_p95,
        percentile_cont(0.5) within group (order by tps) filter (where status = 200 and tps > 0) tps_p50,
        percentile_cont(0.05) within group (order by tps) filter (where status = 200 and tps > 0) tps_p05,
        percentile_cont(0.5) within group (order by total_ms) filter (where status = 200) total_p50,
        sum(prompt_tokens) pin, sum(completion_tokens) pout, sum(cached_tokens) pcached
      from ai_usage where created_at > now() - make_interval(hours => p_hours) and provider is not null
      group by provider, model, source order by n desc) x), '[]'::jsonb),
    'totals', (select jsonb_build_object('requests', count(*), 'ok', count(*) filter (where status = 200),
        'users', count(distinct user_id), 'prompt_tokens', coalesce(sum(prompt_tokens),0), 'completion_tokens', coalesce(sum(completion_tokens),0),
        'cached_tokens', coalesce(sum(cached_tokens),0),
        'ttft_p50', percentile_cont(0.5) within group (order by ttft_ms) filter (where status=200),
        'ttft_p95', percentile_cont(0.95) within group (order by ttft_ms) filter (where status=200),
        'tps_p50', percentile_cont(0.5) within group (order by tps) filter (where status=200 and tps>0))
      from ai_usage where source <> 'bench' and created_at > now() - make_interval(hours => p_hours)),
    'top_users', coalesce((select jsonb_agg(u) from (
      select d.user_id, au.email, d.tokens, d.requests from ai_user_daily d left join auth.users au on au.id = d.user_id
      where d.day = (now() at time zone 'utc')::date order by d.tokens desc limit 20) u), '[]'::jsonb),
    'errors', coalesce((select jsonb_agg(e) from (
      select created_at, provider, model, status, error from ai_usage where status <> 200 and created_at > now() - make_interval(hours => p_hours)
      order by created_at desc limit 30) e), '[]'::jsonb)
  );
$$;

-- create or replace keeps existing grants, but restate the lock-down to be safe.
revoke all on function public.ai_record_usage(jsonb) from public, anon, authenticated;
grant execute on function public.ai_record_usage(jsonb) to service_role;
revoke all on function public.ai_stats(integer) from public, anon, authenticated;
grant execute on function public.ai_stats(integer) to service_role;
