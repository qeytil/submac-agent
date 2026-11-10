-- Max output (2026-11-07). APPLIED to project telesia-agent (moeemacbvsueekuvfjbo) at 2026-11-07 14:43 UTC
-- (Blocks 1 and 2 in one statement batch, block 3 in the next). Owner's report: replies were cut short, for the main
-- agent and the bots. See docs/max-output.md. Each block stands on its own; apply in this order.
-- Blocks 1-2 take effect at once (usage_gate / ai-chat read them). Block 3 needs ai-chat v46, which reads
-- ai_models.max_output_tokens; v45 ignores the new field, so block 3 is safe to apply before the deploy.

-- 1. The cap that cut every Telesia reply (main agent and bots): with billing on, usage_gate returns
--    reply_cap = least(billing_reply_cap_tokens, today's balance) and ai-chat clamps every reply's max_tokens to it.
--    It was 8192. The balance still bounds each reply (replyCap), and a reply never goes past the route's own room.
--    Before: {"key": "billing_reply_cap_tokens", "value": 8192}
update public.ai_settings set value = '65536'::jsonb, updated_at = now() where key = 'billing_reply_cap_tokens';

-- 2. The chat alias ceiling: ai-chat serves every chat call on alias 'telesia' (CHAT_ALIAS) and asks a route for
--    min(requested, alias max_output_tokens). It was 32768. Gemini routes (priority 10/20/80) can write 65536.
--    Routes with a smaller window still get only their room (window - prompt), and a route that refuses a big
--    max_tokens is shrunk and remembered by ai-chat (shrinkFor), so the first refusal costs one retry.
--    Before: telesia 32768
update public.ai_aliases set max_output_tokens = 65536 where alias = 'telesia';

-- 3. Each model's own output maximum, so ai-chat asks a route for no more than it can write (ai-chat v46 reads it;
--    v45 ignores the new field, so this block is safe before the deploy). NULL = unknown (room and learned caps only).
alter table public.ai_models add column if not exists max_output_tokens integer
  check (max_output_tokens is null or max_output_tokens > 0);
update public.ai_models set max_output_tokens = 65536 where model_id like 'gemini-%';

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
            'context_window', m.context_window, 'max_output_tokens', m.max_output_tokens,
            'extra_body', case when r.extra_body is null then m.extra_body else coalesce(m.extra_body, '{}'::jsonb) || r.extra_body end, 'healthy', m.healthy,
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

-- Rollback:
--   update public.ai_settings set value = '8192'::jsonb, updated_at = now() where key = 'billing_reply_cap_tokens';
--   update public.ai_aliases set max_output_tokens = 32768 where alias = 'telesia';
--   (block 3: re-run the previous ai_config_lite without 'max_output_tokens'; the column can stay.)
