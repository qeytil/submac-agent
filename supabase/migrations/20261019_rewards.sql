-- Plan 2.4: referral and creator rewards (+ the "From Telesia" inbox the rewards write into).
-- Agent project moeemacbvsueekuvfjbo. Recorded in schema_migrations as 20261019220000.
--
-- Plain words: every user has a daily AI allowance (ai_settings.daily_cap_tokens). Rewards add a temporary bonus:
--  * referral: a NEW person signs up through your invite link/code  -> reward_referral_tokens per day for reward_referral_days
--  * creator:  someone hires your published Bot Store bot for the first time -> reward_creator_tokens/day for reward_creator_days
--  * admin_grant: the owner gives a bonus from the dashboard (not limited by the caps below)
-- Guards: no self-referral / own bot, each account counts once (one inviter ever; once per creator), the invitee account must
-- be new (reward_invite_window_days), the same phone (install id) cannot reward its own other accounts, and per person caps:
-- reward_max_bonus_per_day (tokens/day from earned rewards), reward_max_lifetime (earned rewards ever), reward_max_new_per_day.
-- Every number lives in ai_settings, so the dashboard changes it with no app update.

-- ---------- settings ----------
insert into public.ai_settings(key, value) values
  ('reward_enabled', 'true'::jsonb),
  ('reward_referral_tokens', '30000'::jsonb),
  ('reward_referral_days', '7'::jsonb),
  ('reward_creator_tokens', '30000'::jsonb),
  ('reward_creator_days', '7'::jsonb),
  ('reward_max_bonus_per_day', '150000'::jsonb),
  ('reward_max_lifetime', '20'::jsonb),
  ('reward_max_new_per_day', '5'::jsonb),
  ('reward_invite_window_days', '7'::jsonb)
on conflict (key) do nothing;

create or replace function public.reward_num(p_key text, p_default numeric) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce((select case when jsonb_typeof(value) = 'number' then (value)::text::numeric
                               when jsonb_typeof(value) = 'string' and (value #>> '{}') ~ '^[0-9.]+$' then (value #>> '{}')::numeric end
                   from ai_settings where key = p_key), p_default)
$$;
revoke all on function public.reward_num(text, numeric) from public, anon, authenticated;

-- ---------- devices (install ids) ----------
-- One row per account per phone install. Written by touch_device() when the app starts signed in. Used for the
-- same-phone guard and, in the dashboard, for last active / app version. Users cannot read it back.
create table if not exists public.user_devices (
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id text not null check (char_length(device_id) between 6 and 64),
  platform text not null default 'android',
  app_version text,
  first_seen timestamptz not null default now(),
  last_seen timestamptz not null default now(),
  primary key (user_id, device_id)
);
create index if not exists user_devices_device_idx on public.user_devices (device_id);
alter table public.user_devices enable row level security;
revoke all on public.user_devices from anon, authenticated;

create or replace function public.touch_device(p_device text, p_version text default null, p_platform text default 'android') returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or p_device is null or p_device !~ '^[A-Za-z0-9_-]{6,64}$' then return; end if;
  insert into user_devices(user_id, device_id, platform, app_version)
  values (auth.uid(), p_device, left(coalesce(p_platform, 'android'), 16), left(p_version, 24))
  on conflict (user_id, device_id) do update set last_seen = now(),
    app_version = coalesce(left(excluded.app_version, 24), user_devices.app_version), platform = excluded.platform;
end $$;
revoke all on function public.touch_device(text, text, text) from public, anon;
grant execute on function public.touch_device(text, text, text) to authenticated;

-- ---------- invite codes ----------
create table if not exists public.referral_codes (
  user_id uuid primary key references auth.users(id) on delete cascade,
  code text not null unique check (code ~ '^[A-Z0-9]{6,12}$'),
  created_at timestamptz not null default now()
);
alter table public.referral_codes enable row level security;
revoke all on public.referral_codes from anon, authenticated;

-- ---------- referrals (who brought whom) ----------
create table if not exists public.referrals (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('invite', 'hire')),
  inviter_id uuid not null references auth.users(id) on delete cascade,
  invitee_id uuid not null references auth.users(id) on delete cascade,
  source text not null default 'link',          -- invite: link | code | hire_link ; hire: store | link | code
  bot_store_id uuid,                             -- hire: the listing (no FK: the listing may be removed later)
  ref_code text,
  device_id text,
  status text not null default 'rewarded' check (status in ('rewarded', 'refused')),
  reason text,                                   -- refused: self | own_bot | not_new | already | same_device | device_used | cap | disabled
  created_at timestamptz not null default now()
);
create unique index if not exists referrals_invite_once on public.referrals (invitee_id) where kind = 'invite' and status = 'rewarded';
create unique index if not exists referrals_hire_once on public.referrals (inviter_id, invitee_id) where kind = 'hire' and status = 'rewarded';
create index if not exists referrals_inviter_idx on public.referrals (inviter_id, created_at desc);
create index if not exists referrals_invitee_idx on public.referrals (invitee_id, created_at desc);
alter table public.referrals enable row level security;
revoke all on public.referrals from anon, authenticated;

-- ---------- reward ledger ----------
create table if not exists public.reward_ledger (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null check (kind in ('referral', 'creator', 'admin_grant')),
  amount_per_day integer not null check (amount_per_day between 0 and 100000000),
  days integer not null check (days between 1 and 3650),
  starts_at timestamptz not null default now(),
  expires_at timestamptz not null,
  status text not null default 'active' check (status in ('active', 'revoked')),   -- expired = expires_at <= now()
  revoked boolean not null default false,
  revoked_at timestamptz,
  revoked_by text,
  revoke_reason text,
  referral_id uuid references public.referrals(id) on delete set null,
  note text,
  created_by text not null default 'system',
  created_at timestamptz not null default now()
);
create index if not exists reward_ledger_user_idx on public.reward_ledger (user_id, expires_at desc);
create index if not exists reward_ledger_created_idx on public.reward_ledger (created_at desc);
alter table public.reward_ledger enable row level security;
revoke all on public.reward_ledger from anon, authenticated;

-- ---------- "From Telesia" inbox ----------
-- Everything the owner sends a user (admin messages, reward grants) and earned-reward notices. Users read their own rows
-- and mark them read through inbox_mark(); nothing else.
create table if not exists public.user_inbox (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null check (kind in ('admin_message', 'reward_grant', 'reward_earned')),
  message_id uuid,                     -- admin_messages.id (FK added by the admin migration)
  reward_id uuid references public.reward_ledger(id) on delete set null,
  title text not null default '' check (char_length(title) <= 200),
  body text not null default '' check (char_length(body) <= 4000),
  in_chat boolean not null default false,
  push boolean not null default false,
  push_status text,                    -- sent | no_device | failed | null (not asked)
  read_at timestamptz,
  deleted boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists user_inbox_user_idx on public.user_inbox (user_id, updated_at desc);
create index if not exists user_inbox_msg_idx on public.user_inbox (message_id);
alter table public.user_inbox enable row level security;
revoke all on public.user_inbox from anon, authenticated;
grant select on public.user_inbox to authenticated;
drop policy if exists user_inbox_own on public.user_inbox;
create policy user_inbox_own on public.user_inbox for select to authenticated using (user_id = auth.uid());

create or replace function public.inbox_mark(p_ids uuid[], p_read boolean default true) returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if auth.uid() is null then return 0; end if;
  update user_inbox set read_at = case when p_read then coalesce(read_at, now()) else null end, updated_at = now()
   where user_id = auth.uid() and id = any(coalesce(p_ids, '{}')) and (read_at is null) = p_read;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.inbox_mark(uuid[], boolean) from public, anon;
grant execute on function public.inbox_mark(uuid[], boolean) to authenticated;

-- ---------- safety flags (also used by the admin Users section) ----------
create table if not exists public.safety_flags (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  category text not null check (category in ('fraud_scam', 'illegal', 'abuse_harassment', 'minor_sexual', 'self_harm',
                                             'spam_automation', 'reward_farming', 'multi_account', 'cap_hits', 'other')),
  severity text not null default 'low' check (severity in ('low', 'medium', 'high')),
  source text not null default 'anomaly' check (source in ('moderation', 'anomaly', 'admin', 'rewards')),
  reason text not null default '' check (char_length(reason) <= 240),
  meta jsonb not null default '{}'::jsonb check (octet_length(meta::text) <= 1000),
  resolved boolean not null default false,
  resolved_by text,
  resolved_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists safety_flags_user_idx on public.safety_flags (user_id, created_at desc);
create index if not exists safety_flags_open_idx on public.safety_flags (resolved, created_at desc);
alter table public.safety_flags enable row level security;
revoke all on public.safety_flags from anon, authenticated;

-- One open flag per user + category + day (no floods).
create or replace function public.flag_user(p_uid uuid, p_category text, p_severity text, p_source text, p_reason text, p_meta jsonb default '{}'::jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare fid uuid;
begin
  if p_uid is null then return null; end if;
  select id into fid from safety_flags where user_id = p_uid and category = p_category and not resolved
     and created_at > now() - interval '24 hours' order by created_at desc limit 1;
  if fid is not null then
    update safety_flags set severity = case when p_severity = 'high' or severity = 'high' then 'high'
                                            when p_severity = 'medium' or severity = 'medium' then 'medium' else 'low' end,
           meta = jsonb_set(meta, '{repeats}', to_jsonb(coalesce((meta->>'repeats')::int, 1) + 1))
     where id = fid;
    return fid;
  end if;
  insert into safety_flags(user_id, category, severity, source, reason, meta)
  values (p_uid, p_category, coalesce(p_severity, 'low'), coalesce(p_source, 'anomaly'), left(coalesce(p_reason, ''), 240), coalesce(p_meta, '{}'::jsonb))
  returning id into fid;
  return fid;
end $$;
revoke all on function public.flag_user(uuid, text, text, text, text, jsonb) from public, anon, authenticated;
grant execute on function public.flag_user(uuid, text, text, text, text, jsonb) to service_role;

-- ---------- per-user cap override (admin) ----------
create table if not exists public.ai_user_limits (
  user_id uuid primary key references auth.users(id) on delete cascade,
  daily_cap_tokens bigint check (daily_cap_tokens is null or daily_cap_tokens between 0 and 1000000000),
  note text,
  updated_at timestamptz not null default now()
);
alter table public.ai_user_limits enable row level security;
revoke all on public.ai_user_limits from anon, authenticated;

-- ---------- core: grant a reward ----------
-- Earned kinds (referral, creator) respect reward_max_lifetime and reward_max_new_per_day; admin_grant does not.
-- Writes the inbox notice. Returns the ledger id, or null when a cap stops it.
create or replace function public.reward_grant(p_uid uuid, p_kind text, p_amount integer, p_days integer, p_referral uuid,
                                               p_note text, p_by text, p_title text, p_body text)
returns uuid language plpgsql security definer set search_path = public as $$
declare rid uuid; life integer; today_n integer;
begin
  if p_uid is null or p_amount is null or p_amount <= 0 or p_days is null or p_days <= 0 then return null; end if;
  if p_kind <> 'admin_grant' then
    select count(*) into life from reward_ledger where user_id = p_uid and kind <> 'admin_grant' and not revoked;
    if life >= reward_num('reward_max_lifetime', 20) then return null; end if;
    select count(*) into today_n from reward_ledger where user_id = p_uid and kind <> 'admin_grant' and created_at > now() - interval '24 hours';
    if today_n >= reward_num('reward_max_new_per_day', 5) then return null; end if;
  end if;
  insert into reward_ledger(user_id, kind, amount_per_day, days, expires_at, referral_id, note, created_by)
  values (p_uid, p_kind, least(p_amount, 100000000), least(p_days, 3650), now() + make_interval(days => least(p_days, 3650)), p_referral,
          left(p_note, 300), coalesce(p_by, 'system'))
  returning id into rid;
  insert into user_inbox(user_id, kind, reward_id, title, body)
  values (p_uid, case when p_kind = 'admin_grant' then 'reward_grant' else 'reward_earned' end, rid, left(coalesce(p_title, ''), 200), left(coalesce(p_body, ''), 4000));
  return rid;
end $$;
revoke all on function public.reward_grant(uuid, text, integer, integer, uuid, text, text, text, text) from public, anon, authenticated;
grant execute on function public.reward_grant(uuid, text, integer, integer, uuid, text, text, text, text) to service_role;

create or replace function public.reward_fmt(p integer) returns text language sql immutable as $$
  select case when p >= 1000000 then trim(to_char(p / 1000000.0, 'FM999990.0')) || 'M'
              when p >= 1000 then (p / 1000)::text || 'k' else p::text end
$$;

-- Same phone? true when the two accounts were ever seen on one install.
create or replace function public.reward_same_device(a uuid, b uuid, p_device text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from user_devices x join user_devices y on x.device_id = y.device_id where x.user_id = a and y.user_id = b)
      or (p_device is not null and exists (select 1 from user_devices where user_id = a and device_id = p_device))
$$;
revoke all on function public.reward_same_device(uuid, uuid, text) from public, anon, authenticated;

-- ---------- invite code / link for the signed-in user ----------
create or replace function public.my_invite() returns jsonb
language plpgsql security definer set search_path = public as $$
declare c text; tries int := 0; alpha text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
begin
  if auth.uid() is null then return null; end if;
  select rc.code into c from referral_codes rc where rc.user_id = auth.uid();
  while c is null and tries < 8 loop
    tries := tries + 1;
    c := (select string_agg(substr(alpha, 1 + floor(random() * 32)::int, 1), '') from generate_series(1, 7));
    begin
      insert into referral_codes(user_id, code) values (auth.uid(), c);
    exception when unique_violation then
      select rc.code into c from referral_codes rc where rc.user_id = auth.uid();   -- a race on our own row, or a code clash (retry)
    end;
  end loop;
  return jsonb_build_object('code', c, 'link', 'https://telesia.site/download?ref=' || c,
    'tokens', reward_num('reward_referral_tokens', 30000), 'days', reward_num('reward_referral_days', 7));
end $$;
revoke all on function public.my_invite() from public, anon;
grant execute on function public.my_invite() to authenticated;

-- ---------- claim: a new account joined through someone's invite (link or typed code) ----------
-- Returns {ok, reason}. Refusals are recorded (and suspicious ones flagged) but never tell the caller who the inviter is.
create or replace function public.claim_referral(p_code text, p_source text default 'link', p_device text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); inviter uuid; created timestamptz; rid uuid; why text; refused int; amt int; d int; lid uuid;
        v_code text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
        src text := case when p_source in ('link', 'code', 'hire_link') then p_source else 'link' end;
        dev text := case when p_device ~ '^[A-Za-z0-9_-]{6,64}$' then p_device end;
begin
  if me is null then return jsonb_build_object('ok', false, 'reason', 'auth'); end if;
  if v_code = '' then return jsonb_build_object('ok', false, 'reason', 'no_code'); end if;
  select count(*) into refused from referrals where invitee_id = me and kind = 'invite';
  if refused >= 5 then return jsonb_build_object('ok', false, 'reason', 'too_many'); end if;
  select rc.user_id into inviter from referral_codes rc where rc.code = v_code limit 1;
  if inviter is null then return jsonb_build_object('ok', false, 'reason', 'unknown_code'); end if;
  if exists (select 1 from referrals where invitee_id = me and kind = 'invite' and status = 'rewarded') then
    return jsonb_build_object('ok', false, 'reason', 'already');
  end if;
  select u.created_at into created from auth.users u where u.id = me;
  why := case
    when (select value from ai_settings where key = 'reward_enabled') = 'false'::jsonb then 'disabled'
    when inviter = me then 'self'
    when created < now() - make_interval(days => reward_num('reward_invite_window_days', 7)::int) then 'not_new'
    when reward_same_device(inviter, me, dev) then 'same_device'
    when dev is not null and exists (select 1 from referrals where device_id = dev and kind = 'invite' and status = 'rewarded') then 'device_used'
    else null end;
  insert into referrals(kind, inviter_id, invitee_id, source, ref_code, device_id, status, reason)
  values ('invite', inviter, me, src, v_code, dev, case when why is null then 'rewarded' else 'refused' end, why)
  returning id into rid;
  if why in ('self', 'same_device', 'device_used') then
    perform flag_user(inviter, 'reward_farming', 'medium', 'rewards', 'Invite claim refused: ' || why, jsonb_build_object('invitee', me, 'device', dev));
  end if;
  if why is not null then return jsonb_build_object('ok', false, 'reason', why); end if;
  amt := reward_num('reward_referral_tokens', 30000)::int; d := reward_num('reward_referral_days', 7)::int;
  lid := reward_grant(inviter, 'referral', amt, d, rid, null, 'system', 'Someone joined with your invite',
           '+' || reward_fmt(amt) || ' extra a day for ' || d || ' days, on top of your daily allowance. Thanks for sharing Telesia!');
  if lid is null then
    update referrals set status = 'refused', reason = 'cap' where id = rid;
    return jsonb_build_object('ok', true, 'reason', 'counted');   -- the newcomer is fine; the inviter hit a cap
  end if;
  -- Many sign-ups through one inviter in a day looks like farming.
  if (select count(*) from referrals where inviter_id = inviter and kind = 'invite' and created_at > now() - interval '24 hours') >= 5 then
    perform flag_user(inviter, 'reward_farming', 'low', 'rewards', '5+ invite sign-ups in 24 h', '{}'::jsonb);
  end if;
  return jsonb_build_object('ok', true, 'reason', null);
end $$;
revoke all on function public.claim_referral(text, text, text) from public, anon;
grant execute on function public.claim_referral(text, text, text) to authenticated;

-- ---------- creator reward: first hire of a published listing by an account (once per creator) ----------
create or replace function public.reward_creator_for_hire(p_bot uuid, p_hirer uuid, p_source text, p_device text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare author uuid; pub boolean; bname text; rid uuid; why text; amt int; d int; lid uuid;
begin
  select author_id, published, name into author, pub, bname from bot_store where id = p_bot;
  if author is null then return jsonb_build_object('ok', false, 'reason', 'no_bot'); end if;
  why := case
    when (select value from ai_settings where key = 'reward_enabled') = 'false'::jsonb then 'disabled'
    when not pub then 'unlisted'
    when author = p_hirer then 'own_bot'
    when exists (select 1 from referrals where kind = 'hire' and inviter_id = author and invitee_id = p_hirer and status = 'rewarded') then 'already'
    when reward_same_device(author, p_hirer, p_device) then 'same_device'
    else null end;
  if why in ('unlisted', 'own_bot', 'disabled') then return jsonb_build_object('ok', false, 'reason', why); end if;
  if why = 'already' then return jsonb_build_object('ok', false, 'reason', why); end if;
  insert into referrals(kind, inviter_id, invitee_id, source, bot_store_id, device_id, status, reason)
  values ('hire', author, p_hirer, coalesce(p_source, 'store'), p_bot, p_device, case when why is null then 'rewarded' else 'refused' end, why)
  returning id into rid;
  if why = 'same_device' then
    perform flag_user(author, 'reward_farming', 'medium', 'rewards', 'Hire of own bot from the same phone', jsonb_build_object('hirer', p_hirer));
    return jsonb_build_object('ok', false, 'reason', why);
  end if;
  amt := reward_num('reward_creator_tokens', 30000)::int; d := reward_num('reward_creator_days', 7)::int;
  lid := reward_grant(author, 'creator', amt, d, rid, left(bname, 60), 'system', 'Someone hired ' || left(bname, 60),
           '+' || reward_fmt(amt) || ' extra a day for ' || d || ' days, on top of your daily allowance. Keep building!');
  if lid is null then update referrals set status = 'refused', reason = 'cap' where id = rid; end if;
  if (select count(*) from referrals where inviter_id = author and kind = 'hire' and created_at > now() - interval '24 hours') >= 10 then
    perform flag_user(author, 'reward_farming', 'low', 'rewards', '10+ hires of their bots in 24 h', '{}'::jsonb);
  end if;
  return jsonb_build_object('ok', lid is not null, 'reason', case when lid is null then 'cap' end);
end $$;
revoke all on function public.reward_creator_for_hire(uuid, uuid, text, text) from public, anon, authenticated;

-- bot_store_hired keeps its signature (old apps); new apps pass where the hire came from and the install id.
create or replace function public.bot_store_hired(bot uuid, p_source text default 'store', p_device text default null) returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if auth.uid() is null then return 0; end if;
  insert into bot_store_hires (bot_id, user_id) values (bot, auth.uid()) on conflict do nothing;
  if found then
    update bot_store set hires = hires + 1 where id = bot;
    begin
      perform reward_creator_for_hire(bot, auth.uid(),
        case when p_source in ('store', 'link', 'code') then p_source else 'store' end,
        case when p_device ~ '^[A-Za-z0-9_-]{6,64}$' then p_device end);
    exception when others then null;   -- a reward problem never breaks a hire
    end;
  end if;
  select hires into n from bot_store where id = bot;
  return coalesce(n, 0);
end $$;
drop function if exists public.bot_store_hired(uuid);
revoke all on function public.bot_store_hired(uuid, text, text) from public, anon;
grant execute on function public.bot_store_hired(uuid, text, text) to authenticated;

-- ---------- effective cap (ai-chat) ----------
-- cap = (per-user override or daily_cap_tokens) + min(earned bonuses, reward_max_bonus_per_day) + admin grants.
create or replace function public.ai_user_cap(p_uid uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  with s as (select reward_num('daily_cap_tokens', 200000)::bigint as dflt, reward_num('reward_max_bonus_per_day', 150000)::bigint as maxb),
  o as (select daily_cap_tokens from ai_user_limits where user_id = p_uid),
  a as (select kind, amount_per_day from reward_ledger where user_id = p_uid and not revoked and starts_at <= now() and expires_at > now()),
  t as (select coalesce(sum(amount_per_day) filter (where kind <> 'admin_grant'), 0)::bigint as earned,
               coalesce(sum(amount_per_day) filter (where kind = 'admin_grant'), 0)::bigint as granted,
               count(*) filter (where kind = 'referral') as n_ref, count(*) filter (where kind = 'creator') as n_cre,
               count(*) filter (where kind = 'admin_grant') as n_adm from a)
  select jsonb_build_object(
    'base', coalesce((select daily_cap_tokens from o), s.dflt), 'default_cap', s.dflt, 'override', (select daily_cap_tokens from o),
    'earned', t.earned, 'granted', t.granted, 'max_bonus', s.maxb,
    'bonus', least(t.earned, s.maxb) + t.granted,
    'cap', coalesce((select daily_cap_tokens from o), s.dflt) + least(t.earned, s.maxb) + t.granted,
    'active', jsonb_build_object('referral', t.n_ref, 'creator', t.n_cre, 'admin_grant', t.n_adm))
  from s, t
$$;
revoke all on function public.ai_user_cap(uuid) from public, anon, authenticated;
grant execute on function public.ai_user_cap(uuid) to service_role;

-- ---------- what the app shows (Today / Settings) ----------
create or replace function public.my_rewards() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid(); cap jsonb; inv text;
begin
  if me is null then return null; end if;
  cap := ai_user_cap(me);
  select code into inv from referral_codes where user_id = me;
  return cap || jsonb_build_object(
    'invite_code', inv, 'invite_link', case when inv is null then null else 'https://telesia.site/download?ref=' || inv end,
    'enabled', coalesce((select value from ai_settings where key = 'reward_enabled'), 'true'::jsonb) <> 'false'::jsonb,
    'referral_tokens', reward_num('reward_referral_tokens', 30000), 'referral_days', reward_num('reward_referral_days', 7),
    'creator_tokens', reward_num('reward_creator_tokens', 30000), 'creator_days', reward_num('reward_creator_days', 7),
    'joined', (select count(*) from referrals where inviter_id = me and kind = 'invite' and status = 'rewarded'),
    'hires', (select count(*) from referrals where inviter_id = me and kind = 'hire' and status = 'rewarded'),
    'rewards', coalesce((select jsonb_agg(jsonb_build_object('kind', kind, 'amount', amount_per_day, 'expires_at', expires_at, 'note',
                          case when kind = 'admin_grant' then note end) order by expires_at)
                        from reward_ledger where user_id = me and not revoked and starts_at <= now() and expires_at > now()), '[]'::jsonb));
end $$;
revoke all on function public.my_rewards() from public, anon;
grant execute on function public.my_rewards() to authenticated;
