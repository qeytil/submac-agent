# browser_eval — the browser on real sites

*2026-11-01. Closes the last open item of `docs/browser-godmode.md` §6: "What is left is not a phase but the eval run
itself: browser_eval on real sites."*

## What it is

`tools/browser_eval/eval.js` drives **20 tasks on real public sites** through the exact page script the phone
injects into every page (`tools/browser_page.js`, copied into `lib/services/browser/page_script.dart`). Each task
works the way the agent's tools do:

- it reads `S.snapshot()` (the numbered elements and visible text the model sees) and finds its target **by visible
  words only**, never by a CSS selector the model could not know;
- it taps where `S.point()` says a finger should go, as a trusted touch, then asks the page who got it
  (`S.armHits` / `S.hitOn`) and falls back to the script's own click when the touch missed — the same order as
  `BrowserAgent._touch` on the phone;
- it types with `S.type`, fills sign-ins with `S.login`, reads the data layer with `S.schema`, `S.netList`,
  `S.netBody`, `S.extract`, `S.extractHtml`, and checks that the page really changed.

It runs in a Pixel-sized Chromium (viewport, user agent, touch), the closest stand-in for Android's WebView that CI
has. Command: `cd tools/browser_eval && npm i && npx playwright install chromium && node eval.js`.

CI: `.github/workflows/browser-eval.yml` — on every change to the page script or the eval, every Monday (real sites
drift), and on demand. It also fails when `page_script.dart` is stale against the JS, so the app always ships the
script the eval tested. Pass bar: 85% (one drifting site never fails the run; a broken script fails many tasks).

## The 20 tasks (mapped to §1 of the god-mode doc)

| kind | tasks |
|---|---|
| act | wiki-search, login-form, dropdown, checkboxes, add-remove, file-upload, key-press |
| breadth (extract-many) | hn-extract-30 (30 rows, zero dropped), books-extract-20 |
| speed | http-triage-no-render (page 2 parsed over HTTP, never rendered), dynamic-wait |
| data layer | net-ear-json (the site's own API call, with body), net-ear-next-page-by-api (page 2 by re-calling that API instead of scrolling), schema-jsonld (Recipe JSON-LD), state-tree (Next.js) |
| perception | shadow-dom, iframe-editor, modal-detect |
| cost | snapshot-budget (Wikipedia, GitHub trending, BBC: ≤140 elements, ≥80% named, ≤9k tokens) |
| memory | heal-after-redraw (an old number finds the redrawn button) |

## First run: 3 real bugs found and fixed (page script v11 → v12)

Baseline with the shipped v11 script: **16/20**. With v12: **20/20**.

1. **The data ear was deaf to XHR.** `browser_page.js` defined the recording `XMLHttpRequest.send` wrapper and then a
   second, plain one under the same name that replaced it. Every jQuery / XHR site (still a large share of the web)
   showed zero calls to `browser_net`. Fixed; a unit test now asserts exactly one wrapper and that it records.
2. **Pop-ups without ARIA were not modals.** Only `role=dialog` / `aria-modal` counted, so a plain `div.modal` over a
   dimmed page was invisible as a pop-up. A fixed/absolute layer named like a modal/popup/dialog/lightbox that covers
   ≥30% of the screen now counts.
3. **Clickable paragraphs and headings got no number.** The pointer-cursor scan looked at div/span/li/img/svg/i only,
   so a `<p>Close</p>` with a click handler (the pop-up's only way out) was not in the snapshot. The scan now also
   covers p, h1–h6, td, dt, dd.

## What this eval does not cover (runs on the phone)

- The model's choices (which element, when to stop): that is the agent eval, not this one.
- Real WebView touch injection (`WebHands.kt`) and the notch/overlay: phone-only.
- Site-skill replay through the agent loop and background (scheduled) browser jobs: phone-only.
