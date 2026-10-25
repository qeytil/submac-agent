-- Plan 2.1 part B: the cloud runner. Edge function `bot-run` (supabase/functions/bot-run) runs bots' cloud jobs
-- (routines, follow-ups, heartbeats) every 5 minutes from pg_cron through pg_net.
--
-- Secrets (never in git): two Vault secrets the cron job reads when it fires.
--   bot_run_secret    random, made here inside the database; bot-run refuses any call without it (x-bot-run-secret),
--                     and ai-chat accepts bot-run's internal calls (x-submac-internal) only with it.
--   bot_run_anon_key  the project's public anon key, so the call passes the gateway's JWT check (verify_jwt stays on).
--                     Created once by hand: select vault.create_secret('<anon key>', 'bot_run_anon_key', '...');
-- Functions (service role only): bot_run_check(secret), bot_run_claim(limit, user).

create extension if not exists pg_cron;
create extension if not exists pg_net;

do $$
begin
  if not exists (select 1 from vault.secrets where name = 'bot_run_secret') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'bot_run_secret',
      'Plan 2.1 part B: shared secret for cron -> bot-run -> ai-chat');
  end if;
end $$;

-- Is this the runner's secret? (constant work per call; the secret never leaves the database here)
create or replace function public.bot_run_check(p_secret text) returns boolean
language sql security definer stable set search_path = public as $$
  select coalesce(length(p_secret) >= 32 and p_secret = (select decrypted_secret from vault.decrypted_secrets where name = 'bot_run_secret'), false)
$$;
revoke all on function public.bot_run_check(text) from public, anon, authenticated;
grant execute on function public.bot_run_check(text) to service_role;

-- Takes up to p_limit due bots and locks each for 5 minutes (two runners never take the same bot).
-- p_user: only that user's bots (tests while the runner switch is off).
create or replace function public.bot_run_claim(p_limit int default 10, p_user uuid default null)
returns table (user_id uuid, bot_id text, name text, setup jsonb, knowledge jsonb, schedule jsonb, tz_offset_min int,
               run_state jsonb, last_run_at timestamptz, next_run_at timestamptz, created_at timestamptz)
language sql security definer volatile set search_path = public as $$
  with due as (
    select c.user_id, c.bot_id from cloud_bots c
    where c.cloud_enabled and not c.deleted and c.next_run_at <= now()
      and (c.run_lock_until is null or c.run_lock_until < now())
      and (p_user is null or c.user_id = p_user)
    order by c.next_run_at
    limit greatest(1, least(coalesce(p_limit, 10), 25))
    for update skip locked
  )
  update cloud_bots c set run_lock_until = now() + interval '5 minutes'
  from due where c.user_id = due.user_id and c.bot_id = due.bot_id
  returning c.user_id, c.bot_id, c.name, c.setup, c.knowledge, c.schedule, c.tz_offset_min, c.run_state, c.last_run_at,
            c.next_run_at, c.created_at
$$;
revoke all on function public.bot_run_claim(int, uuid) from public, anon, authenticated;
grant execute on function public.bot_run_claim(int, uuid) to service_role;

-- Every 5 minutes. pg_net is asynchronous: the cron job only queues the request.
select cron.unschedule('bot-run') where exists (select 1 from cron.job where jobname = 'bot-run');
select cron.schedule('bot-run', '*/5 * * * *', $cron$
  select net.http_post(
    url := 'https://moeemacbvsueekuvfjbo.supabase.co/functions/v1/bot-run',
    headers := jsonb_build_object(
      'content-type', 'application/json',
      'authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'bot_run_anon_key'),
      'x-bot-run-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'bot_run_secret')),
    body := '{"from":"cron"}'::jsonb,
    timeout_milliseconds := 150000)
  where exists (select 1 from vault.decrypted_secrets where name = 'bot_run_anon_key')
$cron$);
