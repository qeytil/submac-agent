# Browser use v2 (v1.13.96+163)

Owner report (2026-10-24): the in-app browser agent is buggy. Rebuild it and restyle it like hark.com.
Owner follow-ups the same afternoon: (1) weak loop (planning, verification, recovery; gives up or loops),
(2) weak, slow actions, (3) the browser bleeds into the sky, (4) clicks miss the button, (5) it hangs forever,
(6) the agent is "blind": it needs a fresh screenshot after every action.

## 1. Audit of v1: bugs and root causes

| # | Bug | Root cause (file) |
|---|-----|-------------------|
| A1 | **Browser bleeds into the sky** | `BrowserLayer` sat INSIDE `SkyBackground` and put the hidden WebView between the sky and the app. The app's screens are see-through (`scaffoldBackgroundColor: transparent`, so the sky shows), so the hidden page showed through every screen. (`main.dart`, `browser_layer.dart`) |
| A2 | **Clicks land beside the button** | (a) `scrollIntoView({block:'center'})` follows the site's CSS `scroll-behavior: smooth`, so the point was measured mid-scroll; (b) the point was the centre of the element box, which on wrappers (cards, `[onclick]`, `cursor:pointer` divs) is often another control or an overlay; (c) the JS fallback pressed `elementFromPoint` even when that was a PARENT of the target; (d) a real touch counted as success if ANY trusted event arrived, not one on the target; (e) `tap_at` mixed layout-viewport and visual-viewport maths, and element positions were % of the layout viewport while the screenshot shows the visual viewport, so with page zoom the % were off. (`browser_agent.dart` `__sm_pt`, `__sm_tap`, `__sm_ptPct`, `_touch`) |
| A3 | **Agent is blind** | The screenshot was attached only when the very last step was a browser call; after a `plan`/`note`/`check`/`report` call (frequent) the next model call got NO picture. Error paths returned before taking one. (`browser_jobs.dart` `_payload`) |
| A4 | **Hangs forever** | Unbounded awaits: sign-in sheet (`askLogin`, `confirmLogin`), hand-back wait, `loadUrl`, `goBack`, `reload`, `setSettings`, model call; `_waitFor` looped with no deadline; Stop did not end a step waiting on the user; `onDisposed` left `ready` completed so `_ensure` could return a null controller. |
| A5 | **Loops / gives up** | Watchdog window was not reset after a warning, so one repeat fired it on 3 consecutive steps and the task jumped to "needs" (asking the user) within two steps; "same page" used a hash of the result text (never equal), so stalls were missed; no total step budget (only per segment), so "continue" could run forever. |
| A6 | **Slow** | The 25 KB helper script was re-sent over the platform channel on every JS call (5–10 per step); fixed sleeps (`_settle` 120 ms + 6×80 ms polls, 160 ms title mark, 60 ms); real touches first (arm + mark + native + check) for every click; one action per model call. |
| A7 | **Approval bypass** | Only `browser_click`/`tap_at`/`js` were gated. `browser_type submit:true` and `browser_press Enter` submitted forms (pay, send) with no ask; icon-only buttons (empty label) and "Continue" on checkout never asked; page `confirm()` dialogs ("Delete account?") were auto-accepted. (`tool_router.dart` `_riskFor`, `browser_layer.dart` `onJsConfirm`) |
| A8 | **Iframes invisible** | Same-origin iframe elements were collected but the occlusion test ran against the top document, so every iframe element was dropped; cross-origin frames were not mentioned at all. |
| A9 | **Overlay drawn into the page** | Blue boxes were injected into the page DOM before each screenshot: users saw them flash, sites' MutationObservers reacted, and the "quiet" wait saw its own mutations. |
| A10 | **Sign-in sheet in the wrong chat** | `askLogin` used the global `_browserConv` (last chat that used the browser), not the asking task's chat. |
| A11 | **Chat step spam** | `report` posted a chat message every 45 s; the composer line had a Watch pill + a checklist under it. |
| A12 | Misc | URLs with a space became a DuckDuckGo search; `localhost:3000` too; pop-up tabs were not owned by the task that opened them. |

## 2. Research takeaways (what fits a phone)

Sources read: browser-use system prompt (github.com/browser-use/browser-use, `browser_use/agent/system_prompts/system_prompt.md`),
Playwright MCP README (github.com/microsoft/playwright-mcp), Stagehand docs (docs.stagehand.dev), Skyvern README
(github.com/Skyvern-AI/skyvern), Nanobrowser README (github.com/nanobrowser/nanobrowser), Agent-E README
(github.com/EmergenceAI/Agent-E). LaVague was not re-read this session (known pattern: world model + action engine).

- **Numbered interactive elements** from a DOM/accessibility snapshot (browser-use `[index]`, Playwright MCP `ref`,
  Agent-E `mmid`). Nanobrowser: an id is tied to the exact element and stops working when the page changes, instead of
  pointing at something else. → stable ids per element (WeakMap), `gone` when removed.
- **Vision + DOM hybrid**: screenshot with boxes whose numbers match the list is the ground truth (browser-use);
  Playwright MCP shows DOM alone is enough for many steps, Skyvern shows vision handles unknown sites. → both, every step.
- **New elements starred** (`*[` in browser-use) after an action, e.g. autocomplete options. → done.
- **Act → verify**: Agent-E reports DOM changes after each skill (MutationObserver); Nanobrowser checks visible, not
  covered, and reports whether the page responded. → hit-test before press + Effect line after.
- **Several actions per step** with page-changing actions last and the rest skipped on change (browser-use). → `browser_act`.
- **Evaluation / memory / next goal** fields each step; plan with `[x] [>] [ ]`; 75 % budget warning; `done` only after
  re-checking every requirement (browser-use). → in the prompt, notebook and `finish` checks.
- **Loop breaking**: same URL 3+ steps or same failing action 2–3 times → change approach (browser-use). → `LoopGuard`.
- **Smart settle** (Playwright MCP `timeout-settle`, network + DOM quiet) instead of sleeps. → `S.quiet`.
- **Ask before submit / send / delete / pay**, hand payments to the user (Nanobrowser Ask mode). → `BrowserGate` + the
  app's approval flow; payment pages always ask.
- **Cookie banners and pop-ups first** (browser-use). → auto-dismiss (reject when offered) once per site.
- Not taken: CDP/Playwright (not on Android WebView), LLM-written code (Agent-E argues skills are safer), per-frame model
  calls (cost), Stagehand's server-side caching (no server change allowed).

## 3. Design (what was rebuilt)

**Page script** (`tools/browser_page.js` → generated `lib/services/browser/page_script.dart`, injected at document
start as a user script, re-injected on demand):
- Snapshot: interactive elements in the main document, open shadow roots and same-origin frames (with their offset),
  plus up to 1.6 screens below (marked "scrolls in"); stable numbers; label from aria-label/labelledby/label/placeholder…;
  cross-origin frames reported for `tap_at`; cookie banner and its refuse/accept button; payment markers; fingerprint.
- Clicks: instant scroll, then a **hit point** — centre if `elementFromPoint` (through shadow roots and frames) is the
  element or its descendant, else the first free point of a 3×3 grid, avoiding inner controls; covered elements report
  what covers them. Events go to the element actually under the point, then `click()`.
- Positions are fractions of the **visual viewport** (= the screenshot = the WebView), so DPR, zoom and scroll never shift
  a tap.
- Typing through the native value setter + `beforeinput`/`input`/`change` (React-safe), then the value is checked.
- `S.quiet(max, 250)`: DOM quiet + no fetch/XHR in flight + not loading; hard max.
- Never mutates the page (no overlay, no attributes).

**Engine** (`lib/services/browser_agent.dart`): JS first; if a click had no effect (no URL/DOM/focus/network change), one
real Android touch at the same verified point, and the trusted event must land on the target. Every await is bounded
(step 60 s, load 20 s, JS 8 s, screenshot 5 s, user 10 min) and ends at once on Stop (per-task end signal). After every
action: smart settle → snapshot and screenshot **in parallel** → set-of-marks drawn in Dart in an isolate (720 px JPEG
for the model, clean copy for the card) → **Effect** line from before/after state + screenshot signature.
`browser_act` runs 1–6 actions and stops at the first failure or page change. Live frames (~1.4 fps, 420 px) only while
a card is on screen.

**Loop** (`lib/services/browser_jobs.dart`): browser-use style prompt; notebook with checklist `[x] [>] [ ]`, memory,
pages visited, budget left; the latest marked screenshot always attached (one image); `LoopGuard` (repeat, stall,
failures, bounce) → nudge → forced re-plan → clean stop with a clear message; `StepBudget` 120 steps / 25 min;
model call limit 150 s (twice → clean stop); `_waitFor` deadline; `finish` checked against the checklist.

**Approvals** (`BrowserGate` in `lib/services/browser/actions.dart`, used by `tool_router.dart`): click, type+submit,
Enter, tap_at, js and batches are gated; on payment pages any button that moves on asks and the kind is always
`money` (asks even with Full access). Page `confirm()` that sends/pays/deletes goes through the approval flow. When the
chat's browser card is on screen, the same approval appears on the card (inline form); otherwise the usual sheet/bubble.

**UI** (`lib/widgets/browser_card.dart`, `lib/widgets/browser_layer.dart`): see section 4.

## 4. Hark-style UI

- Live card in the chat turn (replaces the status line + Watch pill + checklist): soft dark rounded card (20 px),
  72×104 live thumbnail (opaque, clipped 16 px), site icon (or first letter) + domain, one faded pill whose words change
  in place. Tap → full-screen live view.
- Full view: domain + status at top, Close; the live page in an opaque card clipped to 20 px; Take over / Hand back and
  Stop at the bottom. It sits above the app; the hidden page sits under the app on an opaque floor.
- Inline forms on the card: approval (Allow / Not now / Allow always — never for money), sign-in (email, password,
  save on this phone), saved-login confirm, one-time code / question. The ask bar leaves those asks to the card.
- When the task ends: a compact ```` ```browser ```` result card (site, Done/Stopped/Could not finish + time, two lines of
  summary, opens the final page).
- Reduced motion (status swap instant), RTL (directional layout), both themes (Palette tokens), Somali and Arabic strings
  (status phrases included; native review owed).

## 5. Tests

- `test/browser_use_v2_test.dart`: snapshot/indexing, starred new elements, payment detection, page-script sync and click
  fixes, URL handling, batch validation, effect, approval gating (incl. Enter/submit, icon buttons, batches, money always
  asks), inline approval (answer / timeout), loop guard (repeat → nudge → re-plan → stop, stall, failures, bounce,
  progress reset), budget, bounded waits, agent loop (missing click ends cleanly, budget, Stop during thinking, silent
  model, finish check, screenshot always attached, result card), set-of-marks drawing.
- `test/browser_card_test.dart`: card states, status in place, opaque + clipped thumbnail, reduced motion, RTL,
  Arabic/Somali, inline approval, money without "Allow always", result card, layer order (hidden page under the app,
  live view above, opaque, clipped), app not rebuilt when the view closes, Stop.
- `tools/browser_page_test.js` (dev, jsdom with a fake layout): wrapper vs inner button points, covered elements,
  typing, stable ids, below-the-fold clicks, cookie banner, select. Run:
  `NODE_PATH=<dir with jsdom> node tools/browser_page_test.js`.

## 6. Not changed / open

- No server change, no billing change. Native `WebHands.kt` unchanged.
- Needs a real-phone pass: hidden WebView under the opaque floor must still render and screenshot (TLHC; same as before:
  it was always behind the app), live frames cost, sites that only accept trusted input.
- The incoming-call layer is now under the full browser view (the view covers it while open).
