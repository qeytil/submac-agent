-- ai-chat speed (2026-10-21, ai-chat v30): one round trip for everything a chat call checks, and key secrets
-- decrypted only for the provider actually used.
--
-- ai_config_lite(): the routing config WITHOUT secrets (settings, aliases -> routes with provider_id, key ids and
--   cooldowns per provider). Replaces ai_get_config() in ai-chat, which decrypted every key in the vault on every
--   cold request (~40 keys). ai_get_config() is left in place (the dashboard / older code may still call it).
-- ai_provider_keys(ids): decrypted keys for just these providers.
-- ai_gate(uid, want_config, alias, need_tools): blocked, burst count (last 60 s, ok replies), today's usage,
--   the user's cap (ai_user_cap), optionally the config, and optionally the keys of the first route that would be
--   tried for `alias` (healthy first, tools when needed) so a cold request needs no second round trip.
-- All three are service-role only.

create or replace function public.ai_config_lite()
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select jsonb_build_object(
    'settings', coalesce((select jsonb_object_agg(key, value) from ai_settings), '{}'::jsonb),
    'aliases', coalesce((select jsonb_agg(jsonb_build_object(
        'alias', a.alias, 'max_output_tokens', a.max_output_tokens, 'system_hint', a.system_hint,
        'routes', coalesce((select jsonb_agg(jsonb_build_object(
            'route_id', r.id, 'model_ref', m.id, 'model', m.model_id, 'vision', m.vision, 'tools', m.tools,
            'context_window', m.context_window, 'extra_body', case when r.extra_body is null then m.extra_body else coalesce(m.extra_body, '{}'::jsonb) || r.extra_body end, 'healthy', m.healthy,
            'provider', p.name, 'provider_id', p.id, 'base_url', p.base_url
          ) order by r.priority, r.id)
          from ai_routes r join ai_models m on m.id = r.model_ref join ai_providers p on p.id = m.provider_id
          where r.alias = a.alias and r.enabled and m.enabled and p.enabled), '[]'::jsonb)
      )) from ai_aliases a where a.enabled), '[]'::jsonb),
    'key_meta', coalesce((select jsonb_object_agg(pid, ks) from (
        select k.provider_id::text pid, jsonb_agg(jsonb_build_object('id', k.id, 'cooldown_until', k.cooldown_until) order by k.created_at) ks
        from ai_keys k join ai_providers p on p.id = k.provider_id where k.enabled and p.enabled group by k.provider_id) x), '{}'::jsonb)
  );
$function$;

create or replace function public.ai_provider_keys(p_provider_ids uuid[])
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public', 'vault'
as $function$
  select coalesce(jsonb_object_agg(pid, ks), '{}'::jsonb) from (
    select k.provider_id::text pid, jsonb_agg(jsonb_build_object('id', k.id, 'key', ds.decrypted_secret) order by k.created_at) ks
    from ai_keys k join vault.decrypted_secrets ds on ds.id = k.secret_id
    where k.provider_id = any(p_provider_ids) and k.enabled
    group by k.provider_id) x;
$function$;

create or replace function public.ai_gate(p_uid uuid, p_want_config boolean default false, p_alias text default null, p_need_tools boolean default false)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare
  rpm int;
  burst int := 0;
  u record;
  first_pid uuid;
begin
  begin rpm := coalesce((select (value #>> '{}')::int from ai_settings where key = 'user_rpm'), 40); exception when others then rpm := 40; end;
  if rpm > 0 then
    select count(*) into burst from ai_usage
     where user_id = p_uid and status = 200 and created_at >= now() - interval '60 seconds';
  end if;
  select tokens, requests, bg_tokens into u from ai_user_daily where user_id = p_uid and day = (now() at time zone 'utc')::date;
  if p_alias is not null then
    select p.id into first_pid
      from ai_routes r join ai_models m on m.id = r.model_ref join ai_providers p on p.id = m.provider_id
     where r.alias = p_alias and r.enabled and m.enabled and p.enabled and (not p_need_tools or m.tools)
       and exists (select 1 from ai_keys k where k.provider_id = p.id and k.enabled)
     order by m.healthy desc, r.priority, r.id limit 1;
  end if;
  return jsonb_build_object(
    'blocked', exists (select 1 from ai_blocked_users b where b.user_id = p_uid),
    'burst', burst,
    'usage', jsonb_build_object('tokens', coalesce(u.tokens, 0), 'requests', coalesce(u.requests, 0), 'bg', coalesce(u.bg_tokens, 0)),
    'cap', ai_user_cap(p_uid),
    'config', case when p_want_config then ai_config_lite() else null end,
    'keys', case when first_pid is not null then ai_provider_keys(array[first_pid]) else null end
  );
end $function$;

revoke all on function public.ai_config_lite() from public, anon, authenticated;
revoke all on function public.ai_provider_keys(uuid[]) from public, anon, authenticated;
revoke all on function public.ai_gate(uuid, boolean, text, boolean) from public, anon, authenticated;
grant execute on function public.ai_config_lite() to service_role;
grant execute on function public.ai_provider_keys(uuid[]) to service_role;
grant execute on function public.ai_gate(uuid, boolean, text, boolean) to service_role;
