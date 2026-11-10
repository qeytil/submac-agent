-- Plan 6 item 1: Live calls get their own key pool, apart from the chat/bot models.
-- live_routes: one row = one provider key (own Vault secret) + optional model for Live voice.
--   model null = use the ai_settings live_model default (the owner's switch keeps working).
--   priority: lower first; rows with the same priority share the load (random order), so a
--   fallback is simply a row with a higher priority number.
-- Failures and rests are recorded here only (never on ai_keys), and chat routing never reads this table.
create table if not exists public.live_routes (
  id uuid primary key default gen_random_uuid(),
  provider text not null default 'Google Gemini',
  label text not null default 'live key',
  model text,
  secret_id uuid not null,
  key_preview text,
  priority int not null default 10,
  enabled boolean not null default true,
  cooldown_until timestamptz,
  fail_count int not null default 0,
  last_error text,
  last_ok_at timestamptz,
  last_fail_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists live_routes_order_idx on public.live_routes (priority, created_at);
alter table public.live_routes enable row level security;
revoke all on public.live_routes from anon, authenticated;

-- Add a key (new Vault secret). Returns the row id.
create or replace function public.live_add_route(p_label text, p_key text, p_model text, p_priority int, p_provider text default 'Google Gemini')
returns uuid language plpgsql security definer set search_path = public, vault as $$
declare sid uuid; rid uuid;
begin
  sid := vault.create_secret(p_key, 'live_key_' || gen_random_uuid()::text, 'Telesia Live voice key');
  insert into live_routes(provider, label, model, secret_id, key_preview, priority)
  values (coalesce(nullif(p_provider,''),'Google Gemini'), coalesce(nullif(p_label,''),'live key'), nullif(p_model,''), sid,
          left(p_key, 6) || '…' || right(p_key, 4), coalesce(p_priority, 10))
  returning id into rid;
  return rid;
end $$;

-- Same key again with another model (a model fallback) without retyping it: copies the secret.
create or replace function public.live_copy_route(p_from uuid, p_label text, p_model text, p_priority int)
returns uuid language plpgsql security definer set search_path = public, vault as $$
declare k text; src live_routes; rid uuid;
begin
  select * into src from live_routes where id = p_from;
  if src.id is null then raise exception 'live route not found'; end if;
  select decrypted_secret into k from vault.decrypted_secrets where id = src.secret_id;
  rid := live_add_route(coalesce(nullif(p_label,''), src.label), k, p_model, coalesce(p_priority, src.priority + 10), src.provider);
  return rid;
end $$;

create or replace function public.live_replace_key(p_id uuid, p_key text) returns void
language plpgsql security definer set search_path = public, vault as $$
declare sid uuid;
begin
  select secret_id into sid from live_routes where id = p_id;
  perform vault.update_secret(sid, p_key);
  update live_routes set key_preview = left(p_key, 6) || '…' || right(p_key, 4), fail_count = 0, cooldown_until = null, last_error = null where id = p_id;
end $$;

create or replace function public.live_delete_route(p_id uuid) returns void
language plpgsql security definer set search_path = public, vault as $$
declare sid uuid;
begin
  delete from live_routes where id = p_id returning secret_id into sid;
  if sid is not null then delete from vault.secrets where id = sid; end if;
end $$;

create or replace function public.live_route_secret(p_id uuid) returns jsonb
language sql security definer set search_path = public, vault as $$
  select jsonb_build_object('id', r.id, 'key', ds.decrypted_secret, 'model', r.model, 'provider', r.provider)
  from live_routes r join vault.decrypted_secrets ds on ds.id = r.secret_id where r.id = p_id;
$$;

create or replace function public.live_mark_route(p_id uuid, p_ok boolean, p_error text, p_cooldown_seconds int) returns void
language sql security definer set search_path = public as $$
  update live_routes set
    last_ok_at = case when p_ok then now() else last_ok_at end,
    last_fail_at = case when p_ok then last_fail_at else now() end,
    fail_count = case when p_ok then 0 else fail_count + 1 end,
    last_error = case when p_ok then last_error else left(p_error, 300) end,
    cooldown_until = case when p_ok then null when p_cooldown_seconds > 0 then now() + make_interval(secs => p_cooldown_seconds) else cooldown_until end
  where id = p_id;
$$;

do $$ declare f text; begin
  foreach f in array array['live_add_route(text,text,text,integer,text)','live_copy_route(uuid,text,text,integer)','live_replace_key(uuid,text)',
                           'live_delete_route(uuid)','live_route_secret(uuid)','live_mark_route(uuid,boolean,text,integer)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;

-- Seed once from the keys Live uses today (enabled keys of the live_provider), as separate Vault copies,
-- all at priority 10 (shared load, as before) and model null (= live_model setting). Nothing is copied twice.
do $$ declare r record; prov text;
begin
  if exists (select 1 from live_routes) then return; end if;
  select value #>> '{}' into prov from ai_settings where key = 'live_provider';
  for r in select k.label, ds.decrypted_secret as key from ai_keys k join ai_providers p on p.id = k.provider_id
           join vault.decrypted_secrets ds on ds.id = k.secret_id
           where p.name = coalesce(prov, 'Google Gemini') and k.enabled order by k.label, k.created_at loop
    perform live_add_route('live ' || r.label, r.key, null, 10, coalesce(prov, 'Google Gemini'));
  end loop;
end $$;
