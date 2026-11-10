# Telesia: screen audit (plan 5.6), dev v1.13.0+33

Read-only audit. No files in the repo were changed. Every finding below was checked against the code in `/workspace/work/repo`. Line numbers are for that copy.

**Severity:** **High** means broken, a crash, or a leftover from the removed key/model setup that users run into. **Med** means confusing UI, jargon, or a setting that plan 5.3/5.4 says to remove or move. **Low** means cleanup.

**Headline:** no code path still reads a user's own model key. `ProviderConfig` has no key field (models.dart:166-181). Every route goes through `Cloud.provider` (app_state.dart:73-93). Old keys are wiped once on launch (`_forgetOldModelSetup`, app_state.dart:2750-2756, called at :1962; local_store.dart:27-39). What remains of the key/model setup is wording in the Offices screen and dead branches in app_state.

---

## widgets/sidebar.dart (main navigation)
- **Low**: L111-173: nine nav items (New chat, Bots, Offices, Skills, Apps, Library, Files, Scheduled, Archived chats). Plan 5.1 cuts this to Today · Team · Apps · Files.
- **Low**: L82: chat search always drops archived chats (`!c.archived`), so search can't find them. Archived chats are reachable from two places: here (L167-173) and Settings › Your data (settings_screen.dart:324-327). Plan 5.1 makes "archived" a search filter instead.

## screens/home_screen.dart
- **Med**: L172-176: on a new chat, the top-right button is a bare red dot whose only label is the tooltip "Skills", and it opens Skills. There is no icon or label, so its purpose is unclear. Plan 5.1 also takes Skills out of the main navigation.
- **Med**: L505-524: Easy mode tile grid on the empty chat. Plan 5.3 removes Easy mode. When it is on, the same skills also appear as chips (L196, L565-610).
- **Med**: L647-666 (used at L683, L725): the "Auto compacted" divider in chat. Plan 5.3 removes it.
- **Med**: L255-273: the "Needs your OK" sheet's **Show details** prints the raw request in monospace. Its sources:
  - for MCP actions: the tool name plus indented JSON arguments (app_state.dart:2589-2593);
  - for connectors: `METHOD path` plus a JSON body (app_state.dart:2608-2612, 2617-2621);
  - for files: shell commands (tools.dart:245-250).
- **Low**: L196: `state.providers.isNotEmpty` is always true, because `providers => [Cloud.provider]` (app_state.dart:73). This guard is left over from the old key setup.
- **Low**: L205-224: `_MenuGlyph` is never used.

## widgets/composer.dart
- **Low**: L117-123 (`_camera`), L211-224 (`_pick`) and L145-147 (`_toggleDictation`) call `setState` after an `await` without checking `mounted`. In release builds this only logs.
- **Low**: L287-297: the "Let it take action" switch is in the + menu and also in Settings (settings_screen.dart:242-247). Plan 5.4 folds this into a single Phone access page.
- **Low**: L360 and L466-471: the Live pill shows even when the proxy has Live turned off. Tapping it only shows a snackbar (live_screen.dart:28-33).

## screens/settings_screen.dart
- **Med**: L357-362: **Show working steps** switch. Plan 5.3 removes it.
- **Med**: L363-374: **Steps per task** slider, range 5-100. Plan 5.3 removes it, and it is jargon. The assistant's `app_settings` tool uses a different range, 4-40 (system_tools.dart:357, 430-433).
- **Med**: L375-386: **Size limit per task**, shown as "150k", which is a token budget. Plan 5.3 removes it.
- **Med**: L387-393: **Workspace folder** shows a raw file path in monospace. Plan 5.3 removes it.
- **Med**: L316-321: **Easy mode** switch. Plan 5.3 removes it.
- **Med**: L328-332: **Trash** is under "Your data". Plan 5.3 moves it into Files.
- **Med**: L205-213: **Memory** is in Settings. Plan 5.4 moves it to the profile as "What Telesia knows about you".
- **Med**: L284-288: **Saved logins** is in Settings. Plan 5.4 moves it to Apps as "Websites I can sign in to".
- **Med**: L289-295: **Telegram** is in Settings. Plan 5.4 moves it to Apps. Its screen asks the user to paste a "Bot token" from BotFather (extras_screens.dart:77-85).
- **Med**: Plan 5.4 says these belong on one page each, but they are still separate tiles:
  - Phone access items: L242-247, L256-263 and L270-274;
  - Voice items: L229-234 and L235-239.
- **Med**: L394-398: **Delete account** only appears after tapping "Show advanced". It is hard to find and belongs in the Account section.
- **Med**: L453-455: the Privacy screen has a heading "Passwords and keys" and says "tokens for apps you connect". Both are jargon.
- **Low**: L277-281: the "Apps and connectors" subtitle only counts `mcpServers`. A user whose apps are connected with keys (`ConnectorCatalog.connected`) still sees "Gmail, Calendar, GitHub, Notion and more".
- **Low**: L552-558: Trash restore shows the raw exception, "Could not restore: $err".
- **Low**: L626 and L640: the instructions screen is titled "Custom instructions" and refers to "the assistant", but the tile that opens it says "About you and reply style".

## screens/connectors_screen.dart (Apps)
- **High**: L499-502: the **Test connection** button stays disabled while the user types a link for a new tool server.
  - Cause: its `onPressed` checks `_url.text.trim().isEmpty`, but the URL field (L475) has no `onChanged` and nothing rebuilds the screen.
  - It only turns on after another control, such as the switch, triggers a rebuild.
- **Med**: L29 of services/mcp_oauth.dart: Zapier is the first preset in the "Everything" category. On the default "Sign in" tab it is the first app a new user sees, under "Many apps at once" (L125-136), and it also shows in All. Plan 5.3 takes Zapier off the featured list.
- **Med**: L16-17 and L87-88: the Apps screen still says "Connect your apps with your own key… Keys are encrypted and stay on this phone."
- **Med**: L97-108 and L149-196: the "Any API" sheet uses developer terms: "Base link", "Key header", "Before the key" with a default of `Bearer `, and "Key".
- **Med**: L103-108, L439, L458 and L474-487: "Tool server", "MCP tool server", "Key header (optional)", "Key value", "Bearer …".
- **Med**: L425-428: shows "Connected: N tools ready." and the raw exception "Could not connect: $e". It also calls `setState` after an `await` without checking `mounted`.
- **Med**: L185: if the link doesn't start with `http`, saving "Any API" closes the sheet and does nothing, with no message.
- **Low**: L14, L390-402, L455-469 and L482-486: Composio code is still here, though plan 4 dropped Composio. No caller passes `composio: true`. It is only reachable for an existing server whose URL contains composio.dev.

## screens/bot_setup_screens.dart
- **Med**: L77-87: the **MCP servers** tile in bot setup. `BotAppsScreen` for kind `mcp` also has:
  - "Add by address" / "An MCP server's https address" (L454-460);
  - "Add an MCP server" (L479-499);
  - "MCP servers" / "Add a server" (L558, L566).

  Plan 5.3 removes adding MCP servers inside a bot.
- **Med**: L348-367, L385 and L409: the **"Add your <app> key"** dialog and "Add key" button. This also shows in the "Connect <bot>'s apps" sheet right after hiring from the Bot Store (bot_store_screen.dart:284-287). Plan 5.3 removes it.
- **Med**: L394 and L508-546: shows "uses N tools", and the tool picker lists raw server tool names to tick ("${b.name} uses all N tools").
- **Low**: L267-280: the label "Knowledge sandbox" is jargon.

## screens/bots_screen.dart
- **Med**: L556: the "What <bot> may use" section uses blurbs from services/bot_powers.dart:32-33: "Run code, read and write files" and "Email, GitHub, Notion, MCP servers…".
- **Low**: L525-534: bot voices are a hard-coded list of Gemini voice names. Settings reads the voices from the proxy (`Cloud.features.value.voices`, settings_screen.dart:101), so the two lists can drift apart.
- **Low**: L144-151 and L535-543: "Full-screen calls" sits on the Bots list, and "can call me" sits in each bot's settings. Plan 5.2 puts both in one Calls setting.

## screens/bot_activity_screen.dart
- **Med**: L54-56, L96 and L201-229: activity and daily budget are shown in tokens ("Today: 12k tokens", "50k tokens" … "3M tokens").
- **Med**: L102-113: each step shows the raw tool name, timings in ms, and raw JSON input in monospace. Plan 5.2 hides these behind "How did you do it?".

## screens/bot_store_screen.dart
- **Low**: L204-208: tapping a card waits on a network fetch (`BotStore.I.package`) with no loading indicator.

## screens/offices_screen.dart
- **High**: L154: when an office fails to set up, the user is told "Couldn't set up the office. **Check your model** and connection." Users can no longer pick a model.
- **High**: L366: the office header says "**On hold: out of model credit**". This shows when the daily allowance runs out (`failure == 'credit'`, app_state.dart:970-973). The rest of the app calls this "resting".
- **Med**: L1354-1366: "Team usage today" lists each bot's usage as "N tokens of M".
- **Low**: L278-282: `_create` calls `setState(() => _busy = false)` after an `await` without checking `mounted`.
- **Low**: L397: the office has five tabs: Chat/Board/Docs/Team/Settings. Plan 5.2 drops Board and Docs.

## screens/live_screen.dart (+ services/live_session.dart)
- **High**: live_session.dart:364-367: when a call drops, it says "**Tap to call again.**", but nothing on the Live screen can be tapped to do that.
  - The orb (live_screen.dart ~L187-214) has no gesture handler.
  - Mute is disabled on error (L218).
  - Only End works.
- **Med**: live_session.dart:89 and :366-367: raw errors reach the user ("Connection problem: $e", "The call dropped ($reason)").
- **Low**: live_controller.dart:52 and :227, app_state.dart:716-719: the "voice not available" result is still named `'needs_key'`, a leftover from the key setup.

## screens/extras_screens.dart (Telegram)
- **Low**: L9: the doc comment above `TelegramScreen` is stale ("What the AI has used: tokens per model…").
- (The token wording and its placement are counted under Settings.)

## screens/files_screen.dart
- **Med**: L130-132: if Move to Trash fails, the snackbar shows the tool's raw "Error: …" text.
- **Low**: L195-201: the "Back to …" row uses the `send` icon.
- **Low**: L119-125: "Copy location" copies an internal app path.

## screens/projects_screen.dart
- **Med (crash risk)**: L204: `f.lengthSync()` runs in `build`. If a project file is removed, for example with Files › Move to Trash, the next rebuild throws `FileSystemException` and shows the red error screen. Files does guard this with a try/catch (files_screen.dart:216-220).
- **Med**: L196-206: project files are listed, but a row can't be opened, shared or removed. The rows do nothing.
- **Low**: L98-111: renaming accepts an empty name.

## screens/library_screen.dart
- **Low**: L87-100: the empty state has no pull-to-refresh. L69-75: "Move to Trash" has no confirmation and reports nothing if it fails.

## screens/system_screens.dart
- **Low**: L98-99 and L121: `_say` uses `context` after an `await` without checking `mounted`.
- **Low**: L303-312: there is a second "Tell me when a task is done" switch, also in Settings (settings_screen.dart:264-269), with a different subtitle.

## screens/skill_library_screen.dart
- **Low**: L190-191: choosing "Give to a bot" for a bot that already has the skill silently does nothing.

## screens/skills_screen.dart, memory_screen.dart, logins_screen.dart, auth_screen.dart, preview_screen.dart
- No dead buttons, key leftovers or clear crash risks found. Where Memory and Saved logins sit is covered under Settings. `SkillsCatalog.byId(...)!` (skills_screen.dart:60, home_screen.dart:470/571) is safe today: all the ids exist in the catalog.

## Leftovers from the key/model setup in app_state and services (none read a user key)
- **Low**: app_state.dart has dead branches that can't change anything:
  - L78 `autoMode` is always true, yet these lines still branch on it: L3055, L3122, L3560, L3812, L3818, L4203.
  - L96 `usableProvider`, L99 `_badModels`, L101 `autoProblem` (always null, read at L3821), L2507-2508 `resolveModelHint` (always 'auto').
  - L4333 `_backupFor` always returns null, so the backup loop at L4345-4359 is dead. That loop sets "Trying <provider> instead" and a banner naming models.
- **Low**: app_state.dart:4529-4530: tool label `add_provider` → "Saving your provider".
- **Low**: app_state.dart:1939-1944: the vision-model regex lists vendor model names. Only `telesia-*` matters now.
- **Low**: system_tools.dart:33: the `app_settings` description still mentions "API keys". L351/356/357 still let the assistant change `easy_mode`, `show_steps` and `max_steps`; these should be removed together with the UI.

---

## Top 10 fixes, in priority order
1. **Live "Tap to call again" does nothing** (live_session.dart:366 / live_screen.dart): make the orb or a button restart the call, or change the wording. Also make raw connection errors friendly.
2. **Offices model wording** (offices_screen.dart:154, :366): change it to the allowance language ("resting until tomorrow") and drop "model".
3. **Dead "Test connection" button** (connectors_screen.dart:475/500): add `onChanged: (_) => setState(() {})` to the URL field.
4. **Settings cleanup per plan 5.3**: remove Show working steps, Steps per task, Size limit, Workspace folder and Easy mode, both the UI and the `app_settings` keys. Move Delete account out of Advanced into Account.
5. **Chat jargon**: remove the "Auto compacted" divider. Replace "Show details" in the approval sheet (raw JSON, shell commands, HTTP calls) with a plain summary.
6. **Bot setup**: remove the "MCP servers" tile, "Add an MCP server" and "Add your key", including the sheet shown after hiring. Hide the raw tool picker.
7. **Token jargon**: change bot budget, bot activity and office "Team usage" to plain words, such as "Light / Normal / Heavy day" or the share of the daily allowance. Move step traces behind "How did you do it?".
8. **Apps screen**: take Zapier off the top of "Sign in". Move "your own key / Any API / Tool server" copy into an Advanced/API row. Delete the Composio code. Make "Any API" Save explain why it didn't save.
9. **Projects**: guard `lengthSync()` (crash) and make project files open, share and remove.
10. **Settings moves per plan 5.4 and cleanup**:
    - Move Memory, Saved logins and Telegram out of Settings.
    - Merge the Phone access and Voice items.
    - Remove the dead `autoMode`/backup/`add_provider`/`needs_key` code in app_state and the live controller.
    - Replace raw error strings: files delete, trash restore, MCP test.

## Findings by severity
| Severity | Count |
|---|---|
| High | 4 |
| Med | 33 |
| Low | 30 |
| **Total** | **67** |
