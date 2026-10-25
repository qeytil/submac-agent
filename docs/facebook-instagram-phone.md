# Facebook, Messenger and Instagram on the phone ("phone engine") — spec

Status: **spec only, nothing built** (written 2026-10-19 evening, EAT). Implement on `dev` after the owner reads it.
Model: the shipped WhatsApp phone engine (`docs/project-state.md` "WhatsApp on the phone", `lib/services/whatsapp.dart`,
`whatsapp_text.dart`, `android_native/WhatsApp.kt`, `WaHands.kt`, `lib/screens/whatsapp_screen.dart`).

## 1. The decision this implements (owner, 2026-10-19 18:30 EAT)
- No Composio (or any third-party connector) for users' Facebook/Instagram.
- Until SubMac has its **own Meta app** (app review + business verification), Facebook (profile, Messenger, Pages via the app)
  and Instagram run on the **phone engine** = Path 2, same as WhatsApp: **notification access + accessibility** on the
  user's own phone, in the user's own installed apps.
- Hard rules: **approval before posting / sending / replying**, **human-paced**, **no bulk**, **phone must be unlocked**,
  **no browser automation**, **no unofficial clients** (no private APIs, no scraped web sessions, no cookies).
- Later: own Meta app -> official Graph API (Pages: posts, schedule, comments, Page inbox, insights; Instagram professional
  accounts: publishing, comments, DMs). The phone engine stays for personal profile + Messenger, which the Graph API does not cover.
- Owner also wants **frictionless dashboard monitoring** for whatever ships: usage, health, failures per feature (section 9).

## 2. Scope

### Apps (Android packages)
| App | Package | Phase 1 | Notes |
|---|---|---|---|
| Messenger | `com.facebook.orca` | messages (notifications + hands) | Main channel for person-to-person Facebook chats. |
| Instagram | `com.instagram.android` | DMs + activity (notifications + hands), post prep | |
| Facebook | `com.facebook.katana` | activity (comments, mentions, tags, group posts), post prep, comment reply | Facebook routes chats to Messenger; the FB app itself has no chats to read. |
| Meta Business Suite (Pages) | `com.facebook.pages.app` | Page inbox messages + Page comments via notifications; reply | "Pages via the app". Hands later (phase 3). |
| Facebook Lite | `com.facebook.lite` | notifications only (inbox / watch), no hands | Common on low-end phones in Somalia/East Africa. Hands not planned (custom-drawn UI, little accessibility tree). |
| Instagram Lite | `com.instagram.lite` | notifications only | Same reason. |

Out of scope: Threads (`com.instagram.barcelona`), WhatsApp (already shipped), Messenger Kids, Workplace.

### What SubMac can do (user-facing)
- "Who messaged me on Messenger / Instagram?" -> inbox from notifications (works with the screen off; reading only).
- "Reply to Amina on Messenger: ..." -> approval card -> send (from the notification when it is still there, else open the
  chat, type, press Send, verify).
- "Read my chat with Hodan on Instagram" -> opens the thread, reads the visible messages (+ scroll for older).
- "What happened on Facebook today?" -> activity digest from notifications (comments, mentions, tags, Page messages).
- "Reply to that comment on my Page: ..." -> approval card -> opens the post from the notification, types, presses Reply, verifies.
- "Post this photo on Instagram with this caption" / "Post on my Page: ..." -> approval card -> SubMac **prepares** the
  composer (media + caption typed) and **the user taps Post/Share** (phase 4 decision, section 5).
- Bots: watch a Messenger chat / Instagram DM / Page inbox and draft replies (approval), daily activity digest.

### What SubMac will never do (refused in the tool, not just the prompt)
- Bulk: no `send_bulk` action at all on Meta apps, one recipient per call, and a bulk detector (section 6).
- Engagement automation: no likes, follows/unfollows, friend requests, group joins, story-view farming, auto-comments on
  other people's posts, mass tagging, "DM everyone who liked my post".
- Cold outreach: messaging someone who never wrote to the user is limited to a few per day (section 6).
- Acting while the phone is locked, browser automation of facebook.com / instagram.com, unofficial clients, saved cookies.
- Calls in Messenger/Instagram (phase 1-4). Possible later as `call` like WhatsApp; not needed now.
- Logging in, changing account settings, deleting content, reading Marketplace, payments.

## 3. Tool design (Dart)
Three tools, one per app family, each with an `action` (mirrors `whatsapp`). Three small tools beat one mega `social` tool:
the model picks by the app the user named, the enums stay short, and each guide rides only when that app is mentioned.

**Toolbox cost rule (decided):** a Meta tool's definition is only sent when that app is **installed and switched on in its
setup card** (section 8). The expert guide (`withGuide`) rides only when the chat mentions the app (hint regex, like
`WhatsAppTools.hint`). A user who never set up Instagram pays zero tokens for it.

### `messenger` (Messenger + Page inbox)
- `action`: `inbox | read | reply | send | send_file | watch | status`
- `to`: chat name as shown in Messenger (person or group). **No phone numbers, no usernames** (Messenger has no reliable deep link by
  number; we never guess identities).
- `message`, `path` (send_file), `more` (read older), `unread_only`, `keyword` / `instruction` / `op` (watch).
- `app`: `messenger` (default) | `page` (Meta Business Suite Page inbox). Same idea as WhatsApp personal/business.
- No `send_bulk`, no `call` (yet).

### `instagram`
- `action`: `inbox | read | reply | send | activity | comment_reply | post | watch | status`
- `to`: thread name or `@username` (username only matches a thread that already exists in the store or the DM list; no cold DMs
  beyond the daily new-chat cap).
- `kind` (post): `feed | story | reel`. `media`: list of workspace paths (1-10 images for feed, 1 image/video for story/reel).
- `caption`, `message`, `comment` (comment_reply: which notification, by id from `activity`), `more`, `unread_only`, watch fields.

### `facebook` (Facebook app + Page posting)
- `action`: `activity | comment_reply | post | watch | status`
- `as`: `me` (profile, default) | `page` (Page through Meta Business Suite; if several Pages, `page_name`).
- `text`, `media` (paths), `comment` (activity id), watch fields.
- Facebook chats are **not** here: the tool description says "for chats use messenger".

### Shared executor
`lib/services/meta_apps.dart` (`MetaAppsTools`): one executor with three definitions (`definitionFor(app)`), shared
approval (`approvalFor`), status, explain-state texts, limiter, trust. Pure helpers in `lib/services/meta_text.dart`
(`MetaText`: package mapping, display names, `@username` normalisation, thread matching, activity parsing into
comment / mention / tag / like / follow / page_message / other, flags reuse `WaText.flags`, bulk detector, limiter
`MetaLimiter`), unit tested in `test/meta_apps_test.dart`.

Results the agent sees use the WhatsApp style: short lines, "Sent on Messenger to Amina.", "Not sent yet: ... Tell the user to tap
Send in Instagram.", "Error: the phone is locked ...".

### Approval cards (always, also with Full access)
| Action | Card | Confirm | Edit | Who presses the final button |
|---|---|---|---|---|
| messenger reply/send, instagram reply/send | "Reply to Amina on Messenger?" + text | Send | yes | SubMac (verifies), fallback: typed for the user |
| send_file | "Send photo.jpg to Amina on Messenger?" | Send | caption | SubMac via share picker; fallback user |
| comment_reply (IG/FB/Page) | "Reply publicly to Hodan's comment on your post?" + text | Reply | yes | SubMac (verifies) |
| post (IG/FB/Page) | "Post on Instagram (feed)?" + caption + media names + "You tap Share" | Prepare | yes | **The user** (phase 4) |

- Bots in the background ask through the approval notification (existing path).
- **Trust** (skip the card): only for private messages (`reply`, `send`) and only per bot per app (`meta_trusted` = set of
  `app:botId`, phone-only, bot settings switch "Can send on Messenger/Instagram without asking"). **Never** for public actions
  (comment_reply, post) and office trust does **not** bypass public actions. Decided: public speech always gets a human look.

## 4. Native pieces (Kotlin)
Reuse, don't fork. WhatsApp.kt already contains a good MessagingStyle parser, a per-chat store and a RemoteInput quick reply.

1. **`ChatNotif.kt` (extract, small refactor):** move the MessagingStyle parse (`EXTRA_MESSAGES`, sender_person, big text fallback,
   group detection), the RemoteInput "Reply" action pick and `quickReply` sending out of WhatsApp.kt into a shared helper.
   WhatsApp.kt keeps its behaviour (regression-tested on a phone before the Meta work ships).
2. **`MetaApps.kt` (store + intents):**
   - `isMeta(pkg)`, per-package names, `installed`, app version (`versionName`, cut to 24 chars, for monitoring).
   - **Chat store** `meta_chats.json` (app files, never synced): key `pkg|conversation` (shortcutId / tag when present, else
     lowercased title); newest 40 messages per chat, 150 chats, 7 days (same numbers as WhatsApp).
   - **Activity store** `meta_activity.json`: one row per non-chat notification (FB comment/mention/tag/group post, IG
     like/comment/follow/mention, Page comment): id, pkg, kind (classified by `MetaText` rules + channel id), title, text (1,000
     chars), time, the notification's `contentIntent` kept in memory (to open the exact post for comment_reply) and its RemoteInput
     reply action if it has one. Newest 100 per app, 7 days.
   - Skip: group summaries, "Uploading…/Posting…" progress notifications, login/security codes (never stored: notifications
     from these apps whose text matches a code pattern or "login"/"code"/"security" words are dropped).
   - `capture(sbn)` returns (app, chat, newest text) for bot watches; `removed(sbn)` clears unread + reply action.
   - Intents: launch app, open DM list, **Instagram official share intents** (`com.instagram.share.ADD_TO_FEED`,
     `com.instagram.share.ADD_TO_STORY`, plain `ACTION_SEND` image/video to `com.instagram.android` for reel/feed), Facebook
     `ACTION_SEND` image to `com.facebook.katana` / `com.facebook.pages.app`, Messenger `ACTION_SEND` to `com.facebook.orca`.
     Files go through the existing non-exported read-only provider `com.submac.agent.wafiles` (`WaFiles.kt`, reused as is;
     no new exported component). Note: Meta apps drop pre-filled text from share intents (platform policy), so captions are
     **typed by MetaHands** or, as fallback, put on the clipboard with "Paste the caption, then tap Share".
3. **`MetaHands.kt` (accessibility, like WaHands):** per app: find entry box, Send button, verify the message appears and the box
   empties; open a thread by name via the app's search; read visible thread messages + scroll up; comment reply (open from the
   saved contentIntent, find reply box, type, press, verify); composer prepare (wait for composer, type caption into the caption
   field, stop before Share/Post and report `ready_for_user`). Lookup order as in WaHands: view ids first -> content
   descriptions in ~12 languages (EN, SO, AR, FR, SW, ES, PT, DE, IT, TR, HI, ID) -> visible text. **All ids/descriptions must be
   collected on a real device from current app versions** (Instagram exposes some resource ids; Facebook/Messenger are mostly
   Litho/React views with descriptions only). Keep them in one table per app at the top of the file so an app update is a
   one-table fix.
   States returned: `sent | opened_for_user | ready_for_user | not_found | locked | phone_control_off | not_installed |
   ui_changed | unsure | no_button | timeout`.
4. **NotifListener:** dispatch `MetaApps.isMeta(pkg)` like WhatsApp (respect a per-app "keep messages" switch); bot watch gap
   2 min per chat for messages, 10 min for activity.
5. **Bridge** (`submac/system`): `metaStatus`, `metaInbox(pkg, query, unread, limit, per)`, `metaActivity(pkg, kinds, limit)`,
   `metaChat(query, pkg)`, `metaQuickReply(chat, pkg, text)`, `metaCapture(pkg, on)`, `metaClear(pkg)`, `metaAct(json)` (async,
   same `waAsync` style with timeout).
6. **Manifest:** `<queries>` for all six packages + the Instagram share actions.
7. **Locked check (stricter than WhatsApp, decided):** every outgoing step, **including notification quick replies**, first
   checks `KeyguardManager.isKeyguardLocked`; locked -> state `locked`, nothing sent. Owner rule "phone must be unlocked" taken
   literally for Meta apps. (WhatsApp allows locked quick replies; we can relax Meta later if the owner wants.)

## 5. Safety and approval rules
- Approval card before every send / reply / comment / post (table above). Edit keeps the user's text exactly.
- **Posting (decided): SubMac prepares, the user taps Post/Share.** Reasons: posts are public and permanent-feeling, composer UIs
  change often, and the audience selector (Public / Friends / a Page) cannot be verified reliably by accessibility. After
  phase 4 has clean monitoring numbers, a later setting "Let SubMac press Post after I approve" can be added (still never for
  bots in the background).
- Comment replies are pressed by SubMac after approval (short, on the user's own posts/Page only; the reply box is under a
  known comment, so the target is verifiable). Replying to comments on other people's posts: not supported.
- Identity: never guess who someone is. `to` must match one chat in the store or the app's search results exactly (case- and
  accent-insensitive); two matches -> ask the user which one ("There are two chats called Ahmed: ...").
- Groups: reply only when the user asked; never forward private chat content into a group.
- Privacy: stores are phone-only and never synced; `Repo.forBackup` replaces `messenger`/`instagram`/`facebook` tool results with
  "<App> result (kept on the phone only)" and strips call arguments to the action name, exactly like `whatsapp`.
- Security codes / login notifications from Meta apps are never stored or shown to the model.
- The guide (per app) teaches tone: short, human, the chat's language (Somali, Arabic, English), no markdown, no hashtags spam
  (max 5 on Instagram, none on Messenger), never invent prices or promises for business accounts.

## 6. Rate limits (human pace; enforced in `MetaLimiter`, counts kept on the phone)
| What | Gap between | Per hour | Per day |
|---|---|---|---|
| Messenger messages (person + Page inbox) | 8 s | 30 | 120 |
| Instagram DMs | 12 s | 20 | 80 |
| New chats (someone who never wrote to the user, any app) | – | 2 | 5 |
| Comment replies (IG + FB + Page) | 20 s | 15 | 60 |
| Posts prepared (each app; IG feed+story+reel together) | – | 3 | 6 |
| Thread reads (opening chats with hands) | 3 s | 60 | – |
- **Bulk detector:** the same or near-same text (normalised, >80% token overlap) to more than 3 different chats within 30 minutes
  is refused: "This looks like a bulk message. SubMac sends Messenger/Instagram messages one person at a time." Bots get the same.
- Over a limit -> plain error with when it frees up; never queue silently.
- Instagram is known to "action block" accounts that act fast; the numbers above are deliberately below normal human peaks.
  They live in `MetaLimiter` constants for phase 1; phase 0 adds optional `ai_settings` overrides only if real data asks for it.

## 7. Bot plugin
- `bot_powers.dart`: plugins `messenger`, `instagram`, `facebook` under the **Phone** power (labels "Messenger", "Instagram",
  "Facebook"; blurbs "Read new messages and draft replies on Messenger (needs Phone)" etc.), stored in `powers_off` like `whatsapp`.
- Watches: `watch` adds a `BotWatch(app: 'Messenger' | 'Instagram' | 'Facebook' | 'Meta Business Suite', chat filter, keyword)`.
  Wake text: "New Messenger message in "<chat>": "<text>". If it needs an answer, draft a short reply in the chat's language and
  send it with messenger action "reply"; the owner approves it first." Activity watches wake at most every 10 min with a batch.
- Public actions from bots always ask (no trust bypass, section 3). Bots cannot `post` without the owner approving each one and
  the owner tapping Post.
- Cloud bots: none of this runs in the cloud (phone engine only). `hand_to_phone` already covers "do it when the phone is back".

## 8. Setup screen
Apps > On this phone > **Facebook & Instagram** (`lib/screens/meta_apps_screen.dart`, same building blocks as
`whatsapp_screen.dart`): one card per installed app (Messenger, Instagram, Facebook, Meta Business Suite; Lite apps shown with
"messages only"), each with:
- **Use with SubMac** switch (default off; on = tool offered to the agent, notifications kept).
- Status rows with live state + deep links: Notification access (shared), Phone control (shared), "Keep messages on this phone"
  (per app), Clear saved messages.
- Plain notes: what SubMac can and can't do, "You approve every message. Posts: SubMac gets them ready and you tap Post.",
  "Works only while your phone is unlocked.", "SubMac never likes, follows or messages strangers for you."
- One-line honesty note: "Meta can limit accounts that act too fast. SubMac keeps a human pace."
- Status JSON (`metaStatus`): per app installed/version/enabled/capture/chats/activity count, notifRead, phoneControl, locked.

## 9. Dashboard monitoring (frictionless, per feature, for WhatsApp too)
Goal: one glance tells the owner whether each phone-engine feature is used, healthy, and where it breaks — **without any
message text, names or usernames**.

### Events (extends Plan 2.6 `events`, migration `2026xxxx_app_events`)
- New kinds: `app_action` (an attempt finished), `app_setup` (a setup step changed), `app_approval` (the card's answer).
- New allowed props keys (still scalar, strings ≤ 24 chars, row ≤ 400 chars): `app` (`wa`, `wab`, `ms`, `pg`, `ig`, `fb`,
  `fbl`, `igl`), `act` (inbox/read/reply/send/send_file/activity/comment_reply/post/watch/call), `ok` (bool), `st` (result
  state: sent, opened_for_user, ready_for_user, not_found, locked, ui_changed, limit, bulk, timeout, error...), `tv` (target app
  version, e.g. "Instagram 412.0.0.35"), `ms` (duration), `by` (`me` | `bot`), `path` (`notif` | `hands` | `intent`), `ans`
  (approve | edit | decline). Existing keys stay.
- `log_events` + table check updated to the new kinds/keys (backward compatible: old apps keep working).
- App: `Events.I.log('app_action', props: {...})` after every Meta (and WhatsApp) action in the executor; `app_setup` when a
  switch/permission changes; `app_approval` from the approval card result.

### Server
- `apps_summary(p_days)` (service role): per app -> attempts, ok, success rate, users, by action, by state (top failures), by
  `tv` (success per target app version — the early warning that a Facebook/Instagram update broke the hands), by path
  (notif vs hands vs intent), approvals (approve/edit/decline), setup funnel (installed -> switched on -> notif -> phone control).
- `ai-admin` action `apps_summary {days: 1|7|30}`.
- Hourly cron (existing bench cron) adds a **health check**: any app with ≥ 20 attempts in 24 h and success < 70%, or a `tv`
  with ≥ 10 attempts and success < 50%, writes an `app_health` row (or reuses `safety_flags` with category `app_health`,
  user null — decide at build time; prefer a tiny `app_health` table) that the dashboard shows as a red banner on Overview.

### Dashboard "Phone apps" tab (`tools/proxy-admin/index.html`)
- Day switch 1/7/30. One card per app with a health pill (ok ≥ 90%, warn 70–90%, bad < 70%, "no data"), attempts, people,
  success, approvals answered "edit"/"decline" share.
- Table per action: attempts, success, top 3 failure states in plain words ("Chat not found", "App screen changed",
  "Phone locked", "Hit the hourly limit").
- "Broke after an app update?" table: target app versions with success per version.
- Setup funnel per app. Same escaping/style as the Events tab.

## 10. Test plan
- **Unit (CI, `flutter test`)**: `MetaText` package mapping, `@username` normalisation, thread matching (exact, accents, two
  matches -> ask), activity classification fixtures (EN/SO/AR notification texts), security-code filter, bulk detector,
  `MetaLimiter` (gaps, hour/day windows, new-chat cap), approval card texts per action, trust rules (never for public),
  backup stripping for the three tool names, tool offered only when enabled.
- **Native fixtures (manual, debug build)**: dump real notifications of each app (`adb shell dumpsys notification --noredact`)
  into `test/fixtures/meta/*.txt` (names replaced) and check the parser against them.
- **Real phone matrix**: Android 10, 13, 14, 15; current Play versions of each app; languages EN, SO, AR (RTL); light/dark;
  phone locked / unlocked / screen off; personal + Page account; slow network.
- **Golden checks**: inbox after 3 Messenger chats; quick reply from notification (unlocked) and refusal when locked; send to a
  chat by name (hands), two chats with the same name -> ask; IG DM read + older; IG reply; FB activity digest; Page comment reply;
  IG feed post prepared with 2 photos + caption, user taps Share; story; FB Page post prepared; bulk detector trips at the 4th
  chat; new-chat cap; bot watch on a Messenger chat drafts a reply with approval; bot cannot post without the owner; backup
  contains no message text; dashboard tab shows the attempts with states and app versions.

## 11. Risks
- **Meta terms and account limits:** automating Meta apps through accessibility is not an official integration. Mitigation: the
  user acts on their own account on their own phone, every outgoing item is approved, human pace, no engagement automation, no
  bulk, no cold outreach beyond 5/day. Residual risk of an action block (Instagram especially) remains and is stated in setup.
- **Google Play accessibility policy:** fine for the sideloaded beta; before any Play listing SubMac needs the prominent
  disclosure + consent screen and the AccessibilityService declaration (applies to WhatsApp too).
- **UI churn:** Facebook/Messenger/Instagram ship weekly and use generated views. Mitigation: id/description tables per app,
  `ui_changed` state with typed-for-user fallback, per-version monitoring (section 9) to spot breakage within hours.
- **Notification gaps:** users with message previews off, muted chats, message requests (IG/Messenger often notify "sent you a
  message" without text), E2EE chats on some devices -> inbox shows "new message (preview hidden)" and suggests `read`.
- **Quick reply availability:** Messenger and Instagram usually attach a RemoteInput Reply action to DM notifications; Business
  Suite and Facebook comment notifications may not. Treat as optional; hands are the fallback.
- **Multiple accounts** (IG account switcher, several Pages): phase 1 acts in whatever account is active and says so; `page_name`
  for Pages in phase 3; account choice for IG later.
- **Captions not pre-fillable** via share intents (Meta policy): typed by hands; clipboard fallback.
- **Battery/latency:** none new; uses the existing listener and accessibility service.

## 12. Build order and effort (one dev, on `dev`, each phase its own version bump + Dev CI)
| Phase | What | Effort |
|---|---|---|
| 0 | Monitoring foundation: `app_events` migration, `log_events` update, `apps_summary` + ai-admin action, dashboard "Phone apps" tab, WhatsApp instrumented (`app_action/app_setup/app_approval`). Ships value immediately for WhatsApp. | 0.5–1 day |
| 1 | Messenger + Instagram **from notifications**: `ChatNotif.kt` extract (WhatsApp regression check), `MetaApps.kt` stores, bridge, `meta_text.dart` + tests, `messenger`/`instagram` tools (inbox, reply via notification, watch, status), approval + trust, setup screen, bot plugins, backup stripping. | 2 days |
| 2 | **Hands** for Messenger + Instagram DMs: open by name, read + older, send with verify, send_file via share picker, typed-for-user fallback, rate limits, bulk detector, new-chat cap. Real-device id tables. | 2–3 days |
| 3 | **Facebook + Pages**: activity store + digest, Business Suite Page inbox (`messenger app:page`), comment_reply for FB/IG/Page (open from notification, type, press, verify), FB Lite / IG Lite notification-only. | 2 days |
| 4 | **Posting prep**: IG feed/story/reel via official share intents + caption typing, FB profile / Page composer prep, `ready_for_user` flow, clipboard fallback, post limits. | 1.5–2 days |
| 5 | Real-phone test pass across the matrix + fixes, docs, beta APK. | 1–2 days |
| Later | Own Meta app: business verification + app review; Graph API for Pages (post/schedule, comments, Page inbox, insights) and IG professional accounts; switch Pages/IG business traffic to the API, keep the phone engine for personal profile + Messenger; same verification can unlock official WhatsApp Business. | weeks (Meta review time) |

Total to a testable beta: about 9–12 working days. Recommended first slice: phases 0 + 1 (monitoring + notification-only
Messenger/Instagram) — lowest risk, no UI automation, visible value in two to three days.

## Decided while the owner was away (2026-10-19)
- Three tools (`messenger`, `instagram`, `facebook`) instead of one; tools are sent only when the app is switched on in setup.
- Facebook chats go through `messenger`; the `facebook` tool is activity, comment replies and posts only. Pages: Page inbox under
  `messenger` (`app: page`), Page posts under `facebook` (`as: page`), both via Meta Business Suite.
- Posts: SubMac prepares, **the user taps Post/Share**; comment replies and private messages are pressed by SubMac after approval.
- Trust (no card) only for private messages per bot per app; never for public actions; office trust does not bypass public actions.
- Phone must be unlocked for every Meta outgoing step, **including notification quick replies** (stricter than WhatsApp).
- No calls, no bulk action, no engagement automation, cold chats capped at 5/day; limits in section 6.
- Lite apps: notifications only. Threads out of scope.
- Monitoring: extend the Plan 2.6 `events` table with `app_action/app_setup/app_approval` (no text, no names) and add a
  "Phone apps" dashboard tab with per-app-version health; instrument WhatsApp first (phase 0).
