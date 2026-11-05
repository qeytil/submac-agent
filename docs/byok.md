# Bring your own key (BYOK), v1.13.118+188

Owner request 2026-11-03: bring BYOK back (removed in v1.13.0 when everyone moved to the SubMac proxy) as a
professional provider system. The user picks either **SubMac** (our proxy, alias `submac`, default) or any model of
their own providers, and that choice is really used by the opencode agent on the phone.

The original BYOK code is not in this checkout (history here starts at 0c01666; the v1.13.0 removal predates it), so
nothing could be reused verbatim. What survived and is reused: `AiSecretStore`/`SecureAiStore` (flutter_secure_storage,
encrypted shared prefs) from `ai_keys.dart`, the list-model idea of `ai_models.dart`, and the old key names
(`providers`, `liveKey`) are left to the one-time wipe in `LocalStore.forgetModelSetup` (BYOK now uses new names, so
that wipe never touches it).

## Model

```
ByokProvider { id: byok-xxxxxxxx, kind, preset, name, baseUrl, modelsUrl?, headers{}, enabled,
               keys: [ByokKey{id, name, hint(last 4)}], activeKey, rotate,
               models: [ByokModel{id, name?, context?, output?, reasoning?, vision?, tools?, enabled}] }
ByokConfig   { v: 1, providers: [...], chat: "<ref>" }   ref = "submac" | "<providerId>|<modelId>"
```

- Stored in the phone's encrypted storage (`SecureAiStore`): the config without secrets under `byok_config_v1`, each
  key under `byok_key_<keyId>`. Keys are never in the config JSON, never logged, never synced (no repo/cloud call
  touches them) and shown masked (`••••abcd`).
- `kind` decides the wire protocol: `openai` (official, Responses API), `openaiCompatible`, `anthropic`,
  `anthropicCompatible`, `gemini`, `openrouter`.
- Migration: `ByokConfig.fromJson` accepts missing fields and unknown kinds (falls back to openai-compatible), drops
  providers with no id, and reads a bare list (`[...]`) as `{providers: [...]}`.

## Presets (verified 2026-11-03 against official docs)

| Preset | Kind | Base URL | Models list |
|---|---|---|---|
| OpenAI | openai | https://api.openai.com/v1 | GET /models (Bearer) |
| Anthropic | anthropic | https://api.anthropic.com/v1 | GET /v1/models, x-api-key + anthropic-version: 2023-06-01 |
| Google Gemini | gemini | https://generativelanguage.googleapis.com/v1beta | GET /models?pageSize=1000 (x-goog-api-key), keep generateContent |
| OpenRouter | openrouter | https://openrouter.ai/api/v1 | GET /api/v1/models |
| DeepSeek | openaiCompatible | https://api.deepseek.com | GET /models |
| NVIDIA NIM | openaiCompatible | https://integrate.api.nvidia.com/v1 | GET /v1/models |
| TokenHarbor | openaiCompatible | https://tokenharbor.ai/v1 | GET /v1/models (Bearer; Anthropic base is https://tokenharbor.ai) |
| OpenCode (Console/Zen) | openaiCompatible | https://opencode.ai/inference/openai/v1 | GET https://opencode.ai/inference/v1/models |
| Groq | openaiCompatible | https://api.groq.com/openai/v1 | GET /models |
| Mistral | openaiCompatible | https://api.mistral.ai/v1 | GET /models |
| xAI | openaiCompatible | https://api.x.ai/v1 | GET /models |
| Together AI | openaiCompatible | https://api.together.xyz/v1 | GET /models (bare array) |
| Fireworks | openaiCompatible | https://api.fireworks.ai/inference/v1 | GET /models |
| Cerebras | openaiCompatible | https://api.cerebras.ai/v1 | GET /models |
| Moonshot (Kimi) | openaiCompatible | https://api.moonshot.ai/v1 | GET /models |
| Z.ai (GLM) | openaiCompatible | https://api.z.ai/api/paas/v4 | GET /models |
| Ollama (local) | openaiCompatible, no key | http://localhost:11434/v1 | GET /models |
| LM Studio (local) | openaiCompatible, no key | http://localhost:1234/v1 | GET /models |
| Custom OpenAI-compatible | openaiCompatible | any | GET {base}/models |
| Custom Anthropic-compatible | anthropicCompatible | any (a base without /v1 gets /v1, as the Anthropic SDK does) | GET {base}/v1/models |

Sources: tokenharbor.ai/docs/integrations, opencode.ai/v2/docs/console/harnesses (pay-as-you-go base
`https://opencode.ai/inference`, every text model on every API; free models answer 403 outside OpenCode's own provider),
docs.api.nvidia.com/nim/reference/llm-apis, api-docs.deepseek.com, docs.z.ai/api-reference/introduction,
platform.kimi.ai/docs/api/overview, docs.together.ai/reference/models, ai.google.dev/api/models,
platform.claude.com/docs/en/api/models/list.

## Model fetching

`ByokFetch.request(provider, key)` builds the list request per kind and `ByokFetch.parse(kind, json)` turns the
answer into `ByokModel`s, taking what each API tells: context (`context_length`, `context_window`,
`max_context_length`, `max_model_len`, Gemini `inputTokenLimit`, Anthropic `max_input_tokens`), output
(`top_provider.max_completion_tokens`, `outputTokenLimit`, `max_tokens`), vision (OpenRouter input_modalities,
Mistral capabilities.vision, Anthropic capabilities.image_input), tools and reasoning where given. Obvious non-chat
models (embeddings, TTS, whisper, image, moderation) are left out. Gemini follows `nextPageToken` (5 pages max);
Anthropic asks `limit=1000`. Models can always be added by id by hand.

**Test connection** lists models; when a provider has no list endpoint (404/405) and a model is chosen, it sends one
tiny chat request instead. Errors are plain: key refused (401/403), address not found (404), out of credit or rate
limited (402/429), server error (5xx), cannot reach the host, timeout.

## Where the choice is used

### opencode (main chat, bots, teams)
opencode 1.19.5 bundles its provider SDKs inside the binary (`/$bunfs/root/chunk-*.js` lazy imports for
`@ai-sdk/openai-compatible`, `@ai-sdk/anthropic`, `@ai-sdk/google`, `@ai-sdk/openai`, `@openrouter/ai-sdk-provider`,
`@ai-sdk/groq`, `@ai-sdk/mistral`, `@ai-sdk/xai`, ...: checked with grep on the arm64 binary), so no npm install is
needed on the phone. Each enabled BYOK provider becomes one custom opencode provider with id = the BYOK id
(`byok-xxxxxxxx`, never a built-in id, so opencode's models.dev catalogue is not needed):

```json
"byok-1a2b3c4d": { "npm": "@ai-sdk/anthropic", "name": "Anthropic",
  "options": { "baseURL": "https://api.anthropic.com/v1", "apiKey": "{env:SUBMAC_BYOK_1A2B3C4D}", "headers": {} },
  "models": { "claude-sonnet-4-5": { "name": "Claude Sonnet 4.5", "tool_call": true, "reasoning": true,
              "attachment": true, "limit": { "context": 200000, "output": 64000 } } } }
```

npm per kind: openai → `@ai-sdk/openai`, openaiCompatible → `@ai-sdk/openai-compatible`, anthropic(+compatible) →
`@ai-sdk/anthropic`, gemini → `@ai-sdk/google`, openrouter → `@openrouter/ai-sdk-provider`.

- The key is **not written into opencode.json**: `apiKey` is `{env:SUBMAC_BYOK_<ID>}` and the app passes the active key
  in the opencode process environment only (opencode's config variable substitution).
- The JSON comes from Dart (`ByokOpencode.providers`) and is passed to `OpenCode.kt` as `byokProviders` (a JSON
  string) plus `byokEnv`; Kotlin merges only `byok-*` ids next to the lane providers, so lanes cannot be overridden.
- opencode reads config at start: when the BYOK signature (providers, models, active keys) changes, the engine is
  restarted before the next prompt, but only while no turn is running. A prompt naming a BYOK provider the running
  engine does not have yet fails with a clear message instead of an opaque opencode error.
- Traffic: opencode's HTTPS goes through LocalProxy CONNECT (TLS end to end, phone → provider). Nothing passes
  SubMac's servers, nothing bills the SubMac allowance. Local servers (Ollama, LM Studio) on 127.0.0.1 are reached
  directly (NO_PROXY); a LAN address goes through the proxy's plain-HTTP path.
- Selection: `OcLane.pick` reads the owner's chat choice (`ByokStore.chatModel`) when no bot is involved, and a bot's
  `model` setting (`auto`, `submac|<alias>`, or `byok-…|<model>`) for bots. A BYOK choice routes to that provider and
  model for foreground and background turns alike (background lanes exist only for SubMac billing). A choice whose
  provider was deleted/disabled or whose model is gone falls back to SubMac. BYOK bot/team turns are not stopped by
  the bots' SubMac share being paused.
- Key rotation (optional per provider): when a BYOK turn fails with a key/quota error (401/403/429, invalid key,
  quota, credit) and the provider has more than one key with rotate on, the next key becomes active; the engine picks
  it up before the next turn.

### Non-opencode paths
LlmClient side jobs (chat titles, Live call notes, bot/office helper calls, the browser worker on agent/core.dart)
stay on SubMac: they are small, server-shaped (lanes, allowance) and not the agent the user chose a model for.
opencode's own small jobs (titles, summaries) run on the turn's provider, so a BYOK turn's helpers use the BYOK model.
The cloud bot runner (bot-run) never sees keys; a bot set to a BYOK model runs on SubMac when it runs in the cloud.

## UI
- Settings → **Models**: the current chat model, "SubMac" first, then each provider (BrandLogo tile, name, model
  count, enabled switch). Add provider → preset grid → key (masked, optional for local) → Fetch models → searchable
  multi-select list + "Add a model by id" → Save. Edit screen: name, base URL, models URL, extra headers, keys (add,
  name, choose active, remove, rotate switch), models (enable, per-model display name/context/output/flags), Test
  connection, Delete.
- Composer: a small model pill next to Ask · Autopilot, only when at least one BYOK model exists; the sheet lists
  SubMac first, then models grouped by provider.
- Bot setup: "Model" row on the bot's settings uses the same picker.
- Style: `lib/ui/tokens.dart` + `Palette` only (design_guard_test budget unchanged); logos from Simple Icons (CC0)
  for OpenAI, Anthropic, Gemini, OpenRouter, DeepSeek, NVIDIA, Mistral, xAI, Ollama, Moonshot, OpenCode, LM Studio;
  initials for the rest.

## Verified here vs needs a device
- Verified in this sandbox (aarch64): the real opencode 1.19.5 binary started with a generated config containing
  BYOK providers of each npm kind against local mock servers; requests reached the mocks with the right path and auth
  header and `{env:…}` keys (see the commit message / report).
- Needs a phone: Kotlin bridge (`byokProviders`/`byokEnv`), engine restart on change, LocalProxy CONNECT to real
  providers, secure storage, the screens on a real device.
