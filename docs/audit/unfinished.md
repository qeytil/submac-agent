# SubMac Agent: what's broken, unfinished or bloated

Read-only audit of the copy in /workspace/work/repo, dated 2026-10-23. Nothing in the repo was changed.

**Which code this is.** This copy is version 1.13.62+95, which includes the Somali knowledge work. It is not the main release (1.13.58+91, merged but never built) and not the last beta APK (1.13.54+87).

**Analyzer.** Flutter and Dart are not installed in this sandbox, so `flutter analyze` was not run. The project's own notes say CI analyze and tests were clean as of the 2026-10-21 merge. Everything below comes from reading the code and docs.

---

## The short version

- **The app does far too much for a first launch.** I count about 30 user-facing areas, eight ways to talk to it, five scheduling concepts, six permission concepts and four ways to get a bot. Most of it was built in the last ten days.
- **Almost none of it has been used on a real phone.** The project notes say "not tested on a real phone" 26 times. That includes the merged build, which put chat feel, long tasks, bots and in-app updates together. The 15 golden-path phone checks from plan 5.6 were never run.
- **The app hides its own failures.** Errors are logged and swallowed, and a widget that crashes is drawn as empty space. About 184 error handlers are empty. There is no crash reporting.
  - What users see: blank patches on screens, and buttons that do nothing.
  - What the owner sees: nothing at all.
- **One file is the whole app.** The main state file is about 6,600 lines and 320 KB. It holds the agent loop, prompts, tools, bots, teams, browser, phone, connectors, settings and chats. It is the riskiest thing to change, and the GitHub tooling can no longer commit it.
- **Some docs promise more than the code does.** The clearest case is "Keeps working when your phone is off": a cloud bot can't use the web, a browser or any app. It can only update its notes and pass the job back to the phone.
- **The 5.6 audit's own top fixes are mostly done.** "Call again" works, the old model wording is gone, Test connection works, and the projects crash is guarded. What's left there is cleanup and duplication.

---

## 1. Feature inventory: keep, hide or cut

**Keep** means it's on the main path at launch. **Hide** means it stays built but moves behind "More", Advanced, or a setup step. **Cut** means it's switched off or removed for launch and can come back later.

### Talking to SubMac
| Area | What it is | Call |
|---|---|---|
| Chat with cards | Main chat, rich answer cards (tables, lists, diagrams, graphs, files), attachments, camera, scan text | **Keep**, as the core |
| Web search and reading pages | Search with source chips, reading web pages and PDFs | **Keep** |
| Memory ("What SubMac knows about you") | Facts it remembers across chats | **Keep**, but move it out of Settings as planned |
| Live voice calls | Real-time voice with SubMac, Somali captions fix, minutes per day | **Keep**: a headline feature for this audience |
| Dictation and read aloud | Phone speech-to-text and text-to-speech | **Keep** |
| Somali knowledge library | 124 entries on language and culture, used by the agent, bots and calls | **Keep**. It needs a review by a native speaker first. |
| Thinking modes (Quick / Think / Auto) | Choice of model depth | **Hide**: keep Auto and make the rest Advanced |
| "Hello SubMac" wake word | Always-on offline listener | **Cut**. It uses an English-only voice pack downloaded from a third-party site, drains battery, and doesn't fit a Somali-first audience. |
| Telegram bridge | Talk to SubMac through your own Telegram bot (paste a BotFather token) | **Cut** for launch. It's developer setup, and it keeps the app alive in the background. |
| Floating task bubble | Small chat over other apps while SubMac drives the phone | **Keep**, but only for phone-control tasks |

### Getting things done
| Area | What it is | Call |
|---|---|---|
| Documents | Make Word/PDF/slides/sheets, read office files, calculator, units, dates | **Keep** |
| Meeting recorder | Record, transcribe, get notes | **Keep**, inside Skills |
| Phone actions | Alarms, timers, calendar, contacts, call and SMS drafts | **Keep** |
| Phone control (screen taps) | Accessibility-based control of other apps | **Hide**: opt-in from the Phone access page |
| WhatsApp on the phone | Read, reply and send through the user's own WhatsApp, always with approval | **Keep, opt-in.** It's a strong reason to use the app in Somalia, but it's untested on phones and fragile when WhatsApp updates. |
| Browser agent | Built-in browser the agent drives, which the user can watch or take over | **Hide**: the agent uses it on its own, with no menu entry |
| Website builder and publishing | Builds a site; Publish gives a 7-day link or the user's own Vercel | **Hide**, under Files ("Your sites") |
| Image and video generation | Code is present but switched off (no provider) | **Cut**. Remove the leftover prompt text that still asks for images (see item 8 below). |
| Scheduled tasks ("Routines") | "Every morning at 7, tell me the weather" | **Keep**, shown on Today |
| Projects | Chats, files and instructions grouped together | **Hide**: keep in the sidebar under chats, and merge with Teams (section 3) |
| Skills (built-in, 39) | One-tap actions: Translate, Scan, Prayer, Money and so on | **Keep**, but only as the quick chips on an empty chat |
| Skill library (417 public playbooks) | Downloadable expert instructions | **Hide**. The agent loads them by itself, so users don't need a screen for it. |
| Prayer times, Qibla, Hijri date, Quran | Faith tools | **Keep** |
| Business tools (books, invoices, PDFs) | The "Ganacsade" business bot | **Keep**: it fits the small-shop audience |
| Health bot ("Caafimaad") | Health information | **Hide** until a professional has reviewed it. Plan 8 says the owner approves it before release. |
| Coder bot ("Barnaamije") and code tools | Runs git and code on the phone | **Cut** for a consumer launch. It's a developer tool and adds about 2,200 lines. |

### Team (bots)
| Area | What it is | Call |
|---|---|---|
| Hire with roles | 8 roles, 3 questions each, first job right away | **Keep**: the main way to get a bot |
| Bot job page | Job / Training / Settings tabs, responsibilities, evening note | **Keep** |
| Approval card and trust levels | Approve · Edit · Not now; New vs Trusted | **Keep** |
| Bot calls (calling a bot, or a bot calling you) | Voice with a bot, full-screen incoming call | **Hide**: off by default, "Can't call me" as the default |
| Bot activity traces | Step-by-step log with timings | **Hide**, behind "How did you do it?" (partly done) |
| Bot Store | Publish and hire community bots | **Hide**. Moderation is dashboard-only and the in-app report button doesn't exist (item 5). |
| Shared bot files | Import a bot from a file | **Hide**, under Hire > More |
| Teams (formerly Offices) | A lead plus teammates, shared tasks, team chat, team folder, 6 ready-made teams | **Hide**. It's a second, heavy system with about 2,600 lines. Launch with single bots. |
| Cloud runner ("works when phone is off") | Server runs eligible bot jobs | **Keep the plumbing, change the promise**: today it can't do web, browser or app work |
| Referral and creator rewards, invite codes | Extra allowance for invites and hires | **Hide**, under Settings > Invite friends |

### Apps and accounts
| Area | What it is | Call |
|---|---|---|
| One-tap sign-in apps | 108 presets, including Notion, Canva, Asana and Linear | **Keep**, but feature about 20 that were actually tested |
| Phone apps (Calendar, Contacts, texts, notifications) | On-device access | **Keep** |
| Key-paste apps (52) | Gmail app password, Shopify, Stripe, GitHub, Vercel, Supabase and others | **Hide**, under an "API" row. **Cut** the developer-only ones (Vercel, Netlify, Cloudflare, Supabase, GitLab, Twilio, NewsAPI, search keys). |
| Custom tool server (MCP) and "Any API" | Paste a server link or base URL plus key | **Hide**, under Advanced |
| Saved logins | Websites the browser can sign in to | **Hide**, under Apps |

### Account, files and system
| Area | What it is | Call |
|---|---|---|
| Today | Needs your OK, done while you were away, From SubMac, routines | **Keep**: make it the single place for updates (section 3) |
| Files | SubMac files plus phone files | **Keep**, and absorb Library, Sites and Trash |
| Library | Images SubMac made (just a view of one folder inside Files) | **Cut** as a separate screen |
| Trash | Restore deleted files (shown both in Settings and in Files) | **Keep**, but only inside Files |
| Archived chats | Separate screen in Settings | **Hide**: make it a search filter as planned (not done) |
| "From SubMac" inbox | Messages and gifts from the SubMac team | **Keep**, but as a section of Today, not a fourth bell |
| Settings, Privacy, Delete account, Help | | **Keep** |
| In-app updates | Direct-APK updater from Cloudflare R2 | **Keep**. This is how a direct APK gets updated. |
| Wallet, coins, passes (billing) | Sifalo payments, coins, store screens | **Hide** behind the existing switch until Sifalo live keys exist and payments have been tested end to end |
| Easy mode | Removed in plan 5.3, but code is left | **Cut** the leftovers |

**After this, the launch app is:** Chat (with Live), Today, Team (single bots, hire by role), Apps (tested sign-in apps plus phone), Files, and Settings. Everything else sits one tap deeper or waits for a later release.

---

## 2. Top 10 broken or unfinished things, and what the user would hit

1. **Nothing is phone-tested, including the merged build.**
   - Untested on a phone: the merged chat, long-task, bot and update build; the floating bubble; the Live echo gate; WhatsApp control; trust levels; teams; in-app updates; push.
   - The 15 golden-path phone checks were never run.
   - Two different builds both carry the number 1.13.54+87, so the in-app updater and testers can't tell them apart.
   - **What the user hits:** anything. The most likely trouble is long tasks, the bubble covering taps, a stuck "using your phone" badge, and WhatsApp steps failing after a WhatsApp update.

2. **Failures are invisible.**
   - Every app error is logged and swallowed.
   - A broken widget is drawn as empty space instead of an error.
   - About 184 error handlers are empty (39 of them in the main state file).
   - No crash reporting exists, and the "crash and drop-off events in the dashboard" from plan 5.6 were never built.
   - The Somali knowledge loader also fails silently: if a file is bad, the library is just empty.
   - **What the user hits:** a blank card or section, a button that does nothing, a bot or tool that "just didn't answer". The owner gets no signal.

3. **"Keeps working when your phone is off" overpromises.**
   - The cloud runner gives a bot only its notes, its task list, its own knowledge and a "hand to phone" step.
   - It has no web search, no browser, no connected apps, no files, and it can't make new routines.
   - The plan says web, research, briefs and connected apps would be cloud work.
   - **What the user hits:** they hire a researcher for a morning brief and the phone is off overnight. The bot can't research. It waits for the phone, or sends a thin note built from memory.

4. **Connected apps live only on the phone.**
   - Plan 4's server side was never built (the app catalog, server-held connections, and the two simple tools "find an action" and "do it").
   - Sign-in tokens stay on the device. The agent still sees raw tool lists.
   - **What the user hits:**
     - Cloud bots can't use Notion, Asana and the rest.
     - A reinstall or a new phone loses every app connection, even though the bots themselves come back.
     - Apps can't be featured or fixed without an app update.

5. **Bot Store safety is half done.**
   - When a hire is blocked as unsafe, the app says "You can report it", but no report button exists anywhere in the app.
   - Moderation exists only in the admin dashboard.
   - The "what this bot can do" list before hiring (plan 2.5) is thin.
   - **What the user hits:** a dead-end message, and no way to flag a bad bot.

6. **The navigation cleanup (plans 5.1, 5.3, 5.4) is only half done.**
   - The sidebar is down to Today · Team · Apps · Files. Behind it, though:
     - Skills still open from three places: a bare red-dot button on an empty chat, the quick chips, and Settings.
     - Archived chats can't be found by search, and the planned filter isn't there.
     - Library is still a separate screen.
     - Trash is in both Settings and Files.
     - "From SubMac" has four entry points.
     - Settings still holds Skills, Archived, Trash, Apps, Invite code and From SubMac, beyond the planned eight.
   - **What the user hits:** the same thing in several places, and things they can't find (old chats).

7. **Removed settings still apply.**
   - The "Steps per task" and "Show working steps" controls were removed, but the app still reads the saved values.
   - Wording leftovers: Easy mode is still in the code, there's dead "backup model" logic, and old "model"/"key" result names remain.
   - Bot app setup still tells users to connect apps in the "MCP row with its link and key".
   - **What the user hits:** a beta tester who once picked 5 steps has every task pause after 5 steps, with no way to change it. Someone who turned steps on keeps raw steps forever.

8. **Image generation is off, but the site builder is still told to use it.**
   - The website-building instructions always say to use image generation for hero pictures.
   - The image tool is only offered when image generation is on, and it's off.
   - **What the user hits:** website tasks that hit an extra failed step, or an answer that promises a picture that never comes.

9. **Payments are built but not live.**
   - Wallet, coins, passes, checkout, a wallet chip in the chat header and billing notice cards are all wired in.
   - They're held back by one server switch, and Sifalo live keys don't exist.
   - The monetization notes say the branch "is not on GitHub", yet the billing code is in this copy.
   - **What the user hits:** nothing today. But if the switch flips early, users get a store whose payments were never run end to end.

10. **Release plumbing is unsettled.**
    - Push notifications were never tested on a phone. The docs contradict each other on the app's package id: one section says it went back to the old id, while the code and push setup use the new one. A mismatch means no push.
    - The public bot pages ("Hire in SubMac" links) sit on an unmerged website branch.
    - The Somali captions fix and the Somali knowledge library sit on unmerged branches with no APK.
    - Server-side database changes for releases, site previews and billing have no migration files in the repo.
    - **What the user hits:** notifications that never arrive (bot results, approvals), "Hire" links that don't open the app, and Somali call captions that still come out in the wrong language on the released build.

**Smaller things worth a line each:**
- Two "Tell me when a task is done" switches in different places.
- Library's "Move to Trash" asks for no confirmation.
- Unused leftover widgets: an old "Thinking" line, a thinking dot, an unused menu icon, and an unused stats helper.
- The "Ready-made" teams include a "Dev team".
- Bot voices come from a fixed list, while Settings reads them from the server.
- Syncfusion's PDF package is used, but its licence isn't listed with the other third-party credits. Its community licence must be registered.
- The old GitHub/Notion token tools and the Brave/Tavily search keys are still wired in, beside the newer app catalog.

### The size problem and stability
- **Main state file: about 6,600 lines, one class.**
  - It runs the agent loop, every prompt, about 360 methods, tool routing and approvals, bots, teams, the browser subagent, phone features, connectors, key apps, settings, chats, the bubble, compaction and long tasks.
  - Its own section labels are misleading. For example, the "auto-compaction" section is about 1,100 lines and holds the main chat loop and system prompt.
- **What that means:**
  - Every change risks breaking something unrelated.
  - Merges collide here. The 10-21 merge needed hand reconciliation of duplicate features.
  - It calls the "screen changed" signal in about 115 places, and about 26 screens rebuild on every one. That costs phone speed during streaming.
  - It can't be unit-tested in isolation. Only 6 test files touch it.
  - The GitHub tooling used here can't commit a file this big, so edits now need a workaround.
- **Other very large files:**

  | Area | Lines |
  |---|---|
  | Bots service | ~1,860 |
  | Browser agent | ~1,620 |
  | Teams service | ~1,590 |
  | Code tools | ~1,370 |
  | Answer cards | ~1,340 |
  | Health tools | ~1,340 |
  | Business tools | ~1,260 |
  | Diagram card | ~1,080 |
  | Home screen | ~1,070 |
  | Teams screen | ~1,030 |
  | Composer | ~1,000 |

- In total the app is about 65,000 lines of Dart in 157 files. The tests are about 5,800 lines.
- **Advice:** before launch, split the main state file along its real seams: agent loop and prompts, tool routing and approvals, bots and teams, browser and phone, connectors, chats. Cut the features marked Cut above, which removes several thousand lines at once.

### Test coverage gaps
- The tests are mostly prompt and wording checks plus pure logic: the agent loop, Somali, billing, trust, WhatsApp text, Live audio, updates.
- Only a handful of screen tests exist (update screen, billing widgets, the chat task line).
- These have **no tests at all**:
  - chat storage and cloud backup (the biggest data-loss risk)
  - bot cloud sync
  - Bot Store
  - browser agent
  - tool-server client
  - push
  - events
  - rewards
  - Telegram
  - wake word
  - "From SubMac" inbox
  - projects
  - built-in skills catalog
  - updater service
  - device access
  - meeting notes
  - the old GitHub/Notion tools
- There's no end-to-end test of hiring a bot, approving an action, connecting an app or making a call. The one integration test films a marketing reel and isn't part of the test run.
- Kotlin (bubble, WhatsApp hands, screen guard, updater) is only compiled in CI and never tested.

### Docs that say done when the code says otherwise
| Doc says | Code shows |
|---|---|
| Cloud bots do web, research, briefs and connected apps while the phone is off | Cloud runner has no web, browser or apps |
| Plan 5.1: Skills leave the menu; Archived becomes a search filter; Files = Library + Files + Trash | Skills reachable in 3 places; archived chats can't be searched; Library is a separate screen; Trash in 2 places |
| Plan 5.4: Settings becomes eight sections | Settings still has about 15 rows, including Skills, Archived, Trash, Apps and Invite |
| Plan 2.5: report and remove bots | "You can report it" with no report button |
| Plan 5.6: crash and drop-off events in the dashboard; 15 phone golden paths | No crash events; the phone checks were never run |
| Plan 4 server catalog listed as next-day work | Not started; tokens stay on the phone |
| Plan 8: five professional bots (health, legal, business, education, agriculture), owner-approved | Business, Health and Coder exist. Coder isn't in the plan, legal is only a hire role, education and agriculture are missing, and there's no record of owner approval. |
| Project-state "Release" and "App (v1.13.0)" sections | Stale. Main is quoted as both 1.13.15+48 and 1.13.58+91. The package id is described two ways. |
| Plans header "in progress / Next 2026-10-20" | Stale |

---

## 3. Duplicates to merge

1. **Skills, Skill library, quick chips and bot skills.** There are two different things called "skills": 39 built-in one-tap actions and 417 downloadable playbooks. They're reached from the red dot, the chips, Settings, and bot setup. **Merge:** keep the chips on an empty chat. The agent loads playbooks by itself. Put one "Skills" list under More.

2. **Files, Library, Sites, Trash, project files and team folders.** Library is just one folder of Files. Sites, project folders and team folders are also folders in Files, but projects are named by id and teams by name. Trash appears twice. **Merge:** one Files screen with filters (Made by SubMac, Sites, Projects, Teams, Trash). Name every folder by its human name.

3. **Today, Needs your OK, From SubMac, bot activity, the job page's "Needs you", and team-chat approval cards.** That's six places to see "what happened and what needs me", and four doors to the From SubMac inbox. **Merge:** Today is the single feed: Needs your OK, done while you were away, From SubMac, and Coming up. Activity traces go only behind "How did you do it?".

4. **Teams (formerly Offices) and Projects.** Both are a folder, a shared context or instructions, chats and tasks. **Merge:** one "Project", which can have teammates (bots) and a lead. Or hide Teams at launch and keep Projects.

5. **Ways to get a bot.** Hire roles, Bot Store built-ins, the store's community bots, "Someone else" (describe), a shared file, ready-made teams, and a hire link. Worse, Nova, Amal, Rank and Ustad exist **twice**, as a hire role and as a different built-in store bot with the same name. **Merge:** one Hire screen with roles first (one definition per bot), then More (Store, shared file, describe).

6. **Scheduling.** Routines (scheduled tasks), bot responsibilities, bot follow-ups, notification watches, bot check-ins, team check-ins and work hours, and evening notes. **Merge:** one idea, "Responsibilities", shown on Today ("Coming up") and on each bot's page, all on one scheduler.

7. **Connecting things.** 108 sign-in presets, 52 key-paste apps, the old GitHub/Notion token tools, old search keys, custom tool servers, "Any API", saved website logins, plus Telegram and WhatsApp rows. **Merge:** an Apps row with tested sign-in apps and phone apps, and one Advanced row (keys, tool servers, API, logins). Delete the old token tools that duplicate catalog entries.

8. **Permissions and trust.** SubMac's trust level, each bot's trust level, WhatsApp trust per bot, team trust, bot power switches, read-only apps, and "Let it take action". That's seven controls for "may it act without asking?". **Merge:** trust level per assistant (New / Trusted), plus one Phone access page. WhatsApp and team trust become part of the bot's trust level.

9. **Voice and talk channels.** Live with SubMac, calling a bot, a bot calling you, the "lead calls me" daily report, the wake word, Telegram, and the WhatsApp bubble. **Merge:** Live and bot calls as one calling feature. Cut the wake word and Telegram for launch.

10. **Chat progress UI.** The current working line, an old unused "Thinking" line, an unused thinking dot, "How I did it" next to the "Worked for … · N steps" fold (only one shows in practice), and two "tell me when done" switches. **Merge:** keep the working line and the "Worked for" fold. Delete the rest.

---

## Appendix: files referred to (for the developer)

- Size: `lib/app_state.dart` (6,594 lines); `lib/services/bots.dart`, `browser_agent.dart`, `offices.dart`, `code_tools.dart`, `health_tools.dart`, `biz_tools.dart`; `lib/widgets/output_cards.dart`, `diagram_card.dart`, `composer.dart`; `lib/screens/home_screen.dart`, `offices_screen.dart`
- Hidden errors: `lib/main.dart` (global error handlers, blank ErrorWidget); `lib/services/somali_knowledge.dart` (silent load)
- Cloud runner limits: `supabase/functions/bot-run/index.ts` ("Working in the cloud" block, apps "live on the owner's phone")
- Apps: `lib/services/mcp_oauth.dart`, `connector_catalog.dart`, `connector_tools.dart` (old GitHub/Notion), `lib/screens/connectors_screen.dart`, `bot_setup_screens.dart` ("MCP row" wording)
- Store: `lib/services/bot_store.dart` ("You can report it"); `lib/services/roles.dart` and the `BotTemplates` class in `bots.dart` (duplicate Nova/Amal/Rank/Ustad)
- Leftovers: `easyMode`, `autoMode`, `_backupFor`, `add_provider`, `needs_key` in `app_state.dart` and `live_controller.dart`; `_MenuGlyph` in `home_screen.dart`; `PendingLine` in `chat_extras.dart`; `ThinkingDot` in `message_view.dart`; `PayloadStats` in `agent_loop.dart`; stale `maxSteps`/`showSteps` in `local_store.dart`
- Image prompt: `app_state.dart`, the website-builder instructions near the line "Pictures: generate_image…"
- Duplicated places: `lib/screens/library_screen.dart`, `files_screen.dart`, `settings_screen.dart` (Trash, Archived, Skills, two "task done" switches with `system_screens.dart`), `skills_screen.dart`, `skill_library_screen.dart`, `inbox_screen.dart`, `approvals_screen.dart`, `today_screen.dart`, `projects_screen.dart`, `widgets/sidebar.dart` (archived excluded from search)
- Cut candidates: `lib/services/wake_word.dart`, `telegram_bridge.dart`, `code_tools.dart`/`code_git.dart`/`code_runner.dart`, `assets/bots/coder.json`
- Billing: `lib/screens/billing/*`, `lib/services/billing/*`
- Push and package id: `lib/services/push.dart`, `.github/workflows/*.yml`, `docs/project-state.md`
- Docs checked: `ROADMAP.md`, `docs/project-state.md`, `docs/plans-2026-10.md`, `docs/audit-5.6.md`
- Tests: `test/` (about 40 files), `integration_test/reel_test.dart` (marketing reel only)
