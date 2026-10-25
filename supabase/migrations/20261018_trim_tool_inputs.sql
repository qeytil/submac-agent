-- v1.12.1: one-time cleanup of tool-call inputs already in the backup.
-- The app backup (Repo.forBackup / _trimCall) now replaces any tool-call input
-- (tool_calls[i].function.arguments, a JSON string) longer than 2,000 characters with
-- the JSON string {"note":"Long input kept on the phone only"}. Old rows get the same
-- shape so they still load; every other key and the order of the calls is kept.
update public.messages m
set tool_calls = (
  select jsonb_agg(
           case
             when jsonb_typeof(c->'function'->'arguments') = 'string'
                  and length(c->'function'->>'arguments') > 2000
             then jsonb_set(c, '{function,arguments}',
                            to_jsonb('{"note":"Long input kept on the phone only"}'::text))
             else c
           end
           order by i)
  from jsonb_array_elements(m.tool_calls) with ordinality as t(c, i)
)
where jsonb_typeof(m.tool_calls) = 'array'
  and exists (
    select 1 from jsonb_array_elements(m.tool_calls) c
    where jsonb_typeof(c->'function'->'arguments') = 'string'
      and length(c->'function'->>'arguments') > 2000
  );

-- Run separately (VACUUM cannot run inside a transaction block):
-- vacuum public.messages;
