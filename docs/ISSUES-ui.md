# ISSUES-ui.md: luxury restyle, Dev 1 (UI worker)

Owned by the UI worker. `docs/ISSUES.md` belongs to the trust-fixes worker (`feature/trust-fixes`). Rules are in `RESTYLE.md` and `docs/ui-rules.md`.

Last updated 2026-10-23 20:45 EAT.

## Where the work is
- **Released (main dbf0cf6, v1.13.73+140, GitHub release build-51):** the luxury chat and Grok-style bots list from `feature/luxury-ui`.
- **Follow-up branch `feature/top-call`** (off main, v1.13.74+141; not merged, no release, per the owner's rule for changes that came in after the release started). It carries the owner's 20:04–20:34 EAT changes listed below. Code commit **9d90e00** (branch head), dev-check run **39998320167** (dispatched once). "Fixed on feature/top-call" below means fixed in 9d90e00.

## Issues

| ID | Screen | What the user sees | File(s) | Status | Suggested fix |
|---|---|---|---|---|---|
| UI-1 | Chat, top bar | No way to start a Telesia call from the top; it was hidden as a long press on the mic | lib/screens/home_screen.dart, lib/widgets/composer.dart | Fixed on feature/top-call. A Call icon (Telesia `phone` icon) sits before "+" in Telesia and bot chats. Mic tap = dictation only; long-press-mic call removed. Talk live stays in "+". | |
| UI-2 | Chat, activity | Three animated dots, a check glyph and chevrons beside status | lib/widgets/chat/activity.dart, composer.dart, message_view.dart | Fixed on feature/top-call. `StatusWord` is plain text only (InkText settle + Breath). | |
| UI-3 | Whole app | Buzz on taps, sends, streaming and blocks appearing | 21 files; new lib/ui/haptics.dart | Fixed on feature/top-call. Only `SubHaptics` remains: hold sheet, call connect/end, approval needed. Billing screens still buzz (not edited). | Monetization dev: swap to `SubHaptics` in lib/screens/billing/* |
| UI-4 | Whole app | Serif (Instrument Serif) on wordmark, headings, short messages, dialogs | lib/theme.dart (`Brand.display`, `Brand.serif` now maps to it), ask_bar.dart | Fixed on feature/top-call. One bold sans (Geist 600) for display. The serif stays only in documents Telesia makes (doc_maker, media_coder). | |
| UI-5 | Chat outputs | Boxes and lines: composer outline, dark code slab, table row lines, ALL-CAPS table head, attachment/page outlines, link pill borders, check ring, blockquote bar, rule line | composer.dart, markdown_view.dart, output_cards.dart, message_view.dart, chat/document_tile.dart | Fixed on feature/top-call | |
| UI-6 | Bots, sidebar | Avatar ring, presence-dot ring, listening ring around faces, search field borders, long labels | bots_screen.dart, bot_face.dart, bot_list.dart, sidebar.dart, services/bots.dart | Fixed on feature/top-call. Labels shortened: "Worked 08:02 · next 18:00", "on request", "· may pause", "Search". | |
| UI-7 | Call | Old call: glowing filled orb, italic serif status, Material buttons, "Captions" | lib/screens/live_screen.dart (new `CallView`), bots_screen.dart (incoming call) | Fixed on feature/top-call. Two styles: Telesia call (mark alone) and bot call (face, name, role). Controls are Telesia icons over one word (Mute / Again / End). Screenshots: /workspace/work/luxury-ui/v2/v2_call_*.png | |
| UI-8 | Motion | Generic fades, spring overshoots | new lib/ui/motion.dart (`SubMotion`, `InkText`, `Breath`, `SendSettle`, `SubPageTransitions`); motion.dart, entrance.dart, tokens.dart | Fixed on feature/top-call. Pages, the hold sheet, list reveal (sidebar, bots page), send and status all use it. | Apply `SubMotion.sheet` to every other `showModalBottomSheet` (about 30 call sites) |
| UI-9 | Theme | Filled ink buttons, outlined buttons, outlined fields, chip outlines, ink snackbar pill, drag handle, card surfaces | lib/theme.dart | Fixed on feature/top-call. Buttons are bold words, fields are a tone with no outline, chips have tone only, snackbar is plain words, sheets have no handle, cards are transparent. | Check on a phone that the main buttons on sign-in still read as buttons |
| UI-10 | QA | The other developer's `qa-emulator` flow taps the old resting chat pill, which no longer exists | their branch `qa-emulator` | Open (not ours to edit) | Their owner updates the flow to the top-bar Call / "+" |
| UI-11 | Floating task chat (native) | Android bubble/overlay layouts still use pill/box drawables | android_native/res/drawable/telesia_widget_pill.xml, telesia_widget_bg.xml, TaskBubble.kt, Overlay.kt | Open | Restyle the native drawables (no stroke, tone only) |
| UI-12 | Approval / sign-in cards in chat | `_VerifiedCard` (accent wash), ask_bar cards, approval_card still have fills | message_view.dart (~l.426), widgets/ask_bar.dart, widgets/approval_card.dart | Open | Remove fill and border, use a bold title and spacing |

## What's left, per screen (for the next run)
Done on feature/top-call: chat screen, composer, outputs (text, document, file, media frame, table, code, plan check), sidebar, bots page, incoming bot call, call screen (both styles), theme defaults, haptics app-wide (except billing), motion set.

Still in the old style, file by file (theme defaults already reach them, but local boxes, borders and serif-era sizes remain):
- Settings: lib/screens/settings_screen.dart. Check local Containers and borders; App update screen inside it.
- Onboarding / sign-in: lib/screens/auth_screen.dart.
- Profile / bot profile and job: lib/screens/bot_job_screen.dart, bot_setup_screens.dart, bot_activity_screen.dart, hire_screen.dart, bot_store_screen.dart.
- Skills and library: lib/screens/skills_screen.dart, skill_library_screen.dart, library_screen.dart, files_screen.dart.
- Apps and connections: lib/screens/connectors_screen.dart, logins_screen.dart, whatsapp_screen.dart.
- Inbox and notifications: lib/screens/inbox_screen.dart, approvals_screen.dart, today_screen.dart.
- Projects, memory, sites, system: projects_screen.dart, memory_screen.dart, site_screens.dart, system_screens.dart, preview_screen.dart, offices_screen.dart (teams), widgets/team_parts.dart.
- Shared widgets: widgets/rich_cards.dart, hark_cards.dart, graph_card.dart, data_viz.dart, diagram_card.dart, meeting_sheet.dart, save_sheet.dart, pill_kit.dart, audio_card.dart, update_window.dart, browser_layer.dart, chat_extras.dart, ask_bar.dart, approval_card.dart.
- Floating task chat (native Android): see UI-11.
- Dialogs, sheets and empty/error states: the theme covers the defaults. Sheets built by hand with their own Container fill or border still need a pass (grep `Border.all(` and `BoxDecoration(color:` in lib/, excluding billing).

Needs the monetization dev (not edited by us): lib/screens/billing/* (get_more_screen, pay_screen, payment_screen, billing_widgets incl. `WalletChip`), plus any allowance, pricing, coins or rewards UI. They still have their own haptics, boxes and serif-era sizes. The shared theme reaches them.

Not done anywhere yet: real-phone check (60 fps, keyboard, RTL), Somali strings for the new short labels (none of the changed labels were in lib/ui/i18n.dart).
