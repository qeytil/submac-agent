-- Telesia billing follow-up (step 3b): charges are never lost, Live seconds closed by the server are billed,
-- and the per-user wallet lock can never be waited on for long.
-- ADDITIVE ONLY. Requires 20261020_billing.sql. Independent of 20261021_billing_providers / _hardening. Safe to run twice.
--
--   billing.consume_retry                       durable queue of reply charges ai-chat could not write (billing_consume
--                                               failed twice). Keyed by the reply's request id, so draining is idempotent:
--                                               a charge that did land after all comes back `duplicate` and is not taken twice.
--   public.billing_consume_enqueue(...)         ai-chat: park a charge (no wallet lock, one insert).
--   public.billing_consume_retry_drain(limit)   charge parked rows (each in its own sub-transaction), exponential backoff on
--                                               failure, rows older than billing_retry_max_age_hours (72) expire unbilled.
--   public.billing_live_reconcile(hours, limit) closes stale calls of billed callers (public.live_close_stale) and bills the
--                                               seconds a call has that its billing rows do not (stale close <= 30 s, or a
--                                               heartbeat whose charge failed). Same idempotency id as a heartbeat:
--                                               live:<call>:<call_seconds>.
--   public.billing_reconcile_usage()            both of the above; for pg_cron (`select public.billing_reconcile_usage()`)
--                                               or the billing-reconcile function. Service role only.
--   lock_timeout on billing_consume (3 s) / billing_precheck (2 s): a contended wallet lock fails fast; ai-chat then
--                                               queues the charge / uses its conservative fallback instead of hanging.
-- Optional tunables (read with billing.num, no rows added): billing_retry_max_age_hours (72).

create table if not exists billing.consume_retry (
  id bigint generated always as identity primary key,
  request_id text not null unique,               -- the reply's id (chat:<uuid> / media:<uuid>): idempotency key
  user_id uuid not null,
  weighted bigint not null check (weighted >= 0),
  model text,
  source text,
  lane text,
  multiplier numeric(6,3),
  status text not null default 'pending' check (status in ('pending','done','expired')),
  attempts int not null default 0,
  error text,
  result jsonb,
  next_try_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  done_at timestamptz
);
create index if not exists consume_retry_pending on billing.consume_retry (next_try_at) where status = 'pending';

alter table billing.consume_retry enable row level security;
revoke all on billing.consume_retry from public, anon, authenticated;
grant all on billing.consume_retry to service_role;

create or replace function public.billing_consume_enqueue(p_uid uuid, p_request_id text, p_weighted bigint, p_model text,
  p_source text, p_lane text default 'user', p_multiplier numeric default null, p_error text default null) returns jsonb
language plpgsql security definer set search_path = billing, public as $$
declare qid bigint;
begin
  if p_uid is null or coalesce(p_request_id, '') = '' or p_weighted is null or p_weighted < 0 then
    return jsonb_build_object('queued', false, 'reason', 'bad_request');
  end if;
  if exists (select 1 from billing.consumption where request_id = p_request_id) then
    return jsonb_build_object('queued', false, 'reason', 'already_charged');
  end if;
  insert into billing.consume_retry(request_id, user_id, weighted, model, source, lane, multiplier, error)
  values (left(p_request_id, 200), p_uid, p_weighted, left(p_model, 120), left(p_source, 20), coalesce(p_lane, 'user'),
          case when p_multiplier > 0 then p_multiplier end, left(p_error, 300))
  on conflict (request_id) do nothing
  returning id into qid;
  return jsonb_build_object('queued', true, 'id', qid, 'duplicate', qid is null);
end $$;

create or replace function public.billing_consume_retry_drain(p_limit int default 100) returns jsonb
language plpgsql security definer set search_path = billing, public as $$
declare r record; res jsonb; ok int := 0; dup int := 0; bad int := 0; old int := 0;
        max_age numeric := greatest(1, billing.num('billing_retry_max_age_hours', 72));
begin
  if not billing.enabled() then return jsonb_build_object('enabled', false); end if;
  for r in select * from billing.consume_retry where status = 'pending' and next_try_at <= now()
           order by id limit least(greatest(coalesce(p_limit, 100), 1), 1000) for update skip locked loop
    if r.created_at < now() - make_interval(hours => max_age::int) then
      update billing.consume_retry set status = 'expired', done_at = now(), error = coalesce(error, '') || ' | expired unbilled'
       where id = r.id;
      old := old + 1; continue;
    end if;
    begin
      res := billing.consume(r.user_id, r.request_id, r.weighted, r.model, r.source, coalesce(r.lane, 'user'), r.multiplier);
      update billing.consume_retry set status = 'done', done_at = now(), attempts = attempts + 1, result = res where id = r.id;
      if coalesce((res->>'duplicate')::boolean, false) then dup := dup + 1; else ok := ok + 1; end if;
    exception when others then
      update billing.consume_retry set attempts = attempts + 1, error = left(sqlerrm, 300),
             next_try_at = now() + least(interval '1 hour', interval '1 minute' * power(2, least(attempts, 6)))
       where id = r.id;
      bad := bad + 1;
    end;
  end loop;
  return jsonb_build_object('charged', ok, 'duplicate', dup, 'failed', bad, 'expired', old,
    'pending', (select count(*) from billing.consume_retry where status = 'pending'));
end $$;

create or replace function public.billing_live_reconcile(p_hours int default 48, p_limit int default 200) returns jsonb
language plpgsql security definer set search_path = billing, public as $$
declare u record; c record; closed int := 0; billed int := 0; secs bigint := 0; bad int := 0;
        lim int := least(greatest(coalesce(p_limit, 200), 1), 1000);
        hrs int := least(greatest(coalesce(p_hours, 48), 1), 24 * 30);
begin
  if not billing.enabled() then return jsonb_build_object('enabled', false); end if;
  -- 1. Calls of billed callers that stopped reporting: close them the same way live_call_start would (<= 30 s added).
  for u in select distinct lc.user_id from public.live_calls lc
           where lc.ended_at is null and lc.last_beat_at < now() - interval '150 seconds'
             and exists (select 1 from billing.live_charges b where b.call_id = lc.id)
           limit lim loop
    begin
      perform public.live_close_stale(u.user_id); closed := closed + 1;
    exception when others then bad := bad + 1;
    end;
  end loop;
  -- 2. Ended calls (during billing) whose seconds are more than what was billed.
  for c in select lc.id, lc.user_id, lc.seconds, coalesce(sum(b.seconds), 0)::int as billed_s
           from public.live_calls lc join billing.live_charges b on b.call_id = lc.id
           where lc.ended_at is not null and lc.ended_at > now() - make_interval(hours => hrs)
           group by lc.id, lc.user_id, lc.seconds
           having lc.seconds > coalesce(sum(b.seconds), 0)
           order by lc.id limit lim loop
    begin
      perform billing.live_charge(c.user_id, c.id, c.seconds, c.seconds - c.billed_s);
      billed := billed + 1; secs := secs + (c.seconds - c.billed_s);
    exception when others then bad := bad + 1;
    end;
  end loop;
  return jsonb_build_object('closed_users', closed, 'calls_billed', billed, 'seconds_billed', secs, 'failed', bad);
end $$;

create or replace function public.billing_reconcile_usage() returns jsonb
language plpgsql security definer set search_path = billing, public as $$
begin
  if not billing.enabled() then return jsonb_build_object('enabled', false); end if;
  return jsonb_build_object('consume', public.billing_consume_retry_drain(200), 'live', public.billing_live_reconcile(48, 200));
end $$;

-- A contended per-user wallet lock fails fast instead of holding an edge request (ai-chat queues / falls back).
alter function public.billing_consume(uuid, text, bigint, text, text, text, numeric) set lock_timeout = '3s';
alter function public.billing_precheck(uuid) set lock_timeout = '2s';

do $$ declare f text; begin
  for f in select p.oid::regprocedure::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('billing_consume_enqueue','billing_consume_retry_drain',
             'billing_live_reconcile','billing_reconcile_usage') loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
