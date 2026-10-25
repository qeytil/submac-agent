# SubMac Plan — Clean Rebuild (Oct 2026)

Owner decisions (2026-10-23). This replaces earlier routing and monetization plans where they conflict.

1. **One model.** Users get one thing: the *SubMac model*. No aliases (smart/fast/think/lite/vision/somali), no Auto/Quick/Think picker, and no model names anywhere in the app.
2. **Two routers only.**
   - **Chat router:** picks a model and keeps it until it fails, then moves to the next healthy one.
   - **Live router:** hands out Gemini Live API keys.
3. **Billing is volume, not model.**
   - Coins are removed entirely.
   - Users buy usage one of two ways:
     - **A. Packages:** Weekly or Monthly, each with a daily amount and a total.
     - **B. Pay as you go:** the user picks a number of tokens and pays for them.
4. **Clean UI.**
   - Short words, nothing technical shown, and no over-explaining.
   - Settings is a list of sections. You see what's inside only after tapping a section.
   - No divider lines between rows or sections.
5. **Agent flow** has to be fast, calm and survive stress: timeouts, retries, interruptions.

Background audits: `docs/audit/` (ui, agent, backend, unfinished, timing).

---

## Rules for all three devs

- **Branches:** everyone works off `dev`, one branch each: `rebuild/dev1-engine`, `rebuild/dev2-billing`, `rebuild/dev3-ui`.
- **Merging:** merge to `dev` through small PRs. `main` only after phone tests and owner OK.
- **Versions:** bump the `pubspec.yaml` version on every code commit. Docs-only commits use `[skip ci]`. No secrets in git.
- **File ownership** (to avoid merge fights):
  - **Dev 1:** `lib/app_state.dart` (agent and chat parts), `lib/services/` (except billing), `supabase/functions/ai-chat`, `bot-run`, and the router migrations.
  - **Dev 2:** `lib/services/billing/`, `lib/screens/billing/`, `supabase/functions/billing-*`, `_shared` payment code, and billing migrations.
  - **Dev 3:** `lib/screens/` (except billing), `lib/widgets/`, `lib/ui/`, `lib/theme.dart`, `lib/main.dart`, and translations.
  - **Anything shared:** say so in the PR and tag the owner of that file.
- **Splitting `app_state.dart`:** Dev 1 splits it first (week 1) into `chat_controller`, `agent_runner`, `tool_router`, `bots_controller`, `settings_store` and so on. Dev 2 and Dev 3 then only touch the new small files.
- **Contracts between parts are fixed here.** Changing one needs all three to agree.

### Contract A — Server → app (Dev 1 ↔ Dev 2 ↔ Dev 3)
- The app calls one model name: `submac`.
- The chat stream sends a heartbeat (`: ping`) at once, then every 10 s.
- Errors arrive as an SSE `error` event with one of these codes:
  - `busy` (with `Retry-After`)
  - `too_long`
  - `limit_daily`
  - `limit_total`
  - `no_plan`
  - `blocked`
  - `server`
- Every response carries the user's balance in headers:
  - `x-submac-today-left`
  - `x-submac-total-left`
  - `x-submac-resets-at` (ISO, EAT midnight)
  - `x-submac-plan` (`free|weekly|monthly|payg`)

### Contract B — Usage → billing (Dev 1 ↔ Dev 2)
- **Before the call:** ai-chat calls one DB function, `usage_gate(user_id, source)`. It answers allow/deny, today-left, total-left, resets-at and reply cap.
- **After the call:** ai-chat calls `usage_charge(user_id, tokens_in, tokens_out, source, request_id)`. It is idempotent by `request_id`.
- **One price for everything.** Tokens are counted raw: input + output, with cached input at a discount if Dev 2 wants. No model multipliers.
- **Live voice** charges the same balance per minute via `usage_charge(source='live')`.
- **Dev 2 owns** the functions and tables. **Dev 1 owns** the calls.

---

## PART 1 — Dev 1: Engine (router, agent flow, timing, stress) — *Hark*

**Goal:** One model, a sticky router, first word fast, never a 4-minute wait, and tasks that survive interruptions.

### 1.1 Single model + sticky chat router (server)
- **Remove every alias and its logic:**
  - the Somali swap
  - vision forcing
  - the grace/lite alias
  - think aliases
  - spare routes from other aliases
  - the per-alias admin editing

  Keep one route list.
- **Shared current-route pointer** in the DB, returned inside the gate call (no extra round trip).
  - Requests try the current route first with a per-chat sticky key.
  - If that fails, the same request moves on to the next healthy route.
- **When to swap:** 3 hard failures or 2 first-byte timeouts within 60 s. The swap is a compare-and-set, so it happens once, not once per user.
- **Rested routes:** a swapped-out route rests with backoff (1 → 2 → 4 → 8 → 15 min). A probe every 1–2 min marks it usable again. The pointer doesn't jump back while the current route is fine.
- **429 overflow** (capacity) sends that one request to the next route without moving the pointer.
- **Model checks:** every route must support tools, images and 128k+ context, and write good Somali.
  - Pick the primary and the fallbacks by these four checks.
  - Log "Somali chat served by fallback".
- **Keep:**
  - per-chat sticky keys
  - key rests by error type
  - capability filters
  - "commit only on real output"
  - `cutTail`
  - history repair
- **Write key and route state only when it changes**, never on every success.
- **Over-limit grace** = same model with a `max_tokens` cap, never another model.
- **Effort hint header** `x-submac-effort: low|normal|high`, mapped to the model's reasoning setting.
  - `low` for greetings, short questions and step 1.
  - "Think harder" in the app, if kept, sends `high`.

### 1.2 Live router
- Sticky key until it fails, the same rules as chat.
- Decrypt only the key in use (today it decrypts up to 6 one after another).
- 5 s limit per key on Google's token fetch, 12 s total. Fold the start-up checks into one gate call.
- **Target:** tap Call → first audio under 2.5 s.

### 1.3 Timeout budget (server always finishes before the app gives up)

| Where | Limit |
|---|---|
| Server | gate 2 s; per attempt 6 s headers / 10 s first output; no new attempt after 18 s; hard stop 25 s; heartbeat every 10 s; mid-reply silence 45 s → `cutTail`; reply total under the platform wall clock (confirm Supabase plan: 140 s on Free); non-streamed calls 45 s; `busy` + `Retry-After` 15–30 s with jitter |
| Server | stop everything when the phone hangs up (`req.signal`); don't charge for replies nobody received |
| App | headers 10 s; stream silence 30 s; 1 auto-retry before any output; "continue" after a drop at most 2× per step; at 45 s with no word → "SubMac is busy. Tap to try again." (message kept) |
| bot-run | per model call 40 s; per job 120 s; no new jobs after 60 s of a round |

### 1.4 First word faster

| Target | Value |
|---|---|
| Greeting | ≤ 1.5 s (p50) |
| Task first line | ≤ 2.5 s (p50) |
| All replies | ≤ 5 s (p90) |

- Upload attachments in parallel, after starting the model call. Compress gallery photos to 2048 px.
- Send each image once. Later steps get a one-line note instead.
- Never block step 1 on connected-app tools. Fix `_mcpRefreshing` never resetting.
- Session refresh on resume and every 50 min, with a 5 s limit.
- Gzip request bodies.
- Register the run (per-chat lock) at the top of `send()`, before any await. This stops double agents and double charges.

### 1.5 Calm, short agent output
- Cut the system prompt about in half. Send the app-tour text only when asked.
- Remove the forced "say every 6 steps" note.
- The opening line and the closing "Want me to…?" become conditional, not default.
- One rule for questions: at most 1 clarifying question, unless it's a build.
- One-line tool descriptions.
- Merge duplicate tools:
  - the money notebook and business books
  - 3 document makers → 1
  - 3 readers → 1
  - 5 "later" tools → 1 scheduler
  - 3 memory tools → 1
- Narrow the trigger words that switch tool groups on. Groups switch off after a few turns without use.
- Run the truth check before showing the final answer, so answers no longer appear and then vanish.
- Professional tone: answer first, no filler, the user's language.

### 1.6 Stress and recovery
- Per-batch budget for parallel tool results (24k chars shared).
- Compaction never blocks a step. Read `x-submac-window`. Summary limit 45 s.
- Cooldowns per lane (foreground vs background), so a busy bot never pauses the user's chat.
- Moderation de-dupe in the DB. Only the user's real message is screened.
- Keep-alive service starts when a task starts, with a partial wake lock (10 min safety release).
- Abort and continue at once when the network changes.
- **Interrupted tasks:** save a small "task in progress" record. On start-up, offer "This task was interrupted. Continue?" Approvals survive a restart.
- **Background questions:** asked by notification with a time limit. Scheduled runs never bring the app to the front.
- Re-arm scheduled tasks after a reboot. A missed one-off runs late with "(late)".
- **Approvals:**
  - Add Somali and Arabic risky words.
  - Always ask before position taps, Enter, or scripts on a page with a filled form.
  - Stricter read-only test for app actions.
  - Stop cancels a task's open cards.
- **Cloud bots:** send only memory/notes jobs to the cloud. The phone runs "waiting for phone" jobs when it wakes. Reword the "works when phone is off" promise.
- **Visible failures:** crash reporting, no empty error handlers on the main paths, and friendly fixed error text from the server (never raw text).

### 1.7 App code to delete (Dev 1)
- **Model roles and routing:**
  - `Cloud.smart/fast/think/vision`
  - `roleRef`, `_route`, `_withThinking`, `_quickRoute`, `_seeRef`
  - `canLift/liftIf`, `TurnRouter.escalate`, `_backupFor`
  - `_noToolModels`, `_liteModels`
- **Whole files:** `auto_router.dart`, the model table in `context_window.dart`.
- **Dead code in `quick_lane.dart`:** `effortFor`, `quickMaxTokens`. Keep `laneFor`.
- **State:** `thinking` in `local_store` (Dev 3 removes the chip).
- **Leftovers:** Easy mode leftovers; stale `maxSteps`/`showSteps` reads.
- **Cut features:**
  - wake word
  - Telegram bridge
  - coder bot and code tools
  - video tool
  - image-generation prompt text (until images ship)

### 1.8 Ops
- Re-export every live edge function and commit it.
- Pin `verify_jwt` per function in `supabase/config.toml`, and have ai-chat verify the token itself.
- Commit every hand-applied DB change as a migration.
- Admins matched by user ID, not email.
- Measure `ttfw_ms` by lane, plus fallback-route counts, on the dashboard.

**Done when:**
- p50/p90 targets are met on a real phone from Mogadishu.
- No wait is longer than 45 s before a clear message.
- Killing the app mid-task offers Continue.
- One model name is in the app.

---

## PART 2 — Dev 2: Billing rebuild

**Goal:** Two simple ways to pay, no coins, one price per token, and a payment flow with no friction.

### 2.1 Remove
- Everything about coins:
  - the coin wallet and coin terms
  - buy-coins, exchange and auto-exchange
  - the first-top-up bonus
  - coin→token rates
  - `somali_wallet` coin code
  - coin columns and functions
- Model multipliers (Standard/Advanced/Premium) and any "free = standard models only" rule.
- The old Day/Starter/Plus/Pro passes and the 12-month token packs. They're replaced by the products below.
- Migration plan for any test balances: convert to PAYG tokens at the old rate, then drop the coin tables.

### 2.2 Products (prices are a starting point; owner confirms before launch)

**Free:** a small daily amount (e.g. 60k tokens/day) and a monthly cap. Same SubMac model.

**A. Packages:** one payment buys a period with a daily amount and a total.

| Package | Price | Total | Daily amount | Valid |
|---|---|---|---|---|
| Weekly | $1.25 | 700k | 200k | 7 days |
| Monthly | $4.99 | 3M | 250k | 30 days |
| *(optional Monthly Plus)* | $9.99 | 6M | 500k | 30 days |

**B. Pay as you go:** the user picks a token amount on a slider or presets (e.g. 1M, 3M, 5M, 10M) and sees the price live.
- Base price: $2.00 per 1M (owner to confirm). Small volume discount optional.
- Tokens are valid 12 months.

**General rules:**
- **Spending order:** free daily → package (within its daily amount) → PAYG tokens. Soonest-expiring first.
- **Live voice** uses the same balance per minute (owner sets the rate; old plan was 40k/min).
- **Bots/background** may use at most 50% of a package's daily amount.
- **Day boundary:** midnight EAT (Africa/Mogadishu), sent to the app in `x-submac-resets-at`. The app never assumes UTC.
- **How the UI counts:** "replies", never "unlimited" and never "tokens" on main screens. "About 270 replies" per 1M.

### 2.3 Server
- **New tables:**
  - `plans` (catalogue, editable from the admin dashboard)
  - `subscriptions` (user, plan, starts, ends, daily_amount, total_left)
  - `token_balances` (user, amount, expires)
  - `usage_ledger` (append-only)
  - `payments`
- **Functions:** `usage_gate` and `usage_charge` per Contract B, server-only, idempotent by `request_id`. Remove all coin RPCs.
- **Keep the good parts of the existing payment core:**
  - always re-verify with Sifalo
  - double-tap guards
  - "unknown ≠ failed"
- **Add:**
  - schedule the payment re-check job (every 10 min)
  - expire abandoned checkouts
  - schedule the failed-charge retry queue and ledger sync
  - order lookup so a payment reference must match its order
  - block `billing_enabled` while Sifalo is in staging
  - the return link always goes back to the app (never a JSON page)
- **Renewal:** Weekly and Monthly are one-time purchases with a renewal reminder the day before expiry (no auto-charge with Sifalo).
- **Account deletion** warns about remaining paid balance.
- **Admin dashboard:** edit plan prices/amounts, see payments, refund/adjust via reversing ledger entries.

### 2.4 App (billing screens only — Dev 3's style rules apply)
- One **Plan & usage** screen, reached from Settings:
  - today left
  - total left
  - resets at
  - current plan
  - one **Get more** button
- **Get more** opens two tabs:
  - **Packages:** Weekly / Monthly cards with price, replies per day and total.
  - **Pay as you go:** amount picker with the live price.
- **Pay:** one Sifalo step (EVC Plus / Zaad / Sahal / card), then back in the app with a clear "Done. 3M added."
- **Limit reached** shows a short sheet: "You've used today's replies. Resets at midnight." + Get more. No paragraphs.
- Somali and English copy for every billing string. Arabic from Dev 3's language system.
- Delete:
  - `buy_coins_screen`
  - `exchange_screen`
  - `coin_terms_screen`
  - the coin parts of `wallet_screen`
  - the coin chip in the chat header

### 2.5 Tests
- Unit tests for gate/charge: daily caps, spending order, expiry, idempotency, EAT reset.
- An end-to-end Sifalo staging purchase for each product.
- Webhook-missed recovery.
- A refund reversal.

**Done when:**
- A user can buy Weekly, Monthly or PAYG in under 30 seconds on a phone.
- The balance updates at once.
- No coin code remains.
- The ledger balances.

### Dev 2 status (2026-10-23)
**Done** (PR #31, v1.13.66+132):
- Coins removed in one migration, `20261023_billing_v2.sql` (no conversion: no users on billing). Plan numbers above are the defaults and the prices.
- Tables `plans`, `subscriptions`, `token_balances`, `usage_ledger`, `payments`. Functions `usage_gate`, `usage_charge`, `usage_charge_enqueue` (failed-charge retry).
- Jobs: payment re-check every 10 min (expires abandoned checkouts), retry queue every 5 min, ledger sync every 30 min, renewal reminder the day before a package ends.
- A payment ref must match its order. `billing_enabled` blocked while Sifalo is staging; only `billing_testers` are billed then. Return link always goes back to the app.
- `billing_deletion_warning`. Admin: `billing_plan_update`, `billing_admin_payments`, refund via `billing_payment_reverse` / `billing_adjust`.
- App: Plan & usage and Get more (Packages / Pay as you go), every string in Somali and English.

**Open:** Sifalo staging E2E must confirm that verify-by-order finds hosted-checkout payments (order binding depends on it).

**Needs other owners:**
- **Dev 1:** ai-chat calls `usage_gate` / `usage_charge` (+ `usage_charge_enqueue` on failure), sends the Contract A headers and error codes; bot-run passes the `bot` source. The old coin RPCs are gone.
- **Dev 3:** remove `const WalletChip()` (`home_screen.dart:177`); show `Billing.I.deletionWarning()` in the delete-account dialog; hook the language setting to `BillingCopy.somaliOverride`; Arabic billing strings.
- **Owner / shared:** `user_inbox.kind` gains `billing_reminder`; vault secret `billing_cron_secret`; admin dashboard UI wiring; `docs/monetization/MONETIZATION.md` still describes coins; CI concurrency group per branch (`dev-check-${{ github.ref }}`).

---

## PART 3 — Dev 3: UI, words and layout

**Goal:** A clean, quiet app. Short words, nothing technical, every job in one place, in Somali, Arabic and English.

### 3.1 Style rules (apply everywhere, including billing)
- **Copy length:** at most one short line of helper text per screen. Most screens have none.
- **No technical words in the UI:**
  - model
  - provider
  - token (outside pay-as-you-go)
  - API
  - MCP
  - Bearer
  - key header
  - alias
  - Paper/Ink
- **No model or provider names anywhere,** including fallback banners. Delete the "[model] didn't answer" banner.
- **No divider lines** between rows or sections. Use spacing and grouping instead.
- **One title style,** one section-header style, only the type scale in `lib/ui/tokens.dart`, one corner radius set.
- **Brand red** only for danger or delete.
- **Sentence case** everywhere.
- **Plain verbs:** Add, Pause, Resume, Delete. Drop the hire/colleague/time-off metaphor.

### 3.2 Settings rebuild
Top level is a short list of sections, with no rows exposed. Tap a section to see and change what's inside.

| Section | Inside |
|---|---|
| Account | Name, email, sign out, delete account |
| Plan & usage | Dev 2's screen |
| Language | App language (Auto · Soomaali · العربية · English), reply language |
| Voice | Live voice, read aloud |
| Phone access | Calendar, contacts, SMS, notifications, screen control (one place only) |
| Privacy | What SubMac knows about you (memory), saved logins, trash, archived chats |
| Notifications | One "Tell me when a task is done" switch |
| Advanced | Trust level ("Ask me first" / "Do routine work alone"), API & tool servers, Think harder (optional) |
| Help | Help, terms, privacy policy, about |

- Theme: Auto · Light · Dark.
- Remove from Settings:
  - Skills
  - the "From SubMac" row
  - the invite card (one "Invite friends" row inside Account)
  - duplicate switches

### 3.3 Navigation and screens
- **Menu:** Chat · Today · Bots · Apps · Files · Settings.
- **Rename** "Team" to **Bots**. "Team" only means a group with a lead (and Teams are hidden for launch).
- **Empty chat:**
  - greeting
  - at most 4 language-aware shortcut chips + More
  - one Live button (in the composer)
  - remove the Live chip, the Auto/Quick/Think picker and the "Let it take action" switch from the + menu
- **Today** is the single feed: Needs your OK, done while you were away, From SubMac, Coming up (real scheduled items).
  - Hidden until the user has a bot or routine.
  - No second ask box.
- **Approvals:** one list (on Today) plus the pop-up card.
- **Files** absorbs Library, Sites and Trash as filters. Folders use human names.
- **Bots:**
  - one Hire screen (roles first, then More: Store, shared file, describe)
  - remove the duplicate Nova/Amal/Rank/Ustad definitions
  - one "Add from code or file" path
  - fix the share text to "SubMac > Bots > Bot Store > Add from code"
- **Bot settings:** Trust, Voice, Off hours + "More settings". Same for team settings.
- **Apps:** Connected and Apps tabs only. API and MCP go under Advanced. Feature about 20 tested apps.
- **Hide for launch:**
  - Teams
  - Bot Store publishing
  - Skill library screen
  - Health bot
  - website builder entry (keep in Files > Sites)
  - browser agent menu entry
- **Remove:**
  - Easy mode UI
  - wake word UI
  - Telegram UI
  - coder bot UI
  - the unused thinking widgets
  - duplicate activity entries
- Add a **Report** button where the Bot Store says "You can report it".

### 3.4 Languages
- App language setting follows the phone by default: Somali, Arabic, English.
- Full right-to-left layout for Arabic.
- Translate the main path first:
  - sign-up and consent
  - chat
  - menu
  - Settings
  - approvals
  - errors
  - billing
- Then everything else.
- Language names shown in their own language.
- Wake word hidden for Somali/Arabic.

### 3.5 Copy pass
Apply the short rewrites in `docs/audit/ui.md` section 4, for example:
- "Pick a role." (not "Pick a role. Three quick questions, then…")
- "Nothing to approve."
- "Saved on this phone only."
- "Pause / Resume"

### 3.6 Streaming polish (with Dev 1)
- Dev 1 adds a per-message notifier. Dev 3 makes `ReplyView` listen to it instead of the whole app state.
- Code blocks and tables render as plain text while streaming and are formatted when complete.

**Done when:**
- Every screen passes the style rules.
- Settings shows only sections.
- No divider lines.
- The app runs fully in Somali and Arabic (RTL).
- The 15 phone golden-path checks pass.

---

## Order and timing (suggested)

| Week | Dev 1 | Dev 2 | Dev 3 |
|---|---|---|---|
| 1 | Split `app_state.dart`; single model + sticky router; timeout budget + heartbeat | Remove coins; new tables, `usage_gate` / `usage_charge` | Style tokens; Settings sections; copy pass |
| 2 | First-word work; agent prompt/tool trim; recovery after kill | Packages + PAYG checkout; scheduled jobs; admin plan editor | Navigation merge (Today, Files, Bots); hide/remove list |
| 3 | Stress fixes, approvals, bots, crash reporting; Live router | Plan & usage screens; tests; staging E2E | Somali/Arabic + RTL; streaming polish |
| 4 | Joint: phone golden paths from Mogadishu, fix, owner review → `main` | | |
