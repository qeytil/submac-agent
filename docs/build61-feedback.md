# Owner feedback on build-61 (v1.13.101+171)

Manuel phone-tested build-61 and reported four problems. All four existed before build-61 (owner, 2026-10-24), so the
root causes below are in the older code; the fixes are on top of current main (build-61). No Supabase, ai-chat, server,
pricing, plan or schema change.

## 1. "The sky bg is short, it should be zoomed in"
**Root cause (native, since the shared engine).** The app runs one long-lived Flutter engine (`SubMacApp`). Dart's
`main()` calls `SystemChrome.setEnabledSystemUIMode(edgeToEdge)` once, and it only reaches the first screen the engine is
attached to (and none at all when a background service started the engine first). Every later `MainActivity` (after
Back, a recreate, a start from a service or notification) gets a new `PlatformPlugin` with Flutter's default flags:
`LAYOUT_STABLE | LAYOUT_FULLSCREEN`, i.e. under the status bar but **not under the navigation bar**, plus
FlutterActivity's own 25% black status-bar scrim. So the window stopped above the navigation bar and the sky looked
cut short. The sky widget itself was right (BoxFit.cover at the full window, drift zoom above its shift; its tests pass).

**Fix.**
- `MainActivity.edgeToEdge()` after `super.onCreate` and in `onPostResume` (after FlutterActivity re-applies its
  defaults): `setDecorFitsSystemWindows(false)` (API 30+) or the legacy layout flags, transparent bars, no contrast
  scrim, display cutout `ALWAYS`/`SHORT_EDGES`. The look's light/dark icon bits are kept.
- Dart re-sends `setEnabledSystemUIMode(edgeToEdge)` on every return to the app (`SkyBackgroundState`).
- Base zoom 1.12 → 1.16 ("zoomed in"); the drift still always covers (`skyCovers`).

## 2. "The follow up questions have bugs and it's asking questions with minimal choices"
**Root causes.**
- ```` ```choices```` drew only a bare JSON list of strings. `{"question","options":[…]}`, `[{"label":…}]` or plain lines
  drew nothing, and the reply check sent such replies back for another model call.
- The choices card had no "Something else" row; every old card stayed tappable (re-sending an old answer) and lost its
  tick when it scrolled away; it rebuilt on every streamed word (`context.watch`).
- `ask_user` crashed on `options` sent as one string ("A, B, C" or a JSON string), so the model asked again with none.
- The model's own "Other" showed next to the app's "Something else".
- The prompt and the tool asked for "2-5" answers, so models gave two. Bot greetings asked for "one or two" suggestions
  while a one-answer card was invalid (dropped, or one more model call).
- The automatic follow-up taps turned "X, Y or Z?" into Yes / No, made "Me to keep going" out of "Do you want me to
  keep going, or stop here?", and put "Explain it simply" under any card (file, table).

**Fix.** `lib/services/choices.dart` (`Choices.parse` reads every shape, drops "Other" and duplicates, at most 6;
`Choices.rule`). Card, reply check and `ask_user` all use it. `ChoicesCard` shows an optional question, a "Something
else" row, is live only until the user answers after it (then shows the pick), and selects only its own status. Prompt
and tool: 3-5 specific answers, most likely first, never "Other"; bot greetings suggest two or three. Follow-up taps
read lists of up to five. Tests: `test/build61_feedback_test.dart`.

## 3. "The usage limit count is too small and it runs out after little messages"
**Diagnosis (production numbers, read only, `ai_usage`, last 6 days).**
- One agent model call (source `agent`, alias `submac`): **avg 10,145 prompt tokens (median 8,066), 6,706 of them
  cached (66%), 239 output tokens.**
- Steps per user message: about 2.3 (10-24: 205 agent calls for 88 user messages) to 6.2 (10-23).
- Per user message: **~27,500 raw tokens** (10-24: 2.42M raw / 88 messages), but only **~4,800 weighted tokens** with the
  old allowance weights (input 0.3, cached 0.1, output 1: 425k weighted that day).
- Billing v2 (on since 2026-10-23) charges **raw** `prompt_tokens + completion_tokens` (ai-chat `costOf` →
  `usage_charge`, "Contract B: raw tokens, one price"), with no cache or input discount. The allowance before billing was
  weighted. So the same message costs **~5.7× more** of the allowance than it did, and the free 200,000/day lasts **about
  7 messages** (~40 with the old weighting).
- App side: no double counting found. Build-61 (Genkit) makes the same calls as build-60 plus at most one format-fix
  call when a card is malformed. Older app-side waste: side replies (a message sent while a task runs) sent the whole
  agent prompt (~7,000 prompt tokens each, 130 calls / 0.93M raw in 6 days); the "keep the user in the loop" nudge spent a
  step on a `say` line every six quiet steps; a markdown table or an unclosed card cost a whole extra model call.

**App fixes (no server change).**
- Side replies use the small prompt: ~620 tokens instead of ~4,070 for a fresh chat (test prints it); in real chats with
  history the saving is larger (the 7k average above).
- No more "keep the user in the loop" nudge (owner rule: the agent works quietly).
- `ReplySchema.repair`: a markdown table becomes a table card and a card left open is closed locally; the
  "Tidying the answer" call happens only for what the app cannot fix.
- Choices in any shape no longer trigger a fix call.

**Current limits (production, read 2026-10-24).** `billing.plans`: free 200,000/day, 5,000,000/month; weekly
200,000/day, 700,000 total, $1.25; monthly 250,000/day, 3,000,000 total, $4.99; payg $2 per 1M; monthly_plus inactive.
`ai_settings`: `input_weight` 0.3, `cached_weight` 0.1, `output_weight` 1 (used only by the old allowance and
`quota_tokens`), `billing_tokens_per_reply` 3700, `billing_bot_share` 0.5, `daily_cap_tokens` 500000 (old allowance).

**Proposed server change (not made, needs the owner).** Either
- A (recommended): charge billing in weighted tokens like the old allowance: in ai-chat `costOf`, pass
  `quotaOf(s, pt, ct, usage)` (already computed as `w`) to `usage_charge` instead of `pt + ct`. One message then costs
  ~4.8k instead of ~27.5k, and 200k/day lasts ~40 messages. Prices per "token" stay; the unit becomes weighted tokens.
- B: keep raw charging and raise the daily amounts about 5× (free 1,000,000/day; packages likewise), which changes
  what each package is worth.

## 4. "The app kinda lost the smoothness, it should provide maximum frame rate"
**Root causes.**
- The high refresh rate was asked for once, in `onCreate`, and only by mode id. Many phones drop an app back to 60 Hz
  after the background, a dialog or split screen.
- The sky's 40-second drift ran on a per-frame ticker forever: the whole screen, and every frosted blur over the sky,
  re-rendered at the full display rate even with nothing else moving.
- Each frosted piece (3 floating circles + 2-3 composer pieces) did its own backdrop read and blur.
- Streamed words notified every 40 ms while the reply reveals words every 90 ms; the whole chat screen
  (`HomeScreen` watched all of AppState), the follow-up row and every choices card rebuilt on each notify.

**Fixes.**
- `MainActivity.highRefresh()` before `super.onCreate`, on every resume and window focus, with `preferredDisplayModeId`
  and `preferredRefreshRate`.
- Sky drift steps on a 33 ms timer (30 steps/s, a few pixels a second, looks the same) and stops in the background or
  with Remove animations; other animations still run at the full rate.
- `BackdropGroup` + `BackdropFilter.grouped` for the floating circles and the composer pieces (one backdrop read per
  group).
- Stream notify every 80 ms; `HomeScreen`, the follow-up row and choices cards `select` only what they show.
- Impeller is stated explicitly in the manifest (`EnableImpeller=true`): Flutter 3.47 picks Vulkan or falls back to
  Impeller GLES, and has no shader-compile jank. Skia is deprecated on Android in 3.47 (the engine warns on the opt-out),
  so it is not the more stable choice. build-60 (Flutter 3.24.5) still ran Skia; the jank above predates both.

## Phone tests
See the PR description.
