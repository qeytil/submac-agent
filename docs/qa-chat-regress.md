# Chat regression harness (PR-H)

Test infrastructure only. One emulator run of the real debug app against production ai-chat checks the chat bugs from
the fix plan (CB-1 … CB-65) and prints one `CB-xx PASS|FAIL|SKIP` line per assertion. PASS means the fixed behaviour;
FAIL means the bug is still there.

## Files
- `integration_test/chat_regress_test.dart`: phases **A** (main chat), **B** (bots), **C** (teams), then **K** (arms
  the cold-start checks). Consolidates `chat_bughunt3*`, `chat_bughunt4_bots` and `chat_bughunt4_teams`.
- `tools/chat_regress_capture.sh`: drives the test on the emulator, runs ADB commands the test asks for (front, net,
  background, doze, notifications, alarms), then the cold-start phases **P2** (force-stop, CB-21) and **P3** (process kill,
  CB-46), and writes `out/logs/verdict.env`.
- `tools/qa_allowance.sh add|revert <uid>`: per-uid `billing.token_balances` row (source 'admin', note
  `qa-regress harness allowance`). No global settings. Revert deletes an unused row; a row that already paid for charges
  is referenced by `billing.usage_ledger` (FK), so it is revoked (`status 'revoked'`, `left_tokens 0`) instead of
  deleting finance history.
- `.github/workflows/chat-regress-emu.yml`.

## Running it
- Push a change to any harness file above, or to `.github/chat-regress.run`, on a `qa/**`, `dev`, `fix/**` or
  `release/**` branch. Never on main. Own concurrency group `chat-regress-emu`, runs queue (no cancel).
- `QA_PHASES` (workflow env) picks phases, e.g. `A` or `BC`.
- `FAIL_ON_CB: '1'` makes a CB FAIL fail the job; leave it `0` until the fix PRs are merged.

## Account, allowance, cleanup
- Repository secrets `QA_EMAIL` + `QA_PW` when set; otherwise the job signs up `qa-regress-<run>-<attempt>@example.com`
  and deletes it at the end with `SUPABASE_SERVICE_ROLE_KEY` (secret). Without that secret the job warns, and the
  account must be deleted from outside.
- Allowance: `SUPABASE_DB_URL` or `SUPABASE_ACCESS_TOKEN` (secrets) let the job add and revert the row itself.
  Without them the job prints the SQL and waits up to `ALLOWANCE_WAIT_MIN` minutes after the build for someone to add it,
  then carries on with the free daily allowance.

## Reliability rules
- The consent box is ticked in the UI; no composer after sign-in is a FATAL that stops the run.
- Approvals: scripted per step; a watchdog answers any other approval sheet, team approval or `ask_user` with "Not now"
  after 20–25 s and logs `QAWARN unanswered-ask <title>`.
- No other-app tasks: "Let it take action" off, phone/apps/browser powers off for bots and team members, team calls to
  those tools refused, `ADB:front` if Telesia loses the front.
- Each step has a hard timeout; the stall detector fails a step after 5 min with no log line, no app progress and no new
  charge (`billing_usage()`; `ai_usage` itself has no user read policy). A cut-off step's leftovers are retired and its
  runs stopped; per-phase budgets (A 38, B 28, C 20 min) skip what does not fit. Job/drive/test: 165/110/95 min.
- The job fails on: drive exit ≠ 0, any `QAERR`, any `QA: STEPFAIL`, a logcat `FATAL EXCEPTION` in Telesia, an uncaught
  Flutter exception, or no `QA: done`.
- CB-3 and CB-10 use a transport seam inside the test (`LlmClient.testClient` wrapper): a fake unknown tool call, and a
  stream cut with `finish_reason: length`. No app code changes.

## Notes from the first run (40207082061, dev 34f75d6)
- `flutter drive` uninstalls the app when it ends; the capture script now passes `--keep-app-running` so P2/P3 can run.
- The team composer in `TeamChat` threw `Bad state: No element` on `enterText`; `say()` now falls back to
  `TeamRun.send` and logs which way it sent.
- CB-3 and CB-10 now also require the run to end on its own (the unknown-tool case looped on the same request).

## Results
- The job summary lists verdict, phases, CB lines and harness errors.
- Logs and screenshots go up as a prerelease `qa-regress-<run>-<attempt>` (asset `.tgz`); only the newest 5 are kept. An
  artifact upload with `retention-days: 1` is tried too (it fails while the artifact quota is full).
