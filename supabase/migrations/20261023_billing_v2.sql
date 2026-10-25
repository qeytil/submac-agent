-- SubMac billing (clean rebuild, PLAN.md PART 2 + Contract B). Volume billing: no coins, no model multipliers.
-- One migration: removes the whole coin system (tables, functions, settings, cron) and creates the new one.
-- No users are on billing, so nothing is converted. Safe to run twice.
--
--   plans           catalogue (Free, Weekly, Monthly, optional Monthly Plus, Pay as you go). Editable: billing_plan_update().
--   subscriptions   one bought package: a period with a daily amount and a total. Packages queue after the running one.
--   token_balances  pay-as-you-go tokens, each with its own expiry (12 months).
--   usage_ledger    append-only token movements: +grant, -charge, -reverse, +/-adjust. billing_ledger_check() proves the
--                   sums equal what is left.
--   usage_daily     per EAT day counters (free / each subscription; bot share).
--   usage_requests  idempotency registry for usage_charge (one row per request_id, stores the answer).
--   charge_queue    usage charges ai-chat could not write at once; billing_charge_retry_drain() (cron) retries them.
--   payments        money in (idempotency key, double-tap fingerprint, unique (provider, provider_ref)).
--
-- Contract B (ai-chat, server only):
--   public.usage_gate(user_id, source)                                         -> allow/deny + today/total left + resets_at + plan + reply_cap
--   public.usage_charge(user_id, tokens_in, tokens_out, source, request_id)    -> idempotent by request_id
--   source 'live': tokens_in = SECONDS of the call segment; charged at billing_live_tokens_per_minute (40k).
--   source 'bot', 'bot-cloud', 'background', 'office' = bot lane: at most billing_bot_share (50%) of each daily amount.
--   Spending order: free daily -> packages (soonest-ending first, within each daily amount) -> PAYG (soonest-expiring first).
--   Tokens are raw input + output (no cached-input discount). Day boundary: midnight Africa/Mogadishu (EAT).
--
-- Switch: billing_enabled can only be true when billing_provider_env = 'live' (blocked while Sifalo is staging).
-- billing_testers (uuid list) get billing in staging for end-to-end tests.

create schema if not exists billing;
revoke all on schema billing from public, anon, authenticated;
grant usage on schema billing to service_role;

-- ============================================================================ 0. remove the coin system
do $$ begin
  if to_regnamespace('cron') is not null then
    begin
      perform cron.unschedule(jobid) from cron.job where jobname in ('billing-reconcile-usage', 'billing-consume-retry');
    exception when others then null;
    end;
  end if;
end $$;

do $$ declare f text; begin
  for f in select p.oid::regprocedure::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where (n.nspname = 'billing' and p.proname in ('today','month_start','multiplier_for','wallet','add_coins','free_limits',
                    'entitlements','grant_pass','settle_passes','buy_with_coins','maybe_auto_exchange','consume','live_charge',
                    'mark_paid','reverse','payment_key','purchases_provider_ref','purchase_replay'))
              or (n.nspname = 'public' and p.proname in ('billing_summary','billing_history','billing_exchange','billing_buy_pass',
                    'billing_set_auto_exchange','billing_precheck','billing_consume','billing_live_charge','billing_multipliers',
                    'billing_create_purchase','billing_create_purchase_v2','billing_create_purchase_v3','billing_set_checkout_key',
                    'billing_find_purchase','billing_find_purchase_v2','billing_find_purchase_v3','billing_mark_paid','billing_mark_paid_v2',
                    'billing_mark_failed','billing_mark_failed_v2','billing_touch_purchase','billing_pending_purchases',
                    'billing_pending_purchases_v2','billing_reverse','billing_grant_admin','billing_save_checkout_response',
                    'billing_note_pending_ref','billing_expire_purchase_v2','billing_consume_enqueue','billing_consume_retry_drain',
                    'billing_live_reconcile','billing_reconcile_usage')) loop
    execute format('drop function if exists %s cascade', f);
  end loop;
end $$;

drop table if exists billing.consume_retry;
drop table if exists billing.live_charges;
drop table if exists billing.consumption;
drop table if exists billing.free_usage;
drop table if exists billing.daily_spend;
drop table if exists billing.referral_rewards;
drop table if exists billing.first_bonus;
drop table if exists billing.coin_transactions;
drop table if exists billing.token_grants;
drop table if exists billing.wallets;
drop table if exists billing.purchases;
drop table if exists billing.model_multipliers;
drop table if exists billing.products;

delete from public.ai_settings where key in (
  'billing_coin_usd', 'billing_first_topup_bonus_max', 'billing_referral_coins', 'billing_referral_max_per_inviter',
  'billing_auto_exchange_threshold', 'billing_rollover_pct', 'billing_rollover_window_days', 'billing_bg_pass_share',
  'billing_free_daily_tokens', 'billing_free_monthly_tokens', 'billing_free_live_minutes_month', 'billing_legacy_tokens_per_coin');


-- ---------------------------------------------------------------- settings (insert only; existing values kept)
insert into public.ai_settings(key, value) values
  ('billing_enabled', 'false'::jsonb),
  ('billing_bot_share', '0.5'::jsonb),                  -- bots/background: at most 50% of a daily amount (free and packages)
  ('billing_live_tokens_per_minute', '40000'::jsonb),   -- Live voice price per minute (owner sets; old plan 40k/min)
  ('billing_reply_cap_tokens', '8192'::jsonb),          -- largest reply cap usage_gate hands out
  ('billing_tokens_per_reply', '3700'::jsonb),         -- UI: 1M ~ 270 replies
  ('billing_provider_env', '"staging"'::jsonb),         -- Sifalo mode; billing_enabled stays off until this is "live"
  ('billing_testers', '[]'::jsonb),                     -- user ids that get billing while Sifalo is staging (E2E tests)
  ('billing_checkout_per_minute', '10'::jsonb),         -- checkout rate limit per user
  ('billing_max_pending_per_hour', '10'::jsonb),
  ('billing_doubletap_seconds', '20'::jsonb),           -- same checkout within 20 s = the same payment
  ('billing_retry_max_age_hours', '72'::jsonb)          -- charge_queue: older than this = dropped unbilled
on conflict (key) do nothing;

-- helpers
create or replace function billing.num(p_key text, p_default numeric) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce((select case when jsonb_typeof(value) = 'number' then (value)::text::numeric
                               when jsonb_typeof(value) = 'string' and (value #>> '{}') ~ '^-?[0-9.]+$' then (value #>> '{}')::numeric end
                   from public.ai_settings where key = p_key), p_default)
$$;

create or replace function billing.flag(p_key text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select value = 'true'::jsonb or value = '"true"'::jsonb from public.ai_settings where key = p_key), false)
$$;

create or replace function billing.provider_live() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select value #>> '{}' from public.ai_settings where key = 'billing_provider_env'), 'staging') = 'live'
$$;

-- Billing for everyone: billing_enabled and Sifalo live.
create or replace function billing.enabled() returns boolean
language sql stable security definer set search_path = public as $$
  select billing.flag('billing_enabled') and billing.provider_live()
$$;

create or replace function billing.is_tester(p_uid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select p_uid is not null and exists (select 1 from public.ai_settings s, jsonb_array_elements_text(
           case when jsonb_typeof(s.value) = 'array' then s.value else '[]'::jsonb end) x
         where s.key = 'billing_testers' and x = p_uid::text)
$$;

-- Billing for this user: on for everyone, or a tester (staging end-to-end tests).
create or replace function billing.on_for(p_uid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select billing.enabled() or billing.is_tester(p_uid)
$$;

-- billing_enabled cannot be turned on while Sifalo is staging, and Sifalo cannot go back to staging while it is on.
create or replace function billing.guard_switch() returns trigger
language plpgsql security definer set search_path = public as $$
declare on_ boolean; env text;
begin
  if new.key not in ('billing_enabled', 'billing_provider_env') then return new; end if;
  -- insert ... on conflict: the existing row decides (an update through do update fires this trigger again)
  if tg_op = 'INSERT' and exists (select 1 from public.ai_settings where key = new.key) then return new; end if;
  on_ := case when new.key = 'billing_enabled' then (new.value = 'true'::jsonb or new.value = '"true"'::jsonb) else billing.flag('billing_enabled') end;
  env := case when new.key = 'billing_provider_env' then new.value #>> '{}'
              else coalesce((select value #>> '{}' from public.ai_settings where key = 'billing_provider_env'), 'staging') end;
  if on_ and env is distinct from 'live' then
    raise exception 'billing_enabled needs billing_provider_env = live (Sifalo is %)', coalesce(env, 'staging')
      using errcode = 'check_violation';
  end if;
  return new;
end $$;
drop trigger if exists billing_guard_switch on public.ai_settings;
create trigger billing_guard_switch before insert or update on public.ai_settings
  for each row execute function billing.guard_switch();

-- The billing clock. now() unless the session sets billing.test_now (tests only; PostgREST clients cannot set it and
-- every function that reads it is service-role only or reads the caller's own data).
create or replace function billing.clock() returns timestamptz
language sql stable set search_path = pg_catalog as $$
  select coalesce(nullif(current_setting('billing.test_now', true), '')::timestamptz, now())
$$;

-- EAT calendar day of an instant, and the instant the next EAT day starts.
create or replace function billing.eat_day(p_at timestamptz) returns date
language sql immutable set search_path = pg_catalog as $$ select (p_at at time zone 'Africa/Mogadishu')::date $$;

create or replace function billing.eat_midnight_after(p_at timestamptz) returns timestamptz
language sql immutable set search_path = pg_catalog as $$
  select ((p_at at time zone 'Africa/Mogadishu')::date + 1)::timestamp at time zone 'Africa/Mogadishu'
$$;

create or replace function billing.is_bot(p_source text) returns boolean
language sql immutable set search_path = pg_catalog as $$
  select lower(coalesce(p_source, '')) in ('bot', 'bot-cloud', 'bot_cloud', 'background', 'office')
$$;

-- ---------------------------------------------------------------- catalogue
create table if not exists billing.plans (
  id text primary key check (id ~ '^[a-z][a-z0-9_]{1,31}$'),
  kind text not null check (kind in ('free','package','payg')),
  tier text not null check (tier in ('free','weekly','monthly','payg')),  -- what x-submac-plan says
  name text not null,
  price_usd numeric(10,2) not null default 0 check (price_usd >= 0),   -- package: the price; payg: price per unit_tokens
  total_tokens bigint,                       -- package: total for the period; free: monthly cap
  daily_tokens bigint,                       -- package / free: daily amount
  validity interval not null,                -- package period; payg token lifetime; free: '1 month' (informational)
  unit_tokens bigint,                        -- payg: price unit (1M)
  min_tokens bigint,                         -- payg: smallest purchase
  max_tokens bigint,                         -- payg: largest purchase
  step_tokens bigint,                        -- payg: slider step
  presets bigint[],                          -- payg: suggested amounts
  active boolean not null default true,
  sort int not null default 100,
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (kind <> 'package' or (total_tokens > 0 and daily_tokens > 0 and price_usd > 0)),
  check (kind <> 'payg' or (unit_tokens > 0 and min_tokens > 0 and max_tokens >= min_tokens and step_tokens > 0 and price_usd > 0)),
  check (kind <> 'free' or (daily_tokens >= 0 and total_tokens >= 0))
);

insert into billing.plans(id, kind, tier, name, price_usd, total_tokens, daily_tokens, validity, unit_tokens, min_tokens, max_tokens,
                          step_tokens, presets, active, sort, note) values
  ('free', 'free', 'free', 'Free', 0, 1000000, 60000, interval '1 month', null, null, null, null, null, true, 10, '60k a day, 1M a month'),
  ('weekly', 'package', 'weekly', 'Weekly', 1.25, 700000, 200000, interval '7 days', null, null, null, null, null, true, 20, null),
  ('monthly', 'package', 'monthly', 'Monthly', 4.99, 3000000, 250000, interval '30 days', null, null, null, null, null, true, 30, null),
  ('monthly_plus', 'package', 'monthly', 'Monthly Plus', 9.99, 6000000, 500000, interval '30 days', null, null, null, null, null, false, 40,
   'Optional, off'),
  ('payg', 'payg', 'payg', 'Pay as you go', 2.00, null, null, interval '12 months', 1000000, 1000000, 50000000, 100000,
   array[1000000, 3000000, 5000000, 10000000]::bigint[], true, 50, '$2.00 per 1M, valid 12 months')
on conflict (id) do nothing;

-- ---------------------------------------------------------------- payments (money in)
create table if not exists billing.payments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,                     -- no FK: money records outlive account deletion
  plan_id text not null references billing.plans(id),
  tokens bigint not null check (tokens > 0), -- what this payment buys (package total or PAYG amount)
  amount_usd numeric(10,2) not null check (amount_usd > 0),
  currency text not null default 'USD',
  status text not null default 'pending' check (status in ('pending','paid','failed','reversed')),
  provider text not null default 'sifalo' check (provider ~ '^[a-z][a-z0-9_]{1,31}$'),
  provider_ref text,                         -- the provider's payment id (Sifalo sid); credit once per (provider, ref)
  checkout_key text,
  pending_ref text,                          -- ref of our own server-side wallet charge
  payment_type text,
  device_id text,
  idempotency_key text,
  fingerprint text,
  client_response jsonb,
  verify_payload jsonb,
  result text,
  subscription_id uuid,
  balance_id uuid,
  created_at timestamptz not null default now(),
  paid_at timestamptz,
  reversed_at timestamptz,
  last_checked_at timestamptz
);
create unique index if not exists payments_provider_ref on billing.payments (provider, provider_ref) where provider_ref is not null;
create unique index if not exists payments_user_idem on billing.payments (user_id, idempotency_key) where idempotency_key is not null;
create index if not exists payments_user on billing.payments (user_id, created_at desc);
create index if not exists payments_pending on billing.payments (created_at) where status = 'pending';
create index if not exists payments_key on billing.payments (checkout_key) where checkout_key is not null;
create index if not exists payments_user_fp on billing.payments (user_id, fingerprint, created_at) where fingerprint is not null;

-- ---------------------------------------------------------------- balances
create table if not exists billing.subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  plan_id text not null references billing.plans(id),
  payment_id uuid references billing.payments(id),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  daily_amount bigint not null check (daily_amount > 0),
  total_amount bigint not null check (total_amount > 0),
  total_left bigint not null check (total_left >= 0),
  status text not null default 'active' check (status in ('active','revoked')),
  source text not null default 'purchase' check (source in ('purchase','admin')),
  reminded_at timestamptz,                   -- renewal reminder sent (the day before it ends)
  created_at timestamptz not null default now(),
  check (ends_at > starts_at)
);
create index if not exists subscriptions_user on billing.subscriptions (user_id, ends_at) where status = 'active';

create table if not exists billing.token_balances (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  amount bigint not null check (amount > 0),         -- what was added
  left_tokens bigint not null check (left_tokens >= 0),
  expires_at timestamptz not null,
  source text not null check (source in ('payg','admin')),
  payment_id uuid references billing.payments(id),
  status text not null default 'active' check (status in ('active','revoked')),
  note text,
  created_at timestamptz not null default now()
);
create index if not exists token_balances_user on billing.token_balances (user_id, expires_at) where status = 'active' and left_tokens > 0;

create table if not exists billing.usage_ledger (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  user_id uuid not null,
  kind text not null check (kind in ('grant','charge','reverse','adjust')),
  ref text not null,                          -- request_id for charges, payment id / admin note for the rest
  bucket text not null check (bucket in ('free','package','payg','unpaid')),
  subscription_id uuid references billing.subscriptions(id),
  balance_id uuid references billing.token_balances(id),
  tokens bigint not null,                     -- signed: + adds, - spends
  source text,
  day date,                                   -- EAT day (charges)
  note text
);
create index if not exists usage_ledger_user on billing.usage_ledger (user_id, created_at desc);
create index if not exists usage_ledger_sub on billing.usage_ledger (subscription_id) where subscription_id is not null;
create index if not exists usage_ledger_bal on billing.usage_ledger (balance_id) where balance_id is not null;

create table if not exists billing.usage_daily (
  user_id uuid not null,
  day date not null,                          -- EAT day
  bucket text not null,                       -- 'free' or a subscription id
  tokens bigint not null default 0,
  bot_tokens bigint not null default 0,
  primary key (user_id, day, bucket)
);

create table if not exists billing.usage_requests (
  request_id text primary key,
  user_id uuid not null,
  result jsonb not null,
  created_at timestamptz not null default now()
);

create table if not exists billing.ledger_outbox (       -- finance.ledger fallback, posted by billing_sync_ledger()
  id bigint generated always as identity primary key,
  entry jsonb not null,
  source_ref text not null unique,
  error text,
  attempts int not null default 0,
  posted_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists billing.charge_queue (        -- usage charges ai-chat could not write at once
  request_id text primary key,
  user_id uuid not null,
  tokens_in bigint not null check (tokens_in >= 0),
  tokens_out bigint not null default 0 check (tokens_out >= 0),
  source text,
  status text not null default 'pending' check (status in ('pending','done','expired')),
  attempts int not null default 0,
  next_try_at timestamptz not null default now(),
  error text,
  result jsonb,
  created_at timestamptz not null default now(),
  done_at timestamptz
);
create index if not exists charge_queue_due on billing.charge_queue (next_try_at) where status = 'pending';

create or replace function billing.block_changes() returns trigger language plpgsql set search_path = pg_catalog as $$
begin raise exception 'billing.% is append-only', tg_table_name; end $$;
drop trigger if exists usage_ledger_append_only on billing.usage_ledger;
create trigger usage_ledger_append_only before update or delete on billing.usage_ledger for each row execute function billing.block_changes();
drop trigger if exists usage_requests_append_only on billing.usage_requests;
create trigger usage_requests_append_only before update or delete on billing.usage_requests for each row execute function billing.block_changes();

do $$ declare t text; begin
  for t in select tablename from pg_tables where schemaname = 'billing'
           and tablename in ('plans','payments','subscriptions','token_balances','usage_ledger','usage_daily','usage_requests','ledger_outbox',
                             'charge_queue') loop
    execute format('alter table billing.%I enable row level security', t);
    execute format('revoke all on billing.%I from public, anon, authenticated', t);
    execute format('grant all on billing.%I to service_role', t);
  end loop;
end $$;

-- finance.ledger through the finance dashboard's API; outbox on failure
create or replace function billing.post_ledger(p_entry jsonb) returns void
language plpgsql security definer set search_path = billing, public as $$
declare ref text := p_entry->>'source_ref';
begin
  begin
    perform finance.ledger_add_row(p_entry || jsonb_build_object('product', 'agent', 'created_by', 'billing'));
  exception when unique_violation then
    null;
  when others then
    insert into billing.ledger_outbox(entry, source_ref, error, attempts) values (p_entry, ref, left(sqlerrm, 300), 1)
    on conflict (source_ref) do update set error = excluded.error, attempts = billing.ledger_outbox.attempts + 1;
  end;
end $$;

-- ============================================================================ position (what a user can spend now)
-- One JSON for the gate, the charge answer and the app:
--   enabled, plan, today_left, total_left, resets_at, bot_today_left, free{...}, packages[...], payg{left, next_expiry}
create or replace function billing.position(p_uid uuid, p_source text default 'chat') returns jsonb
language plpgsql stable security definer set search_path = billing, public as $$
declare
  t timestamptz := billing.clock();
  d date := billing.eat_day(t);
  m date := date_trunc('month', d)::date;
  share numeric := least(greatest(billing.num('billing_bot_share', 0.5), 0), 1);
  bot boolean := billing.is_bot(p_source);
  fp billing.plans;
  f_used bigint := 0; f_bot bigint := 0; f_month bigint := 0;
  f_left bigint := 0; f_month_left bigint := 0; f_bot_left bigint := 0;
  pk jsonb := '[]'::jsonb; pk_today bigint := 0; pk_bot bigint := 0; pk_total bigint := 0; top_tier text;
  py_left bigint := 0; py_next timestamptz;
  s record; u_t bigint; u_b bigint; l bigint; lb bigint;
begin
  select * into fp from billing.plans where id = 'free' and kind = 'free' and active;
  if fp.id is not null then
    select coalesce(sum(tokens) filter (where day = d), 0), coalesce(sum(bot_tokens) filter (where day = d), 0), coalesce(sum(tokens), 0)
      into f_used, f_bot, f_month
      from billing.usage_daily where user_id = p_uid and bucket = 'free' and day >= m and day <= d;
    f_month_left := greatest(0, coalesce(fp.total_tokens, 0) - f_month);
    f_left := greatest(0, least(coalesce(fp.daily_tokens, 0) - f_used, f_month_left));
    f_bot_left := greatest(0, least(f_left, floor(coalesce(fp.daily_tokens, 0) * share)::bigint - f_bot));
  end if;

  for s in select x.*, p.tier from billing.subscriptions x join billing.plans p on p.id = x.plan_id
           where x.user_id = p_uid and x.status = 'active' and x.starts_at <= t and x.ends_at > t
           order by x.ends_at, x.created_at loop
    select coalesce(tokens, 0), coalesce(bot_tokens, 0) into u_t, u_b from billing.usage_daily where user_id = p_uid and day = d and bucket = s.id::text;
    u_t := coalesce(u_t, 0); u_b := coalesce(u_b, 0);
    l := greatest(0, least(s.daily_amount - u_t, s.total_left));
    lb := greatest(0, least(l, floor(s.daily_amount * share)::bigint - u_b));
    pk_today := pk_today + l; pk_bot := pk_bot + lb; pk_total := pk_total + s.total_left;
    top_tier := coalesce(top_tier, s.tier);
    pk := pk || jsonb_build_object('id', s.id, 'plan', s.plan_id, 'tier', s.tier, 'starts_at', s.starts_at, 'ends_at', s.ends_at,
      'daily_amount', s.daily_amount, 'today_used', u_t, 'today_left', l, 'total_amount', s.total_amount, 'total_left', s.total_left);
  end loop;

  select coalesce(sum(left_tokens), 0), min(expires_at) into py_left, py_next
    from billing.token_balances where user_id = p_uid and status = 'active' and left_tokens > 0 and expires_at > t;

  return jsonb_build_object(
    'enabled', billing.on_for(p_uid),
    'plan', coalesce(top_tier, case when py_left > 0 then 'payg' else 'free' end),
    'today_left', case when bot then f_bot_left + pk_bot + py_left else f_left + pk_today + py_left end,
    'total_left', pk_total + py_left + case when top_tier is null and py_left = 0 then f_month_left else 0 end,
    'paid_left', pk_total + py_left,
    'resets_at', billing.eat_midnight_after(t),
    'day', d,
    'bot', bot,
    'free', jsonb_build_object('daily', coalesce(fp.daily_tokens, 0), 'monthly', coalesce(fp.total_tokens, 0), 'today_used', f_used,
                               'today_left', f_left, 'month_used', f_month, 'month_left', f_month_left, 'bot_today_left', f_bot_left),
    'packages', pk,
    'package_today_left', pk_today,
    'payg', jsonb_build_object('left', py_left, 'next_expiry', py_next),
    'tokens_per_reply', billing.num('billing_tokens_per_reply', 3700)::bigint);
end $$;

-- ============================================================================ Contract B
-- Before the call. Never writes. Billing off -> allow with enabled=false (ai-chat keeps its own limits).
-- deny codes (Contract A): limit_daily (something is left overall, not today / not for bots), limit_total (nothing left),
-- no_plan (nothing to spend at all: no free plan, no package, no PAYG).
create or replace function public.usage_gate(p_user_id uuid, p_source text default 'chat') returns jsonb
language plpgsql stable security definer set search_path = billing, public as $$
declare p jsonb; today bigint; total bigint; cap bigint; code text; has_any boolean;
begin
  if p_user_id is null then
    return jsonb_build_object('allow', false, 'code', 'server', 'reason', 'bad_request');
  end if;
  if not billing.on_for(p_user_id) then
    return jsonb_build_object('allow', true, 'enabled', false, 'code', null, 'today_left', null, 'total_left', null,
      'resets_at', billing.eat_midnight_after(billing.clock()), 'plan', 'free', 'reply_cap', billing.num('billing_reply_cap_tokens', 8192)::bigint);
  end if;
  p := billing.position(p_user_id, p_source);
  today := (p->>'today_left')::bigint;
  total := (p->>'total_left')::bigint;
  has_any := exists (select 1 from billing.plans where id = 'free' and kind = 'free' and active and coalesce(daily_tokens, 0) > 0)
          or (p->>'paid_left')::bigint > 0
          or jsonb_array_length(p->'packages') > 0;
  if today > 0 then
    code := null;
  elsif not has_any then
    code := 'no_plan';
  elsif (p->>'paid_left')::bigint > 0 or ((p->'free'->>'month_left')::bigint > 0 and (p->>'plan') = 'free') then
    code := 'limit_daily';
  else
    code := 'limit_total';
  end if;
  cap := case when code is null then least(billing.num('billing_reply_cap_tokens', 8192)::bigint, today) else 0 end;
  return jsonb_build_object('allow', code is null, 'enabled', true, 'code', code,
    'reason', case when code = 'limit_daily' and (p->>'bot')::boolean and (p->>'paid_left')::bigint + (p->'free'->>'today_left')::bigint > 0
                   then 'bot_share' else code end,
    'today_left', today, 'total_left', total, 'resets_at', p->'resets_at', 'plan', p->'plan', 'reply_cap', cap,
    'source', p_source);
end $$;

-- After the call. Idempotent by request_id (same id -> same answer, nothing charged twice; another user's id -> refused).
-- The last request may overrun what was left: the overrun is logged as bucket 'unpaid' and never billed.
create or replace function public.usage_charge(p_user_id uuid, p_tokens_in bigint, p_tokens_out bigint, p_source text, p_request_id text)
returns jsonb language plpgsql security definer set search_path = billing, public as $$
declare
  t timestamptz := billing.clock();
  d date := billing.eat_day(t);
  m date := date_trunc('month', d)::date;
  share numeric := least(greatest(billing.num('billing_bot_share', 0.5), 0), 1);
  bot boolean := billing.is_bot(p_source);
  live boolean := lower(coalesce(p_source, '')) = 'live';
  rid text := nullif(btrim(coalesce(p_request_id, '')), '');
  prev billing.usage_requests;
  amount bigint; rem bigint; take bigint; f_take bigint := 0; pk_take bigint := 0; py_take bigint := 0;
  fp billing.plans; u_t bigint; u_b bigint; f_month bigint; cap bigint;
  s billing.subscriptions; b billing.token_balances;
  pos jsonb; res jsonb;
begin
  if p_user_id is null or rid is null or length(rid) > 200 or coalesce(p_tokens_in, 0) < 0 or coalesce(p_tokens_out, 0) < 0 then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;
  if not billing.on_for(p_user_id) then return jsonb_build_object('ok', true, 'enabled', false, 'charged', 0); end if;

  -- one charge per user at a time; the duplicate check runs under the lock so a racing retry sees the first answer
  perform pg_advisory_xact_lock(hashtext('billing.usage'), hashtext(p_user_id::text));
  select * into prev from billing.usage_requests where request_id = rid;
  if found then
    if prev.user_id <> p_user_id then return jsonb_build_object('ok', false, 'reason', 'request_id_conflict'); end if;
    return prev.result || jsonb_build_object('duplicate', true);
  end if;

  amount := case when live then ceil(coalesce(p_tokens_in, 0) * billing.num('billing_live_tokens_per_minute', 40000) / 60.0)::bigint
                 else coalesce(p_tokens_in, 0) + coalesce(p_tokens_out, 0) end;
  rem := amount;

  -- 1) free daily (and the free monthly cap)
  select * into fp from billing.plans where id = 'free' and kind = 'free' and active;
  if rem > 0 and fp.id is not null then
    select coalesce(sum(tokens) filter (where day = d), 0), coalesce(sum(bot_tokens) filter (where day = d), 0), coalesce(sum(tokens), 0)
      into u_t, u_b, f_month from billing.usage_daily where user_id = p_user_id and bucket = 'free' and day >= m and day <= d;
    cap := greatest(0, least(coalesce(fp.daily_tokens, 0) - u_t, coalesce(fp.total_tokens, 0) - f_month));
    if bot then cap := greatest(0, least(cap, floor(coalesce(fp.daily_tokens, 0) * share)::bigint - u_b)); end if;
    f_take := least(rem, cap);
    if f_take > 0 then
      insert into billing.usage_daily(user_id, day, bucket, tokens, bot_tokens) values (p_user_id, d, 'free', f_take, case when bot then f_take else 0 end)
      on conflict (user_id, day, bucket) do update set tokens = billing.usage_daily.tokens + excluded.tokens,
                                                       bot_tokens = billing.usage_daily.bot_tokens + excluded.bot_tokens;
      insert into billing.usage_ledger(user_id, kind, ref, bucket, tokens, source, day) values (p_user_id, 'charge', rid, 'free', -f_take, p_source, d);
      rem := rem - f_take;
    end if;
  end if;

  -- 2) packages, soonest-ending first, each within its daily amount (bots within their share)
  for s in select * from billing.subscriptions where user_id = p_user_id and status = 'active' and starts_at <= t and ends_at > t and total_left > 0
           order by ends_at, created_at for update loop
    exit when rem <= 0;
    select coalesce(tokens, 0), coalesce(bot_tokens, 0) into u_t, u_b from billing.usage_daily where user_id = p_user_id and day = d and bucket = s.id::text;
    u_t := coalesce(u_t, 0); u_b := coalesce(u_b, 0);
    cap := greatest(0, least(s.daily_amount - u_t, s.total_left));
    if bot then cap := greatest(0, least(cap, floor(s.daily_amount * share)::bigint - u_b)); end if;
    take := least(rem, cap);
    continue when take <= 0;
    update billing.subscriptions set total_left = total_left - take where id = s.id;
    insert into billing.usage_daily(user_id, day, bucket, tokens, bot_tokens) values (p_user_id, d, s.id::text, take, case when bot then take else 0 end)
    on conflict (user_id, day, bucket) do update set tokens = billing.usage_daily.tokens + excluded.tokens,
                                                     bot_tokens = billing.usage_daily.bot_tokens + excluded.bot_tokens;
    insert into billing.usage_ledger(user_id, kind, ref, bucket, subscription_id, tokens, source, day)
    values (p_user_id, 'charge', rid, 'package', s.id, -take, p_source, d);
    pk_take := pk_take + take; rem := rem - take;
  end loop;

  -- 3) pay-as-you-go, soonest-expiring first
  for b in select * from billing.token_balances where user_id = p_user_id and status = 'active' and left_tokens > 0 and expires_at > t
           order by expires_at, created_at for update loop
    exit when rem <= 0;
    take := least(rem, b.left_tokens);
    update billing.token_balances set left_tokens = left_tokens - take where id = b.id;
    insert into billing.usage_ledger(user_id, kind, ref, bucket, balance_id, tokens, source, day)
    values (p_user_id, 'charge', rid, 'payg', b.id, -take, p_source, d);
    py_take := py_take + take; rem := rem - take;
  end loop;

  if rem > 0 then
    insert into billing.usage_ledger(user_id, kind, ref, bucket, tokens, source, day, note)
    values (p_user_id, 'charge', rid, 'unpaid', -rem, p_source, d, 'overrun: nothing left to charge');
  end if;

  pos := billing.position(p_user_id, p_source);
  res := jsonb_build_object('ok', true, 'enabled', true, 'request_id', rid, 'charged', amount - rem, 'tokens', amount,
    'free', f_take, 'package', pk_take, 'payg', py_take, 'unpaid', rem,
    'today_left', pos->'today_left', 'total_left', pos->'total_left', 'resets_at', pos->'resets_at', 'plan', pos->'plan');
  insert into billing.usage_requests(request_id, user_id, result) values (rid, p_user_id, res);
  return res || jsonb_build_object('duplicate', false);
end $$;

-- ============================================================================ crediting
-- Adds what a plan buys. Packages queue after the user's latest active package (no overlap, so daily amounts never
-- stack); PAYG tokens expire validity after the purchase. Writes the ledger grant row. Returns {subscription_id|balance_id}.
create or replace function billing.credit(p_uid uuid, p_plan text, p_tokens bigint, p_payment uuid, p_source text, p_ref text)
returns jsonb language plpgsql security definer set search_path = billing, public as $$
declare pl billing.plans; t timestamptz := billing.clock(); st timestamptz; sid uuid; bid uuid;
begin
  select * into pl from billing.plans where id = p_plan;
  if pl.id is null or pl.kind = 'free' then
    raise exception 'billing.credit: % is not for sale', p_plan;
  elsif pl.kind = 'package' then
    select greatest(t, coalesce(max(ends_at), t)) into st from billing.subscriptions
     where user_id = p_uid and status = 'active' and ends_at > t;
    insert into billing.subscriptions(user_id, plan_id, payment_id, starts_at, ends_at, daily_amount, total_amount, total_left, source)
    values (p_uid, pl.id, p_payment, st, st + pl.validity, pl.daily_tokens, coalesce(p_tokens, pl.total_tokens), coalesce(p_tokens, pl.total_tokens),
            case when p_source = 'admin' then 'admin' else 'purchase' end)
    returning id into sid;
  else
    insert into billing.token_balances(user_id, amount, left_tokens, expires_at, source, payment_id)
    values (p_uid, p_tokens, p_tokens, t + pl.validity, case when p_source = 'admin' then 'admin' else 'payg' end, p_payment)
    returning id into bid;
  end if;
  insert into billing.usage_ledger(user_id, kind, ref, bucket, subscription_id, balance_id, tokens, source, note)
  values (p_uid, 'grant', p_ref, case when sid is not null then 'package' else 'payg' end, sid, bid, p_tokens, p_source, p_plan);
  return jsonb_build_object('subscription_id', sid, 'balance_id', bid);
end $$;

-- ============================================================================ payments RPCs (service role; billing-* functions)
-- JSON keys say 'purchase_id' (the app and the return URL use ?purchase=<payment id>).
create or replace function billing.payment_replay(pu billing.payments) returns jsonb
language sql stable set search_path = billing, public as $$
  select jsonb_build_object('ok', true, 'replay', true, 'purchase_id', pu.id, 'amount_usd', pu.amount_usd, 'currency', pu.currency,
    'plan_id', pu.plan_id, 'product_id', pu.plan_id, 'tokens', pu.tokens, 'provider', pu.provider, 'status', pu.status, 'result', pu.result,
    'checkout_key', pu.checkout_key, 'response', pu.client_response)
$$;

-- Price for a plan (+ PAYG amount). null = not for sale.
create or replace function billing.quote(p_plan text, p_tokens bigint) returns jsonb
language plpgsql stable security definer set search_path = billing, public as $$
declare pl billing.plans; n bigint;
begin
  select * into pl from billing.plans where id = p_plan and active and kind in ('package','payg');
  if pl.id is null then return null; end if;
  if pl.kind = 'package' then
    return jsonb_build_object('plan_id', pl.id, 'kind', pl.kind, 'tokens', pl.total_tokens, 'amount_usd', pl.price_usd, 'name', pl.name);
  end if;
  n := p_tokens;
  if n is null or n < pl.min_tokens or n > pl.max_tokens or n % pl.step_tokens <> 0 then return null; end if;
  return jsonb_build_object('plan_id', pl.id, 'kind', pl.kind, 'tokens', n,
    'amount_usd', round(n::numeric / pl.unit_tokens * pl.price_usd, 2), 'name', pl.name);
end $$;

create or replace function public.billing_payment_create(p_uid uuid, p_plan text, p_tokens bigint default null, p_device text default null,
  p_provider text default 'sifalo', p_idem text default null, p_fingerprint text default null) returns jsonb
language plpgsql security definer set search_path = billing, public as $$
declare q jsonb; pu billing.payments; n int; pid uuid;
        prov text := lower(coalesce(p_provider, 'sifalo'));
        idem text := case when p_idem ~ '^[A-Za-z0-9_.:-]{8,100}$' then p_idem end;
        fp text := nullif(left(coalesce(p_fingerprint, ''), 200), '');
        dev text := case when p_device ~ '^[A-Za-z0-9_-]{6,64}$' then p_device end;
begin
  if p_uid is null then return jsonb_build_object('ok', false, 'reason', 'bad_request'); end if;
  if prov !~ '^[a-z][a-z0-9_]{1,31}$' then return jsonb_build_object('ok', false, 'reason', 'bad_provider'); end if;
  if p_idem is not null and idem is null then return jsonb_build_object('ok', false, 'reason', 'bad_idempotency_key'); end if;
  if not billing.on_for(p_uid) then return jsonb_build_object('ok', false, 'reason', 'billing_disabled'); end if;
  perform pg_advisory_xact_lock(hashtext('billing.checkout'), hashtext(p_uid::text));
  if idem is not null then
    select * into pu from billing.payments where user_id = p_uid and idempotency_key = idem;
    if found then
      if pu.plan_id is distinct from p_plan or pu.provider is distinct from prov or pu.fingerprint is distinct from fp
         or (p_tokens is not null and pu.tokens is distinct from p_tokens) then
        return jsonb_build_object('ok', false, 'reason', 'idempotency_key_reused');
      end if;
      return billing.payment_replay(pu);
    end if;
  elsif fp is not null then
    select * into pu from billing.payments
     where user_id = p_uid and fingerprint = fp and idempotency_key is null and status = 'pending'
       and created_at > now() - make_interval(secs => billing.num('billing_doubletap_seconds', 20)::double precision)
     order by created_at desc limit 1;
    if found then return billing.payment_replay(pu); end if;
  end if;
  q := billing.quote(p_plan, p_tokens);
  if q is null then return jsonb_build_object('ok', false, 'reason', 'unknown_product'); end if;
  select count(*) into n from billing.payments where user_id = p_uid and created_at > now() - interval '1 minute';
  if n >= billing.num('billing_checkout_per_minute', 10) then return jsonb_build_object('ok', false, 'reason', 'rate_limited'); end if;
  select count(*) into n from billing.payments where user_id = p_uid and created_at > now() - interval '1 hour';
  if n >= billing.num('billing_max_pending_per_hour', 10) then return jsonb_build_object('ok', false, 'reason', 'rate_limited'); end if;
  insert into billing.payments(user_id, plan_id, tokens, amount_usd, provider, device_id, idempotency_key, fingerprint)
  values (p_uid, p_plan, (q->>'tokens')::bigint, (q->>'amount_usd')::numeric, prov, dev, idem, fp) returning id into pid;
  return jsonb_build_object('ok', true, 'replay', false, 'purchase_id', pid, 'amount_usd', (q->>'amount_usd')::numeric, 'currency', 'USD',
    'plan_id', p_plan, 'product_id', p_plan, 'tokens', (q->>'tokens')::bigint, 'name', q->>'name', 'provider', prov);
end $$;

create or replace function public.billing_payment_find(p_payment uuid, p_uid uuid default null) returns jsonb
language sql stable security definer set search_path = billing, public as $$
  select to_jsonb(x) from (select id, user_id, plan_id, plan_id as product_id, tokens, amount_usd, currency, status, provider,
           provider_ref, pending_ref, checkout_key, idempotency_key, result, subscription_id, balance_id,
           case when status = 'paid' then tokens else 0 end as tokens_added, created_at, paid_at, last_checked_at
    from billing.payments where id = p_payment and (p_uid is null or user_id = p_uid)) x
$$;

create or replace function public.billing_payment_find_by_key(p_key text, p_provider text default null) returns jsonb
language sql stable security definer set search_path = billing, public as $$
  select to_jsonb(x) from (select id, user_id, plan_id, tokens, amount_usd, currency, status, provider, provider_ref, checkout_key, result,
           created_at, paid_at, last_checked_at
    from billing.payments where checkout_key = p_key and p_key is not null and (p_provider is null or provider = p_provider)
    order by created_at desc limit 1) x
$$;

create or replace function public.billing_payment_set_checkout_key(p_payment uuid, p_key text) returns void
language sql security definer set search_path = billing, public as $$
  update billing.payments set checkout_key = left(p_key, 500) where id = p_payment and status = 'pending'
$$;

create or replace function public.billing_payment_touch(p_payment uuid, p_result text) returns void
language sql security definer set search_path = billing, public as $$
  update billing.payments set last_checked_at = now(), result = coalesce(left(p_result, 60), result) where id = p_payment
$$;

create or replace function public.billing_payment_note_ref(p_payment uuid, p_ref text) returns void
language sql security definer set search_path = billing, public as $$
  update billing.payments set pending_ref = left(p_ref, 128) where id = p_payment and status = 'pending' and p_ref ~ '^[A-Za-z0-9_.:-]{1,128}$'
$$;

create or replace function public.billing_payment_save_response(p_payment uuid, p_response jsonb) returns void
language sql security definer set search_path = billing, public as $$
  update billing.payments set client_response = p_response where id = p_payment
$$;

create or replace function public.billing_payment_failed(p_payment uuid, p_reason text, p_payload jsonb) returns void
language sql security definer set search_path = billing, public as $$
  update billing.payments set status = 'failed', verify_payload = coalesce(p_payload, verify_payload),
         result = left(coalesce(nullif(p_reason, ''), 'failed'), 60), last_checked_at = now()
   where id = p_payment and status = 'pending'
$$;

create or replace function public.billing_payment_expire(p_payment uuid, p_min_age_hours int default 24) returns boolean
language plpgsql security definer set search_path = billing, public as $$
declare n int;
begin
  update billing.payments set status = 'failed', result = 'expired', last_checked_at = now()
   where id = p_payment and status = 'pending'
     and created_at <= now() - make_interval(hours => greatest(coalesce(p_min_age_hours, 24), 1));
  get diagnostics n = row_count;
  return n > 0;
end $$;

create or replace function public.billing_payment_pending(p_older_than_minutes int default 10, p_since_hours int default 72,
  p_limit int default 20, p_provider text default null) returns jsonb
language sql stable security definer set search_path = billing, public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'user_id', user_id, 'provider', provider, 'created_at', created_at) order by created_at), '[]'::jsonb) from (
    select id, user_id, provider, created_at from billing.payments
    where status = 'pending'
      and created_at > now() - make_interval(hours => least(greatest(coalesce(p_since_hours, 72), 1), 24 * 30))
      and created_at <= now() - make_interval(mins => least(greatest(coalesce(p_older_than_minutes, 10), 0), 24 * 60))
      and (p_provider is null or provider = p_provider)
    order by created_at limit least(greatest(coalesce(p_limit, 20), 1), 100)) x
$$;

-- Credits a verified payment exactly once per (provider, provider_ref). Outcomes: paid, already_paid, purchase_paid_other_sid,
-- sid_reused, no_sid, amount_mismatch, currency_mismatch, provider_mismatch, no_purchase. Not gated on billing_enabled:
-- money the provider confirmed must always be credited once (the edge functions do the gating).
create or replace function public.billing_payment_paid(p_payment uuid, p_provider text, p_ref text, p_amount numeric, p_currency text,
  p_payment_type text, p_payload jsonb) returns text
language plpgsql security definer set search_path = billing, public as $$
declare pu billing.payments; c jsonb; pl billing.plans;
begin
  select * into pu from billing.payments where id = p_payment for update;
  if pu.id is null then return 'no_purchase'; end if;
  if pu.provider is distinct from p_provider then
    update billing.payments set result = 'provider_mismatch', last_checked_at = now() where id = pu.id and status = 'pending';
    return 'provider_mismatch';
  end if;
  if pu.status in ('paid','reversed') then
    return case when pu.provider_ref = p_ref then 'already_paid' else 'purchase_paid_other_sid' end;
  end if;
  if p_ref is null or p_ref = '' then return 'no_sid'; end if;
  if exists (select 1 from billing.payments where provider = p_provider and provider_ref = p_ref and id <> pu.id) then
    update billing.payments set result = 'sid_reused', last_checked_at = now() where id = pu.id;
    return 'sid_reused';
  end if;
  if upper(coalesce(p_currency, '')) <> upper(pu.currency) then
    update billing.payments set result = 'currency_mismatch', verify_payload = p_payload, last_checked_at = now() where id = pu.id;
    return 'currency_mismatch';
  end if;
  if p_amount is null or round(p_amount * 100) <> round(pu.amount_usd * 100) then
    update billing.payments set result = 'amount_mismatch', verify_payload = p_payload, last_checked_at = now() where id = pu.id;
    return 'amount_mismatch';
  end if;

  c := billing.credit(pu.user_id, pu.plan_id, pu.tokens, pu.id, 'purchase', 'payment:' || pu.id);
  update billing.payments set status = 'paid', provider_ref = p_ref, payment_type = left(p_payment_type, 60), verify_payload = p_payload,
    paid_at = now(), result = 'paid', last_checked_at = now(),
    subscription_id = (c->>'subscription_id')::uuid, balance_id = (c->>'balance_id')::uuid
   where id = pu.id;
  select * into pl from billing.plans where id = pu.plan_id;
  perform billing.post_ledger(jsonb_build_object(
    'entry_type', case when pl.kind = 'package' then 'pass_purchase' else 'pack_purchase' end,
    'funding', 'cash', 'sku', pu.plan_id, 'user_id', pu.user_id, 'amount_usd', pu.amount_usd,
    'tokens', pu.tokens,
    'pass_days', case when pl.kind = 'package' then greatest(1, ceil(extract(epoch from pl.validity) / 86400.0))::int end,
    'payment_method', left(p_payment_type, 60), 'external_ref', case when p_provider = 'sifalo' then p_ref else p_provider || ':' || p_ref end,
    'source_ref', 'billing:payment:' || pu.id, 'note', coalesce(pl.name, 'Payment') || ' (' || pu.tokens || ' tokens)'));
  return 'paid';
end $$;

-- Refund (where the law requires it) or clawback (payment reversed by the provider): takes back what that payment
-- added and is still left (reversing ledger rows), marks the payment reversed and writes the finance row.
create or replace function public.billing_payment_reverse(p_payment uuid, p_kind text, p_reason text, p_by text default 'owner') returns jsonb
language plpgsql security definer set search_path = billing, public as $$
declare pu billing.payments; s billing.subscriptions; b billing.token_balances; back bigint := 0; used bigint := 0;
begin
  if p_kind not in ('refund','clawback') then return jsonb_build_object('ok', false, 'reason', 'bad_kind'); end if;
  select * into pu from billing.payments where id = p_payment for update;
  if pu.id is null then return jsonb_build_object('ok', false, 'reason', 'no_purchase'); end if;
  if pu.status = 'reversed' then return jsonb_build_object('ok', true, 'reason', 'already_reversed'); end if;
  if pu.status <> 'paid' then return jsonb_build_object('ok', false, 'reason', 'not_paid'); end if;
  perform pg_advisory_xact_lock(hashtext('billing.usage'), hashtext(pu.user_id::text));
  if pu.subscription_id is not null then
    select * into s from billing.subscriptions where id = pu.subscription_id for update;
    back := s.total_left; used := s.total_amount - s.total_left;
    update billing.subscriptions set total_left = 0, status = 'revoked' where id = s.id;
    if back > 0 then
      insert into billing.usage_ledger(user_id, kind, ref, bucket, subscription_id, tokens, note)
      values (pu.user_id, 'reverse', 'payment:' || pu.id, 'package', s.id, -back, p_kind || ': ' || left(coalesce(p_reason, ''), 200));
    end if;
  elsif pu.balance_id is not null then
    select * into b from billing.token_balances where id = pu.balance_id for update;
    back := b.left_tokens; used := b.amount - b.left_tokens;
    update billing.token_balances set left_tokens = 0, status = 'revoked' where id = b.id;
    if back > 0 then
      insert into billing.usage_ledger(user_id, kind, ref, bucket, balance_id, tokens, note)
      values (pu.user_id, 'reverse', 'payment:' || pu.id, 'payg', b.id, -back, p_kind || ': ' || left(coalesce(p_reason, ''), 200));
    end if;
  end if;
  update billing.payments set status = 'reversed', reversed_at = now(), result = p_kind || ': ' || left(coalesce(p_reason, ''), 200) where id = pu.id;
  perform billing.post_ledger(jsonb_build_object('entry_type', p_kind, 'funding', 'cash', 'sku', pu.plan_id,
    'user_id', pu.user_id, 'amount_usd', pu.amount_usd, 'tokens', back, 'external_ref', pu.provider_ref,
    'source_ref', 'billing:' || p_kind || ':' || pu.id,
    'note', coalesce(p_reason, p_kind) || case when used > 0 then ' | ' || used || ' tokens already used' else '' end || ' | by ' || coalesce(p_by, 'system')));
  return jsonb_build_object('ok', true, 'tokens_taken_back', back, 'tokens_already_used', used);
end $$;

-- Owner tool: give a package or PAYG tokens (support, compensation), or take tokens back (p_tokens < 0, PAYG only:
-- taken from the soonest-expiring balances). Every movement is a ledger row.
create or replace function public.billing_adjust(p_uid uuid, p_plan text, p_tokens bigint, p_note text default null) returns jsonb
language plpgsql security definer set search_path = billing, public as $$
declare pl billing.plans; c jsonb; rem bigint; take bigint; b billing.token_balances; ref text := 'admin:' || gen_random_uuid();
begin
  if p_uid is null then return jsonb_build_object('ok', false, 'reason', 'bad_request'); end if;
  select * into pl from billing.plans where id = coalesce(p_plan, 'payg');
  if pl.id is null or pl.kind = 'free' then return jsonb_build_object('ok', false, 'reason', 'unknown_product'); end if;
  if pl.kind = 'payg' and coalesce(p_tokens, 0) = 0 then return jsonb_build_object('ok', false, 'reason', 'bad_request'); end if;
  perform pg_advisory_xact_lock(hashtext('billing.usage'), hashtext(p_uid::text));
  if coalesce(p_tokens, 0) < 0 then
    if pl.kind <> 'payg' then return jsonb_build_object('ok', false, 'reason', 'payg_only'); end if;
    rem := -p_tokens;
    for b in select * from billing.token_balances where user_id = p_uid and status = 'active' and left_tokens > 0 and expires_at > billing.clock()
             order by expires_at for update loop
      exit when rem <= 0;
      take := least(rem, b.left_tokens);
      update billing.token_balances set left_tokens = left_tokens - take where id = b.id;
      insert into billing.usage_ledger(user_id, kind, ref, bucket, balance_id, tokens, source, note)
      values (p_uid, 'adjust', ref, 'payg', b.id, -take, 'admin', left(coalesce(p_note, 'Adjusted by owner'), 300));
      rem := rem - take;
    end loop;
    return jsonb_build_object('ok', true, 'taken', -p_tokens - rem, 'short', rem);
  end if;
  c := billing.credit(p_uid, pl.id, case when pl.kind = 'package' then coalesce(nullif(p_tokens, 0), pl.total_tokens) else p_tokens end, null, 'admin', ref);
  perform billing.post_ledger(jsonb_build_object('entry_type', 'reward_grant', 'funding', 'none', 'sku', pl.id, 'user_id', p_uid,
    'tokens', case when pl.kind = 'package' then coalesce(nullif(p_tokens, 0), pl.total_tokens) else p_tokens end, 'amount_usd', 0,
    'source_ref', 'billing:' || ref, 'note', left(coalesce(p_note, 'Granted by owner'), 300)));
  return jsonb_build_object('ok', true) || c;
end $$;

-- The ledger balances: for every subscription and balance, the sum of its ledger rows equals what is left. Returns the
-- rows that do not (empty array = balanced).
create or replace function public.billing_ledger_check(p_uid uuid default null) returns jsonb
language sql stable security definer set search_path = billing, public as $$
  select coalesce(jsonb_agg(x), '[]'::jsonb) from (
    select 'subscription' as kind, s.id, s.user_id, s.total_left as left_now, coalesce(sum(l.tokens), 0) as ledger_sum
      from billing.subscriptions s left join billing.usage_ledger l on l.subscription_id = s.id
     where p_uid is null or s.user_id = p_uid
     group by s.id having s.total_left <> coalesce(sum(l.tokens), 0)
    union all
    select 'balance', b.id, b.user_id, b.left_tokens, coalesce(sum(l.tokens), 0)
      from billing.token_balances b left join billing.usage_ledger l on l.balance_id = b.id
     where p_uid is null or b.user_id = p_uid
     group by b.id having b.left_tokens <> coalesce(sum(l.tokens), 0)) x
$$;

-- ============================================================================ user RPCs (signed-in app)
-- Plan & usage screen + Get more: position, active packages, PAYG balances, catalogue.
create or replace function public.billing_usage() returns jsonb
language plpgsql stable security definer set search_path = billing, public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'auth required' using errcode = '28000'; end if;
  if not billing.on_for(me) then return jsonb_build_object('enabled', false); end if;
  return billing.position(me, 'chat') || jsonb_build_object(
    'balances', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'left', left_tokens, 'amount', amount, 'expires_at', expires_at,
                   'source', source) order by expires_at), '[]'::jsonb)
                 from billing.token_balances where user_id = me and status = 'active' and left_tokens > 0 and expires_at > billing.clock()),
    'queued', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'plan', plan_id, 'starts_at', starts_at, 'ends_at', ends_at,
                   'daily_amount', daily_amount, 'total_amount', total_amount) order by starts_at), '[]'::jsonb)
               from billing.subscriptions where user_id = me and status = 'active' and starts_at > billing.clock()),
    'plans', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'kind', kind, 'tier', tier, 'name', name, 'price_usd', price_usd,
                   'total_tokens', total_tokens, 'daily_tokens', daily_tokens,
                   'validity_days', round(extract(epoch from validity) / 86400.0, 2), 'unit_tokens', unit_tokens,
                   'min_tokens', min_tokens, 'max_tokens', max_tokens, 'step_tokens', step_tokens, 'presets', presets) order by sort), '[]'::jsonb)
              from billing.plans where active));
end $$;

-- Payments and what they added, newest first (no per-request usage rows).
create or replace function public.billing_activity(p_limit int default 50) returns jsonb
language plpgsql stable security definer set search_path = billing, public as $$
declare me uuid := auth.uid(); n int := least(greatest(coalesce(p_limit, 50), 1), 200);
begin
  if me is null then raise exception 'auth required' using errcode = '28000'; end if;
  if not billing.on_for(me) then return jsonb_build_object('enabled', false); end if;
  return jsonb_build_object('enabled', true,
    'payments', (select coalesce(jsonb_agg(x order by x.created_at desc), '[]'::jsonb) from (
        select id, plan_id, tokens, amount_usd, currency, status, payment_type, result, created_at, paid_at from billing.payments
        where user_id = me order by created_at desc limit n) x),
    'grants', (select coalesce(jsonb_agg(x order by x.created_at desc), '[]'::jsonb) from (
        select id, kind, bucket, tokens, note, created_at from billing.usage_ledger
        where user_id = me and kind in ('grant','reverse','adjust') order by created_at desc limit n) x));
end $$;

-- ============================================================================ switch (edge functions)
-- {enabled: on for everyone, tester: this user is a tester, on: billing applies to this user, testers: any testers,
--  provider_live}. p_uid null = no user (webhook, return, reconcile): on when enabled or any tester exists.
create or replace function public.billing_is_on(p_uid uuid default null) returns jsonb
language sql stable security definer set search_path = billing, public as $$
  select jsonb_build_object('enabled', billing.enabled(), 'tester', billing.is_tester(p_uid), 'provider_live', billing.provider_live(),
    'testers', exists (select 1 from public.ai_settings where key = 'billing_testers' and jsonb_typeof(value) = 'array' and jsonb_array_length(value) > 0),
    'on', case when p_uid is null
               then billing.enabled() or exists (select 1 from public.ai_settings where key = 'billing_testers' and jsonb_typeof(value) = 'array'
                                                  and jsonb_array_length(value) > 0)
               else billing.on_for(p_uid) end)
$$;

-- ============================================================================ failed-charge retry queue
-- ai-chat: when usage_charge fails (timeout, DB hiccup), queue the same charge here; cron retries it. Same request_id,
-- so a charge that did land is never written twice.
create or replace function public.usage_charge_enqueue(p_user_id uuid, p_tokens_in bigint, p_tokens_out bigint, p_source text,
  p_request_id text) returns jsonb
language plpgsql security definer set search_path = billing, public as $$
declare rid text := nullif(btrim(coalesce(p_request_id, '')), ''); n int;
begin
  if p_user_id is null or rid is null or length(rid) > 200 or coalesce(p_tokens_in, 0) < 0 or coalesce(p_tokens_out, 0) < 0 then
    return jsonb_build_object('queued', false, 'reason', 'bad_request');
  end if;
  if exists (select 1 from billing.usage_requests where request_id = rid) then
    return jsonb_build_object('queued', false, 'reason', 'already_charged');
  end if;
  insert into billing.charge_queue(request_id, user_id, tokens_in, tokens_out, source)
  values (rid, p_user_id, coalesce(p_tokens_in, 0), coalesce(p_tokens_out, 0), left(p_source, 40))
  on conflict (request_id) do nothing;
  get diagnostics n = row_count;
  return jsonb_build_object('queued', true, 'duplicate', n = 0);
end $$;

create or replace function public.billing_charge_retry_drain(p_limit int default 100) returns jsonb
language plpgsql security definer set search_path = billing, public as $$
declare r record; res jsonb; ok int := 0; dup int := 0; bad int := 0; old int := 0;
        max_age numeric := greatest(1, billing.num('billing_retry_max_age_hours', 72));
begin
  for r in select * from billing.charge_queue where status = 'pending' and next_try_at <= now()
           order by created_at limit least(greatest(coalesce(p_limit, 100), 1), 1000) for update skip locked loop
    if r.created_at < now() - make_interval(hours => max_age::int) then
      update billing.charge_queue set status = 'expired', done_at = now(), error = coalesce(error || ' | ', '') || 'too old, not billed'
       where request_id = r.request_id;
      old := old + 1; continue;
    end if;
    begin
      res := public.usage_charge(r.user_id, r.tokens_in, r.tokens_out, r.source, r.request_id);
      if coalesce((res->>'ok')::boolean, false) then
        update billing.charge_queue set status = 'done', done_at = now(), attempts = attempts + 1, result = res where request_id = r.request_id;
        if coalesce((res->>'duplicate')::boolean, false) then dup := dup + 1; else ok := ok + 1; end if;
      else
        update billing.charge_queue set status = 'expired', done_at = now(), attempts = attempts + 1, result = res,
               error = 'refused: ' || coalesce(res->>'reason', '?') where request_id = r.request_id;
        bad := bad + 1;
      end if;
    exception when others then
      update billing.charge_queue set attempts = attempts + 1, error = left(sqlerrm, 300),
             next_try_at = now() + least(interval '1 hour', interval '1 minute' * power(2, least(attempts, 6)))
       where request_id = r.request_id;
      bad := bad + 1;
    end;
  end loop;
  return jsonb_build_object('charged', ok, 'duplicate', dup, 'failed', bad, 'expired', old,
    'pending', (select count(*) from billing.charge_queue where status = 'pending'));
end $$;

-- ============================================================================ ledger sync (finance.ledger outbox)
create or replace function public.billing_sync_ledger() returns jsonb
language plpgsql security definer set search_path = billing, public as $$
declare r record; ok int := 0; bad int := 0;
begin
  for r in select * from billing.ledger_outbox where posted_at is null order by id limit 500 for update skip locked loop
    begin
      perform finance.ledger_add_row(r.entry || jsonb_build_object('product', 'agent', 'created_by', 'billing'));
      update billing.ledger_outbox set posted_at = now(), error = null where id = r.id; ok := ok + 1;
    exception when unique_violation then
      update billing.ledger_outbox set posted_at = now(), error = 'already in ledger' where id = r.id; ok := ok + 1;
    when others then
      update billing.ledger_outbox set error = left(sqlerrm, 300), attempts = attempts + 1 where id = r.id; bad := bad + 1;
    end;
  end loop;
  return jsonb_build_object('posted', ok, 'failed', bad, 'waiting', (select count(*) from billing.ledger_outbox where posted_at is null));
end $$;

-- ============================================================================ renewal reminder (no auto-charge with Sifalo)
-- The day before a package ends, if nothing is queued after it: one "From SubMac" inbox row (English + Somali).
do $$ begin
  if to_regclass('public.user_inbox') is not null and exists (select 1 from pg_constraint where conname = 'user_inbox_kind_check') then
    alter table public.user_inbox drop constraint user_inbox_kind_check;
    alter table public.user_inbox add constraint user_inbox_kind_check
      check (kind in ('admin_message', 'reward_grant', 'reward_earned', 'billing_reminder'));
  end if;
end $$;

create or replace function public.billing_renewal_reminders(p_limit int default 500) returns jsonb
language plpgsql security definer set search_path = billing, public as $$
declare t timestamptz := billing.clock(); s record; sent int := 0; bad int := 0;
begin
  for s in select x.*, p.name as plan_name from billing.subscriptions x join billing.plans p on p.id = x.plan_id
           where x.status = 'active' and x.reminded_at is null and x.starts_at <= t
             and x.ends_at > t and x.ends_at <= t + interval '1 day'
             and not exists (select 1 from billing.subscriptions y where y.user_id = x.user_id and y.status = 'active'
                               and y.id <> x.id and y.ends_at > x.ends_at)
           order by x.ends_at limit least(greatest(coalesce(p_limit, 500), 1), 5000) for update of x skip locked loop
    continue when not billing.on_for(s.user_id);
    begin
      insert into public.user_inbox(user_id, kind, title, body)
      values (s.user_id, 'billing_reminder', 'Your plan ends tomorrow · Qorshahaagu berri ayuu dhammaanayaa',
              'Get more in Settings > Plan & usage. · Ka iibso Settings > Plan & usage.');
      update billing.subscriptions set reminded_at = t where id = s.id;
      sent := sent + 1;
    exception when others then
      bad := bad + 1;
    end;
  end loop;
  return jsonb_build_object('sent', sent, 'failed', bad);
end $$;

-- ============================================================================ account deletion warning (signed-in app)
-- What paid balance the user would lose. has_paid false = nothing to warn about.
create or replace function public.billing_deletion_warning() returns jsonb
language plpgsql stable security definer set search_path = billing, public as $$
declare me uuid := auth.uid(); p jsonb; pend int;
begin
  if me is null then raise exception 'auth required' using errcode = '28000'; end if;
  if not billing.on_for(me) then return jsonb_build_object('has_paid', false); end if;
  p := billing.position(me, 'chat');
  select count(*) into pend from billing.payments where user_id = me and status = 'pending';
  return jsonb_build_object('has_paid', (p->>'paid_left')::bigint > 0 or pend > 0,
    'paid_left', (p->>'paid_left')::bigint, 'tokens_per_reply', p->'tokens_per_reply',
    'package_ends_at', (select max(ends_at) from billing.subscriptions where user_id = me and status = 'active' and ends_at > billing.clock()),
    'payg_left', p->'payg'->'left', 'pending_payments', pend);
end $$;

-- ============================================================================ admin (owner dashboard, service role)
-- Edit a plan. Keys: name, price_usd, total_tokens, daily_tokens, validity_days, unit_tokens, min_tokens, max_tokens,
-- step_tokens, presets, active, sort, note. New prices apply to new payments; bought packages keep their amounts.
create or replace function public.billing_plan_update(p_id text, p_patch jsonb) returns jsonb
language plpgsql security definer set search_path = billing, public as $$
declare bad text; pl billing.plans;
begin
  select k into bad from jsonb_object_keys(coalesce(p_patch, '{}'::jsonb)) k
   where k not in ('name','price_usd','total_tokens','daily_tokens','validity_days','unit_tokens','min_tokens','max_tokens',
                   'step_tokens','presets','active','sort','note') limit 1;
  if bad is not null then return jsonb_build_object('ok', false, 'reason', 'unknown_field', 'field', bad); end if;
  update billing.plans set
    name = coalesce(p_patch->>'name', name),
    price_usd = coalesce((p_patch->>'price_usd')::numeric, price_usd),
    total_tokens = case when p_patch ? 'total_tokens' then (p_patch->>'total_tokens')::bigint else total_tokens end,
    daily_tokens = case when p_patch ? 'daily_tokens' then (p_patch->>'daily_tokens')::bigint else daily_tokens end,
    validity = case when p_patch ? 'validity_days' then make_interval(days => (p_patch->>'validity_days')::int) else validity end,
    unit_tokens = case when p_patch ? 'unit_tokens' then (p_patch->>'unit_tokens')::bigint else unit_tokens end,
    min_tokens = case when p_patch ? 'min_tokens' then (p_patch->>'min_tokens')::bigint else min_tokens end,
    max_tokens = case when p_patch ? 'max_tokens' then (p_patch->>'max_tokens')::bigint else max_tokens end,
    step_tokens = case when p_patch ? 'step_tokens' then (p_patch->>'step_tokens')::bigint else step_tokens end,
    presets = case when p_patch ? 'presets' then array(select jsonb_array_elements_text(p_patch->'presets')::bigint) else presets end,
    active = coalesce((p_patch->>'active')::boolean, active),
    sort = coalesce((p_patch->>'sort')::int, sort),
    note = case when p_patch ? 'note' then p_patch->>'note' else note end,
    updated_at = now()
  where id = p_id
  returning * into pl;
  if pl.id is null then return jsonb_build_object('ok', false, 'reason', 'unknown_plan'); end if;
  return jsonb_build_object('ok', true, 'plan', to_jsonb(pl));
exception when check_violation or invalid_text_representation or numeric_value_out_of_range then
  return jsonb_build_object('ok', false, 'reason', 'bad_value', 'detail', left(sqlerrm, 200));
end $$;

-- Payments for the dashboard, newest first. Refund = billing_payment_reverse(id, 'refund', reason, by); give or take
-- tokens = billing_adjust(...). Both write reversing ledger rows.
create or replace function public.billing_admin_payments(p_status text default null, p_uid uuid default null, p_limit int default 100)
returns jsonb language sql stable security definer set search_path = billing, public as $$
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc), '[]'::jsonb) from (
    select id, user_id, plan_id, tokens, amount_usd, currency, status, provider, provider_ref, payment_type, result,
           subscription_id, balance_id, created_at, paid_at, reversed_at, last_checked_at
      from billing.payments
     where (p_status is null or status = p_status) and (p_uid is null or user_id = p_uid)
     order by created_at desc limit least(greatest(coalesce(p_limit, 100), 1), 500)) x
$$;

-- ---------------------------------------------------------------- grants on functions
do $$ declare f text; begin
  for f in select p.oid::regprocedure::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'billing' loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
  for f in select p.oid::regprocedure::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('usage_gate','usage_charge','usage_charge_enqueue','billing_is_on',
             'billing_payment_create','billing_payment_find','billing_payment_find_by_key','billing_payment_set_checkout_key',
             'billing_payment_touch','billing_payment_note_ref','billing_payment_save_response','billing_payment_failed',
             'billing_payment_expire','billing_payment_pending','billing_payment_paid','billing_payment_reverse','billing_adjust',
             'billing_ledger_check','billing_charge_retry_drain','billing_sync_ledger','billing_renewal_reminders',
             'billing_plan_update','billing_admin_payments') loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
  for f in select p.oid::regprocedure::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('billing_usage','billing_activity','billing_deletion_warning') loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
end $$;

-- ---------------------------------------------------------------- schedules (pg_cron; skipped where it is missing)
--   billing-reconcile          every 10 min  re-verify pending payments, expire abandoned ones (edge function; needs
--                                            vault secrets bot_run_anon_key + billing_cron_secret = AI_CRON_SECRET)
--   billing-charge-retry       every 5 min   failed usage charges
--   billing-ledger-sync        every 30 min  finance.ledger outbox
--   billing-renewal-reminders  hourly        the day before a package ends
do $$ begin
  if to_regnamespace('cron') is null then
    raise notice 'pg_cron missing: billing schedules not created';
    return;
  end if;
  perform cron.unschedule(jobid) from cron.job
   where jobname in ('billing-reconcile', 'billing-charge-retry', 'billing-ledger-sync', 'billing-renewal-reminders');
  perform cron.schedule('billing-charge-retry', '*/5 * * * *', 'select public.billing_charge_retry_drain()');
  perform cron.schedule('billing-ledger-sync', '7,37 * * * *', 'select public.billing_sync_ledger()');
  perform cron.schedule('billing-renewal-reminders', '15 * * * *', 'select public.billing_renewal_reminders()');
  if to_regnamespace('net') is not null then
    perform cron.schedule('billing-reconcile', '*/10 * * * *', $cron$
      select net.http_post(
        url := 'https://moeemacbvsueekuvfjbo.supabase.co/functions/v1/billing-reconcile?older_than_minutes=10',
        headers := jsonb_build_object(
          'content-type', 'application/json',
          'authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'bot_run_anon_key'),
          'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'billing_cron_secret')),
        body := '{}'::jsonb,
        timeout_milliseconds := 120000)
      where exists (select 1 from vault.decrypted_secrets where name = 'billing_cron_secret')
    $cron$);
  end if;
end $$;
