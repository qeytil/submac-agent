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
  chat (`convId: home`); a member with no chat fell back to the "SubMac team" chat. Unwaited browser results were posted
  into the private chat. A team's "stop" stopped every run in its members' private chats.
- The bot's private brief read its journal's team lines ("Team part for …", "Led …").
- A `session.error` with no session id ended every opencode turn running at that moment.
- A SubMac call with no route went to "the only turn running", also when it came from a session no turn owned (a
  stopped turn finishing a step); with several turns, the arguments fallback could take another turn's entry.
- Caps: `TeamRun.parallel` (2 members at once), leftover parts run one by one, `_officeParallel` (2 office jobs at once),
  one office job per bot, office work waiting while the owner talks to the bot, the team daily work limit, 6 mentions
  an hour, wakes put off while the bot did office work. `syncMcp` re-added SubMac's MCP server while other turns had
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
