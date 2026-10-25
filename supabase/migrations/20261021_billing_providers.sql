-- SubMac Agent billing follow-up: provider-neutral payments (swappable payment provider).
-- ADDITIVE ONLY. Requires 20261020_billing.sql. Safe to run twice (idempotent).
--
-- * billing.purchases gets `provider` (default 'sifalo', so every existing row and every caller of the v1 RPCs keeps
--   working unchanged) and `provider_ref` (the provider's payment id; for Sifalo = the sid).
-- * Credit idempotency is keyed on (provider, provider_ref): unique partial index + checks in billing_mark_paid_v2.
-- * The existing `sifalo_sid` column keeps working: for provider 'sifalo' it holds the raw sid exactly as before; for any
--   other provider the v2 RPC stores '<provider>:<ref>' in it (it is the global "payment key" billing.mark_paid uses, and
--   the ledger's external_ref). A trigger fills provider_ref from sifalo_sid, so v1 billing_mark_paid also populates it.
-- * Nothing pre-existing is altered or dropped: billing.mark_paid / billing_create_purchase / billing_find_purchase are
--   reused as they are; the v2 RPCs are thin wrappers. New RPCs are service_role only.

alter table billing.purchases add column if not exists provider text not null default 'sifalo';
alter table billing.purchases add column if not exists provider_ref text;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'purchases_provider_format' and conrelid = 'billing.purchases'::regclass) then
    alter table billing.purchases add constraint purchases_provider_format check (provider ~ '^[a-z][a-z0-9_]{1,31}$');
  end if;
end $$;

-- Backfill (no-op on a fresh/empty table; keeps rows paid through v1 consistent).
update billing.purchases set provider_ref = sifalo_sid
 where provider = 'sifalo' and provider_ref is null and sifalo_sid is not null;

create unique index if not exists purchases_provider_ref on billing.purchases (provider, provider_ref) where provider_ref is not null;
create index if not exists purchases_provider_pending on billing.purchases (provider, created_at) where status = 'pending';

-- The global payment key stored in sifalo_sid: raw for Sifalo (backward compatible), namespaced for everyone else.
create or replace function billing.payment_key(p_provider text, p_ref text) returns text
language sql immutable set search_path = pg_catalog as $$
  select case when p_ref is null or p_ref = '' then null
              when p_provider = 'sifalo' then p_ref
              else p_provider || ':' || p_ref end
$$;

create or replace function billing.purchases_provider_ref() returns trigger
language plpgsql set search_path = pg_catalog as $$
begin
  if new.sifalo_sid is not null and new.provider_ref is null then
    new.provider_ref := case
      when new.provider = 'sifalo' then new.sifalo_sid
      when left(new.sifalo_sid, length(new.provider) + 1) = new.provider || ':' then substr(new.sifalo_sid, length(new.provider) + 2)
      else new.sifalo_sid end;
  end if;
  return new;
end $$;

drop trigger if exists purchases_provider_ref on billing.purchases;
create trigger purchases_provider_ref before insert or update of sifalo_sid, provider_ref on billing.purchases
  for each row execute function billing.purchases_provider_ref();

-- ---------------------------------------------------------------- v2 RPCs (service_role only)
create or replace function public.billing_create_purchase_v2(p_uid uuid, p_product text, p_device text default null, p_provider text default 'sifalo')
returns jsonb language plpgsql security definer set search_path = billing, public as $$
declare r jsonb; prov text := lower(coalesce(p_provider, 'sifalo'));
begin
  if prov !~ '^[a-z][a-z0-9_]{1,31}$' then return jsonb_build_object('ok', false, 'reason', 'bad_provider'); end if;
  r := public.billing_create_purchase(p_uid, p_product, p_device);
  if coalesce((r->>'ok')::boolean, false) then
    update billing.purchases set provider = prov where id = (r->>'purchase_id')::uuid and status = 'pending';
    r := r || jsonb_build_object('provider', prov);
  end if;
  return r;
end $$;

create or replace function public.billing_find_purchase_v2(p_purchase uuid default null, p_key text default null, p_uid uuid default null, p_provider text default null)
returns jsonb language sql stable security definer set search_path = billing, public as $$
  select to_jsonb(x) from (select id, user_id, product_id, kind, amount_usd, currency, status, provider, provider_ref, sifalo_sid,
           checkout_key, result, created_at, paid_at, last_checked_at
    from billing.purchases
    where (p_purchase is null or id = p_purchase) and (p_key is null or checkout_key = p_key) and (p_uid is null or user_id = p_uid)
      and (p_provider is null or provider = p_provider)
      and (p_purchase is not null or p_key is not null)
    order by created_at desc limit 1) x
$$;

-- Credits a verified payment exactly once per (provider, provider_ref). Same result vocabulary as billing_mark_paid
-- ('paid', 'already_paid', 'purchase_paid_other_sid', 'sid_reused', 'no_sid', 'amount_mismatch', 'currency_mismatch',
-- 'no_purchase') plus 'provider_mismatch'. Not gated on billing_enabled (a confirmed payment must be credited once);
-- the edge functions do the gating.
create or replace function public.billing_mark_paid_v2(p_purchase uuid, p_provider text, p_ref text, p_amount numeric, p_currency text,
  p_payment_type text, p_payload jsonb) returns text
language plpgsql security definer set search_path = billing, public as $$
declare pu billing.purchases;
begin
  select * into pu from billing.purchases where id = p_purchase for update;
  if pu.id is null then return 'no_purchase'; end if;
  if pu.provider is distinct from p_provider then
    update billing.purchases set result = 'provider_mismatch', last_checked_at = now() where id = pu.id and status = 'pending';
    return 'provider_mismatch';
  end if;
  if pu.status in ('paid','reversed') then
    return case when pu.provider_ref = p_ref then 'already_paid' else 'purchase_paid_other_sid' end;
  end if;
  if p_ref is null or p_ref = '' then return 'no_sid'; end if;
  if exists (select 1 from billing.purchases where provider = p_provider and provider_ref = p_ref and id <> pu.id) then
    update billing.purchases set result = 'sid_reused', last_checked_at = now() where id = pu.id;
    return 'sid_reused';
  end if;
  return billing.mark_paid(pu.id, billing.payment_key(p_provider, p_ref), p_amount, p_currency, p_payment_type, p_payload);
end $$;

create or replace function public.billing_pending_purchases_v2(p_older_than_minutes int default 10, p_since_hours int default 72,
  p_limit int default 20, p_provider text default null) returns jsonb
language sql stable security definer set search_path = billing, public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'user_id', user_id, 'provider', provider, 'created_at', created_at) order by created_at), '[]'::jsonb) from (
    select id, user_id, provider, created_at from billing.purchases
    where status = 'pending'
      and created_at > now() - make_interval(hours => least(greatest(coalesce(p_since_hours, 72), 1), 24 * 30))
      and created_at <= now() - make_interval(mins => least(greatest(coalesce(p_older_than_minutes, 10), 0), 24 * 60))
      and (p_provider is null or provider = p_provider)
    order by created_at limit least(greatest(coalesce(p_limit, 20), 1), 100)) x
$$;

do $$ declare f text; begin
  for f in select p.oid::regprocedure::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where (n.nspname = 'billing' and p.proname in ('payment_key','purchases_provider_ref'))
              or (n.nspname = 'public' and p.proname in ('billing_create_purchase_v2','billing_find_purchase_v2','billing_mark_paid_v2','billing_pending_purchases_v2')) loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
