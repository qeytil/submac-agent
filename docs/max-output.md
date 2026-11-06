# Max output: why replies were cut short, and what changed (2026-11-06, 1.13.137+207)

Owner's report: something limits the model's maximum output tokens for the main agent and the bots; replies get cut.

## Every cap found

| # | Where | Value | Who it hit | Status |
|---|---|---|---|---|
| 1 | `usage_gate()` → `reply_cap = least(ai_settings.billing_reply_cap_tokens, today)`; ai-chat `replyCap()` clamps every reply's `max_tokens` to it (`billing_enabled` is true) | **8192** | every SubMac reply: owner chat, bots, teams (app and cloud) | **server, awaiting approval** (`supabase/pending/max-output/max_output.sql` block 1) |
| 2 | `ai_aliases.max_output_tokens` for `submac` (ai-chat serves every chat call on this alias) | 32768 | every SubMac reply | server, awaiting approval (block 2: 65536) |
| 3 | ai-chat `makePlan`: `state === "light"` → `grace_max_output_tokens` | 400 | users in the grace state only (deliberate) | unchanged |
| 4 | ai-chat `roomW`: `min(max_tokens, window - prompt - 256)` | per route | big prompts on 128k routes (correct) | unchanged |
| 5 | ai-chat: no per-model output maximum (only `PROVIDER_MAX_OUTPUT` poolside 32768 + `provider_max_output_tokens`) | — | first try on a route that refuses a big max_tokens | server, awaiting approval (block 3 + ai-chat v46 patch) |
| 6 | opencode: asks `min(model limit.output, OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX ‖ 32000) ‖ 32000`; SubMac's models had no `limit` (`android_native/OpenCode.kt` config) | 32000 | owner chat, bot chats, team turns on SubMac | **fixed in app** |
| 7 | `ByokOpencode.defaultOutput` for BYOK models with no listed output limit (OpenAI's list has none) | 8192 | owner/bots on their own providers | **fixed in app** |
| 8 | opencode ends a turn quietly on `finish: "length"`; ai-chat also ends a reply it cut with `finish_reason: "length"` (`cutTail`) | — | everything on opencode | **fixed in app**: auto-continue |
| 9 | `_teamAsk` default (`bots_controller.dart`), team combined answer / lead (`team_run.dart` 2000), member parts 1500, lead plan 900 | 900–2000 | team answers (plain calls, no length handling) | **fixed in app** (16384 / 4096 + continue) |
| 10 | `_botConsult` (bot_ask, `bots_controller.dart`) | 1200 | a bot's expert answer to another bot | **fixed in app** |
| 11 | `createBotFromText` JSON | 1500 | new-bot JSON | raised to 4096 |
| 12 | cloud `bot-run` `work()` step `max_tokens` | 1200 | cloud bot replies | server, awaiting approval (`bot-run-v15-to-v16.patch`) |
| — | Deliberately small, unchanged: bot heartbeat 60 (app and cloud), team floor 160, chat title 200, office one-liner 400, live recap 400, byok probe 1 | | yes/no and one-liners | unchanged |
| — | No app-side truncation of streamed reply text was found (tool-output clips only: tools 12000 chars, MCP 8000, etc.) | | | — |

## App changes
- `lib/services/output_limits.dart`: `OutputLimits` (SubMac 65536 — the server clamps it per route; unknown BYOK model
  16384; family table for known models; opencode ceiling = largest configured limit, max 131072) and
  `ReplyContinuation` (continue a `length` stop up to 3 times; join pieces; the note when still cut).
- opencode config (`OpenCode.kt`, `OcChannel.kt`, `OpenCodeEngine.startLimits`): SubMac models get
  `limit: {context: 0, output: 65536}` (context 0 keeps opencode's previous no-auto-compaction behaviour), and the
  engine gets `OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX` = the largest configured limit.
- BYOK: `ByokOpencode.outputOf` = provider figure → family maximum → 16384, never above half the model's window
  (opencode compacts when tokens ≥ context − output).
- `OpenCodeTurn`: tracks the newest assistant message's `finish`; `shouldContinue` / `beginContinue` / `leftCut`;
  continued text glues onto the cut text (`OcPart.continues`, `chainText`, `answer`). Chat turns
  (`agent_runner._runAgent`) and team turns (`_teamTurn`) send `ReplyContinuation.prompt` in the same session; after
  3 continuations a still-cut reply gets a note.
- `LlmClient.complete(continues:)` + `completeOnce` + `answerOf`: plain calls continue a `length` stop.

## Server changes awaiting approval (nothing deployed, nothing written)
`supabase/pending/max-output/`:
- `max_output.sql` — block 1 (reply cap 8192 → 65536) is the main fix and works without any deploy; block 2 (alias
  32768 → 65536); block 3 (`ai_models.max_output_tokens`, gemini 65536, `ai_config_lite` returns it). Rollback at the end.
- `ai-chat-v45-to-v46.patch` — `providerOutCap` also honours the route's own `max_output_tokens`. Deploy after block 3.
- `bot-run-v15-to-v16.patch` — cloud bot steps ask for 16384 instead of 1200 and continue a `length` stop twice.
  (Assumes `supabase/functions/bot-run/index.ts` is live v15.)
