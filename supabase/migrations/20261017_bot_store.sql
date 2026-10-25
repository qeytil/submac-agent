-- v1.11: the Bot Store. Anyone signed in can browse published bots and hire a copy; only the author can change or remove theirs.
-- A row holds a bot package that already passed the app's strict sanitizer (BotPackage.sanitize): no logins, keys, tokens,
-- or anything the bot knew about its owner.
create table if not exists public.bot_store (
  id uuid primary key default gen_random_uuid(),
  author_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  author_name text not null default '',
  name text not null,
  role text not null default '',
  icon text not null default 'person',
  blurb text not null default '',
  package jsonb not null,
  -- false = shared only by its code (not listed in the Store)
  published boolean not null default true,
  share_code text unique,
  hires integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint bot_store_pkg_size check (octet_length(package::text) < 1500000),
  constraint bot_store_name_len check (char_length(name) between 1 and 60)
);
create index if not exists bot_store_list_idx on public.bot_store (published, hires desc, created_at desc);
create index if not exists bot_store_author_idx on public.bot_store (author_id);

alter table public.bot_store enable row level security;
drop policy if exists bot_store_read on public.bot_store;
create policy bot_store_read on public.bot_store for select to authenticated using (published or author_id = auth.uid());
drop policy if exists bot_store_insert on public.bot_store;
create policy bot_store_insert on public.bot_store for insert to authenticated with check (author_id = auth.uid());
drop policy if exists bot_store_update on public.bot_store;
create policy bot_store_update on public.bot_store for update to authenticated using (author_id = auth.uid()) with check (author_id = auth.uid());
drop policy if exists bot_store_delete on public.bot_store;
create policy bot_store_delete on public.bot_store for delete to authenticated using (author_id = auth.uid());

-- Authors cannot set their own hire count.
revoke update on public.bot_store from authenticated, anon;
grant update (author_name, name, role, icon, blurb, package, published, share_code, updated_at) on public.bot_store to authenticated;
revoke all on public.bot_store from anon;

-- Who hired what, so each person counts once.
create table if not exists public.bot_store_hires (
  bot_id uuid not null references public.bot_store(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (bot_id, user_id)
);
alter table public.bot_store_hires enable row level security;
revoke all on public.bot_store_hires from anon, authenticated;

create or replace function public.bot_store_hired(bot uuid) returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if auth.uid() is null then return 0; end if;
  insert into bot_store_hires (bot_id, user_id) values (bot, auth.uid()) on conflict do nothing;
  if found then
    update bot_store set hires = hires + 1 where id = bot;
  end if;
  select hires into n from bot_store where id = bot;
  return coalesce(n, 0);
end $$;

-- A bot shared by code (listed or not).
create or replace function public.bot_store_by_code(code text) returns setof public.bot_store
language sql security definer stable set search_path = public as $$
  select * from bot_store where share_code = upper(trim(code)) and auth.uid() is not null limit 1
$$;

revoke all on function public.bot_store_hired(uuid) from public, anon;
revoke all on function public.bot_store_by_code(text) from public, anon;
grant execute on function public.bot_store_hired(uuid) to authenticated;
grant execute on function public.bot_store_by_code(text) to authenticated;

-- Authors cannot set hire counts or ids on insert either, and nobody can empty the table.
revoke insert, truncate, trigger, references on public.bot_store from authenticated;
grant insert (author_name, name, role, icon, blurb, package, published, share_code) on public.bot_store to authenticated;
