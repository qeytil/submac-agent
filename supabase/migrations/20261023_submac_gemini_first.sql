-- Owner fix 2026-10-23 (after the first production smoke test of the one-model router, 20261023_router_single_model.sql).
--
-- 1. Somali quality: the `submac` route list had the Ollama / NVIDIA routes first (unhealthy), so Poolside served every
--    chat and its Somali is weak. The Gemini routes now come first, in their current relative order; every other route
--    keeps its order after them. Priorities are renumbered 10, 20, 30, ... (the router and ai_config_lite order by
--    priority, then id). The shared router pointer is not touched (it is empty when nothing has failed).
-- 2. Wasted first try: alias `submac` asked for max_tokens 64000, which Poolside refuses (400, limit 32768), so every
--    fresh isolate lost one attempt before shrinking. The alias output limit is now 32768; ai-chat also clamps each
--    provider to its known limit (router.ts providerOutCap, override with ai_settings.provider_max_output_tokens).
--
-- Rows before this change: backup_20261023.ai_routes_pre_fix / ai_aliases_pre_fix. Safe to re-run (same result).

with ordered as (
  select r.id,
         row_number() over (
           order by case when p.name ilike '%gemini%' or m.model_id ilike 'gemini%' then 0 else 1 end, r.priority, r.id
         ) * 10 as prio
    from public.ai_routes r
    join public.ai_models m on m.id = r.model_ref
    join public.ai_providers p on p.id = m.provider_id
   where r.alias = 'submac'
)
update public.ai_routes r
   set priority = o.prio
  from ordered o
 where r.id = o.id and r.priority is distinct from o.prio;

update public.ai_aliases
   set max_output_tokens = 32768
 where alias = 'submac' and (max_output_tokens is null or max_output_tokens > 32768);
