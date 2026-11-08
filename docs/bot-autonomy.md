# Bot and team autonomy (1.13.140+210, branch feat/bot-autonomy, 2026-11-07)

Owner's request: bots and teams must be able to run automations, long-horizon work or a business without the owner
present. Autonomy is opt-in (the owner switches it on per bot or team, or tells them in chat); once given a goal they
decide and act on their own, and reach the owner only for approvals, money or irreversible steps.

## 1. Mission mode

`lib/services/missions.dart` (core, pure Dart), `lib/state/missions_controller.dart` (app wiring),
`lib/widgets/mission_section.dart` (owner UI).

- **One mission per bot and one per team.** A mission has a goal, a plan (steps: todo/doing/done/blocked, optional
  teammate), an activity log, a summary, a budget and counters.
- **On disk, resumable.** `<workspace>/missions/<id>/mission.json` (written atomically: tmp + rename) and a readable
  `MISSION.md` the bot can open with its own file tools (and the owner sees in Files). Loaded at start-up before the
  alarm gate opens, so an alarm that started SubMac finds it.
- **Wakes itself.** Its own exact alarm `mission|<id>` through the same path bot routines and scheduled tasks use
  (AlarmManager → AlarmReceiver → TaskService foreground + wake lock → headless engine → AlarmGate →
  `_onAlarm`). Before each run a fallback wake is set (+2 h), so a run killed with the app, or one that ends without
  `mission_schedule_next`, still continues. After a restart BootReceiver re-arms when `missions_on_v1` is set
  (Kotlin: one condition) and `Missions.armAll` re-sets every alarm; a time missed while the phone was off wakes in a
  minute.
- **Bot runs**: `_botWake(kind: 'mission')` in the bot's own chat, background lane (bots' share or the bot's own BYOK
  model), unattended (no cards, no questions). The instruction is the goal, plan, recent log and the rules; the reply
  is a 1-2 line progress summary kept as a quiet note.
- **Team runs**: an office job `kind: 'mission'` for the lead (step cap 40, 80 when browsing). The lead hands parts
  out with team-turns assignments ("Nova: …" lines, or `mission_plan` with `who` + `assign: true`, which posts that
  line); the assignee starts by itself and reports back, and the lead is woken by the report (team-turns watches). The
  lead's prompt carries the plan and log; members see the goal.
- **Tools** (bot tools, offered through the bot's brief / find_tools, never in the owner's own chat; never switched off
  with a power): `mission_plan` (steps, step update, `goal` to start), `mission_update` (progress, step, `needs_you`),
  `mission_schedule_next` (in_minutes or when; clamped 5 min .. 7 days), `mission_done` (summary, success).
  In a team only the lead may schedule or close the mission.
- **Escalation**: `needs_you` sets the mission to "waiting", sends one high-priority notification
  ("[needs you] …") and shows Approve / Decline on the bot's Job page (team: Tasks tab). The mission keeps working on
  other steps; the answer is logged and wakes it within a minute. Tool approvals inside a run follow the usual trust
  rules (unattended: refused at once + "Needs your OK" notification, bots-background).

### Guardrails
- Runs per day (default 12, 1..96) and tokens per day (default 400k). Checked before every run; tokens of the
  bot's background turns (team: any member's turn in that team) during a mission run count toward it, and the turn's
  `OcBgGuard` stops at the smaller of the bot's own budget and the mission's remaining tokens. Out of budget: one
  "Paused until tomorrow" line + notification, next wake 08:00.
- A wake while the last run still goes on starts nothing (looks again in 15 min). A run cut by no connection, busy
  models or the allowance does not count and retries (5-10 min, or tomorrow).
- Stop switch: ends the mission for good (log kept), cancels its alarm, stops the bot's running mission wake (team:
  drops the queued lead job; a running one finds the mission stopped at its next mission tool call).
- On/off switch: off cancels the alarm and no wake runs; on again wakes within a minute.
- Only the owner starts a mission: from the UI, or the owner's own words in chat (`mission_plan` with `goal` is
  accepted only in the bot's chat outside a wake, or in a team job answering the owner). A background run cannot give
  itself one.
- Progress notifications are summaries, at most one per 30 minutes per mission; quiet hours respected (needs-you
  excepted).

### How the owner turns it on
- Bot: its Job page → **Mission** → *Set a goal* (goal, runs a day, tokens a day) → Start. Then the switch turns
  autonomy on/off; *Activity log*, *Budget*, *Stop*; Approve / Decline when it needs you.
- Team: the team's Tasks tab → **Mission**, same controls; the lead runs it.
- In chat: "Nova, take this on by yourself: get 20 supplier quotes this week" → the bot starts the mission with
  `mission_plan` (goal + steps); the first own wake comes 5 minutes later.

## 2. Long-horizon runs with the app closed
Built on bots-background (1.13.125): headless `OcChannel`, TaskService wake lock, AlarmGate, unattended permissions.
Mission state is never kept only in memory: every change is saved before the next await that could be cut, and the
next wake is armed before a run starts, so any number of background runs can follow each other with SubMac never
opened.

## 3. Browser use with the app closed
**Why it failed.** The browser agent (`browser_task` → `BrowserJobs` subagent on `agent/core.dart` →
`BrowserAgent`) drives `InAppWebView` widgets that live in the app's widget tree (`lib/widgets/browser_layer.dart`).
With SubMac closed the engine runs headless: no frame is ever drawn, so the platform view is never created,
`BrowserTab.ready` never completes and every browser step failed after 20 s ("the browser view is not ready"). The
web tools (`web_search`, `web_research`, `fetch_url`, opencode's `webfetch`) are plain HTTP and already worked.

**Now.**
1. *Off-screen tabs*: when nothing can draw the browser (`BrowserAgent.noScreen` = started headless or SubMac not
   visible), a new tab is a `HeadlessInAppWebView` (flutter_inappwebview's own off-screen WebView, created with the
   application context, 412×915) with the same callbacks and page script as the widget tab. Pop-ups of an off-screen
   page are off-screen too; the browser layer never builds a second view for such a tab; closing frees it. No Kotlin
   was needed (the plugin already provides it).
2. *Read-only fallback* (`lib/services/fetch_browser.dart`): if the off-screen view cannot start, the task switches to
   read-only mode at that step (and later tasks this session start in it): plain HTTP GET, the page's readable text
   (`Readable`), numbered links. `browser_open`, `browser_click` (link number), `browser_find`, `browser_scroll` /
   `browser_read`, `browser_back` work; typing, sign-in, forms, scripts and payments answer that they need SubMac
   open, and the task finishes saying so.
3. *The bot's own model*: a bot's browser task thinks on the bot's model (`BotBrowserModel`, bot_llm.dart): an
   OpenAI-compatible BYOK key → that provider straight from the phone (tool calls + screenshots in the OpenAI shape;
   no screenshots for a model marked text-only; tokens count to the bot); a SubMac model → that model; Anthropic /
   Gemini keys or a model without tool calling → SubMac's model (their tool protocols are not converted yet).

**Limits.** Off-screen pages cannot be watched live on the card while SubMac is closed; a site's real-touch fallback
(`webTouch`) finds no view and uses page script; whether `takeScreenshot` returns a picture for an off-screen view
varies by WebView version (the agent still has the numbered elements and text). Read-only mode cannot sign in or
submit. Sites that block plain reads stay blocked.

## 4. A bot's own engine (`lib/bot_agent/`)
A bot is a "digital person" that works on its own, on the phone, under its own profile, so it no longer shares opencode
with the SubMac agent (owner 2026-11-07). opencode is reserved for the owner's chat.

- **`lib/bot_agent/bot_agent_config.dart`** — `BotAgentConfig` (the bot's id, name, notes folder and loop limits:
  `maxSteps` 24, `maxContinues` 4, `maxToolChars` 16000) and `BotAgents`, one stable config per bot.
- **`lib/bot_agent/bot_agent_engine.dart`** — `BotAgentEngine`: the turn loop model step → the tools it asked for →
  model step …, until the bot answers without a tool, its allowance stops it, the turn is cancelled or the step cap is
  reached. A reply cut for length is continued where it stopped, so a bot never sends half a sentence. It is pure: the
  app passes the model step (`step`) and the tool runner (`runTool`) in, which is what `test/bot_agent_engine_test.dart`
  tests. It has no MCP gateway, no opencode session, no server of its own.
- **Route** (`lib/state/agent_runner.dart`, `_runBotTurn`): a turn whose conversation belongs to a bot
  (`Bots.I.byConv(convId) != null`) takes this path and returns before opencode is ever touched. The model step goes to
  the bot's own BYOK provider when it can take tools (`BotBrowserModel.of(...).byok`, OpenAI-shaped tool calls straight
  from the phone); otherwise to SubMac's lane (the same resilient stream as the owner's chat). Every tool is called
  directly by name through the app's router (no `submac_run_tool` lookup, no MCP gateway, no opencode session).
- **Teams** (`_teamTurn`): a team's lead and members run the same loop under their `TeamKey`
  (`team:<team>:<bot>`) — `team_assign`, `team_task`, the office tools and the bot's own tools are called by name, and
  only the answer is posted to the team chat. Their turns write no chat rows, so nothing leaks into the member's 1:1
  chat. `Runner.ocTurn = teamTurn` means every office job and team plan uses this engine; opencode is never started for
  a team.
- **Allowance:** the bot's profile allowance (`tokenBudgetK`/`overBudget`, plus a live mission's) stops background work
  between steps, and only when the bot is **not** on its own key. A BYOK bot is not billed by SubMac, so its allowance
  never cuts its own-model work (owner 2026-11-07). `b.addTokens` counts the lane's tokens as they go.

**Limits.** An Anthropic or Gemini BYOK key (a tool protocol that is not converted yet) still falls back to SubMac's
lane. The team's `_teamPermission` helper remains in `agent_runner.dart` for the owner-chat opencode path only; no
opencode session ever runs under a `TeamKey`.

## 5. Always on (owner 2026-11-08)

A digital person should feel present, not only wake on an alarm. "Always on" is the phone-side version of that: on by
default, it keeps SubMac's foreground service up all day and pulses it, so a bot is never waiting for the app to be
opened.

- **`lib/services/always_on.dart`** — `AlwaysOn.I`: the saved choice (`always_on`, default **on**) and the steady
  service line (`Your digital people are active`).
- **The steady service** (`SystemBridge.keepAlive`): while "Always on" is on, the many `keepAlive(false)` calls that
  normally end a run are turned back into the steady line, so the service does not blink off between tasks. A run's own
  hold, and the owner's message, still show their own line.
- **The pulse** (`AppState.startAlwaysOnPulse`, every 5 minutes): re-asserts the service, and wakes a heartbeat whose
  exact alarm the OS killed and never redelivered (overdue by more than 5 minutes, never in quiet hours, never for a bot
  with no heartbeat). It is **local**: no model call happens unless a bot is genuinely due.
- **The trade-off**, spelled out in Settings > Advanced: it uses more battery (the service holds a wake lock while it
  runs). Turning it off is the old behaviour — the service runs only while a task actually does.
- **No Kotlin change.** A continuous "thinking" loop would be frozen or killed by Android's Doze and OEM battery
  killers, and would drain the battery in hours. The heartbeat stays the pulse, and events (routines, follow-ups,
  missions, watches, messages) stay the reason to wake; the pulse only keeps the phone ready.

## Tests
- `test/bot_agent_engine_test.dart`: the loop on its own — a plain answer, a tool round-trip, a reply cut for length
  continued and joined, the allowance stopping between steps, the step cap, per-step tokens, and cancellation.
- `test/missions_test.dart`: disk state and reload, MISSION.md, own alarm + label, BootReceiver pref, fallback wake,
  schedule_next clamps, runs/tokens guardrails and day roll-over, tokens only during runs, on/off, stop, needs_you +
  answer, done, owner-only start, replace, team assign, armAll after restart, failed and unstarted runs, notification
  rate limit, tools in every bot's list and never switched off, brief in the prompt.
- `test/mission_wake_test.dart`: mission alarm with SubMac closed → unattended bot wake with the mission instruction
  and "<Bot> · Mission: …" line; outcome; busy bot not woken twice; offline cut; tool routing (owner starts, wake
  cannot); team mission → lead's mission job with the plan; "Name: step" hand-off starts the teammate's turn.
- `test/browser_background_test.dart`: FetchBrowser parse/open/click/find/back, unsupported actions, blocked pages;
  BrowserJobs switches to read-only on a no-view error with no screen only; new tasks start read-only after a failure;
  BotBrowserModel routes and the OpenAI tool-call request/answer; source checks for the off-screen tab, the layer and
  BootReceiver; an off-screen start failure marks the session.
- `test/tool_budget_test.dart`: cap 11560 → 11970 for the four mission tools (~400 tokens).
- `test/always_on_test.dart`: while "Always on", a finished run keeps the steady service and a finished run while it is
  off really drops it; a pulse re-asserts the line and wakes only a genuinely overdue heartbeat, never one that ran.

## Device checks (after the next APK)
1. Bot Job page → Mission → goal "Every 2 hours check the price of <product> on two shops and keep a log", 6 runs a
   day. Swipe SubMac away, screen off. Within ~1 min a "<Bot> · Mission: …" notification appears and goes; the Job
   page later shows the plan, a log line per run and the next wake. `adb shell dumpsys alarm | grep mission` lists it.
2. In that run, a `browser_task` (or ask for a site that needs scripts): `adb logcat | grep -i inappwebview` shows a
   headless WebView; no "browser view is not ready". If the device's WebView refuses off-screen use, the task's report
   says READ-ONLY mode and still reads the pages.
3. Restart the phone, do not open SubMac: the mission's next wake still comes (rearm notification, then the run).
4. A goal that needs spending ("buy the cheapest one") → one "[needs you]" notification, Approve on the Job page →
   the next run within a minute logs the answer.
5. Stop on the Job page during a run: the run stops, no more wakes.
6. Team: Tasks tab → Mission "Plan and write 3 blog posts"; the lead's run posts "Name: …" hand-offs, those bots
   start by themselves and report back, the lead is woken by the reports.
7. A bot on an OpenAI-compatible key doing a browser task: the provider's dashboard shows the calls.

## Not done / server
No server or edge-function change (nothing in supabase/pending). No APK, no deploy.
