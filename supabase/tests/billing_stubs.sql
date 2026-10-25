-- Minimal stand-ins for the live Supabase objects billing reads, so the billing migration and its tests run on a plain
-- PostgreSQL (CI service container). NEVER run this against the real project.
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin bypassrls; end if;
end $$;
create extension if not exists pgcrypto;
create schema if not exists auth;
create or replace function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;

create table if not exists public.ai_settings (key text primary key, value jsonb not null, updated_at timestamptz default now());
insert into public.ai_settings(key, value) values ('background_share', '0.3'), ('daily_cap_tokens', '500000') on conflict do nothing;
create table if not exists public.ai_user_limits (user_id uuid primary key, daily_cap_tokens bigint, note text, updated_at timestamptz default now());
create table if not exists public.reward_ledger (id uuid primary key default gen_random_uuid(), user_id uuid, kind text, amount_per_day int,
  days int, starts_at timestamptz default now(), expires_at timestamptz, revoked boolean default false);
create table if not exists public.referrals (id uuid primary key default gen_random_uuid(), kind text, inviter_id uuid, invitee_id uuid,
  device_id text, status text, reason text, created_at timestamptz default now());
create table if not exists public.user_devices (user_id uuid, device_id text, primary key (user_id, device_id));
create table if not exists public.user_inbox (id uuid primary key default gen_random_uuid(), user_id uuid, kind text, title text, body text,
  created_at timestamptz default now());
create table if not exists public.safety_flags (id bigserial primary key, user_id uuid, category text, detail jsonb);
create or replace function public.reward_same_device(a uuid, b uuid, p_device text) returns boolean language sql stable as $$
  select exists (select 1 from public.user_devices x join public.user_devices y on x.device_id = y.device_id where x.user_id = a and y.user_id = b)
      or (p_device is not null and exists (select 1 from public.user_devices where user_id = a and device_id = p_device))
$$;
create or replace function public.flag_user(p_uid uuid, p_category text, p_severity text, p_source text, p_reason text, p_meta jsonb)
returns void language sql as $$ insert into public.safety_flags(user_id, category, detail) values (p_uid, p_category, p_meta) $$;

-- finance stand-in: the real schema is created by the finance dashboard (append-only ledger + ledger_add_row()).
create schema if not exists finance;
create table if not exists finance.ledger (
  id bigint generated always as identity primary key, ts timestamptz default now(), entry_type text not null, product text default 'agent',
  amount_usd numeric(14,4) default 0, coins bigint default 0, tokens bigint default 0, pass_days int, user_id uuid, payment_method text,
  external_ref text, reverses_id bigint, source_ref text, sku text, funding text default 'cash', note text, created_by text default 'system');
create unique index if not exists ledger_source_once on finance.ledger (entry_type, source_ref) where source_ref is not null and reverses_id is null;
create or replace function finance.ledger_add_row(a jsonb) returns jsonb language sql security definer as $$
  insert into finance.ledger(entry_type, product, amount_usd, coins, tokens, pass_days, user_id, payment_method, external_ref, source_ref, sku, funding, note, created_by)
  values (a->>'entry_type', coalesce(a->>'product','agent'), coalesce((a->>'amount_usd')::numeric,0), coalesce((a->>'coins')::bigint,0),
          coalesce((a->>'tokens')::bigint,0), (a->>'pass_days')::int, (a->>'user_id')::uuid, a->>'payment_method', a->>'external_ref',
          a->>'source_ref', a->>'sku', coalesce(a->>'funding','cash'), a->>'note', coalesce(a->>'created_by','system'))
  returning to_jsonb(ledger.*)
$$;

-- pg_cron / pg_net stand-ins: record the schedules (nothing runs).
create schema if not exists cron;
create table if not exists cron.job (jobid bigserial primary key, jobname text unique, schedule text, command text);
create or replace function cron.schedule(p_name text, p_schedule text, p_command text) returns bigint language sql as $$
  insert into cron.job(jobname, schedule, command) values (p_name, p_schedule, p_command)
  on conflict (jobname) do update set schedule = excluded.schedule, command = excluded.command returning jobid
$$;
create or replace function cron.unschedule(p_id bigint) returns boolean language sql as $$
  with d as (delete from cron.job where jobid = p_id returning 1) select exists (select 1 from d)
$$;
create schema if not exists net;
