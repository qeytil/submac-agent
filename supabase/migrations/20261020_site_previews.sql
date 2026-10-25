-- Free 7-day preview links for sites SubMac builds (edge function `site-preview`, Cloudflare Pages project
-- `submac-sites`, one branch per site: https://<slug>.submac-sites.pages.dev).
-- Additive only: two new tables and one daily cron job. Reuses the existing bot_run_secret / bot_run_anon_key
-- Vault secrets (see 20261019_bot_run.sql) so the sweep passes the gateway and the function's secret check.

create table if not exists public.site_previews (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  site_key text not null,                 -- the app's own id for the site
  slug text not null,                     -- the Pages branch, also the link's first label
  title text not null default '',
  deployment_id text,
  url text not null,
  files int not null default 0,
  bytes int not null default 0,
  status text not null default 'live' check (status in ('live', 'expired', 'removed', 'replaced')),
  created_at timestamptz not null default now(),
  published_at timestamptz not null default now(),
  expires_at timestamptz not null
);
create unique index if not exists site_previews_live_slug on public.site_previews (slug) where status = 'live';
create index if not exists site_previews_user on public.site_previews (user_id, status);
create index if not exists site_previews_expiry on public.site_previews (expires_at) where status = 'live';

alter table public.site_previews enable row level security;
drop policy if exists "own previews read" on public.site_previews;
create policy "own previews read" on public.site_previews for select to authenticated using (user_id = auth.uid());
-- No client writes: only the edge function (service role) writes.
revoke insert, update, delete on public.site_previews from anon, authenticated;

create table if not exists public.site_preview_log (
  id bigserial primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  slug text,
  at timestamptz not null default now()
);
create index if not exists site_preview_log_user on public.site_preview_log (user_id, at);
alter table public.site_preview_log enable row level security;
revoke all on public.site_preview_log from anon, authenticated;

-- Daily at 02:20 UTC: take expired links offline.
select cron.unschedule('site-preview-sweep') where exists (select 1 from cron.job where jobname = 'site-preview-sweep');
select cron.schedule('site-preview-sweep', '20 2 * * *', $cron$
  select net.http_post(
    url := 'https://moeemacbvsueekuvfjbo.supabase.co/functions/v1/site-preview',
    headers := jsonb_build_object(
      'content-type', 'application/json',
      'authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'bot_run_anon_key'),
      'x-bot-run-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'bot_run_secret')),
    body := '{"action":"sweep"}'::jsonb,
    timeout_milliseconds := 120000)
  where exists (select 1 from vault.decrypted_secrets where name = 'bot_run_anon_key')
$cron$);
