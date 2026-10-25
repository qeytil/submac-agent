-- SubMac Agent billing: SubMac Coins, token packs, passes (LOCKED PLAN, docs/monetization/MONETIZATION.md section 4).
-- Agent project moeemacbvsueekuvfjbo.
--
-- ADDITIVE ONLY. New schema `billing`, new public.billing_* RPCs and new ai_settings keys (inserted with ON CONFLICT DO
-- NOTHING). It never alters, drops or deletes an existing table, function or row. Existing tables are only read
-- (ai_settings, ai_user_limits, reward_ledger, referrals, user_devices); the only writes outside `billing` are
--   * finance.ledger rows through finance.ledger_add_row() (the finance dashboard's own API), with a billing outbox
--     as fallback when that call fails, and
--   * a "From SubMac" inbox note (public.user_inbox) when an inviter earns a referral reward.
--
-- Everything is inert until ai_settings.billing_enabled = true: user RPCs refuse, service RPCs return
-- {"enabled": false}, and ai-chat keeps the old daily allowance.
--
-- Access: RLS on every billing table with no policies; nothing in schema billing is granted to anon/authenticated.
-- User RPCs (authenticated, check auth.uid()):  billing_summary, billing_history, billing_exchange, billing_buy_pass,
--   billing_set_auto_exchange.
-- Service-role RPCs (edge functions only): billing_precheck, billing_consume, billing_live_charge, billing_multipliers,
--   billing_create_purchase, billing_set_checkout_key, billing_find_purchase, billing_mark_paid, billing_mark_failed,
--   billing_pending_purchases, billing_reverse, billing_sync_ledger, billing_grant_admin.
--
-- Day boundary for billing (free daily, pass daily ceiling, free month): East Africa Time (Africa/Mogadishu),
-- the same day the finance dashboard closes on.

create schema if not exists billing;
revoke all on schema billing from public, anon, authenticated;
grant usage on schema billing to service_role;

-- ---------------------------------------------------------------- settings (public.ai_settings, owner edits them)
insert into public.ai_settings(key, value) values
  ('billing_enabled', 'false'::jsonb),                     -- master switch: nothing changes for users until true
  ('billing_free_daily_tokens', '60000'::jsonb),           -- free tier, weighted tokens per EAT day
  ('billing_free_monthly_tokens', '1000000'::jsonb),       -- free tier hard cap per calendar month (EAT)
  ('billing_free_live_minutes_month', '10'::jsonb),        -- free Live minutes per month
  ('billing_live_tokens_per_minute', '40000'::jsonb),      -- Live voice draws 40k weighted per minute after free minutes
  ('billing_coin_usd', '0.01'::jsonb),                     -- 1 coin = $0.01 (closed loop)
  ('billing_first_topup_bonus_max', '100'::jsonb),         -- first top-up doubled, at most +100 coins
  ('billing_bg_pass_share', '0.5'::jsonb),                 -- bots/background max 50% of a pass's daily ceiling
  ('billing_rollover_pct', '0.25'::jsonb),                 -- renewal carries up to 25% of the new pool
  ('billing_rollover_window_days', '7'::jsonb),            -- renew while active or within 7 days after expiry
  ('billing_tokens_per_reply', '3700'::jsonb),             -- UI: 1M weighted ~ 270 replies
  ('billing_referral_coins', '50'::jsonb),                 -- PLACEHOLDER (spec gap): inviter reward on invitee's first purchase
  ('billing_referral_max_per_inviter', '10'::jsonb),       -- PLACEHOLDER (spec gap): lifetime cap per inviter
  ('billing_auto_exchange_threshold', '20000'::jsonb),     -- auto-exchange buys a pack when paid balance drops below this
  ('billing_max_pending_per_hour', '10'::jsonb)            -- checkout rate limit per user
on conflict (key) do nothing;

create or replace function billing.num(p_key text, p_default numeric) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce((select case when jsonb_typeof(value) = 'number' then (value)::text::numeric
                               when jsonb_typeof(value) = 'string' and (value #>> '{}') ~ '^-?[0-9.]+$' then (value #>> '{}')::numeric end
                   from public.ai_settings where key = p_key), p_default)
$$;

create or replace function billing.enabled() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select value = 'true'::jsonb or value = '"true"'::jsonb from public.ai_settings where key = 'billing_enabled'), false)
$$;

create or replace function billing.today() returns date language sql stable as $$
  select (now() at time zone 'Africa/Mogadishu')::date
$$;
create or replace function billing.month_start() returns date language sql stable as $$
  select date_trunc('month', (now() at time zone 'Africa/Mogadishu'))::date
$$;

-- ---------------------------------------------------------------- catalog
create table if not exists billing.products (
  id text primary key,                         -- also the finance.ledger sku
  kind text not null check (kind in ('coins','pack','pass')),
  name text not null,
  price_usd numeric(10,2),                     -- cash price (coins top-ups; passes); null = coins only
  price_coins bigint,                          -- price in coins (packs, passes); null for top-ups
  coins bigint not null default 0,             -- top-up: coins credited before bonuses
  bonus_coins bigint not null default 0,       -- top-up ladder bonus
  tokens bigint not null default 0,            -- pack size / pass pool (weighted tokens)
  daily_ceiling bigint,                        -- pass daily ceiling; null = pool only (Day pass)
  validity interval not null default interval '30 days',
  cash_ok boolean not null default false,      -- can be bought directly through Sifalo
  badge text,                                  -- 'Best value', '+10%'
  sort int not null default 100,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

insert into billing.products(id, kind, name, price_usd, price_coins, coins, bonus_coins, tokens, daily_ceiling, validity, cash_ok, badge, sort) values
  ('topup_1',  'coins', '100 coins',   1.00, null,  100,   0, 0, null, interval '0', true, null,    10),
  ('topup_2',  'coins', '200 coins',   2.00, null,  200,   0, 0, null, interval '0', true, null,    20),
  ('topup_5',  'coins', '525 coins',   5.00, null,  500,  25, 0, null, interval '0', true, '+5%',   30),
  ('topup_10', 'coins', '1,100 coins',10.00, null, 1000, 100, 0, null, interval '0', true, '+10%',  40),
  ('topup_20', 'coins', '2,200 coins',20.00, null, 2000, 200, 0, null, interval '0', true, '+10%',  50),
  ('pack_1m',  'pack',  '1M pack',     null,  200, 0, 0,  1000000, null, interval '12 months', false, null, 110),
  ('pack_5m',  'pack',  '5M pack',     null,  950, 0, 0,  5000000, null, interval '12 months', false, null, 120),
  ('pack_10m', 'pack',  '10M pack',    null, 1850, 0, 0, 10000000, null, interval '12 months', false, null, 130),
  ('pack_15m', 'pack',  '15M pack',    null, 2700, 0, 0, 15000000, null, interval '12 months', false, null, 140),
  ('pass_day',     'pass', 'Day pass',     0.25,  25, 0, 0,  120000,   null, interval '24 hours', true, null,         210),
  ('pass_week',    'pass', 'Week pass',    1.25, 125, 0, 0,  700000, 200000, interval '7 days',   true, null,         220),
  ('pass_starter', 'pass', 'Starter pass', 1.99, 199, 0, 0, 1000000, 100000, interval '30 days',  true, null,         230),
  ('pass_plus',    'pass', 'Plus pass',    4.99, 499, 0, 0, 3000000, 250000, interval '30 days',  true, 'Best value', 240),
  ('pass_pro',     'pass', 'Pro pass',     9.99, 999, 0, 0, 6000000, 500000, interval '30 days',  true, null,         250)
on conflict (id) do nothing;

-- ---------------------------------------------------------------- model multipliers (dated)
create table if not exists billing.model_multipliers (
  id bigint generated always as identity primary key,
  pattern text not null,                       -- exact model id as in ai_models.model_id, a LIKE pattern ('gemini-3.8-flash%'), or '*'
  tier text not null check (tier in ('standard','advanced','premium')),
  multiplier numeric(6,3) not null check (multiplier > 0),
  effective_from date not null default date '2026-01-01',
  note text,
  created_at timestamptz not null default now()
);
create index if not exists mm_pattern on billing.model_multipliers (pattern, effective_from desc);

insert into billing.model_multipliers(pattern, tier, multiplier, effective_from, note)
select * from (values
  ('*', 'standard', 1.0, date '2026-01-01', 'Default: every model not listed is Standard 1x'),
  ('gemini-3.6-flash', 'advanced', 2.5, date '2026-01-01', 'PLACEHOLDER tier (spec names tiers, not models): ~2.5x Standard cost'),
  ('gemini-3-flash-preview', 'advanced', 2.5, date '2026-01-01', 'PLACEHOLDER tier: priced as Gemini 3.6 Flash'),
  ('gemini-3.8-flash', 'advanced', 2.5, date '2026-01-01', 'PLACEHOLDER tier until the 2027 price rise'),
  ('gemini-3.8-flash', 'premium', 5.0, date '2027-01-01', 'LOCKED PLAN: Gemini 3.8 Flash -> 5x from 2027-01-01')
) v(pattern, tier, multiplier, effective_from, note)
where not exists (select 1 from billing.model_multipliers);

create or replace function billing.multiplier_for(p_model text) returns table(tier text, multiplier numeric)
language sql stable security definer set search_path = billing, public as $$
  select m.tier, m.multiplier from billing.model_multipliers m
  where m.effective_from <= billing.today()
    and (m.pattern = '*' or m.pattern = p_model or (position('%' in m.pattern) > 0 and coalesce(p_model, '') like m.pattern))
  order by (m.pattern = p_model) desc, (m.pattern <> '*') desc, length(m.pattern) desc, m.effective_from desc
  limit 1
$$;

-- ---------------------------------------------------------------- wallets and coin history
create table if not exists billing.wallets (
  user_id uuid primary key,                    -- auth.users id (no FK: money records outlive account deletion)
  coins bigint not null default 0 check (coins >= 0),
  auto_exchange boolean not null default false,
  auto_exchange_product text not null default 'pack_1m' references billing.products(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists billing.purchases (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  product_id text not null references billing.products(id),
  kind text not null check (kind in ('coins','pass')),
  amount_usd numeric(10,2) not null check (amount_usd > 0),
  currency text not null default 'USD',
  status text not null default 'pending' check (status in ('pending','paid','failed','reversed')),
  sifalo_sid text unique,                      -- credit once per Sifalo transaction id
  checkout_key text,
  payment_type text,
  device_id text,
  coins_credited bigint not null default 0,
  grant_id uuid,
  verify_payload jsonb,
  result text,                                 -- last verification outcome (amount_mismatch, sid_reused, ...)
  created_at timestamptz not null default now(),
  paid_at timestamptz,
  reversed_at timestamptz,
  last_checked_at timestamptz
);
create index if not exists purchases_user on billing.purchases (user_id, created_at desc);
create index if not exists purchases_pending on billing.purchases (status, created_at) where status = 'pending';
create index if not exists purchases_key on billing.purchases (checkout_key) where checkout_key is not null;

create table if not exists billing.coin_transactions (
  id bigint generated always as identity primary key,
  user_id uuid not null,
  delta bigint not null,
  balance_after bigint not null,
  kind text not null check (kind in ('topup','bonus_ladder','bonus_first','pack','pass','auto_exchange','refund','clawback','referral','admin')),
  product_id text,
  purchase_id uuid,
  grant_id uuid,
  note text,
  created_at timestamptz not null default now()
);
create index if not exists coin_tx_user on billing.coin_transactions (user_id, created_at desc);

-- ---------------------------------------------------------------- token grants (packs and passes)
create table if not exists billing.token_grants (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  kind text not null check (kind in ('pack','pass')),
  product_id text not null references billing.products(id),
  pool_tokens bigint not null check (pool_tokens >= 0),   -- includes rollover_tokens
  rollover_tokens bigint not null default 0,              -- carried from rollover_from; burns first; never rolls again
  rollover_from uuid references billing.token_grants(id),
  rollover_cap bigint not null default 0,                 -- max carry-over (25% of this pool), settled when this pass starts
  rollover_settled boolean not null default true,         -- false while a renewal waits for the pass it renews to end
  used_tokens bigint not null default 0 check (used_tokens >= 0),
  daily_ceiling bigint,
  starts_at timestamptz not null default now(),
  ends_at timestamptz not null,
  funding text not null check (funding in ('coins','cash','admin','referral')),
  coins_paid bigint not null default 0,
  purchase_id uuid references billing.purchases(id),
  status text not null default 'active' check (status in ('active','replaced','revoked')),
  closed_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists grants_user_active on billing.token_grants (user_id, kind, ends_at) where status = 'active';

create table if not exists billing.daily_spend (
  grant_id uuid not null references billing.token_grants(id),
  day date not null,
  tokens bigint not null default 0,
  bg_tokens bigint not null default 0,
  primary key (grant_id, day)
);

create table if not exists billing.free_usage (
  user_id uuid not null,
  day date not null,
  tokens bigint not null default 0,
  bg_tokens bigint not null default 0,
  live_seconds int not null default 0,          -- free Live seconds used that day (monthly allowance = sum over month)
  primary key (user_id, day)
);

-- One row per charged request (idempotency key = request_id) — also the revenue-recognition source for passes/packs.
create table if not exists billing.consumption (
  id bigint generated always as identity primary key,
  request_id text not null unique,
  user_id uuid not null,
  source text,
  lane text,
  model text,
  tier text,
  multiplier numeric(6,3) not null default 1,
  weighted_tokens bigint not null,              -- before the multiplier
  charged_tokens bigint not null,               -- after the multiplier
  free_tokens bigint not null default 0,
  pass_tokens bigint not null default 0,
  pack_tokens bigint not null default 0,
  unpaid_tokens bigint not null default 0,      -- the last request may overrun what was left; logged, never billed
  detail jsonb,
  created_at timestamptz not null default now()
);
create index if not exists consumption_user on billing.consumption (user_id, created_at desc);

create table if not exists billing.live_charges (
  id bigint generated always as identity primary key,
  request_id text not null unique,              -- live:<call_id>:<call_seconds>
  user_id uuid not null,
  call_id uuid,
  seconds int not null,
  free_seconds int not null default 0,
  paid_tokens bigint not null default 0,
  created_at timestamptz not null default now()
);

-- First top-up bonus: once per user AND once per device (no verified phone exists yet — see docs, "gaps").
create table if not exists billing.first_bonus (
  user_id uuid primary key,
  device_id text unique,
  purchase_id uuid not null references billing.purchases(id),
  coins bigint not null,
  created_at timestamptz not null default now()
);

-- Referral reward on the invitee's first paid purchase (one per invitee, one per invitee device, capped per inviter).
create table if not exists billing.referral_rewards (
  invitee_id uuid primary key,
  inviter_id uuid not null,
  device_id text unique,
  purchase_id uuid not null references billing.purchases(id),
  coins bigint not null,
  status text not null default 'granted' check (status in ('granted','refused')),
  reason text,
  created_at timestamptz not null default now()
);
create index if not exists rr_inviter on billing.referral_rewards (inviter_id);

-- Finance ledger fallback: rows that could not be written to finance.ledger (retried by billing_sync_ledger()).
create table if not exists billing.ledger_outbox (
  id bigint generated always as identity primary key,
  entry jsonb not null,
  source_ref text not null unique,
  error text,
  attempts int not null default 0,
  posted_at timestamptz,
  created_at timestamptz not null default now()
);

-- Append-only money history.
create or replace function billing.block_changes() returns trigger language plpgsql as $$
begin raise exception 'billing.% is append-only', tg_table_name; end $$;
drop trigger if exists coin_tx_append_only on billing.coin_transactions;
create trigger coin_tx_append_only before update or delete on billing.coin_transactions for each row execute function billing.block_changes();
drop trigger if exists consumption_append_only on billing.consumption;
create trigger consumption_append_only before update or delete on billing.consumption for each row execute function billing.block_changes();

do $$ declare t text; begin
  for t in select tablename from pg_tables where schemaname = 'billing' loop
    execute format('alter table billing.%I enable row level security', t);
    execute format('revoke all on billing.%I from public, anon, authenticated', t);
    execute format('grant all on billing.%I to service_role', t);
  end loop;
end $$;

-- ---------------------------------------------------------------- helpers
create or replace function billing.wallet(p_uid uuid) returns billing.wallets
language plpgsql security definer set search_path = billing, public as $$
declare w billing.wallets;
begin
  insert into billing.wallets(user_id) values (p_uid) on conflict (user_id) do nothing;
  select * into w from billing.wallets where user_id = p_uid for update;
  return w;
end $$;

create or replace function billing.add_coins(p_uid uuid, p_delta bigint, p_kind text, p_product text, p_purchase uuid, p_grant uuid, p_note text)
returns bigint language plpgsql security definer set search_path = billing, public as $$
declare bal bigint;
begin
  perform billing.wallet(p_uid);
  update billing.wallets set coins = coins + p_delta, updated_at = now() where user_id = p_uid returning coins into bal;
  insert into billing.coin_transactions(user_id, delta, balance_after, kind, product_id, purchase_id, grant_id, note)
  values (p_uid, p_delta, bal, p_kind, p_product, p_purchase, p_grant, left(p_note, 300));
  return bal;
end $$;

-- Writes one finance.ledger row through the finance dashboard's API; on any failure the row waits in billing.ledger_outbox.
create or replace function billing.post_ledger(p_entry jsonb) returns void
language plpgsql security definer set search_path = billing, public as $$
declare ref text := p_entry->>'source_ref';
begin
  begin
    perform finance.ledger_add_row(p_entry || jsonb_build_object('product', 'agent', 'created_by', 'billing'));
  exception when unique_violation then
    null;  -- already posted (same entry_type + source_ref)
  when others then
    insert into billing.ledger_outbox(entry, source_ref, error, attempts) values (p_entry, ref, left(sqlerrm, 300), 1)
    on conflict (source_ref) do update set error = excluded.error, attempts = billing.ledger_outbox.attempts + 1;
  end;
end $$;

-- Free allowance for today: base (ai_user_limits override or billing_free_daily_tokens) + active admin grants per day.
create or replace function billing.free_limits(p_uid uuid) returns jsonb
language sql stable security definer set search_path = billing, public as $$
  with o as (select daily_cap_tokens from public.ai_user_limits where user_id = p_uid),
  g as (select coalesce(sum(amount_per_day), 0)::bigint as granted from public.reward_ledger
        where user_id = p_uid and kind = 'admin_grant' and not revoked and starts_at <= now() and expires_at > now()),
  b as (select coalesce((select daily_cap_tokens from o), billing.num('billing_free_daily_tokens', 60000))::bigint as base)
  select jsonb_build_object(
    'daily', b.base + g.granted,
    'monthly', greatest(billing.num('billing_free_monthly_tokens', 1000000)::bigint,
                        coalesce((select daily_cap_tokens from o), 0)::bigint * 31) + g.granted * 31,
    'live_seconds_month', (billing.num('billing_free_live_minutes_month', 10) * 60)::int)
  from b, g
$$;

-- ---------------------------------------------------------------- entitlements (what the user can spend right now)
create or replace function billing.entitlements(p_uid uuid) returns jsonb
language plpgsql stable security definer set search_path = billing, public as $$
declare
  lim jsonb := billing.free_limits(p_uid);
  d date := billing.today();
  ft bigint; fbg bigint; fm bigint; flive int;
  free_left bigint; free_bg_left bigint;
  share numeric := least(1, greatest(0, billing.num('background_share', 0.3)));
  bgp numeric := least(1, greatest(0, billing.num('billing_bg_pass_share', 0.5)));
  tpm numeric := greatest(1, billing.num('billing_live_tokens_per_minute', 40000));
  w billing.wallets;
  pass jsonb := null; pass_left bigint := 0; pass_today_left bigint := 0; pass_bg_left bigint := 0;
  packs jsonb := '[]'::jsonb; pack_left bigint := 0;
  r record; spent bigint; bgspent bigint; tl bigint; base_left bigint; prod billing.products; roll bigint;
  allowance bigint; bg_allow bigint; used_today bigint; live_free_left int;
begin
  select coalesce(sum(tokens) filter (where day = d), 0), coalesce(sum(bg_tokens) filter (where day = d), 0),
         coalesce(sum(tokens), 0), coalesce(sum(live_seconds), 0)
    into ft, fbg, fm, flive
    from billing.free_usage where user_id = p_uid and day >= billing.month_start();
  free_left := greatest(0, least((lim->>'daily')::bigint - ft, (lim->>'monthly')::bigint - fm));
  free_bg_left := greatest(0, least(free_left, floor((lim->>'daily')::bigint * share)::bigint - fbg));
  live_free_left := greatest(0, (lim->>'live_seconds_month')::int - flive);

  select * into w from billing.wallets where user_id = p_uid;

  for r in select g.* from billing.token_grants g
           where g.user_id = p_uid and g.status = 'active' and g.kind = 'pass' and g.starts_at <= now() and g.ends_at > now()
           order by g.ends_at loop
    select coalesce(s.tokens, 0), coalesce(s.bg_tokens, 0) into spent, bgspent from billing.daily_spend s where s.grant_id = r.id and s.day = d;
    spent := coalesce(spent, 0); bgspent := coalesce(bgspent, 0);
    tl := greatest(0, r.pool_tokens - r.used_tokens);
    pass_left := pass_left + tl;
    pass_today_left := pass_today_left + case when r.daily_ceiling is null then tl else greatest(0, least(tl, r.daily_ceiling - spent)) end;
    pass_bg_left := pass_bg_left + greatest(0, least(tl,
        floor(coalesce(r.daily_ceiling, r.pool_tokens) * bgp)::bigint - bgspent,
        case when r.daily_ceiling is null then tl else r.daily_ceiling - spent end));
    if pass is null then
      select * into prod from billing.products where id = r.product_id;
      base_left := greatest(0, least(tl, r.pool_tokens - r.rollover_tokens - greatest(0, r.used_tokens - r.rollover_tokens)));
      roll := least(base_left, floor(prod.tokens * billing.num('billing_rollover_pct', 0.25))::bigint);
      pass := jsonb_build_object('grant_id', r.id, 'product_id', r.product_id, 'name', prod.name, 'pool', r.pool_tokens,
        'rollover_tokens', r.rollover_tokens, 'left', tl, 'daily_ceiling', r.daily_ceiling, 'today_used', spent,
        'today_left', case when r.daily_ceiling is null then tl else greatest(0, least(tl, r.daily_ceiling - spent)) end,
        'starts_at', r.starts_at, 'ends_at', r.ends_at,
        'days_left', greatest(0, ceil(extract(epoch from (r.ends_at - now())) / 86400.0))::int,
        'rollover_preview', roll,
        'renew_until', r.ends_at + make_interval(days => billing.num('billing_rollover_window_days', 7)::int));
    end if;
  end loop;

  for r in select g.* from billing.token_grants g
           where g.user_id = p_uid and g.status = 'active' and g.kind = 'pack' and g.starts_at <= now() and g.ends_at > now()
             and g.used_tokens < g.pool_tokens
           order by g.ends_at loop
    tl := r.pool_tokens - r.used_tokens;
    pack_left := pack_left + tl;
    packs := packs || jsonb_build_array(jsonb_build_object('grant_id', r.id, 'product_id', r.product_id, 'size', r.pool_tokens,
      'left', tl, 'ends_at', r.ends_at, 'funding', r.funding));
  end loop;

  allowance := free_left + pass_today_left + pack_left;
  bg_allow := free_bg_left + pass_bg_left + pack_left;
  select coalesce(sum(s.tokens), 0) into used_today from billing.daily_spend s join billing.token_grants g on g.id = s.grant_id
    where g.user_id = p_uid and s.day = d;
  used_today := used_today + ft;

  return jsonb_build_object(
    'enabled', billing.enabled(),
    'day', d,
    'coins', coalesce(w.coins, 0),
    'auto_exchange', coalesce(w.auto_exchange, false),
    'auto_exchange_product', coalesce(w.auto_exchange_product, 'pack_1m'),
    'free', jsonb_build_object('daily', (lim->>'daily')::bigint, 'monthly', (lim->>'monthly')::bigint,
        'today_used', ft, 'month_used', fm, 'left', free_left, 'bg_left', free_bg_left,
        'live_seconds_left', live_free_left, 'live_seconds_month', (lim->>'live_seconds_month')::int),
    'pass', pass,
    'pass_left', pass_left, 'pass_today_left', pass_today_left, 'pass_bg_left', pass_bg_left,
    'packs', packs, 'pack_left', pack_left,
    'queued_passes', (select coalesce(jsonb_agg(jsonb_build_object('grant_id', q.id, 'product_id', q.product_id, 'pool', q.pool_tokens,
        'rollover_cap', q.rollover_cap, 'starts_at', q.starts_at, 'ends_at', q.ends_at) order by q.starts_at), '[]'::jsonb)
      from billing.token_grants q where q.user_id = p_uid and q.kind = 'pass' and q.status = 'active' and q.starts_at > now()),
    'paid', (pass_left + pack_left) > 0,
    'allowance', allowance,
    'bg_allowance', bg_allow,
    'used_today', used_today,
    'ratio', case when allowance <= 0 then 1 else round(used_today::numeric / greatest(1, used_today + allowance), 3) end,
    'state', case when allowance <= 0 then 'limit'
                  when (pass_left + pack_left) = 0 and free_left < (lim->>'daily')::bigint * 0.2 then 'notice'
                  else 'ok' end,
    'live_seconds_left', live_free_left + floor((pass_today_left + pack_left) * 60.0 / tpm)::int,
    'tokens_per_reply', billing.num('billing_tokens_per_reply', 3700)::int,
    'coin_usd', billing.num('billing_coin_usd', 0.01));
end $$;

-- ---------------------------------------------------------------- buying with coins
-- Renewal / early renewal. A new pass bought while another is active QUEUES: it starts when the latest pass ends
-- (no overlap, nothing lost). A pass bought within the rollover window after the latest pass ended starts now.
-- Either way the renewed pass may carry up to 25% of the NEW pool from the previous pass's own (non-rollover) unused
-- tokens. The carry-over is settled when the new pass starts (billing.settle_passes), so the previous pass can still be
-- used until its last minute. Rolled tokens burn first, expire with the new period and never roll again.
create or replace function billing.grant_pass(p_uid uuid, p_product text, p_funding text, p_coins bigint, p_purchase uuid)
returns uuid language plpgsql security definer set search_path = billing, public as $$
declare prod billing.products; prev billing.token_grants; gid uuid; st timestamptz := now();
        win int := billing.num('billing_rollover_window_days', 7)::int; cap bigint := 0;
begin
  select * into prod from billing.products where id = p_product and kind = 'pass';
  if prod.id is null then raise exception 'unknown_pass'; end if;
  select * into prev from billing.token_grants
   where user_id = p_uid and kind = 'pass' and status = 'active' and ends_at > now() - make_interval(days => win)
   order by ends_at desc limit 1 for update;
  if prev.id is not null then
    st := greatest(now(), prev.ends_at);
    cap := floor(prod.tokens * billing.num('billing_rollover_pct', 0.25))::bigint;
  end if;
  insert into billing.token_grants(user_id, kind, product_id, pool_tokens, rollover_tokens, rollover_from, rollover_cap, rollover_settled,
                                   daily_ceiling, starts_at, ends_at, funding, coins_paid, purchase_id)
  values (p_uid, 'pass', prod.id, prod.tokens, 0, prev.id, cap, prev.id is null, prod.daily_ceiling, st, st + prod.validity,
          p_funding, coalesce(p_coins, 0), p_purchase)
  returning id into gid;
  perform billing.settle_passes(p_uid);
  return gid;
end $$;

-- Settles the carry-over of every renewal whose start has come: up to rollover_cap of the previous pass's own unused
-- tokens (0 if that pass was revoked). Called by grant_pass, consume, precheck and summary.
create or replace function billing.settle_passes(p_uid uuid) returns int
language plpgsql security definer set search_path = billing, public as $$
declare r record; prev billing.token_grants; base_left bigint; roll bigint; n int := 0;
begin
  for r in select * from billing.token_grants where user_id = p_uid and kind = 'pass' and not rollover_settled and starts_at <= now()
           order by starts_at for update loop
    select * into prev from billing.token_grants where id = r.rollover_from for update;
    roll := 0;
    if prev.id is not null and prev.status = 'active' then
      base_left := greatest(0, least(prev.pool_tokens - prev.used_tokens,
                                     prev.pool_tokens - prev.rollover_tokens - greatest(0, prev.used_tokens - prev.rollover_tokens)));
      roll := least(base_left, r.rollover_cap);
      update billing.token_grants set status = 'replaced', closed_at = now(), ends_at = least(ends_at, now()) where id = prev.id;
    end if;
    update billing.token_grants set rollover_tokens = roll, pool_tokens = pool_tokens + roll, rollover_settled = true,
      rollover_from = case when roll > 0 then rollover_from end
     where id = r.id;
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function billing.buy_with_coins(p_uid uuid, p_product text, p_auto boolean default false) returns jsonb
language plpgsql security definer set search_path = billing, public as $$
declare prod billing.products; w billing.wallets; gid uuid; coin_usd numeric := billing.num('billing_coin_usd', 0.01);
begin
  select * into prod from billing.products where id = p_product and active and kind in ('pack','pass');
  if prod.id is null or prod.price_coins is null then return jsonb_build_object('ok', false, 'reason', 'unknown_product'); end if;
  w := billing.wallet(p_uid);  -- locks the wallet row
  if w.coins < prod.price_coins then
    return jsonb_build_object('ok', false, 'reason', 'not_enough_coins', 'coins', w.coins, 'price_coins', prod.price_coins);
  end if;
  if prod.kind = 'pack' then
    insert into billing.token_grants(user_id, kind, product_id, pool_tokens, starts_at, ends_at, funding, coins_paid)
    values (p_uid, 'pack', prod.id, prod.tokens, now(), now() + prod.validity, 'coins', prod.price_coins) returning id into gid;
  else
    gid := billing.grant_pass(p_uid, prod.id, 'coins', prod.price_coins, null);
  end if;
  perform billing.add_coins(p_uid, -prod.price_coins, case when p_auto then 'auto_exchange' when prod.kind = 'pack' then 'pack' else 'pass' end,
                            prod.id, null, gid, prod.name);
  perform billing.post_ledger(jsonb_build_object(
    'entry_type', case when prod.kind = 'pack' then 'pack_purchase' else 'pass_purchase' end,
    'funding', 'coins', 'sku', prod.id, 'user_id', p_uid, 'coins', prod.price_coins, 'tokens', prod.tokens,
    'amount_usd', round(prod.price_coins * coin_usd, 4),
    'pass_days', case when prod.kind = 'pass' then greatest(1, ceil(extract(epoch from prod.validity) / 86400.0))::int end,
    'source_ref', 'billing:grant:' || gid,
    'note', prod.name || ' paid with coins' || case when p_auto then ' (auto-exchange)' else '' end));
  return jsonb_build_object('ok', true, 'grant_id', gid, 'product_id', prod.id, 'coins_left', w.coins - prod.price_coins);
end $$;

-- Auto-exchange: when the user switched it on and the paid balance runs low, buy their chosen pack with coins.
create or replace function billing.maybe_auto_exchange(p_uid uuid) returns jsonb
language plpgsql security definer set search_path = billing, public as $$
declare w billing.wallets; left_paid bigint; prod billing.products;
begin
  select * into w from billing.wallets where user_id = p_uid;
  if w.user_id is null or not w.auto_exchange then return null; end if;
  select * into prod from billing.products where id = w.auto_exchange_product;
  if prod.id is null or w.coins < coalesce(prod.price_coins, 0) then return null; end if;
  select coalesce(sum(pool_tokens - used_tokens), 0) into left_paid from billing.token_grants
   where user_id = p_uid and status = 'active' and kind = 'pack' and starts_at <= now() and ends_at > now();
  if left_paid >= billing.num('billing_auto_exchange_threshold', 20000) then return null; end if;
  return billing.buy_with_coins(p_uid, prod.id, true);
end $$;

-- ---------------------------------------------------------------- consume (burn order)
-- free daily -> pass pool (within the daily ceiling; bots/background at most 50% of it) -> packs, soonest expiry first.
create or replace function billing.consume(p_uid uuid, p_request_id text, p_weighted bigint, p_model text, p_source text,
                                           p_lane text default 'user', p_multiplier numeric default null) returns jsonb
language plpgsql security definer set search_path = billing, public as $$
declare
  mt record; mult numeric; tier text; cost bigint; need bigint; take bigint;
  bg boolean := coalesce(p_lane, 'user') = 'background' or coalesce(p_source, '') in ('bot-cloud');
  lim jsonb; d date := billing.today(); ft bigint; fbg bigint; fm bigint; free_left bigint;
  share numeric := least(1, greatest(0, billing.num('background_share', 0.3)));
  bgp numeric := least(1, greatest(0, billing.num('billing_bg_pass_share', 0.5)));
  t_free bigint := 0; t_pass bigint := 0; t_pack bigint := 0;
  r record; spent bigint; bgspent bigint; room bigint; prev jsonb; parts jsonb := '[]'::jsonb;
begin
  if p_uid is null or p_request_id is null or p_weighted is null or p_weighted < 0 then raise exception 'bad_request'; end if;
  perform billing.wallet(p_uid);  -- per-user lock: concurrent requests are charged one after another
  -- idempotent per request id (checked after the lock so a retry racing the original sees its row)
  select to_jsonb(c) into prev from billing.consumption c where request_id = p_request_id;
  if prev is not null then return prev || jsonb_build_object('duplicate', true); end if;
  perform billing.settle_passes(p_uid);

  if p_multiplier is not null and p_multiplier > 0 then mult := p_multiplier; tier := null;
  else select * into mt from billing.multiplier_for(p_model); mult := coalesce(mt.multiplier, 1); tier := coalesce(mt.tier, 'standard'); end if;
  cost := ceil(p_weighted * mult)::bigint;
  need := cost;

  -- 1. free daily (and the monthly cap)
  lim := billing.free_limits(p_uid);
  select coalesce(sum(tokens) filter (where day = d), 0), coalesce(sum(bg_tokens) filter (where day = d), 0), coalesce(sum(tokens), 0)
    into ft, fbg, fm from billing.free_usage where user_id = p_uid and day >= billing.month_start();
  free_left := greatest(0, least((lim->>'daily')::bigint - ft, (lim->>'monthly')::bigint - fm));
  if bg then free_left := greatest(0, least(free_left, floor((lim->>'daily')::bigint * share)::bigint - fbg)); end if;
  take := least(need, free_left);
  if take > 0 then
    insert into billing.free_usage(user_id, day, tokens, bg_tokens) values (p_uid, d, take, case when bg then take else 0 end)
    on conflict (user_id, day) do update set tokens = billing.free_usage.tokens + excluded.tokens,
      bg_tokens = billing.free_usage.bg_tokens + excluded.bg_tokens;
    t_free := take; need := need - take;
  end if;

  -- 2. pass pool within today's ceiling (soonest-ending pass first)
  if need > 0 then
    for r in select g.* from billing.token_grants g
             where g.user_id = p_uid and g.status = 'active' and g.kind = 'pass' and g.starts_at <= now() and g.ends_at > now()
               and g.used_tokens < g.pool_tokens
             order by g.ends_at for update loop
      exit when need <= 0;
      select coalesce(s.tokens, 0), coalesce(s.bg_tokens, 0) into spent, bgspent from billing.daily_spend s where s.grant_id = r.id and s.day = d;
      spent := coalesce(spent, 0); bgspent := coalesce(bgspent, 0);
      room := r.pool_tokens - r.used_tokens;
      if r.daily_ceiling is not null then room := least(room, r.daily_ceiling - spent); end if;
      if bg then room := least(room, floor(coalesce(r.daily_ceiling, r.pool_tokens) * bgp)::bigint - bgspent); end if;
      take := greatest(0, least(need, room));
      if take > 0 then
        update billing.token_grants set used_tokens = used_tokens + take where id = r.id;
        insert into billing.daily_spend(grant_id, day, tokens, bg_tokens) values (r.id, d, take, case when bg then take else 0 end)
        on conflict (grant_id, day) do update set tokens = billing.daily_spend.tokens + excluded.tokens,
          bg_tokens = billing.daily_spend.bg_tokens + excluded.bg_tokens;
        t_pass := t_pass + take; need := need - take;
        parts := parts || jsonb_build_array(jsonb_build_object('grant_id', r.id, 'tokens', take));
      end if;
    end loop;
  end if;

  -- 3. packs, soonest expiry first
  if need > 0 then
    for r in select g.* from billing.token_grants g
             where g.user_id = p_uid and g.status = 'active' and g.kind = 'pack' and g.starts_at <= now() and g.ends_at > now()
               and g.used_tokens < g.pool_tokens
             order by g.ends_at, g.created_at for update loop
      exit when need <= 0;
      take := least(need, r.pool_tokens - r.used_tokens);
      update billing.token_grants set used_tokens = used_tokens + take where id = r.id;
      insert into billing.daily_spend(grant_id, day, tokens, bg_tokens) values (r.id, d, take, case when bg then take else 0 end)
      on conflict (grant_id, day) do update set tokens = billing.daily_spend.tokens + excluded.tokens,
        bg_tokens = billing.daily_spend.bg_tokens + excluded.bg_tokens;
      t_pack := t_pack + take; need := need - take;
      parts := parts || jsonb_build_array(jsonb_build_object('grant_id', r.id, 'tokens', take));
    end loop;
  end if;

  insert into billing.consumption(request_id, user_id, source, lane, model, tier, multiplier, weighted_tokens, charged_tokens,
                                  free_tokens, pass_tokens, pack_tokens, unpaid_tokens, detail)
  values (p_request_id, p_uid, left(p_source, 20), case when bg then 'background' else 'user' end, left(p_model, 120), tier, mult,
          p_weighted, cost, t_free, t_pass, t_pack, need, jsonb_build_object('grants', parts));

  perform billing.maybe_auto_exchange(p_uid);

  return jsonb_build_object('request_id', p_request_id, 'multiplier', mult, 'tier', tier, 'charged_tokens', cost,
    'free_tokens', t_free, 'pass_tokens', t_pass, 'pack_tokens', t_pack, 'unpaid_tokens', need, 'duplicate', false);
end $$;

-- Live voice: free monthly minutes first, then 40k weighted per minute through the normal burn order.
-- Idempotent per heartbeat: request id live:<call_id>:<call_seconds after the beat>.
create or replace function billing.live_charge(p_uid uuid, p_call uuid, p_call_seconds int, p_added_seconds int) returns jsonb
language plpgsql security definer set search_path = billing, public as $$
declare rid text := 'live:' || p_call || ':' || coalesce(p_call_seconds, 0);
        lim jsonb; used int; free_s int := 0; paid_s int; tok bigint := 0; c jsonb;
        tpm numeric := greatest(1, billing.num('billing_live_tokens_per_minute', 40000));
begin
  if coalesce(p_added_seconds, 0) <= 0 then return jsonb_build_object('ok', true, 'charged', 0); end if;
  if exists (select 1 from billing.live_charges where request_id = rid) then return jsonb_build_object('ok', true, 'duplicate', true); end if;
  perform billing.wallet(p_uid);
  lim := billing.free_limits(p_uid);
  select coalesce(sum(live_seconds), 0) into used from billing.free_usage where user_id = p_uid and day >= billing.month_start();
  free_s := greatest(0, least(p_added_seconds, (lim->>'live_seconds_month')::int - used));
  if free_s > 0 then
    insert into billing.free_usage(user_id, day, live_seconds) values (p_uid, billing.today(), free_s)
    on conflict (user_id, day) do update set live_seconds = billing.free_usage.live_seconds + excluded.live_seconds;
  end if;
  paid_s := p_added_seconds - free_s;
  if paid_s > 0 then
    tok := ceil(paid_s * tpm / 60.0)::bigint;
    c := billing.consume(p_uid, rid, tok, 'live-voice', 'live', 'user', 1);
  end if;
  insert into billing.live_charges(request_id, user_id, call_id, seconds, free_seconds, paid_tokens)
  values (rid, p_uid, p_call, p_added_seconds, free_s, tok);
  return jsonb_build_object('ok', true, 'free_seconds', free_s, 'paid_tokens', tok, 'consume', c);
end $$;

-- ---------------------------------------------------------------- purchases (Sifalo)
create or replace function billing.mark_paid(p_purchase uuid, p_sid text, p_amount numeric, p_currency text, p_payment_type text, p_payload jsonb)
returns text language plpgsql security definer set search_path = billing, public as $$
declare pu billing.purchases; prod billing.products; total bigint; bonus bigint := 0; gid uuid; dev text; inv uuid;
        ref_coins bigint; ref_max int; n int; note text;
begin
  select * into pu from billing.purchases where id = p_purchase for update;
  if pu.id is null then return 'no_purchase'; end if;
  if pu.status in ('paid','reversed') then
    return case when pu.sifalo_sid = p_sid then 'already_paid' else 'purchase_paid_other_sid' end;
  end if;
  if p_sid is null or p_sid = '' then return 'no_sid'; end if;
  if exists (select 1 from billing.purchases where sifalo_sid = p_sid and id <> p_purchase) then
    update billing.purchases set result = 'sid_reused', last_checked_at = now() where id = p_purchase;
    return 'sid_reused';
  end if;
  if upper(coalesce(p_currency, '')) <> upper(pu.currency) then
    update billing.purchases set result = 'currency_mismatch', verify_payload = p_payload, last_checked_at = now() where id = p_purchase;
    return 'currency_mismatch';
  end if;
  if p_amount is null or round(p_amount * 100) <> round(pu.amount_usd * 100) then
    update billing.purchases set result = 'amount_mismatch', verify_payload = p_payload, last_checked_at = now() where id = p_purchase;
    return 'amount_mismatch';
  end if;

  select * into prod from billing.products where id = pu.product_id;
  if pu.kind = 'coins' then
    total := prod.coins + prod.bonus_coins;
    perform billing.add_coins(pu.user_id, prod.coins, 'topup', prod.id, pu.id, null, prod.name);
    if prod.bonus_coins > 0 then perform billing.add_coins(pu.user_id, prod.bonus_coins, 'bonus_ladder', prod.id, pu.id, null, 'Top-up bonus'); end if;
    -- First top-up doubled (max +100 coins): once per account and once per device.
    dev := pu.device_id;
    if not exists (select 1 from billing.first_bonus where user_id = pu.user_id)
       and (dev is null or not exists (select 1 from billing.first_bonus where device_id = dev))
       and not exists (select 1 from billing.purchases where user_id = pu.user_id and status in ('paid','reversed') and kind = 'coins' and id <> pu.id) then
      bonus := least(total, billing.num('billing_first_topup_bonus_max', 100)::bigint);
      if bonus > 0 then
        insert into billing.first_bonus(user_id, device_id, purchase_id, coins) values (pu.user_id, dev, pu.id, bonus);
        perform billing.add_coins(pu.user_id, bonus, 'bonus_first', prod.id, pu.id, null, 'First top-up doubled');
        total := total + bonus;
      end if;
    end if;
    note := prod.name || case when prod.bonus_coins + bonus > 0 then ' (incl. ' || (prod.bonus_coins + bonus) || ' bonus coins)' else '' end;
  else
    gid := billing.grant_pass(pu.user_id, prod.id, 'cash', 0, pu.id);
    total := 0;
    note := prod.name || ' paid with Sifalo';
  end if;

  update billing.purchases set status = 'paid', sifalo_sid = p_sid, payment_type = left(p_payment_type, 60), verify_payload = p_payload,
    paid_at = now(), coins_credited = total, grant_id = gid, result = 'paid', last_checked_at = now() where id = pu.id;

  perform billing.post_ledger(jsonb_build_object(
    'entry_type', case when pu.kind = 'coins' then 'coin_purchase' else 'pass_purchase' end,
    'funding', 'cash', 'sku', prod.id, 'user_id', pu.user_id, 'amount_usd', pu.amount_usd, 'coins', total,
    'tokens', case when pu.kind = 'pass' then prod.tokens else 0 end,
    'pass_days', case when pu.kind = 'pass' then greatest(1, ceil(extract(epoch from prod.validity) / 86400.0))::int end,
    'payment_method', left(p_payment_type, 60), 'external_ref', p_sid,
    'source_ref', 'billing:purchase:' || pu.id, 'note', note));

  -- Referral reward: the inviter earns coins when the invitee's FIRST purchase is paid. One per invitee and per
  -- invitee device; capped per inviter; self/same-device invites never pay.
  if not exists (select 1 from billing.purchases where user_id = pu.user_id and status in ('paid','reversed') and id <> pu.id)
     and not exists (select 1 from billing.referral_rewards where invitee_id = pu.user_id) then
    select inviter_id into inv from public.referrals
     where invitee_id = pu.user_id and kind = 'invite' and coalesce(reason, '') not in ('self','same_device','device_used')
     order by created_at limit 1;
    if inv is not null then
      ref_coins := billing.num('billing_referral_coins', 50)::bigint;
      ref_max := billing.num('billing_referral_max_per_inviter', 10)::int;
      select count(*) into n from billing.referral_rewards where inviter_id = inv and status = 'granted';
      if inv = pu.user_id or public.reward_same_device(inv, pu.user_id, dev)
         or (dev is not null and exists (select 1 from billing.referral_rewards where device_id = dev)) then
        insert into billing.referral_rewards(invitee_id, inviter_id, device_id, purchase_id, coins, status, reason)
        values (pu.user_id, inv, dev, pu.id, 0, 'refused', 'same_device') on conflict do nothing;
      elsif n >= ref_max or ref_coins <= 0 then
        insert into billing.referral_rewards(invitee_id, inviter_id, device_id, purchase_id, coins, status, reason)
        values (pu.user_id, inv, dev, pu.id, 0, 'refused', 'cap') on conflict do nothing;
      else
        insert into billing.referral_rewards(invitee_id, inviter_id, device_id, purchase_id, coins) values (pu.user_id, inv, dev, pu.id, ref_coins);
        perform billing.add_coins(inv, ref_coins, 'referral', null, pu.id, null, 'Invite reward: your friend made their first purchase');
        perform billing.post_ledger(jsonb_build_object('entry_type', 'reward_grant', 'funding', 'none', 'sku', 'referral_coins', 'user_id', inv,
          'coins', ref_coins, 'amount_usd', round(ref_coins * billing.num('billing_coin_usd', 0.01), 4),
          'source_ref', 'billing:referral:' || pu.user_id, 'note', 'Referral reward in coins (invitee first purchase)'));
        begin
          insert into public.user_inbox(user_id, kind, title, body)
          values (inv, 'reward_earned', 'Your invite paid off', '+' || ref_coins || ' SubMac Coins: someone you invited made their first purchase. Thanks for sharing SubMac!');
        exception when others then null;
        end;
      end if;
    end if;
  end if;
  return 'paid';
end $$;

-- Refund (only where the law requires it) or clawback (payment reversed by Sifalo/the wallet provider).
-- Takes back the coins credited by that purchase (as many as are left) and ends a pass bought with it.
create or replace function billing.reverse(p_purchase uuid, p_kind text, p_reason text, p_by text) returns jsonb
language plpgsql security definer set search_path = billing, public as $$
declare pu billing.purchases; w billing.wallets; take bigint := 0; short bigint := 0; g billing.token_grants; tok_left bigint := 0;
begin
  if p_kind not in ('refund','clawback') then raise exception 'kind must be refund or clawback'; end if;
  select * into pu from billing.purchases where id = p_purchase for update;
  if pu.id is null then return jsonb_build_object('ok', false, 'reason', 'no_purchase'); end if;
  if pu.status = 'reversed' then return jsonb_build_object('ok', true, 'reason', 'already_reversed'); end if;
  if pu.status <> 'paid' then return jsonb_build_object('ok', false, 'reason', 'not_paid'); end if;
  w := billing.wallet(pu.user_id);
  if pu.coins_credited > 0 then
    take := least(w.coins, pu.coins_credited);
    short := pu.coins_credited - take;
    if take > 0 then perform billing.add_coins(pu.user_id, -take, p_kind, pu.product_id, pu.id, null, left(coalesce(p_reason, p_kind), 200)); end if;
  end if;
  if pu.grant_id is not null then
    select * into g from billing.token_grants where id = pu.grant_id for update;
    tok_left := greatest(0, g.pool_tokens - g.used_tokens);
    update billing.token_grants set status = 'revoked', closed_at = now() where id = g.id and status = 'active';
  end if;
  update billing.purchases set status = 'reversed', reversed_at = now(), result = p_kind || ': ' || left(coalesce(p_reason, ''), 200) where id = pu.id;
  perform billing.post_ledger(jsonb_build_object('entry_type', p_kind, 'funding', 'cash', 'sku', pu.product_id, 'user_id', pu.user_id,
    'amount_usd', pu.amount_usd, 'coins', take, 'tokens', tok_left, 'external_ref', pu.sifalo_sid,
    'source_ref', 'billing:' || p_kind || ':' || pu.id,
    'note', coalesce(p_reason, p_kind) || case when short > 0 then ' | ' || short || ' coins already spent (shortfall)' else '' end
            || ' | by ' || coalesce(p_by, 'system')));
  -- A clawback that could not recover everything is worth a look.
  if short > 0 and p_kind = 'clawback' then
    begin
      perform public.flag_user(pu.user_id, 'payment_reversal', 'medium', 'billing', 'Payment reversed after coins were spent', jsonb_build_object('purchase', pu.id, 'shortfall_coins', short));
    exception when others then null;
    end;
  end if;
  return jsonb_build_object('ok', true, 'coins_taken', take, 'shortfall_coins', short, 'pass_tokens_revoked', tok_left);
end $$;

-- ============================================================================ public RPCs
-- ---- user (authenticated) ----
create or replace function public.billing_summary() returns jsonb
language plpgsql security definer set search_path = billing, public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'auth required' using errcode = '28000'; end if;
  if not billing.enabled() then return jsonb_build_object('enabled', false); end if;
  perform billing.settle_passes(me);
  return billing.entitlements(me) || jsonb_build_object(
    'products', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'kind', kind, 'name', name, 'price_usd', price_usd, 'price_coins', price_coins,
        'coins', coins, 'bonus_coins', bonus_coins, 'tokens', tokens, 'daily_ceiling', daily_ceiling,
        'validity_days', round(extract(epoch from validity) / 86400.0, 2), 'cash_ok', cash_ok, 'badge', badge) order by sort), '[]'::jsonb)
      from billing.products where active),
    'first_topup_bonus', not exists (select 1 from billing.first_bonus where user_id = me)
                         and not exists (select 1 from billing.purchases where user_id = me and kind = 'coins' and status in ('paid','reversed')),
    'first_topup_bonus_max', billing.num('billing_first_topup_bonus_max', 100)::int);
end $$;

create or replace function public.billing_history(p_limit int default 50) returns jsonb
language plpgsql stable security definer set search_path = billing, public as $$
declare me uuid := auth.uid(); n int := least(greatest(coalesce(p_limit, 50), 1), 200);
begin
  if me is null then raise exception 'auth required' using errcode = '28000'; end if;
  if not billing.enabled() then return jsonb_build_object('enabled', false); end if;
  return jsonb_build_object('enabled', true,
    'coins', (select coalesce(jsonb_agg(x order by x.created_at desc), '[]'::jsonb) from (
        select id, delta, balance_after, kind, product_id, note, created_at from billing.coin_transactions where user_id = me
        order by created_at desc limit n) x),
    'purchases', (select coalesce(jsonb_agg(x order by x.created_at desc), '[]'::jsonb) from (
        select id, product_id, kind, amount_usd, currency, status, payment_type, coins_credited, created_at, paid_at from billing.purchases
        where user_id = me order by created_at desc limit n) x),
    'grants', (select coalesce(jsonb_agg(x order by x.created_at desc), '[]'::jsonb) from (
        select id, kind, product_id, pool_tokens, rollover_tokens, used_tokens, daily_ceiling, starts_at, ends_at, funding, status, created_at
        from billing.token_grants where user_id = me order by created_at desc limit n) x));
end $$;

create or replace function public.billing_exchange(p_product text) returns jsonb
language plpgsql security definer set search_path = billing, public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'auth required' using errcode = '28000'; end if;
  if not billing.enabled() then return jsonb_build_object('ok', false, 'reason', 'billing_disabled'); end if;
  if not exists (select 1 from billing.products where id = p_product and kind = 'pack') then return jsonb_build_object('ok', false, 'reason', 'unknown_product'); end if;
  return billing.buy_with_coins(me, p_product, false);
end $$;

create or replace function public.billing_buy_pass(p_product text) returns jsonb
language plpgsql security definer set search_path = billing, public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'auth required' using errcode = '28000'; end if;
  if not billing.enabled() then return jsonb_build_object('ok', false, 'reason', 'billing_disabled'); end if;
  if not exists (select 1 from billing.products where id = p_product and kind = 'pass') then return jsonb_build_object('ok', false, 'reason', 'unknown_product'); end if;
  return billing.buy_with_coins(me, p_product, false);
end $$;

create or replace function public.billing_set_auto_exchange(p_on boolean, p_product text default null) returns jsonb
language plpgsql security definer set search_path = billing, public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'auth required' using errcode = '28000'; end if;
  if not billing.enabled() then return jsonb_build_object('ok', false, 'reason', 'billing_disabled'); end if;
  if p_product is not null and not exists (select 1 from billing.products where id = p_product and kind = 'pack' and active) then
    return jsonb_build_object('ok', false, 'reason', 'unknown_product');
  end if;
  perform billing.wallet(me);
  update billing.wallets set auto_exchange = coalesce(p_on, false), auto_exchange_product = coalesce(p_product, auto_exchange_product), updated_at = now()
   where user_id = me;
  return jsonb_build_object('ok', true, 'auto_exchange', coalesce(p_on, false), 'product', (select auto_exchange_product from billing.wallets where user_id = me));
end $$;

-- ---- service role (edge functions) ----
create or replace function public.billing_precheck(p_uid uuid) returns jsonb
language plpgsql security definer set search_path = billing, public as $$
declare e jsonb;
begin
  if not billing.enabled() then return jsonb_build_object('enabled', false); end if;
  perform billing.settle_passes(p_uid);
  e := billing.entitlements(p_uid);
  if (e->>'allowance')::bigint <= 0 or ((e->>'pass_today_left')::bigint + (e->>'pack_left')::bigint) < billing.num('billing_auto_exchange_threshold', 20000) then
    if billing.maybe_auto_exchange(p_uid) is not null then e := billing.entitlements(p_uid); end if;
  end if;
  return e;
end $$;

create or replace function public.billing_consume(p_uid uuid, p_request_id text, p_weighted bigint, p_model text, p_source text,
                                                  p_lane text default 'user', p_multiplier numeric default null) returns jsonb
language plpgsql security definer set search_path = billing, public as $$
begin
  if not billing.enabled() then return jsonb_build_object('enabled', false); end if;
  return billing.consume(p_uid, p_request_id, p_weighted, p_model, p_source, p_lane, p_multiplier);
end $$;

create or replace function public.billing_live_charge(p_uid uuid, p_call uuid, p_call_seconds int, p_added_seconds int) returns jsonb
language plpgsql security definer set search_path = billing, public as $$
declare c jsonb;
begin
  if not billing.enabled() then return jsonb_build_object('enabled', false); end if;
  c := billing.live_charge(p_uid, p_call, p_call_seconds, p_added_seconds);
  return c || jsonb_build_object('live_seconds_left', (billing.entitlements(p_uid)->>'live_seconds_left')::int);
end $$;

create or replace function public.billing_multipliers() returns jsonb
language sql stable security definer set search_path = billing, public as $$
  select jsonb_build_object('enabled', billing.enabled(), 'day', billing.today(), 'rows', coalesce(jsonb_agg(jsonb_build_object(
    'pattern', pattern, 'tier', tier, 'multiplier', multiplier, 'effective_from', effective_from) order by pattern, effective_from), '[]'::jsonb))
  from billing.model_multipliers where effective_from <= billing.today()
$$;

create or replace function public.billing_create_purchase(p_uid uuid, p_product text, p_device text default null) returns jsonb
language plpgsql security definer set search_path = billing, public as $$
declare prod billing.products; n int; pid uuid;
        dev text := case when p_device ~ '^[A-Za-z0-9_-]{6,64}$' then p_device end;
begin
  if not billing.enabled() then return jsonb_build_object('ok', false, 'reason', 'billing_disabled'); end if;
  select * into prod from billing.products where id = p_product and active and cash_ok and price_usd is not null;
  if prod.id is null then return jsonb_build_object('ok', false, 'reason', 'unknown_product'); end if;
  select count(*) into n from billing.purchases where user_id = p_uid and created_at > now() - interval '1 hour';
  if n >= billing.num('billing_max_pending_per_hour', 10) then return jsonb_build_object('ok', false, 'reason', 'rate_limited'); end if;
  insert into billing.purchases(user_id, product_id, kind, amount_usd, device_id)
  values (p_uid, prod.id, case when prod.kind = 'coins' then 'coins' else 'pass' end, prod.price_usd, dev) returning id into pid;
  return jsonb_build_object('ok', true, 'purchase_id', pid, 'amount_usd', prod.price_usd, 'currency', 'USD', 'product_id', prod.id, 'name', prod.name);
end $$;

create or replace function public.billing_set_checkout_key(p_purchase uuid, p_key text) returns void
language sql security definer set search_path = billing, public as $$
  update billing.purchases set checkout_key = left(p_key, 500) where id = p_purchase and status = 'pending'
$$;

create or replace function public.billing_find_purchase(p_purchase uuid default null, p_key text default null, p_uid uuid default null) returns jsonb
language sql stable security definer set search_path = billing, public as $$
  select to_jsonb(x) from (select id, user_id, product_id, kind, amount_usd, currency, status, sifalo_sid, created_at, paid_at
    from billing.purchases
    where (p_purchase is null or id = p_purchase) and (p_key is null or checkout_key = p_key) and (p_uid is null or user_id = p_uid)
      and (p_purchase is not null or p_key is not null)
    order by created_at desc limit 1) x
$$;

create or replace function public.billing_mark_paid(p_purchase uuid, p_sid text, p_amount numeric, p_currency text, p_payment_type text, p_payload jsonb)
returns text language plpgsql security definer set search_path = billing, public as $$
begin
  -- Deliberately NOT gated on billing_enabled: a payment Sifalo confirmed must always be credited once.
  return billing.mark_paid(p_purchase, p_sid, p_amount, p_currency, p_payment_type, p_payload);
end $$;

create or replace function public.billing_mark_failed(p_purchase uuid, p_payload jsonb) returns void
language sql security definer set search_path = billing, public as $$
  update billing.purchases set status = 'failed', verify_payload = p_payload, result = 'failed', last_checked_at = now()
  where id = p_purchase and status = 'pending'
$$;

create or replace function public.billing_touch_purchase(p_purchase uuid, p_result text) returns void
language sql security definer set search_path = billing, public as $$
  update billing.purchases set last_checked_at = now(), result = coalesce(left(p_result, 60), result) where id = p_purchase
$$;

create or replace function public.billing_pending_purchases(p_since_hours int default 72, p_uid uuid default null, p_limit int default 20) returns jsonb
language sql stable security definer set search_path = billing, public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'user_id', user_id, 'created_at', created_at) order by created_at), '[]'::jsonb) from (
    select id, user_id, created_at from billing.purchases
    where status = 'pending' and created_at > now() - make_interval(hours => least(greatest(coalesce(p_since_hours, 72), 1), 24 * 30))
      and (p_uid is null or user_id = p_uid)
    order by created_at limit least(greatest(coalesce(p_limit, 20), 1), 100)) x
$$;

create or replace function public.billing_reverse(p_purchase uuid, p_kind text, p_reason text, p_by text default 'owner') returns jsonb
language sql security definer set search_path = billing, public as $$
  select billing.reverse(p_purchase, p_kind, p_reason, p_by)
$$;

-- Owner tool: give a user a pack or pass (support, compensation). Posted as reward_grant.
create or replace function public.billing_grant_admin(p_uid uuid, p_product text, p_note text default null) returns jsonb
language plpgsql security definer set search_path = billing, public as $$
declare prod billing.products; gid uuid;
begin
  select * into prod from billing.products where id = p_product and kind in ('pack','pass');
  if prod.id is null then return jsonb_build_object('ok', false, 'reason', 'unknown_product'); end if;
  if prod.kind = 'pack' then
    insert into billing.token_grants(user_id, kind, product_id, pool_tokens, starts_at, ends_at, funding)
    values (p_uid, 'pack', prod.id, prod.tokens, now(), now() + prod.validity, 'admin') returning id into gid;
  else
    gid := billing.grant_pass(p_uid, prod.id, 'admin', 0, null);
  end if;
  perform billing.post_ledger(jsonb_build_object('entry_type', 'reward_grant', 'funding', 'none', 'sku', prod.id, 'user_id', p_uid,
    'tokens', prod.tokens, 'amount_usd', 0, 'source_ref', 'billing:grant:' || gid, 'note', coalesce(p_note, 'Granted by owner')));
  return jsonb_build_object('ok', true, 'grant_id', gid);
end $$;

-- Retries finance.ledger rows that waited in the outbox (run after the finance schema is fixed/created).
create or replace function public.billing_sync_ledger() returns jsonb
language plpgsql security definer set search_path = billing, public as $$
declare r record; ok int := 0; bad int := 0;
begin
  for r in select * from billing.ledger_outbox where posted_at is null order by id limit 500 loop
    begin
      perform finance.ledger_add_row(r.entry || jsonb_build_object('product', 'agent', 'created_by', 'billing'));
      update billing.ledger_outbox set posted_at = now(), error = null where id = r.id; ok := ok + 1;
    exception when unique_violation then
      update billing.ledger_outbox set posted_at = now(), error = 'already in ledger' where id = r.id; ok := ok + 1;
    when others then
      update billing.ledger_outbox set error = left(sqlerrm, 300), attempts = attempts + 1 where id = r.id; bad := bad + 1;
    end;
  end loop;
  return jsonb_build_object('posted', ok, 'failed', bad);
end $$;

-- ---------------------------------------------------------------- grants on functions
do $$ declare f text; begin
  -- internal billing.* functions: service role only
  for f in select p.oid::regprocedure::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'billing' loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
  -- service-only public wrappers
  for f in select p.oid::regprocedure::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('billing_precheck','billing_consume','billing_live_charge','billing_multipliers',
             'billing_create_purchase','billing_set_checkout_key','billing_find_purchase','billing_mark_paid','billing_mark_failed',
             'billing_touch_purchase','billing_pending_purchases','billing_reverse','billing_grant_admin','billing_sync_ledger') loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
  -- user RPCs: signed-in users only (each checks auth.uid())
  for f in select p.oid::regprocedure::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('billing_summary','billing_history','billing_exchange','billing_buy_pass','billing_set_auto_exchange') loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
end $$;
