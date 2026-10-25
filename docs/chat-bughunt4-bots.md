# SubMac chat bug hunt, round 4: BOTS part (investigation only)

Status: **FINAL. The emulator run was blocked by GitHub billing.** No device results. Cleanup is done.

- Branch: `chat-bughunt-4-bots`, created from `chat-bughunt-3` @ 25f3d0e.
- App code: unchanged. Do not merge.
- Status meanings:
  - **confirmed (live)**: reproduced against production ai-chat v41 / DB.
  - **confirmed (host test)**: a red probe test on the current code.
  - **confirmed (code)**: the path is certain from the code, but no run reproduced it.
  - **not tested on device**: the emulator never ran.

## 0. Blocker: the emulator job could not start
| Run | Result |
|---|---|
| 40193905326 (push 6f2f4a1, workflow `chat-bughunt4-bots-emu.yml`) | Failed in under 1 s with `runner_id 0` and no steps. |
| Same run, re-run once via the API | Failed the same way. |

- Check-run annotation: **"The job was not started because recent account payments have failed or your spending limit needs to be increased. Please check the 'Billing & plans' section in your settings."**
- The teams run on `chat-bughunt-4-teams` (16:03 +0330) failed the same way.
- Only the owner can clear this, in GitHub → Submac-Org → Billing & plans: fix the payment or raise the Actions spending limit.
- Running locally is not an option: the sandbox has no `/dev/kvm`, 2 CPUs and no Android SDK.
- I stopped after 2 attempts, as the brief requires.

**Ready to run as soon as billing is fixed.** The harness is on the branch:
- `integration_test/chat_bughunt4_bots_test.dart`, `tools/chatbug4b_capture.sh`, `.github/workflows/chat-bughunt4-bots-emu.yml`.
- Own concurrency group `chat-bughunt4-bots-emu`. Triggers on push to this branch only.
- Hard limits: 165 min job timeout, 110 min drive `timeout`, and a hard timeout on every step.
- A watchdog answers approval sheets with "Not now", cancels `ask_user` after 25 s, and sends `ADB:front` to bring SubMac back to the front if it loses focus.
- Bots have the phone, apps and browser powers switched off, and no main-chat tasks run.
- Force-stop (CB-21) and kill (alarm cold start) phases use a marker file and `P2:`/`P3:` logcat lines.

To re-run:
1. Create a fresh `chatbugs4b-…` account.
2. Put its email and password in the workflow's "Throwaway account" step. It still holds the deleted account.
3. Re-add the per-user allowance (§1).
4. Push any change to the three files.

## 1. Allowance (per user only), and its revert
- **How it is stored.** ai-chat v41 calls the RPC `usage_gate(uid, source)`. That calls `billing.position()`, which sums:
  - the free plan (`billing.usage_daily`);
  - `billing.subscriptions`;
  - payg `billing.token_balances`, per user.
- `billing.is_unlimited()` and `is_tester()` read the **global** `ai_settings` keys (`billing_unlimited`, `billing_testers`), so I did not touch them.
- `billing_adjust()` was not used, because it also posts a `reward_grant` to the finance ledger.
- **Change.** I inserted 1 row into `billing.token_balances`:
  - id `489a3b35-edca-4cc5-92ca-6137de89a284`, user f81a217e-7c78-4b2d-bdfb-fd946e2e0ad0 (chatbugs4b-emu-1792931773@example.com);
  - amount = left_tokens = 50,000,000, source 'admin', expires 2026-10-27 12:36 UTC.
  - Result: `usage_gate` returned plan=payg, today_left 50.2M (chat) and 50.1M (bot).
- **Reverted.**
  - 0 `usage_ledger` rows referenced the balance (all charges came out of the free bucket).
  - The row was deleted (left_tokens was still 50,000,000).
  - Afterwards: 0 balances for `chatbugs4b-%` users, and `usage_gate` was back to plan=free, today_left 193,826.
- No global setting and no edge function was changed.

## 2. Results
| # | Test | Outcome | Evidence | Tokens |
|---|---|---|---|---|
| 1 | Create a bot; does it follow instructions? | Not run (CI blocked). | — | 0 |
| 2 | Edit the bot (instructions, tools: web off) | Not run. | — | 0 |
| 3 | Rendering: table, choices, Somali/Arabic | Not run. | Round 3 device results stand: CB-7 and CB-9. | 0 |
| 4 | Routines: one-off and repeating, on time, duplicate, missed, doze | Device: not run. Host: **CB-35 red** (3 wakes for one 09:00 slot) and **CB-21 red** (armed 1,430 min later). | `hosttest4_kept.txt` | 0 |
| 5 | Owner message during a silent wake | Not run. | Round 3 code proof stands. | 0 |
| 6 | Bot budget and Bot Activity under weighted billing | **Live, confirmed.** Details below this table. | `live4_cb20.json`, DB | 36,315 p / 114 c / 24,176 cached raw; **6,174 charged** |
| 7 | Bots workspace wrong-chat send (CB-16) | Device: not run. Host: **red**. The workspace stays `b:chief` while the composer sends to `conv-nova`. | `hosttest4_kept.txt` | 0 |
| 8 | Attachments per chat (CB-29) | Not run. Code proof stands. | — | 0 |
| 9 | Deleted bot or chat; delete-all while a bot runs (CB-18) | Not run. Code proof stands. | — | 0 |
| 10 | Telegram without a real token (CB-25) | **Partly live.** A dead or fake token gets `{"ok":false,"error_code":401,"description":"Unauthorized"}` from both getMe and getUpdates. The loop's handling follows from the code; see CB-25. | curl, code | 0 |
| 11 | Notifications | Not run. | — | 0 |

**Test 6 details (CB-20).** I made 3 bot-source calls with the same 12.1k-token bot prompt:
- What the app counts per call (`r.tokens` = prompt + completion): 12,146, 12,141 and 12,142, so 36,429 in total.
- What the server charged (`billing.usage_ledger`): 3,663 (uncached), 1,255 and 1,256 (12,064 of 12,105 prompt tokens cached), so 6,174 in total.
- **The app over-counts 5.9× overall, and 9.7× on cached wakes.**
- The bot's `tokensToday` and Bot Activity's usage line, "Busy day, N% of its daily limit", are therefore inflated by that much.

## 3. Verdicts
| Bug | Verdict | Basis |
|---|---|---|
| CB-16 workspace sends to the wrong chat after a notification-style open | **Confirmed** (host test, current code) | Round-2 probe still red: `active=b:chief`, Chief's messages on screen, composer sends to `conv-nova`. |
| CB-17 owner message deleted by a silent wake | **Confirmed (code)**. Not on device. | `bots_controller.dart:396–405` `removeRange(start, …)` and `deleteMessages`. Unchanged since round 3. |
| CB-18 delete-all leaves ghost chats / a bot keeps acting | **Confirmed (code)**. Not on device. | `deleteAllConversations()` never stops runs. Unchanged. |
| CB-20 bot budget counts raw tokens | **Confirmed (live)** | See test 6. Owner chats are included as well; see CB-45. |
| CB-21 missed routine, no catch-up | **Confirmed** (host test) | `BotRoutine.next()` at 08:40 for an 08:30 routine gives tomorrow (+1,430 min). Nothing stores a last-run time. Not tested on device; the force-stop/kill phases are built but did not run. |
| CB-25 Telegram | **Confirmed (code + live API)** | Pairing code: kept only in memory (`telegram_bridge.dart:24/62`, never written to prefs or secure storage). After a restart before pairing, `init()` turns polling back on, but `_handle` drops every message (`chatId == null && pairCode.isEmpty`), so the user can never link and gets no error. Dead token: getUpdates returns 401 "Unauthorized". `_loop` treats it like a network error and retries forever (backoff 3 s… capped at 60 s, about 60 polls an hour), showing "Reconnecting to Telegram…". It never says the token is dead and never stops. |
| CB-29 attachments/drafts leak between chats | **Confirmed (code)**. Not on device. | `_ComposerState._attachments` is never swapped by `_swapDraft`. |
| CB-35 redelivered alarm reruns the routine | **Confirmed** (host test + round-2 device) | `Bots.fire()` has no once-per-slot guard: 2 concurrent fires plus 1 late redelivery give 3 `onWake` calls. In the app, the concurrent one becomes a 15-minute follow-up, as round 2 saw on device. |

None were dropped. Without a device run there is no evidence against any of them.

## 4. New bugs
- **CB-45 (Medium, billing). The owner's own chats with a bot are billed as background bot work.**
  - `agent_stream.dart:114` sends `source:'bot'` for every run in a bot's chat, including the owner typing to it.
  - The server bills by source (`billing.is_bot('bot')` = true): it counts the call in `bot_tokens` against the bots' 50% share (`billing_bot_share`), and `usage_gate` can refuse it with reason `bot_share`.
  - This goes against the app's promise that "Chats with the owner are never cut" (`bots.dart:295`).
  - Live: the call without the background lane also landed in `usage_daily.bot_tokens` (all 6,174 tokens were bot_tokens).
  - Fix: send `source:'agent'` (or `bot-chat`) when the run is not a wake, so only `_botWakeConvs` runs say `bot`.
- **CB-46 (Medium, provisional, code). A routine alarm that cold-starts the app can be lost silently.**
  - `Bots.fire()` re-arms the routine (`arm(b)`) before it calls `onWake`.
  - `_botWake` returns at once when `activeProvider == null` (`bots_controller.dart:219`), with no journal line and no follow-up.
  - If the alarm reaches Dart before the provider is restored, that day's run is consumed and lost.
  - The kill phase of this harness (P3) is built to show this on device.

## 5. Token totals
- Emulator: **0** (the job never started).
- Live probe: 3 `ai_usage` rows (gpt-oss:120b, source `bot`): 36,315 prompt / 114 completion / 24,176 cached raw. Server-weighted charge: **6,174**, from the free bucket. The payg balance was untouched.
- `ai_usage` rows are kept; the account is deleted.

## 6. Cleanup
- Allowance reverted (§1).
- `delete from auth.users where email like 'chatbugs4b-%@example.com'` deleted **1** row (chatbugs4b-emu-1792931773@example.com). Count afterwards: **0**.
- The workflow file on the branch still names that (now deleted) throwaway account.

## 7. Files
- This report: `/workspace/work/chatbugs4/bots_report.md`. Same text as `docs/chat-bughunt4-bots.md` on the branch.
- Live probe: `/workspace/work/chatbugs4/live4.py`, `/workspace/work/chatbugs4/live4_cb20.json`.
- Host tests:
  - `test/zz_bughunt4_bots_test.dart` (CB-35, CB-21), new on the branch;
  - round-2 probes `test/zz_chat_bughunt2_test.dart` re-run;
  - output in `/workspace/work/chatbugs4/hosttest4_kept.txt`.
- Harness: `integration_test/chat_bughunt4_bots_test.dart`, `tools/chatbug4b_capture.sh`, `.github/workflows/chat-bughunt4-bots-emu.yml`.
