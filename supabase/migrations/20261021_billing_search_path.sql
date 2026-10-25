-- SubMac Agent billing follow-up: pin search_path on the three billing helpers the Supabase security advisor flags
-- (lint function_search_path_mutable). They only use built-ins (now(), AT TIME ZONE, date_trunc, RAISE), so
-- pg_catalog is all they need. Behaviour is unchanged; ALTER ... SET is idempotent (safe to run twice).
-- Agent project moeemacbvsueekuvfjbo. Requires 20261020_billing.sql.
alter function billing.today() set search_path = pg_catalog;
alter function billing.month_start() set search_path = pg_catalog;
alter function billing.block_changes() set search_path = pg_catalog;
