# RESTYLE.md — Telesia luxury redesign (owner plan, 2026-10-23)

Two developers share this. Each owns its own branch and files. Refetch and 3-way merge before every push. Never change the other's branch. Do not touch billing, allowance, pricing, coins, rewards or monetization code (including bot-slot limits).

## UI rules (whole app, binding)
- Quiet, spacious, minimal, luxury (Hark.com feel).
- No boxes, containers, cards or inline borders. Every element stands on its own, using space, type weight and soft tone.
- Short words, few symbols.
- Action buttons stay hidden until a tap or a hold.
- Agent status is plain text only ("Thinking", "Working"), with no dots or icons.
- Icons come from Telesia's own icon family only.
- Display text uses a bold sans; body text uses the reading sans. No serif.
- Haptics are minimal: one light tick for a hold, a call connecting, or an error. Never during streaming, scrolling or items appearing.
- Motion comes from the shared Telesia set in `lib/ui/motion.dart` (named curves and durations). It must keep 60 fps and respect reduce-motion. No generic fades.

## Dev 1 (Hark): branch `feature/luxury-ui`
1. Chat screen: the top shows the Telesia name, then Call, then +. Then the message stream, then the input with +, text, mic (dictation) and send/stop.
2. Output pieces: text, document, file, media, report, chart, code, table and plan. They stand alone with no boxes.
3. The rules above applied to chat, sidebar and the bots list: fonts, borders, haptics and motion.
4. Call UI redesign, in two styles: the Telesia call and the bot call.
5. **Whole app.** No screen keeps the old style: settings, onboarding and sign-in, profile, skills, apps, app update, floating task chat, inbox, dialogs, sheets, snackbars, and empty and error states. The app theme itself also follows the rules. Billing, wallet and coins screens are left to the monetization developer.
6. Merge to main and build one signed release APK. Delete Actions artifacts older than the release day.

## Dev 2: branch `feature/grok-bots`, created from `feature/luxury-ui` (or from main after Dev 1's merge)
Goal: bots behave like Grok, in Telesia's brand. Reference: `docs/ui-grok-reference.md`.
1. **A ready Chief bot.** Every user starts with one Chief bot, already set up. The user can make any bot the Chief.
2. **The Chief creates bots.** The user asks the Chief, in chat, for a new bot ("make me a sales bot"). The Chief drafts the name, role, instructions and skills, shows it quietly for a yes, and then creates it.
3. **Teams from the sidebar.** In the sidebar, under the bot profiles, the user creates a group or team, picks its bots and picks a lead (the Chief).
4. **How a team works, Grok-style.** The user writes to the team. The Chief splits the job and hands parts to members. Members' progress shows as short plain-text lines. The Chief returns one combined answer, and each member's part opens on tap.
5. **Sidebar.** Sections for Chief, Bots and Teams, each foldable, with search. Tap a bot to open it; hold for Message, Call or Profile.
6. Use Dev 1's chat components, motion set and UI rules. Add no new boxes or borders.
7. Keep the existing team launch flag and the bot limits exactly as they are (monetization owns them).

## Merge order
1. Dev 1 merges `feature/luxury-ui` to main and releases.
2. Dev 2 rebases or merges onto the new main, passes analyze, tests and dev-check, then the owner approves the merge to main.
3. Bump the version above the highest build on any branch, in both `pubspec.yaml` and `AppConfig.version`.

## Known conflict
The `qa-emulator` QA flow taps the old resting chat pill, which no longer exists. Its owner needs to update the flow.
