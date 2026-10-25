# Chat bug hunt 3 (v1.13.102 base): final report, CB-1 to CB-44 (investigation only)

Base: `chat-bughunt-2` @ e47464a → branch `chat-bughunt-3`. No app code changed. Do not merge.
Status meanings: **confirmed** = reproduced on device, live or by unit test. **confirmed (code)** = the path is certain from the code, but no run reproduced the outcome. **dropped** = not reproduced, or the code no longer allows it.

## 0. Runs
| Run | Workflow | Account (uid) | Result |
|---|---|---|---|
| 1: 40182704967 | `chat-bughunt3-emu.yml` | chatbugs3-emu-1792922238 (48a3e8f2…) | I cancelled it at 10:57 UTC after the free daily allowance ran out (~10:44). Results in §2. |
| 3b: 40187261209 | `chat-bughunt3b-emu.yml` | chatbugs3-r1ui-1792926268 (334f485b…) | Green. Round-1 UI checks, §1. |
| 2: 40187261228 | `chat-bughunt3-emu.yml` | chatbugs3-emu-1792926250 (2d98fcd0…). The second account (emu2) was never created. | **Stalled at 11:29:33 UTC and cancelled by me at about 11:56 UTC**, after more than 25 minutes with no `ai_usage` row and no log line. Artifacts were uploaded (`always()`), with partial logs and 7 screenshots. Results in §3. |

**Why run 2 stalled.** In t4 the agent called `open_app("Gmail")` at 11:29:28. Logcat shows `START … com.google.android.gm/.ConversationListActivityGmail` and then SubMac MainActivity "pause timeout". The agent then called `phone_tap(about:"open compose window", text:"Compose")`. Because `about` was non-empty, `_riskFor` raised an approval sheet inside SubMac while Gmail was in front. Nobody saw it, so the run waited, and the integration test also froze with SubMac in the background (`VMServiceFlutterDriver: request_data message is taking a long time`). This is a product bug (CB-42), not only a harness problem.
Harness fix for a next run: set "Let it take action" off, or `adb shell am start -n com.submac.agent/.MainActivity` on a timer, and give each step a hard timeout.

## 1. Round-1 UI checks on device (3b run 40187261209, green)
| Bug | Result | Evidence |
|---|---|---|
| CB-1 steer typed into the final stream | **Confirmed.** The 370-char steer is never answered. | `shots/cb1_steer_unanswered.png` |
| CB-2 Stop erases the reply | **Confirmed.** 718 chars streamed, 0 kept after Stop. | `shots/cb2_stop_erases_reply.png` |
| CB-3 | Not tested. | |
| CB-5 stale choice card | **Confirmed.** A card that was already answered still sent "Not now". | `shots/cb5_stale_choices.png` |
| CB-6 | Not reproduced. | |
| CB-7 broken table card | **Confirmed.** The "Rent" row is missing. | `shots/cb7_broken_table_vanishes.png` |
| CB-8 copy | **Confirmed.** Copy gave only "Your packing list:⏎⏎Useful links:". | 3b log |
| CB-9 text direction | **Confirmed both ways.** Somali shown RTL, Arabic shown LTR. | `shots/cb9_direction_both_ways.png` |
| CB-10 | Not tested. | |

## 2. Run-1 real-task results (uid 48a3e8f2)
| Task | Outcome |
|---|---|
| t3 code + fix | OK. 15 steps: skill_use, write_file ×2, run_shell, code_run ×4, edit_file. 1,817-char final with code and test output. |
| t4 email needing approval | ask_user "Do you want to send this email now?" (Yes, send it / No, just draft / Something else). The harness never answered it, so the run sat "Waiting for you" for 30 min. The question showed in every other chat (CB-41). |
| t5 Somali, 500 words | Delivered as two .docx files (make_document ×2): a file card and no text, replyWords=6 (CB-39). |
| t6 Arabic, 400 words | Delivered as a .txt file with a 26-word reply. The reply line rendered RTL; the file-name chip rendered LTR (CB-39). |
| t7 multi-tool (2 FX rates + 2 weathers) | OK. 14 tool calls (web_search, get_weather, fetch_url), 1 table card with sources, 1,191 chars. |
| t8 steer mid-task | OK. Steer sent at step 2; side reply "Okay, switching to Kigali."; the final mentions Kigali, not Nairobi. But web_search fell back to Wikipedia, then ran 2 browser_task runs on google.com (CB-38). The window header flipped to 1,000,000 here (CB-23). |
| t9 Stop + continue | Not valid: the harness stopped the wrong run. After "continue": 24 tool calls, all Wikipedia-engine searches, no answer within 300 s (CB-38). |
| t11 530 KB paste | "You've used today's replies" (allowance gone). |
| t12 offline | After 20 s, error card "You're offline. Check your connection and try again." with a Try again button. The retry hit the allowance. |
| t10, t13–t16, bots, team | Did not run (allowance gone). |

Run-1 tokens: agent 78 calls, 846,093 prompt / 14,378 completion / 595,680 cached; side 25 calls 166,551 / 1,944 / 2,816 cached (browser_task vision on gemini-3-flash-preview, uncached); title 8 calls. Server-weighted day total (`ai_user_daily`): **197,584 tokens, 108 requests**, which is the whole free 200k day (CB-40).

## 3. Run-2 results (run 40187261228, uid 2d98fcd0)
Tokens are raw `ai_usage` sums for the uid in each task's time window: prompt / completion / cached.

| Task | Outcome | Steps | Tokens (`ai_usage`) |
|---|---|---|---|
| t1 trip | OK. 24 s, 1 table card (3 days, 5 columns), 1 choices card (Hotel / Airbnb), 1,178 chars. U+2011 hyphens rendered as a low "_" glyph: "3_Day", "airport_city", "day_trip" (**CB-43**). | 1 | agent 1 call 9,919 / 402 / 32; title 162 / 41 / 48 |
| t1 choice tap | Harness miss. The choice card was below the fold, and `tap(warnIfMissed:false)` hit nothing. 0 calls. Not a product result. | 0 | 0 |
| t2 phones | **No answer in 300 s.** 18 steps: skill_use ×2, web_search ×9 (DuckDuckGo engine this time, not Wikipedia), fetch_url ×6. It had every spec and two of the three prices by 11:24:11, then started browser_task for the S25 price. On samsung.com's S25 FE `/buy/` page it asked "Tap "Continue" on samsung.com?". That button was the cookie banner. The whole chat waited on Allow / Not now, with nothing delivered (**CB-44**). It also opened the wrong model (S25 FE). The harness stopped it at 11:28:07. One fetch of gsmarena `…s25-13620.php` returned a vivo Y22s page (wrong id, model error). | 18 | agent 18 calls 254,871 / 1,734 / 184,768; side 1 gpt-oss 2,814 / 56 / 64 + 4 gemini-3-flash-preview 21,764 / 221 / 1,977 (browser vision); title 152 / 617 / 80 |
| t3 code, t3 fix | Skipped (done in run 1). | | |
| t4 email approval | **CB-42.** Ran skill_use(wri-professional-email). That skill says "Ask first", but the agent did not ask. It called `open_app("Gmail")`, which put SubMac in the background on Gmail's inbox, then `phone_tap("Compose", about:"open compose window")`. The approval sheet came up inside the hidden app, and the run and harness froze there. No draft was shown in chat. In run 1 the same prompt produced an ask_user, so the behaviour depends on the model's choice. | 3 | agent 3 calls 27,764 / 391 / 21,072; title 134 / 51 / 80 |
| t5 Somali, t6 Arabic, t9 stop/resume, t10 photo, t12 offline, t13 compaction, t14 big photo, t15 drafts, t16 Telegram | **Did not run** (run stalled in t4). | | |
| b1–b6 bots | **Did not run.** | | |
| c1–c2 team (and c3, c4, d1) | **Did not run.** | | |

Run-2 tokens: 30 requests, raw 317,580 prompt / 3,513 completion / 208,121 cached. Server-weighted (`ai_user_daily`): **57,177**. The 3b UI account used 5 requests, 5,587 weighted.

Round-3 total, server-weighted: 197,584 + 57,177 + 5,587 = **260,348** across 143 requests (plus 2 live-probe calls on chatbugs3-live).

## 4. Settling the open items
| Bug | Verdict | Evidence |
|---|---|---|
| CB-17 owner message deleted by a silent bot wake | **Confirmed (code).** b5 did not run. | A message typed during a wake goes through `send()`, which appends it to the bot chat's list after the `botWakeMark` user row (steer path, `chat_controller.dart:306–333`). When the wake ends silent, `bots_controller.dart:396–405` does `list.removeRange(start, list.length)` plus `repo.deleteMessages(gone)`. That deletes the owner's message and the side reply too. It also fires when the bot wrote real text with a stray silence tag (`BotOutcome.parse`: kind "silent" keeps the text, but this branch tests only `kind=='silent'`). Fix: remove only rows the wake itself wrote (track their ids), or skip the drop when a non-wake user row exists after `start`. |
| CB-18 delete-all leaves ghost chats | **Confirmed (code).** d1 did not run. | `deleteAllConversations()` (`chat_controller.dart:141`) never stops `runs`, unlike `deleteConversation()` (l.131) and `deleteAccount()`. After `store.wipe()`, the live run's next `repo.insertMessage()` (`repo.dart:247–256`) recreates an index entry `{_unknown:true, _remote:true}` and marks it dirty, so the chat comes back as a ghost and is queued to sync. Fix: stop and await all runs, then wipe. |
| CB-22 Try again repeats sends | **Confirmed (code).** | `regenerate()` (`chat_controller.dart:467`) guards on `busy \|\| anyRunHere`, but no run exists until `_runAgent` adds one. In between it awaits `repo.deleteMessages()`. A second tap in that window passes the guard (nothing left to remove) and starts a second `_runAgent` on the same chat, and `_runAgent` has no per-chat guard (`agent_runner.dart:6–28`). Result: two replies and double spend. Fix: claim via `_sendGate` or set a regenerating flag synchronously before the first await. |
| CB-29 drafts and attachments leak between chats | **Confirmed (code), both halves.** t15/c4 did not run. | Main chat: `home_screen.dart:248` builds `Composer()` with `perChatDrafts:false`, so one controller follows every chat and its text carries over. Attachments: `_ComposerState._attachments` (`composer.dart:52`) is never swapped by `_swapDraft`, even in the Bots workspace (`perChatDrafts:true`), so a photo picked in chat A is sent to chat B. |
| CB-34 team stop doesn't stop member jobs | **Confirmed** (round-2 emulator c1/c2; code unchanged). | `team_run.dart:107` `busy(o) => running.contains(o.id)` still ignores queued and running `OfficeJob`s. With `busy` false, "stop" goes to `_decide`, not `stopWork`. |
| CB-35 redelivered alarm runs the routine again | **Confirmed** (round-2 emulator b4; code unchanged). | `_botWake` → `_wakeLater` (`bots_controller.dart:226/285/307`). `hasPendingFollowup` dedupes follow-ups only, not the running routine. |
| CB-36 team intro promises a plan, gets a single reply | **Confirmed** (round-2 emulator c1; code unchanged). | Intro copy at `offices.dart:908` "…will suggest a plan and wait for your go-ahead". `_decide` takes the plan path only if the floor model returns `team_task:true`. |
| CB-37 team follow-up silently dropped | **Confirmed (code).** c3 did not run. | `_decide` (`team_run.dart:284–313`) posts "Nobody picked this up" only when the floor call throws. A valid JSON answer with no or unknown `speaker` and `team_task:false` posts nothing. A `reply` job that ends with empty text (`bots_controller.dart:917–919`) posts nothing too. The owner gets neither an answer nor a notice, matching round-2 c2. |

## 5. New bugs this round
- **CB-38 (High).** With no search key, web_search silently falls back to Wikipedia (`lib/services/web_tools.dart:118`). This leads to search loops and costly browser tasks (run 1 t8, t9). In run 2, DuckDuckGo answered, so the fallback is intermittent.
- **CB-39 (Medium).** Long answers come back as files with no text (run 1 t5 .docx ×2, t6 .txt), even when the prompt says "not in a file".
- **CB-40 (Medium, cost).** About 9 tasks use up the free 200k daily allowance (197,584 weighted in run 1), a quarter of it uncached browser vision. The allowance sheet then covers the composer (`shots/cb40_quota_sheet_blocks_composer_t10.png`).
- **CB-41 (Medium).** Chat A's pending ask_user shows in every chat, with a one-tap "Yes, send it" (`shots/cb41_email_ask_in_other_chat_t7.png`).
- **CB-42 (High, new).** Asked to "draft and send" an email with no mail account connected, the agent drives the Gmail app instead of showing a draft. It calls `open_app("Gmail")`, which backgrounds SubMac, then `phone_tap("Compose", about:…)`. The approval sheet for that tap is raised inside SubMac, behind Gmail, so the user never sees it and the run hangs "waiting". No draft appears in the chat, against the email skill's "Ask first" and `email_send`'s "show the draft and get a yes first". Evidence: run-2 messages for conversation 31ed5349… (skill_use → open_app → phone_tap) and logcat 11:29:28 (Gmail START, SubMac pause timeout).
  - Fix: route outbound email without a connector to a `mailto:` compose intent with the body, after showing the draft in chat.
  - Fix: while an approval is pending and SubMac is in the background, post a notification.
  - Fix: block screen actions in another app until the outbound draft has been approved.
- **CB-43 (Low, new).** Non-breaking hyphen U+2011, which gpt-oss emits often, renders as a low underscore-like glyph: "3_Day", "airport_city", "day_trip" (`shots/cb43_nb_hyphen_renders_as_underscore_t1.png`). Cause: the Geist TTFs in `assets/fonts` have no glyph for U+2010, U+2011 or U+202F (checked with fontTools), so Flutter falls back. Titles also carry U+202F ("iPhone 16 vs Galaxy S25…"). Fix: normalise U+2010/2011 → "-" and U+202F → " " in the markdown renderer and titles, or add the glyphs.
- **CB-44 (Medium, new).** A read-only research task stalls on an approval for a cookie banner, and the chat gets nothing. On samsung.com's `/buy/` page `PageRisk.isMoneyPage` is true, so `pressNeedsOk("Continue")` matches `_submitLabel` (`page_model.dart:270–276`). The browser asked "Tap "Continue" on samsung.com?" for the cookie-consent button. The run had all specs and two of the three prices but delivered no table for 4+ minutes (`shots/cb44_cookie_continue_gated_research_stalls_t2.png`).
  - Fix: treat consent and cookie overlays as safe.
  - Fix: for goals that only read (price lookup), don't ask; answer from what was found.
  - Fix: when an approval waits longer than N seconds, finish with a partial answer.

## 6. Final bug list (round 3 view)
| Bug | Sev | Status |
|---|---|---|
| CB-1 steer into final stream unanswered | High | confirmed (device) |
| CB-2 Stop erases the reply | High | confirmed (device) |
| CB-3 | – | not tested |
| CB-5 stale choice card still sends | Medium | confirmed (device) |
| CB-6 | – | dropped (not reproduced) |
| CB-7 broken table drops rows | Medium | confirmed (device) |
| CB-8 copy loses card content | Medium | confirmed (device) |
| CB-9 wrong text direction (Somali RTL, Arabic LTR) | Medium | confirmed (device) |
| CB-10 | – | not tested |
| CB-15 router stuck / 400s as route failures | Medium | confirmed (live DB) |
| CB-17 owner message deleted by silent wake | High | confirmed (code) |
| CB-18 delete-all leaves ghost chats | Medium | confirmed (code) |
| CB-22 Try again double send | Medium | confirmed (code) |
| CB-23 photo follow-up to no-vision route + 1M window | Medium | confirmed (routing live in round 2; window on device t8) |
| CB-25 Telegram issues | Medium | partly confirmed (t16 did not run) |
| CB-26 no attachment size limit | Medium | confirmed (code) |
| CB-29 drafts and attachments leak | Medium | confirmed (code, text and attachments) |
| CB-31 photos resent after restart | Low | confirmed (code) |
| CB-34 team stop doesn't stop members | High | confirmed |
| CB-35 redelivered alarm reruns the routine | High | confirmed |
| CB-36 plan promised, single reply given | Medium | confirmed |
| CB-37 team follow-up silently dropped | Medium | confirmed (code) |
| CB-38 web_search silent Wikipedia fallback | High | confirmed (device run 1) |
| CB-39 long answers delivered only as files | Medium | confirmed (device run 1) |
| CB-40 9 tasks use up the daily allowance; sheet blocks composer | Medium | confirmed (device + DB) |
| CB-41 pending ask shown in every chat | Medium | confirmed (device) |
| CB-42 email "send" drives Gmail and hides the approval | High | confirmed (device run 2 + DB) |
| CB-43 U+2011/U+202F glyphs missing in Geist | Low | confirmed (device + font check) |
| CB-44 cookie "Continue" gated, research stalls | Medium | confirmed (device run 2) |

Items from round 2 not re-examined this round keep their round-2 status: CB-14, 16, 19, 20, 21, 24 confirmed; CB-27, 28, 30, 32, 33 as before.

## 7. Fix order
1. CB-17 (deletes the user's words) and CB-14/CB-24 from round 2 (data loss, silent half answers).
2. CB-42 and CB-41 (outbound email safety: hidden approval, one-tap send in the wrong chat), then CB-44 (approvals that stall reads).
3. CB-38 and CB-40 (search fallback loops into browser vision and uses up the free day), then CB-39.
4. CB-1, CB-2, CB-5 (steer, Stop, stale cards on device).
5. CB-35, CB-34, CB-37, CB-36 (bots and team), with CB-18 and CB-22 (run guards: stop on delete-all, claim on regenerate).
6. CB-29, CB-7, CB-8, CB-9 (composer and rendering), then CB-23, CB-15.
7. Low items: CB-43 (one-line normaliser), CB-31, CB-26.
8. Harness: keep SubMac in front (or actions off), add per-step hard timeouts, scroll choice cards into view before tapping, then re-run t5–t16, b1–b6 and c1–c4 on a fresh account.

## 8. Files
- Run-2 artifacts: `/workspace/work/chatbugs3/run2/` (`chatbug3-logs/drive.txt`, `logcat_debug.txt`, `chatbug3-shots/`), `ai_usage` dump `run2/usage_both.json`.
- Run-1 artifacts: `/workspace/work/chatbugs3/run1/`; 3b: `/workspace/work/chatbugs3/run3b/`.
- Screenshots: `/workspace/work/chatbugs3/shots/`.
- Repo doc: `docs/chat-bughunt3-102.md` on branch `chat-bughunt-3`.
