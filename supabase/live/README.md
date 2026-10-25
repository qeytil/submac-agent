# Live ai-chat bundles

`ai-chat-v42.js` is the exact single-file source deployed as ai-chat **v42** (function 44de3add-89df-44df-9ae0-fa367ecb6930,
2026-10-25 15:28:06 UTC, ezbr_sha256 4dcc98eb…4f1e). It is live v41 (weighted billing, deployed from a bundle, never
committed as TypeScript) plus S-1:

- router section = `deno bundle supabase/functions/ai-chat/router.ts` (this branch), byte-for-byte;
- index section = v41 + CB-23 window header + `routerHome` / `homeOf` wiring.

`supabase/functions/ai-chat/index.ts` on dev is still the **v40** TypeScript (no weighted billing); this branch adds only
the S-1 edits to it. Deploy from `ai-chat-v42.js`, not from `index.ts`, until the v41 billing changes are ported.

Tests: `deno test supabase/functions/ai-chat/router_test.ts` (19) and
`deno test --no-check -A supabase/live/ai-chat-v42_window_test.ts` (CB-23 on the bundle).
