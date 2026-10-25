-- A removed bot stays removed (BUGHUNT round 2, SYNC-5). Bot ids are never reused, so a plain upsert with
-- deleted = false landing on a tombstone is always a phone that had not heard about the removal yet: it would
-- bring the bot back on every phone without its memory, desk or journal. The phone's round fails once, its next
-- pull sees the tombstone and takes the bot off.
create or replace function public.cloud_bot_touch() returns trigger
language plpgsql set search_path = public as $$
begin
  new.updated_at := clock_timestamp();
  if tg_op = 'UPDATE' then
    new.user_id := old.user_id;
    new.created_at := old.created_at;
    if tg_table_name = 'cloud_bots' then
      if old.deleted and not new.deleted then
        raise exception 'bot removed' using errcode = '23514';
      end if;
      new.version := old.version + 1;
    end if;
  else
    new.created_at := new.updated_at;
    if tg_table_name = 'cloud_bots' then new.version := 1; end if;
  end if;
  return new;
end $$;
