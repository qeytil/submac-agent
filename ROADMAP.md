# SubMac Agent roadmap (agreed 2026-10-13)

> Historical. Current state: `docs/project-state.md`. Current plans: `docs/plans-2026-10.md`.

## Status
- **v1.4.0 (shipped 2026-10-14)**: provider limits (requests/tokens per minute, requests per day) with calm waiting, auto-retry on "too many requests", backup model, usage meter, Test connection, Get a free key guide; reply style (short answer first, then cards) with new cards (Table, Photos, Images, Rich links, Code Run, Receipt + Undo, Confirm), shimmer while a card is written, spring fade-in motion; web search with source chips; Memory (remember/forget + Settings page, synced); no-login tools (weather, Wikipedia, currency, maps, RSS, YouTube transcripts); phone actions (alarm, timer, calendar, call/SMS drafts, open link/app, share); camera, Scan text (on-device OCR), PDF reading; Files screen + Share to SubMac; Connectors (Composio and any MCP server, GitHub, Notion, Brave/Tavily search keys).
- **Next (1.5)**: SubMac built-in model (zero-setup default via a Supabase key pool, parked 2026-10-14); email connector (IMAP/SMTP with app password); jump-to-latest pill; scheduled automations.

Principle: power under the hood, zero jargon on screen. Agent actions shown as plain-language cards ("Organizing your Downloads"), tech details collapsible.

## Phase 1 (next): Device access
- All-files access toggle (MANAGE_EXTERNAL_STORAGE, permission_handler); onboarding card explains in plain words
- Built-in file browser + "share to SubMac Agent" from any app (share intent)
- Safe mode: confirm before delete/overwrite outside workspace; trash folder instead of rm

## Design pass (runs with Phase 1): Premium, calm, simple
- Typography: one premium bundled font (Inter / Manrope), tighter type scale, generous spacing
- Motion: smooth word-by-word fade-in streaming, spring sheet/drawer animations, light haptics on send/stop/approve
- Surfaces: true-black OLED dark mode, soft depth, frosted top bar, refined composer pill
- Onboarding: 3 calm screens, then straight into chat; empty state with personalized greeting
- Text-first, minimal icons: words instead of symbols in menus/settings/sidebar; keep icons only where universal (send, stop, back, +); thin consistent line style when used
- Plain language everywhere (no 'tool', 'shell', 'base URL' on main screens; advanced tucked away)
- Branded loading shimmer + animated spark logo instead of spinners
- Accessibility: large-text, contrast, RTL (Arabic/Somali-ready)

## Live voice (Phase 2)
- Full-screen Live mode: animated orb, mute, end, camera toggle, live captions
- Gemini Live API over WebSocket (user's own Gemini key, encrypted on device); live models + voices loaded from Google at runtime; voice preview in Settings
- Barge-in (interrupt anytime), hands-free or hold-to-talk, auto language
- Agent tools during Live (files, Composio) with spoken + on-screen confirmation for risky actions
- Camera/screen sharing into Live; transcript saved into the chat afterwards
- Keeps running with screen off (foreground service); session timer / usage hint
- Provider-agnostic layer so OpenAI Realtime etc. can be added later

## SubMac brand
- Paper #f4f0e7 / ink #17150f / signature red #c2361b (sparingly); dark mode = ink bg, cream text
- Instrument Serif (titles, greeting, Live captions), Geist (UI), Geist Mono (code); 4px corners, hairline rules
- App icon: serif S on ink square + red dot; Live orb = the red dot

## Output cards
- Agent replies as short message + typed cards: Summary, Table, Grid, Links, Draft (Copy/Send), Code (Copy/Run), File (Open/Share/Save), Action (+Undo), Confirm
- Cream sheet cards, slide in a beat apart; same renderer in chat and Live

## Auto mode (default model)
- Chat model routes via tools: quick chat, deep thinking, image gen/edit, vision, video (later), Live
- Faint "Made with X" label; role->model mapping under Advanced settings

## Media & Library
- Image/doc/chart/audio (video later) outputs as inline cards; shimmer placeholder while generating
- Library screen (Images/Files/Audio), synced via Supabase; Save to Downloads/Gallery; edit + version history

## Agentic but simple
- Goals not commands; plan card for big jobs (Start/Edit); background tasks + notification; self-check & retry
- Outcome lines, Details to reveal commands; permission levels (Ask always / Ask for risky / Just do it)
- SubMac trash (30-day restore), Undo; memory page; scheduled automations; one-tap action gallery

## Smarter tools & commands
- Bundled Linux toolbox (Termux/proot-style, ~100 MB on first use): Python, ffmpeg, zip, curl, ImageMagick, PDF tools (sideload flavor; check Play policy)
- Hidden environment briefing each chat: device, Android version, folders, installed tools, connected apps
- Purpose-built tools: search files, find/replace edit, zip, convert media, read PDF, run Python; rich descriptions + examples
- Built-in playbooks (skills) loaded on demand; user playbooks later
- Smart output trimming, exit codes, timing, created files; timeouts + Stop
- Self-correct and retry (max 3), verify before done; parallel steps; background jobs + notification
- Sandbox folder by default; UI = one plain line per step, tap for mono command/output card

## Approval modes (Settings)
- **Ask** (default): confirms before risky actions (delete, overwrite, send, post, pay)
- **Full access**: does everything without asking; enabling shows a one-time clear warning; red-dot indicator while on; trash/undo still active as a safety net
- Optional per-chat override from the composer

## Free premium touches (no API cost)
- Haptics; animated splash (ink S + red dot); spring scrolling, jump-to-latest pill, predictive back, edge-to-edge
- Free voice: Android speech recognition dictation + TextToSpeech read-aloud
- Auto chat titles, pin/rename, swipe-delete + Undo, instant search, long-press menu (Copy/Edit/Regenerate/Read aloud/Share), time-of-day greeting
- Share reply as branded image card; export chat to PDF
- App icon shortcuts (New chat/Live/Scan), quick settings tile, home widget, Share-to-SubMac
- Shimmer loaders, offline drafts/queued send, optional sound cues, tablet layout

## Built-in skills (playbooks) for non-tech users
- Phone & files: Clean my phone, Organize photos, Find a file, Back up important files, Compress/convert video & images
- Documents: Summarize PDF, Fill a form, Scan to PDF, Make a CV, Write a letter/report, Make slides, Excel helper
- Daily life: Translate photo/text/voice, Budget planner & expense tracker, Meal plan & shopping list, Study helper/quiz, Reminders & routines
- Communication: Draft email/WhatsApp message, Reply to email, Summarize inbox, Polite complaint/request
- Business: Social post + image, Product description, Invoice/receipt, Simple website/landing copy, Customer reply
- Learning: Explain like I'm new, Step-by-step how-to, Language practice (incl. Somali/Arabic)
- Each skill = hidden playbook + one-tap card in Actions gallery; auto-triggered from normal chat; users can save their own ("Teach SubMac")

## Builder skill (websites & mini-apps for non-tech users)
- Flow: describe -> 2-3 simple questions (name, style, photos) -> agent builds static site/PWA in sandbox -> live preview in app WebView (phone/tablet/desktop toggle)
- Edit by talking ("make the title bigger") or tap an element and say what to change; version history + Undo
- One-tap Publish to free hosting, e.g. name.submac.site (Cloudflare Pages); custom domain later; QR code + share link
- Mini-apps = installable PWAs (trackers, calculators, booking/order forms, quizzes); form/data storage via Supabase
- Templates: business page, shop catalog with WhatsApp order button, restaurant menu, portfolio, CV site, event invite, link-in-bio
- Brand kit from a logo photo (colors/fonts); AI images; plain-language SEO
- Advanced (hidden): view/download code, export ZIP, push to GitHub
- Native APK builds: later, via cloud CI

## Built-in connectors (no app registration needed)
- No login: Open-Meteo weather, Wikipedia, currency rates, OpenStreetMap search, any website/RSS, YouTube transcripts
- On-device: contacts, calendar, alarms/reminders, files/photos, share sheet, call/SMS drafts (user taps send)
- Email via IMAP/SMTP + app password: Gmail, iCloud (mail/calendar/contacts), Yahoo, Zoho. NOT Outlook/Hotmail (basic auth off since Sept 2024) -> Composio
- Personal API key/token: Notion, Airtable, Todoist, Trello, Asana, ClickUp, Linear, Jira/Confluence, GitHub, Cloudflare, Supabase, WordPress, Stripe, Shopify (custom app token), Telegram bot, Home Assistant, Brave/Tavily/Serper search, Gemini, OpenAI-compatible, ElevenLabs
- Everything OAuth-only (Google Drive/Calendar, Slack, Microsoft 365...) via Composio
- Custom MCP: paste a server URL
- Connectors screen: logo, one-line benefit, Connect -> short step-by-step guide; keys encrypted on device

## Phase 2: Connectors (MCP) + Talk & see
- Generic MCP client in the app (Streamable HTTP, JSON-RPC tools/list + tools/call), tools exposed to the agent
- First connector: Composio. Settings > Connectors > paste Composio key (ck_, stored encrypted on device). App calls https://connect.composio.dev/mcp with header x-consumer-api-key; agent uses Composio meta tools (SEARCH_TOOLS, MANAGE_CONNECTIONS, MULTI_EXECUTE_TOOL) so it can reach all the user's connected apps
- Connecting a new app: auth link opens in browser, agent waits then continues
- Plain-language action cards ("Sending email via Gmail") + confirm before sending/posting/deleting
- Later: add any custom MCP server by URL
- Voice input (speech-to-text) + read aloud (TTS); hands-free voice mode later
- Camera button: snap photo → ask; on-device OCR for documents
- PDF/Doc reading (text extraction) for attachments

## Phase 3: Smarter agent
- Built-in web search tool (no key needed by default) with sources shown
- Memory: remembers user facts across chats (editable list in Settings)
- Skills/"Actions" gallery: one-tap templates (Clean up Downloads, Summarize PDF, Translate photo, Make a budget)
- Python/JS runtime (bundled interpreter) so code tasks work without Termux
- Phone actions via intents: set alarm/reminder, calendar event, open app, share, call/SMS draft (user confirms)

## Phase 4: Easy setup & accounts
- (Later, user decision) Built-in default SubMac model (proxy via Supabase Edge Function) so non-tech users need no API key; advanced users add their own
- Google sign-in; chat sync across devices already on
- Image generation; shareable chat links

## Phase 5: Polish & release
- Home-screen widget + quick-tile "Ask"
- Real release keystore, Play-compliant flavor (SAF instead of all-files), iOS build
- Crash reporting + in-app feedback

## Multi-task handling (requested 2026-10-13)
- Long tasks run in the background per conversation; the composer stays usable.
- New messages get answered while a task runs; a task status chip shows progress; results post into the chat when done; Stop per task.
