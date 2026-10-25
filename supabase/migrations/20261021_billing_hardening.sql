-- SubMac Agent billing follow-up: payment gateway hardening (idempotency, double-tap, rate limit, expiry, reasons).
-- ADDITIVE ONLY. Requires 20261020_billing.sql + 20261021_billing_providers.sql. Safe to run twice (idempotent).
-- No ai_settings rows are added: tunables are read with billing.num(key, default) and can be created later:
--   billing_checkout_per_minute (10)  per-user checkout attempts per minute (on top of billing_max_pending_per_hour)
--   billing_doubletap_seconds   (20)  a second identical checkout (same product/method/wallet) without an idempotency key
--                                     inside this window returns the first purchase instead of charging again
--   billing_pending_expire_hours (24) reconcile marks older pendings expired (status failed, result 'expired')
-- Expired is stored as status 'failed' + result 'expired' (no change to the purchases status CHECK). Failed is not
-- terminal: a payment that is verified later still credits through billing_mark_paid_v2.

alter table billing.purchases add column if not exists idempotency_key text;  -- client x-idempotency-key
alter table billing.purchases add column if not exists fingerprint text;      -- product|method|wallet|account (double-tap)
alter table billing.purchases add column if not exists pending_ref text;      -- provider ref of our own server-side charge
alter table billing.purchases add column if not exists client_response jsonb; -- the checkout answer, replayed for the same key

create unique index if not exists purchases_user_idem on billing.purchases (user_id, idempotency_key) where idempotency_key is not null;
create index if not exists purchases_user_fp on billing.purchases (user_id, fingerprint, created_at) where fingerprint is not null;

create or replace function billing.purchase_replay(pu billing.purchases) returns jsonb
language sql stable set search_path = billing, public as $$
  select jsonb_build_object('ok', true, 'replay', true, 'purchase_id', pu.id, 'amount_usd', pu.amount_usd, 'currency', pu.currency,
    'product_id', pu.product_id, 'provider', pu.provider, 'status', pu.status, 'result', pu.result,
    'checkout_key', pu.checkout_key, 'response', pu.client_response)
$$;

-- Serialised per user (advisory xact lock): concurrent double taps / retries never create two purchases for one key.
create or replace function public.billing_create_purchase_v3(p_uid uuid, p_product text, p_device text default null,
  p_provider text default 'sifalo', p_idem text default null, p_fingerprint text default null) returns jsonb
language plpgsql security definer set search_path = billing, public as $$
declare r jsonb; pu billing.purchases; n int;
        idem text := case when p_idem ~ '^[A-Za-z0-9_.:-]{8,100}$' then p_idem end;
        fp text := nullif(left(coalesce(p_fingerprint, ''), 200), '');
begin
  if p_uid is null then return jsonb_build_object('ok', false, 'reason', 'bad_request'); end if;
  if p_idem is not null and idem is null then return jsonb_build_object('ok', false, 'reason', 'bad_idempotency_key'); end if;
  if not billing.enabled() then return jsonb_build_object('ok', false, 'reason', 'billing_disabled'); end if;
  perform pg_advisory_xact_lock(hashtext('billing.checkout'), hashtext(p_uid::text));
  if idem is not null then
    select * into pu from billing.purchases where user_id = p_uid and idempotency_key = idem;
    if found then
      if pu.product_id is distinct from p_product or pu.provider is distinct from lower(coalesce(p_provider, 'sifalo'))
         or pu.fingerprint is distinct from fp then
        return jsonb_build_object('ok', false, 'reason', 'idempotency_key_reused');
      end if;
      return billing.purchase_replay(pu);
    end if;
  elsif fp is not null then
    select * into pu from billing.purchases
     where user_id = p_uid and fingerprint = fp and idempotency_key is null and status = 'pending'
       and created_at > now() - make_interval(secs => billing.num('billing_doubletap_seconds', 20)::double precision)
     order by created_at desc limit 1;
    if found then return billing.purchase_replay(pu); end if;
  end if;
  select count(*) into n from billing.purchases where user_id = p_uid and created_at > now() - interval '1 minute';
  if n >= billing.num('billing_checkout_per_minute', 10) then return jsonb_build_object('ok', false, 'reason', 'rate_limited'); end if;
  r := public.billing_create_purchase_v2(p_uid, p_product, p_device, p_provider);
  if coalesce((r->>'ok')::boolean, false) then
    update billing.purchases set idempotency_key = idem, fingerprint = fp where id = (r->>'purchase_id')::uuid;
  end if;
  return r || jsonb_build_object('replay', false);
end $$;

create or replace function public.billing_save_checkout_response(p_purchase uuid, p_response jsonb) returns void
language sql security definer set search_path = billing, public as $$
  update billing.purchases set client_response = p_response where id = p_purchase
$$;

create or replace function public.billing_note_pending_ref(p_purchase uuid, p_ref text) returns void
language sql security definer set search_path = billing, public as $$
  update billing.purchases set pending_ref = left(p_ref, 128) where id = p_purchase and status = 'pending' and p_ref ~ '^[A-Za-z0-9_.:-]{1,128}$'
$$;

-- Failed with a machine-readable reason (insufficient_funds, declined, provider_config, provider_rejected, ...).
create or replace function public.billing_mark_failed_v2(p_purchase uuid, p_reason text, p_payload jsonb) returns void
language sql security definer set search_path = billing, public as $$
  update billing.purchases set status = 'failed', verify_payload = coalesce(p_payload, verify_payload),
         result = left(coalesce(nullif(p_reason, ''), 'failed'), 60), last_checked_at = now()
   where id = p_purchase and status = 'pending'
$$;

-- Abandoned pending -> status failed + result 'expired', only when still pending and old enough. Returns true when expired.
create or replace function public.billing_expire_purchase_v2(p_purchase uuid, p_min_age_hours int default 24) returns boolean
language plpgsql security definer set search_path = billing, public as $$
declare n int;
begin
  update billing.purchases set status = 'failed', result = 'expired', last_checked_at = now()
   where id = p_purchase and status = 'pending'
     and created_at <= now() - make_interval(hours => greatest(coalesce(p_min_age_hours, 24), 1));
  get diagnostics n = row_count;
  return n > 0;
end $$;

create or replace function public.billing_find_purchase_v3(p_purchase uuid, p_uid uuid default null) returns jsonb
language sql stable security definer set search_path = billing, public as $$
  select to_jsonb(x) from (select id, user_id, product_id, kind, amount_usd, currency, status, provider, provider_ref, pending_ref,
           checkout_key, idempotency_key, result, coins_credited, created_at, paid_at, last_checked_at
    from billing.purchases where id = p_purchase and (p_uid is null or user_id = p_uid)) x
$$;

do $$ declare f text; begin
  for f in select p.oid::regprocedure::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where (n.nspname = 'billing' and p.proname in ('purchase_replay'))
              or (n.nspname = 'public' and p.proname in ('billing_create_purchase_v3','billing_save_checkout_response',
                  'billing_note_pending_ref','billing_mark_failed_v2','billing_expire_purchase_v2','billing_find_purchase_v3')) loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
