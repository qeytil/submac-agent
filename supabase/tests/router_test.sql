-- Router migration tests (throwaway DB only): seeding of alias `submac`, CAS swap, windows, backoff ladder, ai_gate.
-- Run: supabase/tests/run_router_tests.sh
\set ON_ERROR_STOP 1
\pset tuples_only on
\o /dev/null
create or replace function pg_temp.ok(c boolean, what text) returns void language plpgsql as $$
begin if not c then raise exception 'FAIL: %', what; end if; raise notice 'ok - %', what; end $$;

-- Seeded routes: 3 smart (incl. one Gemini), Gemini from somali + vision, nothing else.
select pg_temp.ok((select count(*) from ai_routes where alias = 'submac') = 5, 'R01 submac has 3 smart + 2 extra Gemini routes');
select pg_temp.ok((select count(*) from ai_routes r join ai_models m on m.id = r.model_ref where r.alias = 'submac' and m.model_id = 'open-x') = 0, 'R02 non-Gemini routes of other aliases are not copied');
select pg_temp.ok((select min(priority) from ai_routes r join ai_models m on m.id=r.model_ref where r.alias='submac' and m.model_id in ('gemini-so','gemini-vis')) > 1000, 'R03 Gemini extras come after the smart routes');
select pg_temp.ok((select count(*) from ai_routes where alias = 'submac-smart') = 3, 'R04 old alias rows untouched');

-- Snapshot with no pointer.
select pg_temp.ok(ai_router_snapshot() -> 'current_route_id' = 'null'::jsonb, 'R05 no pointer yet');

create temp table ids as select
  (select r.id from ai_routes r join ai_models m on m.id=r.model_ref where r.alias='submac' and m.model_id='smart-a') a,
  (select r.id from ai_routes r join ai_models m on m.id=r.model_ref where r.alias='submac' and m.model_id='smart-b') b,
  (select r.id from ai_routes r join ai_models m on m.id=r.model_ref where r.alias='submac' and m.model_id='gemini-so') c;

-- Two hard failures: no swap. Third: swap to b, a rests 1 min.
select pg_temp.ok((ai_router_report(a, 'hard', b) ->> 'swapped')::boolean = false, 'R06 1st hard failure: no swap') from ids;
select pg_temp.ok((ai_router_report(a, 'hard', b) ->> 'swapped')::boolean = false, 'R07 2nd hard failure: no swap') from ids;
select pg_temp.ok((ai_router_report(a, 'hard', b) ->> 'rest_seconds')::int = 60, 'R08 3rd hard failure: swap, rest 60 s') from ids;
select pg_temp.ok((ai_router_snapshot() ->> 'current_route_id')::uuid = b, 'R09 pointer is now b') from ids;
select pg_temp.ok(ai_router_snapshot() -> 'rest' ? a::text, 'R10 a is resting') from ids;
-- CAS: late reports about a (other isolates) change nothing.
select pg_temp.ok((ai_router_report(a, 'hard', c) ->> 'stale')::boolean, 'R11 stale report ignored (compare-and-set)') from ids;
select pg_temp.ok((ai_router_snapshot() ->> 'current_route_id')::uuid = b, 'R12 pointer still b') from ids;

-- Two first-byte timeouts swap b -> c.
select ai_router_report(b, 'fb_timeout', c) from ids;
select pg_temp.ok((ai_router_report(b, 'fb_timeout', c) ->> 'swapped')::boolean, 'R13 2 first-byte timeouts swap') from ids;

-- Window: failures older than 60 s do not count.
update ai_router_state set fail_count = 2, window_start = now() - interval '61 seconds';
select pg_temp.ok((ai_router_report(c, 'hard', a) ->> 'swapped')::boolean = false, 'R14 old window resets the count') from ids;
select pg_temp.ok((select fail_count from ai_router_state) = 1, 'R15 count restarted at 1');

-- Backoff ladder: a rested recently -> next swap of a rests 2 min, then 4, 8, 15, 15.
update ai_router_state set current_route_id = (select a from ids), fail_count = 0, fb_timeouts = 0, window_start = now();
select pg_temp.ok((select (ai_router_report(a,'fb_timeout',b)->>'swapped') is not null) and (ai_router_report(a,'fb_timeout',b)->>'rest_seconds')::int = 120, 'R16 second rest within 30 min = 2 min') from ids;
do $$ declare i int; s int; exp int[] := array[240, 480, 900, 900]; a uuid; b uuid; begin
  select ids.a, ids.b into a, b from ids;
  for i in 1..4 loop
    update ai_router_state set current_route_id = a, fail_count = 0, fb_timeouts = 1, window_start = now();
    s := (ai_router_report(a, 'fb_timeout', b) ->> 'rest_seconds')::int;
    if s <> exp[i] then raise exception 'FAIL: R17 ladder step % got % want %', i, s, exp[i]; end if;
  end loop;
  raise notice 'ok - R17 ladder 4, 8, 15, 15 min';
end $$;
-- A long-ago rest starts again at 1 min.
update ai_route_rest set rested_until = now() - interval '2 hours';
update ai_router_state set current_route_id = (select a from ids), fail_count = 0, fb_timeouts = 1, window_start = now();
select pg_temp.ok((ai_router_report(a, 'fb_timeout', b) ->> 'rest_seconds')::int = 60, 'R18 old rest: back to 1 min') from ids;

-- No next route: count but never swap to nothing.
update ai_router_state set current_route_id = (select b from ids), fail_count = 2, fb_timeouts = 0, window_start = now();
select pg_temp.ok((ai_router_report(b, 'hard', null) ->> 'swapped')::boolean = false, 'R19 no next route: no swap') from ids;
-- Bad kind ignored.
select pg_temp.ok((ai_router_report(b, 'overflow', c) ->> 'ignored')::boolean, 'R20 overflow is not a failure kind') from ids;

-- Disabled pointer route reads as no pointer.
update ai_routes set enabled = false where id = (select b from ids);
select pg_temp.ok(ai_router_snapshot() -> 'current_route_id' = 'null'::jsonb, 'R21 disabled pointer route = no pointer');
update ai_routes set enabled = true where id = (select b from ids);

-- ai_gate carries the router and prefers the current route's provider keys.
select pg_temp.ok((ai_gate(gen_random_uuid(), false, 'submac', false) -> 'router' ->> 'current_route_id')::uuid = b, 'R22 ai_gate returns the pointer') from ids;
select pg_temp.ok((select jsonb_object_keys(ai_gate(gen_random_uuid(), false, 'submac', false) -> 'keys') limit 1)::uuid =
  (select m.provider_id from ai_routes r join ai_models m on m.id=r.model_ref where r.id=(select b from ids)), 'R23 cold-start keys are the current route''s provider');
select pg_temp.ok(ai_gate(gen_random_uuid(), true, null, false) -> 'config' -> 'aliases' @> '[{"alias":"submac"}]', 'R24 config lists alias submac');
-- Service role only.
select pg_temp.ok(not has_function_privilege('authenticated', 'public.ai_router_report(uuid,text,uuid)', 'execute'), 'R25 report is service-only');
select pg_temp.ok(not has_table_privilege('authenticated', 'public.ai_router_state', 'select'), 'R26 state table closed to users');
\echo 'router tests: all passed'
