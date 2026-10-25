-- Plan 1 step 1: real context windows for models whose size was verified (2026-10-18).
-- Source: OpenRouter's public model list (context_length) for OpenRouter routes, and the
-- Gemini 1,048,576-token window for Google Gemini routes. Every other model keeps the
-- 128000 default until its provider's number is confirmed; that default is below their
-- real windows, so the fit check stays on the safe side.
-- Applied to production 2026-10-18.
update public.ai_models m set context_window = v.w
from (values
  ('OpenRouter',    'nvidia/nemotron-3-ultra-550b-a55b:free', 1000000),
  ('OpenRouter',    'nvidia/nemotron-3-super-120b-a12b:free', 262144),
  ('OpenRouter',    'nvidia/nemotron-3.5-super-vl:free',      1000000),
  ('OpenRouter',    'cohere/north-mini-code:free',            256000),
  ('OpenRouter',    'liquid/lfm-2.5-2.6b:free',               65536),
  ('Google Gemini', 'gemini-3.6-flash',                       1048576),
  ('Google Gemini', 'gemini-3.5-flash-lite',                  1048576),
  ('Google Gemini', 'gemini-3-flash-preview',                 1048576)
) as v(provider, model_id, w), public.ai_providers p
where p.id = m.provider_id and p.name = v.provider and m.model_id = v.model_id;
