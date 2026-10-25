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
