# Motion audit (v1.13.87+154, 2026-10-24)

Owner request (10:34 +0330): "All the app have many animation glitches so findout and fix."
Every screen and transition was read for jank, mismatched timing, double animations, layout jumps, leaks and
reduced-motion gaps. One rule now holds everywhere: timings and curves come from `SubMotion` (lib/ui/motion.dart,
also reached through `LuxMotion` in lib/ui/tokens.dart). `test/motion_guard_test.dart` keeps it that way.

## Found and fixed

| # | Where | Glitch | Fix |
|---|-------|--------|-----|
| 1 | Expand/collapse everywhere: steps fold and tool details (message_view), "How I did it" (chat_extras), browser checklist (composer), approval "Show details" (home), error details | `AnimatedSize` around `open ? content : SizedBox()`: the content vanished at once on close and the gap closed after it (a jump); on open it popped in at full opacity while the box grew | New `SubFold` (ui/motion.dart): one controller drives clipped height and fade together, content stays built while it folds, nothing is built when folded, instant with Remove animations |
| 2 | Reply action row (Copy, Share…) under answers and your messages | `Entrance` fade+rise inside a growing `AnimatedSize` (opacity and size fighting), vanished at once on close | `SubFold` |
| 3 | Working line at the top of a turn | Vanished, then its space closed | `SubFold` |
| 4 | Chat screen: loading → greeting → chat | Default `AnimatedSwitcher` centred each child in a loose box, so the greeting and list jumped while crossing; linear curve; ignored Remove animations | Full-size `fillLayout`, settle in / leave out, `SubMotion.of` |
| 5 | Card being written → finished card (reply_blocks) | Box kept the taller child's height until the fade ended, then snapped | `AnimatedSize` eases the height while the two cross-fade |
| 6 | Turn head switcher, choice tick, composer send/mic, avatar previews | Mixed curves, no out curve, tick scaled from 0 (popped from a dot), ignored Remove animations | Shared curves, small 0.85→1 settle, `SubMotion.of` |
| 7 | Jump-to-newest button | Fade 180 ms linear vs slide 220 ms eased | One duration and curve |
| 8 | Answered cards sliding away (`Leaving`) | Fold, slide and fade on three different curves (faded before it moved) | One `leave` curve, shared `leaveCard` duration |
| 9 | Bottom sheets (45 of 50) | Default sheet motion; only 5 used Telesia's | All non-billing sheets use `SubMotion.sheet` |
| 10 | List reveals: rich cards (up to 26 rows × 70 ms), quick replies, choices, projects, files, sidebar projects | Uncapped staggers (the last row arrived ~1.8 s late) | `SubMotion.staggerFor` (capped at 360 ms) |
| 11 | Two entrance animations | `FadeSlideIn` was a second copy of `Entrance` with its own scale and an uncancelled delay timer | `FadeSlideIn` now uses `Entrance` (timer cancelled on dispose, RepaintBoundary) |
| 12 | Diagrams | Draw time grew with item count (a long timeline took ~2.8 s) | `SubMotion.drawIn` keeps it between 480 ms and 1.1 s |
| 13 | Graph full-screen route | New `CurvedAnimation` on every rebuild (listener pile-up), raw timing, ignored Remove animations | Driven tween, `SubMotion.page` / `sheetOut`, instant when still |
| 14 | Switching light/dark look | Theme faded 200 ms linear while the sky's veils switched at once | `themeAnimationDuration/Curve` = base/settle; sky veils cross-fade on the same beat |
| 15 | Sky | Picture repainted every frame of the 40 s drift; first frame blank before the picture decoded; night picture half-decoded at dusk | Drifting picture in its own layer; both pictures precached |
| 16 | Pictures (favicons, link previews, files, library, cards) | Popped in when loaded | Shared `subImageFade` frame builder |
| 17 | Raw timings in Pressable, Expandable, DoneTick, shimmers, progress bar, call banner, send button, pills, image box, audio button, team activity, site screens, bot setup | Each had its own `Duration`/`Curves`, several ignored Remove animations (Expandable chevron, call banner, folds) | `SubMotion` tokens + `SubMotion.of` |
| 18 | Audio card | Leaving while the player was starting ran `setState` and started timers on a disposed card | `mounted` check before starting |
| 19 | Meeting recorder | Closing the sheet while the mic started left a 1 s timer calling `setState` after dispose | `mounted` checks; timer guarded |
| 20 | MCP server "Test" | `setState` after the screen closed | `mounted` checks |
| 21 | MCP edit screen, About-you screen | Text controllers never disposed | Disposed |

Checked and fine: keyboard insets (no animated padding fighting the keyboard), drawer section fold (already one
controller), page transition (driven tweens, underneath page fades out), tabs, the greeting (fades once, reduced
motion respected), streaming text, controllers in the rest of the app.

## Guards

`test/motion_guard_test.dart`:
* no `Curves.` and no raw `Duration(...)` given to an animation in lib/screens, lib/widgets, lib/main.dart, lib/theme.dart
  (billing screens excluded by owner rule; timeouts, timers and snack bars are not motion);
* every bottom sheet uses `SubMotion.sheet`;
* `SubFold` keeps its content while folding and is instant with Remove animations;
* diagram draw time is capped; pictures fade in only while loading.

## Not changed

* Dialogs (`showDialog`) keep Flutter's default fade: Flutter 3.24 has no per-call animation style for them.
* Billing screens (owner rule).
* `logo.dart` loop periods (idle/thinking/working marks) are their own rhythm, not transitions.

## Owner additions (10:56 +0330)

* **Chat header**: the solid bar is gone. Menu, Call and "+" float on their own in small blurred circles
  (`ChatFloatBar` / `FloatIcon` in home_screen.dart), below the status bar, mirrored in right-to-left. The chat list
  scrolls full height behind them with a top inset of status bar + `chatFloatHeight`, so nothing is hidden; the list
  still rests on the newest message. The old header's hold actions moved to the menu button (hold: a bot's profile in
  its chat, otherwise this chat's options, or today's allowance on a new chat). Tests: `test/chat_float_test.dart`.
* **Sky on any screen**: the app now draws edge to edge (behind the status and navigation bars, which are see-through),
  so the sky fills tall phones to the bottom. The picture is `BoxFit.cover` at the screen's own size (turned on wide
  screens), and the drift's zoom always exceeds its shift (`skyDrift` / `skyCovers` in main.dart), so no edge shows at any
  frame, size, shape or rotation. Tests cover 1080×2640, 1080×2400, 390×844, 1600×2560, 2560×1600 and 2208×1768, each
  through a full drift loop and again after turning the screen.
