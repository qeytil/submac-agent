-- Owner 2026-11-08: a digital person runs on the phone. Bots are phone-local (Bot.cloudOn is always false), so the
-- cloud runner is retired: nothing may run a bot server-side.
--
-- Applied to project moeemacbvsueekuvfjbo on 2026-11-08 (verified: cron.job has no 'bot-run'; every cloud_bots row is
-- cloud_enabled=false, next_run_at=null, run_lock_until=null).
--
-- Rollback: re-apply 20261019_bot_run.sql to re-create the cron job, then enable a bot from the app (or set
-- cloud_enabled/next_run_at on its row). The bot-run edge function stays deployed and is inert meanwhile.

select cron.unschedule('bot-run') where exists (select 1 from cron.job where jobname = 'bot-run');

update public.cloud_bots
   set cloud_enabled = false,
       next_run_at = null,
       run_lock_until = null
 where cloud_enabled or next_run_at is not null or run_lock_until is not null;