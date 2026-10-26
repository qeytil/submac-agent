# ai-chat v43 (S-2, CB-45 server part)

`ai-chat-v43.js` is the exact single-file source deployed as ai-chat **v43** (function 44de3add-89df-44df-9ae0-fa367ecb6930,
2026-10-25 16:03:14 UTC, ezbr_sha256 0683f848…672a, file sha256 0df8ff47…3fdd). It is `ai-chat-v42.js` (S-1, PR #5) plus two edits:

- `billSource()`: `bot-chat` (the owner typing in a bot's chat) is returned as-is, even with `x-submac-lane: background`.
  `billing.is_bot('bot-chat')` is already false in the DB, so it is charged to the user's chat bucket like `agent` and is
  never refused for `billing_bot_share`.
- handler: `background = internal || (lane == background && !chatLane(source))`, so a `bot-chat` request is always the user lane
  (chat precheck cache key, no background allowance / `background_paused`).

`ai_usage.source` and `billing.usage_ledger.source` keep `bot-chat` as its own value. No database change was needed:
`supabase/sql/20261025_verify_is_bot_bot_chat.sql` is a read-only check (is_bot false; no CHECK constraint on source).

Tests: `deno test supabase/functions/ai-chat/billing_gate_test.ts` (new CB-45 case) and
`deno test --no-check -A supabase/live/ai-chat-v43_bot_chat_test.ts` (3 pass on v43; 2 fail with `BUNDLE=./ai-chat-v42.js`).

Rollback: redeploy `ai-chat-v42.js` (creates a new version). The app keeps working either way: before v43 it sends `agent`.
