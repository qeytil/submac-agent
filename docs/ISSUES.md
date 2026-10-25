# SubMac Agent: trust and safety issues

Branch `feature/trust-fixes` (from main 59d380c, 2026-10-23). Living list: every issue found, fixed or not. Updated as the work goes.
Severity: Critical (another person's data, secrets) · High (wrong chat/account context, task stops or never stops) · Medium (duplicate or stuck UI) · Low.
Status: `fixed in <commit>` · `fixing` · `open` (not fixed here, suggested fix given) · `suspected` (seen in code, not reproduced).

| ID | Area | What the user sees | Cause | File(s) | Sev | Status |
|---|---|---|---|---|---|---|
| T-01 | Memory / accounts | After signing out and signing in with another account on the same phone, SubMac "remembers" the first person's facts, and they are saved into the new account for good | `signOut()` keeps `MemoryStore.facts` and the `memories` pref. On the next sign-in `memory.sync()` treats every local fact the server lacks as "saved offline" and inserts it into the NEW account | `lib/services/memory_store.dart`, `lib/state/chat_controller.dart` | Critical | fixed in dd30921 |
| T-02 | Accounts | The next account's prompts still carry the previous person's "About you" and "How to respond" until settings load (forever if that load fails); the team Inbox shows the previous account's messages | `signOut()` does not clear `aboutYou`, `howToRespond`, the chat cache `_lists`, open asks, or `Inbox` | `lib/state/chat_controller.dart` | High | fixed in dd30921 |
| T-03 | Accounts | Projects (with their standing notes), scheduled tasks and saved site logins stay on the phone for the next account; scheduled prompts of the first person run in the second account | These live in device prefs, not per account | `lib/services/projects.dart`, `lib/services/system_tools.dart` (Scheduler), `lib/state/settings_store.dart` | High | scheduled tasks fixed in v1.13.77+144 (owner decision 2026-10-23: tasks belong to the account; tagged with the user id, unarmed on sign-out, only the signed-in account's tasks load and run, untagged tasks move to the first signed-in account; test/scheduler_account_test.dart). Projects stay on the device by owner decision. Saved site logins: still open |
| T-04 | Chat context | A skill picked for one message rides along on a different chat's (or a bot's background) next task | `_skillNote` is one global field; it is not consumed when the message joins a running task, or when saving fails, so the next run anywhere takes it | `lib/state/chat_controller.dart`, `lib/state/agent_runner.dart`, `lib/app_state.dart` | Medium | fixed in dd30921 |
| T-05 | Chat / bot context | In a long bot chat (or any background chat) that hits "too long", the next step is built with the chat on screen: wrong bot persona or SubMac's own prompt, the on-screen chat's project, tools and pictures | `_payload` finds the chat by identity of the list; `_tail()` returns a new list, so it falls back to `currentId` | `lib/state/agent_prompt.dart`, `lib/state/agent_runner.dart` | High | fixed in dd30921 |
| T-06 | Live / bots | A task asked for in a Live call while a bot's chat is open runs inside that bot's chat, as that bot (bot chat sees SubMac's task) | `startBackgroundTask` reuses `currentId` without checking whether it is a bot chat | `lib/state/live_calls.dart` | High | fixed in dd30921 |
| T-07 | New chat | Tapping "+" while the first message of a new chat is still saving jumps back to the old chat | `send()` sets `currentId = c.id` after the await even if the user already moved on | `lib/state/chat_controller.dart` | Medium | fixed in dd30921 |
| T-08 | Agent loop | Long tasks stop at step ~49 saying "send continue" although the loop would go on; later checkpoints get no wrap-up at all | `StepBudget.note(step, 50)` fires at step 48 every time, but step 50 is only a checkpoint (the task continues when it is making progress) | `lib/services/agent_loop.dart`, `lib/state/agent_runner.dart` | High | fixed in dd30921 |
| T-09 | Agent loop | A task that keeps repeating the same failing call never stops: a new "you seem stuck" note every 3 steps until the checkpoint or the 1000-step ceiling, burning allowance | `LoopGuard` resets after each note; nothing counts how many notes were ignored | `lib/services/agent_loop.dart`, `lib/state/agent_runner.dart` | High | fixed in dd30921 |
| T-10 | Popups | The same snackbar (banner) appears two or three times in a row | `HomeScreen.build` adds a post-frame callback on every build while `banner != null`; each callback shows the captured text | `lib/screens/home_screen.dart`, `lib/state/settings_store.dart` | Medium | fixed in dd30921 |
| T-11 | Popups / navigation | After sign-out and sign-in, tapping an approvals/inbox/team notification throws or opens the screen twice | `HomeScreen` adds an `openRequest` listener and never removes it; the old state reads `context` before checking `mounted` | `lib/screens/home_screen.dart` | Medium | fixed in dd30921 |
| T-12 | Stuck indicator | After Stop (chat, floating bubble or the phone badge) the "Working on your task" notification stays until the stopped step returns (a slow page or phone step can take a minute or more) | `stopRun()` takes the run off screen but only `_afterTask` (when the loop really ends) turns keep-alive off | `lib/state/chat_controller.dart` | Medium | fixed in dd30921 |
| T-13 | Duplicates | Two scheduled runs or two Telegram messages arriving together on the same chat start two agents: two answers | `startBackgroundTask` checks "no run in this chat", then awaits saving, then starts the run | `lib/state/live_calls.dart` | Medium | fixed in dd30921 |
| T-14 | Logs / secrets | A failed Live connect writes the call's access token into the device log | `debugPrint('Live connect failed: $e')`: the socket error text contains the URL with `?access_token=` | `lib/services/live_session.dart`, `lib/main.dart` | Medium | fixed in dd30921 |
| T-15 | Popups | Closing the meeting recorder while pausing/finishing can throw "setState after dispose" | `setState` after `await` without a `mounted` check | `lib/widgets/meeting_sheet.dart` | Low | fixed in dd30921 |
| T-16 | Phone badge | After Stop, the "SubMac is using your phone" badge can come back for up to 45 s | Kotlin: a step thread that passed `ScreenGuard.stale()` posts `showBadge()` after `hideBadge()` was posted | `android_native/Ghost.kt` | Low | fixed (round 2): suggest re-checking the generation inside the posted runnable (capture `ScreenGuard.gen` before posting) |
| T-17 | Duplicates | Regenerate or edit while a quick side reply is still coming leaves an extra old reply under the new one | `regenerate()`/`editAndResend()` only check non-side runs | `lib/state/chat_controller.dart` | Low | fixed (bug hunt 2026-10-23): also blocked while any run of this chat, side replies included, is going |
| T-18 | Live / bots | A SubMac Live call started while a bot's chat is open is saved into that bot's chat (the bot then reads SubMac's call as its own history) | `saveLiveTurns` uses `currentId` when the call has no chat yet | `lib/state/live_calls.dart` | High | fixed in dd30921 |
| T-19 | Accounts / bubble | Suspected: background browser jobs and a Live call's screen owner (`live`) rely on the watchdog (45 s / 2 min) rather than an explicit end, so the floating bubble can linger up to ~2 min after a hung step | `lib/services/task_bubble.dart`, `lib/services/screen_control.dart` | Low | fixed (round 2): suggest calling `runEnded('live')` when a Live call ends |

## Bug hunt 2026-10-23: agent loop and bots (v1.13.79)
| # | Area | What went wrong | Cause | Where | Fix |
|---|---|---|---|---|---|
| L-1 | Bots / spend | A bot over its daily token budget mid-wake got the same "stop" note on every step and kept calling tools until the step ceiling | Only a note, no stop (the main agent had one) | `lib/state/agent_runner.dart` | One note, then a hard stop two steps later (`SpendStop`) |
| L-2 | Agent loop | A long task died with "The answer stopped in the middle of the task" at its third empty reply of the whole task | The blank-reply allowance (2) was never reset | `lib/state/agent_runner.dart` | Two blanks IN A ROW; any real reply resets (`BlankGuard`) |
| L-3 | Agent loop | A call with no result in a background chat was told "Still running" or "Cancelled" depending on the chat on screen | `_payload` checked `currentId` instead of the request's own chat | `lib/state/agent_prompt.dart` | Uses the request's chat |
| L-4 | Bots / cost | A check-in put off because the bot was busy came back as a full wake told to "Do this now: Heartbeat check" (skipping the cheap yes/no check), and a busy bot stacked one more follow-up per wake | The deferral saved the check-in as an instruction | `lib/state/bots_controller.dart`, `lib/services/bots.dart` | Treated as a plain check-in again; one pending follow-up per job; a retried one still retries once only |
| T-17 | Duplicates | see above | | | fixed |

`test/bughunt_loop_test.dart` covers L-1, L-2, L-4. L-3 and T-17 are fixed by reading the code.

## Tests
`test/trust_fixes_test.dart` (18 tests) reproduces T-01, T-02, T-05, T-06/T-13/T-18, T-07, T-08, T-09, T-10, T-12, T-14. T-04, T-11, T-15 are fixed by reading the code (no harness for the full send/HomeScreen path); phone checks below.

## Phone checks to run
1. Sign in as A, say "remember I live in Hargeisa", sign out, sign in as B: Settings > Memory is empty and stays empty after a minute.
2. Pick a skill, send in chat X while a task runs there; open chat Y and send: Y's answer does not follow the skill.
3. Open a bot's chat, start a SubMac Live call, ask for a task: it opens in a new "Live:" chat, the bot's chat is untouched.
4. Send the first message of a new chat and tap "+" at once: you stay on the empty new chat; the first chat is in the sidebar with its answer.
5. Stop a phone-control task from the badge with SubMac in the background: the "Working on your task" notification goes at once.
6. A long build (60+ steps) carries on past step 50 without asking "continue" when it is making progress.


## Bug hunt round 2 (2026-10-23, v1.13.80): browser tasks, teams, bot sync

Tests: `test/bughunt_round2_test.dart`.

| ID | Area | Bug | Fix |
|---|---|---|---|
| T-16 | Phone badge | Stop could land between a step's check and the badge's post on the main thread | Ghost.kt checks the step's generation again on the main thread (`ScreenGuard.mine()`) |
| T-19 | Bubble | A browser job ending during a tool step, or a Live call ending, left the bubble up until the watchdog | `BrowserJobs.onEnded` and `LiveController.end` end the screen owner at once |
| B-1 | Browser | A step waiting for the user's hand-back timed out, then fired later beside its retry | Wait for the user before the 2-minute clock; keep the page locked up to 30 s after a timeout |
| B-2 | Browser | A stopped job's queued step still acted and re-claimed its tab | `_ended` set: steps of an ended job do nothing and claim nothing |
| B-3 | Browser | `browser_task_wait/status/stop/reply` saw every chat's tasks (wrong-chat reports, cross-chat stop, wait ignored Stop) | Scoped to the calling chat; wait without an id honours Stop |
| B-4 | Browser | A second message during a steer dropped the first | Inbox messages leave only once the answer that heard them is used |
| B-5 | Browser | Stop did nothing to a paused job (needs / checkin) | Paused jobs stop and release their tab |
| B-6 | Browser | Idle close after 4 min wiped a paused job's page | Kept up to 30 min while a paused job holds a tab |
| B-7 | Browser | Closing a tab before the current one jumped to the wrong tab | Index fixed |
| B-8 | Browser | Jobs, steps and progress grew without limit | Old step results folded, 50 progress lines, 20 finished jobs kept |
| T-1 | Bots | Calls ignored quiet hours, "calls off" and the daily cap (bot_call tool, report call) | `Bots.callBlock` checked in `_botRing` and `allow` (existing limits enforced, none changed) |
| T-2 | Teams | Stop on a teammate's task restarted it up to 3 times | A stopped run waits for Tap Start and does not burn a try |
| T-3 | Teams | A wake and an office job racing for one chat wiped each other's mark (no step cap, wrong lane) | Re-check after the awaits; a run only removes its own mark |
| T-4 | Teams | Offline with no cached chat: retry every 300 ms | Retry in 2 min, 5 times |
| T-5 | Teams | An error before the run started left the task "doing" and the chat marked as office work | Undone in the catch |
| T-6 | Teams | A queued job undid Blocked / review | Job skipped unless todo/doing; Blocked takes the job out of the queue |
| T-7 | Teams | Daily session limit could go one over | Sessions started in a pass count against the limit |
| T-8 | Bots | A call that couldn't ring was lost and its text leaked into the next call | Falls back to a message or note; ring text cleared |
| SYNC-1 | Sync | Sign-out on a slow network could tombstone the account's bots | Leaving waits for the running round; push stops once leaving |
| SYNC-2 | Sync | A new phone's template Chief overwrote the account's Chief | A bot never synced on this phone takes the account's setup |
| SYNC-3 | Sync | Skills still installing were wiped from the account | Pending installs are remembered and sent along |
| SYNC-4 | Sync | jsonb key order made every round re-apply the same row (6 s loop) | Key-order-free hash and last-seen remote hash |
| SYNC-5 | Sync | A stale push resurrected a removed bot | Server refuses un-deleting a bot (migration 20261023_bot_no_undelete.sql, needs applying) |
| SYNC-6 | Sync | Child rows written before the bot row reached this phone were skipped for good | A bot the pull creates gets its memory, desk and journal fetched whole |
| SYNC-7 | Sync | Offset paging skipped rows changed between pages | Paged by time |
| SYNC-8 | Sync | Journal and follow-up times had no zone; a zone change re-sent the journal as duplicates | Written in UTC |

Not fixed yet (minor): skill removal on one phone does not reach the others; `TeamRun` ignores the team's pause and daily limit; several jobs in one chat share one screen owner.

Phone tests for round 2:
1. Start a phone task, tap Stop on the badge mid-step: the badge goes and does not come back.
2. End a Live call that used the phone: the floating bubble goes at once.
3. Let a bot with quiet hours try to call during them: no ring, a note instead.
4. Two phones signed in: change the Chief on one, sign in on a fresh install of the other: the changed Chief arrives, not the template.
5. Sign out on a slow connection, sign back in: every bot comes back.

## Owner feedback 2026-10-23 (v1.13.82+149)
- PAY-1 Checkout refused every buyer: production `SIFALO_ENV` was still `staging`, so non-testers got `billing_disabled` before Sifalo opened. Set to `live` (server secret).
- PAY-2 Pay screen offered EVC/ZAAD/SAHAL/eDahab/Premier/Card direct charges. Only Sifalo's own page now; it lists the ways to pay.
- L10N-1 Billing words went Somali when the reply language was Somali or the user said they speak Somali. They now follow the app language only.
- NAV-1 Chat screen had no visible menu button (only the wordmark opened the sidebar). Menu icon added.
- NAV-2 Bots: one foldable "Bots" section in the sidebar, Chief first, "All" opens the full bots page; the separate "Bots" page link is gone.
- NAV-3 Phone Back in a bot's chat closed the app. It now returns to the chat it was opened over (or a new chat).
- UI-1 With Android "Remove animations" on, folding a sidebar section threw (zero-length AnimatedSize). Fixed in DrawerSection, team posts and motion.
