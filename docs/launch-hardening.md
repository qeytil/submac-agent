# Launch hardening (feat/launch-hardening, 2026-10-26)

Owner's ask: prepare the app and agent so untested requests don't break or embarrass us at launch, and so it handles
any task the way the best assistants do. Base: dev 769887ca (v1.13.104+174).

Method: 186 realistic launch prompts in 21 categories ([use-case-matrix.md](use-case-matrix.md)), each traced through
the code it hits: system prompt (`lib/state/agent_prompt.dart`), turn building and gates (`lib/state/agent_runner.dart`),
the Genkit core (`lib/agent/core.dart`), loop helpers (`lib/services/agent_loop.dart`), truth gate
(`lib/services/truth.dart`), attachments (`_userContent`), rendering (`lib/widgets/markdown_view.dart`, `math_text.dart`,
`lib/services/reply_text.dart`), errors (`agent_stream.dart`, `ErrorCopy`), bots and teams (`team_run.dart`,
`offices.dart`, `bot_manner.dart`). Then a scenario suite drives 34 representative prompts and model behaviours through
the real task loop with a mocked model (`test/launch_scenarios_test.dart`).

What already held up well (no change needed): unknown tool names no longer crash a run (CB-3), Stop races the model call
(CB-2), messages sent mid-answer are answered (CB-1), cut-off replies continue in one bubble (CB-10), too-long requests
compact or answer plainly (CB-30), error cards are in the app's language (CB-27), approvals and outbound guards, loop
and stuck guards, step checkpoints, kill/resume journal, the English truth gate, the site/page checks, markdown table
repair, the quick lane for greetings, attachment size limits.

## Findings, ranked by launch risk

| Id | Risk | Finding | Where | Status |
|---|---|---|---|---|
| H-1 | High | **Replies drift out of the user's language.** "Reply in the language the user writes in" sits at the top of a long prompt; after English web pages, files or tool results the final answer to a Somali or Arabic question often came back in English. Nothing checked it. | `_systemPrompt` (Language), `buildTurn`, no finish check | **Fixed** |
| H-2 | High | **The truth gate only understood English.** A Somali or Arabic reply claiming "sent / saved / booked / paid" with no tool behind it ("Fariinta waa la diray", "تم إرسال الرسالة") went straight to the user. Most launch users write Somali or Arabic. | `lib/services/truth.dart` | **Fixed** |
| H-3 | High | **Missing capabilities had no graceful path.** An invented tool name got "use one of the tools you were given" and nothing more, so the model kept guessing until the 3-strike stop. The prompt said "if nothing can do it, say so" but never "then do the closest real thing" (draft it, give the link/steps, set a reminder, connect the app). Team members had no such rule. | `ToolNames` in `core.dart`, prompt, `team_run.dart` | **Fixed** |
| H-4 | High | **A system-written chat reply was English-only.** The reply left when the unknown-tool stop ends a run (CB-42) was English in a Somali or Arabic chat. | `ToolNames.stopReply`, `agent_runner.dart` | **Fixed** |
| H-5 | Medium-High | **No ceiling on finish-gate send-backs per turn.** Each gate limits itself, but together (inbox, blank, truth, site, cut-off ×6, checklist ×3, finish, inline, format, language) one answer could cost a long string of model calls. | `FinishGateMiddleware` | **Fixed** (max 10, then the reply stands) |
| M-1 | Medium | **Arabic replies flipped left-to-right** when they carried a code block or a long link: the bubble's direction counted every Latin letter in code and URLs. | `majorityDir` in `reply_text.dart` | **Fixed** |
| M-2 | Medium | **"I'll do it now" with nothing done was only caught in English.** A Somali ("Hadda waxaan raadinayaa…") or Arabic ("سأبحث…") one-line promise ended the task. | `Announce` in `agent_loop.dart` | **Fixed** |
| M-3 | Medium | **Attached Office files, audio and video said only "[Attached file …]".** The agent guessed at contents, or said it couldn't open a .docx/.xlsx although `read_document`/`data_sheet` can; for audio/video it could pretend to have listened. | `_userContent` | **Fixed** (reading route or an honest "cannot hear/watch") |
| M-4 | Medium | **An unclosed `$$` swallowed the rest of the reply** into one broken formula (a cut-off reply, "$$$" for price). | `MathBlockSyntax` | **Fixed** |
| M-5 | Medium | **General-purpose quality was implicit.** The prompt is strong on SubMac's tools and cards but had no compact guidance for knowledge answers (search only when current), writing (finished text, keep meaning), translation fidelity, complete runnable chat code, maths via `calculate`, broad asks (answer first, then one question), and "help fully, no lecturing". | `_systemPrompt` | **Fixed** (`AgentCraft.block`, cached prefix) |
| M-6 | Medium | Persian/Urdu text would be named "Arabic" by any naive script check. | `ReplyLang.detect` | **Fixed** in the new code (generic line instead) |
| L-1 | Low | The quick/light lane's action words have no Arabic verbs. Harmless: short Arabic tasks fall in the light lane, which still has the core tools and `more_tools`. | `quick_lane.dart` | Left |
| L-2 | Low-Med | **No built-in transcription of attached audio/video.** Only the user's own model (`ai_call` transcribe) can. The agent now says so honestly. A `transcribe_file` tool on `Cloud.transcribe` (already used by meeting notes) would close it, but it spends the transcription allowance in a new place: an owner decision. | tools | Left (recommendation below) |
| L-3 | Low | Code block rendering (wide/RTL code) | `CodeBlock` | Left: owned by fix/ui-restyle |
| L-4 | Low | Tool descriptions: spot-checked the ones the matrix routes to (calculate, read_document, data_sheet, email_draft, schedule_task, browser_task, web_search); a full audit of every catalog description was not done. | tool catalog | Left |
| L-5 | Low | The truth and announcement patterns are phrase lists: paraphrases still slip, and a Somali sentence with the question particle "ma" is skipped on purpose (never a false "not proven"). | `truth.dart`, `agent_loop.dart` | By design |
| L-6 | Low | Team and browser sub-runs are settled, not resumed, after the app is killed (known since build-61). | genkit-core | Left |
| L-7 | Low | The language finish check covers Somali, Arabic and English (clear script/word evidence). Other languages get the per-step anchor only. | `ReplyLang.mismatch` | By design |

## What changed (feat/launch-hardening)

- `lib/services/reply_lang.dart` (new): `ReplyLang.detect/ofChat` (Arabic script, Ethiopic, Somali, English; code,
  links and formulas ignored; short answers like "haa" carry the previous language; Persian/Urdu not called Arabic),
  `anchor` (one line at the END of every step's request, in the tail note, so the cached prefix is untouched),
  `mismatch` + `fixNote` (finish check, one round, never when the user asked for a translation or another language,
  never when the reply language is set by hand), `asksOtherLanguage`.
- `lib/state/agent_runner.dart`: the anchor is added to every step (not for app-made wakes); a new last finish gate
  sends a wrong-language final reply back once; the unknown-tool stop reply uses `ToolNames.stopReplyFor(userLang)`.
- `lib/services/truth.dart`: Somali and Arabic claims (sent, booked, saved, created, deleted, posted, paid, called,
  installed) with Somali/Arabic negation; Arabic question mark ends a sentence.
- `lib/agent/core.dart`: `ToolNames.near` (shared words or near spelling, up to three) rides on the `unknown_tool`
  stub's arguments; `unknownText` names them and says to use one, do it another way, or say plainly what can't be done
  and do the closest real thing. `stopReplyFor` (en/so/ar). `FinishGateMiddleware.maxSendBacks = 10`.
- `lib/services/agent_craft.dart` (new): `AgentCraft.block` (in the main prompt after "How you work"; bots read it
  through their SubMac section), `teamLine` (team member prompt), `attachLine` (Office → read_document/data_sheet;
  audio/video → cannot hear/watch, ask for text; missing file → attach again).
- `lib/services/agent_loop.dart`: `Announce` also catches Somali and Arabic one-line promises (and the Arabic "؟").
- `lib/services/reply_text.dart`: `majorityDir` ignores code, inline code, link targets and URLs.
- `lib/widgets/math_text.dart`: `MathBlockSyntax.canParse` needs a closing delimiter.
- `lib/state/agent_prompt.dart`, `lib/app_state.dart`, `lib/services/team_run.dart`: one-line wiring each.

Shared files touched (kept tiny, additive): `agent_prompt.dart` (+2 lines), `agent_runner.dart` (+25 lines in
`buildTurn`, `gates()`, the stop reply), `app_state.dart` (+2 imports), `team_run.dart` (+1 import, 1 line). Nothing in
the sidebar, code blocks, Chief/bot-creation tools, the call tool or the updater.

## Tests

- `test/launch_hardening_test.dart`: unit tests for every fix (language detection/anchor/mismatch, Somali/Arabic truth
  claims and negations, near tool names, craft block, localized stop reply, send-back ceiling, bubble direction,
  Somali/Arabic announcements, attachment lines, unclosed math).
- `test/launch_scenarios_test.dart`: 34 scenarios through the real loop (send → `_runAgent` → Genkit → `LlmClient` with a
  fake ai-chat): every one must end on its own, show a reply or a readable error card, and never show raw internals
  (GenkitException, NOT_FOUND, SocketException, stack traces). Covers language (en/so/ar, translation, mixed, short
  follow-ups), fake claims in three languages, tool routing (calculate, todo), unknown tools and localized stops,
  announcements, 40k-character code, cut-off continuation, table repair, LaTeX + Arabic with code, blank replies,
  429/401/413, offline, Stop mid-task, two quick sends, Office/audio attachments, greeting quick lane, ambiguous ask.
- One existing expectation updated: `chat_regress_tools_test.dart` CB-3 (the unknown-tool text now names the closest
  real tool).

## Server-side recommendations (not deployed, not required for this PR)

1. **Transcription of attached recordings (L-2):** either a client tool on the existing `Cloud.transcribe` (no server
   change, but it spends the transcription allowance from chat, so it is a billing/product call) or nothing. Owner
   decision.
2. None of the fixes needs a server change. ai-chat v43 stays as is.

## Judgment calls for the owner

- The language check sends a wrong-language answer back **once** (one extra model call in that case only). It never
  fires on translations, on "write it in X", on code-heavy replies, or when the reply language is set by hand.
- The per-step language line costs about 60 prompt tokens per step; it sits in the tail note, so the cached prefix and
  cache hits are unchanged.
- The craft block adds about 600 tokens to the cached system prompt (one-time cache cost per prompt version).
- The send-back ceiling is 10 per turn; after that the reply stands as it is (an imperfect answer beats a silent loop).
- Somali/Arabic phrases (stop reply, claim and promise patterns) need a native speaker's review.
- No version bump: four branches are open against dev at the same version; the release prep sets it (as #26 did).
