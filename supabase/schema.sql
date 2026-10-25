create table if not exists public.conversations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade default auth.uid(),
  title text not null default 'New chat',
  model text,
  pinned boolean not null default false,
  archived boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade default auth.uid(),
  role text not null check (role in ('system','user','assistant','tool')),
  content text not null default '',
  tool_calls jsonb,
  tool_call_id text,
  name text,
  attachments jsonb,
  created_at timestamptz not null default now()
);
create index if not exists messages_conv_idx on public.messages(conversation_id, created_at);
create index if not exists conv_user_idx on public.conversations(user_id, updated_at desc);
create table if not exists public.user_settings (
  user_id uuid primary key references auth.users(id) on delete cascade default auth.uid(),
  settings jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
alter table public.conversations enable row level security;
alter table public.messages enable row level security;
alter table public.user_settings enable row level security;
drop policy if exists own_conv on public.conversations;
create policy own_conv on public.conversations for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists own_msg on public.messages;
create policy own_msg on public.messages for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists own_settings on public.user_settings;
create policy own_settings on public.user_settings for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
insert into storage.buckets (id, name, public) values ('attachments','attachments',false) on conflict (id) do nothing;
drop policy if exists att_rw on storage.objects;
create policy att_rw on storage.objects for all to authenticated
  using (bucket_id = 'attachments' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'attachments' and (storage.foldername(name))[1] = auth.uid()::text);
-- v1.4: things the user asked SubMac to remember (synced across devices).
create table if not exists public.memories (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade default auth.uid(),
  fact text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists memories_user_idx on public.memories(user_id, created_at);
alter table public.memories enable row level security;
drop policy if exists own_memories on public.memories;
create policy own_memories on public.memories for all
  using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- Shared skill library: public read for every user (and anonymous), written only with the service role (skills/publish.py).
insert into storage.buckets (id, name, public) values ('skills','skills',true) on conflict (id) do update set public = true;

-- v1.12: phone-first chats with packed archives (see migrations/20261018_chat_archives.sql).
alter table public.conversations add column if not exists archive_path text;
alter table public.conversations add column if not exists stored_at timestamptz;
alter table public.conversations add column if not exists summary text;
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('chat-archives', 'chat-archives', false, 20971520, array['application/gzip', 'application/octet-stream'])
on conflict (id) do nothing;
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
