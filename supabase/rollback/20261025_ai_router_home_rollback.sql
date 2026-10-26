-- Rollback for 20261025_ai_router_home.sql (S-1 / ai-chat v42).
-- The migration only ADDS a function; ai_router_report, ai_router_snapshot, ai_gate and all tables are untouched.
-- v41 never calls ai_router_home, so dropping it after redeploying v41 is safe (and harmless before, too: v42 logs
-- router_home_failed and keeps working on the current pointer).
drop function if exists public.ai_router_home(uuid, uuid, boolean, text);
-- Pointer rollback, only if needed (pre-v42 value):
-- update public.ai_router_state set current_route_id = '70a8ad0d-7772-4a44-8736-e43b7aaf092f', updated_at = now() where id = 1;
