# Live edge function versions (exported 2026-10-21 from project moeemacbvsueekuvfjbo)

Exported with the Management API `GET /v1/projects/{ref}/functions/{slug}/body` (multipart, one module each).
Every `index.ts` in this folder matched the live deployment at export time.

| function | live version | verify_jwt | last deploy (UTC) | note |
|---|---|---|---|---|
| ai-chat | 30 | true | 2026-10-21 15:41 | v30 = speed pass on top of the synced v29 (see project-state); v29 source is in commit 4120ab6 |
| ai-admin | 14 | true | 2026-10-20 18:03 | adds Updates tab actions (app_releases, bucket app-updates) |
| account-delete | 6 | true | 2026-10-20 13:36 | also removes the user's live site previews |
| push-send | 5 | true | 2026-10-18 17:04 | unchanged |
| bot-run | 8 | true | 2026-10-21 14:14 | unchanged |
| site-preview | 4 | true | 2026-10-20 13:08 | new in repo: 7-day Cloudflare Pages preview links |
| billing-checkout | 4 | true | 2026-10-21 09:15 | new in repo: bundled (shared payments code inlined, Sifalo) |
| billing-webhook | 4 | **false** | 2026-10-21 09:15 | new in repo: bundled |
| billing-return | 4 | **false** | 2026-10-21 09:15 | new in repo: bundled |
| billing-reconcile | 5 | true | 2026-10-21 09:17 | new in repo: bundled |

The billing functions were deployed as bundles, so their `_shared/payments/*` sources are inlined in each file.
Since branch `feat/billing-coins`: `billing-*/index.ts` are the one-line source wrappers over `functions/_shared/payments/*`. `deno bundle --platform deno`
of those sources (deno 2.9.7) is byte-identical to the exported live bundles above (checkout v4, webhook v4, return v4, reconcile v5), so live = repo.
DB objects they use (app_releases, site_previews, billing tables) have no migration file in the repo yet.
Since branch `feat/billing-coins` (2026-10-22): `ai-chat/index.ts` is **live v30 + the billing path** (behind `ai_settings.billing_enabled`, **not deployed**).
Flag off it behaves exactly like live v30; the pristine v30 export is kept as `supabase/tests/ai-chat/baseline/ai-chat.v30.ts` (md5 a7002d40…) and
`supabase/tests/ai-chat/run.sh` checks flag-off parity against it. See `docs/monetization/ai-chat-billing-port/README.md`.
Since branch `rebuild/dev2-billing` (2026-10-23): `_shared/payments/core.ts` calls the billing v2 payment RPCs (`billing_payment_*`,
migration `20261023_billing_v2.sql`) and takes `{plan, tokens?}` instead of `{product|coins}`. **Not deployed**: deploy the four billing-*
functions only after `20261023_billing_v2.sql` is applied (they no longer call the coin-era `billing_*_purchase*` RPCs).

## 2026-10-23 deploy (rebuild week 1, owner OK)
- DB: `20261023_billing_v2.sql` (applied 10:21 UTC as `billing_v2_20261023`, before this deploy) and `20261023_router_single_model.sql`
  (applied 10:45 UTC as `router_single_model_20261023`). `billing_enabled` stays false.
- ai-chat deployed 10:46 UTC (deploy v34, verify_jwt true) from main f5aae44 as one esbuild bundle of `ai-chat/index.ts` + `router.ts` +
  `billing_gate.ts` (no external imports). Then redeployed with the PLAN 1.8 token check (`jwt_verify.ts`), see below.
- bot-run deployed 10:50 UTC (deploy v11, verify_jwt true) from main f5aae44 (single file).
- Rollback sources: ai-chat before = commit 246f66c (live v33), bot-run before = commit 3730426 (live v8).
- `supabase/config.toml` pins verify_jwt for every function (PLAN 1.8).

## 2026-10-23 owner fixes (ai-chat v38, bot-run v12)
- DB: `20261023_submac_gemini_first.sql` (applied 11:10 UTC as `submac_gemini_first_20261023`): alias `submac` routes renumbered with
  the Gemini routes first (rest in their old order) and `max_output_tokens` 64000 -> 32768. `20261023_eat_day.sql` (applied 11:10 UTC
  as `eat_day_20261023`): the legacy daily counters (`ai_user_daily`, `live_call_daily`) are keyed by the EAT date, so the allowance
  resets at 00:00 EAT. Rows before: schema `backup_20261023`, tables `*_pre_fix` (routes, aliases, settings, old function bodies).
- ai-chat v38 (verify_jwt true, esbuild bundle as before): `x-submac-resets-at` = next 00:00 EAT with billing on or off; per-provider
  output clamp (`router.ts providerOutCap`, Poolside 32768, `ai_settings.provider_max_output_tokens` overrides); Live charges parked
  with `usage_charge_enqueue` after two failures; coin leftovers removed. Rollback source: ai-chat = commit c845d9b (v37).
- bot-run v12 (single file): allowance day = EAT date. Rollback source: commit c845d9b (v11).
- ai-admin: `reset_user_today` / `live_reset_user_today` use the EAT date in the repo; **not deployed** (live v18 is older than repo).

## 2026-10-26 account-delete v11 (release 1.13.104)
- account-delete deployed 10:52 UTC (v11, verify_jwt true): also wipes `feedback-screenshots/<uid>/`. Rollback source: v10 = this file before
  the change (commit 0a12382f; live since 2026-10-20 13:36 UTC). Smoke: throwaway account uploaded a screenshot, deleted itself, folder gone.
