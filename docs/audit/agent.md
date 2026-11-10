# Telesia: audit of the agent workflows

Read-only review of the app as it stands in the working copy (version 1.13.62+95), dated 23 October 2026. Nothing was changed. Where a finding comes from reading the code and not from running it, it says so.

---

## 1. Overall state

The agent is far more complete than most apps of its kind. Every tool the model is offered has real code behind it: no declared tool is missing a handler. The main loop is carefully built. It runs independent lookups at the same time, notices when it is going round in circles, retries network blips, moves a struggling task up to a stronger model, folds long chats into a summary, and checks that a reply saying "sent" or "saved" is backed by a real result. Approvals work as a single card with Approve, Edit and Not now. A separate browser agent has its own plan, notes and check-ins.

The weak spots are at the edges, where the phone, the cloud and the user meet:

- **Anything running in the background.** Bots in the cloud, scheduled tasks after a phone restart, tasks the app was killed in the middle of, and questions asked while nobody is looking can all stop without the user being told.
- **Approval coverage.** It depends on English button words and on the model choosing to flag a risky tap.
- **The toolbox has grown to roughly 170 built-in tools,** with several doing the same job, and the instructions push towards chatty replies.
- **Very little has been checked on a real phone.** Almost every agent feature added since mid-October is marked "not tested on a real phone" in the project's own notes. The released version is still 1.13.15, while the working copy is 1.13.62.

**In short:** the brain is strong. The background, recovery and approval layers need hardening before users can trust it to work while they are not watching.

---

## 2. Top 10 issues, ranked by user impact

### 1. Cloud bots take on jobs they cannot do, and those jobs are never finished
- **What the user sees:** They hire a bot with a routine like "every morning check the dollar rate and message me", or "check my email and summarise it". With cloud running switched on (it is on), nothing useful arrives, or the bot's journal says "Waiting for the phone". The phone never picks that up, so the job is never done.
- **Why:** The app decides a job can run in the cloud unless its wording mentions the phone (calls, texts, WhatsApp, camera…). That word list is English only. Web searches, email and connected apps are not on it, so those jobs go to the cloud. The cloud runner has no web, email, apps or browser; it can only update the bot's notes and task list. Its "hand to phone" step only writes a note, and nothing on the phone acts on that note.
- **Fix:** Send a job to the cloud only when it needs nothing but memory and notes. Otherwise keep it on the phone, and treat web, email, apps and Somali wording as needing the phone. Make the phone pick up "waiting for the phone" notes and run them the next time it wakes. Longer term, give the cloud runner web search and page reading.

### 2. Tasks cut off by Android or a restart vanish without a word
- **What the user sees:** They start a long job, switch apps, and Android closes Telesia (common on low-memory phones). When they come back, the chat stops half-way: no answer, no "this was interrupted", no way to pick up. In-app browser jobs, tasks started from a Live call and the step-by-step checklist are all gone. Bot approval requests left open are marked expired, and the bot's action is silently dropped.
- **Why:** Running tasks, browser jobs and Live tasks are kept only in memory. The checklist is saved only when a task ends normally, so a killed task never saves it. Unanswered bot approvals are expired on start-up.
- **Fix:** Write a small "task in progress" record (the request, the checklist, the step reached) as the task goes. On start-up, show "This task was interrupted. Continue?" in the chat. Keep unanswered approvals open after a restart and let the bot redo the action once they are approved.

### 3. Questions and approvals asked in the background can wait forever
- **What the user sees:**
  - A scheduled task, a Telegram request or a background job hits a question or needs an app connected. Nothing happens. The "working" notification stays up and the result never comes.
  - A scheduled 7 a.m. task that needs approval can pull Telesia on top of whatever the user is doing and show a sheet that cannot be dismissed.
  - On Telegram the user gets "Still working on it" after 20 minutes and never hears more.
- **Why:** Questions to the user ("ask user", "connect app", sign-in) have no time limit and send no notification when the app is not open. The approval sheet in the owner's own chats also has no time limit.
- **Fix:** For any question or approval raised while the app is in the background, send a notification the user can answer from. Give each one a time limit (for example 30 minutes for questions). When it runs out, the task should end politely ("Skipped because you weren't around: …") instead of hanging. Scheduled runs should never bring the app to the front; they should ask by notification, like bots do.

### 4. Approval cards can be skipped, or work after the user pressed Stop
- **What the user sees:**
  - A Somali or Arabic site or app has a button such as "Dir", "Bixi", "إرسال" or "ادفع". Telesia taps it with no approval card, because only English words like "send", "pay" and "post" are recognised.
  - The model can tap by screen position, press Enter on a form or run page scripts with no card unless it chooses to describe the action itself.
  - Some connected-app actions with "list" or "get" in their name are treated as read-only even when they change things (for example "delete list item").
  - Writes made through plain web addresses, such as a Telegram bot "send message" link or a command-line post without an explicit method, are treated as reads.
  - If the user stops a bot's task and later taps Approve on its old card, the action still goes through.
- **Fix:**
  - Add Somali and Arabic words to the list of risky buttons.
  - Ask for approval on any position-tap, Enter key or script that runs on a page where a form is filled in, whether or not the model flags it.
  - Treat connected-app actions as read-only only when the name starts with a read verb.
  - Treat known write addresses as changes even when they use plain web requests.
  - When a task is stopped, cancel its open approval cards.

### 5. Scheduled tasks stop after a phone restart; overdue one-off tasks disappear
- **What the user sees:** They set "remind me every morning at 7" and later restart the phone. Unless they also have an active bot or team, nothing fires until they open Telesia again. A one-off reminder that was missed by more than 30 minutes (phone off, battery saver) is deleted without any note.
- **Why:** After a restart, the phone only wakes Telesia to set its alarms again if bots or teams are active; plain scheduled tasks are not checked. Overdue one-off tasks are removed on start-up.
- **Fix:** Also wake Telesia after a restart when the user has any scheduled task. For a missed one-off task, either run it late with a "(late)" label or send "Missed: … (your phone was off)".

### 6. Too many tools that overlap, which confuses the model
- **What the user sees:** Results are inconsistent. A sale is recorded in the personal money notebook one day and the business books the next. A document might be made with any of three different tools. A reminder becomes a phone alarm, a calendar entry, a scheduled task or a bot routine depending on the wording. A page is fetched, opened in the browser, or opened on the phone. Answers are slower, and the daily allowance runs out sooner.
- **Why:**
  - There are about 170 built-in tools plus whatever connected apps add, with clear doubles:
    - money notebook vs. business books
    - three ways to make a document, plus plain file writing
    - three ways to read a document
    - five ways to "do it later"
    - three kinds of memory (Telesia's, a bot's, and knowledge)
    - two kinds of picture making
    - three ways to reach a website
  - The words that switch tool groups on are very broad ("open", "app", "account", "page", "plan", "report", "order", "job", "code"…), and once switched on they stay on for the rest of the chat. Long chats end up carrying almost everything.
  - The first step of short messages runs on the small fast model, which handles big tool lists least well.
- **Fix:**
  - Merge the doubles: one way to record money (business mode when the user has a business set up), one document maker, one document reader, one "later" tool with a type (reminder, repeat, watch).
  - Narrow the trigger words.
  - Let tool groups close again after a few turns without use.
  - Keep the fast model to tool-free replies.

### 7. Bloated instructions that produce wordy, filler-heavy replies
- **What the user sees:** Extra bubbles on almost every task:
  - an opening line ("Checking Friday flights…")
  - milestone updates
  - an automatic progress line after every six quiet steps
  - a closing offer ("Want me to…?")
  - suggestion chips on top

  Short Somali questions get padded answers, and the first word takes longer to appear.
- **Why:**
  - The main instructions are about 4,000 tokens before tools. On top of that come the safety block, a tour of Telesia's menus sent with every request, the full card catalogue when a message looks visual, and a growing set of notes added to every step: the request repeated word for word, the list of must-haves, the checklist, the final self-check, skill hints and frustration hints.
  - Several rules pull against each other. "Ask at most one question" sits next to "ask up to 3 questions before a build". "Start every task with a line" sits next to "say one line before you start the browser".
  - The full tool descriptions are an estimated 10–15k tokens on top of all this.
- **Fix:**
  - Cut the main instructions roughly in half.
  - Send the Telesia menu tour only when the user asks how the app works.
  - Drop the forced six-step check-in (the live task line already shows progress).
  - Make the opening line and the closing offer optional ("only if the task will take more than a few seconds"; "only when there is an obvious next step").
  - Settle on one rule for questions.
  - Shorten tool descriptions to one line each, with details on demand.

### 8. Cloud bots will run late or be missed as users grow
- **What the user sees:** Bot routines arrive hours late, or the bot's journal says "Couldn't do a routine in the cloud (the model was busy)". The promise "keeps working when your phone is off" is broader than what the cloud can do: no web, apps, calls or browsing.
- **Why:**
  - The cloud runner handles at most 10 bots every 5 minutes for the whole user base, about 120 an hour. A routine more than 3 hours late is skipped.
  - Each job gets 6 model steps.
  - It gives up on the model after 55 seconds, while the model service may take up to 75 seconds trying backup routes. Slow moments therefore count as failures: one retry, then "missed".
  - Cloud bots also lack the identity and safety block that the phone version carries.
- **Fix:**
  - Process bots in larger batches, or call the runner more often.
  - Raise the model wait to match the server's backup window.
  - Add the same identity and safety block.
  - Reword the promise to "keeps notes and reminders going while your phone is off".

### 9. Team (office) work pauses quietly and teammates get tied up
- **What the user sees:** On a busy day a team stops picking up work and does not resume until something else happens in the app. When a teammate asks for approval, it stays busy for up to 3 hours waiting. Other work queued for it sits behind.
- **Why:** When the daily allowance is low, the team scheduler stops without setting a time to try again. Bot approvals wait up to 3 hours inside the running task.
- **Fix:** When pausing for the allowance, schedule a retry for when it resets and post "Paused until tomorrow" in the team chat. Let a teammate park a task that is waiting for approval and move on, then resume it when the user answers.

### 10. Features that are promised but missing or off
- **What the user sees:**
  - "Make a video" always fails (the video tool is a placeholder that returns "not available yet").
  - Image making depends on a server switch that is off. If the app thinks an image route exists while the server has images off, the user asks for a picture and only then hears it is unavailable.
  - Facebook and Instagram are a written plan only.
  - The roadmap promises a Linux toolbox (Python, ffmpeg) and per-chat approval modes, which are not in the agent.
  - Server-side tasks the docs list as still to do: removing provider names from server error messages, and giving cloud bots the same safety rules and "user's words last" order.
- **Fix:** Hide the video tool and the image tool unless the server says they are on. Update the in-app guide and the docs so nothing is offered that cannot be delivered. Finish the server-side safety items before the next release.

---

## 3. Unfinished vs. working well

### Unfinished or fragile
- **Phone testing:** most agent, loop, chat, bubble, Live and bot features are not yet checked on a real phone. The published release is far behind the working copy.
- **Cloud bots:** no web or apps, the hand-back to the phone is not built, a small batch size, a short model wait, and no safety block.
- **Recovering after an app kill or restart:** none for tasks, browser jobs, Live tasks, questions or bot approvals.
- **Background questions and approvals:** no notification or time limit for questions; scheduled runs can pop the app to the front.
- **Scheduled tasks:** not re-armed after a restart unless bots or teams exist; missed one-off tasks are deleted silently.
- **Approval detection:** English-only risky words; some taps, keys and scripts are flagged only if the model chooses to; a loose read-only test for connected apps; approvals still act after Stop.
- **Tool sprawl and broad, sticky group triggers.**
- **Prompt size and reply padding.**
- **Video tool (placeholder), image tool (server switch off), Facebook/Instagram (plan only).**
- **Smaller gaps:** a few network calls can wait on a slow reply body with no time limit (connector calls). Office scheduling stops on low-allowance days without setting a retry. Step times on finished tasks are lost after a restart (already noted in the docs).
- **Over-eager approvals for some connected apps:** the general "run any app action" helper of the app connector service asks for approval even for reads such as checking email, which leads to approval fatigue.

### Working well
- **Coverage:** every tool offered to the model has working code; nothing is declared and left empty.
- **The main loop:**
  - parallel read-only lookups (up to 6)
  - a loop/stuck guard with specific advice
  - one quiet retry for network errors
  - moving up to a stronger model only in Auto
  - wrap-up before step and size limits
  - continuing after a cut-off or dropped stream
  - folding long chats into a summary
  - the "not proven yet" check before claiming something was done
  - the final self-check against the user's own requirements, including Somali constraint words
- **Steering mid-task:** a new message amends the task instead of replacing it, and Stop is wired to everything that runs (browser, phone badge, bubble).
- **Browser agent:** its own plan, notes, folding old steps, check-ins, up to 3 jobs at once, a clean report when it stops, and a hard step cap per segment.
- **Approvals, where they apply:** one card with Edit, grouped similar asks, trust levels, notification answers for bots, WhatsApp always asking, and edited text passed through accurately.
- **Long tasks:** checkpoints, a 1,000-step ceiling, a token budget with a polite pause and "send continue".
- **Timeouts:** most network tools have them (stream idle at 75 seconds, app connectors at 40 seconds, external tool servers at 90 seconds, email at 20 seconds).
- **Errors:** cleaned of provider and model names before the user sees them; friendly wording throughout.
- **Tests:** about 40 test files cover the loop logic, prompt safety (English and Somali), tool scoping, Live audio and screen control.

---

## Appendix: files relied on
- Main loop, approvals, prompts, background tasks, schedule handling: `lib/app_state.dart`
- Loop helpers: `lib/services/agent_loop.dart`, `tool_scope.dart`, `quick_lane.dart`, `truth.dart`, `constraints.dart`, `house_rules.dart`
- Tools and risk rules: `lib/services/tools.dart`, `system_tools.dart`, `connector_catalog.dart`, `connector_tools.dart`, `mcp_client.dart`, `life_tools.dart`, `biz_tools.dart`, `health_tools.dart`, `code_tools.dart`, `doc_maker.dart`, `somali_knowledge.dart`
- Browser: `lib/services/browser_agent.dart`, `browser_jobs.dart`
- Bots, teams, cloud: `lib/services/bots.dart`, `bot_sync.dart`, `offices.dart`, `supabase/functions/bot-run/index.ts`
- Live: `lib/services/live_tasks.dart`
- Android side: `android_native/BootReceiver.kt`, `TaskService.kt`, `TelesiaApp.kt`, `tools/patch_android.py`
- Screens: `lib/screens/home_screen.dart`
- Docs: `docs/agent-loop.md`, `docs/project-state.md`, `ROADMAP.md`
