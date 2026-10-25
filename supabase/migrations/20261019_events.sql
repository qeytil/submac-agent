-- Plan 2.6: measure bots. One row per product event, written by the app (batched, fire-and-forget), never read by
-- users. Counts per kind come from ai-admin `events_summary` (service role).
--
-- kinds: hired, first_result, replied, ignored, kept_7d, shared, hired_from_share
-- props: small, allow-listed, no PII (no names, text, emails, codes): from, kind, how, mins, v.

create table if not exists public.events (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  kind text not null check (kind in ('hired','first_result','replied','ignored','kept_7d','shared','hired_from_share')),
  bot_id text check (bot_id is null or (length(bot_id) <= 64 and bot_id ~ '^[A-Za-z0-9_:.-]+$')),
  props jsonb not null default '{}'::jsonb check (jsonb_typeof(props) = 'object' and length(props::text) <= 400),
  at timestamptz not null default now()
);
create index if not exists events_kind_at on public.events(kind, at);
create index if not exists events_user_at on public.events(user_id, at);

alter table public.events enable row level security;
-- Insert-only for the owner; no select/update/delete policy, so users can never read events back.
drop policy if exists events_insert_own on public.events;
create policy events_insert_own on public.events for insert to authenticated with check (user_id = auth.uid());
revoke all on public.events from anon, authenticated;
grant insert (kind, bot_id, props) on public.events to authenticated;

-- Batched insert from the app: up to 50 events per call, unknown kinds dropped, props cut to the allow-list
-- (scalar values, strings at most 24 characters), times clamped to the last 3 days (a phone that was offline).
create or replace function public.log_events(p_events jsonb)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  e jsonb; k text; b text; pr jsonb; t timestamptz; n int := 0; key text; val jsonb;
begin
  if uid is null then raise exception 'sign in first'; end if;
  if jsonb_typeof(p_events) <> 'array' then return 0; end if;
  for e in select * from jsonb_array_elements(p_events) limit 50 loop
    if jsonb_typeof(e) <> 'object' then continue; end if;
    k := e->>'kind';
    if k is null or k not in ('hired','first_result','replied','ignored','kept_7d','shared','hired_from_share') then continue; end if;
    b := nullif(left(e->>'bot_id', 64), '');
    if b is not null and b !~ '^[A-Za-z0-9_:.-]+$' then b := null; end if;
    pr := '{}'::jsonb;
    if jsonb_typeof(e->'props') = 'object' then
      for key, val in select * from jsonb_each(e->'props') loop
        if key not in ('from','kind','how','mins','v') then continue; end if;
        if jsonb_typeof(val) = 'number' or jsonb_typeof(val) = 'boolean' then pr := pr || jsonb_build_object(key, val);
        elsif jsonb_typeof(val) = 'string' then pr := pr || jsonb_build_object(key, left(val #>> '{}', 24));
        end if;
      end loop;
    end if;
    begin t := (e->>'at')::timestamptz; exception when others then t := null; end;
    if t is null or t > now() + interval '5 minutes' or t < now() - interval '3 days' then t := now(); end if;
    insert into events(user_id, kind, bot_id, props, at) values (uid, k, b, pr, t);
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.log_events(jsonb) from public, anon;
grant execute on function public.log_events(jsonb) to authenticated;

-- Counts per kind over the last p_days (7 or 30) for the admin dashboard (service role only).
create or replace function public.events_summary(p_days int default 7)
returns jsonb
language sql
security definer
set search_path = public
as $$
  with w as (select * from events where at >= now() - make_interval(days => greatest(1, least(coalesce(p_days, 7), 90))))
  select jsonb_build_object(
    'days', greatest(1, least(coalesce(p_days, 7), 90)),
    'kinds', coalesce((select jsonb_object_agg(kind, jsonb_build_object('events', c, 'users', u, 'bots', bc))
       from (select kind, count(*) c, count(distinct user_id) u, count(distinct (user_id, bot_id)) bc from w group by kind) x), '{}'::jsonb),
    'reply_rate', (select case when count(*) = 0 then null else round(count(*) filter (where kind = 'replied')::numeric / count(*), 3) end
       from w where kind in ('replied','ignored')),
    'total', (select count(*) from w));
$$;
revoke all on function public.events_summary(int) from public, anon, authenticated;
grant execute on function public.events_summary(int) to service_role;
