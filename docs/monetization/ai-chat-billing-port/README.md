# ai-chat billing path: ported onto v30 (2026-10-22)

**Status:** ported. `supabase/functions/ai-chat/index.ts` on this branch is **dev's v30 plus the billing path**, all behind
`ai_settings.billing_enabled`. With the flag off (missing or `false`) every answer, header, database call, provider request and
Server-Timing phase is v30's: the parity suite checks this against a pristine copy of v30 (`supabase/tests/ai-chat/baseline/ai-chat.v30.ts`,
md5 a7002d40…), cold and warm isolate.

**Not deployed.** Before flipping the flag in production: deploy ai-chat with the flag off → apply
`20261021_billing_usage_retry.sql` (and `20261021_billing_search_path.sql`) → schedule `billing_reconcile_usage()` → flip the flag on a test window.

## What is here
- `index.v27-billing.ts`: the earlier billing path written on ai-chat **v27** (supabase-js). Historical reference only; the tests
  no longer use it.
- `supabase/tests/ai-chat/`: Deno tests with PostgREST mocked at the fetch layer (`mock_rest.ts`; each module instance gets its own
  `SUPABASE_URL` host so its calls are logged separately). `run.sh` runs them: **182 passed, 0 failed** (2026-10-22, deno 2.9.7):
  152 flag-off parity vs v30 (flag missing/false × cold/warm × 38 scenarios), 18 flag-on, 12 hardening.

## How it sits on v30
- **DB access**: all billing calls use v30's `rpc(fn, args)` (never throws, `{data,error}`). Two small helpers were added:
  `usageOrThrow()` (today's usage for the fail-closed fallback when no gate answer is at hand; unlike `rows()` it throws on a failed
  read, so an unreadable balance answers 503 `busy` instead of a full free tier) and `insertRow()` (the Live `live_calls` row).
- **Pre-checks**: on a **warm** isolate (settings cached) `billing_precheck` + `billing_multipliers` start together with `ai_gate`;
  the precheck's fallback reads today's usage from the gate's answer. On a **cold** isolate the flag is only known once `ai_gate`
  brings the config, so the precheck runs right after it (one extra round trip, cold isolates with billing on only). Server-Timing
  gains `billing` (ms until entitlements were in hand) only when the flag is on.
- **makePlan(cfg, body, alias, state, bx?)**: `bx` carries entitlements, multipliers, balance. With it: free users Standard-only
  (own and spare routes), grace-alias swap or 402 `paid_model`, reply size capped by the balance (`replyCap` inside `roomOf`, so the
  max_tokens shrink retry uses it too), 429 `too_big_for_balance`. Without it: v30 planning unchanged.
- **Early (speculative) model call**: flag off, exactly v30. Flag on: started only when this isolate already knows the user's
  entitlements (precheck cache), planned from them; after the fresh precheck the plan is rebuilt and the early call is kept only if
  the first route and the exact request body match, otherwise it is aborted (nothing reached the client) and the loop starts over.
- **Refusals** (`daily_limit`, `payments_pending`, `background_paused`) go through v30's `refuse()` (abort early call, mark gate).
- **/status**: billing block + `x-telesia-balance`; precheck in parallel with `ai_gate` + `live_minutes_left` when warm.
- **Live / transcribe / image**: as in the v27 path (`billing_live_charge` per heartbeat, grace on outage, Standard-only media for free
  users, charged with `media:<uuid>` ids); image keeps v30's `ensureKeys(cfg, [r])` per route.
- **Charges**: `billing_consume` with `chat:<uuid>`, retry → `billing_consume_enqueue` → in-isolate list (`billing_unsaved`).
  Cancelled streams are charged only for output produced.
