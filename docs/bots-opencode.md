# Bots on opencode — design (draft 2026-11-02)

## Core idea
A bot is a folder plus an opencode agent. Its state is files, so opencode manages memory with its own file tools; SubMac only wakes it and shows results.

workspace/bots/<id>/
- BOT.md — persona, mission, rules (built from Bot fields; becomes the opencode agent prompt)
- MEMORY.md — what it knows; it edits this itself
- DESK.md — open tasks and their status
- runs/YYYY-MM-DD-HHMM.md — one short summary per run
- knowledge/ — owner's notes and files
- skills/ — SKILL.md files it learned or was given

## Wakes (one pipeline for every trigger)
time (routine, follow-up) · event (notification watch, keyword) · heartbeat (proactivity) · owner message · another bot.
Every wake = { bot, reason, payload } → run queue (one run at a time on the phone).

## A run
1. Gate (no model): quiet hours, daily budget, battery/charging, and a cheap precheck for watches (did the page or inbox change?). Nothing new → no run.
2. Start engine if cold (~5 s), new session on the bot's agent, cwd = bot folder.
3. Preamble: the wake reason, DESK.md, last 3 run summaries. MEMORY.md is read on demand.
4. Work with its tools (SubMac MCP: browser, phone, apps, web).
5. Must finish with bot_report(kind: silent | message | call | ask, text). Missing report → one nudge, then silent + logged.
6. Wrap-up: writes the run summary, updates MEMORY/DESK, may schedule its own follow-up (bot_followup).
7. Engine stops when the queue is empty.

## Safety
- Powers map to opencode permissions per bot agent (web, browser, phone, files, apps).
- Read-only actions allowed. Side effects (send, pay, post, delete, sign in) = "ask".
- An "ask" while unattended becomes a notification with Approve / Deny; the session waits on opencode's permission request and resumes on the answer; expires to Deny.
- Caps per run (time, steps) and per day (runs, messages, calls). Ignored messages back off (ignoredStreak).

## Out of the box
- Rehearsal on creation: first run is a dry run showing what it would do; owner taps OK and that becomes the routine.
- Prechecks without a model save the free budget: most wakes end at the gate.
- Self-improving: after a run that needed a correction, it writes a lesson into skills/.
- Teams = opencode subagents: the Chief delegates to other bots' agents; team_run.dart's old core can go.
- Shareable: a bot folder (minus memory and logins) is the package to share, publish or hire.
- Missed runs (phone off): on wake, run the latest missed one once and skip stale ones.

## Phases
P1 routines + follow-ups on opencode, folder memory, bot_report.
P2 notification approvals.
P3 watches with prechecks, heartbeat.
P4 Chief and teams as subagents; delete agent/core.dart.
P5 rehearsal, lessons, sharing.

## Done in 1.13.113 (2026-11-03)
- A bot's opencode turn (owner chat or background wake) gets the bot's own brief after opencode's prompt
  (`Bots.opencodeBriefOf`): who it is, mission, instructions, memory, lessons, desk, routines, follow-ups, recent
  journal, its tools, its folder `bots/<id>/`, and its name in place of SubMac's.
- Its own tools (bot_remember, bot_desk, bot_followup, bot_routine, bot_watch, bot_call, bot_ask, bot_lesson, and
  bot_make / team_make for the Chief) are offered through the SubMac gateway and called with submac_run_tool.
- Routines, follow-ups, watches, heartbeat, scheduled tasks and the @note / @message / @call outcome stay as they were
  and now drive full opencode turns.

## 2026-11-04: private chat vs team work
A bot's private chat with the owner is a normal 1:1 conversation (its own session, its own wakes and routines). Team
and office work never runs there: it has its own sessions under a team key and posts only to the team chat. Bots run
side by side with no cap (see docs/teams-opencode-plan.md, "Team audit").
