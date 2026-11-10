# Telesia: backend and reliability audit

Date: 23 Oct 2026. I only read the repository copy at /workspace/work/repo. I changed nothing and called no live service. Where the live server might differ from the repo, I say so.

---

## 1. Overall health

**Fair to good, with a few sharp edges. The structure is sound. The weak spots are where pieces meet: app and server timeouts, the Somali routing, and keeping the repo in step with what is actually deployed.**

What is solid:
- **Database security is careful.** Every table has row-level security on. Tables that only the server should touch are fully closed to app users. Every money and key function is limited to the server. I found no table or function that a signed-in user could abuse to read another person's data or add coins to their own wallet.
- **The payment code is built defensively** (apart from Sifalo not being live yet, which I do not count as a bug). It never trusts the webhook or the return link and always re-checks with the provider. It protects against double taps and retries, never charges twice, and never marks a payment failed just because the result is unknown. It also has a large test file.
- **Most user-facing errors are friendly.** The app rewrites server errors into calm sentences and removes provider and model names. A reply that gets cut off midway ends cleanly, so the app can carry on.
- **No committed secrets** apart from the public keys that are meant to ship with the app (the Supabase anon key and the Firebase client config) and the intentionally committed signing keystore.
- **Every endpoint the app calls exists on the server.** Every database function the app or the edge functions call is defined in the migrations. No edge function is truly dead. The four billing functions are deployed but switched off by the billing flag, which is intended.

What drags it down:
- **Timeouts don't line up.** The server keeps trying models for longer than the app (and the cloud bot runner) is willing to wait. Users get "took too long" while the server is still working, and that work can still count against their allowance.
- **Somali tasks probably fall off the Somali models.** Somali chats go to Gemini, but the proxy has no handling for a requirement Gemini 3 has when tools are used. The team's own route notes already logged this error. Somali agent tasks will likely end up on the open models that write poor Somali, after long waits.
- **The repo and the live server have drifted.** The notes disagree about which ai-chat version is live (v30 in the live-versions file, Somali work since then). No settings file pins which functions require a login. Some live database changes exist only as hand-run SQL. A routine redeploy from the repo could quietly roll back behaviour or change who can call what.
- **Billing is still half built beyond Sifalo.** The background jobs that rescue stuck payments and retry failed charges are written but never scheduled.

---

## 2. Top 8 issues, ranked by risk and user impact

### 1. Somali tasks likely drop to weak models, or time out (High)
**What the user experiences:** A Somali speaker asks Telesia to do something that uses tools, such as search, files or a reminder. The first reply may be fine. After the first tool step, the answer either arrives in noticeably worse Somali or the app shows "The connection dropped" after about 90 seconds.

**Why:** Somali chats are sent to the Gemini routes. Gemini 3 models need a hidden "thought signature" passed back with each tool call in later turns. Neither the proxy nor the app keeps it, and the route-change notes from 21 Oct already record Gemini failing with "missing thought_signature" on tool calls. When Gemini refuses, the proxy tries the other Somali routes and then falls back to the general open models, which are the ones you found weak at Somali. Each Somali route also gets up to 30 seconds to start. Two or three slow Somali routes can use up the app's 90-second limit before any fallback answers.

**Plain fix:** Have the proxy keep and pass back Gemini's thought signature on tool calls, or send Somali tool turns through Gemini's native API. Lower the Somali start-wait to about 12–15 seconds. When a Somali chat has to leave the Somali routes, record it on the dashboard so you can see how often it happens.

### 2. The app gives up before the server does, and usage can still be charged (High)
**What the user experiences:** On a busy day, "That took too long. Please try again" or "The connection dropped". If they try again, the first, invisible attempt may already have counted against their daily allowance. Once billing is on, it may also have cost coins. The same thing happens to cloud bots ("keeps working when your phone is off").

**Why:** The server keeps trying other models for up to 75 seconds, plus up to 12–30 seconds for the attempt already running. A non-streamed answer can then take up to 5 more minutes to arrive. The app waits only 60 seconds for non-streamed calls, 90 seconds for a streamed reply to start, and the cloud bot runner 55 seconds. When the server does finish, it records the usage even though nobody received the answer.

**Plain fix:** Make the server's total time budget clearly shorter than the shortest client wait, for example 50 seconds on the server against 60 to 90 seconds on clients. Cap non-streamed reply time the same way. Send a small "still working" signal on streamed replies so the app knows the line is alive. Don't charge for a reply when the caller had already hung up before it started.

### 3. Raw internal errors can reach the chat screen (Medium-High)
**What the user experiences:** If the database check in front of every chat fails, for example during a short database or network blip, the user can see technical text like "gate: ai_gate 500" or "config: TypeError: fetch failed" in the chat instead of a calm message.

**Why:** On the chat path, the proxy puts the raw error text into the message it sends back. The app shows any message the server sends. Its scrubber only removes provider and model names.

**Plain fix:** Have the server always send a fixed friendly sentence for these cases ("Telesia couldn't get an answer just now…") and write the technical detail only to the server log. As a second guard, the app should ignore server messages for the "config" error type.

### 4. The repo no longer matches what is live, and deploy settings aren't written down (Medium-High)
**Risk:** One routine redeploy could roll back live fixes, switch on unfinished code, or change who is allowed to call a function.

**Why:**
- The live-versions file says ai-chat v30 is live and that the repo copy adds an undeployed billing path. The ai-chat file itself also contains the later Somali routing, and other notes say later versions were deployed. Nobody can tell from the repo which copy is actually running.
- No Supabase settings file records, per function, whether a login is required. Two billing functions must be open, because the payment page and Sifalo call them. ai-chat must stay locked, because it trusts the login check done before it (see Security).
- Some live database objects were applied as hand-run SQL or exist only live (finance tables and a few others). Rebuilding the database from the repo would not reproduce production.

**Plain fix:** Export every live function again and commit it. Add a settings file that pins the login requirement for each function. Record every hand-applied database change as a migration. Update the live-versions file whenever something is deployed.

### 5. Billing pieces that aren't finished, apart from Sifalo (Medium; only matters once billing is switched on)
**What users would experience once billing is live:**
- **Payments stuck on "processing":** if someone pays and closes the app before it confirms, and Sifalo's webhook (which fires only once and is unsigned) is missed, nothing re-checks the payment. The checker exists but is never scheduled. Abandoned purchases also never expire.
- **Lost charges:** a model reply whose charge fails goes into a retry queue that is never drained, so those replies end up free. The ledger sync to the finance side is also never scheduled.
- **A wrong "back tomorrow" time:** with billing on, the server resets allowances at midnight Mogadishu time (00:00 EAT). The app still assumes midnight UTC. Bots stay "paused until tomorrow" about three hours longer than needed, and reset times on screen are wrong.
- **A raw page after paying:** if billing is off or not configured, the payment-return link shows a bare technical JSON page in the browser instead of returning to the app.
- **Test money that becomes real coins:** if the Sifalo setting is left on "staging" when the billing flag is turned on, test payments would credit real coins.

**Plain fix:** Before turning billing on, schedule the payment re-check (every 10 minutes), the usage-retry and live-reconcile jobs, and the ledger sync. Have the app read the reset time the server sends instead of assuming UTC. Have the return link always send the user back to the app. Refuse to turn billing on while Sifalo is in staging mode.

### 6. Fallback routing can quietly send the wrong kind of model (Medium)
**What the user experiences or what it costs:**
- A user over their daily cap is supposed to get the small "lite" model. If the lite routes fail, the proxy falls back to the big smart and think models. You pay full cost for users who are out of allowance.
- "Think" (careful mode) and "smart" can quietly be answered by the small fast models when their own routes are down. The user picked careful mode and gets a quick, shallower answer with no sign of it.
- Healthy models from other aliases are tried before this alias's own models that are only flagged unhealthy. A brief hiccup on the bench can therefore send smart requests to fast-tier models.
- The saved "undo" SQL for the 21 Oct route change switches every listed route back on. Running it later would also re-enable any route you have turned off since.

**Plain fix:** Fall back only within the same tier or a smaller one. For over-cap users, never fall back to larger models. Let think fall back to smart, but not to fast. Show on the dashboard when a reply came from a fallback alias. Update the undo script so it changes only the order, not on or off.

### 7. Voice-note transcription and image creation have no time limit on the server (Medium)
**What the user experiences:** A voice note can sit on "turning into text" for minutes. The app waits up to 5 minutes, and the platform may cut the request off first. The user then gets a vague "try again".

**Why:** Each transcription attempt (up to 5 in a row) and each image attempt calls Google or the image provider with no time limit. Those requests go straight to Google, so this is a separate path from the chat routes.

**Plain fix:** Give each attempt a time limit (about 45–60 seconds for transcription) and an overall budget below the app's wait. For long recordings, transcribe in chunks.

### 8. Cloud bots ("keeps working when your phone is off") are fragile and untested since the last proxy change (Medium)
**What the user experiences:** Bot routines may silently not run, or run halfway, when the phone is off. Notifications from them may never arrive.

**Why:**
- The internal path that cloud bots use was changed in ai-chat v30 and never tested live. The notes say no cloud bot run has happened since 20 Oct.
- The bot runner waits 55 seconds per model call while ai-chat may take longer (issue 2), so bot steps fail on slow days.
- A job can run up to 6 steps of 55 seconds each, more than the platform's roughly 150-second limit per run. The run can be killed midway, leaving the bot locked for 5 minutes with half-saved state.
- The cron calls the runner every 5 minutes whether or not the feature is switched on.

**Plain fix:** Do one live end-to-end test of a cloud bot run, including the push notification. Give the runner a total time budget that fits inside one run, and save progress after each step. Align its model timeout with ai-chat (issue 2).

**Also noted (lower priority):**
- The "start the model early while checks run" speed trick almost never triggers. Your own measurements show every request lands on a fresh server instance. It adds complexity for little gain, so consider removing it.
- When billing is live, deleting an account keeps money records, which is intended. Users aren't warned that any remaining paid coins or passes are lost.
- If account deletion fails partway, some data may already be gone while the account still exists. The user is only told to "try again".

---

## 3. Security concerns

Ranked by risk. None of these looks like an active hole today, but the first two are one mistake away from serious.

1. **The proxy trusts a login check that happens before it, and that setting isn't pinned (Medium-High).** ai-chat reads the user's ID from the login token without checking the signature itself, because Supabase's gateway checks it first. That gateway setting lives only in the live project, not in the repo (issue 4). If ai-chat were ever redeployed with the check off, as the two billing functions must be, anyone could pretend to be any user, spend their allowance and, once billing is live, their coins. **Fix:** have ai-chat check the token itself (one call, or check the signature locally), and pin the per-function setting in the repo.

2. **Admin access is granted by email address alone (Medium, depending on sign-up settings).** The admin API gives full control: provider keys, users and releases. It lets in anyone signed in whose email is on the admin list, without checking that the email was ever confirmed. If sign-ups don't require email confirmation, someone could register an admin address that isn't in use yet and get in. **Fix:** require a confirmed email, or match admins by user ID. Also consider a second factor for the dashboard.

3. **Payment references can be claimed by the wrong purchase (Low now, fix before go-live).** For hosted card payments, Sifalo's check doesn't say which order a payment belongs to. If someone got hold of another buyer's payment reference for the same amount before it was credited, and sent it with their own pending purchase, the coins could land in the wrong wallet. The real buyer would then see "payment already used". **Fix:** when a reference comes from outside (a webhook or return link), also look up the order with Sifalo and accept it only if both agree.

4. **Staging payments could mint real coins (Low; configuration).** See issue 5. Block turning billing on while Sifalo is in staging mode.

5. **Free site links can be abused (Medium; reputational).** Any signed-in user can publish arbitrary web pages, up to 30 a day, on your Cloudflare Pages project. Phishing pages hosted there could get the project or account flagged. **Fix:** scan or limit what can be uploaded (for example, block login forms and pages that collect payments), add a report link, and lower limits for new accounts.

6. **Bot Store trust (Low-Medium).** An author can create their own listing with any hire count, because only edits are restricted, not new entries, so popularity can be faked. Shared bot packages are instructions that run on other people's phones, so a malicious bot could try to steer someone's agent. **Fix:** let only the server set hire counts. Review or screen packages before they are listed publicly.

7. **Small hardening items (Low):**
   - The Firebase key in the app is meant to be public, but restrict it to the Android app in Google Cloud.
   - The admin API's cron-secret check is a plain comparison; use the constant-time one already used elsewhere.
   - The "attachments" storage bucket is wiped on account deletion, but no repo migration defines its access rules. Confirm live that users can only reach their own folder.
   - My database security review covers the repo migrations only. Since live has hand-applied changes (issue 4), run Supabase's security advisor on the live project to confirm.

**Checked and found fine:**
- Row-level security on every table, and service-only access to keys, routes, usage and all billing data.
- Money functions callable only by the server.
- Cron and bot-runner secrets are checked in the database and not stored in git.
- Push sending is server-only.
- Payment logs hide secrets and wallet numbers.
- App updates are checked against a SHA-256 hash before installing.
- No stray API keys, tokens or private keys in the code.

---

## Appendix: files relied on

- supabase/functions/ai-chat/index.ts: routing, fallbacks, timeouts, Somali detection, error messages, internal bot path
- supabase/functions/_shared/payments/core.ts, sifalo.ts, db.ts, registry.ts; billing-checkout, billing-webhook, billing-return, billing-reconcile (index.ts)
- supabase/functions/bot-run/index.ts, push-send/index.ts, site-preview/index.ts, account-delete/index.ts, ai-admin/index.ts
- supabase/functions/LIVE.md
- supabase/migrations/* (especially 20261018_cloud_proxy, 20261019_bot_run, 20261019_bot_cloud, 20261017_bot_store, 20261020_billing, 20261021_billing_hardening, 20261021_billing_providers, 20261021_billing_usage_retry, 20261021_ai_gate, 20261020_site_previews, 20261020_app_releases); supabase/schema.sql
- lib/services/cloud.dart, lib/services/llm_client.dart, lib/services/billing/billing_api.dart, payment_flow.dart, billing_service.dart, checkout_url.dart; lib/app_state.dart (account delete, image/video tools); lib/services/sites.dart; lib/services/push.dart; lib/config.dart
- android_native/AppUpdater.kt; tools/patch_android.py (deep links)
- docs/project-state.md, docs/model-routes-2026-10-21.md, docs/cloud-proxy.md, docs/monetization/MONETIZATION.md, docs/monetization/payments-implementation.md
