# SubMac Agent: UI/UX audit

Scope: every screen and shared piece of the app's interface, read from the code (version 1.13.62+95). I read it only; nothing was changed. I didn't run the app on a phone, so this report covers what each screen says and contains, not how fast it feels or how it looks pixel by pixel.

---

## 1. Overall impression

The wording is cleaner than most AI apps. There are no emoji, no "Great!", and almost no hype. Error messages are mostly short and human ("No internet connection. Check your data or Wi-Fi."). The chat screen is calm, and the Paper/Ink design is distinctive.

The problems are size and explanation. SubMac has grown into about 40 screens built around a few strong metaphors at once: hiring "colleagues", "teams with a lead", "trust levels", "skills" versus a "skill library", and "apps" versus "API" versus "MCP". Each new feature brought its own screen, its own entry point and a paragraph explaining itself. As a result:

- **Many screens open with a paragraph instead of the thing itself.** Team, WhatsApp, Bot training, Apps, Skills, Saved logins and the allowance sheet all explain before they show.
- **The same job lives in two to four places.** Messages from SubMac, invites, approvals, Skills, Trash, phone permissions, Live, Deep research, "Let it take action", adding a shared bot and run activity all repeat.
- **Some words mean two things.** "Team" means both everyone you hired and one group with a lead. "Library" means both the files SubMac made and expert playbooks. "Skills" means both quick starters and the expert library.
- **For the audience (Somali, Arabic and English speakers), the interface is English only.** The only Somali is in the update window, the coin terms and one payment line. There is no Arabic interface and no right-to-left layout for the interface itself; only chat messages flip direction.

In short, the core (chat, Live, documents) is good. Everything around it needs cutting, merging and translating more than it needs new features.

---

## 2. Top 10 problems, ranked by how much they hurt

### 1. The app is English-only for a Somali/Arabic audience
- **What happens:** Every menu, button, empty state, sign-up step, consent screen, setting and error is English. Somali appears only in the update window ("Cusboonaysiin cusub"), the coin terms and one payment line ("Waxaad ku bixin doontaa bogga sugan ee Sifalo…"). Arabic appears nowhere in the interface. The app never switches the layout to right-to-left, so an Arabic user gets English menus on the left with Arabic chat replies on the right.
- **Specific examples:**
  - Settings > Reply language lists the choices in English: "Somali", "English", "Arabic". A Somali or Arabic reader should see "Soomaali" and "العربية".
  - The wake word is the English phrase "Hello SubMac".
  - The "Ask SubMac anything" box on Today doesn't flip for Arabic typing; only the main chat box and team chat do.
- **Plain fix:** Add an app language setting (Soomaali / العربية / English) that follows the phone's language by default. Translate the main path first: sign-up, consent, the chat screen, the menu, Settings, approval sheets and errors. Turn on right-to-left layout when Arabic is chosen. Show each language's name in that language.

### 2. Too many places do the same job
- **What happens:** Users can't build a mental map because each feature has several doors:
  - **Messages from SubMac:** the bell in the top bar, a row on Today, the bell on Today, and a row in Settings ("Messages from the SubMac team, gifts and rewards").
  - **Invites:** an invite card on Today, again in the Inbox, "Have an invite code?" in Settings, and "Invite code (optional)" at sign-up.
  - **Approvals:** the pop-up sheet, the "Needs your OK" section on Today, the Approvals screen, each bot's Job tab ("Needs you"), and each team's Tasks tab.
  - **Skills:** an unlabelled red dot in the top bar, the "All skills" chip, Settings > Your data > Skills, and per-bot Skills.
  - **Trash:** in Files and in Settings.
  - **Phone permissions:** Calendar, Contacts, Text messages and Notifications appear in Apps > "On this phone" and again in Settings > Phone access > Phone permissions. "Tell me when a task is done" is a switch on two different screens.
  - **"Let it take action":** in the + menu and in Settings.
  - **Live:** a "Talk with SubMac Live" chip and a "Live" button on the same empty chat screen.
  - **Deep research:** the + menu, a quick chip, and the "Try now" poster on Skills.
  - **Bot run history:** the bot's ⋮ menu ("How it worked, step by step") and its Settings tab ("Every run, step by step").
  - **Adding a shared bot:** six ways. Hire screen ("A bot someone shared"), Bot Store's top-bar button, Bot Store's "A friend shared a bot with me", Start a team > "From a shared file", file import, and links.
- **Plain fix:** Give each job one home and link to it from at most one other place. See section 3.

### 3. "Team", "Bots", "people", "colleagues", "hire": the words fight each other
- **What happens:**
  - The menu says **Team**, but that screen holds "Your people", a section called "Teams", "Not started yet", a Bot Store card and a + button labelled "Hire someone".
  - A team is also one group with a lead, so one Team screen contains several teams.
  - Messages mix "joined your team" and "joined your teams".
  - The share message is wrong. It tells the friend to "open Bots > Bot Store > 'A friend shared a bot with me'", but no menu item is called Bots; it's called Team.
  - The job metaphor runs very deep: Hire, Job, Training, Responsibilities, "Give Hodan time off", Off hours, Trust level, Mission, evening notes.
  - For people reading in a second language, "Hire" also sounds like paying money.
- **Plain fix:**
  - Call the menu item **Bots**.
  - Keep "team" only for a group of bots with a lead.
  - Use plain verbs: "Add" instead of "Hire", "Pause" instead of "Give time off", "Delete" instead of "Remove Hodan". Keep the personality in the bots' names, not in the settings.
  - Fix the share message.

### 4. Screens explain themselves instead of showing the thing
- **What happens:** Long helper paragraphs sit at the top of screens, in muted grey that people skip. Examples:
  - **Team:** "Colleagues who work for you on their own: they research, keep track, message you when it matters, and can call you. Put a few together as a team with a lead."
  - **Allowance sheet** (tap the title on the chat screen): "Everyone gets a fair daily allowance. It refreshes every day, and SubMac keeps answering with shorter replies if you use a lot. Bots and teams use their own part of it, so they never get in the way of your chats. Calls have their own minutes, which come back every day at …" That's four sentences.
  - **WhatsApp:** a four-sentence opening ("SubMac uses WhatsApp on this phone the way you would: it reads new messages from WhatsApp's notifications, answers from the notification, and opens WhatsApp to send…") plus a three-sentence footer about "at most 20 people per request and about one message every 6 seconds".
  - **Bot training > Tell it:** "How Hodan should do the job: steps, rules, tone, what to avoid. Plain words are perfect. This travels with Hodan when you share it, so keep personal details out."
  - **Bot Store:** "Hire a ready-made colleague. You get your own copy: it learns about you, and nothing about you is ever shared back."
  - **Skill library:** "Expert playbooks … reads before a task. Installed ones are always at hand; the rest are found when a task needs them."
  - **Saved logins:** two sentences of reassurance above an empty list.
  - **Wallet:** "SubMac uses today's free allowance first, then your pass (up to its daily limit), then token packs, soonest-expiring first. Advanced models use more per reply."
- **Plain fix:** At most one short line per screen, or none. Move the "how it works" detail behind a small "How this works" link, or into the Privacy page where it's already written.

### 5. Jargon a normal user shouldn't see
- **What happens:**
  - **Apps screen:** tabs **"Connected · Apps · API · MCP"**. Inside are "Tool server", "Paste an MCP server link", "Key header", "Bearer …", "Base link" and "Developer apps".
  - **A bot's apps:** "Connect X in Apps (MCP row) with its link and key".
  - **When a model fails,** a banner reads "*[model] didn't answer, so [model] replied this time.*" and the status line says "Trying [provider] instead".
  - **Wallet and store:** "tokens", "token packs", "Exchange coins for tokens", "Auto-exchange", "Reply counts are estimates for Standard models. Advanced models use more per reply".
  - **Settings > Look and feel:** "Paper" and "Ink" instead of Light and Dark.
  - **Trust level:** "New" sounds like a status, not a level of permission.
- **Plain fix:**
  - Leave only "Connected" and "Apps" on the Apps screen. Hide API and MCP under one "Advanced" row at the bottom.
  - Never show model or provider names; a short "Slow answer, trying again…" is enough.
  - Say "Light / Dark / Automatic".
  - Rename the trust levels "Ask me first" and "Do routine work alone".

### 6. Navigation is deep, and key things hide behind icons only
- **What happens:** Everything is in a side drawer: New chat, Today, Team, Apps, Files, then Projects and chat history, then Settings at the bottom. Important things sit two to five taps deep:
  - **Memory:** Menu > Settings > "What SubMac knows about you".
  - **Routines:** Menu > Today > scroll to the bottom > Routines. This is the only way in.
  - **Your sites and Library:** icon-only buttons in the Files top bar. Their tooltips are long sentences ("Your sites: pages SubMac built, and their links").
  - **A bot's tools or WhatsApp permission:** Menu > Team > bot > Settings tab > scroll > Tools.
  - **Skills on the chat screen:** an unlabelled red dot. Nothing tells a new user it means Skills.
  - **Easy mode:** big tiles on the home screen are built, but no switch anywhere turns them on, so the feature is unreachable.
- **Plain fix:**
  - Give the red dot a label or a clear icon.
  - Move Routines and Memory up one level.
  - Show Sites and Library as tabs in Files instead of icons.
  - Either add an "Easy mode" switch in Settings or delete the feature.

### 7. Today is a page of empty states for most users
- **What happens:** Someone without bots opens Today and gets, top to bottom:
  - another "Ask SubMac anything" box (a second chat box);
  - "From SubMac";
  - an invite card;
  - "Needs your OK" ("Nothing waiting. Your team asks here before anything that needs your OK.");
  - "Done while you were away" ("Hire a bot in Team and its work shows up here.");
  - "Coming up" ("No bots working yet.");
  - Routines.

  "Coming up" lists bots, not upcoming events, so the label is wrong.
- **Plain fix:** Hide Today, or turn it into one short list, until the user has a bot or a routine. Remove its separate ask box. Rename "Coming up" to "Working now", or show actual scheduled items there.

### 8. The empty chat screen and its buttons are crowded
- **What happens:** On a new chat the user sees:
  - a ringed logo and "Hi …, what would you like to do today?";
  - a "Talk with SubMac Live" chip;
  - the team status line;
  - a sideways row of **ten** quick chips plus "All skills" (Document, Scan to PDF, Translate, Prayer…, Meeting, Deep research, Money, WhatsApp message, Shop, Study);
  - the composer: +, an "Auto ⌄" mode picker, mic and a Live button.

  The top bar adds the menu, sometimes a wallet chip and a bell, and the red dot. The + menu holds seven more items (Camera, Scan text, Photos, Files, Record a meeting, Deep research, and a "Let it take action" switch).

  "Auto / Quick / Think" with its explainer ("Picks for you: quick for simple chats, careful for real tasks") is a choice most users never need to make.

  "Translate" quietly opens a Live voice call, which a user wouldn't expect.
- **Plain fix:**
  - Show at most four quick chips, chosen for the user's language (for example Document, Scan to PDF, WhatsApp message, Translate), plus "More".
  - Keep one Live entry: the button in the composer.
  - Move Auto/Quick/Think into Settings, or into a long-press on Send.
  - Remove "Let it take action" from the + menu.

### 9. Visual styling isn't consistent screen to screen
- **What happens:**
  - The app has a type scale of eight sizes, yet screens use 17 different hand-picked text sizes (13, 12.5, 13.5, 14.5, 15.5…) and about ten different corner roundings.
  - Page titles change style: big serif on Today, Settings and Files; small plain centred text on Apps and Skills; plain left-aligned text on Team; a 17-point bold title on a team screen.
  - Section headers come in three styles: UPPERCASE letter-spaced (Team, menu), small grey (Apps), and bold 15-point (Today).
  - Brand red is meant only for warnings and delete actions, but it's also used for the "New" project button and the Skills dot.
  - Chat-history groups use title case ("Previous 7 Days") while everything else uses sentence case.
- **Plain fix:** Pick one title style and one section-header style and apply them everywhere. Use only the set sizes. Keep red for danger and alerts.

### 10. Same-name features that aren't the same
- **What happens:**
  - **"Skills"** (39 quick starters such as "Invoice: Numbered, with totals and your logo name") and the **"Skill library"** ("Hundreds of expert skills: phone apps, browser, platforms, business, marketing, SEO, trading, coding, creators") are different things with the same name. The library's poster sits inside the Skills screen.
  - **"Library"** in Files ("pages, documents and pictures SubMac made") overlaps with **"Your sites"** ("pages SubMac built") and **"SubMac files"**.
  - **Projects** and **Teams** both offer "a folder plus instructions plus chat".
  - Bots can be found in three catalogs: the "Not started yet" list on Team, the role cards on the Hire screen ("Researcher", "Legal helper", "Money keeper"…), and the Bot Store's "Made by SubMac" list.
- **Plain fix:**
  - Rename the quick starters "Shortcuts" (or "Quick start"). Hide the expert library from regular users; bots can still use it.
  - Merge Library and Sites into Files.
  - Keep one catalog of bots: the Bot Store, with SubMac's own bots on top.

---

## 3. Screens and features to cut, merge or hide

| Today | Suggested | Why |
|---|---|---|
| Today screen | **Hide until the user has a bot or routine**, and drop its second ask box | It's mostly empty states and duplicates the chat box |
| "From SubMac" rows in Today and Settings | **Keep only the bell** in the top bar (shown when there's something unread) | Four doors to one inbox |
| Invite card on Today, invite code row in Settings | **Merge into one "Invite friends" row** in Settings. Keep the code field at sign-up only | Repeated marketing |
| Approvals screen plus "Needs your OK" on Today | **One "Needs your OK" list**, reached from the notification and the Today/Bots badge | Same items in two lists |
| Trash in Settings | **Cut**; keep it in Files | Duplicate |
| Settings > Skills | **Cut**; skills are already on the chat screen | Duplicate, and it isn't "Your data" |
| Apps > "On this phone" vs Settings > Phone permissions | **Keep one** (Settings > Phone access). Apps shows only apps | Same switches on two screens |
| "Tell me when a task is done" (two screens) | **One switch** | Duplicate |
| "Let it take action" in the + menu | **Cut**; keep it in Settings | A risky switch shouldn't sit next to "Camera" |
| "Talk with SubMac Live" chip on the empty chat | **Cut**; keep the Live button | Duplicate |
| API and MCP tabs in Apps | **Hide under "Advanced"** | Developer-only |
| Skill library (expert playbooks) | **Hide from the main Skills screen**; keep it per bot under Advanced | Confuses it with Skills |
| Library and Sites (icons in Files) | **Merge into Files as tabs**: Made by SubMac · Sites · Phone | Three names for SubMac's output |
| "Not started yet" bot list plus Hire-screen roles plus Bot Store "Made by SubMac" | **One catalog: the Bot Store** | Three catalogs of the same thing |
| Six ways to add a shared bot | **One "Add from code or file"** in the Bot Store | Over-built |
| Bot ⋮ "How it worked, step by step" and Settings "Every run, step by step" | **Keep one** (Activity in Settings) | Duplicate |
| Bot Settings tab: notes, how often it reaches out, check-in frequency, off hours, call style, 9 voices, cloud, tools, daily limit, WhatsApp autosend | **Show only Trust, Voice, Off hours; put the rest under "More settings"** | Far too many choices for a first-time user |
| Team settings: Mode, lead check frequency, work hours, daily report, team trust, daily work limit, rules, what the team agreed | **Same treatment: three basics plus "More settings"** | Same |
| Team ⋮ menu that repeats Mode ("Only when I ask / Work on its own / I approve new tasks / Pause the team") | **Cut**; keep the Mode setting | Duplicate of the setting |
| Auto / Quick / Think picker in the composer | **Move to Settings** (default Auto) | Most users never need it |
| Easy mode (built but unreachable) | **Either add a Settings switch or delete it** | Dead feature |
| "Hello SubMac" wake word | **Hide for Somali/Arabic users until there's a wake phrase in their language**, or offer one | An English phrase for a non-English audience |

---

## 4. Copy rewritten short

| Where | Now | Shorter |
|---|---|---|
| Sign-in screen | "Your phone, with a mind of its own." / "Ask, create and get things done.\nIt can take action, not just talk." | "Ask. Make. Get it done." (one line, or nothing) |
| Consent | "SubMac is for people aged 18 and over. Please read and agree to our Terms of Use and Privacy Policy." | "For ages 18+. Please agree to the Terms and Privacy Policy." |
| Sign-up hint | "We'll email you a 6-digit code to confirm this address is yours." | "We'll email you a code." |
| Empty chat | "Hi Amina, what would you like to do today?" | "Hi Amina. What can I do?" |
| Allowance sheet | "Everyone gets a fair daily allowance. It refreshes every day, and SubMac keeps answering with shorter replies if you use a lot. Bots and teams use their own part of it…" | "Free every day. Resets at midnight. Calls: 15 min a day." |
| Title note | "Resting" / "Lighter today" / "Busy day" | "Limit reached" / "Shorter replies today" / (nothing) |
| Model fallback banner | "[model] didn't answer, so [model] replied this time." | Remove, or "Took a little longer." |
| Team intro | "Colleagues who work for you on their own: they research, keep track, message you when it matters, and can call you. Put a few together as a team with a lead." | Remove. Empty state only: "No bots yet. Tap + to add one." |
| Bot Store card | "Hire a ready-made colleague: researcher, lawyer, teacher and more" | "Ready-made bots" |
| Bot Store intro | "Hire a ready-made colleague. You get your own copy: it learns about you, and nothing about you is ever shared back." | "Your own copy. Nothing about you is shared." |
| Hire screen | "Pick a role. Three quick questions, then they get to work on something real for you." | "Pick a role." |
| After hiring | "Hodan starts as New: asks before anything that changes something, and gets to work on a first job right away." | "Hodan will ask before changing anything." |
| Share message | "…open Bots > Bot Store > "A friend shared a bot with me" and type CODE" | "…open SubMac > Bots > Bot Store > Add from code: CODE" (and rename the menu item to Bots so it matches) |
| Bot training, Tell it | "How Hodan should do the job: steps, rules, tone, what to avoid. Plain words are perfect. This travels with Hodan when you share it, so keep personal details out." | "How Hodan should work. Shared with copies, so no personal details." |
| Bot training, lessons | "Short lessons Hodan wrote down after tasks, mistakes and your corrections, and follows next time (up to 30). General know-how only, never details about you." | "Lessons Hodan learned." |
| Pause bot | "Give Hodan time off" / "Bring Hodan back" | "Pause" / "Resume" |
| Start a team card | "A few colleagues with a lead who plans, hands out tasks and reports back, even while you're away." | "Bots working together on one goal." |
| Team chat empty | "Say hi to the team, or give them a job. Use @Name to talk to one person." | "Give the team a job. Use @Name for one person." |
| Team trust option | "Trust the whole team: no asking, not even before sending or paying" | "Never ask me (including payments)" |
| Approvals empty | "All clear. Your team asks here, and in a notification, before anything that needs your OK." | "Nothing to approve." |
| Today, done empty | "Hire a bot in Team and its work shows up here." | "Nothing yet." |
| Apps intro | "Tap Connect and sign in with your account, or allow an app that is already on your phone. No keys, no setup." | Remove |
| Apps, API tab | "For people who have a key or token from the app (for example a Telegram bot token). Keys are encrypted and stay on this phone." | (Under Advanced) "Connect with a key." |
| Saved logins | "When SubMac signs in to a site for you, it can remember the login here. Logins are encrypted and never leave this phone. The AI never sees your passwords." | "Saved on this phone only." |
| WhatsApp intro (4 sentences) | "SubMac uses WhatsApp on this phone the way you would: it reads new messages…" | "SubMac reads and sends WhatsApp for you. You approve every message. Nothing leaves this phone." |
| WhatsApp footer | "To keep your number safe, SubMac sends at most 20 people per request and about one message every 6 seconds. Bots can watch a chat…" | Remove (enforce it quietly) |
| Skills poster | "Reads many sources and writes you one clear report, with links." | "One clear report, with sources." |
| Skill library row | "Hundreds of expert skills: phone apps, browser, platforms, business, marketing, SEO, trading, coding, creators" | Hide (see section 3) |
| Skills no result | "No skill matches that. Just ask in the chat — SubMac can still do it." | "No match. Just ask in chat." |
| Composer mode sheet | "Picks for you: quick for simple chats, careful for real tasks" / "Takes a moment longer for hard problems, plans and code" | "Best for most" / "Slower, for hard tasks" |
| Memory | "Tap a note to change it. These are saved to your account so every phone you sign in on knows them." | "Tap to edit." |
| Settings, account | "Chats stay on this phone and are backed up to your account" | "Backed up" |
| Settings, invite | "Joined because of a friend? Their code gives them a thank-you bonus" | "Enter a friend's code" |
| Settings, theme | "Automatic · Paper · Ink" | "Auto · Light · Dark" |
| Settings, trust | "Trusted: does routine work on its own. Still asks before money, sending or deleting." | "Asks only before paying, sending or deleting." |
| Settings, reply language | "Same as mine · Somali · English · Arabic" | "Auto · Soomaali · English · العربية" |
| Custom instructions | "What would you like the assistant to know about you?" | "About you" (and say "SubMac", not "the assistant") |
| Site publish | "Online in seconds at a free SubMac link. Lasts 7 days, so it's perfect for showing people." | "Free link, 7 days." |
| Wallet note | "SubMac uses today's free allowance first, then your pass (up to its daily limit), then token packs, soonest-expiring first. Advanced models use more per reply." | "Free first, then your pass, then packs." |
| Exchange | "When your tokens run low, SubMac uses your coins to get the pack below, so replies never stop mid-task." | "Top up automatically from coins." |

---

## What's already good (keep it)
- No emoji, no "Great!", no hype words anywhere in the interface.
- Error messages are short and actionable ("That code is wrong or has expired. Check it, or send a new code.").
- Delete and destructive actions are clearly marked and confirmed ("Type DELETE to confirm.").
- The single approval sheet (Approve · Edit · Not now) is a good pattern; just give it one home.
- Chat replies in Arabic flip to right-to-left correctly, and voice typing follows the reply language.
- The update window and coin terms show how Somali should be done everywhere: the full screen translated, picked automatically.

---

## Appendix: where each finding lives (for the developer)
- Navigation drawer, chat-history groups, red "New" button: `lib/widgets/sidebar.dart`
- Chat screen, top bar, red-dot Skills button, allowance sheet, empty state, 10 quick chips, Easy-mode tiles, approval sheet: `lib/screens/home_screen.dart`
- Composer, + menu, Auto/Quick/Think, Live button: `lib/widgets/composer.dart`
- Model-fallback banner: `lib/app_state.dart` (~line 6183); Easy mode never switched on: `setEasyMode` in `lib/app_state.dart` has no caller
- Today: `lib/screens/today_screen.dart`; Approvals: `lib/screens/approvals_screen.dart`; Inbox and invites: `lib/screens/inbox_screen.dart`
- Team/Bots list: `lib/screens/bots_screen.dart`; Hire flow: `lib/screens/hire_screen.dart`; Bot profile (Job/Training/Settings): `lib/screens/bot_job_screen.dart`, `lib/screens/bot_setup_screens.dart`, `lib/screens/bot_activity_screen.dart`
- Bot Store, sharing, wrong "open Bots >" share text: `lib/screens/bot_store_screen.dart` (~line 473)
- Teams (offices): `lib/screens/offices_screen.dart`, `lib/widgets/team_parts.dart`
- Apps / API / MCP: `lib/screens/connectors_screen.dart`; Telegram: `lib/screens/extras_screens.dart`; Saved logins: `lib/screens/logins_screen.dart`; WhatsApp: `lib/screens/whatsapp_screen.dart`
- Skills and Skill library: `lib/screens/skills_screen.dart`, `lib/screens/skill_library_screen.dart`, `lib/services/skills_catalog.dart`
- Files, Library, Sites, Trash: `lib/screens/files_screen.dart`, `lib/screens/library_screen.dart`, `lib/screens/site_screens.dart`, `lib/screens/settings_screen.dart` (Trash)
- Settings, Privacy, Custom instructions, Phone access: `lib/screens/settings_screen.dart`; Phone permissions, Hello SubMac, Routines: `lib/screens/system_screens.dart`; Memory: `lib/screens/memory_screen.dart`
- Sign-in and consent: `lib/screens/auth_screen.dart`, `lib/main.dart` (no app language or right-to-left setup)
- Wallet and payments: `lib/screens/billing/*`
- Type scale and radii (bypassed in many screens): `lib/ui/tokens.dart`; colours and red-only-for-warnings rule: `lib/theme.dart`
- Somali done right (model to copy): `lib/widgets/update_window.dart`, `lib/screens/billing/coin_terms_screen.dart`
