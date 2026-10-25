-- Thinking modes (2026-10-20): per-route extra_body overrides, a careful "submac-think" alias, smarter main route.
alter table public.ai_routes add column if not exists extra_body jsonb;

CREATE OR REPLACE FUNCTION public.ai_get_config()
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'vault'
AS $function$
  select jsonb_build_object(
    'settings', coalesce((select jsonb_object_agg(key, value) from ai_settings), '{}'::jsonb),
    'aliases', coalesce((select jsonb_agg(jsonb_build_object(
        'alias', a.alias, 'max_output_tokens', a.max_output_tokens, 'system_hint', a.system_hint,
        'routes', coalesce((select jsonb_agg(jsonb_build_object(
            'route_id', r.id, 'model_ref', m.id, 'model', m.model_id, 'vision', m.vision, 'tools', m.tools,
            'context_window', m.context_window, 'extra_body', case when r.extra_body is null then m.extra_body else coalesce(m.extra_body, '{}'::jsonb) || r.extra_body end, 'healthy', m.healthy,
            'provider', p.name, 'base_url', p.base_url,
            'keys', coalesce((select jsonb_agg(jsonb_build_object('id', k.id, 'key', ds.decrypted_secret, 'cooldown_until', k.cooldown_until) order by k.created_at)
                     from ai_keys k join vault.decrypted_secrets ds on ds.id = k.secret_id
                     where k.provider_id = p.id and k.enabled), '[]'::jsonb)
          ) order by r.priority, r.id)
          from ai_routes r join ai_models m on m.id = r.model_ref join ai_providers p on p.id = m.provider_id
          where r.alias = a.alias and r.enabled and m.enabled and p.enabled), '[]'::jsonb)
      )) from ai_aliases a where a.enabled), '[]'::jsonb)
  );
$function$;

insert into public.ai_aliases (alias, description, enabled, max_output_tokens, system_hint)
select 'submac-think', 'Think mode: careful reasoning for hard tasks', true, 8000,
  'Think it through before answering: understand exactly what the user wants, check your facts, then reply clearly. Lead with the answer; go longer only when the task needs it.'
where not exists (select 1 from public.ai_aliases where alias = 'submac-think');

insert into public.ai_routes (alias, model_ref, priority, enabled, extra_body) values
  ('submac-think', 'ededba51-72ec-40f6-9e34-34832547fbd3', 10, true, '{"reasoning_effort":"high"}'),
  ('submac-think', 'f9ef6d85-0ff0-4908-ba9f-953d51a628b9', 20, true, '{"reasoning_effort":"high"}'),
  ('submac-think', '193a7fa6-a5db-4c80-a0ff-c90efcf25109', 30, true, null),
  ('submac-think', '2faa5e30-75ec-4ff1-ba86-10acdce545f6', 40, true, null),
  ('submac-think', 'bc7d5805-0c2d-4cbf-8be7-53bc1837f1b6', 50, true, null)
on conflict (alias, model_ref) do nothing;

-- Main brain: the stronger model first, and room for longer replies.
update public.ai_routes set priority = 5 where id = '407c1b7a-3a74-4360-a1ec-2b4bacfc1c06';
update public.ai_aliases set max_output_tokens = 8000 where alias = 'submac-smart';

-- Reverted the same day at the owner's request: gemini-3-flash-preview back to its old place (p80) in submac-smart.
update public.ai_routes set priority = 80 where id = '407c1b7a-3a74-4360-a1ec-2b4bacfc1c06';

-- Later the same day, owner: stronger model first again, and long replies with no cut-offs.
update public.ai_routes set priority = 5 where id = '407c1b7a-3a74-4360-a1ec-2b4bacfc1c06';
update public.ai_aliases set max_output_tokens = 16000 where alias in ('submac-smart','submac-think');
update public.ai_aliases set max_output_tokens = 4000 where alias in ('submac-fast','submac-vision');
-- Owner: replies long enough for any need (fewer requests per minute is fine).
update public.ai_aliases set max_output_tokens = 64000 where alias in ('submac-smart','submac-think');
update public.ai_aliases set max_output_tokens = 16000 where alias = 'submac-fast';
update public.ai_aliases set max_output_tokens = 8000 where alias = 'submac-vision';
