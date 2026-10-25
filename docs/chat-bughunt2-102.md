# Chat bug hunt 2 (v1.13.102 base): findings CB-14 to CB-37 (investigation only)

Base: main `a891a83` (v1.13.102+172). Branch `chat-bughunt-2` is for investigation only and must not be merged.
Emulator run: GitHub Actions run 40177122711 (`chat-bughunt2-emu.yml`, head 17b0ef5), completed with conclusion *success*. The harness reports success even when its steps fail. Read this report for the real outcome.
Throwaway accounts: emu `chatbugs2-emu-1792917306@example.com` (uid c7cd704a…) and live `chatbugs2-live-1792917929@example.com` (uid 4e7b352d…). Both were deleted after the run. Their `ai_usage` rows are kept.

## 0. What the emulator run actually tested

**Every UI step was blocked by the 18+ consent gate.** The fresh throwaway account opened on the "Before you start" screen (age 18+ and Terms checkbox, then "Agree and continue"). The harness never ticks that box, so `box()` found no chat `TextField` and every `type()` threw `no chat box`.
- I pixel-diffed all 17 screenshots. Below the status bar they are identical: every one shows the consent gate.
- No screenshot shows a product bug. I kept one copy as evidence of the harness failure: `shots/harness_consent_gate_all17.png`.
- Timeline (UTC): sign-in at 08:49:16. t1 to t9 each failed in about 4 s (08:49:20 to 08:49:52). t10 at 08:50:00, t11 at 08:50:08 to 08:50:21. Bots started at 08:50:23, the team at 08:51:05, and `QA: done` came at 08:52:28.
- **That is why the bot and team calls started at 08:50.** The main-chat block was meant to take about 45 minutes but collapsed to about 1 minute.
- **Main-chat tasks t1 to t9 did not run.** `ai_usage` has no agent row for uid c7cd… before 08:50:00, so no request reached the server.
- t10 and t11 only got as far as their programmatic `st().send(...)` calls.
- The bot, routine and team steps call `AppState`, `Bots` and `TeamRun` directly, so they did run.
- b5 and d1 needed the composer, so they failed before testing anything.

Two other harness defects affect how to read the bot results:
- **b3 is a false positive.** `Bots.hire()` sets `lastWake = now`, and the harness took "lastWake under 5 min ago" to mean "the routine fired". So `fired=true` at 08:50:50 came from the hire at 08:50:23, and the step ended before the 08:52 alarm.
  - The real Android alarm did fire. `ai_usage` has a full bot wake at 08:52:04 (14,196 prompt / 165 completion tokens), and the 08:52 alarm is gone from `alarms_last.txt`.
- **c1 exits after 2 s.** `TeamRun.busy()` does not cover member reply jobs (see CB-34). As a result, c1's answer was posted during c2.

Harness fixes for round 3 (not pushed, because editing `integration_test/` re-triggers the workflow and creates a new account):
1. After sign-in, tick the consent checkbox and tap "Agree and continue", or pre-accept consent for the QA account.
2. In b3, compare `lastWake` against the time the routine was armed.
3. In c1, wait on `Offices.I.queue` as well as `TeamRun.busy`.
4. Fail the job when there are `QAERR` lines.

## 1. Real-task results (emulator, uid c7cd704a)

| Task | Ran? | Outcome | Steps / tools | Route, tokens (`ai_usage`) |
|---|---|---|---|---|
| t1 trip, t1 choice tap | No | Consent gate: `no chat box`. The choice step logged 0 cards. | none | none |
| t2 phones, t3 code, t4 email approval, t5 Somali, t6 Arabic, t7 multitool, t9 stop/resume | No | Consent gate | none | none |
| t8 steer | No | Consent gate. `t8_check` logged Kigali=false, Nairobi=false because nothing ran. | none | none |
| t10 photo | Part only | Photo turn OK: "The shape in the picture is a red circle." The follow-up with no photo was never typed (gate), so CB-23 is not settled by this step. | 1 model call, no tools | Gemini `gemini-3-flash-preview`: 12,240 prompt / 10 completion, 2.6 s. Title: Ollama `gpt-oss:120b`, 129 / 79. |
| t11 too long (530,434-char paste) | Yes | Error after 12 s: "Request too large to send in one go. Start a new chat or send less at once." No reply, no summary, `banner=null`. | 0 steps | **No row.** ai-chat returns 413 `too_long` before any model call (`promptEstimate > max_prompt_tokens`), so the server does not log the attempts (see CB-30). |

Live API probe (uid 4e7b352d, 08:46 UTC, `chatbugs2_logs/live2.py`):
- **Tools history plus a new image:** the first try on Gemini `gemini-3-flash-preview` timed out (status 0, 8.6 s). It moved to `gemini-3.6-flash` (attempts=2) and returned correctly: 1,262 prompt / 80 completion tokens, with a `get_weather(Nairobi)` call. Fallback works.
- **Photo follow-up without the image:** this went to Ollama `gpt-oss:120b` (137 / 84) and answered: *"I'm sorry—I can't see the image, so I can't tell you the colors…"*. **This confirms the routing half of CB-23.**

## 2. Bot and team findings (emulator)

| Step | Result |
|---|---|
| b1 create bot "Ledger" (rule: exactly 3 bullets, no tables) | OK. 3 bullets, no table. Ollama `gpt-oss:120b`, 13,492 / 97, 1.1 s. |
| b2 edit instructions (Somali, one paragraph, no bullets) | OK. The change applied on the next turn: Somali paragraph, 0 bullets. It used `skill_use(so-invoice-receipt)`. 2 calls: 9,039 / 33 and 9,353 / 171 (8,864 cached). |
| b3 real routine alarm at 08:52 | Harness false positive (see section 0). The real alarm fired and ran a full wake at 08:52:04 (14,196 / 165). Product behaviour is OK. |
| b4 same routine alarm delivered twice | **Bug, CB-35.** `fire()` returned `[true, true]` and traces went up by only 1. The second delivery became a follow-up for 09:05 to "Send me one practical bookkeeping tip." `alarms_last.txt` shows the 09:05:53 RTC alarm armed. The wake that ran: 14,120 / 125. |
| b5 owner message during a wake | The wake started (`wake running=true`, 14,171 / 75). The owner message was blocked by the gate, so **CB-17 was not tested**. |
| b6 bot budget | `tokensToday=60,676`. Of that, 32,185 is from the two owner chats ("You: …" traces 13,589 and 18,596) and the rest from wakes. These are raw prompt+completion counts with no cache weighting, even though 44,016 of the 74,781 bot prompt tokens were cached. **CB-20 confirmed.** (budgetK=0, meaning unlimited, so the over-budget path was not triggered.) |
| c1 team job (Hodan lead, Nova researcher) | **Bug, CB-36.** The team intro promised "Hodan will suggest a plan and wait for your go-ahead". Instead the floor call (409 / 38) routed the 3-part job (venues + budget + checklist) as a plain reply from Hodan. There was no plan, `awaitingGo=false`, and `busy=false` after 2 s. Hodan's answer took 6 calls (08:51:08 to 08:51:25, about 12 to 14k prompt each) and was posted after c2's message. |
| c2 team stop | **Bug, CB-34.** At stop time (67 s) `busy=false`, although the members were still doing reply jobs. So "stop" took the not-busy path: a 471 / 55 floor call at 08:52:16 decided "who answers 'stop'", and nothing was cancelled. The office-chairs request never got a reply in 75 s. 3 Gemini office calls after 08:52 returned 15 to 82 tokens and posted nothing. |
| d1 delete all while running | Blocked by the gate, so **CB-18 was not tested** by the run. Code evidence is below. |

Token totals for uid c7cd704a: agent 12,240 / 10 (1 call); title 129 / 79; bot 74,781 / 697 (7 calls, 44,016 cached); office 152,898 / 1,546 (16 calls, 99,376 cached). Bots and the team used Ollama `gpt-oss:120b`, except 3 office calls on `gemini-3-flash-preview` at 08:52.

## 3. Bug list

Status meanings:
- **confirmed**: reproduced by a probe that fails (unit test, emulator or live).
- **confirmed (code)**: the path is certain from reading the code, but no run reproduced the outcome.
- **provisional**: not reproduced yet.

### High
**CB-14 ChatStore flush race corrupts the chat file.** Confirmed (unit test `CB-14`, `chatbugs2_logs/run2.log`).
- Repro: overlapping `save()` flushes on one chat.
- Evidence: 8 of 40 rounds failed. The file was either not JSON (6.1 MB) or stale (1,500 rows on disk while the chat holds 10). On the next start `ChatStore.chat()` returns null and the chat is lost.
- Fix: serialise flushes per chat with a mutex or chained future. Write to `*.tmp` then rename. Keep the last good file as a backup.

**CB-16 Bots workspace sends to the wrong chat.** Confirmed (unit test, `run1.log`).
- Repro: with the Chief on screen, tap a notification for Nova.
- Evidence: the workspace still shows the Chief, but the composer sends to `conv-nova`.
- Fix: drive the workspace's active bot from `currentId`, or open the workspace on the tapped bot.

**CB-24 A cut-off stream is saved as complete.** Confirmed (unit test, `run3.log`).
- Repro: the SSE stream closes without a `finish_reason` or `[DONE]`.
- Evidence: `streamChat` returned `finish=null` with half a table, and the runner saves that as the final answer.
- Fix: treat end-of-stream without `finish_reason` or `[DONE]` as a drop (`LlmException` status 0) so the reissue path runs.

**CB-35 (new) A redelivered routine alarm runs the routine again 15 minutes later.** Confirmed (emulator b4).
- Repro: `Bots.I.fire(alarmId)` twice at once. Android can redeliver an alarm after a process restart.
- Evidence: results `[true, true]` with only 1 trace. A follow-up was set for 09:05 ("Send me one practical bookkeeping tip.") and its alarm was armed at 09:05:53.
- Why: `_botWake` → `_wakeMayClaim` fails → `_wakeLater` adds a 15-minute follow-up (`bots_controller.dart:309`). `hasPendingFollowup` only removes duplicate follow-ups, not the routine that is already running.
- Result: a "message" routine messages the owner twice, and a "work" routine costs about 14k tokens twice.
- Fix: give each routine wake a key (`routineId + scheduled minute`) and drop a second fire with the same key. Only defer genuinely different work.

### Medium
**CB-15 Router stuck on Ollama with no swap-back, and 400s counted as route failures.** Provisional.
- In this run the office route did move to Gemini at 08:52:08 and back to Ollama at 08:52:16, which is weak counter-evidence for "stuck".
- No 400s were seen. A probe that injects a 400 is needed.
- Fix: count only 5xx and timeouts as route failures, and add a timed swap-back.

**CB-17 Owner message deleted by a silent bot wake.** Provisional (not tested; b5 was blocked by the gate). Re-run b5 after the harness fix.

**CB-18 Delete-all leaves ghost chats.** Provisional, with code evidence.
- `ChatController.deleteAllConversations()` (`lib/state/chat_controller.dart:141`) never stops `runs`. `deleteAccount()` does stop them (line 165).
- A run still working then calls `_save(convId, …)` and writes the chat back.
- Fix: stop and await every run, and clear `_imagesOnce` and drafts, before `repo.deleteAllConversations()`.
- To confirm: d1, after the harness fix.

**CB-19 Team member posts after Stop.** Confirmed (unit test, `run1.log`).
- Evidence: after "stop", Nova posted "I could not finish my part this time."
- Fix: when `_stopped` is set, suppress failure posts from cancelled cores.

**CB-20 Bot budget counts raw tokens, including owner chats.** Confirmed (emulator b6).
- Evidence: 60,676 "today", of which 32,185 is the owner's own chats. Cached tokens are counted at full weight.
- Fix: count only background wakes, and use weighted tokens from the `x-submac-usage` or cost headers.

**CB-21 Missed routines have no catch-up.** Confirmed (unit test, `run1.log`).
- Evidence: boot at 08:40 with an 08:30 routine not yet run today. The next run is set for tomorrow, 1,430 minutes away.
- Fix: on boot or arm, if today's slot passed less than N hours ago and has not run, schedule a catch-up within a minute.

**CB-23 A photo follow-up goes to a no-vision route, and the window is set to 1M.** Routing half confirmed (live probe); window half provisional.
- Evidence: the follow-up with the "[Photo was shown earlier]" note went to Ollama `gpt-oss:120b`, which answered "I can't see the image". The x-submac-window headers were not captured.
- Fix: re-attach the last image, or keep vision routing for N turns after a photo. Clamp `ContextWindow` to the smallest route actually used.

**CB-29 Drafts and attachments leak to other chats.** Provisional.

**CB-30 Too-long fallback drops the summary, and huge pastes are tried four times.** Outcome confirmed (emulator t11); retry count confirmed (code).
- Evidence: a 530 KB paste ended after 12 s with only the raw server sentence, no `ai_usage` row, and no guidance in the app's own words.
- Code path:
  1. The 1st 413 compacts; if compaction fails, it sets `_trimTo=16`.
  2. The 2nd 413 skips the too-long branch, because `_trimTo != 0`.
  3. It then falls into the drop-reissue path twice, because `too_long` is not in `isFinal` (`agent_runner.dart:636-658`, `llm_client.dart:25`).
  4. Total: 4 uploads of about 530 KB each.
- No server count was possible: `function_edge_logs` was not queryable through the logs tool ("Table does not exist").
- Fix:
  - Add `too_long` to the codes the drop path never reissues.
  - Add a client-side size guard (about 120k tokens, roughly 480 KB) before upload, offering "attach as a file" or "summarise in parts".
  - Keep the compaction summary when falling back to `_trimTo`.

**CB-34 (new) Team "stop" does not stop member reply jobs, and `busy()` reports false while members work.** Confirmed (emulator c1/c2, plus code).
- `TeamRun.busy()` only covers `_run` and `_propose`. Member replies started through `Offices.askBot` are queued `OfficeJob`s outside `running`.
- Evidence: `busy=false` 2 s into c1, while Hodan's reply ran 6 calls for 17 s more and was posted after c2's message. At stop (67 s), `busy=false`, so "stop" went to `_decide`: a floor call (471 / 55) decided who answers "stop", and no job was cancelled.
- Fix:
  - Make `busy()` include queued and running office jobs for that office.
  - Make `isStop` cancel and clear them (`Offices.I.queue.removeWhere(officeId)` plus `stop()` on the running cores) whatever `busy` says.
  - Give the owner's stop its own system post.

**CB-36 (new) The team intro promises a plan, but a multi-part job is answered as a single reply.** Confirmed (emulator c1).
- Evidence: the system message says "Hodan will suggest a plan and wait for your go-ahead". The floor model returned no `team_task` for "venues with prices, a budget, and a checklist", so Hodan answered directly. There was no plan card and no Go.
- Fix: in a team with 2 or more members, treat a job that lists several deliverables as `team_task` (heuristic plus model), or change the intro copy to match.

**CB-37 (new) A follow-up to the team is silently dropped while an earlier reply is still running.** Provisional (emulator c2).
- Evidence: "Research the five best suppliers of office chairs…" was sent while Hodan's c1 reply was in progress. The floor call (417 / 46) ran, and 3 later Gemini office calls returned 15 to 82 tokens, but no post answered it in 75 s and nothing told the owner.
- Fix: when the floor picks nobody, or a job ends in `[no reply]` for a direct request, post "Nobody picked this up". Add a test that sends two requests back to back.

**CB-22 Try again repeats sends.** Provisional.

**CB-25 Telegram pairing, group, 429 and raw-error issues.** Provisional.

**CB-26 No attachment size limit.** Provisional. Related: t11 shows that text pastes have no client limit either (CB-30).

### Low
**CB-27 Error card is English-only and shows raw `$e`.** Provisional. t11 showed the server's English sentence verbatim, which is consistent with CB-27.

**CB-28 TTS sets no language and truncates at 3,900 characters.** Provisional.

**CB-31 Photos resent after restart.** Provisional.

**CB-32 Search covers titles only.** Provisional.

**CB-33 MCP tool names collide at 64 characters.** Provisional.

## 4. Fix order
1. CB-14 (data loss), then CB-24 (silent half answers).
2. CB-35 (duplicate routine messages and spend) and CB-18 (stop runs on delete-all).
3. CB-16 (message goes to the wrong bot) and CB-34 (stop doesn't stop the team), together with CB-19.
4. CB-30: add `too_long` to the no-reissue codes and a client size guard. This is a one-line fix plus a guard.
5. CB-23 (vision follow-up) and CB-20 (budget accounting).
6. CB-21 (catch-up), then CB-36 and CB-37 (team floor).
7. The provisional items once round 3 runs with the harness fixed: CB-15, 17, 22, 25, 26, 29, 31, then the low items.

## 5. Files
- Run artifacts: `/workspace/work/cb2run/logs/` and `/workspace/work/cb2run/shots/`
- `ai_usage` dump: `/workspace/work/cb2run/ai_usage.json`
- Unit probe: `test/zz_chat_bughunt2_test.dart` (CB-14, 16, 19, 21, 24)
- Emulator probe: `integration_test/chat_bughunt2_test.dart`
- Live probe: `/workspace/work/chatbugs2_logs/live2.py`
