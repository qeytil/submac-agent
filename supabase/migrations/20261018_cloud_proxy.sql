-- Telesia Cloud: model proxy config, Vault-backed provider keys, per-user daily allowance, usage and benchmarks.
-- Applied live 2026-10-18. Only the service role (edge functions) can read or write these tables.
-- Telesia cloud model proxy: config, keys (Vault), usage, quotas
create table if not exists public.ai_providers (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  base_url text not null,
  enabled boolean not null default true,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists public.ai_keys (
  id uuid primary key default gen_random_uuid(),
  provider_id uuid not null references public.ai_providers(id) on delete cascade,
  label text not null default 'key',
  secret_id uuid not null,
  key_preview text,
  enabled boolean not null default true,
  cooldown_until timestamptz,
  fail_count int not null default 0,
  last_error text,
  last_ok_at timestamptz,
  last_fail_at timestamptz,
  created_at timestamptz not null default now()
);
create table if not exists public.ai_models (
  id uuid primary key default gen_random_uuid(),
  provider_id uuid not null references public.ai_providers(id) on delete cascade,
  model_id text not null,
  label text,
  enabled boolean not null default true,
  vision boolean not null default false,
  tools boolean not null default true,
  context_window int not null default 128000,
  extra_body jsonb,
  notes text,
  healthy boolean not null default true,
  last_check_at timestamptz,
  created_at timestamptz not null default now(),
  unique (provider_id, model_id)
);
create table if not exists public.ai_aliases (
  alias text primary key,
  description text,
  max_output_tokens int not null default 1024,
  system_hint text,
  enabled boolean not null default true,
  created_at timestamptz not null default now()
);
create table if not exists public.ai_routes (
  id uuid primary key default gen_random_uuid(),
  alias text not null references public.ai_aliases(alias) on delete cascade on update cascade,
  model_ref uuid not null references public.ai_models(id) on delete cascade,
  priority int not null default 100,
  enabled boolean not null default true,
  unique (alias, model_ref)
);
create table if not exists public.ai_settings (
  key text primary key,
  value jsonb not null,
  updated_at timestamptz not null default now()
);
create table if not exists public.ai_admins (email text primary key);
create table if not exists public.ai_blocked_users (
  user_id uuid primary key,
  reason text,
  created_at timestamptz not null default now()
);
create table if not exists public.ai_user_daily (
  user_id uuid not null,
  day date not null,
  tokens bigint not null default 0,
  requests int not null default 0,
  primary key (user_id, day)
);
create table if not exists public.ai_usage (
  id bigserial primary key,
  created_at timestamptz not null default now(),
  user_id uuid,
  source text not null default 'app',
  alias text,
  provider text,
  model text,
  key_id uuid,
  status int,
  prompt_tokens int default 0,
  completion_tokens int default 0,
  ttft_ms int,
  total_ms int,
  tps numeric,
  attempts int default 1,
  error text
);
create index if not exists ai_usage_created_idx on public.ai_usage (created_at desc);
create index if not exists ai_usage_user_idx on public.ai_usage (user_id, created_at desc);

-- Lock everything down: only service_role (edge functions) touches these.
do $$ declare t text; begin
  foreach t in array array['ai_providers','ai_keys','ai_models','ai_aliases','ai_routes','ai_settings','ai_admins','ai_blocked_users','ai_user_daily','ai_usage'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $$;
revoke all on sequence public.ai_usage_id_seq from anon, authenticated;

-- Config for the proxy (decrypted keys) -- service_role only
create or replace function public.ai_get_config() returns jsonb
language sql security definer set search_path = public, vault as $$
  select jsonb_build_object(
    'settings', coalesce((select jsonb_object_agg(key, value) from ai_settings), '{}'::jsonb),
    'aliases', coalesce((select jsonb_agg(jsonb_build_object(
        'alias', a.alias, 'max_output_tokens', a.max_output_tokens, 'system_hint', a.system_hint,
        'routes', coalesce((select jsonb_agg(jsonb_build_object(
            'route_id', r.id, 'model_ref', m.id, 'model', m.model_id, 'vision', m.vision, 'tools', m.tools,
            'context_window', m.context_window, 'extra_body', m.extra_body, 'healthy', m.healthy,
            'provider', p.name, 'base_url', p.base_url,
            'keys', coalesce((select jsonb_agg(jsonb_build_object('id', k.id, 'key', ds.decrypted_secret, 'cooldown_until', k.cooldown_until) order by k.created_at)
                     from ai_keys k join vault.decrypted_secrets ds on ds.id = k.secret_id
                     where k.provider_id = p.id and k.enabled), '[]'::jsonb)
          ) order by r.priority, r.id)
          from ai_routes r join ai_models m on m.id = r.model_ref join ai_providers p on p.id = m.provider_id
          where r.alias = a.alias and r.enabled and m.enabled and p.enabled), '[]'::jsonb)
      )) from ai_aliases a where a.enabled), '[]'::jsonb)
  );
$$;

create or replace function public.ai_model_with_keys(p_model_ref uuid) returns jsonb
language sql security definer set search_path = public, vault as $$
  select jsonb_build_object('model', m.model_id, 'provider', p.name, 'base_url', p.base_url, 'extra_body', m.extra_body,
    'keys', coalesce((select jsonb_agg(jsonb_build_object('id', k.id, 'key', ds.decrypted_secret, 'label', k.label) order by k.created_at)
       from ai_keys k join vault.decrypted_secrets ds on ds.id = k.secret_id where k.provider_id = p.id and k.enabled), '[]'::jsonb))
  from ai_models m join ai_providers p on p.id = m.provider_id where m.id = p_model_ref;
$$;

create or replace function public.ai_add_key(p_provider uuid, p_label text, p_key text) returns uuid
language plpgsql security definer set search_path = public, vault as $$
declare sid uuid; kid uuid;
begin
  sid := vault.create_secret(p_key, 'ai_key_' || gen_random_uuid()::text, 'Telesia proxy provider key');
  insert into ai_keys(provider_id, label, secret_id, key_preview)
  values (p_provider, coalesce(nullif(p_label,''),'key'), sid, left(p_key, 6) || '…' || right(p_key, 4))
  returning id into kid;
  return kid;
end $$;

create or replace function public.ai_update_key(p_key_id uuid, p_key text) returns void
language plpgsql security definer set search_path = public, vault as $$
declare sid uuid;
begin
  select secret_id into sid from ai_keys where id = p_key_id;
  perform vault.update_secret(sid, p_key);
  update ai_keys set key_preview = left(p_key, 6) || '…' || right(p_key, 4), fail_count = 0, cooldown_until = null, last_error = null where id = p_key_id;
end $$;

create or replace function public.ai_delete_key(p_key_id uuid) returns void
language plpgsql security definer set search_path = public, vault as $$
declare sid uuid;
begin
  delete from ai_keys where id = p_key_id returning secret_id into sid;
  if sid is not null then delete from vault.secrets where id = sid; end if;
end $$;

create or replace function public.ai_delete_provider(p_id uuid) returns void
language plpgsql security definer set search_path = public, vault as $$
begin
  delete from vault.secrets where id in (select secret_id from ai_keys where provider_id = p_id);
  delete from ai_providers where id = p_id;
end $$;

create or replace function public.ai_mark_key(p_key_id uuid, p_ok boolean, p_error text, p_cooldown_seconds int) returns void
language sql security definer set search_path = public as $$
  update ai_keys set
    last_ok_at = case when p_ok then now() else last_ok_at end,
    last_fail_at = case when p_ok then last_fail_at else now() end,
    fail_count = case when p_ok then 0 else fail_count + 1 end,
    last_error = case when p_ok then last_error else left(p_error, 300) end,
    cooldown_until = case when p_ok then null when p_cooldown_seconds > 0 then now() + make_interval(secs => p_cooldown_seconds) else cooldown_until end
  where id = p_key_id;
$$;

create or replace function public.ai_record_usage(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare tot int := coalesce((p->>'prompt_tokens')::int,0) + coalesce((p->>'completion_tokens')::int,0);
begin
  insert into ai_usage(user_id, source, alias, provider, model, key_id, status, prompt_tokens, completion_tokens, ttft_ms, total_ms, tps, attempts, error)
  values ((p->>'user_id')::uuid, coalesce(p->>'source','app'), p->>'alias', p->>'provider', p->>'model', (p->>'key_id')::uuid,
          (p->>'status')::int, coalesce((p->>'prompt_tokens')::int,0), coalesce((p->>'completion_tokens')::int,0),
          (p->>'ttft_ms')::int, (p->>'total_ms')::int, (p->>'tps')::numeric, coalesce((p->>'attempts')::int,1), left(p->>'error',300));
  if (p->>'user_id') is not null and coalesce(p->>'source','app') <> 'bench' then
    insert into ai_user_daily(user_id, day, tokens, requests) values ((p->>'user_id')::uuid, (now() at time zone 'utc')::date, tot, 1)
    on conflict (user_id, day) do update set tokens = ai_user_daily.tokens + excluded.tokens, requests = ai_user_daily.requests + 1;
  end if;
end $$;

create or replace function public.ai_stats(p_hours int default 24) returns jsonb
language sql security definer set search_path = public as $$
  select jsonb_build_object(
    'routes', coalesce((select jsonb_agg(x) from (
      select provider, model, source, count(*) n,
        count(*) filter (where status = 200) ok,
        percentile_cont(0.5) within group (order by ttft_ms) filter (where status = 200) ttft_p50,
        percentile_cont(0.95) within group (order by ttft_ms) filter (where status = 200) ttft_p95,
        percentile_cont(0.5) within group (order by tps) filter (where status = 200 and tps > 0) tps_p50,
        percentile_cont(0.05) within group (order by tps) filter (where status = 200 and tps > 0) tps_p05,
        percentile_cont(0.5) within group (order by total_ms) filter (where status = 200) total_p50,
        sum(prompt_tokens) pin, sum(completion_tokens) pout
      from ai_usage where created_at > now() - make_interval(hours => p_hours) and provider is not null
      group by provider, model, source order by n desc) x), '[]'::jsonb),
    'totals', (select jsonb_build_object('requests', count(*), 'ok', count(*) filter (where status = 200),
        'users', count(distinct user_id), 'prompt_tokens', coalesce(sum(prompt_tokens),0), 'completion_tokens', coalesce(sum(completion_tokens),0),
        'ttft_p50', percentile_cont(0.5) within group (order by ttft_ms) filter (where status=200),
        'ttft_p95', percentile_cont(0.95) within group (order by ttft_ms) filter (where status=200),
        'tps_p50', percentile_cont(0.5) within group (order by tps) filter (where status=200 and tps>0))
      from ai_usage where source <> 'bench' and created_at > now() - make_interval(hours => p_hours)),
    'top_users', coalesce((select jsonb_agg(u) from (
      select d.user_id, au.email, d.tokens, d.requests from ai_user_daily d left join auth.users au on au.id = d.user_id
      where d.day = (now() at time zone 'utc')::date order by d.tokens desc limit 20) u), '[]'::jsonb),
    'errors', coalesce((select jsonb_agg(e) from (
      select created_at, provider, model, status, error from ai_usage where status <> 200 and created_at > now() - make_interval(hours => p_hours)
      order by created_at desc limit 30) e), '[]'::jsonb)
  );
$$;

do $$ declare f text; begin
  foreach f in array array['ai_get_config()','ai_model_with_keys(uuid)','ai_add_key(uuid,text,text)','ai_update_key(uuid,text)','ai_delete_key(uuid)','ai_delete_provider(uuid)','ai_mark_key(uuid,boolean,text,integer)','ai_record_usage(jsonb)','ai_stats(integer)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;

insert into public.ai_admins(email) values ('telesia.owner@gmail.com') on conflict do nothing;
insert into public.ai_settings(key, value) values
  ('daily_cap_tokens', '200000'),
  ('soft_notice_ratio', '0.8'),
  ('grace_tokens', '40000'),
  ('grace_alias', '"telesia-lite"'),
  ('grace_max_output_tokens', '400'),
  ('kill_switch', 'false'),
  ('first_byte_timeout_ms', '20000'),
  ('max_attempts', '6'),
  ('limit_message', '"You''ve done a lot today! Your daily allowance refreshes tomorrow."'),
  ('baseline', '{"ttft_p95_ms": 1500, "tps_min": 40, "locked": false}')
on conflict (key) do nothing;

create or replace function public.ai_key_secret(p_key_id uuid) returns jsonb
language sql security definer set search_path = public, vault as $$
  select jsonb_build_object('id', k.id, 'key', ds.decrypted_secret, 'base_url', p.base_url, 'provider_id', p.id)
  from ai_keys k join ai_providers p on p.id = k.provider_id join vault.decrypted_secrets ds on ds.id = k.secret_id where k.id = p_key_id;
$$;
revoke all on function public.ai_key_secret(uuid) from public, anon, authenticated;
grant execute on function public.ai_key_secret(uuid) to service_role;

create or replace function public.ai_record_usage(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare tot int := coalesce((p->>'quota_tokens')::int, coalesce((p->>'prompt_tokens')::int,0) + coalesce((p->>'completion_tokens')::int,0));
begin
  insert into ai_usage(user_id, source, alias, provider, model, key_id, status, prompt_tokens, completion_tokens, ttft_ms, total_ms, tps, attempts, error)
  values ((p->>'user_id')::uuid, coalesce(p->>'source','app'), p->>'alias', p->>'provider', p->>'model', (p->>'key_id')::uuid,
          (p->>'status')::int, coalesce((p->>'prompt_tokens')::int,0), coalesce((p->>'completion_tokens')::int,0),
          (p->>'ttft_ms')::int, (p->>'total_ms')::int, (p->>'tps')::numeric, coalesce((p->>'attempts')::int,1), left(p->>'error',300));
  if (p->>'user_id') is not null and coalesce(p->>'source','app') <> 'bench' and coalesce((p->>'status')::int, 0) = 200 then
    insert into ai_user_daily(user_id, day, tokens, requests) values ((p->>'user_id')::uuid, (now() at time zone 'utc')::date, tot, 1)
    on conflict (user_id, day) do update set tokens = ai_user_daily.tokens + excluded.tokens, requests = ai_user_daily.requests + 1;
  end if;
end $$;
insert into ai_settings(key,value) values ('input_weight','0.3'),('output_weight','1'),('cached_weight','0.1') on conflict do nothing;

insert into public.ai_settings(key, value) values
  ('live_provider', '"Google Gemini"'),
  ('live_model', '"gemini-2.5-flash-native-audio-latest"'),
  ('live_session_minutes', '30'),
  ('live_session_tokens', '6000'),
  ('transcribe_models', '["gemini-3.5-flash-lite","gemini-3-flash-preview"]'),
  ('image_tokens', '4000'),
  ('user_rpm', '40'),
  ('max_prompt_tokens', '120000')
on conflict (key) do nothing;
-- Provider keys are added from the admin dashboard (stored in Supabase Vault), never in a migration.
