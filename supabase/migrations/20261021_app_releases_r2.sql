-- In-app updates: one-file releases in Cloudflare R2 (bucket submac-app-updates). Additive only.
-- Before this, Supabase Storage capped one file at 50 MB on this plan, so builds were stored in 40 MiB parts in the
-- Supabase bucket app-updates. Now the dashboard Worker (submac-proxy-admin, R2 binding UPDATES) streams the file
-- into R2 with a multipart upload and the phone downloads ONE file from the public URL.
-- Old rows keep storage = 'supabase' and their parts (the phone still understands them).

alter table public.app_releases add column if not exists storage text not null default 'supabase';
alter table public.app_releases add column if not exists file_url text;
alter table public.app_releases add column if not exists file_key text;

do $$ begin
  alter table public.app_releases add constraint app_releases_storage_chk check (storage in ('supabase', 'r2'));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.app_releases add constraint app_releases_r2_chk check (
    storage <> 'r2' or (file_url ~ '^https://[A-Za-z0-9.-]+/android/[0-9]+-[0-9a-f]{8}/SubMac-[0-9]+\.apk$'
                        and file_key ~ '^android/[0-9]+-[0-9a-f]{8}/SubMac-[0-9]+\.apk$'));
exception when duplicate_object then null; end $$;

-- Public address of the R2 bucket (r2.dev for now; a custom domain is better for production).
-- ai-admin reads it to check an upload and to build file_url. Change it here when a custom domain is added.
insert into public.ai_settings (key, value)
values ('app_updates_public_base', to_jsonb('https://pub-f8ebeb9291264a2d873d45061a442de0.r2.dev'::text))
on conflict (key) do nothing;

-- Same answer as before plus storage / file_url / file_key. required_at is still the EARLIEST deadline of any
-- published release newer than p_current_code.
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
      'storage', t.storage,
      'file_url', t.file_url,
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
