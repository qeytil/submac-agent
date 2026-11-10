# Teams on opencode — plan (2026-11-03, for owner approval)

Today: a team is a group chat run by TeamRun on the old Genkit core (its own model calls and tool loop). Offices jobs
already run as opencode turns in members' chats.

## Plan
1. One engine. Every member's part is an opencode turn in that member's own session, with its own brief, memory and
   tools (as bots now). TeamRun keeps only the group chat rules (who is addressed answers; @team; @silent; stop).
   agent/core.dart and the Genkit team wire are deleted.
2. The lead delegates for real. New lead tool `team_assign(member, task)`: runs the member's turn, waits, and returns
   the member's result to the lead. Up to 2 members work at once on the phone; the rest queue. The lead closes with one
   combined answer; each member's part opens on tap.
3. Shared team folder `teams/<id>/`: GOAL.md, BOARD.md (who does what, status), and the files they make. Every member
   reads and writes there, so work builds on work.
4. Team responsibilities in the background: team routines and watches wake the lead, who plans and assigns, then
   reports with @note / @message like a bot.
5. Safety: Ask / Autopilot applies to every member; money and settings always ask. Per-team daily budget and step cap;
   one note when the budget is used.
6. Who speaks when nobody is addressed: stays one small model decision.

## Order
T1 member turns on opencode (1) · T2 team_assign + shared folder (2, 3) · T3 team routines (4) · T4 delete old core.

## Built (2026-11-03, v1.13.114+184)

- T1: every member's part and the lead's work are opencode turns (`AppState.teamTurn`), each in a fresh session that is
  deleted afterwards, with the bot's own brief (`Bots.opencodeBriefOf`) and its own tools. Route key `team:<team>:<bot>`.
- T2: the lead hands off with one tool, `team_assign(member, ask)`; at most `TeamRun.parallel` (2) members at once.
  Shared folder `teams/<id>/` (GOAL.md, BOARD.md, files) in every team prompt.
- T3: `team_task(team, task)` lets a lead give its team a job (from a routine or follow-up). The lead's brief lists its
  teams. A busy team or a lead over its daily budget says so instead of starting.
- T4: teams no longer use the Genkit core at run time (no `llm`, `toolsFor`, `runTool`, approval interrupts wired).
  `agent/core.dart` stays only for the browser worker and the old test path; deleting it belongs to layer 2.
- Safety: Ask / Autopilot applies to members (their tools go through `runToolWithApproval`); a step cap of 40 tool
  steps and a 30 min limit per turn; the owner's stop aborts the running turns.

## Audit fixes in the same change

- Tool calls from opencode were routed to a chat by tool name only: two chats or two team members running the same tool
  at once could act on the wrong bot (a leak). Now matched on name and arguments (`McpRoutes`), expiring and capped.
- Permission and question cards of a team member's session showed in whatever chat was open; they now show in the
  member's own chat.
- Bot token budgets were not counted for opencode work; opencode's token counts now go to the bot.
- An early idle event could end a turn before it started; a busy event now resets it.
- Stopping a team now also clears the members' waiting approval cards on opencode.
- Design guard and a stale narration test fixed (composer pill and thinking block).

## Team audit (2026-11-04, owner: team output only in the team chat, no leaks, no limits on bots working)

Causes found:
- Office jobs (a member answering the owner in the team chat, board tasks, reviews, the lead's rounds, digests,
  mentions) ran as a wake inside the bot's private chat (`startBackgroundTask(reuseConvId: b.convId)`), in the same
  opencode session as its 1:1 conversation. Every team reply, its steps and its result showed in both chats, the team's
  prompt sat in the private session's context, and the private chat's history leaked into team work.
- Team turns asked (permission and question cards), ran tools, browser jobs and screen steps as the member's private
  chat (`convId: home`); a member with no chat fell back to the "Telesia team" chat. Unwaited browser results were posted
  into the private chat. A team's "stop" stopped every run in its members' private chats.
- The bot's private brief read its journal's team lines ("Team part for …", "Led …").
- A `session.error` with no session id ended every opencode turn running at that moment.
- A Telesia call with no route went to "the only turn running", also when it came from a session no turn owned (a
  stopped turn finishing a step); with several turns, the arguments fallback could take another turn's entry.
- Caps: `TeamRun.parallel` (2 members at once), leftover parts run one by one, `_officeParallel` (2 office jobs at once),
  one office job per bot, office work waiting while the owner talks to the bot, the team daily work limit, 6 mentions
  an hour, wakes put off while the bot did office work. `syncMcp` re-added Telesia's MCP server while other turns had
  calls in flight; a BYOK restart could race a second turn starting.

Fixes:
- Team work runs under its own route key (`TeamKey`: `team:<office>[~job]:<bot>`), in a fresh opencode session, and
  acts as the bot through `Bots.byConv(key)`. Office jobs are `teamTurn`s now; their result is posted to the team chat
  only. Office tools are offered only under a team key.
- Team asks: permissions become the team's approval card (team chat line, approvals inbox, notification); questions
  are skipped. Team browser jobs run unattended and report only to their turn. Stop expires the team's cards and never
  touches private chats.
- Team journal lines carry `team: true` and stay out of the private brief.
- `OpenCodeTurn` ignores errors of no session; orphan sessions' calls are refused (`McpRoutes.watchOrphans`); the
  arguments fallback is used only while one turn runs.
- No caps: every hand-off and leftover part starts at once, every ready office job starts at once (a bot may do several),
  no daily work limit, no hourly mention cap. Kept: the bots' share (background lane), each bot's token budget, the
  "a mention can't wake others" loop guard, one job per team at a time, one run per chat.
- Engine: turns are counted (`ensure(turn: true)` / `endTurn()`); no restart and no MCP re-add while other turns work.

## Team chat status and error lines (owner 2026-11-04, 1.13.121)

"When a bot is working and typing, it should say one state line with the bot name; for an error or issue, the name of
the bot with the error type in a small line."

- `TeamStatus` (lib/services/team_status.dart) tracks team turns by `TeamKey` only (a private chat key is ignored).
  `teamTurn` calls `begin` / `phase` / `end`: "Nova is working…" while the turn thinks or runs steps, "Nova is typing…"
  while its reply text streams; the line goes when the turn ends and its message lands. One line per bot (several bots
  at once: one line each; one bot with two turns: one line, typing wins).
- A failed turn leaves one small line "Nova · rate limit" (types: rate limit, out of budget, allowance used, out of
  credit, key error, provider error, timed out, no connection, tool failed, no reply, error), mapped in one helper
  `TeamStatus.typeOf`. Tap shows the detail. It stays until the bot starts its next work in that team.
- Gone: the "<bot> hit a problem: <raw error>" system posts, the "<bot> used today's token budget" post, and a failed
  member part's "I could not finish my part" bubble. Kept: team-level notices (paused until tomorrow, stopped trying
  after 4 tries, the team could not finish).
- Shown only by `TeamLiveLines` in the team chat (offices_screen); no other screen or widget reads `TeamStatus`.

## Team awareness (owner 2026-11-05, 1.13.126)

Owner: "bots send duplicate messages; they confuse who they are and their roles; weak situational awareness; the lead
always repeats the owner's words to the others." Wanted: the lead leads only when the owner is away or says so; no bot
speaks without understanding the situation.

Root causes found:
- Duplicates. (1) An office job's final reply is posted to the team chat (bots_controller `_officeRun`, the
  `Offices.I.post(o, b.id, visible…)` after `teamTurn`), and the team prompt told bots to post with `office_post` too
  (offices.dart `teamStablePromptOf` "Team chat: office_post"; the tool posts at once in `execute` 'office_post'), so a
  reply often landed twice. (2) "@team" and several mentions enqueued one reply job per bot (`ownerPost` → `askBot`),
  and the pump started them all at once (`_officePump`, no cap since 1.13.119), so every bot answered the same thing
  blind to the others. (3) The lead addressed with named teammates: the teammates were asked (`askBot`) and, when the
  lead's floor call said team_task, the lead also planned and handed them parts: each answered twice. (4) A team job
  posted each part three times: the plan list (`planText`), a hand-off post per member (`doPart` →
  `BotManner.handOff`), and the member's note. (5) `enqueue` never deduped reply jobs, so a double send (or the
  notification reply plus the app) answered twice; a job retried after a busy/offline failure could repost what it
  already posted with office_post. Not a cause: stream + final (team turns post only `turn.answer`, once).
- Identity and roles. The team chat in every prompt was "Name: text" with no role, no lead/member, no "you", no
  reply links or times (`teamLivePromptOf`, `floorSystem`), so a bot could not tell its own lines from a teammate's.
- Parroting. `_propose` asked the lead to "restate the goal", an unreadable plan fell back to the owner's message as
  every member's part (`parts.addAll(… ask: job)`), and `handOff` then posted it to each member.
- Lead always leading. Any team_task from the floor call (or CB-36's listed deliverables) went to `_propose`, so the
  lead planned and relayed even while the owner was in the chat.

Design (lib/services/team_floor.dart):
- `TeamTranscript`: every message labelled `#n HH:MM Name (lead|member, Role; you) → addressee (reply to #m) [NEEDS
  OWNER]: text`, the bot's identity, the roster with roles, and "the situation": newest message and to whom, what the
  owner last asked and of whom, who already answered it, what waits on the owner, whether the owner is here, who leads,
  who is working on a reply. Used by office jobs (`teamLivePromptOf` / `teamStablePromptOf`), team parts, the lead's
  run, the plan and the "who speaks" call.
- `TeamFloor.rules`: addressed → those bots; a role named ("the analyst") → that member; "team lead" → the lead; the
  owner answering a bot's question within 15 min → that bot; only otherwise one small model call. The model picks ONE
  speaker; for a job that needs several roles while the owner leads it lists up to 3 `speakers`.
- Threads: several bots asked about one owner message (`@team`, several mentions, a multi-role job) get
  `OfficeJob.thread` = the owner post id; the pump runs one job of a thread at a time, each sees who answered before it
  (`threadAnswers`) and may reply `[no reply]` (no "did not reply" line for a covered thread answer; a covered small
  talk gets no second quick reply). Same bot + same words: one job (queue and in flight).
- `TeamDedupe` in `Offices.post`: a bot post that near-repeats its own recent post, another bot's substantive post
  (4+ words), or echoes the owner's latest message (15 min window) is dropped and the earlier post returned. Task
  updates, approvals, system lines and the owner are never dropped.
- `TeamLeadMode`: peer while the owner is here; leading when the owner says "lead, take over" / "I'm away" (until
  "I'm back"; `Office.delegated`, saved) or has been away 20 min (for routines and office work). An owner message always
  means the owner is here: the lead plans it only when handed over or given the job by name; otherwise the members the
  job needs answer in a thread. The lead's prompt says which mode it is in; leading = concrete subtasks per role with
  hand-offs ("after"), never the owner's words forwarded (a part that parrots the owner becomes a role part; no
  hand-off post when the plan already shows it). Indicator: one small line in the team chat ("Hodan is leading the
  team" / "… while you are away") while the lead leads.
- `NeedsYou`: a bot starts a post with `[needs you]` when the owner must decide or act; it becomes a "Needs you" post
  (kind 'ask') and notifies the owner. Every team prompt says so.
- Kept: team isolation (TeamKey; nothing goes to private chats), team status lines, stop, @silent, the mention loop
  guard.

Tests: test/team_awareness_test.dart (transcript, turn selection, threads, dedupe, needs you, lead mode);
team_intelligence_test.dart updated (a team job is planned by the lead when handed over; labelled floor prompt).

## Team turns, assignments and bot models (owner 2026-11-06, 1.13.139+209)

_Version note (2026-11-07): merged into main together with fix/oc-tools (1.13.138+208: SaveGuard, bot_routine repeat,
connected apps); both kept, shipped as 1.13.139+209._

Owner's report, highest priority: (1) "bot B, analyze bot A's research once it posts" left B silent when A posted;
(2) bots the lead assigned stayed silent until the owner told each one "start working"; (3) other rules blocking
teamwork; (4) bots ignored the model chosen in their profile.

### Root causes
1. **Only the owner's messages started turns.** `TeamRun.send` routed owner messages into `reply` jobs; a bot's own
   final reply was posted with `Offices.post`, which started nothing. Nothing remembered "when X posts, do Y".
2. **Assignments in chat started nobody.** The only bot-to-bot wake was an `@mention` inside the `office_post` tool,
   and it was a `mention` job (8 steps, "do not start new work"). A lead's final reply ("Nova: find prices",
   "@Nova …") woke no one, and a bot answering a mention could wake no one at all. Only `office_board add` with an
   owner started a task job.
3. Collaboration blockers found: `enqueue` kept one waiting job per bot+kind+task, so a second hand-off or mention to
   the same bot was dropped as a duplicate; while a team job ran, every owner message went to the job's inbox, so a
   member whose part was done never answered when addressed; the lead's PEER instruction said "do not assign" even
   when the owner asked it to; the hand-over flag was saved under `dg`, the daily report time's key, so handing over
   overwrote the report time; retries lost the job's thread.
4. **Plain model calls were pinned to Telesia.** opencode turns (private chat, wakes, scheduled tasks, team parts)
   already sent the bot's model (`OcLane.pick`), but every one-answer call went to `telesiaRef`: the team's "who
   speaks" decision, the lead's plan and combined answer (`_teamAsk`), instant team replies (`_officeQuick`),
   `bot_ask` (`_botConsult`) and the check-in gate (`_worthWaking`). The office pump also held a BYOK bot's team work
   when Telesia's bots' share was used up, and the gate stopped its check-ins for the same reason.

### What changed
- `lib/services/team_floor.dart`: `TeamWatch` (saved per team in `Office.watches`, 24 h, once) and `TeamReact`:
  watches from owner messages (`fromOwner`: a "when/once/after" word, an event word, the teammate waited for),
  assignments in any bot post (`assignmentsIn`: lines opening on a name, @mentions, @team), and `TeamReact.of`
  deciding the turns a post starts: `react` (watch fired), `assign` (work handed over; the one who handed it watches
  for the report and is told who is still to come), `mention` (a question). Lead instructions say naming a teammate
  starts their turn; PEER allows assigning when the owner asks.
- Loop guards: chain depth on every job (`OfficeJob.depth/cause/post`; owner message = 0), bot-to-bot turns up to
  `maxDepth` 4, owner watches up to 8; one turn per post per bot; a `mention` never wakes the teammate whose message
  started the turn (ping-pong); 20 bot-started turns per team per 10 min, then one system line; small talk starts
  nothing; `[no reply]` allowed for react/mention.
- `lib/services/offices.dart`: `post()` runs `TeamReact` for every bot post (depth from the caller or `jobOf`);
  `addOwnerWatches` + system line; new tool `office_watch`; `office_post` uses the same mechanism; job texts for
  `assign` ("it starts now, report back") and `react`; reply text tells a watcher the rest comes later; enqueue keeps
  one job per message for reply/mention/assign/react; `Office` JSON: `dl` for the hand-over flag, `wa` for watches.
- `lib/services/team_run.dart`: watch-only owner messages need no floor call; while a job runs, an addressed bot
  whose part is done answers itself; structured job posts (plan, hand-offs, parts, combined answer) pass
  `assigns: false` so members are not started twice (watches still fire on them).
- `lib/state/bots_controller.dart`, `system_phone.dart`, `app_state.dart`: office runs carry the chain into their
  posts, assignments always report back, step caps for assign/react; plain bot calls go through
  `lib/services/bot_llm.dart` (`BotModelRoute`, `BotLlm`; BYOK calls go straight to the provider via the new
  `ByokFetch.complete`, OpenAI/Anthropic/Gemini); a BYOK bot's office work is not held by Telesia's allowance.
- Tests: `test/team_turns_test.dart`, `test/bot_model_routes_test.dart` (incl. an office run whose post starts the
  watching teammate's run on its own model).

### Still open
- The browser subagent (`browser_task`, old core) still runs on Telesia's model for every caller; it cannot use a
  BYOK model until it moves onto opencode.
- Watches are matched by rules (English, some Somali/Arabic words); a bot can always set one with `office_watch`.
- Device check: a team with A and B; "B, analyze A's research once it posts", then "A, research X": B must post its
  analysis right after A, with no further message. Lead in charge ("lead, take over"), lead assigns "A: …" lines:
  both start and report back, lead sums up once. A bot on an own model: its team answers and instant replies come from
  that model.
