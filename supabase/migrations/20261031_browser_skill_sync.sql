-- Site skills follow the account: a browser flow learned on one phone replays on another.
--
-- A site skill (playbook) is the shortest honest list of steps a flow needed, matched by signature
-- (kind + visible label + href), never by coordinates — see lib/services/browser/playbook.dart. Until now
-- they lived only in this phone's documents, so a new phone started with none.
--
-- cloud_browser_skills   one row per skill: what it is (name, site, goal, steps) and how it has done
--                        (runs, wins). `at` is when the skill was last learned or changed on a phone, in the
--                        phone's own clock, so "newest recording wins" survives a reinstall. `deleted` is a
--                        tombstone: a skill forgotten on one phone is dropped on the others (and never
--                        comes back), instead of being re-learned by every device.
-- RLS: a user reads only their own rows. Nothing writes the table directly — every write goes through
-- browser_skill_push(), which merges: counters only grow (a replay on either phone counts), the newest
-- `at` wins for the steps, and a removal wins over anything older. That is what makes a push idempotent:
-- the same phone can send the same skill every round without the counters inflating or an older copy
-- overwriting a newer one. 200 skills per user.
--
-- No password ever reaches this table: SiteSkills refuses to save a playbook with a password field
-- (compressSteps drops kind ~ 'password'), and the login is offered to the person at replay time instead.

create table if not exists public.cloud_browser_skills (
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  skill_id text not null,
  name text not null default '',
  site text not null default '',
  goal text not null default '',
  steps jsonb not null default '[]'::jsonb,
  runs int not null default 0,
  wins int not null default 0,
  -- When it was last learned or changed on a phone (the playbook's own `at`).
  at timestamptz not null default now(),
  deleted boolean not null default false,
  device_id text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, skill_id),
  constraint cloud_browser_skills_id_len check (char_length(skill_id) between 1 and 64),
  constraint cloud_browser_skills_name_len check (char_length(name) <= 120),
  constraint cloud_browser_skills_site_len check (char_length(site) <= 200),
  constraint cloud_browser_skills_goal_len check (char_length(goal) <= 500),
  constraint cloud_browser_skills_steps_size check (octet_length(steps::text) <= 64000),
  constraint cloud_browser_skills_counts_chk check (runs >= 0 and wins >= 0),
  constraint cloud_browser_skills_device_len check (char_length(device_id) <= 64)
);
create index if not exists cloud_browser_skills_user_upd_idx on public.cloud_browser_skills (user_id, updated_at);

-- Server time on every write; the owner of a row never changes. (The same trigger the cloud_bot* tables use.)
drop trigger if exists cloud_browser_skills_touch on public.cloud_browser_skills;
create trigger cloud_browser_skills_touch before insert or update on public.cloud_browser_skills
  for each row execute function public.cloud_bot_touch();

-- The only way in. Counters only grow; the newest recording wins; a removal wins over anything older.
-- Returns the merged row, so the phone learns the counters the account now holds (another phone may be ahead).
create or replace function public.browser_skill_push(
  p_id text,
  p_name text default '',
  p_site text default '',
  p_goal text default '',
  p_steps jsonb default '[]'::jsonb,
  p_runs int default 0,
  p_wins int default 0,
  p_at timestamptz default now(),
  p_deleted boolean default false,
  p_device text default ''
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  r public.cloud_browser_skills;
  n int;
  mine int;
begin
  if uid is null then raise exception 'not signed in' using errcode = '28000'; end if;
  if p_id is null or char_length(btrim(p_id)) = 0 or char_length(p_id) > 64 then
    raise exception 'a skill needs an id of 1-64 characters' using errcode = '23514';
  end if;
  select count(*) into n from cloud_browser_skills where user_id = uid;
  if n >= 200 and not exists (select 1 from cloud_browser_skills where user_id = uid and skill_id = p_id) then
    raise exception 'too many skills' using errcode = '23514';
  end if;
  mine := greatest(coalesce(p_runs, 0), 0);
  insert into cloud_browser_skills (user_id, skill_id, name, site, goal, steps, runs, wins, at, deleted, device_id)
  values (uid, p_id,
          left(coalesce(p_name, ''), 120), left(coalesce(p_site, ''), 200), left(coalesce(p_goal, ''), 500),
          coalesce(p_steps, '[]'::jsonb),
          mine,
          -- a win is a run that finished: never more wins than runs, whatever a file says
          least(greatest(coalesce(p_wins, 0), 0), mine),
          coalesce(p_at, now()), coalesce(p_deleted, false), left(coalesce(p_device, ''), 64))
  on conflict (user_id, skill_id) do update set
    runs = greatest(cloud_browser_skills.runs, excluded.runs),
    wins = least(greatest(cloud_browser_skills.wins, excluded.wins),
                 greatest(cloud_browser_skills.runs, excluded.runs)),
    name = case when excluded.at > cloud_browser_skills.at then excluded.name else cloud_browser_skills.name end,
    site = case when excluded.at > cloud_browser_skills.at then excluded.site else cloud_browser_skills.site end,
    goal = case when excluded.at > cloud_browser_skills.at then excluded.goal else cloud_browser_skills.goal end,
    steps = case when excluded.at > cloud_browser_skills.at then excluded.steps else cloud_browser_skills.steps end,
    deleted = case when excluded.at > cloud_browser_skills.at then excluded.deleted else cloud_browser_skills.deleted end,
    device_id = case when excluded.at > cloud_browser_skills.at then excluded.device_id else cloud_browser_skills.device_id end,
    at = greatest(cloud_browser_skills.at, excluded.at)
  returning * into r;
  -- The whole merged row: the phone learns the counters the account now holds, and the steps when another
  -- phone recorded a newer version while this one was offline.
  return to_jsonb(r);
end $$;
revoke all on function public.browser_skill_push(text, text, text, text, jsonb, int, int, timestamptz, boolean, text) from public, anon;
grant execute on function public.browser_skill_push(text, text, text, text, jsonb, int, int, timestamptz, boolean, text) to authenticated;

-- Own rows only, and read-only: writes go through browser_skill_push().
alter table public.cloud_browser_skills enable row level security;
drop policy if exists cloud_browser_skills_select on public.cloud_browser_skills;
create policy cloud_browser_skills_select on public.cloud_browser_skills
  for select to authenticated using (user_id = auth.uid());
revoke all on public.cloud_browser_skills from anon;
revoke insert, update, delete on public.cloud_browser_skills from authenticated;
grant select on public.cloud_browser_skills to authenticated;
