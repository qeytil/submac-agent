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
