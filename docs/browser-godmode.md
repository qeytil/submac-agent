# Browser god-mode: how SubMac's agent gets better at the web than any human

*Research pass, 2026-10-31. Question from the owner: "how can we make the browser use god level power and the agent/bot use browser natively better than even human?"*

---

## 1. First, define "better than human" precisely

A human at a browser: 1 deliberate action every 2–4 seconds, one tab of attention, forgets site quirks,
gets distracted mid-flow, mistypes, fatigues after ~30 minutes of form-filling, cannot read a site's
network traffic, and cannot run 8 flows at once. "God level" is not "faster clicking". It is:

| Human limit | The agent's counter |
|---|---|
| Sees only pixels + rendered text | Reads the site's **data layer** (network JSON, JSON-LD, state trees) — the same data the site's own code reads |
| Types/clicks serially | Fills whole forms, extracts whole pages in **one atomic JS call** |
| 1 tab of attention | **N parallel tabs/jobs**, each with its own memory |
| Forgets how a site works | **Site skills**: recorded, replayed, self-healing playbooks — zero model calls on replay |
| Waits for pages like a person | Acts the instant the **network goes quiet**, not when the spinner ends |
| Renders every page to read it | **HTTP-first triage**: fetches with the session's cookies and often never renders at all |
| Tires, distraits, mistypes | Never does; LoopGuard + budgets already exist |

Each row maps to a capability below. The deepest two — the ones no consumer agent ships today —
are the **data layer** and **site skills**. That is where "god level" actually lives.

---

## 2. Where SubMac v2 already stands (honest audit)

From `docs/browser-use-v2.md` and the code (`browser_agent.dart`, `browser_jobs.dart`,
`browser/page_script.dart`, `browser/shots.dart`, `browser/loop_guard.dart`):

Already at or beyond SOTA:
- **Dual-channel perception**: numbered interactive elements (≤140) + visible text + a set-of-marks
  screenshot with the *same* numbers. This is the browser-use hybrid — strictly stronger than OpenAI's
  CUA/Operator pure-vision loop (58.1% WebArena) and stronger than Playwright MCP's a11y-only view
  (which is blind to canvases and maps — SubMac keeps `browser_tap_at` for those).
- **Real touch injection** (`WebHands.kt`): genuine `MotionEvent`s into a real Android WebView on a real
  phone. Desktop agents run headless Chromium with synthetic CDP input — a *worse* stealth position than
  "it literally is a phone". This is SubMac's unfair advantage; keep investing in it.
- **Batched actions** (1–6 per step) with post-action skip, **Effect line** per step ("NOTHING changed"
  self-check), **ShotGate** (no re-send of unchanged screenshots), **LoopGuard + StepBudget**
  (120 steps / 25 min), **3 parallel jobs with owned tabs**, take-over/hand-back, inline approvals,
  password fill without exposure, per-domain session memory.

Honest gaps vs. the frontier:
1. The model is **blind to the network layer** — the biggest one (see §4, P1).
2. Extraction is manual: "read page → reason → retype". No schema extraction tool.
3. Every step costs a model call, even the 50th identical visit to the same site. No flow memory.
4. `browser_js` is framed as "last resort" — right for *writes*, wrong for *reads*.
5. Snapshot per step is full-size; no diff/patch mode.
6. Waits are text-based (`browser_wait` for text, 20 s max) — no network-quiet signal.

---

## 3. What the frontier does (and what to steal from each)

| System | Core idea | Verdict for SubMac |
|---|---|---|
| **browser-use** (~120k★) | DOM tree → indexed clickable elements + optional vision; plan/act loop; history record → `detect_variables()` → `load_and_rerun()` replays recorded flows **without model calls per step**; cloud stealth browsers; BU2 model tuned for browsing | The replay-with-variables idea is the single best steal → becomes **site skills** (§4, P3). Their cloud is not needed — the phone *is* the stealth browser |
| **Playwright MCP** | Accessibility-tree snapshots with stable **refs**; "deterministic tool application, no vision needed"; `browser_find` to search the snapshot cheaply instead of re-snapshotting; explicit network/console observability tools | Steal: refs over re-numbering (stability across steps), `browser_find` (search, don't re-send), and the **network tools** as first-class |
| **Stagehand** | `act` / `extract` / `observe` primitives; **action caching** (replay verified paths, self-heal on site change by re-planning the broken step) | Steal: extract-as-primitive and cache-and-self-heal — folded into site skills + `browser_extract` |
| **Skyvern** | Vision+DOM hybrid, workflow caching for repeated enterprise flows, strong on complex forms | Confirms workflow caching; nothing new beyond §4 |
| **OpenAI CUA / Operator** | Pure vision loop, RL-trained, high-res screenshots; 87% WebVoyager / 58.1% WebArena | Do **not** imitate: slower, costlier, less precise than DOM-first. Keep vision as the *verification* channel (SubMac already does) |
| **Claude computer use** | 17 actions incl. `enable_zoom`; richer action vocabulary | Minor: the action vocabulary is already comparable in v2 |

**The meta-lesson:** every frontier system converges on (a) structured page state over pixels,
(b) fewer model round-trips per unit of work, (c) memory that turns the 50th run into a replay.
SubMac has (a) already. The doc's roadmap is (b) and (c) built on the WebView's own superpowers.

---

## 4. The roadmap: six levels, concrete engineering

### P1 — The network ear (the real god-mode unlock) 🔑 — SHIPPED 2026-10-31
The WebView's page script hears **every data call the page makes** (fetch/XHR hooked at document start) — something no human can see.
- The page script (v8) records data calls (JSON/XML/CSV/plain text, bodies ≤20 KB, ring of 40; assets and page documents skipped).
- `browser_net` — lists the calls (numbered, with size/kind/latency), reads one call's body by id (JSON pretty-printed), `clear` forgets them.
- `browser_fetch` — re-calls a URL (absolute or page-relative) **with the page's own session** (cookies, sign-in, origin) via the page context. GET/HEAD only; writes stay on the page's own controls with approvals.
- The observe payload gains one quiet line: `Data: N data calls — browser_net lists them; browser_fetch re-calls one with this page's own session.`
- Code: page script ear + `S.netList/S.netBody/S.netClear` (`tools/browser_page.js` v8), `lib/services/browser/net_calls.dart` (NetCall + formatters), `browser_agent.dart` (`_net`/`_fetchApi`, observe Data line), sub-agent prompt teaches the data layer. Tests: `tools/browser_page_test.js` §8 (jsdom), `test/browser_net_test.dart`.
- Boundary (honest): the ear hears main-frame fetch/XHR — cross-origin iframes and service-worker-only traffic stay invisible (the page script cannot inject there). `browser_fetch` is also same-origin-plus-CORS: for another origin, the error tells the agent to read the page instead.

### P2 — Data-layer reading + schema extraction — SHIPPED 2026-10-31
The page's own structured data, free for the taking, and every matching item pulled in ONE call.
- The page script (v9) collects the free wins once per document: JSON-LD blocks (`@type` + size, ≤12), app state scripts (`__NEXT_DATA__`, `__INITIAL_STATE__`, `__APOLLO_STATE__`, `__NUXT__`, `__PRELOADED_STATE__`, ≤4), OpenGraph/Twitter meta count. The snapshot carries a one-line summary; the observe payload gains `Schema: JSON-LD Product, state 84.3KB, og:8 — browser_schema opens one; browser_extract walks the page.`
- `browser_schema` — lists the blocks; with an index, reads one in full (JSON pretty-printed, 20 KB cap).
- `browser_extract` — the walker: `rows` = a CSS selector matching each item, `fields` = what to take from each row (a selector for text, or `{"sel":"a","attr":"href"}`); returns JSON for ALL matching rows in one call (≤200 rows, values ≤300 chars) — no read-page → reason → retype loop.
- The ```data``` output card: extracted rows (a JSON array of objects, a table-shaped map, or plain CSV) render as the SubMac table card, folded like every long output.
- Code: page script schema ear + `S.schema/S.schemaOpen/S.extract` (`tools/browser_page.js` v9), `lib/services/browser/extract.dart` (formatters), `page_model.dart` (`schema` field), `browser_agent.dart` (`_schema`/`_extract`, observe Schema line), `output_cards.dart` (`dataCardFrom`, kicker), sub-agent prompt. Tests: `tools/browser_page_test.js` §9 (jsdom), `test/browser_extract_test.dart`, `test/output_visual_test.dart` (data card).

### P2 — Data-layer reading + schema extraction (original plan)
- `browser_extract`: the model supplies a JSON schema; a page-script walker + (when needed) model-written
  JS returns structured data for **all matching items on the page** in ONE call — vs. today's
  read-page → reason → retype loop.
- Auto-collect the free wins into the observe payload: JSON-LD, OpenGraph/meta, `__NEXT_DATA__` /
  `__INITIAL_STATE__` (sizes only; the model opens what it needs). One line: `Data: JSON-LD Product ×1, state 84KB`.
- Promote `browser_js` for **reads**: "for reading/extracting, write one small JS function — it is the
  first choice, not the last resort." Keep it last-resort for *writes* (approval-gated as today).
- A new ```data``` output card: extracted tables/JSON rendered as a SubMac table card (fits the
  existing output-card stack; long output folds like SummaryCard).

### P3 — Site skills (memory: the 50th visit is free) 🔑 — SHIPPED 2026-10-31
A flow that worked once replays with **zero model calls per step**; the first mismatch hands the job back to the agent.
- **Recorded while working**: every successful click / type / select / scroll / key of a job is recorded as a step with a *signature* — kind + visible label + href (never coordinates; a password is never recorded). `compressSteps` drops what cannot be replayed (empty typed values, unlabeled controls, `tap_at`), collapses repeated scrolls, caps at 40.
- **Saved**: `browser_play` action "save" writes the playbook to `<documents>/browser_skills/<id>.json` (`SiteSkills`) and mirrors it into "Your own skills" through `SkillLibrary.save` (id `web-<id>`, readable step list) so the user sees and can remove what the agent learned.
- **Replayed**: action "run" resolves each step by signature against the live snapshot (exact label → partial label → href → kind-only), executes through the same hit-tested engine, refreshes the view between steps, and counts the run (runs / wins).
- **Self-heal handoff**: the moment a step no longer matches (or its action fails), the replay stops with the step, the reason and the fresh page in front of the agent — it does that step itself and the rest of the goal; saving again records the new path. A redesign costs one model call, not a broken automation.
- **Approvals stay in the path**: a replay halts before a click on a payment page ("the user is asked before money moves") — the final purchase is done by the agent's own gated step, never by the replay.
- **Variables**: `values` replaces typed values by field label (`{"Search": "flights to Hargeisa"}`) or by step number (`"2"`).
- Code: `lib/services/browser/playbook.dart` (PlayStep/Playbook, resolveStep, compressSteps, withValues), `lib/services/browser/site_skills.dart` (storage), `browser_agent.dart` (`_record`/`_sig`/`_refresh`/`_play`, the `browser_play` tool), sub-agent prompt. Tests: `test/browser_playbook_test.dart`.
- Boundary (honest): v1 has no cross-visit step *repair* — a mismatch stops and hands over (the agent then saves the new path); values are substituted, not inferred; playbooks are per phone (the Supabase sync is the next step).

### P3 — Site skills (memory: the 50th visit is free) 🔑 (original plan)
The highest-leverage feature, and SubMac already owns the perfect container (`skill_save` + skill library):
- After a browser task succeeds, the job's step history is compressed into a **playbook**:
  `{site pattern, steps: [{act, target signature, optional var}], variables the user supplied}`.
  Target signature = robust match tuple (role + name + placeholder + nth-of-type + text), not coordinates.
- Saved via the existing `skill_save` path as kind `browser` (visible in "Your own skills").
- **Replay**: on a matching task, the playbook executes with **zero model calls per step** — values filled
  from variables, waiting built in. A 40-step checkout replays in seconds.
- **Self-heal** (Stagehand-style): on first signature mismatch, that ONE step is handed to the live
  agent loop (which sees the current page), the repaired step is re-recorded, replay resumes.
  A site redesign costs one model call, not a broken automation.
- Money/approval steps replay **with approval, always** (BrowserGate stays in the replay path).

### P4 — Speed: act at network-quiet, diff the view, triage with HTTP — SHIPPED 2026-10-31
Three cuts that convert directly into more steps per budget.
- **Patch views**: after a step on the same page, the observe payload lists only the elements that are new or changed and says `Elements: N of M — only what is new or changed`; when the words did not move it says `Text: unchanged since your last step.` instead of repeating 2600 chars. A navigation still sends the full view, and `browser_read full:true` lists every element again on demand. (The "Effect:" line was already there and stays.)
- **Network-quiet waits**: `browser_wait quiet:true` waits until the page stops talking (no request in flight, DOM calm, max 10 s) instead of guessing seconds; navigation settle already used the same signal (`S.quiet`).
- **HTTP-first triage**: `browser_open read:true` answers a read-only task from a same-session fetch — the WebView's own cookies, no CORS, no render — returning `Served from fetch, no render — <title>` with the readability text (scripts/styles/markup stripped, entities decoded, 6 KB cap). JSON answers are pretty-printed. If the page is a script shell (under 200 chars of text) or the fetch fails, it renders as usual and says so.
- Code: `lib/services/browser/read_page.dart` (`htmlToText`/`htmlTitle`), `page_model.dart` (`describe(diff:)`), `browser_agent.dart` (`_fetchRead`, `browser_open.read`, `browser_wait.quiet`, `browser_read.full`, observe `diff: true`), sub-agent prompt. Tests: `test/browser_speed_test.dart`.
- Boundary (honest): the readability pass is a tag strip with block breaks, not a full article extractor; the fetch uses the cookie jar but not the page's JS-set storage (localStorage tokens are invisible to it) — those pages fall back to rendering.

### P4 — Speed: act at network-quiet, diff the view, triage with HTTP (original plan)
- **Network-quiet waits**: page script tracks in-flight fetch/XHR + MutationObserver; `browser_wait`
  gains `quiet:true` ("wait until the page stops talking, ≤10 s") and navigation returns the instant
  the network is quiet — the agent acts *before* a human would have noticed the spinner.
- **Snapshot diffing**: after a batched action, send only *changed/new* elements + the Effect line
  (patch, not full snapshot; full re-snapshot on demand with `browser_read`/`view`). Expect 50–70%
  token cut per step — which converts directly into more steps per budget and faster tasks.
- **HTTP-first triage in `browser_open`**: before rendering, a same-session fetch (cookies from the
  cookie manager) + readability pass; if the text answers a read-only task, return it in ONE step with
  `Served from fetch, no render`. Render only for interactive work. Read-heavy research gets 10×+ faster.

### P5 — The fleet: scale and fan-out
- Raise the job cap (3 → 6–8) with a global step/token budget; per-job tabs stay owned (existing pattern).
- `browser_extract_many`: "extract this schema from each of these links" → parallel tabs, merged into
  one ```data``` table card. This is the demonstration users will screenshot: *30 product pages →
  one comparison table, while the user watches the live cards*.
- Planner/worker split stays as-is (the chat agent delegates to browser jobs) — do not add a second
  planning layer.

### P6 — Polish the superpowers already unique to SubMac
- **Human-real input**: randomized human-ish inter-key delays and gesture curves for WebHands
  (micro-jitter, occasional overshoot-and-correct on long drags). The phone is the best stealth
  browser on the market; make its hands indistinguishable.
- **Self-healing targets**: when a click "lands but nothing changed", auto re-match the element by
  signature (role+text+position) and report "the button moved to [15] — tapped it", instead of
  burning a model turn on re-perceive.
- **Login vault UX**: per-domain saved logins surface as one-tap approvals ("Sign into X with your
  saved login?") so replays never stall on auth.

---

## 5. What we deliberately do NOT do (the honesty list)

- **No cloud browser / no cloud computer.** The owner marked the cloud computer as the allowed gap;
  a remote browser would also throw away the phone's stealth advantage. Everything runs on-device.
- **No pure-vision CUA imitation.** Vision stays the verification channel, not the driver.
- **No CAPTCHA-solving services.** Captchas go to `ask_user` (human solves, agent continues) — same
  honesty rule as payments. A "god" that lies about being human is not the product.
- **No scraping of what the site forbids.** BrowserGate's money/risk heuristics extend to replay
  (P3): replays never bypass approvals.

---

## 6. How we'll know it's god-level (browser_eval)

An internal eval set, like `prompt_eval` but for the browser — 20 recorded tasks on real sites:
1. **Speed**: steps-per-task and model-calls-per-task vs. v2 baseline (target: ÷3 on read tasks via P2+P4).
2. **Memory**: a 20+ step flow replayed via site skill with **0 model calls** (target: 100% replay, heal ≤2 steps).
3. **Breadth**: extract-many over 20 links → one table, zero dropped rows.
4. **Data layer**: tasks only answerable via network JSON (e.g. "exact fare breakdown") — pass rate.
5. **Cost**: tokens per task (target: ÷2 via diffing).

Each phase lands with its eval slice green before the next starts. Order: P1 → P2 → P3 → P4 → P5 → P6
(P1+P2 are one release; P3 is the release after; P4–P6 follow as capacity allows).
