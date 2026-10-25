# Approval cards bug hunt (2026-10-24, v1.13.90+157)

Approvals live on the phone only (SharedPreferences `approvals_v1`; the cloud bot run has no action tools), so the
server tables hold no approval records. Evidence came from reading the code paths plus the `messages` table (tool
results "The user said no…" / "wants something changed first", and tool calls that never got a result).

| # | Bug | Fix |
|---|-----|-----|
| AC-1 | Ask ids were `a<milliseconds>`. Two bots asking in the same millisecond (team members side by side) shared an id: the second ask replaced the first one's waiter (that bot waited the full 3 h whatever was tapped), a tap could answer the wrong ask, and the list had two cards with one key. | `Approval.newId()` (microseconds + counter). |
| AC-2 | Stopping a task left its bot asks pending for 3 h; approving one did nothing; the stopped run kept waiting. | Asks carry `convId`; `stop()`/`stopRun()` call `Offices.expireFor(convId)`. |
| AC-3 | "Allow always" turned on Full access but every other waiting ask kept waiting; turning Full access on in Settings did the same. | `Offices.releaseForFullAccess()` on Full access going on (payments still wait); an ask made while Full access is on goes ahead. |
| AC-4 | "Allow always" on a WhatsApp ask approved the message but never turned Full access on. | WhatsApp path honours `req.allowAlways`. |
| AC-5 | The sheet decided "never on payments" from the words only; the router reads the tool name too, so a payment by a tool with neutral words still showed "Allow always". | Router sets `ActionRequest.kind`; sheet hides the button when either says money. |
| AC-6 | Two tasks needing an OK at once stacked two sheets; a sheet from a background chat (browser task, chat left working) opened over the current chat with no hint where it came from; a stopped task's sheet stayed up. | `ConfirmQueue`: one sheet at a time, "From <chat>" line, closes/skips when its task stops. |
| AC-7 | Sign-out cleared the asks list but left their waiters hanging. | `Offices.clearApprovals()` answers them "no". |
| AC-8 | History trimming (60) could cut an ask still waiting. | Trim answered ones first. |
| AC-9 | Words in English only: sheet "Show/Hide details", "Edit/Cancel", every confirm label (Send, Push, Take offline…), card "X asks", "and N more", "3 emails to send", "A and B", the Trusted offer. | `tr()` + Somali and Arabic strings (native review owed). |
| AC-10 | Sheet: "Allow always (Full access)" shared half a row with "Not now" and was clipped on small phones and in Somali; "Show details" showed with no details; a double tap could pop twice. | Own full-width line, details only when present, answered-once guard. |

Tests: `test/approval_cards_test.dart`.
