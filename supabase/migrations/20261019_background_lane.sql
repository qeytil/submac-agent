-- Plan 2.2: the background lane. Bots and Offices (phone-side bot wakes, office work, the cloud runner bot-run) get
-- their own share of each user's daily allowance, so they never block the user's own chats.
--
-- ai_user_daily.bg_tokens  allowance tokens spent today by background work (also counted in tokens, the total).
-- ai_settings.background_share  share of daily_cap_tokens background work may use per day (0..1, default 0.3).
--
-- ai-chat marks a request background when it is an internal bot-run call (source 'bot-cloud') or the app sends
-- x-telesia-lane: background, and passes p.lane = 'background' to ai_record_usage. A background request is refused
-- with 429 background_paused once bg_tokens reaches the share or the total reaches the cap; the user's own chats
-- can still use the whole cap (and the grace after it).

alter table public.ai_user_daily add column if not exists bg_tokens bigint not null default 0;

insert into public.ai_settings(key, value) values ('background_share', '0.3'::jsonb) on conflict (key) do nothing;

create or replace function public.ai_record_usage(p jsonb)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  tot int := coalesce((p->>'quota_tokens')::int, coalesce((p->>'prompt_tokens')::int,0) + coalesce((p->>'completion_tokens')::int,0));
  bg int := case when p->>'lane' = 'background' or p->>'source' = 'bot-cloud' then tot else 0 end;
begin
  insert into ai_usage(user_id, source, alias, provider, model, key_id, status, prompt_tokens, completion_tokens, cached_tokens, ttft_ms, total_ms, tps, attempts, error)
  values ((p->>'user_id')::uuid, coalesce(p->>'source','app'), p->>'alias', p->>'provider', p->>'model', (p->>'key_id')::uuid,
          (p->>'status')::int, coalesce((p->>'prompt_tokens')::int,0), coalesce((p->>'completion_tokens')::int,0), coalesce((p->>'cached_tokens')::int,0),
          (p->>'ttft_ms')::int, (p->>'total_ms')::int, (p->>'tps')::numeric, coalesce((p->>'attempts')::int,1), left(p->>'error',300));
  if (p->>'user_id') is not null and coalesce(p->>'source','app') <> 'bench' and coalesce((p->>'status')::int, 0) = 200 then
    insert into ai_user_daily(user_id, day, tokens, requests, bg_tokens) values ((p->>'user_id')::uuid, (now() at time zone 'utc')::date, tot, 1, bg)
    on conflict (user_id, day) do update set tokens = ai_user_daily.tokens + excluded.tokens, requests = ai_user_daily.requests + 1,
      bg_tokens = ai_user_daily.bg_tokens + excluded.bg_tokens;
  end if;
end $function$;

revoke all on function public.ai_record_usage(jsonb) from public, anon, authenticated;
grant execute on function public.ai_record_usage(jsonb) to service_role;
