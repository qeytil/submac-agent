-- Telesia billing v2 tests (plain PostgreSQL): usage_gate / usage_charge (daily caps, spending order, expiry, idempotency,
-- EAT reset, bots, Live), payments RPCs and the ledger. Run after tests/billing_stubs.sql + the billing migrations
-- (tests/run_billing_tests.sh). Each block raises on the first failed assertion. NEVER run against the real project.
--
-- Time: billing.clock() reads the session setting billing.test_now, so tests move the clock instead of the rows.

\set ON_ERROR_STOP 1
set client_min_messages = warning;

drop schema if exists bt cascade;
create schema bt;
create table bt.results (n serial, name text);
create function bt.eq(label text, got anyelement, want anyelement) returns void language plpgsql as $$
begin
  if got is distinct from want then raise exception 'ASSERT FAILED [%]: got %, want %', label, got, want; end if;
end $$;
create function bt.ok(label text, cond boolean) returns void language plpgsql as $$
begin
  if cond is not true then raise exception 'ASSERT FAILED [%]', label; end if;
end $$;
create function bt.pass(name text) returns void language sql as $$ insert into bt.results(name) values (name) $$;
create function bt.enable(on_ boolean) returns void language sql as $$
  insert into public.ai_settings(key, value) values ('billing_enabled', to_jsonb(on_)) on conflict (key) do update set value = excluded.value
$$;
create function bt.at(ts text) returns void language sql as $$ select set_config('billing.test_now', ts, false) $$;
create function bt.as_user(u uuid) returns void language sql as $$ select set_config('request.jwt.claim.sub', coalesce(u::text, ''), false) $$;
create function bt.gate(u uuid, src text default 'chat') returns jsonb language sql as $$ select public.usage_gate(u, src) $$;
create function bt.charge(u uuid, n bigint, rid text, src text default 'chat') returns jsonb language sql as $$
  select public.usage_charge(u, n, 0, src, rid)
$$;
create function bt.today_left(u uuid, src text default 'chat') returns bigint language sql as $$ select (public.usage_gate(u, src)->>'today_left')::bigint $$;
create function bt.balanced() returns boolean language sql as $$ select public.billing_ledger_check() = '[]'::jsonb $$;
create function bt.pkg(u uuid, plan text default 'weekly') returns uuid language sql as $$
  select (public.billing_adjust(u, plan, null, 'test')->>'subscription_id')::uuid
$$;
create function bt.payg(u uuid, n bigint) returns uuid language sql as $$
  select (public.billing_adjust(u, 'payg', n, 'test')->>'balance_id')::uuid
$$;

-- fixed test settings (independent of the live defaults)
insert into public.ai_settings(key, value) values ('billing_provider_env', '"live"') on conflict (key) do update set value = excluded.value;
select bt.enable(true);
insert into public.ai_settings(key, value) values ('billing_bot_share', '0.5'), ('billing_live_tokens_per_minute', '40000'),
  ('billing_reply_cap_tokens', '8192') on conflict (key) do update set value = excluded.value;
update billing.plans set daily_tokens = 60000, total_tokens = 1000000, active = true where id = 'free';

-- ============================================================ 01 access: server-only functions, user RPCs need sign-in
do $$ declare f text; begin
  foreach f in array array['usage_gate','usage_charge','usage_charge_enqueue','billing_is_on','billing_payment_create',
                            'billing_payment_paid','billing_payment_reverse','billing_adjust','billing_ledger_check','billing_payment_find',
                            'billing_payment_pending','billing_charge_retry_drain','billing_sync_ledger','billing_renewal_reminders',
                            'billing_plan_update','billing_admin_payments'] loop
    perform bt.ok(f || ' not for authenticated', not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = f and has_function_privilege('authenticated', p.oid, 'execute')));
    perform bt.ok(f || ' not for anon', not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = f and has_function_privilege('anon', p.oid, 'execute')));
    perform bt.ok(f || ' for service_role', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = f and has_function_privilege('service_role', p.oid, 'execute')));
    perform bt.ok(f || ' security definer', (select bool_and(prosecdef) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = f));
  end loop;
  perform bt.ok('billing_usage for authenticated', (select bool_and(has_function_privilege('authenticated', p.oid, 'execute'))
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname in ('billing_usage','billing_activity','billing_deletion_warning')));
  perform bt.ok('billing_usage not anon', not (select bool_or(has_function_privilege('anon', p.oid, 'execute'))
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname in ('billing_usage','billing_activity','billing_deletion_warning')));
  perform bt.ok('no billing.* function for app users', not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'billing' and (has_function_privilege('authenticated', p.oid, 'execute') or has_function_privilege('anon', p.oid, 'execute'))));
  perform bt.ok('new tables closed to app users', not exists (select 1 from pg_tables where schemaname = 'billing'
    and tablename in ('plans','payments','subscriptions','token_balances','usage_ledger','usage_daily','usage_requests','charge_queue','ledger_outbox')
    and (has_table_privilege('authenticated', format('billing.%I', tablename), 'select') or has_table_privilege('anon', format('billing.%I', tablename), 'select'))));
  perform bt.pass('01 access');
end $$;

-- ============================================================ 02 billing off: gate allows, charge writes nothing
do $$ declare u uuid := '00000000-0000-0000-0000-000000000002'; g jsonb; c jsonb; begin
  perform bt.enable(false);
  g := bt.gate(u);
  perform bt.eq('off allow', (g->>'allow')::boolean, true);
  perform bt.eq('off enabled', (g->>'enabled')::boolean, false);
  c := bt.charge(u, 5000, 'off-1');
  perform bt.eq('off charge enabled', (c->>'enabled')::boolean, false);
  perform bt.eq('off no ledger', (select count(*) from billing.usage_ledger where user_id = u), 0::bigint);
  perform bt.eq('off no request row', (select count(*) from billing.usage_requests where user_id = u), 0::bigint);
  perform bt.enable(true);
  perform bt.pass('02 billing off is inert');
end $$;

-- ============================================================ 03 free daily cap + EAT day reset
do $$ declare u uuid := '00000000-0000-0000-0000-000000000003'; g jsonb; c jsonb; begin
  perform bt.at('2026-11-10 20:59:59+00');           -- 23:59:59 EAT, 10 Nov
  g := bt.gate(u);
  perform bt.eq('fresh free today', (g->>'today_left')::bigint, 60000::bigint);
  perform bt.eq('plan free', g->>'plan', 'free');
  perform bt.eq('resets at EAT midnight', (g->>'resets_at')::timestamptz, '2026-11-10 21:00:00+00'::timestamptz);
  perform bt.eq('reply cap = min(8192, left)', (g->>'reply_cap')::bigint, 8192::bigint);
  c := bt.charge(u, 50000, 'r3-1');
  perform bt.eq('charged free', (c->>'free')::bigint, 50000::bigint);
  perform bt.eq('left 10k', (c->>'today_left')::bigint, 10000::bigint);
  perform bt.eq('reply cap shrinks to what is left', (bt.gate(u)->>'reply_cap')::bigint, 8192::bigint);
  c := bt.charge(u, 9000, 'r3-2');
  perform bt.eq('reply cap = 1000 left', (bt.gate(u)->>'reply_cap')::bigint, 1000::bigint);
  c := bt.charge(u, 4000, 'r3-3');                    -- overrun: 1000 free, 3000 unpaid
  perform bt.eq('overrun free part', (c->>'free')::bigint, 1000::bigint);
  perform bt.eq('overrun unpaid', (c->>'unpaid')::bigint, 3000::bigint);
  g := bt.gate(u);
  perform bt.eq('deny at 0', (g->>'allow')::boolean, false);
  perform bt.eq('limit_daily (month left)', g->>'code', 'limit_daily');
  perform bt.eq('reply cap 0 when denied', (g->>'reply_cap')::bigint, 0::bigint);
  perform bt.at('2026-11-10 21:00:00+00');           -- 00:00 EAT, 11 Nov: new day
  g := bt.gate(u);
  perform bt.eq('reset at EAT midnight', (g->>'today_left')::bigint, 60000::bigint);
  perform bt.eq('next reset', (g->>'resets_at')::timestamptz, '2026-11-11 21:00:00+00'::timestamptz);
  perform bt.at('2026-11-10 23:30:00+00');           -- 02:30 EAT 11 Nov (UTC still 10 Nov): same EAT day
  perform bt.eq('same EAT day after UTC midnight-ish', bt.today_left(u), 60000::bigint);
  perform bt.at('2026-11-11 20:00:00+00');           -- 23:00 EAT 11 Nov, UTC 11 Nov: no UTC reset at 00:00 UTC
  c := bt.charge(u, 60000, 'r3-4');
  perform bt.at('2026-11-11 21:30:00+00');           -- 00:30 EAT 12 Nov (UTC still 11 Nov)
  perform bt.eq('EAT not UTC', bt.today_left(u), 60000::bigint);
  perform bt.pass('03 free daily cap + EAT reset');
end $$;

-- ============================================================ 04 free monthly cap
do $$ declare u uuid := '00000000-0000-0000-0000-000000000004'; g jsonb; begin
  update billing.plans set total_tokens = 100000 where id = 'free';
  perform bt.at('2026-11-05 09:00:00+00');
  perform bt.charge(u, 60000, 'r4-1');
  perform bt.at('2026-11-06 09:00:00+00');
  perform bt.eq('month cap limits day 2', bt.today_left(u), 40000::bigint);
  perform bt.charge(u, 40000, 'r4-2');
  g := bt.gate(u);
  perform bt.eq('month used: limit_total', g->>'code', 'limit_total');
  perform bt.eq('total 0', (g->>'total_left')::bigint, 0::bigint);
  perform bt.at('2026-11-30 21:00:00+00');           -- 00:00 EAT 1 Dec: new EAT month
  perform bt.eq('new EAT month', bt.today_left(u), 60000::bigint);
  update billing.plans set total_tokens = 1000000 where id = 'free';
  perform bt.pass('04 free monthly cap');
end $$;

-- ============================================================ 05 spending order: free -> package (daily) -> PAYG soonest-expiring
do $$ declare u uuid := '00000000-0000-0000-0000-000000000005'; s uuid; b_late uuid; b_soon uuid; c jsonb; begin
  perform bt.at('2026-11-12 06:00:00+00');
  s := bt.pkg(u, 'weekly');                          -- 200k/day, 700k total
  b_late := bt.payg(u, 1000000);                     -- expires +12 months
  insert into billing.token_balances(user_id, amount, left_tokens, expires_at, source) values (u, 500000, 500000, '2026-12-01 00:00+00', 'admin')
    returning id into b_soon;
  insert into billing.usage_ledger(user_id, kind, ref, bucket, balance_id, tokens) values (u, 'grant', 'test', 'payg', b_soon, 500000);
  perform bt.eq('plan weekly', bt.gate(u)->>'plan', 'weekly');
  perform bt.eq('today = free + pkg day + payg', bt.today_left(u), (60000 + 200000 + 1500000)::bigint);
  c := bt.charge(u, 50000, 'r5-1');
  perform bt.eq('1st from free', (c->>'free')::bigint, 50000::bigint);
  perform bt.eq('1st no package', (c->>'package')::bigint, 0::bigint);
  c := bt.charge(u, 100000, 'r5-2');                 -- 10k free + 90k package
  perform bt.eq('2nd free rest', (c->>'free')::bigint, 10000::bigint);
  perform bt.eq('2nd package', (c->>'package')::bigint, 90000::bigint);
  c := bt.charge(u, 200000, 'r5-3');                 -- 110k package (daily done) + 90k PAYG soonest
  perform bt.eq('3rd package to daily', (c->>'package')::bigint, 110000::bigint);
  perform bt.eq('3rd payg', (c->>'payg')::bigint, 90000::bigint);
  perform bt.eq('soonest-expiring payg first', (select left_tokens from billing.token_balances where id = b_soon), 410000::bigint);
  perform bt.eq('later payg untouched', (select left_tokens from billing.token_balances where id = b_late), 1000000::bigint);
  perform bt.eq('package total_left', (select total_left from billing.subscriptions where id = s), 500000::bigint);
  c := bt.charge(u, 500000, 'r5-4');
  perform bt.eq('spills to next payg', (select left_tokens from billing.token_balances where id = b_late), 910000::bigint);
  perform bt.eq('soon one empty', (select left_tokens from billing.token_balances where id = b_soon), 0::bigint);
  perform bt.ok('ledger balanced', bt.balanced());
  perform bt.pass('05 spending order');
end $$;

-- ============================================================ 06 package daily amount, total, two packages soonest-ending first
do $$ declare u uuid := '00000000-0000-0000-0000-000000000006'; s1 uuid; g jsonb; c jsonb; begin
  update billing.plans set active = false where id = 'free';
  perform bt.at('2026-11-12 06:00:00+00');
  g := bt.gate(u);
  perform bt.eq('nothing at all: no_plan', g->>'code', 'no_plan');
  s1 := bt.pkg(u, 'weekly');
  c := bt.charge(u, 250000, 'r6-1');
  perform bt.eq('only the daily amount', (c->>'package')::bigint, 200000::bigint);
  perform bt.eq('rest unpaid', (c->>'unpaid')::bigint, 50000::bigint);
  g := bt.gate(u);
  perform bt.eq('daily used: limit_daily', g->>'code', 'limit_daily');
  perform bt.eq('total left shown', (g->>'total_left')::bigint, 500000::bigint);
  perform bt.at('2026-11-12 21:00:00+00');           -- next EAT day
  perform bt.eq('next day: daily again', bt.today_left(u), 200000::bigint);
  perform bt.charge(u, 200000, 'r6-2');
  perform bt.at('2026-11-13 21:00:00+00');
  perform bt.charge(u, 200000, 'r6-3');
  perform bt.at('2026-11-14 21:00:00+00');
  perform bt.eq('total caps the day', bt.today_left(u), 100000::bigint);
  perform bt.charge(u, 100000, 'r6-4');
  perform bt.at('2026-11-15 21:00:00+00');
  g := bt.gate(u);
  perform bt.eq('total used: limit_total', g->>'code', 'limit_total');
  perform bt.ok('ledger balanced', bt.balanced());
  update billing.plans set active = true where id = 'free';
  perform bt.pass('06 package daily amount + total');
end $$;

do $$ declare u uuid := '00000000-0000-0000-0000-000000000016'; a uuid; b uuid; c jsonb; begin
  update billing.plans set active = false where id = 'free';
  perform bt.at('2026-11-12 06:00:00+00');
  a := bt.pkg(u, 'monthly');                          -- now .. +30d
  b := bt.pkg(u, 'weekly');                           -- queued after the monthly (no overlap)
  perform bt.eq('second package queued', (select starts_at from billing.subscriptions where id = b), (select ends_at from billing.subscriptions where id = a));
  perform bt.eq('only the running one counts', bt.today_left(u), 250000::bigint);
  perform bt.at('2026-12-12 06:00:01+00');            -- monthly over, weekly running
  perform bt.eq('queued one starts', bt.today_left(u), 200000::bigint);
  perform bt.eq('plan weekly now', bt.gate(u)->>'plan', 'weekly');
  -- two overlapping packages (admin insert): the one that ends first pays first
  insert into billing.subscriptions(user_id, plan_id, starts_at, ends_at, daily_amount, total_amount, total_left, source)
  values (u, 'weekly', '2026-12-12 00:00+00', '2026-12-14 00:00+00', 1000, 1000, 1000, 'admin') returning id into a;
  insert into billing.usage_ledger(user_id, kind, ref, bucket, subscription_id, tokens) values (u, 'grant', 'test', 'package', a, 1000);
  c := bt.charge(u, 1500, 'r16-1');
  perform bt.eq('soonest-ending package first', (select total_left from billing.subscriptions where id = a), 0::bigint);
  perform bt.eq('then the other', (select total_left from billing.subscriptions where id = b), (700000 - 500)::bigint);
  perform bt.ok('ledger balanced', bt.balanced());
  update billing.plans set active = true where id = 'free';
  perform bt.pass('06b queued + soonest-ending packages');
end $$;

-- ============================================================ 07 bots: at most 50% of each daily amount
do $$ declare u uuid := '00000000-0000-0000-0000-000000000007'; c jsonb; g jsonb; begin
  perform bt.at('2026-11-12 06:00:00+00');
  perform bt.pkg(u, 'weekly');                        -- bot share: free 30k + package 100k
  perform bt.eq('bot today left', bt.today_left(u, 'bot'), 130000::bigint);
  c := bt.charge(u, 200000, 'r7-1', 'bot-cloud');
  perform bt.eq('bot free share', (c->>'free')::bigint, 30000::bigint);
  perform bt.eq('bot package share', (c->>'package')::bigint, 100000::bigint);
  perform bt.eq('bot overrun unpaid', (c->>'unpaid')::bigint, 70000::bigint);
  g := bt.gate(u, 'background');
  perform bt.eq('bot denied', (g->>'allow')::boolean, false);
  perform bt.eq('bot code', g->>'code', 'limit_daily');
  perform bt.eq('bot reason', g->>'reason', 'bot_share');
  g := bt.gate(u, 'chat');
  perform bt.eq('user lane still served', (g->>'allow')::boolean, true);
  perform bt.eq('user lane left', (g->>'today_left')::bigint, (30000 + 100000)::bigint);
  perform bt.charge(u, 1000, 'r7-2', 'chat');
  perform bt.payg(u, 1000000);
  perform bt.eq('bot can use PAYG', bt.today_left(u, 'bot'), 1000000::bigint);
  perform bt.pass('07 bot share');
end $$;

-- ============================================================ 08 expiry
do $$ declare u uuid := '00000000-0000-0000-0000-000000000008'; b uuid; g jsonb; begin
  update billing.plans set active = false where id = 'free';
  perform bt.at('2026-11-12 06:00:00+00');
  perform bt.pkg(u, 'weekly');
  insert into billing.token_balances(user_id, amount, left_tokens, expires_at, source) values (u, 300000, 300000, '2026-11-15 00:00+00', 'admin') returning id into b;
  insert into billing.usage_ledger(user_id, kind, ref, bucket, balance_id, tokens) values (u, 'grant', 'test', 'payg', b, 300000);
  perform bt.eq('before expiry', bt.today_left(u), 500000::bigint);
  perform bt.at('2026-11-15 00:00:00+00');            -- balance expired at this instant
  perform bt.eq('payg expired', bt.today_left(u), 200000::bigint);
  perform bt.eq('expired payg not charged', (bt.charge(u, 250000, 'r8-1')->>'payg')::bigint, 0::bigint);
  perform bt.at('2026-11-19 06:00:00+00');            -- weekly ended at 11-19 06:00
  g := bt.gate(u);
  perform bt.eq('all expired, no free plan: no_plan', g->>'code', 'no_plan');
  perform bt.eq('plan back to free', g->>'plan', 'free');
  update billing.plans set active = true where id = 'free';
  perform bt.pass('08 expiry');
end $$;

-- ============================================================ 09 idempotency by request_id
do $$ declare u uuid := '00000000-0000-0000-0000-000000000009'; v uuid := '00000000-0000-0000-0000-000000000099'; c1 jsonb; c2 jsonb; begin
  perform bt.at('2026-11-12 06:00:00+00');
  c1 := public.usage_charge(u, 1000, 500, 'chat', 'same-id');
  c2 := public.usage_charge(u, 9999, 9999, 'chat', 'same-id');
  perform bt.eq('first not duplicate', (c1->>'duplicate')::boolean, false);
  perform bt.eq('retry is duplicate', (c2->>'duplicate')::boolean, true);
  perform bt.eq('retry same charge', (c2->>'charged')::bigint, 1500::bigint);
  perform bt.eq('charged once', (select -sum(tokens) from billing.usage_ledger where user_id = u and kind = 'charge'), 1500::numeric);
  perform bt.eq('day counter once', (select tokens from billing.usage_daily where user_id = u and bucket = 'free'), 1500::bigint);
  perform bt.eq('other user same id refused', public.usage_charge(v, 10, 0, 'chat', 'same-id')->>'reason', 'request_id_conflict');
  perform bt.eq('bad id', public.usage_charge(u, 10, 0, 'chat', '  ')->>'reason', 'bad_request');
  perform bt.eq('negative', public.usage_charge(u, -1, 0, 'chat', 'neg')->>'reason', 'bad_request');
  begin
    update billing.usage_ledger set tokens = 0 where user_id = u;
    raise exception 'ledger update allowed';
  exception when others then
    perform bt.ok('ledger append-only', sqlerrm like '%append-only%');
  end;
  begin
    delete from billing.usage_requests where user_id = u;
    raise exception 'request delete allowed';
  exception when others then
    perform bt.ok('requests append-only', sqlerrm like '%append-only%');
  end;
  perform bt.pass('09 idempotency');
end $$;

-- ============================================================ 10 Live per minute (source 'live', tokens_in = seconds)
do $$ declare u uuid := '00000000-0000-0000-0000-000000000010'; c jsonb; begin
  perform bt.at('2026-11-12 06:00:00+00');
  c := public.usage_charge(u, 30, 999, 'live', 'live:call1:30');
  perform bt.eq('30 s = 20k', (c->>'charged')::bigint, 20000::bigint);
  update public.ai_settings set value = '60000' where key = 'billing_live_tokens_per_minute';
  c := public.usage_charge(u, 61, 0, 'live', 'live:call1:91');
  perform bt.eq('61 s at 60k/min rounds up', (c->>'tokens')::bigint, 61000::bigint);
  update public.ai_settings set value = '40000' where key = 'billing_live_tokens_per_minute';
  perform bt.pass('10 live per minute');
end $$;

-- ============================================================ 11 payments: quote, idempotency, double tap, credit once, reverse
do $$ declare u uuid := '00000000-0000-0000-0000-000000000011'; r jsonb; r2 jsonb; pid uuid; pid2 uuid; s uuid; begin
  perform bt.at('2026-11-12 06:00:00+00');
  r := public.billing_payment_create(u, 'payg', 3000000, null, 'sifalo', 'idem-key-0001', 'checkout|payg|3000000');
  perform bt.eq('payg price', (r->>'amount_usd')::numeric, 6.00);
  perform bt.eq('payg tokens', (r->>'tokens')::bigint, 3000000::bigint);
  pid := (r->>'purchase_id')::uuid;
  r2 := public.billing_payment_create(u, 'payg', 3000000, null, 'sifalo', 'idem-key-0001', 'checkout|payg|3000000');
  perform bt.eq('same key replays', (r2->>'purchase_id')::uuid, pid);
  perform bt.eq('replay flag', (r2->>'replay')::boolean, true);
  perform bt.eq('same key other amount', public.billing_payment_create(u, 'payg', 5000000, null, 'sifalo', 'idem-key-0001', 'checkout|payg|5000000')->>'reason', 'idempotency_key_reused');
  perform bt.eq('bad payg amount', public.billing_payment_create(u, 'payg', 1234567)->>'reason', 'unknown_product');
  perform bt.eq('too small', public.billing_payment_create(u, 'payg', 100000)->>'reason', 'unknown_product');
  perform bt.eq('inactive plan', public.billing_payment_create(u, 'monthly_plus')->>'reason', 'unknown_product');
  perform bt.eq('free not for sale', public.billing_payment_create(u, 'free')->>'reason', 'unknown_product');
  r := public.billing_payment_create(u, 'weekly', null, null, 'sifalo', null, 'checkout|weekly');
  r2 := public.billing_payment_create(u, 'weekly', null, null, 'sifalo', null, 'checkout|weekly');
  perform bt.eq('double tap same payment', (r2->>'purchase_id'), (r->>'purchase_id'));
  perform bt.eq('weekly price', (r->>'amount_usd')::numeric, 1.25);
  pid2 := (r->>'purchase_id')::uuid;
  -- credit
  perform bt.eq('amount mismatch', public.billing_payment_paid(pid, 'sifalo', 'SID1', 5.99, 'USD', 'edahab', '{}'), 'amount_mismatch');
  perform bt.eq('currency mismatch', public.billing_payment_paid(pid, 'sifalo', 'SID1', 6.00, 'SOS', 'edahab', '{}'), 'currency_mismatch');
  perform bt.eq('provider mismatch', public.billing_payment_paid(pid, 'fakepay', 'SID1', 6.00, 'USD', 'edahab', '{}'), 'provider_mismatch');
  perform bt.eq('no sid', public.billing_payment_paid(pid, 'sifalo', '', 6.00, 'USD', 'edahab', '{}'), 'no_sid');
  perform bt.eq('paid', public.billing_payment_paid(pid, 'sifalo', 'SID1', 6.00, 'USD', 'edahab', '{}'), 'paid');
  perform bt.eq('paid again', public.billing_payment_paid(pid, 'sifalo', 'SID1', 6.00, 'USD', 'edahab', '{}'), 'already_paid');
  perform bt.eq('other sid', public.billing_payment_paid(pid, 'sifalo', 'SID9', 6.00, 'USD', 'edahab', '{}'), 'purchase_paid_other_sid');
  perform bt.eq('sid reused on another payment', public.billing_payment_paid(pid2, 'sifalo', 'SID1', 1.25, 'USD', 'edahab', '{}'), 'sid_reused');
  perform bt.eq('payg balance 3M', (select left_tokens from billing.token_balances where payment_id = pid), 3000000::bigint);
  perform bt.eq('payg expires in 12 months', (select expires_at from billing.token_balances where payment_id = pid), '2027-11-12 06:00:00+00'::timestamptz);
  perform bt.eq('finance row once', (select count(*) from finance.ledger where source_ref = 'billing:payment:' || pid), 1::bigint);
  perform bt.eq('paid weekly', public.billing_payment_paid(pid2, 'sifalo', 'SID2', 1.25, 'USD', 'waafi', '{}'), 'paid');
  s := (select subscription_id from billing.payments where id = pid2);
  perform bt.eq('weekly subscription', (select total_left from billing.subscriptions where id = s), 700000::bigint);
  perform bt.eq('find shows tokens added', (public.billing_payment_find(pid2, u)->>'tokens_added')::bigint, 700000::bigint);
  perform bt.eq('find other user null', public.billing_payment_find(pid2, '00000000-0000-0000-0000-000000000000'), null::jsonb);
  -- spend some, then refund: what is left comes back off, ledger still balanced
  perform bt.charge(u, 260000, 'r11-1');              -- 60k free + 200k package
  r := public.billing_payment_reverse(pid2, 'refund', 'test refund', 'test');
  perform bt.eq('refund takes back what is left', (r->>'tokens_taken_back')::bigint, 500000::bigint);
  perform bt.eq('refund used', (r->>'tokens_already_used')::bigint, 200000::bigint);
  perform bt.eq('reversed', (select status from billing.payments where id = pid2), 'reversed');
  perform bt.eq('reverse twice', public.billing_payment_reverse(pid2, 'refund', 'again', 'test')->>'reason', 'already_reversed');
  perform bt.eq('reversed sub not usable', jsonb_array_length(billing.position(u)->'packages'), 0);
  perform bt.eq('finance refund row', (select count(*) from finance.ledger where source_ref = 'billing:refund:' || pid2), 1::bigint);
  perform bt.ok('ledger balanced', bt.balanced());
  -- failed / expire / pending list
  r := public.billing_payment_create(u, 'monthly', null, null, 'sifalo', 'idem-key-0002', null);
  perform public.billing_payment_failed((r->>'purchase_id')::uuid, 'insufficient_funds', '{}');
  perform bt.eq('failed reason', (select result from billing.payments where id = (r->>'purchase_id')::uuid), 'insufficient_funds');
  perform bt.eq('failed is not terminal', public.billing_payment_paid((r->>'purchase_id')::uuid, 'sifalo', 'SID3', 4.99, 'USD', 'waafi', '{}'), 'paid');
  perform bt.pass('11 payments');
end $$;

do $$ declare u uuid := '00000000-0000-0000-0000-000000000012'; i int; r jsonb; begin
  for i in 1..10 loop
    r := public.billing_payment_create(u, 'weekly', null, null, 'sifalo', 'rate-key-' || lpad(i::text, 4, '0'), null);
    perform bt.ok('created ' || i, (r->>'ok')::boolean);
  end loop;
  perform bt.eq('rate limited', public.billing_payment_create(u, 'weekly', null, null, 'sifalo', 'rate-key-0011', null)->>'reason', 'rate_limited');
  perform bt.enable(false);
  perform bt.eq('create refused while off', public.billing_payment_create(u, 'weekly')->>'reason', 'billing_disabled');
  perform bt.enable(true);
  perform bt.pass('11b checkout rate limit + flag');
end $$;

-- ============================================================ 12 admin adjust + user RPCs
do $$ declare u uuid := '00000000-0000-0000-0000-000000000013'; r jsonb; begin
  perform bt.at('2026-11-12 06:00:00+00');
  perform bt.payg(u, 2000000);
  r := public.billing_adjust(u, 'payg', -500000, 'goodwill reversal');
  perform bt.eq('take back', (r->>'taken')::bigint, 500000::bigint);
  perform bt.eq('payg left', (billing.position(u)->'payg'->>'left')::bigint, 1500000::bigint);
  perform bt.eq('package take-back refused', public.billing_adjust(u, 'weekly', -5, 'x')->>'reason', 'payg_only');
  perform bt.ok('ledger balanced', bt.balanced());
  perform bt.as_user(u);
  r := public.billing_usage();
  perform bt.eq('usage plan', r->>'plan', 'payg');
  perform bt.eq('usage total', (r->>'total_left')::bigint, 1500000::bigint);
  perform bt.ok('plans listed', jsonb_array_length(r->'plans') >= 4);
  perform bt.ok('inactive plan hidden', not exists (select 1 from jsonb_array_elements(r->'plans') x where x->>'id' = 'monthly_plus'));
  perform bt.ok('activity', jsonb_typeof(public.billing_activity(10)->'grants') = 'array');
  perform bt.as_user(null);
  begin
    perform public.billing_usage();
    raise exception 'signed-out usage allowed';
  exception when others then
    perform bt.ok('signed out refused', sqlerrm like '%auth required%');
  end;
  perform bt.pass('12 admin adjust + user RPCs');
end $$;

-- ============================================================ 13 billing_enabled blocked while Sifalo is staging; testers
do $$ declare u uuid := '00000000-0000-0000-0000-000000000031'; t uuid := '00000000-0000-0000-0000-000000000032'; r jsonb; begin
  perform bt.at('2026-11-12 06:00:00+00');
  begin
    update public.ai_settings set value = '"staging"' where key = 'billing_provider_env';
    raise exception 'went back to staging while on';
  exception when check_violation then perform bt.ok('staging refused while on', true);
  end;
  perform bt.enable(false);
  update public.ai_settings set value = '"staging"' where key = 'billing_provider_env';
  begin
    perform bt.enable(true);
    raise exception 'enabled while staging';
  exception when check_violation then perform bt.ok('billing_enabled refused while staging', sqlerrm like '%billing_provider_env%');
  end;
  perform bt.eq('off for users in staging', (bt.gate(u)->>'enabled')::boolean, false);
  update public.ai_settings set value = jsonb_build_array(t::text) where key = 'billing_testers';
  perform bt.eq('tester on in staging', (bt.gate(t)->>'enabled')::boolean, true);
  perform bt.eq('tester charged', (bt.charge(t, 1000, 'r13-1')->>'free')::bigint, 1000::bigint);
  perform bt.eq('tester can pay', (public.billing_payment_create(t, 'weekly')->>'ok')::boolean, true);
  perform bt.eq('others cannot pay', public.billing_payment_create(u, 'weekly')->>'reason', 'billing_disabled');
  r := public.billing_is_on(t);
  perform bt.ok('is_on tester', (r->>'on')::boolean and (r->>'tester')::boolean and not (r->>'enabled')::boolean);
  perform bt.ok('is_on no user = testers exist', (public.billing_is_on(null)->>'on')::boolean);
  perform bt.ok('is_on other user off', not (public.billing_is_on(u)->>'on')::boolean);
  update public.ai_settings set value = '[]' where key = 'billing_testers';
  perform bt.ok('is_on no user, no testers: off', not (public.billing_is_on(null)->>'on')::boolean);
  update public.ai_settings set value = '"live"' where key = 'billing_provider_env';
  perform bt.enable(true);
  perform bt.ok('live + enabled', (public.billing_is_on(u)->>'on')::boolean);
  perform bt.pass('13 staging switch + testers');
end $$;

-- ============================================================ 14 failed-charge retry queue
do $$ declare u uuid := '00000000-0000-0000-0000-000000000033'; r jsonb; begin
  perform bt.at('2026-11-12 06:00:00+00');
  perform bt.charge(u, 1000, 'q-landed');
  perform bt.eq('already charged not queued', public.usage_charge_enqueue(u, 1000, 0, 'chat', 'q-landed')->>'reason', 'already_charged');
  perform bt.eq('queued', (public.usage_charge_enqueue(u, 2000, 500, 'chat', 'q-1')->>'queued')::boolean, true);
  perform bt.eq('queued twice = duplicate', (public.usage_charge_enqueue(u, 2000, 500, 'chat', 'q-1')->>'duplicate')::boolean, true);
  perform public.usage_charge_enqueue(u, 100, 0, 'chat', 'q-old');
  update billing.charge_queue set created_at = now() - interval '4 days' where request_id = 'q-old';
  r := public.billing_charge_retry_drain();
  perform bt.eq('drain charged', (r->>'charged')::int, 1);
  perform bt.eq('drain expired old', (r->>'expired')::int, 1);
  perform bt.eq('queued charge landed once', (select -sum(tokens) from billing.usage_ledger where ref = 'q-1'), 2500::numeric);
  perform bt.eq('old one not billed', (select count(*) from billing.usage_ledger where ref = 'q-old'), 0::bigint);
  -- a charge that landed while queued (ai-chat's own retry won): the drain sees the duplicate, charges nothing more
  perform public.usage_charge_enqueue(u, 3000, 0, 'chat', 'q-2');
  perform bt.charge(u, 3000, 'q-2');
  r := public.billing_charge_retry_drain();
  perform bt.eq('duplicate counted', (r->>'duplicate')::int, 1);
  perform bt.eq('q-2 once', (select -sum(tokens) from billing.usage_ledger where ref = 'q-2'), 3000::numeric);
  perform bt.eq('queue empty', (r->>'pending')::int, 0);
  perform bt.pass('14 charge retry queue');
end $$;

-- ============================================================ 15 ledger sync: outbox -> finance.ledger
do $$ declare r jsonb; begin
  insert into billing.ledger_outbox(entry, source_ref, error, attempts)
  values (jsonb_build_object('entry_type', 'pack_purchase', 'amount_usd', 2, 'tokens', 1000000, 'source_ref', 'billing:payment:sync-test'),
          'billing:payment:sync-test', 'finance down', 1);
  r := public.billing_sync_ledger();
  perform bt.eq('posted', (r->>'posted')::int, 1);
  perform bt.eq('in finance ledger', (select count(*) from finance.ledger where source_ref = 'billing:payment:sync-test'), 1::bigint);
  perform bt.eq('nothing waiting', (public.billing_sync_ledger()->>'waiting')::int, 0);
  perform bt.pass('15 ledger sync');
end $$;

-- ============================================================ 16 renewal reminder the day before a package ends
do $$ declare u uuid := '00000000-0000-0000-0000-000000000034'; v uuid := '00000000-0000-0000-0000-000000000035'; r jsonb; begin
  perform bt.at('2026-11-12 06:00:00+00');
  perform bt.pkg(u, 'weekly');                         -- ends 11-19 06:00
  perform bt.pkg(v, 'weekly');
  perform bt.pkg(v, 'weekly');                         -- v has the next week queued: no reminder
  perform bt.at('2026-11-17 06:00:00+00');
  perform public.billing_renewal_reminders();
  perform bt.eq('too early', (select count(*) from public.user_inbox where user_id in (u, v)), 0::bigint);
  perform bt.at('2026-11-18 07:00:00+00');             -- 23 h before the end
  r := public.billing_renewal_reminders();
  perform bt.ok('sent', (r->>'sent')::int >= 1);
  perform bt.eq('inbox row', (select count(*) from public.user_inbox where user_id = u and kind = 'billing_reminder'), 1::bigint);
  perform bt.ok('two languages', (select title from public.user_inbox where user_id = u) like '%tomorrow%berri%');
  perform bt.eq('not twice', (public.billing_renewal_reminders()->>'sent')::int, 0);
  perform bt.eq('queued successor: none', (select count(*) from public.user_inbox where user_id = v), 0::bigint);
  perform bt.at('2026-11-25 07:00:00+00');             -- v's second week ends tomorrow
  perform public.billing_renewal_reminders();
  perform bt.eq('reminder for the last one', (select count(*) from public.user_inbox where user_id = v), 1::bigint);
  perform bt.pass('16 renewal reminder');
end $$;

-- ============================================================ 17 account deletion warning
do $$ declare u uuid := '00000000-0000-0000-0000-000000000036'; w uuid := '00000000-0000-0000-0000-000000000037'; r jsonb; begin
  perform bt.at('2026-11-12 06:00:00+00');
  perform bt.payg(u, 1000000);
  perform bt.as_user(u);
  r := public.billing_deletion_warning();
  perform bt.eq('has paid', (r->>'has_paid')::boolean, true);
  perform bt.eq('paid left', (r->>'paid_left')::bigint, 1000000::bigint);
  perform bt.as_user(w);
  perform bt.eq('free user: nothing to warn', (public.billing_deletion_warning()->>'has_paid')::boolean, false);
  perform bt.as_user(null);
  perform bt.pass('17 deletion warning');
end $$;

-- ============================================================ 18 admin: plan editor, payments list, refund by reversing entries
do $$ declare u uuid := '00000000-0000-0000-0000-000000000038'; r jsonb; pid uuid; begin
  perform bt.at('2026-11-12 06:00:00+00');
  r := public.billing_plan_update('weekly', '{"price_usd": 1.50, "daily_tokens": 220000, "validity_days": 8}');
  perform bt.eq('plan updated', (r->>'ok')::boolean, true);
  perform bt.eq('new price quoted', (public.billing_payment_create(u, 'weekly')->>'amount_usd')::numeric, 1.50);
  perform bt.eq('unknown field', public.billing_plan_update('weekly', '{"coins": 5}')->>'reason', 'unknown_field');
  perform bt.eq('bad value', public.billing_plan_update('weekly', '{"price_usd": 0}')->>'reason', 'bad_value');
  perform bt.eq('unknown plan', public.billing_plan_update('nope', '{"sort": 1}')->>'reason', 'unknown_plan');
  r := public.billing_plan_update('monthly_plus', '{"active": true}');
  perform bt.eq('plus on', (select active from billing.plans where id = 'monthly_plus'), true);
  perform public.billing_plan_update('monthly_plus', '{"active": false}');
  perform public.billing_plan_update('weekly', '{"price_usd": 1.25, "daily_tokens": 200000, "validity_days": 7}');
  pid := (public.billing_payment_create(u, 'payg', 1000000, null, 'sifalo', 'adm-key-0001', null)->>'purchase_id')::uuid;
  perform public.billing_payment_paid(pid, 'sifalo', 'SID_ADM', 2.00, 'USD', 'waafi', '{}');
  perform bt.ok('payments listed', jsonb_array_length(public.billing_admin_payments('paid', u)) = 1);
  perform bt.charge(u, 100000, 'r18-1');               -- free first (60k), then 40k PAYG
  r := public.billing_payment_reverse(pid, 'refund', 'support', 'owner');
  perform bt.eq('refund back', (r->>'tokens_taken_back')::bigint, 960000::bigint);
  perform bt.eq('reversing ledger row', (select tokens from billing.usage_ledger where ref = 'payment:' || pid and kind = 'reverse'), -960000::bigint);
  perform bt.eq('payg gone', (billing.position(u)->'payg'->>'left')::bigint, 0::bigint);
  perform bt.ok('ledger balanced', bt.balanced());
  perform bt.pass('18 admin plan editor + refund');
end $$;

-- ============================================================ 19 schedules
do $$ begin
  perform bt.eq('4 billing jobs', (select count(*) from cron.job where jobname like 'billing-%'), 4::bigint);
  perform bt.eq('reconcile every 10 min', (select schedule from cron.job where jobname = 'billing-reconcile'), '*/10 * * * *');
  perform bt.eq('charge retry every 5 min', (select schedule from cron.job where jobname = 'billing-charge-retry'), '*/5 * * * *');
  perform bt.ok('ledger sync', exists (select 1 from cron.job where jobname = 'billing-ledger-sync'));
  perform bt.ok('renewal reminders', exists (select 1 from cron.job where jobname = 'billing-renewal-reminders'));
  perform bt.ok('old coin job gone', not exists (select 1 from cron.job where jobname = 'billing-reconcile-usage'));
  perform bt.pass('19 schedules');
end $$;

select bt.ok('whole ledger balanced', bt.balanced());
select set_config('billing.test_now', '', false);
select n, name from bt.results order by n;
select 'billing_v2_test: ' || count(*) || ' groups passed' from bt.results;
