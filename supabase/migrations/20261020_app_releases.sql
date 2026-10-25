-- In-app updates (branch feature/app-update). Additive only: one table, two functions, one public bucket.
-- The owner uploads a new Android build in the dashboard "Updates" tab (ai-admin signed upload URL, admins only),
-- writes what's new and picks when it becomes required. The app reads public.latest_release() on every cold start.

create table if not exists public.app_releases (
  id uuid primary key default gen_random_uuid(),
  version_code integer not null unique check (version_code > 0),
  version_name text not null check (length(version_name) between 1 and 40),
  notes text not null default '' check (length(notes) <= 4000),
  -- Folder of the upload in bucket app-updates. Supabase caps one file at 50 MB on this plan, so the dashboard
  -- uploads the build in parts of at most 40 MiB; the app downloads every part and joins them in order.
  apk_path text not null check (apk_path ~ '^android/[A-Za-z0-9._+-]+$'),
  parts jsonb not null check (jsonb_typeof(parts) = 'array' and jsonb_array_length(parts) between 1 and 20),
  size_bytes bigint not null default 0 check (size_bytes >= 0),
  sha256 text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  -- null = never required (users may skip); <= now() = required now (the app is blocked until updated).
  required_at timestamptz,
  published boolean not null default false,
  published_at timestamptz,
  created_by text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- No direct access for app users: reads go through latest_release(), writes only through ai-admin (service role).
alter table public.app_releases enable row level security;
revoke all on public.app_releases from anon, authenticated;

-- Newest published release above the caller's build. required_at is the EARLIEST deadline of any published
-- release newer than p_current_code, so a forced release stays forced even after a newer optional one ships.
create or replace function public.latest_release(p_current_code integer default 0)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with newer as (
    select * from public.app_releases
    where published and version_code > coalesce(p_current_code, 0)
  ), top as (
    select * from newer order by version_code desc limit 1
  )
  select case when not exists (select 1 from top) then jsonb_build_object('update', false, 'server_now', now())
  else (
    select jsonb_build_object(
      'update', true,
      'id', t.id,
      'version_code', t.version_code,
      'version_name', t.version_name,
      'notes', t.notes,
      'apk_path', t.apk_path,
      'bucket', 'app-updates',
      'parts', t.parts,
      'size_bytes', t.size_bytes,
      'sha256', t.sha256,
      'required_at', (select min(required_at) from newer),
      'published_at', t.published_at,
      'server_now', now())
    from top t)
  end;
$$;
revoke all on function public.latest_release(integer) from public;
grant execute on function public.latest_release(integer) to anon, authenticated, service_role;

-- Dashboard: how many devices run each app version (service role only, via ai-admin releases_list).
create or replace function public.admin_app_versions()
returns table (app_version text, devices bigint, seen_7d bigint)
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(nullif(app_version, ''), 'unknown'), count(*), count(*) filter (where last_seen > now() - interval '7 days')
  from public.user_devices group by 1 order by 2 desc;
$$;
revoke all on function public.admin_app_versions() from public, anon, authenticated;
grant execute on function public.admin_app_versions() to service_role;

-- Public bucket for the update files (not the website's R2). Anyone may download by URL; nobody may write
-- with an app key. Uploads only through signed upload URLs that ai-admin makes for admins.
-- 50 MB per object is the project's own ceiling, hence the parts above.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('app-updates', 'app-updates', true, 52428800,
        array['application/vnd.android.package-archive', 'application/octet-stream'])
on conflict (id) do nothing;

drop policy if exists "app-updates no client insert" on storage.objects;
create policy "app-updates no client insert" on storage.objects as restrictive for insert to anon, authenticated
  with check (bucket_id <> 'app-updates');
drop policy if exists "app-updates no client update" on storage.objects;
create policy "app-updates no client update" on storage.objects as restrictive for update to anon, authenticated
  using (bucket_id <> 'app-updates') with check (bucket_id <> 'app-updates');
drop policy if exists "app-updates no client delete" on storage.objects;
create policy "app-updates no client delete" on storage.objects as restrictive for delete to anon, authenticated
  using (bucket_id <> 'app-updates');
