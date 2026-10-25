# Agent core on Genkit Dart (v1.13.100+170)

Every agent in the app now runs on one loop: `lib/agent/core.dart` (`AgentCore`), built on **Genkit Dart 1.0, stable API
only** (generate, tools, interrupts, middleware, cancellation). The old hand-written step loop in
`lib/state/agent_runner.dart` is **removed. There is no flag and no fallback**: if the core breaks, agents break, so the
phone tests in the PR are the gate.

## Who runs on it
- Main chat with SubMac and every bot chat (`_runAgent` → `_MainHooks`).
- Team members and the lead (`TeamRun._agent` → `_TeamHooks`): the lead hands each part to a member with a
  `handoff_<name>` tool, sees each result, then answers once; parts it did not hand off still run and are combined.
- The browser sub-agent (`browser_jobs.dart`).

## Files
| File | What |
|---|---|
| `lib/agent/core.dart` | `AgentCore`, `CoreHooks` (app side: build each turn, run a tool, approvals, commit), middleware: turn rebuild, guards, finish gates, commit/journal |
| `lib/agent/wire.dart` | OpenAI-style messages/tools ⇄ Genkit parts. Gemini thought signatures ride in `ToolCall.extra` and go back exactly as received |
| `lib/agent/tool_effects.dart` | Each tool's effect class: read, idempotent, side effect (unknown = side effect) |
| `lib/agent/run_journal.dart` | Per-run JSONL journal (model steps, tool start/end, approvals waiting, 10 s heartbeat, end), `PendingRun`, `ResumePlan`, `ResumeSettle` |
| `lib/agent/reply_schema.dart` | Typed reply blocks (text, summary, table, links, choices, event, file…) with a JSON Schema and a check; an invalid final reply goes back once ("Tidying the answer") |
| `lib/state/tool_router.dart` | Split into check (gate: blocked / needs OK / free), show (approval card) and run |

## Product rules on top (middleware and gates)
Turn rebuilt from the chat each step (prompt caching, compaction, screenshots, one-time images unchanged); step cap and
token budgets; stuck/loop stop; blank-reply nudge; truth gate (a "done" claim needs a tool result); page check; cut-off
continuation; open checklist; finish check on long builds; reply-format check. Approvals are Genkit interrupts answered
through the existing approval cards (Full access, ConfirmQueue and trust levels unchanged).

## Kill and resume
- Journals live in the app's support folder `/runs` (`RunJournal.useAppFolder()` in `initLocal`), kept 7 days.
- On sign-in at start and on every return to the app, `resumeKilledRuns()` looks for journals with no end line and a
  heartbeat older than 20 s, skipping runs still alive in this process, runs older than 6 h and chats already busy.
- Each journal is marked handled **before** resuming, so a resume that dies is never retried in a loop.
- Every tool call the chat shows without an answer is settled first. **Nothing is run again by the app:**
  - a cut-off side effect (send, pay, post, delete, tap…) → "unknown whether it happened, check before retrying";
  - a cut-off read or idempotent call → "no result, safe to call again";
  - an approval that was waiting → "not done, ask again";
  - a call that never started → "not done".
- Then the agent continues with a resume note (carry on, do not start over, never repeat an unknown side effect). The
  status says "Picking up where it left off" and a banner tells the user.
- Only chat runs (main and bot) resume. Team and browser sub-runs are settled by their parent; a team job cut by a kill
  still shows the existing "stopped when the app closed" line.

## Strings
New UI words have Somali and Arabic in `lib/ui/i18n.dart` ("Tidying the answer", "Picking up where it left off", the
resume banner). Status words and banners now go through `tr()`. Native review owed.

## Tests
`test/agent_core_test.dart` (turns, signatures, gates, guards, interrupts, retries, steer/stop, parallel reads) and
`test/genkit_resume_test.dart` (journal, resume plan, settle, reply schema, team hand-offs).
