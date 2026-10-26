-- In-app feedback (2026-10-26): users write feedback, attach up to 5 screenshots and send it; the owner reads it in the
-- admin dashboard's Feedback section with the user's details.
-- Agent project moeemacbvsueekuvfjbo. Additive only: one table, its policies, one private storage bucket and its
-- policies, three admin functions (service_role only). Rollback: supabase/rollback/20261026_feedback_rollback.sql.
--
-- Who can do what
--   user (authenticated): insert own rows (status 'new', no admin note, screenshots only under "<uid>/"), read own rows.
--                         No update, no delete. At most 20 feedback rows per 24 hours.
--                         Storage: upload/read/delete only under feedback-screenshots/<uid>/, images up to 5 MB each.
--   admin (dashboard):    the dashboard's existing mechanism: email + password sign-in, then an edge function checks the
--                         email against public.ai_admins and works with the service role (edge function feedback-admin).
--                         The admin_* functions below are granted to service_role only.

-- ---------- table ----------
create table if not exists public.feedback (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  message text not null check (char_length(btrim(message)) between 1 and 5000),
  category text check (category is null or char_length(category) <= 40),
  app_version text check (app_version is null or char_length(app_version) <= 40),
  build_number text check (build_number is null or char_length(build_number) <= 20),
  device_model text check (device_model is null or char_length(device_model) <= 120),
  os_version text check (os_version is null or char_length(os_version) <= 120),
  locale text check (locale is null or char_length(locale) <= 20),
  screenshot_paths text[] not null default '{}' check (cardinality(screenshot_paths) <= 5),
  status text not null default 'new' check (status in ('new', 'read', 'resolved')),
  admin_note text check (admin_note is null or char_length(admin_note) <= 4000),
  created_at timestamptz not null default now(),
  updated_at timestamptz
);
create index if not exists feedback_created_idx on public.feedback (created_at desc);
create index if not exists feedback_status_idx on public.feedback (status, created_at desc);
create index if not exists feedback_user_idx on public.feedback (user_id, created_at desc);

alter table public.feedback enable row level security;
revoke all on public.feedback from anon, authenticated;
grant select, insert on public.feedback to authenticated;

-- Own rows only. A new row is always 'new' with no admin note, its screenshots sit in the sender's own folder, and one
-- account can send at most 20 in 24 hours.
drop policy if exists feedback_insert_own on public.feedback;
create policy feedback_insert_own on public.feedback for insert to authenticated
  with check (
    user_id = auth.uid()
    and status = 'new'
    and admin_note is null
    and updated_at is null
    and not exists (select 1 from unnest(screenshot_paths) p where p not like (auth.uid()::text || '/%') or p like '%..%')
    and (select count(*) from public.feedback f where f.user_id = auth.uid() and f.created_at > now() - interval '24 hours') < 20
  );
drop policy if exists feedback_select_own on public.feedback;
create policy feedback_select_own on public.feedback for select to authenticated using (user_id = auth.uid());

-- ---------- storage ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('feedback-screenshots', 'feedback-screenshots', false, 5242880,
        array['image/png', 'image/jpeg', 'image/webp', 'image/gif', 'image/heic', 'image/heif'])
on conflict (id) do nothing;

drop policy if exists feedback_shots_insert on storage.objects;
create policy feedback_shots_insert on storage.objects for insert to authenticated
  with check (
    bucket_id = 'feedback-screenshots'
    and (storage.foldername(name))[1] = auth.uid()::text
    and (select count(*) from storage.objects o
          where o.bucket_id = 'feedback-screenshots' and o.owner_id = auth.uid()::text
            and o.created_at > now() - interval '24 hours') < 50
  );
drop policy if exists feedback_shots_select on storage.objects;
create policy feedback_shots_select on storage.objects for select to authenticated
  using (bucket_id = 'feedback-screenshots' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists feedback_shots_delete on storage.objects;
create policy feedback_shots_delete on storage.objects for delete to authenticated
  using (bucket_id = 'feedback-screenshots' and (storage.foldername(name))[1] = auth.uid()::text);

-- ---------- admin (service_role only; called by the feedback-admin edge function after the ai_admins check) ----------
create or replace function public.admin_feedback_list(p_status text default null, p_limit integer default 100, p_before timestamptz default null)
returns jsonb language sql stable security definer set search_path = public, auth, billing as $$
  select coalesce(jsonb_agg(row_to_json(x)::jsonb order by x.created_at desc), '[]'::jsonb) from (
    select f.id, f.user_id, f.message, f.category, f.app_version, f.build_number, f.device_model, f.os_version, f.locale,
           f.screenshot_paths, f.status, f.admin_note, f.created_at, f.updated_at,
           u.email,
           coalesce(nullif(u.raw_user_meta_data->>'full_name', ''), nullif(u.raw_user_meta_data->>'name', ''),
                    nullif(u.raw_user_meta_data->>'display_name', '')) as display_name,
           u.created_at as user_created_at,
           (select coalesce(pl.name, s.plan_id) from billing.subscriptions s left join billing.plans pl on pl.id = s.plan_id
             where s.user_id = f.user_id and s.status = 'active' and s.starts_at <= now() and s.ends_at > now()
             order by s.ends_at desc limit 1) as plan
      from public.feedback f
      left join auth.users u on u.id = f.user_id
     where (p_status is null or p_status = '' or p_status = 'all' or f.status = p_status)
       and (p_before is null or f.created_at < p_before)
     order by f.created_at desc
     limit least(greatest(coalesce(p_limit, 100), 1), 500)
  ) x;
$$;

create or replace function public.admin_feedback_counts()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'new', count(*) filter (where status = 'new'),
    'read', count(*) filter (where status = 'read'),
    'resolved', count(*) filter (where status = 'resolved'),
    'total', count(*))
  from public.feedback;
$$;

create or replace function public.admin_feedback_update(p_id uuid, p_status text default null, p_note text default null, p_set_note boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.feedback;
begin
  if p_status is not null and p_status not in ('new', 'read', 'resolved') then raise exception 'bad status'; end if;
  update public.feedback
     set status = coalesce(p_status, status),
         admin_note = case when p_set_note then nullif(btrim(coalesce(p_note, '')), '') else admin_note end,
         updated_at = now()
   where id = p_id
  returning * into r;
  if r.id is null then raise exception 'not found'; end if;
  return jsonb_build_object('id', r.id, 'status', r.status, 'admin_note', r.admin_note, 'updated_at', r.updated_at);
end $$;

revoke all on function public.admin_feedback_list(text, integer, timestamptz) from public, anon, authenticated;
revoke all on function public.admin_feedback_counts() from public, anon, authenticated;
revoke all on function public.admin_feedback_update(uuid, text, text, boolean) from public, anon, authenticated;
grant execute on function public.admin_feedback_list(text, integer, timestamptz) to service_role;
grant execute on function public.admin_feedback_counts() to service_role;
grant execute on function public.admin_feedback_update(uuid, text, text, boolean) to service_role;
grant select, update on public.feedback to service_role;
