# Bug hunt 2026-11-06 (bugs, glitches, stutter)

Read through chat, opencode runs, bots, teams, scheduled/background tasks, notifications, voice/Live, settings,
store/sharing, BYOK and UI performance. Full suite 1498 passed (includes tool_budget, tool_scope, chat_regress_*,
long_horizon, design_guard); analyze 0 errors (2 infos, baseline). Test: test/bughunt_1106_test.dart.

## Fixed (1.13.133+203)

| # | Sev | Area | Problem | Fix |
|---|---|---|---|---|
| 1 | High | opencode chat + team runs | The engine's event stream (SSE) dropping mid-turn (phone asleep, socket closed, engine restarted or killed) left the chat on "Working" forever (no timeout in the chat loop) and team work waited out its 30 min. The stream was only reopened at the next turn. | `OpenCodeEngine.streamDrops` + `relisten()` + `statusOf()` (`GET /session/status`) + `recover()`: when the stream dropped, or nothing changed for 30 s, the turn asks the engine (at most every 10 s, never in the first 8 s). Idle → the stored messages (`GET /session/{id}/message`) are folded in (`OpenCodeTurn.applySnapshot`) so the answer shows, and the turn ends; engine gone → the turn ends with a plain error. A long silent step just answers busy. |
| 2 | High | Chat stutter | Every streamed word from opencode called `notifyListeners()` on AppState: the open chat list (O(messages) work per build), composer, home, team line all rebuilt per token; bots' background turns rebuilt the owner's open chat the same way. | `_throttledNotify()` (80 ms batches, same as the reply's reveal); the end of the turn still notifies at once. |
| 3 | Medium | Page cards | `PageCard._title` read the whole HTML file synchronously on every build (i.e. every streamed batch) for each page card on screen. | Reads only the first 4 KB, and only when the file's mtime/size changed. |
| 4 | Medium | End of turn | `TurnVisuals.madeSince` walked up to 3000 workspace entries with blocking calls on the UI thread after every turn. | `madeSinceAsync` runs it in `Isolate.run` (in place under flutter test). |
| 5 | Low | Files screen | `setState` after the screen was closed while the workspace path was still loading. | `mounted` check. |

## Still open (not changed here)

| Sev | Area | Finding | Suggested |
|---|---|---|---|
| Medium | Scheduled tasks | A one-off task missed by more than 30 min (phone off) is removed at the next start without running and without telling the owner (`Scheduler.useAccount` catch-up). | Owner decision: run it late with a "late" note, or drop it with a notification. |
| Medium | Accounts | ISSUES T-03: saved site logins stay on the phone for the next account. | Tag per account like scheduled tasks. |
| Medium | Bots background | Headless alarm runs (OcChannel, wake lock) never checked on a device. | Device check. |
| Low | Preview | Text/docx/pptx previews read the file synchronously inside `build`. | Load once in initState / isolate. |
| Low | UI | 13 widgets `context.watch<AppState>()` whole; composer also rebuilds per keystroke. Mitigated by fix 2. | Selectors per field later. |
| Low | Voice | Wake word is "Hello SubMac" (Vosk phrase list); rename needs a new tested phrase. | See docs/rename-telesia.md (R4). |
