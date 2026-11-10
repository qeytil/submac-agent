# Telesia UI rules (binding, whole app)

Set by the owner on 2026-10-23. Every developer follows these. The shared plan is in `RESTYLE.md`, and open items are in `docs/ISSUES-ui.md`.

## Look
- Quiet, spacious, minimal, luxury (Hark.com feel).
- **No boxes, containers, cards or inline borders/outlines.** Every element stands on its own. Separate things with space, type weight and a soft tone, never with a frame or a line. No table row lines, no outlined fields, chips, pills or buttons, no avatar or presence rings, no dark code slab.
- **Short words, few symbols.** One word where one word works ("Search", "Again", "End"). No decorative glyphs or chevrons where the words already say it.
- Action buttons stay hidden until a tap or a hold.
- **Agent status is plain text only** ("Thinking", "Working", "Listening"), with no dots, icons or glyphs before it. The only animation allowed is a gentle text breath (`StatusWord`).
- **Icons come from Telesia's own family** (`SubIcon`, `assets/icons/*.svg`: fine ink strokes). No Material default icon where a Telesia icon exists. Add a new SVG in the same stroke rather than using a Material one.
- **Type:** one bold display sans (`Brand.display`: Geist 600, tight tracking) for the wordmark, titles, headings, short messages of yours and call names. The reading sans (Geist) is for body text. No serif in the UI (documents Telesia makes may use one). `Brand.serif` is a legacy alias of `Brand.display`.
- One accent, the brand red, used only for danger, errors and End.

## Haptics (`lib/ui/haptics.dart`)
Almost silent: one light tick at most, and only for a hold that opens actions (`SubHaptics.hold`), a call connecting or ending (`SubHaptics.call`), Telesia needing you (`SubHaptics.attention`) or an error you must notice (`SubHaptics.error`). Never on taps, sends, streaming, scrolling or items appearing. Don't call `HapticFeedback` directly.

## Motion (`lib/ui/motion.dart`)
One signature set, used everywhere. Never ad-hoc durations or curves.
- **Curves:** `SubMotion.settle` (quick start, soft rest, never overshoots), `SubMotion.ink` (for words), `SubMotion.leave` (quiet exit).
- **Durations:** tick 120, quick 180, base 280, enter 480, page 420, sheet 360/220 ms; breath 2.4 s; stagger 60 ms, capped at 360 ms.
- **Pieces:**
  - `InkText`: words settle in, with letter spacing closing from slightly open while they fade in (status, changing titles).
  - `Entrance` / `revealRows`: blocks and list rows rise 8 px and settle, staggered (chat outputs, sidebar, bots page).
  - `Breath`: the calm opacity breath of the status word.
  - `SendSettle` / `SendIn`: your message lands with a 14 px rise and a 3 % settle.
  - `SubMotion.sheet`: the quiet reveal for tap/hold action sheets (`sheetAnimationStyle`).
  - `SubPageTransitions`: screens fade up a touch and settle (set in the theme).
- **Paint, not layout:** animate opacity, small offsets and tiny scales only, inside a RepaintBoundary, for 60 fps.
- **Reduce motion wins:** with the system setting on, everything simply appears.

## Theme defaults (`lib/theme.dart`)
Buttons are bold words, not filled or outlined blocks. Fields are a whisper of tone with no outline, even when focused. Chips use tone only. Dividers are space. Sheets and dialogs use the page colour, with no handle and no shadow line. Snackbars are plain words. Cards are transparent. Build new screens on these defaults instead of overriding them.

## Not ours
Billing, allowance, pricing, coins, rewards and wallet screens belong to the monetization developer. Don't edit their files; the shared theme reaches them.
