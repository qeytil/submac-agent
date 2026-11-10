# Telesia Cloud (model proxy)

Users never set up models or keys. Every model call goes through Telesia's own server.

## Pieces
- `supabase/functions/ai-chat` — the proxy the app calls (OpenAI chat format, signed with the user's Supabase session).
  - `POST /functions/v1/ai-chat` with `model` = one of the names below. Streaming and tool calls supported.
  - `GET /status` — today's allowance (`ratio`, `state`: ok / notice / light / limit) and which features are on.
  - `POST /live-token` — a single-use, short-lived pass for one Live voice call (the provider key never reaches the phone). Refused at 0 call minutes.
  - `POST /live-usage` — the call's heartbeat (call minutes).
  - `POST /transcribe` — meeting recordings to text.
  - `POST /image` — pictures, only when the `telesia-image` name has models.
- `supabase/functions/ai-admin` — the API behind the admin dashboard (admins listed in `ai_admins`) and the hourly benchmark.
- `supabase/functions/bot-run` — the cloud runner for bots (see Cloud runner).
- `supabase/functions/account-delete` — deletes a user's account and data (Settings > Advanced > Delete account).
- `tools/proxy-admin` — the Cloudflare Worker `telesia-proxy-admin` serving the dashboard and running the benchmark every hour.
- `supabase/migrations/20261018_cloud_proxy.sql` — tables, RPCs and default settings.

## Names the app asks for
| Name | Used for |
| --- | --- |
| `telesia-smart` | chat, tasks, bots, offices |
| `telesia-fast` | quick replies, titles, summaries |
| `telesia-vision` | anything with a picture (picked automatically by the server) |
| `telesia-lite` | after the daily allowance, shorter replies until tomorrow |

Each name tries its models in order and moves to the next on errors, limits or a slow first token, rotating keys first.
Before trying a model, the proxy checks the request fits: rough prompt estimate x 1.15 plus the reply length must be within the model's `context_window` (set per model in the dashboard). Models that can't fit are skipped. If none fit, it answers 413 "Request too large" so the app compacts and retries. Sticky chats: when the app sends `x-telesia-chat`, each route starts from a key chosen by a hash of user + chat, so one chat keeps the same key (and the provider's prompt cache) and only moves when that key fails or rests. Without the header, keys rotate round robin. Every chat reply carries `x-telesia-window`, the smallest window among the name's healthy models. The dashboard flags any model in `telesia-smart` / `telesia-vision` whose window is below the app's 48k budget plus the reply length.
Models, keys, order, reply length and the style note are all edited in the dashboard; changes are live within a minute.

## Live pool (separate from chat)
- Live voice passes (`/live-token`) come only from the table `live_routes` (migration `supabase/migrations/20261019_live_pool.sql`): one row = one provider key (its own Vault secret) + an optional `model` (empty = the `live_model` setting). Chat, bots, transcription and images never read it, and Live never reads or marks `ai_keys`.
- Order: `priority`, lowest first; rows with the same priority share the load (shuffled). A fallback is a row with a higher number. On a failed pass the proxy rests that row (`cooldown_until`, `fail_count`, `last_error`) and tries the next (up to 6): 429 rests 60 s, 429 with quota/exhausted wording 1 h, 401/403 or "API key not valid" 1 h, 5xx/network 20 s.
- Seeded 2026-10-19 with copies of the 7 Gemini keys Live used before (all priority 10, model empty). Deleting or resting a chat key no longer affects Live, and the reverse.
- `ai-admin` actions: `live_list` (rows + `live_model`; also in `get_all` as `live_routes`), `live_add` (`key`, `label`, `model`, `priority`; or `copy_from` + `model` to reuse a key with another model), `live_update` (`label`, `enabled`, `model`, `priority`, `clear_rest`), `live_replace_key`, `live_delete`, `live_order` (`ids` top to bottom -> priority 10, 20, ...), `live_set_model` (the default), `live_test` / `test_live` (real Live setup with one row, or the first one).
- Dashboard: tab "Live calls" (Live model, Live key pool, call minutes, calls today, user lookup). The `live_provider` setting now only picks the transcription keys.
- Limit: Gemini only checks the key when the pass is made; a model refused later on the socket is seen by the app, not the proxy, so model fallback works only between rows when the pass itself fails.

## Daily allowance
- 200,000 allowance tokens per user per day (UTC). Prompt tokens count at `input_weight` (0.3), reply tokens at 1, cached prompt tokens at 0.1.
- 80%: one gentle heads-up. 100%: replies get lighter (`telesia-lite`, 400 tokens) for 40,000 more; bots and offices pause (they also pause earlier at their own share, see Background lane). Live calls are not part of the allowance (see Call minutes).
- After that: a friendly "you've done a lot today" until the reset.
- Fair use: at most `user_rpm` (40) successful requests per minute per user; one request at most `max_prompt_tokens`.

## Background lane (Plan 2.2)
- Bots and Offices get `background_share` (ai_settings, default 0.3, dashboard Settings) of `daily_cap_tokens` per user per UTC day. Background use counts in the total (`ai_user_daily.tokens`) and in `ai_user_daily.bg_tokens`. The user's own chats are never limited by the share: they keep the whole cap and the grace after it.
- A request is background when it is an internal bot-run call (source `bot-cloud`) or the app sends `x-telesia-lane: background` (bot wakes: heartbeats, routines, follow-ups, call recaps; office work except answering the owner; bot_ask consults during that work). Chatting with a bot or answering the owner in an office is not background. `ai_record_usage` adds to `bg_tokens` when `p.lane = 'background'` or source is `bot-cloud` (migration `20261019_background_lane`).
- Refused with 429 `{error:{code:"background_paused", message:"Paused until tomorrow to save your daily allowance."}, background_left:0, resets_at}` once `bg_tokens` reaches the share, or the total reaches the cap (light zone). Replies carry `x-telesia-bg` (0..1 of the share used). `/status` has `background_left` and `background {share, cap, used, left, ratio, paused}`.
- App: `background_paused` is final (no retry); a phone wake stops with one "Paused until tomorrow to save your daily allowance" line a day in the bot's activity; office work other than owner replies waits in the queue until the next UTC day (retry alarm at 00:05 UTC); Settings/Today shows "Bots: X% of their share today". bot-run writes the same note once a day (`run_state.paused`) and skips the job.

## Call minutes (Plan 6 item 3)
- Live voice has its own daily limit: `live_daily_minutes` (default 15) per user per UTC day, same reset as the allowance. Per-user override in `live_user_limits` (`daily_minutes`, null = default; `live_enabled` false = no calls). Ledger `live_call_daily` (seconds, calls; each user can read only their own row); calls in `live_calls`. Migration `supabase/migrations/20261019_call_minutes.sql`.
- New call: `/live-token` with no `call_id` -> `live_call_start` (refused 429 `call_minutes` with `minutes_left: 0` when used up, 429 `live_off` when off). Renewed line: `{resume: true, call_id, seconds}` -> allowed only while that call is open, connected and heard from in the last 150 s (else 409 `call_ended`); still checked against the minutes. Every pass expires with the minutes left + 60 s (max `live_session_minutes`).
- Counting: the app talks to Gemini directly, so it reports `POST /live-usage {call_id, seconds, end?}` when the line connects (seconds 0), every 30 s (`heartbeat_seconds` in the pass) and on hang-up. Per gap the server counts its own time since the last report, at most 120 s; the app's cumulative `seconds` only fills a longer gap and the call never passes the wall time since it connected. Silent calls close after 150 s, charged at most 30 s past their last report. Answers carry `minutes_left`, `seconds_left`, `limit_minutes`, `used_seconds`, `live_enabled`, `resets_at`, and `stop: true` when time is up. `/status` has the same under `calls`.
- Live passes are still logged in `ai_usage` (`live`, `live-resume`) for stats, with 0 tokens: no allowance charge.
- `ai-admin`: `live_minutes_get`, `live_minutes_set {minutes}`, `live_user_set {user_id|email, minutes|null, enabled, note}`, `live_user_clear {user_id}`, `live_user_minutes {user_id|email}`, `live_minutes_today` (default + rows: user_id, email, used_seconds, used_minutes, calls, limit_minutes, override_minutes, enabled, seconds_left, in_call, note), `live_reset_user_today {user_id}`.

## Cloud runner (bot-run, Plan 2.1 part B)
- `supabase/functions/bot-run`, called by pg_cron job `bot-run` every 5 minutes through pg_net (migration `supabase/migrations/20261019_bot_run.sql`). verify_jwt stays on: the cron sends the public anon key (Vault `bot_run_anon_key`) as the bearer, and bot-run refuses any call without `x-bot-run-secret` = Vault `bot_run_secret` (checked in the DB by `bot_run_check`, service role only). Neither secret is in git.
- Switch: `ai_settings.bot_cloud_runner`. Off: the cron call returns `runner_off` and phones run everything. On: phones stop alarms for jobs the cloud owns. Tests: `POST {only_user: <uuid>}` with the secret runs only that user's bots even while off.
- A round: `bot_run_claim(10)` takes due bots (`cloud_enabled`, not deleted, `next_run_at <= now()`, lock free) and locks each for 5 min; 3 bots at a time, no new job after 105 s.
- Jobs (`schedule`, written by the phone): routines `{id,time,days,kind,do,next}` in phone-local time via `tz_offset_min` (owed from first sight per id|time|days, never more than 3 h late), follow-ups `{id,at,kind,do}` (UTC), heartbeat `{id:'hb',every_hours,next}` (never in quiet hours `qf`-`qt`). Done jobs: `run_state.done[id]`; the phone drops follow-ups listed there. Up to 3 jobs per bot per round.
- Check first: a heartbeat asks `telesia-fast` (60 tokens out) "anything worth doing?"; NO ends the wake (about 500 tokens, no journal, no push). Routines and follow-ups go straight to work.
- Work: `telesia-smart` through ai-chat as an internal call (`authorization` = service key, `x-telesia-internal` = runner secret, `x-telesia-user`; ai-chat records source `bot-cloud` on that user's allowance; `x-telesia-chat` = `bot:<id>` keeps the key sticky for caching). Prompt: stable part first (who it is, persona, mission, instructions, knowledge titles, apps, lessons, cloud rules, outcome tags), fresh part last (memory without tombstones, open desk, last 8 journal lines, the wake). At most 6 steps and 60k tokens per job, and the bot's daily budget `tb` (counted in `run_state.tok`).
- Tools: `bot_remember` (cloud_bot_memory, same item key as the phone), `bot_desk` add/update/done, `knowledge_search` / `knowledge_read`, `hand_to_phone` (journal note: what the phone or an app must do). No web, browser, apps or phone powers (no server-side search exists yet).
- Results: journal rows `origin 'cloud'`, `device_id ''` (`message`/`note` with the full text in `chat`, `work` for a routine with nothing to tell, `missed` after two failed tries, `note` for a pause); memory and desk rows `origin 'cloud'`. Never messages, setup, schedule or device_id. Then `run_state`, `last_run_at`, `next_run_at`, lock cleared. Quiet hours turn a message into a note.
- Allowance: the user's daily allowance used up (or ai-chat `daily_limit`) or the bot's budget spent: the job is skipped with one "Skipped work in the cloud" note a day.
- Push: only for `@message` results, through push-send (`bot_id`, `chat_id` = the bot's chat, `message_id` = journal id).

## Never
- Commit provider keys. They live only in Supabase Vault, added from the dashboard.
- Show provider or model names to users.
