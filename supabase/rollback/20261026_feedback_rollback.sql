-- Rollback of 20261026_feedback.sql (in-app feedback). Removes only what that migration added.
-- Step 1 (outside SQL): empty the bucket through the Storage API first, e.g. with the service role:
--   list feedback-screenshots recursively and remove every object (direct DELETE on storage.objects is blocked by
--   storage.protect_delete). The feedback-admin edge function is removed separately:
--   supabase functions delete feedback-admin --project-ref moeemacbvsueekuvfjbo
-- Step 2: this file. It refuses to drop the bucket while it still holds files.
-- WARNING: dropping public.feedback deletes every feedback row. Export it first if any should be kept:
--   copy (select * from public.feedback) to stdout with csv header;

begin;

drop function if exists public.admin_feedback_list(text, integer, timestamptz);
drop function if exists public.admin_feedback_counts();
drop function if exists public.admin_feedback_update(uuid, text, text, boolean);

drop policy if exists feedback_shots_insert on storage.objects;
drop policy if exists feedback_shots_select on storage.objects;
drop policy if exists feedback_shots_delete on storage.objects;

do $$ begin
  if exists (select 1 from storage.objects where bucket_id = 'feedback-screenshots') then
    raise exception 'feedback-screenshots still has files: empty it through the Storage API first';
  end if;
end $$;
set local storage.allow_delete_query = 'true';
delete from storage.buckets where id = 'feedback-screenshots';

drop table if exists public.feedback;

delete from supabase_migrations.schema_migrations where version = '20261026120000';

commit;
