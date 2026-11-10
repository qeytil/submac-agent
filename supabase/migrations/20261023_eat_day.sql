-- Billing day = EAT (Africa/Mogadishu, UTC+3, no DST) everywhere: PLAN.md Contract A says x-telesia-resets-at is the next
-- EAT midnight, and usage_gate / billing v2 already count days in EAT (billing.eat_day). The legacy daily counters
-- (ai_user_daily for tokens, live_call_daily for call minutes, used while billing_enabled is false) were keyed by the
-- UTC date, so they reset at 03:00 EAT. From now on their `day` is the EAT date, so the allowance resets at 00:00 EAT.
--
-- Same bodies as before; the only change is (now() at time zone 'utc')::date -> (now() at time zone 'Africa/Mogadishu')::date
-- (and live_minutes_left.resets_at = next 00:00 EAT, still written in UTC with a Z). Applied between 00:00 and 21:00 UTC
-- the EAT and UTC dates are equal, so today's rows carry on unchanged. Edge functions read the same key: ai-chat today()
-- and bot-run eatDay() = EAT date; ai-admin reset_user_today / live_reset_user_today too. Safe to re-run.

-- ai_record_usage
CREATE OR REPLACE FUNCTION public.ai_record_usage(p jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  tot int := coalesce((p->>'quota_tokens')::int, coalesce((p->>'prompt_tokens')::int,0) + coalesce((p->>'completion_tokens')::int,0));
  bg int := case when p->>'lane' = 'background' or p->>'source' = 'bot-cloud' then tot else 0 end;
begin
  insert into ai_usage(user_id, source, alias, provider, model, key_id, status, prompt_tokens, completion_tokens, cached_tokens, ttft_ms, total_ms, tps, attempts, error)
  values ((p->>'user_id')::uuid, coalesce(p->>'source','app'), p->>'alias', p->>'provider', p->>'model', (p->>'key_id')::uuid,
          (p->>'status')::int, coalesce((p->>'prompt_tokens')::int,0), coalesce((p->>'completion_tokens')::int,0), coalesce((p->>'cached_tokens')::int,0),
          (p->>'ttft_ms')::int, (p->>'total_ms')::int, (p->>'tps')::numeric, coalesce((p->>'attempts')::int,1), left(p->>'error',300));
  if (p->>'user_id') is not null and coalesce(p->>'source','app') <> 'bench' and coalesce((p->>'status')::int, 0) = 200 then
    insert into ai_user_daily(user_id, day, tokens, requests, bg_tokens) values ((p->>'user_id')::uuid, (now() at time zone 'Africa/Mogadishu')::date, tot, 1, bg)
    on conflict (user_id, day) do update set tokens = ai_user_daily.tokens + excluded.tokens, requests = ai_user_daily.requests + 1,
      bg_tokens = ai_user_daily.bg_tokens + excluded.bg_tokens;
  end if;
end $function$;

-- ai_gate
CREATE OR REPLACE FUNCTION public.ai_gate(p_uid uuid, p_want_config boolean DEFAULT false, p_alias text DEFAULT NULL::text, p_need_tools boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  select tokens, requests, bg_tokens into u from ai_user_daily where user_id = p_uid and day = (now() at time zone 'Africa/Mogadishu')::date;
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

-- admin_anomaly_scan
CREATE OR REPLACE FUNCTION public.admin_anomaly_scan()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r record; n int := 0; d date := (now() at time zone 'Africa/Mogadishu')::date;
begin
  -- Over today's cap (incl. bonus).
  for r in select x.user_id, x.tokens, (ai_user_cap(x.user_id)->>'cap')::bigint cap from ai_user_daily x where x.day = d loop
    if r.tokens >= r.cap then
      perform flag_user(r.user_id, 'cap_hits', case when (select count(*) from ai_user_daily y where y.user_id = r.user_id and y.day > d - 7
                 and y.tokens >= reward_num('daily_cap_tokens', 200000)) >= 3 then 'medium' else 'low' end,
             'anomaly', 'Used the whole daily allowance today', jsonb_build_object('tokens', r.tokens, 'cap', r.cap)); n := n + 1;
    end if;
  end loop;
  -- Burst traffic: very many requests today.
  for r in select user_id, requests from ai_user_daily where day = d and requests >= 1500 loop
    perform flag_user(r.user_id, 'spam_automation', 'medium', 'anomaly', r.requests || ' requests today (looks automated)', '{}'::jsonb); n := n + 1;
  end loop;
  -- Several accounts on one phone install.
  for r in select device_id, array_agg(distinct user_id) ids from user_devices group by device_id having count(distinct user_id) >= 3 loop
    perform flag_user(u, 'multi_account', 'medium', 'anomaly', array_length(r.ids, 1) || ' accounts on one phone', jsonb_build_object('device', left(r.device_id, 6))) from unnest(r.ids) u;
    n := n + 1;
  end loop;
  -- Invitees who never used Telesia (2+ days after joining) for an inviter with 3+ rewarded invites.
  for r in select f.inviter_id, count(*) idle from referrals f
            where f.kind = 'invite' and f.status = 'rewarded' and f.created_at < now() - interval '2 days'
              and not exists (select 1 from ai_user_daily y where y.user_id = f.invitee_id)
            group by f.inviter_id having count(*) >= 3 loop
    perform flag_user(r.inviter_id, 'reward_farming', 'medium', 'anomaly', r.idle || ' invited accounts never used Telesia', '{}'::jsonb); n := n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'flags_touched', n);
end $function$;

-- admin_user_detail
CREATE OR REPLACE FUNCTION public.admin_user_detail(p_uid uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth', 'storage'
AS $function$
  select jsonb_build_object(
    'profile', (select jsonb_build_object('user_id', id, 'email', email, 'created_at', created_at, 'last_sign_in_at', last_sign_in_at,
                  'confirmed_at', email_confirmed_at, 'providers', raw_app_meta_data->'providers') from auth.users where id = p_uid),
    'devices', coalesce((select jsonb_agg(jsonb_build_object('device', left(device_id, 6) || '…', 'device_id', device_id, 'platform', platform,
                  'app_version', app_version, 'first_seen', first_seen, 'last_seen', last_seen,
                  'other_accounts', (select count(distinct d2.user_id) from user_devices d2 where d2.device_id = d.device_id and d2.user_id <> p_uid))
                  order by last_seen desc) from user_devices d where user_id = p_uid), '[]'::jsonb),
    'push', jsonb_build_object('tokens', (select count(*) from push_tokens where user_id = p_uid),
                  'updated_at', (select max(updated_at) from push_tokens where user_id = p_uid)),
    'usage', coalesce((select jsonb_agg(jsonb_build_object('day', day, 'tokens', tokens, 'bg_tokens', bg_tokens, 'requests', requests) order by day desc)
                  from ai_user_daily where user_id = p_uid and day > (now() at time zone 'Africa/Mogadishu')::date - 30), '[]'::jsonb),
    'live', coalesce((select jsonb_agg(jsonb_build_object('day', day, 'seconds', seconds, 'calls', calls) order by day desc)
                  from live_call_daily where user_id = p_uid and day > (now() at time zone 'Africa/Mogadishu')::date - 30), '[]'::jsonb),
    'live_limits', (select to_jsonb(l) - 'user_id' from live_user_limits l where user_id = p_uid),
    'recent_requests', coalesce((select jsonb_agg(jsonb_build_object('at', created_at, 'source', source, 'alias', alias, 'status', status,
                  'prompt_tokens', prompt_tokens, 'completion_tokens', completion_tokens) order by created_at desc)
                  from (select * from ai_usage where user_id = p_uid order by created_at desc limit 40) r), '[]'::jsonb),
    'cap', ai_user_cap(p_uid),
    'limits', (select to_jsonb(l) - 'user_id' from ai_user_limits l where user_id = p_uid),
    'suspended', (select jsonb_build_object('reason', reason, 'since', created_at) from ai_blocked_users where user_id = p_uid),
    'rewards', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'kind', kind, 'amount_per_day', amount_per_day, 'days', days,
                  'starts_at', starts_at, 'expires_at', expires_at, 'revoked', revoked, 'revoked_at', revoked_at, 'revoked_by', revoked_by,
                  'revoke_reason', revoke_reason, 'note', note, 'created_by', created_by, 'created_at', created_at,
                  'state', case when revoked then 'revoked' when expires_at <= now() then 'expired' else 'active' end) order by created_at desc)
                  from reward_ledger where user_id = p_uid), '[]'::jsonb),
    'invite_code', (select code from referral_codes where user_id = p_uid),
    'referrals_made', coalesce((select jsonb_agg(jsonb_build_object('kind', r.kind, 'other', u.email, 'other_id', r.invitee_id, 'source', r.source,
                  'bot', b.name, 'status', r.status, 'reason', r.reason, 'at', r.created_at) order by r.created_at desc)
                  from referrals r left join auth.users u on u.id = r.invitee_id left join bot_store b on b.id = r.bot_store_id
                  where r.inviter_id = p_uid), '[]'::jsonb),
    'referred_by', coalesce((select jsonb_agg(jsonb_build_object('kind', r.kind, 'other', u.email, 'other_id', r.inviter_id, 'source', r.source,
                  'status', r.status, 'reason', r.reason, 'at', r.created_at) order by r.created_at desc)
                  from referrals r left join auth.users u on u.id = r.inviter_id where r.invitee_id = p_uid), '[]'::jsonb),
    -- Published Bot Store content is public, so it is shown in full; unlisted share-code copies show card fields only.
    'store_bots', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'role', role, 'blurb', blurb, 'published', published,
                  'share_code', share_code, 'hires', hires, 'created_at', created_at, 'updated_at', updated_at,
                  'instructions', case when published then left(coalesce(package->>'instructions', ''), 6000) end,
                  'persona', case when published then left(coalesce(package->>'persona', ''), 3000) end,
                  'skills', case when published then jsonb_array_length(case when jsonb_typeof(package->'skills') = 'array' then package->'skills' else '[]'::jsonb end) end,
                  'knowledge', case when published then jsonb_array_length(case when jsonb_typeof(package->'knowledge') = 'array' then package->'knowledge' else '[]'::jsonb end) end)
                  order by created_at desc) from bot_store where author_id = p_uid), '[]'::jsonb),
    'cloud_bots', coalesce((select jsonb_agg(jsonb_build_object('bot_id', bot_id, 'name', name, 'cloud_enabled', cloud_enabled, 'deleted', deleted,
                  'last_run_at', last_run_at, 'next_run_at', next_run_at, 'updated_at', updated_at,
                  'jobs', jsonb_array_length(case when jsonb_typeof(schedule) = 'array' then schedule else '[]'::jsonb end)) order by updated_at desc)
                  from cloud_bots where user_id = p_uid), '[]'::jsonb),
    'hired', (select count(*) from bot_store_hires where user_id = p_uid),
    'events', coalesce((select jsonb_agg(jsonb_build_object('kind', kind, 'bot_id', bot_id, 'props', props, 'at', at) order by at desc)
                  from (select * from events where user_id = p_uid order by at desc limit 100) e), '[]'::jsonb),
    'activity', jsonb_build_object(
      'conversations', (select count(*) from conversations where user_id = p_uid),
      'conversations_30d', (select count(*) from conversations where user_id = p_uid and updated_at > now() - interval '30 days'),
      'messages', (select count(*) from messages where user_id = p_uid),
      'user_messages', (select count(*) from messages where user_id = p_uid and role = 'user'),
      'messages_7d', (select count(*) from messages where user_id = p_uid and created_at > now() - interval '7 days'),
      'last_message_at', (select max(created_at) from messages where user_id = p_uid),
      'first_message_at', (select min(created_at) from messages where user_id = p_uid),
      'memories', (select count(*) from memories where user_id = p_uid),
      'files', (select count(*) from storage.objects where owner = p_uid),
      'messages_by_day', coalesce((select jsonb_agg(jsonb_build_object('day', d, 'n', n) order by d desc) from (
          select (created_at at time zone 'utc')::date d, count(*) n from messages where user_id = p_uid and created_at > now() - interval '14 days' group by 1) x), '[]'::jsonb)),
    'flags', coalesce((select jsonb_agg(to_jsonb(f) - 'user_id' order by created_at desc) from (select * from safety_flags where user_id = p_uid order by created_at desc limit 100) f), '[]'::jsonb),
    'notes', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'note', note, 'by', created_by, 'at', created_at) order by created_at desc) from admin_notes where user_id = p_uid), '[]'::jsonb),
    'inbox', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'kind', kind, 'message_id', message_id, 'title', title, 'in_chat', in_chat, 'push', push,
                  'push_status', push_status, 'read_at', read_at, 'deleted', deleted, 'at', created_at) order by created_at desc)
                  from (select * from user_inbox where user_id = p_uid order by created_at desc limit 50) i), '[]'::jsonb)
  )
$function$;

-- admin_users_list
CREATE OR REPLACE FUNCTION public.admin_users_list(p_search text DEFAULT ''::text, p_limit integer DEFAULT 200, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
  with u as (
    select id, email, created_at, last_sign_in_at from auth.users
     where coalesce(p_search, '') = '' or email ilike '%' || p_search || '%' or id::text = p_search
     order by created_at desc limit least(greatest(p_limit, 1), 1000) offset greatest(p_offset, 0)
  ),
  today as (select (now() at time zone 'Africa/Mogadishu')::date as d)
  select coalesce(jsonb_agg(jsonb_build_object(
    'user_id', u.id, 'email', u.email, 'created_at', u.created_at, 'last_sign_in_at', u.last_sign_in_at,
    'last_active', greatest(u.last_sign_in_at, (select max(last_seen) from user_devices where user_id = u.id),
                            (select max(created_at) from ai_usage where user_id = u.id and created_at > now() - interval '30 days')),
    'app_version', (select app_version from user_devices where user_id = u.id order by last_seen desc limit 1),
    'devices', (select count(*) from user_devices where user_id = u.id),
    'push', exists (select 1 from push_tokens where user_id = u.id),
    'tokens_today', coalesce((select tokens from ai_user_daily, today where user_id = u.id and day = today.d), 0),
    'requests_today', coalesce((select requests from ai_user_daily, today where user_id = u.id and day = today.d), 0),
    'cap', ai_user_cap(u.id),
    'suspended', exists (select 1 from ai_blocked_users where user_id = u.id),
    'open_flags', (select count(*) from safety_flags where user_id = u.id and not resolved),
    'top_severity', (select max(case severity when 'high' then 3 when 'medium' then 2 else 1 end) from safety_flags where user_id = u.id and not resolved),
    'rewards_active', (select count(*) from reward_ledger where user_id = u.id and not revoked and expires_at > now()),
    'bots_published', (select count(*) from bot_store where author_id = u.id and published),
    'cloud_bots', (select count(*) from cloud_bots where user_id = u.id and not deleted),
    'conversations', (select count(*) from conversations where user_id = u.id),
    'messages', (select count(*) from messages where user_id = u.id)
  ) order by u.created_at desc), '[]'::jsonb)
  from u
$function$;

-- ai_stats
CREATE OR REPLACE FUNCTION public.ai_stats(p_hours integer DEFAULT 24)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
      where d.day = (now() at time zone 'Africa/Mogadishu')::date order by d.tokens desc limit 20) u), '[]'::jsonb),
    'errors', coalesce((select jsonb_agg(e) from (
      select created_at, provider, model, status, error from ai_usage where status <> 200 and created_at > now() - make_interval(hours => p_hours)
      order by created_at desc limit 30) e), '[]'::jsonb)
  );
$function$;

-- live_add_seconds
CREATE OR REPLACE FUNCTION public.live_add_seconds(p_uid uuid, p_seconds integer, p_calls integer DEFAULT 0)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  insert into live_call_daily(user_id, day, seconds, calls) values (p_uid, (now() at time zone 'Africa/Mogadishu')::date, greatest(p_seconds, 0), greatest(p_calls, 0))
  on conflict (user_id, day) do update set seconds = live_call_daily.seconds + excluded.seconds,
    calls = live_call_daily.calls + excluded.calls, updated_at = now();
$function$;

-- live_minutes_left
CREATE OR REPLACE FUNCTION public.live_minutes_left(p_uid uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare def int; lim int; en boolean := true; ovr int; used int := 0; calls int := 0; left_s int;
begin
  select coalesce((value #>> '{}')::int, 15) into def from ai_settings where key = 'live_daily_minutes';
  def := coalesce(def, 15);
  select daily_minutes, live_enabled into ovr, en from live_user_limits where user_id = p_uid;
  en := coalesce(en, true);
  lim := coalesce(ovr, def);
  select d.seconds, d.calls into used, calls from live_call_daily d where d.user_id = p_uid and d.day = (now() at time zone 'Africa/Mogadishu')::date;
  used := coalesce(used, 0); calls := coalesce(calls, 0);
  left_s := case when en then greatest(lim * 60 - used, 0) else 0 end;
  return jsonb_build_object('limit_minutes', lim, 'default_minutes', def, 'override_minutes', ovr, 'enabled', en,
    'used_seconds', used, 'calls', calls, 'seconds_left', left_s, 'minutes_left', floor(left_s / 60.0)::int,
    'resets_at', to_char(((((now() at time zone 'Africa/Mogadishu')::date + 1)::timestamp at time zone 'Africa/Mogadishu') at time zone 'utc'), 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
end $function$;

-- live_minutes_report
CREATE OR REPLACE FUNCTION public.live_minutes_report()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with def as (select coalesce((select (value #>> '{}')::int from ai_settings where key = 'live_daily_minutes'), 15) m),
  ids as (
    select user_id from live_call_daily where day = (now() at time zone 'Africa/Mogadishu')::date
    union select user_id from live_user_limits
  )
  select jsonb_build_object(
    'default_minutes', (select m from def),
    'day', (now() at time zone 'Africa/Mogadishu')::date,
    'users', coalesce((select jsonb_agg(x order by x.used_seconds desc, x.email) from (
      select i.user_id, au.email,
        coalesce(d.seconds, 0) used_seconds, round(coalesce(d.seconds, 0) / 60.0, 1) used_minutes, coalesce(d.calls, 0) calls,
        l.daily_minutes override_minutes, coalesce(l.live_enabled, true) enabled, coalesce(l.daily_minutes, (select m from def)) limit_minutes,
        case when coalesce(l.live_enabled, true) then greatest(coalesce(l.daily_minutes, (select m from def)) * 60 - coalesce(d.seconds, 0), 0) else 0 end seconds_left,
        exists (select 1 from live_calls c where c.user_id = i.user_id and c.ended_at is null and c.last_beat_at > now() - interval '150 seconds') in_call,
        l.note
      from ids i left join auth.users au on au.id = i.user_id
      left join live_call_daily d on d.user_id = i.user_id and d.day = (now() at time zone 'Africa/Mogadishu')::date
      left join live_user_limits l on l.user_id = i.user_id) x), '[]'::jsonb)
  );
$function$;
