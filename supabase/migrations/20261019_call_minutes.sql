-- Plan 6 item 3: call minutes. Live voice leaves the token allowance and gets its own daily limit.
-- Day = UTC day, same reset as the token allowance (ai_user_daily).
--
-- live_call_daily   one row per user per UTC day: seconds used, calls started. Users can read their own rows.
-- live_calls        one row per call (a call can use several passes: goAway about every 10 min, drops).
--                   Counting starts when the app reports the line is connected; then every heartbeat
--                   adds the server-measured time since the previous one (at most 120 s per gap), never
--                   more than the wall time since the call connected. "Active" = not ended, connected,
--                   last heartbeat within 150 s: only then is a resume pass handed out.
-- live_user_limits  per-user override: daily_minutes (null = the live_daily_minutes setting) and
--                   live_enabled (false = no calls for this user).
-- Setting live_daily_minutes (default 15, owner confirmed 2026-10-18).

create table if not exists public.live_call_daily (
  user_id uuid not null references auth.users(id) on delete cascade,
  day date not null,
  seconds int not null default 0,
  calls int not null default 0,
  updated_at timestamptz not null default now(),
  primary key (user_id, day)
);

create table if not exists public.live_calls (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  started_at timestamptz not null default now(),
  connected_at timestamptz,
  last_beat_at timestamptz not null default now(),
  ended_at timestamptz,
  seconds int not null default 0,
  passes int not null default 1,
  end_reason text
);
create index if not exists live_calls_user_open_idx on public.live_calls (user_id) where ended_at is null;
create index if not exists live_calls_started_idx on public.live_calls (started_at);

create table if not exists public.live_user_limits (
  user_id uuid primary key references auth.users(id) on delete cascade,
  daily_minutes int check (daily_minutes is null or daily_minutes >= 0),
  live_enabled boolean not null default true,
  note text,
  updated_at timestamptz not null default now()
);

alter table public.live_call_daily enable row level security;
alter table public.live_calls enable row level security;
alter table public.live_user_limits enable row level security;
revoke all on public.live_call_daily, public.live_calls, public.live_user_limits from anon, authenticated;
grant select on public.live_call_daily, public.live_user_limits to authenticated;
drop policy if exists live_call_daily_own on public.live_call_daily;
create policy live_call_daily_own on public.live_call_daily for select to authenticated using (user_id = auth.uid());
drop policy if exists live_user_limits_own on public.live_user_limits;
create policy live_user_limits_own on public.live_user_limits for select to authenticated using (user_id = auth.uid());

insert into public.ai_settings(key, value) values ('live_daily_minutes', '15') on conflict (key) do nothing;

-- Adds seconds to today's ledger (UTC day).
create or replace function public.live_add_seconds(p_uid uuid, p_seconds int, p_calls int default 0) returns void
language sql security definer set search_path = public as $$
  insert into live_call_daily(user_id, day, seconds, calls) values (p_uid, (now() at time zone 'utc')::date, greatest(p_seconds, 0), greatest(p_calls, 0))
  on conflict (user_id, day) do update set seconds = live_call_daily.seconds + excluded.seconds,
    calls = live_call_daily.calls + excluded.calls, updated_at = now();
$$;

-- Today's minutes for one user: limit, used, left, whether Live is on, and when the day resets (UTC midnight).
create or replace function public.live_minutes_left(p_uid uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare def int; lim int; en boolean := true; ovr int; used int := 0; calls int := 0; left_s int;
begin
  select coalesce((value #>> '{}')::int, 15) into def from ai_settings where key = 'live_daily_minutes';
  def := coalesce(def, 15);
  select daily_minutes, live_enabled into ovr, en from live_user_limits where user_id = p_uid;
  en := coalesce(en, true);
  lim := coalesce(ovr, def);
  select d.seconds, d.calls into used, calls from live_call_daily d where d.user_id = p_uid and d.day = (now() at time zone 'utc')::date;
  used := coalesce(used, 0); calls := coalesce(calls, 0);
  left_s := case when en then greatest(lim * 60 - used, 0) else 0 end;
  return jsonb_build_object('limit_minutes', lim, 'default_minutes', def, 'override_minutes', ovr, 'enabled', en,
    'used_seconds', used, 'calls', calls, 'seconds_left', left_s, 'minutes_left', floor(left_s / 60.0)::int,
    'resets_at', to_char(((now() at time zone 'utc')::date + 1)::timestamp, 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
end $$;

-- Closes the user's open calls that stopped reporting (app killed, phone off). A connected call is
-- charged at most 30 s past its last heartbeat (one heartbeat interval).
create or replace function public.live_close_stale(p_uid uuid) returns void
language plpgsql security definer set search_path = public as $$
declare c record; add_s int;
begin
  for c in select * from live_calls where user_id = p_uid and ended_at is null and last_beat_at < now() - interval '150 seconds' for update loop
    add_s := case when c.connected_at is null then 0 else least(30, greatest(0, extract(epoch from now() - c.last_beat_at)::int)) end;
    update live_calls set ended_at = now(), seconds = seconds + add_s, end_reason = 'stale' where id = c.id;
    if add_s > 0 then perform live_add_seconds(p_uid, add_s, 0); end if;
  end loop;
end $$;

-- A new call: closes stale calls, refuses when Live is off or no minutes are left, else opens a call row.
-- Returns live_minutes_left(...) plus ok and call_id.
create or replace function public.live_call_start(p_uid uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m jsonb; cid uuid;
begin
  perform live_close_stale(p_uid);
  m := live_minutes_left(p_uid);
  if not (m->>'enabled')::boolean then return m || jsonb_build_object('ok', false, 'reason', 'live_off'); end if;
  if (m->>'seconds_left')::int <= 0 then return m || jsonb_build_object('ok', false, 'reason', 'minutes_used'); end if;
  insert into live_calls(user_id) values (p_uid) returning id into cid;
  perform live_add_seconds(p_uid, 0, 1);
  return m || jsonb_build_object('ok', true, 'call_id', cid);
end $$;

-- Heartbeat / resume / end for one call. p_reported = connected seconds the app counted (cumulative, may be null).
-- p_kind: 'beat' (also the first "connected" report), 'resume' (a new pass inside the call), 'end'.
-- Credit per gap = server time since the last heartbeat, at most 120 s; the app's own count can fill a longer
-- gap but the call total never passes the wall time since it connected. Before the line connects nothing is counted.
-- A resume is refused (ok false, reason not_active) unless the call is open, connected and heard from in the last 150 s.
create or replace function public.live_call_beat(p_uid uuid, p_call uuid, p_reported int, p_kind text default 'beat') returns jsonb
language plpgsql security definer set search_path = public as $$
declare c live_calls; gap int; wall int; total int; add_s int := 0; m jsonb;
begin
  select * into c from live_calls where id = p_call and user_id = p_uid for update;
  if c.id is null then return live_minutes_left(p_uid) || jsonb_build_object('ok', false, 'reason', 'no_call'); end if;
  if c.ended_at is not null then
    return live_minutes_left(p_uid) || jsonb_build_object('ok', p_kind = 'end', 'reason', 'ended', 'call_id', c.id, 'call_seconds', c.seconds);
  end if;
  if p_kind = 'resume' and (c.connected_at is null or c.last_beat_at < now() - interval '150 seconds') then
    return live_minutes_left(p_uid) || jsonb_build_object('ok', false, 'reason', 'not_active', 'call_id', c.id);
  end if;
  if c.connected_at is null then
    if p_kind = 'beat' then
      update live_calls set connected_at = now(), last_beat_at = now() where id = c.id;
    elsif p_kind = 'end' then
      update live_calls set ended_at = now(), last_beat_at = now(), end_reason = 'end' where id = c.id;
    end if;
  else
    gap := greatest(0, extract(epoch from now() - c.last_beat_at)::int);
    wall := greatest(0, extract(epoch from now() - c.connected_at)::int);
    total := least(wall, greatest(c.seconds + least(gap, 120), least(coalesce(p_reported, 0), wall)));
    add_s := greatest(0, total - c.seconds);
    update live_calls set seconds = c.seconds + add_s, last_beat_at = now(),
      passes = passes + case when p_kind = 'resume' then 1 else 0 end,
      ended_at = case when p_kind = 'end' then now() else null end,
      end_reason = case when p_kind = 'end' then 'end' else end_reason end
    where id = c.id;
    if add_s > 0 then perform live_add_seconds(p_uid, add_s, 0); end if;
  end if;
  m := live_minutes_left(p_uid);
  return m || jsonb_build_object('ok', true, 'call_id', c.id, 'added_seconds', add_s, 'call_seconds', c.seconds + add_s,
    'stop', ((m->>'seconds_left')::int <= 0 and p_kind <> 'end'));
end $$;

-- Dashboard: today's call minutes per user (users who called today or have an override).
create or replace function public.live_minutes_report() returns jsonb
language sql stable security definer set search_path = public as $$
  with def as (select coalesce((select (value #>> '{}')::int from ai_settings where key = 'live_daily_minutes'), 15) m),
  ids as (
    select user_id from live_call_daily where day = (now() at time zone 'utc')::date
    union select user_id from live_user_limits
  )
  select jsonb_build_object(
    'default_minutes', (select m from def),
    'day', (now() at time zone 'utc')::date,
    'users', coalesce((select jsonb_agg(x order by x.used_seconds desc, x.email) from (
      select i.user_id, au.email,
        coalesce(d.seconds, 0) used_seconds, round(coalesce(d.seconds, 0) / 60.0, 1) used_minutes, coalesce(d.calls, 0) calls,
        l.daily_minutes override_minutes, coalesce(l.live_enabled, true) enabled, coalesce(l.daily_minutes, (select m from def)) limit_minutes,
        case when coalesce(l.live_enabled, true) then greatest(coalesce(l.daily_minutes, (select m from def)) * 60 - coalesce(d.seconds, 0), 0) else 0 end seconds_left,
        exists (select 1 from live_calls c where c.user_id = i.user_id and c.ended_at is null and c.last_beat_at > now() - interval '150 seconds') in_call,
        l.note
      from ids i left join auth.users au on au.id = i.user_id
      left join live_call_daily d on d.user_id = i.user_id and d.day = (now() at time zone 'utc')::date
      left join live_user_limits l on l.user_id = i.user_id) x), '[]'::jsonb)
  );
$$;

do $$ declare f text; begin
  foreach f in array array['live_add_seconds(uuid,integer,integer)','live_minutes_left(uuid)','live_close_stale(uuid)',
                           'live_call_start(uuid)','live_call_beat(uuid,uuid,integer,text)','live_minutes_report()'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;
