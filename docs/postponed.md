# Postponed: pre-existing `flutter analyze` errors

Status: **postponed** (recorded 2026-11-24). Not caused by the Investigation work; they already fail
`flutter analyze` on `main`. CI (`analyze-test.yml`) only fails on **errors** (`--no-fatal-infos
--no-fatal-warnings`), so warnings/infos below do not break the build — the errors do.

Run to see the live list: `flutter analyze --no-fatal-infos --no-fatal-warnings`.
Last captured on `investigation/phase-1` after Phase 2: **79 issues** (0 in Investigation files).

## A. Bots feed refactor (half-finished) — biggest cluster

`lib/screens/bots/bot_chat_screen.dart`, `lib/screens/bots/bot_profile_sheet.dart`,
`lib/screens/bots/bots_feed_screen.dart`, `lib/widgets/bots/bot_feed_card.dart`.
These files reference names that no longer exist / were never moved:

- `BotProfileSheet` (undefined in `bot_chat_screen.dart`, `bots_feed_screen.dart`)
- `PresenceStateColors` (undefined, many lines)
- `MoodEngine`, `DigitalPerson`, `PresenceState` (undefined)
- bad relative import `bot_feed_card.dart` in `bot_profile_sheet.dart` / `bots_feed_screen.dart`
  (the file actually lives at `lib/widgets/bots/bot_feed_card.dart`)
- `ListViewState` used as a type argument; `BotChatScreen`/`BotFeedCard` undefined in `bots_feed_screen.dart`
- `String?` assigned to `String` (`bots_feed_screen.dart:351`)
- `bool` passed where `Color?` expected; `Palette` returned as `Color`; `context` undefined; `minWidth`
  named param unknown; `Color.faint` getter undefined (`bot_feed_card.dart`)

## B. `digital_human` services + test (unfinished)

`lib/services/digital_human/{heartbeat,memory,mood,person,registry,digital_human}.dart`,
`test/digital_human_test.dart`.

- `mood.dart`: `Color` not imported/undefined (no `material` import), `_level` uninitialized,
  `starting` is not a field
- `memory.dart`: `SharedPreferences.getStringMap`/`setStringMap` don't exist; named params not wrapped
  in `{}`; unused imports
- `heartbeat.dart`: `id` final field uninitialized; `_wake` undefined
- `person.dart`: named param `id` undefined
- `test/digital_human_test.dart`: named param `id` undefined, `Color` not a class, expected identifier

## C. Loose warnings / infos (non-fatal; safe to leave)

- `lib/screens/settings_screen.dart:286` — unused declaration `_PlanPage`
- `lib/state/agent_runner.dart:507` — unnecessary null comparison (pre-existing; not the Investigation line)
- `lib/widgets/composer.dart:1189` — unnecessary null-aware `?.`
- `lib/widgets/model_picker.dart:62` — unnecessary braces in interpolation
- `lib/services/web_tools.dart:324` — prefer collection literals
- `test/browser_speed_test.dart:3` — unnecessary import

## What to do when picked up

1. Decide whether the bots-feed and digital_human features are still wanted; if yes, finish the refactor
   (move/define the missing symbols, fix the import path); if not, delete the dead files and their tests.
2. Then re-run `flutter analyze` and clear the remaining warnings.
3. Only after this is `analyze` green on `main` will the Investigation branch show a green Check too.
