# Bots workspace (v1.13.93+160, owner spec 2026-10-24)

One Grok-style screen for every bot and team: `lib/screens/bots_workspace.dart` (`BotsWorkspace`).

## What the owner asked for
- Tapping **Bots** in the main menu opens the workspace on the **Chief's chat** (same messages, cards and composer as the main chat).
- **No header bar** in bot or team chats. Only floating blurred circles: rail toggle (start side), Call and "+" (end side). Messages scroll behind them; the list keeps a top inset.
- Who you're talking to: the rail's soft highlight, and in an empty chat the greeting (face, name, role line). Teams: lead's face, team name, "Led by …".
- A thin **rail** (`Lux.railWidth` = 84 dp), folded by default, slides over the start edge with no scrim: Chief first (crown), other bots (pinned first, then latest activity), Teams, a small "+", and **New bot** / **Bot store** pinned at the foot. RTL mirrored.
- Tapping a head **swaps the chat in place** (no route push): the conversation cross-fades, the bot composer stays, each chat keeps its draft (`Composer(perChatDrafts: true)`, `TeamChat.drafts`) and scroll position (`ChatList(convId:)`, `ChatList.offsets`).
- The rail folds when the composer takes the cursor / the keyboard opens, on a tap on the chat, or on the toggle. Back folds an open rail first, then leaves to the chat you came from (`backFromBotChat`).
- Long-press a head: Profile, Edit, Pin/Unpin, Look, Call, Make Chief (bots); Tasks, Bots, Team folder, check now, modes, Pin (teams).
- **Status ring** on every head (`lib/widgets/status_ring.dart`, `lib/services/bot_status.dart`): green working, yellow waiting for the owner's OK, blue finished with unread results, grey idle. Colours are theme tokens (`Palette.statusWorking/Waiting/Done/Idle`). Only the working ring moves (a turning arc, transform only); static under reduced motion. Unread clears when that chat is opened.

## One entry point
- `BotsScreen` and `OfficeScreen(officeId:)` are now thin redirects to `BotsWorkspace` (deep links, notifications and shares keep working).
- `openBotChat` opens the workspace on that bot. The menu shows one "Bots" entry; search still lists matching bots/teams.
- Team tasks and team bots/settings moved to their own pages (`TeamTasksScreen`, `TeamPeopleScreen`), reached from the team's "+" or long press.

## Motion
- Rail: `SlideTransition` + `FadeTransition` on one `AnimationController` (LuxMotion.base in, SubMotion.quick out), inside a RepaintBoundary; the chat never relays out. Folded, the rail stays built (`Offstage` + `TickerMode` off) so its faces are ready.
- Swap: one `AnimatedSwitcher` cross-fade (`SubMotion.fillLayout`). An outgoing chat keeps its own messages while it fades (no flash of the new chat). Bot chats already in memory open at once and refresh quietly (`openConversation` warm path).
- Rings tell listeners only when a ring changes, never during a frame build.

## Status sources and limits
- Working: `Bots.presenceOf` (runs in the bot's chat or team jobs); team: `TeamRun.busy` or any member working.
- Waiting: `Offices.pending` approvals (by bot / by team) and a lead's plan waiting for "Start".
- Done: a bot/team that stopped working while its chat was not on screen (kept on the phone), plus a team's own unread posts. Work finished while the app was closed is not detected for bots (no unread marker in the bot's chat data).
- Pins are kept on the phone only (`bots_rail_pins`); they do not sync between phones.

Tests: `test/bots_workspace_test.dart`.

## v1.13.95+165: smooth rail, floating header

Owner: the rail's open/close looked glitchy, and the bot/team header was too big and solid.

Root causes of the rail glitch (all in `lib/screens/bots_workspace.dart`, fixed in `RailLayer`):

1. **Blur inside a fade.** The rail's `BackdropFilter` sat inside a `FadeTransition`. A backdrop blur inside an opacity layer samples the empty fade layer instead of the chat, so the glass moved without blur and the blur popped in on the last frame (and vanished on the first frame of folding). Now the glass only slides; only the heads and labels inside it fade (`RailFade`).
2. **Whole-screen rebuilds at the ends of the motion.** Opening set `_open` with `setState`, and the controller's status listener set `_railShown` with another `setState`, so the chat, its list and the composer rebuilt on the first and last frames. The flag is now a `ValueNotifier`; only the rail layer, the toggle's label and the Back guard listen.
3. **Repaint boundary outside the slide.** The whole rail (list, rings, blur) re-recorded every frame. The boundary is now inside the moving transform.
4. **Two motions.** Open used 280 ms on `settle`, fold 180 ms on `leave`. Now one LuxMotion duration, with the curve mirrored on the way back.
5. **Keyboard snap-shut.** `_KeyboardWatch` folded the rail on every frame the keyboard showed at all. Tapping the toggle with the keyboard up (which puts the keyboard away) opened the rail and closed it again a frame later. It now folds only while the keyboard is coming up.

The chat never relays out: the rail is a fixed-width overlay (84 dp, same soft edge and Telesia mark). Reduced motion jumps straight to the end; RTL slides in from the right.

Header: the same as the main Telesia chat. No band. The rail toggle, Call and "+" are blurred circles (`FloatIcon`). Who you're talking to is a light blurred pill (`FrostedSurface`) with a 22 dp face in its tiny status ring and the name. The chat scrolls behind it and fades at the top edge (`ChatEdgeFade`). It swaps in place on chat switch. Its height is still `chatTopInset`.

Known limit: opening the rail while the keyboard is up still lets the Scaffold resize the chat as the keyboard goes down. That is the keyboard moving, not the rail.
