-- v1.13.12 (plan 2.1 "Push, not polling"): FCM tokens per phone, so the cloud (push-send, later bot-run) can reach a user.
-- One row per token. A signed-in user sees and manages only their own rows; push-send reads them with the service role.
create table if not exists public.push_tokens (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  token text not null,
  platform text not null default 'android',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint push_tokens_token_key unique (token),
  constraint push_tokens_token_len check (char_length(token) between 10 and 4096),
  constraint push_tokens_platform_chk check (platform in ('android', 'ios', 'web'))
);
create index if not exists push_tokens_user_idx on public.push_tokens (user_id);

alter table public.push_tokens enable row level security;

drop policy if exists push_tokens_select on public.push_tokens;
create policy push_tokens_select on public.push_tokens for select to authenticated using (user_id = auth.uid());
drop policy if exists push_tokens_insert on public.push_tokens;
create policy push_tokens_insert on public.push_tokens for insert to authenticated with check (user_id = auth.uid());
drop policy if exists push_tokens_update on public.push_tokens;
create policy push_tokens_update on public.push_tokens for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists push_tokens_delete on public.push_tokens;
create policy push_tokens_delete on public.push_tokens for delete to authenticated using (user_id = auth.uid());

revoke all on public.push_tokens from anon;
grant select, insert, update, delete on public.push_tokens to authenticated;

-- A phone that signs in to another account takes its token along: the RLS update above cannot move a row that
-- belongs to someone else, so the app calls this instead. It only ever writes the caller's own user id.
create or replace function public.register_push_token(p_token text, p_platform text default 'android') returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if p_token is null or char_length(p_token) not between 10 and 4096 then raise exception 'bad token'; end if;
  insert into push_tokens (user_id, token, platform, updated_at)
  values (auth.uid(), p_token, coalesce(nullif(p_platform, ''), 'android'), now())
  on conflict (token) do update set user_id = excluded.user_id, platform = excluded.platform, updated_at = now();
end $$;
revoke all on function public.register_push_token(text, text) from public, anon;
grant execute on function public.register_push_token(text, text) to authenticated;
