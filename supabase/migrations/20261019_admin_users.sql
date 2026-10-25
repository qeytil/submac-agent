-- Admin dashboard Users section: per-user panel data, admin notes, admin messages ("From SubMac"), anomaly scan.
-- Agent project moeemacbvsueekuvfjbo. Recorded in schema_migrations as 20261019230000. Needs 20261019_rewards.
--
-- Privacy line: nothing here returns the text of a user's private chats, memories, files or bot setups. The admin sees
-- counts, timestamps, usage numbers, safety flags (category + short reason), rewards, and public Bot Store content.

-- ---------- admin messages ----------
create table if not exists public.admin_messages (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(title) between 1 and 200),
  body text not null default '' check (char_length(body) <= 4000),
  delivery text not null check (delivery in ('push', 'chat', 'both')),
  audience text not null check (audience in ('one', 'selected', 'all')),
  recipients integer not null default 0,
  push_sent integer not null default 0,
  push_failed integer not null default 0,
  push_no_device integer not null default 0,
  created_by text not null,
  created_at timestamptz not null default now(),
  edited_at timestamptz,
  deleted_at timestamptz
);
create index if not exists admin_messages_created_idx on public.admin_messages (created_at desc);
alter table public.admin_messages enable row level security;
revoke all on public.admin_messages from anon, authenticated;

do $$ begin
  alter table public.user_inbox add constraint user_inbox_message_fk foreign key (message_id) references public.admin_messages(id) on delete cascade;
exception when duplicate_object then null; end $$;

-- ---------- admin notes (internal, never shown to the user) ----------
create table if not exists public.admin_notes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  note text not null check (char_length(note) between 1 and 2000),
  created_by text not null,
  created_at timestamptz not null default now()
);
create index if not exists admin_notes_user_idx on public.admin_notes (user_id, created_at desc);
alter table public.admin_notes enable row level security;
revoke all on public.admin_notes from anon, authenticated;

create index if not exists messages_user_idx on public.messages (user_id, created_at desc);

-- ---------- users list ----------
create or replace function public.admin_users_list(p_search text default '', p_limit integer default 200, p_offset integer default 0)
returns jsonb language sql stable security definer set search_path = public, auth as $$
  with u as (
    select id, email, created_at, last_sign_in_at from auth.users
     where coalesce(p_search, '') = '' or email ilike '%' || p_search || '%' or id::text = p_search
     order by created_at desc limit least(greatest(p_limit, 1), 1000) offset greatest(p_offset, 0)
  ),
  today as (select (now() at time zone 'utc')::date as d)
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
$$;
revoke all on function public.admin_users_list(text, integer, integer) from public, anon, authenticated;
grant execute on function public.admin_users_list(text, integer, integer) to service_role;

-- ---------- one user's container ----------
create or replace function public.admin_user_detail(p_uid uuid) returns jsonb
language sql stable security definer set search_path = public, auth, storage as $$
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
                  from ai_user_daily where user_id = p_uid and day > (now() at time zone 'utc')::date - 30), '[]'::jsonb),
    'live', coalesce((select jsonb_agg(jsonb_build_object('day', day, 'seconds', seconds, 'calls', calls) order by day desc)
                  from live_call_daily where user_id = p_uid and day > (now() at time zone 'utc')::date - 30), '[]'::jsonb),
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
$$;
revoke all on function public.admin_user_detail(uuid) from public, anon, authenticated;
grant execute on function public.admin_user_detail(uuid) to service_role;

-- ---------- rewards ledger for the dashboard ----------
create or replace function public.admin_rewards_list(p_state text default 'all', p_limit integer default 300) returns jsonb
language sql stable security definer set search_path = public, auth as $$
  select coalesce(jsonb_agg(x order by (x->>'created_at') desc), '[]'::jsonb) from (
    select jsonb_build_object('id', r.id, 'user_id', r.user_id, 'email', u.email, 'kind', r.kind, 'amount_per_day', r.amount_per_day, 'days', r.days,
      'starts_at', r.starts_at, 'expires_at', r.expires_at, 'revoked', r.revoked, 'revoked_at', r.revoked_at, 'revoked_by', r.revoked_by,
      'revoke_reason', r.revoke_reason, 'note', r.note, 'created_by', r.created_by, 'created_at', r.created_at,
      'from_email', fu.email, 'bot', b.name, 'source', rf.source,
      'state', case when r.revoked then 'revoked' when r.expires_at <= now() then 'expired' else 'active' end) x
    from reward_ledger r join auth.users u on u.id = r.user_id
    left join referrals rf on rf.id = r.referral_id left join auth.users fu on fu.id = rf.invitee_id left join bot_store b on b.id = rf.bot_store_id
    where p_state = 'all' or (p_state = 'active' and not r.revoked and r.expires_at > now())
       or (p_state = 'revoked' and r.revoked) or (p_state = 'expired' and not r.revoked and r.expires_at <= now())
    order by r.created_at desc limit least(greatest(p_limit, 1), 2000)) q
$$;
revoke all on function public.admin_rewards_list(text, integer) from public, anon, authenticated;
grant execute on function public.admin_rewards_list(text, integer) to service_role;

-- ---------- anomaly scan (hourly, from the dashboard cron via ai-admin) ----------
create or replace function public.admin_anomaly_scan() returns jsonb
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0; d date := (now() at time zone 'utc')::date;
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
  -- Invitees who never used SubMac (2+ days after joining) for an inviter with 3+ rewarded invites.
  for r in select f.inviter_id, count(*) idle from referrals f
            where f.kind = 'invite' and f.status = 'rewarded' and f.created_at < now() - interval '2 days'
              and not exists (select 1 from ai_user_daily y where y.user_id = f.invitee_id)
            group by f.inviter_id having count(*) >= 3 loop
    perform flag_user(r.inviter_id, 'reward_farming', 'medium', 'anomaly', r.idle || ' invited accounts never used SubMac', '{}'::jsonb); n := n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'flags_touched', n);
end $$;
revoke all on function public.admin_anomaly_scan() from public, anon, authenticated;
grant execute on function public.admin_anomaly_scan() to service_role;

-- Safety check switches (dashboard Settings).
insert into public.ai_settings(key, value) values ('moderation_enabled', 'true'::jsonb), ('moderation_model_check', 'true'::jsonb) on conflict (key) do nothing;
