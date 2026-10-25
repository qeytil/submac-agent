-- v1.12: phone-first chats.
-- The phone keeps every chat in full. The account only backs it up: tool rows keep a short note
-- (300 characters), and old chats are packed into one gzipped JSON file each in the private
-- bucket chat-archives (<user id>/<chat id>.json.gz). A packed chat keeps only its row here.

alter table public.conversations add column if not exists archive_path text;
alter table public.conversations add column if not exists stored_at timestamptz;
alter table public.conversations add column if not exists summary text;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('chat-archives', 'chat-archives', false, 20971520, array['application/gzip', 'application/octet-stream'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- Each person reads and writes only files under their own folder.
drop policy if exists chat_archives_select on storage.objects;
create policy chat_archives_select on storage.objects for select to authenticated
  using (bucket_id = 'chat-archives' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists chat_archives_insert on storage.objects;
create policy chat_archives_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'chat-archives' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists chat_archives_update on storage.objects;
create policy chat_archives_update on storage.objects for update to authenticated
  using (bucket_id = 'chat-archives' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'chat-archives' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists chat_archives_delete on storage.objects;
create policy chat_archives_delete on storage.objects for delete to authenticated
  using (bucket_id = 'chat-archives' and (storage.foldername(name))[1] = auth.uid()::text);

-- One-time cleanup: tool results already in the backup shrink to the same 300-character note.
-- (The space is reused by Postgres; a full VACUUM to hand it back cannot be run through the API.)
update public.messages set content = left(content, 300)
where role = 'tool' and length(content) > 300;
