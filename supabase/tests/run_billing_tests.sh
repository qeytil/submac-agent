#!/usr/bin/env bash
# Billing tests on a THROWAWAY local PostgreSQL (never the real project).
#   PGHOST=/tmp/pg PGPORT=5499 PGUSER=postgres bash supabase/tests/run_billing_tests.sh
# 1) fresh DB: stubs -> 20261023_billing_v2.sql (twice: idempotent) -> billing_v2_test.sql
# 2) old coin-era DB: stubs -> coin-era billing migrations + some coin rows -> v2 (twice): no coin object left -> tests
# 3) concurrency: parallel usage_charge / payment credit sessions (billing_v2_concurrency_test.sh)
set -euo pipefail
cd "$(dirname "$0")/.."
DB="${BILLING_TEST_DB:-billing_v2_test}"
PSQL_BIN="${PSQL:-psql}"
PSQL="$PSQL_BIN -X -q -v ON_ERROR_STOP=1"
quiet() { { grep -v -E 'NOTICE|^$' || true; }; }
fresh() { $PSQL -d postgres -c "drop database if exists $1" -c "create database $1" 2>&1 | quiet; $PSQL -d "$1" -f tests/billing_stubs.sql 2>&1 | quiet; }
objects() { $PSQL -d "$1" -tA -c "select (select count(*) from billing.plans)||'/'||(select count(*) from public.ai_settings)||'/'||
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('billing','public'))||'/'||
  (select count(*) from pg_tables where schemaname='billing')||'/'||(select count(*) from cron.job)"; }
coins_left() { $PSQL -d "$1" -tA -c "select
  (select count(*) from pg_tables where schemaname = 'billing' and tablename in ('wallets','coin_transactions','token_grants','products',
     'purchases','model_multipliers','consumption','consume_retry','live_charges','free_usage','daily_spend','first_bonus','referral_rewards'))
 + (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where (n.nspname = 'billing' and p.proname in
     ('wallet','add_coins','consume','multiplier_for','buy_with_coins','grant_pass','entitlements','live_charge','mark_paid','reverse'))
     or (n.nspname = 'public' and (p.proname like 'billing\_%purchase%' or p.proname in ('billing_summary','billing_exchange',
     'billing_precheck','billing_consume','billing_multipliers','billing_live_charge','billing_reconcile_usage','billing_buy_pass'))))
 + (select count(*) from public.ai_settings where key in ('billing_coin_usd','billing_free_daily_tokens','billing_auto_exchange_threshold'))
 + (select count(*) from cron.job where jobname = 'billing-reconcile-usage')"; }

echo "== 1) fresh database"
fresh "$DB"
$PSQL -d "$DB" -f migrations/20261023_billing_v2.sql 2>&1 | quiet
a=$(objects "$DB")
$PSQL -d "$DB" -f migrations/20261023_billing_v2.sql 2>&1 | quiet
b=$(objects "$DB")
[ "$a" = "$b" ] || { echo "migration not idempotent: $a vs $b"; exit 1; }
echo "20261023_billing_v2.sql applied twice, idempotent (plans/settings/functions/tables/cron $b)"
$PSQL -d "$DB" -f tests/billing_v2_test.sql | grep "groups passed"

echo "== 2) database that had the coin system"
U="${DB}_up"
fresh "$U"
for m in 20261020_billing.sql 20261021_billing_search_path.sql 20261021_billing_providers.sql 20261021_billing_hardening.sql 20261021_billing_usage_retry.sql; do
  $PSQL -d "$U" -f "migrations/$m" 2>&1 | quiet
done
$PSQL -d "$U" -q -c "select billing.add_coins('0000000a-0000-0000-0000-000000000000', 400, 'admin', null, null, null, 'seed');
  select public.billing_grant_admin('0000000b-0000-0000-0000-000000000000', 'pack_1m', 'seed');
  select cron.schedule('billing-reconcile-usage', '*/5 * * * *', 'select public.billing_reconcile_usage()');" >/dev/null
[ "$(coins_left "$U")" != "0" ] || { echo "seed did not create coin objects"; exit 1; }
$PSQL -d "$U" -f migrations/20261023_billing_v2.sql 2>&1 | quiet
c=$(objects "$U")
$PSQL -d "$U" -f migrations/20261023_billing_v2.sql 2>&1 | quiet
d=$(objects "$U")
[ "$c" = "$d" ] || { echo "re-run changed objects: $c vs $d"; exit 1; }
n=$(coins_left "$U")
[ "$n" = "0" ] || { echo "coin objects left after v2: $n"; exit 1; }
echo "coin system removed outright, re-applied unchanged ($d)"
$PSQL -d "$U" -f tests/billing_v2_test.sql | grep "groups passed"

echo "== 3) concurrency"
PSQL="$PSQL_BIN" bash tests/billing_v2_concurrency_test.sh "$DB"
echo "ALL BILLING TESTS PASSED"
