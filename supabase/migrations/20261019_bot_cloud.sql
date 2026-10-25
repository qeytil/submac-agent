-- Plan 2.1 part A: bots live in the cloud (sync only; the cloud runner `bot-run` is part B).
-- Design: docs/plans-2026-10.md "2.1 design".
--
-- cloud_bots          one row per bot: its setup (persona, instructions, routines, follow-ups, powers, budgets,
--                     trust settings, lessons, apps by name only), its knowledge, and the jobs the cloud may run
--                     (`schedule`, written by the phone). Phone-owned columns are written by the app; the
--                     cloud-owned columns (run_state, last_run_at, run_lock_until) only by the service role.
--                     A removed bot stays as a tombstone (deleted = true, setup emptied) so every phone drops it.
-- cloud_bot_memory    one row per memory line (item_id = hash of the line). deleted = true is a tombstone.
-- cloud_bot_desk      one row per desk task (item_id = task id). deleted = true is a tombstone.
-- cloud_bot_journal   append-only journal entries (item_id = hash of time+kind+text, or the cloud's own id).
--                     `chat` holds the full message a cloud run wants posted in the bot's chat (the phone posts it).
-- Every row: server-assigned updated_at (trigger), device_id of the writer (so a phone skips its own echoes),
-- origin 'phone' | 'cloud'. RLS: each user sees and writes only their own rows. Size checks on every jsonb/text.
-- Setting bot_cloud_runner (false until part B is live): read by the app through bot_cloud_info().

create table if not exists public.cloud_bots (
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  bot_id text not null,
  name text not null default '',
  setup jsonb not null default '{}'::jsonb,
  knowledge jsonb not null default '[]'::jsonb,
  knowledge_hash text not null default '',
  -- The owner's "Works in the cloud" switch (and the bot is hired).
  cloud_enabled boolean not null default false,
  -- Cloud-eligible jobs, computed by the phone: [{id, type: routine|followup|heartbeat, time, days, kind, do, at, every_hours}]
  schedule jsonb not null default '[]'::jsonb,
  tz_name text not null default '',
  tz_offset_min int not null default 0,
  next_run_at timestamptz,
  -- Cloud-owned (service role only): {"done": {"<job id>": "<iso>"}, "last": {...}} and run bookkeeping.
  run_state jsonb not null default '{}'::jsonb,
  last_run_at timestamptz,
  run_lock_until timestamptz,
  deleted boolean not null default false,
  device_id text not null default '',
  origin text not null default 'phone',
  version bigint not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, bot_id),
  constraint cloud_bots_id_len check (char_length(bot_id) between 1 and 64),
  constraint cloud_bots_name_len check (char_length(name) <= 120),
  constraint cloud_bots_setup_size check (octet_length(setup::text) <= 300000),
  constraint cloud_bots_knowledge_size check (octet_length(knowledge::text) <= 1300000),
  constraint cloud_bots_schedule_size check (octet_length(schedule::text) <= 64000),
  constraint cloud_bots_run_state_size check (octet_length(run_state::text) <= 64000),
  constraint cloud_bots_origin_chk check (origin in ('phone', 'cloud')),
  constraint cloud_bots_device_len check (char_length(device_id) <= 64),
  constraint cloud_bots_tz_len check (char_length(tz_name) <= 64 and tz_offset_min between -900 and 900)
);
create index if not exists cloud_bots_due_idx on public.cloud_bots (next_run_at) where cloud_enabled and not deleted;
create index if not exists cloud_bots_user_upd_idx on public.cloud_bots (user_id, updated_at);

create table if not exists public.cloud_bot_memory (
  user_id uuid not null default auth.uid(),
  bot_id text not null,
  item_id text not null,
  data jsonb not null default '{}'::jsonb,
  deleted boolean not null default false,
  device_id text not null default '',
  origin text not null default 'phone',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, bot_id, item_id),
  foreign key (user_id, bot_id) references public.cloud_bots(user_id, bot_id) on delete cascade,
  constraint cloud_bot_memory_id_len check (char_length(item_id) between 1 and 64),
  constraint cloud_bot_memory_size check (octet_length(data::text) <= 8000),
  constraint cloud_bot_memory_origin_chk check (origin in ('phone', 'cloud')),
  constraint cloud_bot_memory_device_len check (char_length(device_id) <= 64)
);
create index if not exists cloud_bot_memory_upd_idx on public.cloud_bot_memory (user_id, updated_at);

create table if not exists public.cloud_bot_desk (
  user_id uuid not null default auth.uid(),
  bot_id text not null,
  item_id text not null,
  data jsonb not null default '{}'::jsonb,
  deleted boolean not null default false,
  device_id text not null default '',
  origin text not null default 'phone',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, bot_id, item_id),
  foreign key (user_id, bot_id) references public.cloud_bots(user_id, bot_id) on delete cascade,
  constraint cloud_bot_desk_id_len check (char_length(item_id) between 1 and 64),
  constraint cloud_bot_desk_size check (octet_length(data::text) <= 16000),
  constraint cloud_bot_desk_origin_chk check (origin in ('phone', 'cloud')),
  constraint cloud_bot_desk_device_len check (char_length(device_id) <= 64)
);
create index if not exists cloud_bot_desk_upd_idx on public.cloud_bot_desk (user_id, updated_at);

create table if not exists public.cloud_bot_journal (
  user_id uuid not null default auth.uid(),
  bot_id text not null,
  item_id text not null,
  at timestamptz not null default now(),
  kind text not null default 'note',
  text text not null default '',
  -- A cloud run's full message for the bot's chat ('' = journal line only).
  chat text not null default '',
  device_id text not null default '',
  origin text not null default 'phone',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, bot_id, item_id),
  foreign key (user_id, bot_id) references public.cloud_bots(user_id, bot_id) on delete cascade,
  constraint cloud_bot_journal_id_len check (char_length(item_id) between 1 and 64),
  constraint cloud_bot_journal_kind_chk check (kind in ('work', 'note', 'message', 'call', 'missed', 'learned')),
  constraint cloud_bot_journal_text_len check (char_length(text) <= 2000),
  constraint cloud_bot_journal_chat_len check (char_length(chat) <= 20000),
  constraint cloud_bot_journal_origin_chk check (origin in ('phone', 'cloud')),
  constraint cloud_bot_journal_device_len check (char_length(device_id) <= 64)
);
create index if not exists cloud_bot_journal_upd_idx on public.cloud_bot_journal (user_id, updated_at);
create index if not exists cloud_bot_journal_bot_at_idx on public.cloud_bot_journal (user_id, bot_id, at desc);

-- Server time on every write; version counts updates; the owner of a row never changes.
create or replace function public.cloud_bot_touch() returns trigger
language plpgsql set search_path = public as $$
begin
  new.updated_at := clock_timestamp();
  if tg_op = 'UPDATE' then
    new.user_id := old.user_id;
    new.created_at := old.created_at;
    if tg_table_name = 'cloud_bots' then new.version := old.version + 1; end if;
  else
    new.created_at := new.updated_at;
    if tg_table_name = 'cloud_bots' then new.version := 1; end if;
  end if;
  return new;
end $$;

drop trigger if exists cloud_bots_touch on public.cloud_bots;
create trigger cloud_bots_touch before insert or update on public.cloud_bots for each row execute function public.cloud_bot_touch();
drop trigger if exists cloud_bot_memory_touch on public.cloud_bot_memory;
create trigger cloud_bot_memory_touch before insert or update on public.cloud_bot_memory for each row execute function public.cloud_bot_touch();
drop trigger if exists cloud_bot_desk_touch on public.cloud_bot_desk;
create trigger cloud_bot_desk_touch before insert or update on public.cloud_bot_desk for each row execute function public.cloud_bot_touch();
drop trigger if exists cloud_bot_journal_touch on public.cloud_bot_journal;
create trigger cloud_bot_journal_touch before insert or update on public.cloud_bot_journal for each row execute function public.cloud_bot_touch();

-- Caps: 60 bots per user, 1,000 memory rows and 1,000 desk rows per bot (tombstones included); the journal keeps
-- the newest 500 entries per bot.
create or replace function public.cloud_bot_caps() returns trigger
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if tg_table_name = 'cloud_bots' then
    select count(*) into n from cloud_bots where user_id = new.user_id;
    if n >= 60 and not exists (select 1 from cloud_bots where user_id = new.user_id and bot_id = new.bot_id) then raise exception 'too many bots' using errcode = '23514'; end if;
  elsif tg_table_name = 'cloud_bot_memory' then
    select count(*) into n from cloud_bot_memory where user_id = new.user_id and bot_id = new.bot_id;
    if n >= 1000 and not exists (select 1 from cloud_bot_memory where user_id = new.user_id and bot_id = new.bot_id and item_id = new.item_id) then raise exception 'bot memory full' using errcode = '23514'; end if;
  elsif tg_table_name = 'cloud_bot_desk' then
    select count(*) into n from cloud_bot_desk where user_id = new.user_id and bot_id = new.bot_id;
    if n >= 1000 and not exists (select 1 from cloud_bot_desk where user_id = new.user_id and bot_id = new.bot_id and item_id = new.item_id) then raise exception 'bot desk full' using errcode = '23514'; end if;
  end if;
  return new;
end $$;

drop trigger if exists cloud_bots_caps on public.cloud_bots;
create trigger cloud_bots_caps before insert on public.cloud_bots for each row execute function public.cloud_bot_caps();
drop trigger if exists cloud_bot_memory_caps on public.cloud_bot_memory;
create trigger cloud_bot_memory_caps before insert on public.cloud_bot_memory for each row execute function public.cloud_bot_caps();
drop trigger if exists cloud_bot_desk_caps on public.cloud_bot_desk;
create trigger cloud_bot_desk_caps before insert on public.cloud_bot_desk for each row execute function public.cloud_bot_caps();

create or replace function public.cloud_bot_journal_trim() returns trigger
language plpgsql security definer set search_path = public as $$
declare cut timestamptz;
begin
  select at into cut from cloud_bot_journal where user_id = new.user_id and bot_id = new.bot_id
    order by at desc offset 500 limit 1;
  if cut is not null then
    delete from cloud_bot_journal where user_id = new.user_id and bot_id = new.bot_id and at <= cut;
  end if;
  return null;
end $$;
drop trigger if exists cloud_bot_journal_trim on public.cloud_bot_journal;
create trigger cloud_bot_journal_trim after insert on public.cloud_bot_journal for each row execute function public.cloud_bot_journal_trim();

-- RLS: own rows only.
alter table public.cloud_bots enable row level security;
alter table public.cloud_bot_memory enable row level security;
alter table public.cloud_bot_desk enable row level security;
alter table public.cloud_bot_journal enable row level security;

do $$
declare t text;
begin
  foreach t in array array['cloud_bots', 'cloud_bot_memory', 'cloud_bot_desk', 'cloud_bot_journal'] loop
    execute format('drop policy if exists %I on public.%I', t || '_select', t);
    execute format('create policy %I on public.%I for select to authenticated using (user_id = auth.uid())', t || '_select', t);
    execute format('drop policy if exists %I on public.%I', t || '_insert', t);
    execute format('create policy %I on public.%I for insert to authenticated with check (user_id = auth.uid())', t || '_insert', t);
    execute format('drop policy if exists %I on public.%I', t || '_update', t);
    execute format('create policy %I on public.%I for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid())', t || '_update', t);
    execute format('drop policy if exists %I on public.%I', t || '_delete', t);
    execute format('create policy %I on public.%I for delete to authenticated using (user_id = auth.uid())', t || '_delete', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('revoke insert, update on public.%I from authenticated', t);
    execute format('grant select, delete on public.%I to authenticated', t);
  end loop;
end $$;

-- Phone-owned columns only. run_state, last_run_at, run_lock_until, version, created_at, updated_at stay with the server.
grant insert (user_id, bot_id, name, setup, knowledge, knowledge_hash, cloud_enabled, schedule, tz_name, tz_offset_min,
              next_run_at, deleted, device_id, origin) on public.cloud_bots to authenticated;
grant update (name, setup, knowledge, knowledge_hash, cloud_enabled, schedule, tz_name, tz_offset_min,
              next_run_at, deleted, device_id, origin) on public.cloud_bots to authenticated;
grant insert (user_id, bot_id, item_id, data, deleted, device_id, origin) on public.cloud_bot_memory to authenticated;
grant update (data, deleted, device_id, origin) on public.cloud_bot_memory to authenticated;
grant insert (user_id, bot_id, item_id, data, deleted, device_id, origin) on public.cloud_bot_desk to authenticated;
grant update (data, deleted, device_id, origin) on public.cloud_bot_desk to authenticated;
-- The journal is append-only for the phone.
grant insert (user_id, bot_id, item_id, at, kind, text, chat, device_id, origin) on public.cloud_bot_journal to authenticated;

-- Is the cloud runner live? (part B flips the setting). Until then phones run every routine themselves.
insert into public.ai_settings (key, value) values ('bot_cloud_runner', 'false'::jsonb) on conflict (key) do nothing;

create or replace function public.bot_cloud_info() returns jsonb
language sql security definer stable set search_path = public as $$
  select jsonb_build_object(
    'runner', coalesce((select value from ai_settings where key = 'bot_cloud_runner') = 'true'::jsonb, false),
    'now', now())
  where auth.uid() is not null
$$;
revoke all on function public.bot_cloud_info() from public, anon;
grant execute on function public.bot_cloud_info() to authenticated;
