# Telesia: timing, streaming and stress audit

Read-only review of the working copy in `/workspace/work/repo`, 23 October 2026. Nothing was changed and no live service was called. Timings come from three places, and each number says which:
- **measured**: numbers the team already recorded in `docs/project-state.md` and `docs/model-routes-2026-10-21.md`. These are real traffic and test-box runs.
- **from code**: limits and timeouts written in the code.
- **estimate**: my own estimate for a mid-range Android phone on 4G in Somalia, where the round trip to Frankfurt is about 150–250 ms. Check these on a real phone before relying on them.

This builds on `audit/agent.md` and `audit/backend.md` and does not repeat them. Where a point overlaps (for example, the app's wait being shorter than the server's), this report adds the full chain and the numbers.

---

## The short version

1. **The first word usually takes 1.5–3 s for a simple message and 3–6 s for a task** (estimate, built from measured parts). The server's own overhead is now small (about 0.3 s). Nearly all the time goes to two things: which model answers, and how much text the app sends on the first step.
2. **The worst case is very bad.** One step can wait up to about 4½ minutes before the user sees an error. The server keeps trying models for up to about 88 s, or about 105 s for Somali. The app waits 90 s for the reply to start, then retries the whole thing twice more.
3. **Hidden delays sit before the model is even called:**
   - Photos are uploaded to storage one after another before the model is asked anything.
   - The first message after opening the app can wait up to 12 s for connected-app tools to load.
   - Every photo in the chat is sent again, as text-encoded image data, with every step. A gallery photo is not shrunk first, so that can be several MB per step.
4. **The model swaps several times inside one task**, and each swap throws away the provider's prompt cache. The fast model takes the first step of short messages, the main model the next, the seeing model while browsing, Gemini for Somali, and the stronger model after trouble. One example: a Somali task goes to Gemini on step 1 and very likely to the open models on step 2. From step 2 the newest "user" message is the app's own English note, which the server's Somali check reads.
5. **Streaming is smoother than most apps of this kind.** It reveals the text frame by frame and only re-draws the paragraph that is still growing. Two risks remain on long replies, mostly on cheap phones:
   - every token batch (25 times a second) rebuilds the whole chat screen;
   - code blocks and tables are re-drawn as they grow.
6. **Under stress the system amplifies its own load.**
   - The server answers a provider "too many requests" with a generic "busy" error. The app treats that as a reason to retry quickly, twice, and each retry starts a full new chain of up to about 50 model attempts.
   - The server keeps working after the phone has hung up.
   - One "slow down" on a background bot pauses every chat on the phone.
7. **The single sticky "Telesia model" plan fits this code well.** It removes about a dozen moving parts and most of the cache churn. Health tracking, key rotation, capability checks and failover must stay. The new budget should be:
   - server: 25 s to start a reply (with a heartbeat every 10 s);
   - app: 10 s to see the reply start once the server sends that heartbeat (30 s until it does), and 30 s of silence before treating the connection as dead;
   - at most one automatic retry.

**Targets I recommend:**

| What | Target |
|---|---|
| First visible word for small talk | p50 ≤ 1.5 s |
| First line of a task | p50 ≤ 2.5 s |
| All first words | p90 ≤ 5 s |
| Hard ceiling before a clear "busy, tap to retry" | 45 s |
| Server work after the phone gave up | never |

---

## 1. Time to first word

### 1.1 Every step between pressing Send and the first word

| # | Step | What happens | Typical cost | Worst case | Where |
|---|---|---|---|---|---|
| 1 | Tap Send | Message added to the list, haptic tap, screen redraw | ~16–50 ms | – | `AppState.send` |
| 2 | Save locally | New chat created locally, message saved locally (local-first, no network) | 5–50 ms | – | `repo.createConversation`, `insertMessage` |
| 3 | **Attachments** | Each file uploaded to Supabase storage **one after another, before the model is called, with no time limit** | 0 (none); 1–4 s for a 2048-px camera photo on 4G | 20 s+ for a gallery photo (not compressed) on 3G; can hang | `send` → `repo.uploadAttachment` |
| 4 | Title | First message of a chat starts a separate title request to the fast model (not awaited) | 0 on the critical path, but it competes for the same keys and the per-minute limit | – | `_generateTitle` |
| 5 | **Connected-app tools** | If an enabled app (MCP server) has no tools loaded yet, the first task waits for them | 0 normally | **up to 12 s** on the first send after app start | `ensureMcpTools` |
| 6 | Lane, routing, notes | Regex checks: lane, job type, tool groups, skills, frustration, constraints | < 5 ms | – | `_runAgent` |
| 7 | Build the prompt | System prompt (~3.2k tokens with all groups) + history + tools (~3.9k tokens plain, ~9.8k all) + end notes. **Every image in the history is base64-encoded again** | 10–40 ms (estimate) | 100–500 ms with photos in the chat | `_payload`, `_userContent` |
| 8 | Size checks | The tool list is turned into JSON 3 times just to count its size (compaction check twice, rate limiter once) | 3–15 ms | – | `RateLimiter.estimateTokens` |
| 9 | Inline compaction | If the request is over 36k estimated tokens, the older chat is summarised **before** this step, as a blocking, non-streamed call | 0 normally | 5–60 s (60 s app timeout) | `_autoCompact` in the step loop |
| 10 | Client pacing | Waits out any cooldown from an earlier 429 (shared across every chat and bot on the phone) | 0 normally | 10–90 s | `RateLimiter.acquire` |
| 11 | Session token | Refreshes the login if it expires within 90 s, **no time limit** | 0 normally | 0.3–1.5 s; can hang | `Cloud.token` |
| 12 | Encode and upload the request | The request body is about 25–60 KB of JSON, sent uncompressed. With photos, MBs | 0.1–0.5 s on 4G | several seconds per photo per step | `LlmClient.streamChat` |
| 13 | Connect | A shared HTTP client reuses the connection. A new TLS connection to Frankfurt costs about 2–3 round trips | 0 (warm); 0.4–0.8 s (cold) | – | `LlmClient._shared` |
| 14 | Gateway and isolate | Supabase checks the login, starts a fresh function isolate (measured: almost every request gets a fresh one) | ~50–200 ms (estimate) | – | Supabase |
| 15 | Gate check | One database call: blocked, burst, today's usage, cap, config on a cold isolate | **measured 114–150 ms** | 503 with raw text if the DB blips (see backend.md) | `gate` / `ai_gate` |
| 16 | Plan + keys | Alias, Somali check, fit check, the chosen provider's keys (cached 2 min per isolate, so usually fetched again) | ~20–100 ms | – | `makePlan`, `ensureKeys` |
| 17 | **Model first token** | Prompt read by the model, then the first real output (text, reasoning or tool call) | **measured:** fast p50 0.7 s / p90 1.3 s; Ollama 120b p50 0.5 s; NVIDIA p50 1.5 s / p90 5 s; Gemini p50 4.4 s / p90 11.4 s | each failed route adds up to 12–13 s (30 s for Somali routes) | `upstream`, first-output loop |
| 18 | Reasoning before words | Thinking models (gpt-oss is one) stream hidden reasoning first. The server counts that as "started", and the phone shows "Thinking it through" but no words | +0.5–5 s (estimate) | – | `onReasoning` |
| 19 | Back to the phone, first frame | Half a round trip, a 40 ms redraw throttle, one frame | ~0.1–0.2 s | – | `_throttledNotify`, `ReplyView` |

Measured end to end from a US test box (no phone, same routes): **first token 0.82 s on smart and 0.99 s on fast** (medians of 5, `project-state.md`). From Somalia, add roughly 0.3–0.6 s of network, the phone-side work above, and real prompt sizes.

### 1.2 What this adds up to (estimate, Somalia, 4G, warm connection)

| Situation | First visible word |
|---|---|
| "Salaan" / "hi" (quick lane: tiny prompt, no tools, fast model) | **1.0–1.8 s** |
| Short question (light lane: core tools, fast model on step 1) | 1.5–3 s, plus 2–5 s more if the model then has to call `more_tools` and start again |
| A task (full prompt ~7–13k tokens, main model) | 2.5–6 s to the first "Checking…" line |
| First message after opening the app with a connected app | add up to 12 s |
| A message with one gallery photo | add 2–20 s (upload), then the photo goes again with every later step |
| One provider down | add 12–13 s per dead route tried (30 s for Somali routes) |
| Main providers down | up to about 88 s (105 s Somali), then app retries: up to about 4½ min before an error |

### 1.3 What slows the first word most, and the fix for each

1. **The model and its route.** This is 60–90% of the wait. Ollama gpt-oss:120b answers in about 0.5 s and NVIDIA in 1.5 s (p50). Gemini takes 4.4 s and the Somali routes may wait up to 30 s each.
   - **Fix:** the sticky router (section 5). Keep the fastest healthy route as the standing choice; never try a known-slow route first.
2. **Hidden reasoning.** The app sends no reasoning setting. `QuickLane.effortFor` is never sent (the `effort` parameter is accepted by `streamChat` and ignored), and the quick lane's 400-token cap is never sent either. So a greeting can wait on a medium-length chain of thought.
   - **Fix:** let the app send a hint header such as `x-telesia-effort: low|normal|high`, and let the server map it to the chosen model's setting. Send `low` for quick and light lanes and for step 1 of a task. A hint is not a model name, so it fits the single-model plan.
3. **Attachments upload before the model call.**
   - **Fix:** start the model call at once (the image is already in the request), and upload to storage in parallel or afterwards. Compress gallery images to the same 2048 px / quality 85 used for the camera.
4. **Images re-sent every step.**
   - **Fix:** send an image whole only on the step that first sees it, plus at most the latest one. After that, replace it with a one-line note ("[photo the user sent: receipt, read earlier]"). Cache the base64 string instead of re-encoding.
5. **Waiting for connected-app tools.**
   - **Fix:** never block the first step on the tool list. Start without the missing app's tools, and add them from step 2 (the `more_tools` path already exists).
   - **Bug found:** `_mcpRefreshing` is never cleared. After the first refresh, the "refresh in background when stale" branch never runs again, and a newly added server is never loaded on send (`ensureMcpTools` awaits the old, finished future).
6. **Session refresh with no time limit.**
   - **Fix:** refresh proactively when the app resumes and every 50 minutes, and put a 5 s limit on the refresh in `Cloud.token`.
7. **Request size.** About 25–60 KB of JSON per step, uncompressed.
   - **Fix:** gzip the request body (`Content-Encoding: gzip`; Deno can decompress), which cuts upload by 70–80%. On 3G that saves 0.3–1 s per step.
8. **A 12 s first-byte timeout per route, applied in a row.** One dead route costs 12–13 s before the next is tried.
   - **Fix:** in the new design, use 6 s for the response to start and 10 s for the first real output. Only for the user-facing first step, optionally start the second route after 4 s of silence and keep whichever answers first (a "hedged" request; see 5.4).

**Instant acknowledgement.** `docs/agent-loop.md` already lists the "speculative first token" idea. The cheapest perceived-speed win is to show the working line at once (it already appears on tap). For tasks, the model's own first line (`say`) usually arrives with the first step. Keep the rule that a task starts with one short line, but make it the model's first output, before any tool calls, so it streams first.

---

## 2. Streaming smoothness

### 2.1 How tokens reach the screen
- `LlmClient.streamChat` reads the event stream line by line, decodes each JSON chunk and calls `onDelta`.
- `onDelta` appends to `asst.content`, a string that is copied on every append, and calls `_throttledNotify`, which redraws at most once per 40 ms (25 times a second).
- `ReplyView` reveals the text with a per-frame ticker (`nextRevealLength`: one sixth of the backlog each frame, at least 2 characters). Bursts therefore flow out smoothly and never fall behind what has arrived.
- `StreamingMarkdown` splits the reply into paragraphs and builds a new markdown widget only for paragraphs whose text changed. A growing paragraph longer than 1,200 characters is re-drawn at most every `length / 10` ms (capped at 300 ms).

This is good design. Most chat apps re-parse the whole reply on every token; this one does not.

### 2.2 How often the screen rebuilds
- **25 times a second while streaming,** every `context.watch<AppState>()` widget rebuilds:
  - the whole `HomeScreen` (app bar and scaffold);
  - the message list builder, which walks **every message in the chat** to rebuild its lookup map and visible list, find the current turn and the "worked for" steps;
  - the composer and the ask bar.

  31 widgets in the app watch the whole `AppState`. Only the visible ones rebuild, but they rebuild on every notify.
- **On top of that, 60 times a second,** the reply's own ticker runs `parseReply` and `splitMarkdownChunks` over the whole reply text. That is linear in the reply length; `isListItem` compiles a new regex for every line on every frame.
- **Other notify calls** come on every status change ("Trying again in 3s" ticks once a second), each tool start and end, and each `say`.

### 2.3 Jank risk on long replies (estimate)
| Reply | Risk |
|---|---|
| Normal answer, < 3,000 characters | Low on any phone |
| Long answer, 10–25k characters of prose | Medium on a low-end phone: the whole-screen rebuild (25/s) plus the per-frame parse of the full text (60/s) can take 4–10 ms of a 16 ms frame in a long chat |
| A long code block or table streaming | **High on a low-end phone.** A fenced block stays one paragraph. Each re-draw (up to every 300 ms) re-runs syntax highlighting or table layout of the whole block (`IntrinsicColumnWidth`), and the text is selectable. Expect visible stutter on a 200-line code block |
| Very long chat (500+ messages) | Medium: the list builder's walk over every message happens 25 times a second |

### 2.4 Fixes
1. **Stop rebuilding the whole screen for each token.**
   - Give the streaming message its own `ValueNotifier<String>` (or make `ChatMessage` a `ChangeNotifier`) and listen to it only inside `ReplyView`.
   - Call `notifyListeners()` on `AppState` only when the structure changes: a message added or removed, the run status, a step.
   - This cuts most of the rebuild work while streaming.
2. **Cache what is fixed.**
   - In `ReplyView`, re-parse only from the last complete block boundary.
   - In `_list`, keep the tool-result map and the visible list between rebuilds, and update them when a message is added.
3. **Code and tables while streaming.**
   - Show a fenced code block as plain monospaced text while it streams, and highlight it once it is complete. The fence closes, or the message finishes.
   - Same for tables: draw the card when the block is complete. Cards already do this, with a shimmer placeholder.
4. **Use a `StringBuffer` for `asst.content` while streaming.** It avoids copying the whole string on every append (O(n²) on long replies).
5. **Keep the 40 ms throttle** but drive it from the frame scheduler (`SchedulerBinding.scheduleFrameCallback`), so a notify never lands mid-frame.

---

## 3. Multi-step tasks

### 3.1 How long a step takes (estimate from measured parts)
One step = model start + writing the step + running the tools.

| Part | Typical | Notes |
|---|---|---|
| Model start (same model, prompt cache warm) | 0.5–2 s | measured p50s above. Prefix caching makes later steps cheaper only while the same model and key are kept |
| Model start after a model swap | +0.5–3 s | a cold prompt of 7–20k tokens on a new provider |
| Writing a tool call | 0.5–3 s | 50–300 tokens |
| Writing a document or code file | 20–90 s | 2–4k tokens at roughly 40–100 tokens a second; the app shows "Writing a file" early (`_earlyLabels`) |
| Web search / page read | 1–5 s each; up to 6 run together | `ParallelPlan.maxTogether = 6` |
| Browser step | 2–20 s | 120 s cap per step |
| Connected app call | 1–5 s | 40 s cap; MCP list 25 s |
| Extra steps the app adds at the end | +1 to +5 steps | finish check (builds), truth check (≤ 1), "you said you'd do more" (≤ 3), cut-off continues (≤ 6) |

A typical research task of 5–8 steps takes **20–60 s**. A build with 20–40 steps takes **5–20 minutes**.

### 3.2 How progress is shown
- **Working line** under the user's message (`WorkingLine` in `composer.dart`).
  - It shows the current status: "Thinking", the tool label, "Reading 3 pages", "Writing", "Trying again in 3s".
  - Elapsed time appears after 5 s.
  - The status changes to "Still thinking" after 8 s and "Taking a little longer than usual" after 25 s in the model.
  - Tapping it opens the step list with ticks and seconds per step.
- **Early labels:** the moment the model picks a tool, before its arguments finish streaming, the line shows its label. This hides most of the time spent writing large files.
- **Forced progress line:** after 6 tool steps without a `say`, the next step carries a note telling the model to call `say` with one short line. Cost: an extra tool call and a chat bubble every ~6 steps. The live line already shows progress, so this is mostly noise. agent.md recommends dropping it; I agree, and from a timing view it also adds ~0.5–1 s to every sixth step.
- **In the background:** the ongoing notification follows the status, at most every 4 s.
- **Checklist:** the `todo` steps, recited at the end of every step while open.

### 3.3 How the final answer arrives
- The final answer streams like any reply.
- Before it is accepted, the app may run up to three extra full steps:
  - the **truth check**: a claim like "sent" or "saved" with no tool result behind it costs one more step;
  - the **"open checklist" nudge**: up to 3 times;
  - for builds with 3+ checklist steps or 3+ file writes, a **finish check**, which is one more step and often several (tests, fixes).
- Each extra step re-sends the full prompt. The nudged answers are removed from the chat before the retry, so the user may see an answer appear and then vanish ("Checking the facts"). That reads as a glitch.
  - **Fix:** run the truth check on the streamed text before showing it as final. Keep it visually "in progress" (muted) until the check passes.
- When it ends, "Worked for 1m 12s · N steps" replaces the line, and a soft haptic tap fires.

### 3.4 Timeouts per step and in total (from code)
| Limit | Value |
|---|---|
| Reply to start (headers) | 90 s app (`streamChat` `.timeout(90s)`) |
| Silence inside a stream | 75 s app (`LlmClient.idleTimeout`), 90 s server (`stream_idle_ms`) |
| One reply, total | **none** in the app (a stream that keeps sending bytes can run forever); the platform's wall-clock limit on the server (see 4.9) |
| Retries per step | 3 tries on network/5xx (waits 2 s, 4 s); up to 6 on 429 (waits 15–90 s) |
| Steps per task | checkpoint every 50 (150 when browsing); continues while progress is made; ceiling 1,000 |
| Tokens per task | `taskBudgetK` if set, else stops when today's allowance is ≥ 90% used |
| Browser sub-agent | check-in every 30 min (10–90), 220 steps per segment, 120 s per browser action |
| Non-streamed calls (titles, summaries, bot checks) | 60 s app; **300 s server** |

**Gaps:**
- There is no total time limit per step.
- There is no time limit on waiting for the user (covered in agent.md).
- The server's reply budget is longer than the app's (section 5.5 fixes the ordering).

---

## 4. Stress behaviour

### 4.1 Provider 429 / 503
- **Server, for each key:**
  - A 429 rests that key for 60 s, a 5xx or timeout for 20 s, 401/403 for 1 h, 402 for 6 h.
  - The rest is saved in the database (`ai_mark_key`) and in the isolate's memory. Isolates are almost always fresh, so the in-memory copy rarely helps.
- **Server, for each request:**
  - It tries up to 3 keys of a route, then the next route.
  - Then the routes of the other aliases.
  - Then a second pass with one resting key each.
  - All of this runs within a 75 s budget, with up to `max(6, routes×2+2)` attempts, which is about 50 with the current route list.
- **What the app gets when everything is busy:**
  - The server returns `503 busy` when the last error was a 429, otherwise `502`.
  - It sends **no Retry-After header**.
  - The app treats any 5xx as "retry soon" (`isRetryable`) and tries twice more, after 2 s and 4 s.
  - **Result:** in a provider outage every user's step becomes 3 full server chains. That roughly triples the load on providers that are already struggling, and keeps their keys resting.
- **The app's own 429 handling** only triggers on the server's `slow_down` (40 requests per minute per user). It sets a cooldown on the provider id `telesia`, which is **shared by every chat, bot, office and browser job on the phone**. One busy bot pauses the user's own chat.

**Fixes:**
1. Server: on `busy`, send `Retry-After: 15–30` with random jitter, and a code (`busy`) the app treats as "retry once, after the given time".
2. App: at most **one** automatic retry for "busy" or 5xx before any output. Then show a calm "Telesia is busy. Tap to try again" with the message kept.
3. App: keep cooldowns per lane (foreground chat vs background work), not per provider.

### 4.2 Slow providers
- A provider that never answers costs 12–13 s per attempt (the abort fires at 12 s; there is a 13 s backstop), or 30 s on Somali routes.
- After a timeout the server moves to the next **route**, but it marks only the one key it tried. The route's other keys stay available to the next user. So while a provider is hanging, many users each pay 12 s, until the bench marks the route unhealthy, which happens hourly.
- After the reply starts, a provider that pauses mid-reply gets 90 s on the server but only 75 s in the app. The app cuts first and then re-sends the whole prompt to "continue". The server has meanwhile been charging for the output produced.
- **Fix:** route-level circuit breaker (5.4) and a matching idle budget (5.5).

### 4.3 Many concurrent users
- **Database:** every request makes 1 gate call. Every attempt then writes a usage row and **a key update even on success** (`markKey(…, true)`). There are only about 15–25 keys, so at high load every successful reply updates the same few rows. That causes row-lock contention and write load that grows with traffic.
  - **Fix:** write key state only when it changes (a failure, or the first success after a failure).
- **Provider capacity** is the real ceiling.
  - Ollama Cloud (4 keys) now leads smart, think, fast and lite. Dahl already showed `model_concurrency` 429s.
  - An agent step holds a stream open for 5–60 s, so in practice each active user holds one stream.
  - **Rule of thumb:** users served at once ≈ keys × concurrent streams allowed per key. With one sticky model, *all* traffic hits one provider. Measure per-key concurrency before launch and size the key pool to peak concurrent users. Pick keys by "fewest streams in flight" as well as the per-chat sticky hash.
- **Function isolates:** each request runs in a fresh isolate. That is fine for scale, but the in-memory caches (config 60 s, keys 2 min, cooldowns, `lastGateOk`, moderation de-dupe) almost never help. Anything that must be shared across requests has to live in the database or a KV store.
- **Moderation:** `screenLater` de-dupes per isolate only (20 s). From step 2 of a task the newest "user" message is the app's note that recites the user's request. A message that trips the keyword screen is therefore re-checked with an extra model call **on every step**.
  - **Fix:** de-dupe by user and text hash in the database, or screen only the user's real message once (the app could send `x-telesia-turn: new` on the first step of a turn).

### 4.4 Long chats (context growth and compaction)
- **Working window:** the app plans for 48k tokens for any `telesia-` model and compacts when a request passes ~36k estimated tokens (`ContextWindow.compactAt`).
- **After each reply:** if the chat history (after the last summary) is over ~14k tokens, it is folded in the background 2 s later, keeping the newest ~5k whole.
- **During a task:** the history can grow past 36k inside a single long task. Then a **blocking** summary call runs before the next step: up to 60 s in the app and up to 300 s on the server, non-streamed, with the line showing "Thinking". If the fast model is busy, the summary falls back to a plain digest.
- **When the server says "too long" (413):** the app compacts and retries once, then sends only the last 16 messages.
- The server already sends the real smallest window in `x-telesia-window`, but **the app never reads it**.
- **Fixes:**
  - Read `x-telesia-window` and size compaction from it.
  - Run in-task compaction ahead of time, in parallel with tool execution, so it never blocks a step.
  - Cap the summary at 45 s.

### 4.5 Large tool outputs
- A single result is clipped to 20,000 characters (about 5k tokens), keeping the head and the tail.
- Only the latest 3 results stay whole; older ones shrink to ~500 characters.
- **But a batch of 6 parallel page reads can add ~120,000 characters (~30k tokens) in one step.** That alone passes the 36k compaction line. It triggers a blocking compaction, or a 413, and is re-sent whole on the next 1–3 steps. That adds about +3–6 s of prompt reading per step (estimate).
- **Fix:** a total budget per batch, for example 24,000 characters shared across the batch, so each of 6 pages gets about 4,000. The model can read more of one page on request.

### 4.6 App backgrounded mid-stream
- When the app is hidden, `setAppVisible(false)` starts a foreground service (`TaskService`, type `dataSync`) to keep the task alive, and the notification follows the status.
- **Risks (verify on a phone):**
  - **Starting the service late.** The service is started *after* the app is already hidden. Android 12+ can refuse to start a foreground service from the background. If that happens, the task runs only until Android freezes the app, and the stream silently stops.
    - **Fix:** start the keep-alive service when a task starts (while the app is visible), not when it goes to the background.
  - **No wake lock.** The task service holds no wake lock (`WakeService` has one; `TaskService` does not). With the screen off, the CPU can sleep between packets and the stream can stall. The 75 s idle timeout then fires and the task "continues" with a full re-send.
    - **Fix:** hold a partial wake lock while a task is in a model call or a tool, with a 10-minute safety release.
  - **Time limits on the service type.** Android 15 limits `dataSync` services to about 6 hours a day. That is fine for chat, but long builds and bots should use `shortService` / `specialUse` or WorkManager.

### 4.7 Network switch (Wi-Fi ↔ mobile) and dropouts
- **Before the reply starts:** the app waits up to 90 s for headers on a dead socket. **During the reply:** up to 75 s of frozen text. Then the app "continues" by re-sending the whole prompt.
- The server keeps producing the old reply until it notices the hang-up, and charges for what was produced (499 path).
- **Fixes:**
  - Listen for network changes (`connectivity_plus`), abort the open request at once and continue.
  - With a server heartbeat every 10 s (5.5), cut the idle timeout to 30 s.

### 4.8 Duplicate sends
- Double-tapping Send is safe: the box is cleared on the first tap.
- **The gap:** a task is registered as running only when `_runAgent` starts. That happens *after* attachments upload (seconds) and local saves. A second message typed in that window does not steer the first task. It starts a **second, parallel agent on the same chat**. Both write into the same message list; the user gets two answers and pays twice.
- `regenerate` and `editAndResend` check `busy`, which is still false during that window.
- **Fix:** register a placeholder run, or a per-chat lock, at the top of `send`, before any await.

### 4.9 Retry storms and wasted work after hang-up
**The worst chain for one step today:**
1. The server tries routes for up to ~88 s, or ~105 s with a Somali route started near the 75 s deadline. The deadline is checked only *before* each attempt.
2. The app gives up at 90 s with "connection dropped", which counts as retryable.
3. The app retries twice more (waits 2 s and 4 s).
4. That makes up to **~4½ minutes** before the user sees an error, and up to 3 server chains running.
5. The server never watches for the phone hanging up (`req.signal`). An abandoned chain keeps calling providers.

**Fixes:**
- Server: stop all work when the request is aborted (`req.signal`), and enforce the deadline *inside* attempts (abort the in-flight attempt at the deadline).
- The budgets in 5.5.

**Platform limit to check:** Supabase Edge Functions have a wall-clock limit per request: 150 s on the Free plan, 400 s on paid plans. A long streamed reply, say a 6–8k-token document at ~40 tokens a second, can pass 150 s. The platform then kills the stream with no clean end. The app would see a drop and "continue". **Confirm the plan.** On Free, cap one reply's output so it finishes in about 120 s, or end it cleanly at 140 s with the existing "cut off, continue" signal.

### 4.10 Quota exhaustion
- **Daily limit:** returns `429 daily_limit`. The app treats it as final, shows it, and does not retry. Correct.
- **"Light" state (over the cap, in the grace zone):** the server switches to `telesia-lite` with 400-token replies, which changes the model mid-task.
- **Bots:** `background_paused` is final, and bots wait for the reset. Correct. The app's reset time (UTC) still differs from the billing reset (EAT), as backend.md says.
- **Long tasks:** before a long task runs dry, the app wraps up at 90% used (`allowanceLow`) with a "send continue" note. Good.
- **In the single-model plan:** the light state becomes "same model, shorter replies" (a `max_tokens` cap), not a different model.

---

## 5. The single "Telesia model" with a sticky router

### 5.1 What changes
Today one task can move between up to five model families: fast, smart, think, vision and Somali. Each move:
- loses the provider's prompt cache. A 7–13k-token prefix is read again, which is +0.5–3 s and full cost.
- loses the per-chat sticky key;
- re-learns tool-call formats (the Gemini thought-signature problem);
- changes reply quality and language mid-task.

**One model, kept until it fails, fixes all of that at once.** It also removes the Somali mid-task flip described in "The short version".

Two things to decide up front:
1. **The one model must do everything the old aliases did.** It must use tools, see images (screenshots and photos), have at least a 128k window, and write good Somali. If the standing model cannot see, every browsing step forces a swap, which breaks stickiness. Pick the primary *and* its fallbacks by these four checks.
2. **Fallback models will often write worse Somali** (see backend.md). When the router fails over, Somali quality may drop silently. Log "Somali chat served by fallback" on the dashboard.

### 5.2 Code to delete
**App (`lib/`):**
- `cloud.dart`:
  - delete `Cloud.smart/fast/think/vision`; use one name (e.g. `telesia`);
  - set `provider.models` to that one name.
- `app_state.dart`, routing and model choice:
  - `roleRef` (fast/vision roles; keep image/video only if those stay separate endpoints);
  - `_route`, `_browseHint`, `lastJob`, `lastRouted`, `autoMode`;
  - `_withThinking`, `thinking` / `setThinking`, `_quickRoute`, `_seeRef`;
  - `_botRoute` (always null), `_botAuto`, `_badModels`, `autoProblem`.
- `app_state.dart`, mid-task changes:
  - `canLift` / `lifted` / `liftIf` and both `TurnRouter.escalate` calls;
  - the `lightNow` fast-model start;
  - `_backupFor` and the `candidates` loop in `_streamResilient` (keep one try loop).
- `app_state.dart`, tool fallbacks (the server guarantees a tool-capable route):
  - `_noToolModels`, `_toolsRejected`;
  - `_liteModels`, `_liteTools`, `_liteNames`.
- `app_state.dart`, model checks:
  - `canSee(model)`: always true;
  - `_visionModel` checks;
  - the `roleRef('fast')` choices in titles, summaries, bot checks and Live recaps. Use the same model with a small `max_tokens`.
- `services/auto_router.dart`: the whole file. `mediaKind` is only needed if image or video models stay in the chat path; they have their own endpoints.
- `services/agent_loop.dart`:
  - `TurnRouter.fast/smart/think` and `escalate`;
  - keep `needsPlan` and move it into `Recite` or `TaskBrief`;
  - `LoopSignal.escalate` goes too: a loop now only adds the guidance note.
- `services/quick_lane.dart`:
  - delete `effortFor` (dead today) and `quickMaxTokens` (never sent);
  - **keep `laneFor`.** The quick and light lanes save prompt size and tools, which is most of their speed win, and they work the same on one model.
- `services/context_window.dart`: the whole model table. Use `x-telesia-window` from the server, with 48k as the default.
- `widgets/composer.dart`: the Auto/Quick/Think chip (`_ThinkingChip`) and `local_store` `thinking`.
  - If the owner wants to keep a "Think harder" option, keep it as an **effort hint** (`x-telesia-effort: high`), not a model.
- Tests that cover the removed routing (`TurnRouter`, `AutoRouter`, `_withThinking`).

**Server (`supabase/functions/ai-chat/index.ts` and the database):**
- Somali swap:
  - `SOMALI_ALIAS`, `SOMALI_SWAP`, `SO_WORDS`, `somaliVerdict`, `isSomaliChat`, `SOMALI_HINT`;
  - the Somali branches in `makePlan`, `somali_first_byte_timeout_ms` and `fbFor`;
  - the Somali early-call timeout in the spec start.
  - Language guidance stays in the app's prompt (`Somali.chatGuide`).
- Other aliases in `makePlan`:
  - the "light → grace alias" switch: keep it as a `max_tokens` cap on the same model;
  - forcing `telesia-vision` when images appear: replace with a "route must have vision" capability filter;
  - `thinkIn`;
  - the `spare` routes borrowed from other aliases (one list now).
- `classify()` alias lookup (moderation uses the same model with `max_tokens: 120`).
- `bot-run`: `telesia-fast` and `telesia-smart` become one name. Use a small `max_tokens` for the heartbeat check.
- The `ai_gate` alias parameter, and alias rows in `ai_aliases` (keep one).
- The admin dashboard's per-alias editing.
- The `docs/model-routes-*` revert SQL.

### 5.3 What must stay
- **Key rotation with per-chat sticky keys** (`keysInOrder` hash). This is what makes the provider's prompt cache work.
- **Key rests by error type** (`cooldownFor`): 429 60 s, 5xx 20 s, auth 1 h, payment 6 h. **Add** a route-level rest (5.4).
- **Capability filters per route:**
  - tools, vision, context window fit (413 "too long" so the app compacts);
  - `routeCap` learning of `max_tokens` limits;
  - `cleanHistory` repair of broken tool-call history.
- **Commit only on real output.** Keep "hold the stream until the first real token so a dead stream can still fail over". In the new design, send heartbeats before that point (5.5).
- **`cutTail` when the upstream dies mid-reply,** so the app continues.
- **The gate check** (blocked, burst, allowance, background lane), usage recording, billing hooks, and the early-start ("spec") call if it ever starts paying off.
- **App side:**
  - error classes (`isFinal` codes, auth);
  - "continue after cut-off";
  - steering (`cancelForSteer`);
  - loop guard notes, truth check, compaction, tool scoping, parallel reads.
- **Live keeps its own separate router** (`live_routes`): see 5.6.

### 5.4 How the sticky router should behave
1. **One shared "current route" pointer.** Store it in the database, for example `ai_router_state(current_route_id, since, fail_count, window_start)`, and return it inside the existing `ai_gate` call, so it costs no extra round trip.
2. **Each request tries the current route first,** with the per-chat sticky key. If that attempt fails, the same request moves straight on to the next healthy route, so the user is never left waiting for a vote.
3. **Swap rule (avoid flapping and herds).** Swap the shared pointer only on clear evidence:
   - 3 hard failures within 60 s (5xx, 429 with all keys resting, empty stream), or
   - 2 first-byte timeouts within 60 s.

   Do the swap with a compare-and-set (`update … where current_route_id = $old`). Then 200 users failing at once cause one swap, not 200.
4. **Route rest with backoff:** a swapped-out route rests 1 min, then 2, 4, 8, up to 15 min.
   - A **background probe** (the bench, every 1–2 minutes instead of hourly) marks it usable again.
   - Following the owner's rule, the pointer does **not** jump back while the current route is fine.
   - Optionally, return to the preferred route after it has passed probes for 30 minutes, at a quiet moment.
5. **Overflow is not failure.** When the current route's keys are all resting from 429s (capacity, not breakage), send that request to the next route *without* moving the shared pointer.
6. **Optional hedge for the first step only.** If the current route has not produced a first token in 4 s on a user-facing request, start the next route in parallel and keep whichever answers first. Cancel the loser at once. This costs a little extra provider usage and cuts the p99 sharply. Do not hedge background work.
7. **Stop on hang-up.** Pass `req.signal` into every upstream fetch; when the phone disconnects, abort everything.
8. **Write state only on change:** a key or route failure, a swap, a recovery. Do not write on every success.

### 5.5 Timeout budget (server total < app wait)
The rule: **every server limit ends before the matching app limit, and the server proves it is alive while it works.**

**Server (ai-chat):**
| Limit | Value |
|---|---|
| Gate call | 2 s limit, then a friendly 503 |
| One attempt: response headers | 6 s |
| One attempt: first real output | 10 s from the attempt's start (not added on top) |
| Attempts before the reply starts | current route + at most 2 others; **no new attempt after 18 s; hard stop at 25 s**, aborting whatever is in flight |
| Heartbeat | after the gate passes, send `200` headers and an SSE comment (`: ping`) at once, then **every 10 s** until the first token, and again whenever the upstream is quiet for 10 s. Errors before the first token go out as an SSE `error` event with a code (`busy`, `too_long`, …); the app already reads `error` events |
| Upstream silence after the reply starts | 45 s, then `cutTail` (clean "cut off, continue") |
| One reply, total | under the platform limit: 140 s on Free, 300 s on paid. End with `cutTail` |
| Non-streamed calls | 45 s total, not 300 s |
| Busy answer | code `busy` + `Retry-After` 15–30 s with jitter |

**App:**
| Limit | Value |
|---|---|
| Response headers | **10 s** with the early heartbeat (30 s if the server change ships later than the app) |
| Silence inside a stream | **30 s** (3 missed heartbeats). The idle timer already counts comment lines, because it counts bytes |
| First visible word | no separate timer; the line says "Still thinking" at 8 s and "Taking longer than usual" at 20 s. At **45 s** with no token, stop and show "Telesia is busy. Tap to try again" (the message is kept) |
| Automatic retries | **1** before any output, only for retryable codes, honouring `Retry-After`. Mid-reply drops: "continue" at most 2 times per step (today 6) |
| `complete()` (titles, summaries, bot checks) | 50 s |
| Session refresh | 5 s |
| Attachment upload | 30 s each, in parallel, not on the critical path |

**bot-run:**
| Limit | Value |
|---|---|
| Per model call | 40 s (server 25 s to start + room to write ~1,200 tokens) |
| Per job | 120 s total |
| New jobs | none after 60 s of a round (the platform's 150 s wall clock) |

**Resulting worst cases:**
- About 25 s server work and 30–45 s of user waiting before a clear message. Today it is up to ~4½ min.
- No server work continues after the phone gave up.
- Provider load in an outage: at most 2× (one retry). Today it is up to 3× with ~50 attempts each.

### 5.6 Live router (Gemini Live keys)
Live already has its own pool (`live_routes`) with per-row rests. To match the chat router:
- **Make it sticky:** hand out the current key until it fails, as with chat. Today rows of the same priority are shuffled on every call.
- **Fetch secrets lazily.** `liveRoutes()` decrypts up to 6 keys **one after another** (6 serial database calls, an estimated 150–250 ms) before it tries the first. Decrypt only the key it is about to use.
- **Put a time limit on the token fetch.** The call to Google's `auth_tokens` has none; the app gives up at 20 s. Use 5 s per key and 12 s in total.
- **Cut the start-up checks.** The `/live-token` path also reads the config, the blocked list and the call-start record before Google. Fold them into one gate call, as chat does.
- **Target:** tap Call → first audio under 2.5 s.

---

## 6. What to do, in order

| # | Change | Effect | Effort |
|---|---|---|---|
| 1 | Server: heartbeat + 25 s budget before the reply starts, `req.signal` abort, `Retry-After` on busy; app: 10 s/30 s timeouts, 1 retry, 45 s "tap to retry" | Ends the 4½-minute waits and the retry storms | Medium |
| 2 | Single model with the sticky router (5.2–5.4) | Fewer model swaps: warm caches, steady quality, no Somali flip; −0.5–3 s on many steps | Medium–large |
| 3 | Effort hint header (`low` for quick, light and step 1) | Removes hidden reasoning before the first word; −0.5–5 s | Small |
| 4 | Attachments: upload in parallel and compress gallery photos; send each image once | −2–20 s on photo messages; less data on every later step | Small |
| 5 | Don't block the first step on connected-app tools; fix `_mcpRefreshing` | −up to 12 s on the first send | Small |
| 6 | Register the run before any await in `send` | No double agents or double cost | Small |
| 7 | Stream re-draw: per-message notifier; plain text for code/tables while streaming | Smooth long replies on cheap phones | Medium |
| 8 | Keep-alive started with the task + partial wake lock; network-change abort | Tasks survive screen-off and Wi-Fi changes | Small–medium |
| 9 | Batch budget for parallel tool results; compaction never blocking; read `x-telesia-window` | No 30k-token surprise steps | Small |
| 10 | Server writes key state only on change; moderation de-dupe in the DB | Lower DB load at scale | Small |
| 11 | gzip request bodies | −0.3–1 s per step on 3G | Small |
| 12 | Drop the forced "say every 6 steps" note; show the truth-checked final answer only after the check | Fewer extra steps and no vanishing answers | Small |

**Measure before and after:**
- Add `ttfw_ms` (send to first visible character) as an app event, by lane.
- Add the server's `Server-Timing` (already sent) to that event.
- Watch p50/p90/p99 by lane and by route, plus "steps served by a fallback route" and "Somali chats on fallback".

---

## Technical appendix (for a developer)

**App: the path to the first word**
- `lib/app_state.dart`
  - `send()` (~4154):
    - attachments are uploaded serially (`repo.uploadAttachment`, no timeout) before `_runAgent`;
    - `_generateTitle` runs unawaited;
    - steering via `task.inbox` / `cancelForSteer`;
    - **race:** `runs.add` happens only inside `_runAgent`.
  - `_runAgent()` (~5133):
    - `_route` → `_withThinking`;
    - `ensureMcpTools()` (~3251; up to 12 s; `_mcpRefreshing` never reset);
    - `QuickLane.laneFor`, `_scopeFor`, skill hints, `Calm` frustration;
    - step loop: notes → `_payload`;
    - compaction check `RateLimiter.estimateTokens(...) > ContextWindow.compactAt` (blocking `_autoCompact`);
    - `_streamResilient`.
  - `_payload()` (~4896):
    - `_systemPrompt`;
    - `_userContent` re-base64s images every step;
    - result masking (`_keepWholeResults = 3`, `ResultClip.fresh` 20k chars);
    - `TailNote.attach` puts the per-step notes in a trailing `user` message. That is what the server's Somali check reads on later steps.
  - `_streamResilient()` (~6161):
    - `RateLimiter.acquire` (cooldown shared per provider id);
    - one candidate;
    - retry loop: 3 tries, 2 s/4 s; 429 waits 15+10n s up to 6 times;
    - `_toolsRejected` / `_liteModels` fallbacks.
  - `_throttledNotify()` (~3870): 40 ms.
  - Escalation: `canLift` / `liftIf` + `TurnRouter.escalate`. Fast start: `lightNow` / `_quickRoute`. Browsing: `_seeRef`.
- `lib/services/llm_client.dart`, `streamChat`:
  - the body has no `effort` and no `max_tokens` from lanes;
  - `.timeout(90s)` on headers; `idleTimeout` 75 s;
  - `[DONE]` read to the end so the connection is reused; errors are mapped to `LlmException`.
  - `complete`: 60 s.
- `lib/services/cloud.dart`:
  - `token()`: refreshSession has no timeout;
  - `headers()` adds `x-region: eu-central-1`;
  - `readHeaders()` ignores `x-telesia-window`.
- `lib/services/rate_limiter.dart`: `estimateTokens` runs `jsonEncode(tools)` on every call; `cooldown` is keyed by provider id.
- `lib/services/quick_lane.dart`: `laneFor` (keep); `effortFor` and `quickMaxTokens` (unused).
- `lib/services/tool_scope.dart`: groups only ever grow within a chat; `more_tools` opens all.
- `lib/services/context_window.dart`: `telesia-` → 48k; `compactAt` = 36k.
- `lib/services/agent_loop.dart`:
  - `TurnRouter` (delete escalate);
  - `ParallelPlan.maxTogether = 6`;
  - `ResultClip`, `LoopGuard`, `StepBudget`, `Recite`.

**App: streaming UI**
- `lib/screens/home_screen.dart` `_list()` (~847): `context.watch<AppState>()`; walks all messages per rebuild.
- `lib/widgets/message_view.dart` `AssistantMessageView`.
- `lib/widgets/reply_blocks.dart`:
  - `ReplyView`: a per-frame `Ticker` with `parseReply` over the full text;
  - `_Bubble` → `StreamingMarkdown`.
- `lib/widgets/chat_extras.dart` `StreamingMarkdown`: only changed paragraphs are rebuilt; a live tail ≥ 1,200 chars is throttled up to 300 ms.
- `lib/widgets/chat_logic.dart`: `splitMarkdownChunks` (a regex is created per line), `nextRevealLength`.
- `lib/widgets/markdown_view.dart`: `MarkdownBody(selectable: true)`, highlight, `IntrinsicColumnWidth`.
- `lib/widgets/composer.dart` `WorkingLine` (~741–870): "Still thinking" at 8 s, "Taking a little longer" at 25 s, `handOver` 1.2 s. `_ThinkingChip`: delete with the single model.

**App: background, browser, bots**
- `lib/main.dart` `didChangeAppLifecycleState` → `AppState.setAppVisible` (~2438): keep-alive starts only when the app is hidden.
- `android_native/TaskService.kt`: dataSync foreground service, no wake lock. `WakeService.kt` has a `PARTIAL_WAKE_LOCK`.
- `lib/app_state.dart`:
  - `_wireBrowserJobs` (~1712): browser sub-agent model calls go through `_streamResilient`;
  - `_officeParallel = 2`.
- `lib/services/browser_jobs.dart`: `maxParallel = 3`, `segmentStepCap = 220`, check-in minutes.
- `lib/services/browser_agent.dart`: 120 s per action, page loads 15–20 s.

**Server**
- `supabase/functions/ai-chat/index.ts`:
  - `handle()` chat path (~1267): `gate` / `ai_gate`, early "spec" call, checks, `makePlan`.
  - The fallback loop (~1463):
    - `fetchWithFirstByte`: aborts at `first_byte_timeout_ms` 12 s, `within` +1 s;
    - first-real-output loop: `fbFor + 3000` per read, abort at 12 s;
    - `fallback_budget_ms` 75 s, checked only before attempts;
    - `maxAttempts = max(6, routes×2+2)`;
    - a second pass with resting keys.
  - Streaming `pull` (~1628): `stream_idle_ms` 90 s; `cutTail`.
  - Non-stream `within(res.json(), 300000)`.
  - Exhausted: `503` (last 429) / `502`, no `Retry-After`.
  - `req.signal` is not used.
  - `markKey` on every success and failure (DB write); `localCooldown` and `rr` are per-isolate.
  - `keysInOrder`: per-chat sticky hash.
  - `makePlan` (~1132):
    - grace alias in the light state;
    - Somali swap (`isSomaliChat` reads the last user-role message, which is the app's note on later steps);
    - vision forcing;
    - `spare` routes from other aliases;
    - fit check / 413; `x-telesia-window`.
  - `screenLater` / `classify` (~529–585): per-isolate de-dupe.
  - Live `/live-token` in `mediaRoute` (~922): `liveRoutes()` decrypts up to 6 secrets serially; Google `auth_tokens` fetch has no timeout.
- `supabase/functions/bot-run/index.ts`: `MODEL_TIMEOUT_MS` 55 s, `DEADLINE_MS` 105 s, `MAX_STEPS`, `telesia-fast` / `telesia-smart`.

**Measurements relied on**
- `docs/project-state.md`:
  - the "Proxy speed pass" and "Model proxy speed" sections (gate 114–150 ms, first token 0.82/0.99 s from a test box, upstream first byte, 7-day p50/p90 by provider, fresh-isolate finding);
  - "Tools by need" (tool schemas 3.9k plain / 9.8k all, prompt ~6–7k for a plain message).
- `docs/model-routes-2026-10-21.md`: route order and per-route latency.
- `docs/cloud-proxy.md`: allowance, background lane, Live pool, bot-run.

**Not verified (needs a real phone or the live project)**
- Actual first-word times from Somalia.
- Whether Android allows the keep-alive service to start after the app is hidden.
- Stream behaviour with the screen off.
- Jank levels on a low-end device.
- The Supabase plan's wall-clock limit.
- Per-key concurrency limits at Ollama Cloud and NVIDIA.
- Whether the live ai-chat matches the repo copy (see backend.md).
