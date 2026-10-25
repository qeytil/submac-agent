# SubMac chat and output bug hunt: main a891a83 (build-62, v1.13.102+172)

**Scope:** chat flow, outputs and rendering, and provider responses through ai-chat v41. This was investigation only. Nothing was merged, nothing was pushed to main, and no server, billing or Supabase config was changed.

**Code checked:** I cloned main into `/workspace/work/chatbugs/repo` (branch `chat-bughunt`). Its tree is `02f28329…`, the same as GitHub main a891a83.

**Probe tests:** `test/zz_chat_bughunt_test.dart`, pushed to the `chat-bughunt` branch, no PR.
- Each probe asserts the **correct** behaviour, so it is **red on main** and turns green when its bug is fixed.
- Result on main: **12 red, 1 green.** The green one is a stream-parsing check I confirmed is OK.
- Log: `/workspace/work/chatbugs/run4.log`.
- Run with `flutter test test/zz_chat_bughunt_test.dart`.

**Live calls:** I used a throwaway account (`chatbugs-probe-…@example.com`, uid 3ad9e69b…) against production ai-chat v41.
- 8 streamed calls: plain, Somali/Arabic, tool calls, and attempts to make the model invent a tool name.
- The account was then deleted from `auth.users`, and I verified the count is 0. Its few usage/ledger rows remain, the same as last time.
- Scripts: `/workspace/work/chatbugs/live.py`, `par.py`, `hallu.py`.

**Observation, not a bug:** live chat is served by **Ollama `gpt-oss:120b`**, not Gemini.
- `ai_router_state.current_route_id` = 70a8ad0d (Ollama). It has been since 2026-10-23 15:09 UTC, after 12 swaps, the last one for `fb_timeout`.
- That route has no vision, so photo turns go to the Gemini routes.
- gpt-oss streams its thinking in a separate `reasoning` field. It does not leak into replies.

## Count by severity
| Severity | Count | Bugs |
|---|---|---|
| Critical | 0 | none |
| High | 2 | CB-1, CB-3 |
| Medium | 6 | CB-2, CB-5, CB-7, CB-8, CB-9, CB-10 |
| Low | 5 | CB-6, CB-11 (2 parts), CB-12, CB-13 |

---

## High

### CB-1. A message sent while the final answer is streaming is never answered
**What the user sees:**
- The user types while SubMac is writing its answer, for example "actually make it for 4 people". Their message appears in the chat, the answer finishes, and the task ends.
- Nothing ever answers the new message, and the typing line is gone.
- If the message lands in the second or two after the answer arrived, while the finish checks are still running, it is worse. A quick side reply says "Okay, switching…", but the task has already ended and never acts on it.

**Cause:**
- `lib/state/chat_controller.dart:393-411` puts the message only in `task.inbox`.
- If the model is in a call (`task.inModel`), it calls `cancelForSteer()`. But `lib/services/llm_client.dart:87` ignores that once any word or tool call has streamed (`_gotData`).
- The inbox is read in only one place: `buildTurn` in `lib/state/agent_runner.dart:523`.
- A final answer with no tool calls never builds another turn. `_runAgent`'s `finally` block (agent_runner.dart:185-227) never checks `run.inbox`.
- The same applies to `steerTask` (the floating bubble, chat_controller.dart:246-252) and to bot chats (bots_controller.dart:1083).

**Evidence:** code path, high confidence. A widget-level probe needs a signed-in repo, so there is no automated probe.

**Fix:** in `_runAgent`'s `finally`, if `!run.cancelled && run.inbox.isNotEmpty`, start a new `_runAgent(convId)`. That message is already in the list, so the new run reads it. Alternatively, have a finish gate send the reply back with the inbox as a note when the inbox is not empty, so the same run hears it.

### CB-3. A tool name the app doesn't have ends the whole task with a raw error
**What the user sees:** the task stops with an error card. Its details read `GenkitException: Tool web_search<|channel|>commentary not found (Status: NOT_FOUND, Code: 5)`. Before that, the app silently re-sends the same step twice.

**Cause:**
- `lib/agent/core.dart:588` registers only the catalog's tools.
- Genkit fails the whole `generate` when the model names any other tool, before the middleware's `tool()` wrapper runs. Examples: a hallucinated name, a namespaced name (`functions.x`, `default_api.x`), gpt-oss's `name<|channel|>commentary` or built-in `browser.search`/`python`, or a tool from an MCP server that has been removed.
- `onError` (agent_runner.dart:647-657) treats it as a dropped line and retries the identical step twice. Then `failWith` shows the exception.
- Text tool calls parsed by `TextToolCalls` can carry any name, so they hit the same path.

**Evidence:**
- Probe **CB-3** is red. On main it gives `RunEnd.failed` with `GenkitException … NOT_FOUND` instead of returning an error result to the model and going on.
- Live: in 3 tries, gpt-oss used the right names, so I did not reproduce a bad name live. The crash path itself is proven.

**Fix:**
- Clean names in `TurnMiddleware`: strip `<|…|>` suffixes and `functions.`/`default_api.` prefixes.
- Map any name still unknown to a catch-all, or rewrite the call to a stub tool that returns: "Error: there is no tool named X. Use one of the tools you were given."
- Never treat `NOT_FOUND` as a dropped line.

---

## Medium

### CB-2. Stop erases the words already on screen
**What the user sees:**
- The user taps Stop while a long answer is streaming, for example halfway through a list of flights.
- The whole half-written reply disappears. It is never saved.

**Cause:**
- `AgentCore._send` (core.dart:581-582) races the transport against stop and returns `LlmResult('', [], 'cancelled')`.
- `CommitMiddleware` still calls `hooks.commit` with that empty reply.
- `_MainHooks.commit` (agent_runner.dart:699-723) sets `asst.content = r.text` (now `''`). Because the reply is empty and the run is cancelled, it then does `list.remove(asst)`.

**Evidence:** probe **CB-2** is red. The reply committed after Stop is `''` even though text had streamed.

**Fix:**
- In `commit`, when `r.finish == 'cancelled'`, keep `asst.content` as it streamed.
- Save it (marked stopped) and drop it only if it is really empty.
- An alternative is to have `_send` return the partial text the transport saw.

### CB-5. An answered choice card comes back to life when the same options are offered again
**What the user sees:**
- SubMac asks "Book the flight?" with [Yes, book it] [Not now]. The user taps Yes.
- Later SubMac asks "Also book the hotel?" with the same two options.
- The first card loses its tick and becomes tappable again. Tapping it sends "Yes, book it" to the new question.

**Cause:** `ChoicesCard.statusIn` (lib/widgets/output_cards.dart:711-725) does not know which message the card belongs to. It finds the newest message with the same options and gives every identical card that message's status.

**Evidence:** probe **CB-5** is red. It returns `(true, null)` for the answered card.

**Fix:** pass the owning message id into `ChoicesCard` (`buildOutputCard` → `ReplyView` already has `message.id`). Then compute the status from that message onward.

### CB-7. A card with broken JSON disappears without a trace
**What the user sees:**
- A table, plan or links card the model wrote with a JSON slip (here, a missing `]}`) shows nothing.
- The user sees the lead-in line ("Your budget:") and then empty space. The numbers are gone.

**Cause:**
- `lib/widgets/reply_blocks.dart:251-252` draws `SizedBox.shrink()` for any card language whose `buildOutputCard` returns null.
- The format gate gives one fix round per *run* (`formatFixes >= 1`, agent_runner.dart:987). So a second slip in the same task, or a reply that skips the gate (cut off, or the run was capped), is never repaired. History keeps the broken card forever.

**Evidence:** probe **CB-7** is red. No widget contains "Rent".

**Fix:**
- Fall back to readable content instead of hiding it, using a tolerant JSON parse (trailing commas, missing closers).
- If that still fails, show the cells or lines as plain text, or the raw body in a quiet code block.
- Also: `output_cards.dart:281`'s comment says "show as plain code until it's complete", but that is not what happens.

### CB-8. Copy, Share and Read aloud drop whole cards
**What the user sees:** the user copies or shares an answer that has a packing list, a links card, a plan, sections, a chart or a maths card. They get only the lead-in sentences. Here, the copy holds just the two intro lines, with no "Passport" and no link.

**Cause:** `_plain` in `lib/widgets/message_view.dart:609-617` replaces every card language except summary, draft, template and table with `''`. That includes `list`, `links`, `plan`, `sections`, `math`, `timeline`, `roadmap`, `chart`, `graph`, `choices`, `file` and `images`. The same text feeds Copy, Share and Read aloud (message_view.dart:472-485).

**Evidence:** probe **CB-8** is red. The clipboard got `"Your packing list:\n\nUseful links:"`.

**Fix:** give `_plain` a text form per card:
- list, plan and sections: one item per line.
- links: "title — url".
- math: the TeX.
- file and page: the file name.
- choices: dropped is fine.

### CB-9. One text direction for a whole reply block (Somali and Arabic)
**What the user sees:**
- A Somali reply that opens with "السلام عليكم!" is laid out right to left. The Latin text is right-aligned, and list numbers and punctuation sit on the wrong side.
- An Arabic reply that opens with a brand ("iPhone 16 هو …") is laid out left to right.
- A mixed reply (Somali paragraph, then an Arabic paragraph) gets the first paragraph's direction. My live Somali+Arabic answer showed this.

**Cause:**
- `textDirOf` (lib/widgets/message_view.dart:648-654) picks the direction from the *first* strong character of the whole text block.
- `MessageText` (lib/widgets/chat/blocks.dart:66) wraps the whole markdown block in that one `Directionality`.

**Evidence:** probe **CB-9** is red in both directions.

**Fix:** set the direction per paragraph or block. Use the majority of strong characters in each paragraph, ignoring a leading greeting or a Latin name. Do this inside `StreamingMarkdown` chunks, which already split per paragraph.

### CB-10. An answer cut off mid-way continues in a second bubble with broken formatting
**What the user sees:**
- A long answer stops mid-sentence or mid-table. A second bubble carries on.
- Table rows in the second bubble show as raw `| Tue | Old town |` text.
- Copy and Try again only act on the second half.

**Cause:**
- The cut-off finish gate (agent_runner.dart:942-957) sets `_keep`. `discard` (681-686) keeps the cut text as its own saved message, and the next model call starts a **new** message.
- `ReplySchema.repair` runs on each half separately and is skipped on the cut half (730). The continuation's headerless rows match neither `repair` nor `problems`.
- This happens more often than real length limits. ai-chat v41 sends a synthetic `finish_reason:"length"` (`cutTail`) whenever the upstream stream breaks or runs past `replyTotalMs` (v41.js `pump()` catch block). So an upstream hiccup looks exactly like this.

**Evidence:** probe **CB-10** is red (not repaired, not flagged), plus the code path above.

**Fix:**
- Append the continuation to the kept message: commit into the same `ChatMessage` and save once.
- Run `repair` on the joined text.
- Consider having the server report a real network cut as an error, not as `length`.

---

## Low

### CB-6. An unusual code-fence language swallows the rest of the reply
**What the user sees:** after a code block fenced as ` ```c# ` (also `f#`, `shell script`, `html title=x` and similar), every later card shows as raw code text, and `---` bubble splits stop working.

**Cause:** `_open` (lib/widgets/reply_blocks.dart:24) accepts only `[A-Za-z0-9_+-]*` as the fence language. So the opening fence isn't tracked, and its closing ` ``` ` is read as a new opening fence (line 85).

**Evidence:** probe **CB-6** is red. There is no table block.

**Fix:** accept any info string. Treat a line as a fence opener when it starts with ```` ``` ```` and has no further backticks, and take the first word as the language.

### CB-11a. A tap answer with a thousands comma splits in two
**What the user sees:** options written as one string get split on commas. "Under $1,000" becomes two buttons: "Under $1" and "000".

**Cause:** `lib/services/choices.dart:64`.

**Evidence:** probe red.

**Fix:** don't split on a comma that has digits on both sides. Prefer newlines, `|` or `;` when present.

### CB-11b. Local table repair cuts cells at a `|` inside code
**What the user sees:** a table whose cell holds `` `a \| b` `` loses its last column, and the data is silently truncated.

**Cause:**
- `ReplySchema._tablesToCards` (lib/agent/reply_schema.dart:288) splits on every `|`, ignoring backticks and `\|`.
- Line 297 then drops the extra cells with `take(cols.length)`.

**Evidence:** probe red.

**Fix:** split on unescaped pipes outside backticks, and keep any extra cells joined into the last cell rather than dropping them.

### CB-12. Reduced motion: replies trip a layout assertion when they change size
**What the user sees:**
- With Android's Remove animations on, a reply that grows or shrinks throws `RenderAnimatedSize was mutated in its own performLayout` in debug builds.
- In release builds this is extra relayout work, with no visible crash expected.

**Cause:** `AnimatedSize(duration: SubMotion.of(...))` becomes zero-length under reduced motion. That breaks the repo's own rule ("never a zero-length AnimatedSize, use `SubSize`"). Places:
- reply_blocks.dart:211 and :258
- chat/long_text.dart:88
- output_cards.dart:324
- home_screen.dart:1094

**Evidence:** probe **CB-12** is red, with the exception captured.

**Fix:** use `SubSize` in those places, and add `AnimatedSize(duration: SubMotion.of` to `motion_guard_test`.

### CB-13. Edit and resend drops the reply quote, and does nothing while a task runs
**What the user sees:**
- Editing a message that was a swipe-reply sends it without the quote, so the model no longer knows which message it referred to.
- Editing while any task or side reply runs in the chat closes the dialog and silently does nothing.

**Cause:**
- `_edit` pre-fills `ReplyCodec.bodyOf` (message_view.dart:177).
- `editAndResend` builds the new message from `newText` only (chat_controller.dart:500).
- The early `return` at chat_controller.dart:490 shows no feedback.

**Evidence:** code reading, high confidence.

**Fix:** re-encode with the original `ReplyRef` when the old content had one. When busy, either disable Edit or stop the run first and say so.

---

## Confirmed OK
- **Stream parsing:** UTF-8 characters and JSON lines split across network chunks arrive whole (probe green, `utf8.decoder` + `LineSplitter`).
  - Live v41 streams were all clean: `: ping` heartbeats, `content:""` alongside `reasoning`, tool calls with real ids and `index`, `finish_reason:"tool_calls"`, then a usage chunk with empty `choices` (skipped), then `[DONE]`.
- **Thinking text:** gpt-oss's `reasoning` field is never shown. `<think>…</think>` in content is stripped for display and Copy.
- **Weighted billing headers:** after the v41 switch they are consistent on every reply. `x-submac-today-left` went 200000 → 199909 after a small streamed call, matching `x-submac-balance`, plan and usage. The client reads them (`UsageSummary.headerValues`).
- **Error mapping:** ai-chat errors put the old code in `error.code` (`too_long`, `daily_limit`, `busy`, `paused`, `blocked`).
  - `Cloud.errorFrom` and `LlmException` classify these correctly. Limits and `payments_pending` are final, with no retry. `too_long` compacts and retries quietly. `busy`/`slow_down` (429) get one quiet retry before output.
  - Billing refusals reach the `BillingNoticeCard`, because the notice key is the same message text.
- **Tool results with a message in between:** results are rebuilt right after their call even when the user chatted mid-task (agent_prompt.dart:486-558). So ai-chat's `cleanHistory` never swaps a real result for "Not run."
- **Steering before any output:** this restarts the step and hears the new message. Each model call gets a fresh `LlmClient`, so cancel and steer flags never leak between steps.
- **Mid-stream drops:** the partial reply is dropped and the step re-sent at most twice. Final codes are not retried.
- **Inline maths:** money stays money (`$5-$10`, `$5 to $10`). Display maths and `\( \)` render.
- **Approval, side-reply ordering, regenerate:** these paths behave as documented. The approval paths were covered by PR #51 and the earlier bug hunt.

## Suggested fix order
1. **CB-1** (lost messages) and **CB-3** (task dies on an unknown tool name). Both are small, contained changes in the runner and core.
2. **CB-2** (Stop erases the answer) and **CB-10** (one bubble per answer, with repair on the joined text).
3. **CB-7** (broken cards visible) and **CB-8** (Copy/Share keep card text). Both are rendering-only.
4. **CB-9** (per-paragraph direction), which matters for Somali and Arabic users.
5. **CB-5**, then the Low items: CB-6, CB-11, CB-12, CB-13.

## Files
- Report: `/workspace/work/chatbugs/report.md`. The same text is in the branch as `docs/chat-bughunt-102.md`.
- Probes: `test/zz_chat_bughunt_test.dart` on branch `chat-bughunt`, local clone `/workspace/work/chatbugs/repo`.
- Test log: `/workspace/work/chatbugs/run4.log`.
- Live scripts and raw SSE: `/workspace/work/chatbugs/live.py`, `par.py`, `hallu.py`, `live_*.sse`, `par_*.sse`. The test-account token file has been deleted.
