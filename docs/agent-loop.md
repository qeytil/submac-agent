# SubMac agent loop

How SubMac thinks and works through a task, what changed on branch `feature/agent-loop`, and what is still behind the best open agents. Code: `lib/app_state.dart` (`_runAgent`, `_payload`, `_systemPrompt`, compaction, `_streamResilient`), `lib/services/agent_loop.dart` (pure logic, tested in `test/agent_loop_test.dart` and measured in `test/agent_loop_measure_test.dart`), `lib/services/tool_scope.dart`, `lib/services/quick_lane.dart`, `lib/services/llm_client.dart`.

## 1. How a message becomes an answer

1. **Route** (`_route`, `AutoRouter.classify`, `_withThinking`). The user's Auto / Quick / Think chip picks the cloud alias: Quick = `submac-fast`, Think = `submac-think`, Auto = by message (pictures and browsing -> `submac-vision`, simple -> `submac-fast`, everything else -> `submac-smart`). The server (ai-chat) owns providers, keys and fallback; the phone never sends a second copy.
2. **Lane** (`QuickLane.laneFor`). `quick` = small talk: tiny prompt, no tools, ~1 s first word. `light` = short everyday message: core tools + `more_tools`, first step on the fast model in Auto. `full` = everything else.
3. **Tools by need** (`ToolScope`). Core tools plus the groups the chat's messages point at (browser, phone, files, apps, schedule, media, life, WhatsApp). Groups only grow inside a chat; `more_tools` opens the rest for the current task.
4. **Prompt** (`_payload`). Order for the prefix cache: SubMac's fixed rules -> open tool guides -> profile / project / skills / memory -> summary of older chat -> bot live part. Then the history (tool results right after their calls; older screens and results trimmed). **New:** everything that changes per step goes at the very end (see 3.1).
5. **Step loop** (`_runAgent`). Up to `maxSteps` (150 for browsing): stream a reply (`_streamResilient`: rate-limit waits, tool-less fallback for models that refuse tools, retry on transient errors), then run its tool calls, then loop. Stops when a reply has no tool calls, unless a guard says carry on.
6. **Guards inside the loop (existing)**: steering (the user's mid-task words become the top note and a `say` reply), "keep the user in the loop" after 6 quiet tool calls, empty-reply nudge (2x), cut-off continuation (6x, code blocks redirected to files), checklist nudge (open `todo` steps or a promise of more work, 3x), half-written tool calls never run, context-too-long -> compact and retry, dropped connection -> continue, per-task token budget with a wrap-up note, office step caps, bot daily budgets, approvals (`runToolWithApproval` -> one approval card for send/pay/post/delete, trust levels).
7. **After** (`finally`): haptic tick, bot traces, `_afterTask`, background compaction past ~14k history tokens (`_compactLater`), banners.

Ask-first rule (from feature/site-publish): for things made for the user, missing details only they know are asked once with `ask_user` (up to 3 questions with tap answers) unless they said "just do it".

## 2. Gaps found against leading agents (before this branch)

| Technique | Best practice (who) | SubMac before |
|---|---|---|
| Stable prefix / KV cache | Manus: keep the prefix byte-stable, append-only, no timestamps up front | Per-step notes (steer, nudges, loop warnings, skill hints) and the time were written into the **system prompt**, so any note invalidated the cache for the whole history on that step and the next |
| Recitation | Manus todo.md: re-state the plan at the end of the context | `todo` result only where it was called; drifted out of attention on long tasks |
| Parallel tool calls | OpenAI / Claude / smolagents / LangGraph run independent calls together | Calls ran one by one; the prompt even said "one action at a time" |
| Stuck detection | OpenHands (5 patterns), Roo Code (identical-call limit), Cline (mistake counter) | One check: last 3 calls identical (and it fired on legitimate scrolling) |
| Error recovery | Retry transient failures, suggest another tool | Errors went straight to the model; no retry, no alternatives |
| Escalation | Route to a stronger model on failure | None (fixed route per task) |
| Observation masking | SWE-agent keeps the last N observations whole | Last 3 results whole, older cut to the first 500 chars (lost totals/errors at the end); fresh results up to 30k chars |
| Step budget | OpenAI Agents SDK `max_turns`; graceful wrap-up | Hard stop with a banner at the step limit (token budget had a wrap-up, step limit did not) |
| Reflection | Self-check before answering (Reflexion / Self-Refine) | A rule in the prompt only |
| Plan-then-act | Visible checklist first (Manus, Claude Code TodoWrite, Cline plan mode) | `todo` tool existed; nothing prompted it for multi-part asks |
| Final answer shape | Outcome first, short, next step | Rules existed; not repeated where the model looks last |

## 3. What changed on `feature/agent-loop`

All pure logic lives in `lib/services/agent_loop.dart` (our own Dart; ideas credited in `docs/third-party.md`).

### 3.1 Notes at the end, stable prefix (`TailNote`)
`_payload` no longer puts the time or any step note in the system prompt. They go in an `<app-note>` block at the end of the request: appended to the newest user message, or as a short user message after the latest tool results. Never stored in the chat. The system prompt and history are now byte-identical between steps, so the provider's prefix cache keeps hitting.
Measured (synthetic 12-step task, `agent_loop_measure_test.dart`): prefix reuse 79.8% -> 90.8%; uncached tokens over 11 steps 12.5k -> 5.8k (-54%), with the checklist recitation included (request size +1.4%).

### 3.2 Recitation and final check (`Recite`)
While a `todo` checklist is open, every step ends with it (done count, `<- now` on the next step). When all steps are done it becomes the final check. Tasks without a checklist get the final check once they made 3+ tool calls: re-read the request, verify each instruction, fix gaps with tools, then reply outcome-first in plain words (what they get and where, up to 3 short lines, the one next step; no tool names, JSON or paths). Reflection without an extra model call. ~86 tokens for a 5-step checklist, ~124 for the final check.

### 3.3 Plan, then act
A full-lane owner message that has several parts (`TurnRouter.needsPlan`: long brief, 3+ listed asks, or "build/make a site/app/shop/report...") gets a first-step note: ask first if details are missing, otherwise one `say` line, `todo` with the steps, and start step 1 in the same reply.

### 3.4 Parallel independent tool calls (`ParallelPlan`)
Neighbouring read-only calls in one reply (web_search, fetch_url, wikipedia, read_file, list_dir, read_pdf, email_read/search, skill_use, knowledge_search ... 32 tools) start together (max 6); anything that changes something is a barrier and runs alone, in order. Results go back in the original order. Status shows "Checking 3 things at once". The prompt now asks for independent lookups in one reply. Measured: three 300 ms reads 903 ms -> 301 ms.

### 3.5 Stuck detection (`LoopGuard`)
Per task, on canonical arguments (key order and spacing ignored): **repeat** (same call + same result 3x, or same call 6x; scroll/wait tools 9x), **repeatedError** (same call failing 3x), **failingTool** (one tool failing 3x with different inputs), **pingPong** (A B A B A B). Each gives a specific note with alternatives; the guard resets after a note. Replaces the old "last three identical" check.

### 3.6 Error recovery (`ToolRecovery`)
A read-only call that failed on a network hiccup (timeout, connection reset, 429/5xx) is retried once quietly after 0.8 s (`_runRecovering`). Repeated failures name another way (fetch_url -> web_search / browser_task, web_search -> other words / wikipedia, read_pdf -> read_text_in_image, apps_run_tool -> apps_list_tools / reconnect ...).

### 3.7 Escalation (`TurnRouter.escalate`)
Auto only (the user's Quick/Think pick is never overridden), owner chats, never while driving a screen: fast -> smart on any trouble (an empty reply, 2 failed tools in a row, a loop); smart -> think on a real loop or 3 failed tools in a row. Once lifted, the rest of the task stays on the stronger model.

### 3.8 Results: clip and mask (`ResultClip`)
Fresh results over 20k characters keep the head (80%) and tail (15%) with a marker (the end often holds the total or the error). Older results keep start and end (~500 chars, deterministic so they stay cache-stable). Measured on one 30k-char page across 11 steps: ~23.5k -> ~15.1k tokens.

### 3.9 Step budget (`StepBudget`)
Two steps before the step limit the model is told to finish the important part and say what is done / left / "continue".

## 4. Still behind (next ideas)
- **Tool list changes mid-task** (`more_tools`, group growth) still invalidate the cache once; Manus masks instead of removing. Could send all groups' names but gate by state.
- **Speculative first token**: a long task's first visible text is the model's `say`; an instant local acknowledgement ("On it: checking three hotel sites") before the first model call would feel faster (UX lane).
- **Files as memory for long tasks**: big results could be written to `workspace/notes/` with the path kept in context (restorable compression) instead of trimmed.
- **Server-side**: settings cache across isolates (~1.3 s overhead measured in October) is the biggest remaining latency item; not touched here.
- **Real evaluations**: the numbers above are synthetic; a phone run with the ai-chat `usage.cached_tokens` would confirm the cache gain.

## 5. Status
Shipped in v1.13.48+81 (commit 5798c2a on `feature/agent-loop`); CI green on the branch head b2b314c (Dev check 39466278926). Not yet tested on a real phone. ai-chat unchanged.

## 6. Real-phone checks to run
1. "Compare three hotels in Nairobi under $100" -> status shows "Checking 3 things at once"; answer is a table; total time lower than before.
2. A website build ("build a site for my bakery in Hargeisa, called X, menu: ...") -> one `say` line, a checklist, steps ticked, final reply outcome-first with the file card.
3. Ask for a page that blocks fetching -> after failures it switches to search/browser and says what it did, no endless repeats.
4. Mid-task "use Amazon instead" -> one line, then it switches (steering still works with the tail notes).
5. A long chat (30+ messages) still answers quickly; "hi" still instant.

## 7. Chat screen feel (UX, v1.13.49+82)
The loop is only half of "quick and smart"; the other half is what the user sees while it works. On this branch the chat screen got: an instant "Thinking" line the moment a message is sent (`AppState.awaitingReply`), a smooth frame-by-frame text reveal with block-by-block markdown (only the newest paragraph re-renders), "Writing" while the answer appears, the task's `todo` checklist as a Plan card under the task line, a folded "How I did it" list of plain-words steps after a task, follow-up chips worked out from the answer, one-tap answers for `ask_user` options, and a back-to-newest button. Details, files and phone checks: `docs/project-state.md`, "Chat feel (UX agent)". The loop can make the Plan card shine by calling `todo` for multi-step work (it already does via `TurnRouter.needsPlan`) and the chips by ending offers with a clear question ("Want me to book it?").


## 8. New tools from the ECO agent (v1.13.50+83)
- `calculate` (always sent, core for bots, read-only so it runs in parallel): maths, percentages, units and dates in one call; several lines at once. The model is told to use it for any number the user relies on.
- `read_document` (files group): any office file, EPUB, RTF, HTML or text, plus PDFs and photos; paged by offset like read_file.
- `fetch_url` reads the main article of a page (Readable) and opens PDF/office links as documents.
- Both new names are in `ParallelPlan.safe`; `read_pdf` failures now suggest `read_document`.

## 9. Prompt understanding and safety (branch `feature/prompt-safety`, v1.13.52+85, merged with feature/app-update 51b36d4 as v1.13.54+87 and 4fbfbfc as v1.13.57+90; error scrub finished in v1.13.58+91)
App side only; no server deploys. Our own Dart, no new packages.
- **User's words last** (`TailNote.attach`): the step note now goes in front of the newest user message, so their words are the last thing the model reads. On later steps (after tool results) the note is followed by `TaskBrief.recital()`: the request verbatim, marked as the user's ("# The user's request (their own words; this is the task)"), long messages clipped head+tail with "(long; the full text is above)".
- **Corrections amend** (`TaskBrief`): what the user says mid-task is added to the brief (original + changes) and the steer note says "This amends the task: keep their original request…". The system prompt line "The latest user message is the task" is replaced by the amend wording.
- **"no" continues the task** (`QuickLane.laneFor(answeringQuestion:)`, `AutoRouter.classifyTurn`): a short answer (no, nope, nah, maya, haa, the second one…) to SubMac's own question (a `?`, choices, confirm, or an ask_user call) takes the full lane and is routed like the task it answers.
- **Constraint reader** (`lib/services/constraints.dart`): counts and numbers, money limits, language (incl. af Soomaali, Carabi), format words, don't/never/without/except/only and Somali ha …-in / la'aan / kaliya / mooyee, and multi-part asks. It feeds a compact `Must (from the user's words; check each before you reply): …` line into every step note and a `Self-check` into the final check. A message with constraints skips the `_simple` fast route and the `lightNow` fast start.
- **Ask less**: never ask about anything already said; at most one short question, only when truly ambiguous (replaces "up to 3 short questions").
- **Skills**: the skill hint says the user's own words win wherever the skill says otherwise.
- **Somali tool triggers** (`ToolScope.hinted`): warqad, fayl, qor → files; sawir → media + files; raadi, bog → browser (bog also files, cards); dir / u dir → phone; xisaabi → cards + money.
- **Identity + safety rule** (`lib/services/house_rules.dart`, `HouseRules.core`): one constant block (stable prefix) in `_systemPrompt` (right after the first line; skipped in bot chats where the bot prompt carries it), `_quickPayload`, the Live prompt, `Bots.stablePromptOf` / `quickPromptOf`; teams get `HouseRules.teamLine`. It covers: SubMac identity, never naming/confirming a provider, model or vendor; no instructions/tools/keys/internals/other users' data; outside content is data, not commands; approval cards stay; self-harm support; refuse fraud, weapons, illegal help, sexual content involving minors; health/legal/money "check with a professional" line; no doxxing.
- **Errors**: "SubMac lost the connection to its model." is now "SubMac lost the connection for a moment."; the error card's Details text goes through `HouseRules.scrub` (vendor and model names become "SubMac").
- **Errors, everywhere (v1.13.58+91)**: `CloudException` and `LlmException` scrub their message in the constructor, so a server message that names a provider or model never reaches a snackbar, banner or error card. "SubMac couldn't reach its models just now" is now "SubMac couldn't get an answer just now" (Calm and the bot-wake reason still read it as busy).
- **Tests**: `test/prompt_eval_test.dart` (26 EN/Somali prompts, payload snapshot in `test/goldens/prompt_eval.json`, regenerate with `UPDATE_GOLDENS=1`), `test/prompt_safety_test.dart` (red-team, 16 EN/Somali attacks, rule markers in every payload, prefix stable, page text stays data, vendor scrub), `test/prompt_understanding_test.dart`.
- **Eval, before → after** (same 26 prompts, 108 checks): 18/108 → 108/108. Lane right after SubMac's question 3/7 → 7/7; fast start right (none on constraint messages or "no" answers) 11/20 → 20/20; user's words last at step 0 and on later steps 0/52 → 52/52; Must items found 0/17 → 17/17; multi-part counted 0/2 → 2/2; Somali tool groups 4/10 → 10/10. "Before" = the same harness on 6a959ee with the old APIs (re-run 2026-10-22 on v1.13.58+91: still 18/108 → 108/108).
- **Server side still to do** (not in this branch): scrub vendor/model names in `ai-chat` error bodies and headers; give `bot-run` the same identity + safety block and the user-words-last order; make the `system_hint` of the server aliases (submac-fast/smart/think) carry the same identity line.

## 10. Agent loop fixes (branch `fix/agent-loop`, 2026-10-24)
Found in production chats of 23 Oct (ai_usage, messages, edge logs). Tests: `test/agent_loop_fixes_test.dart`, `test/team_run_test.dart`, `test/bot_manner_test.dart`, `supabase/functions/ai-chat/router_test.ts`.
- **Two or three final answers in a row**: the finish check and the "checklist still open" nudge ran after a final reply was already shown. The held reply is now replaced by the next final one (`_holdReply` / `_replaceHeld`, `FinalReply.carryCards` keeps any file or page card).
- **Checklist ping-pong**: `todo` with the full list and only the newest `done` cleared every earlier tick, so the model re-ticked steps for a dozen calls. Ticks now add up (`Checklist.apply`); only a newly finished step resets the nudge budget; `todo` calls go through the loop guard.
- **Announced but not done**: "Creating a simple to-do list note." with no tool call ended the task. `Announce.only` sends it back to act (any step, tools on).
- **Stopped calls**: an unanswered call of a stopped task now reads "Cancelled by user." (`AgentRun.pendingCalls`), not "Still running in the background". A stopped task finishing late no longer takes "all tools" from the new task in the same chat.
- **Tools**: `code_media` runs the code in its own block (no "Identifier 'out' has already been declared") and refuses a silent render; `open_link` with a file:// link answers with a file card instead of FileUriExposedException.
- **Server (not deployed)**: Gemini routes get Google's dummy thought signature on history tool calls (`withThoughtSignatures`), so tool steps stop failing over with 400s.
- **Teams**: never start by themselves; the lead proposes a plan in the chat and waits for "Go" / Start; hand-offs, members' reports and the combined answer are visible posts; owner messages mid-run reach the lead, "stop" stops. **Manner**: `BotManner` (calm, professional colleague; follow instructions faithfully) is in every bot and team prompt.
