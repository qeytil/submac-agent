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
