#!/usr/bin/env bash
# Real parallel sessions against a billing v2 test DB (after billing_v2_test.sql): the same request_id charged from 8
# sessions at once is charged once; 8 different requests never overspend a package's daily amount; 6 parallel credits
# of one payment credit once. Usage: PSQL=psql bash billing_v2_concurrency_test.sh <db>
set -euo pipefail
DB="$1"
P="${PSQL:-psql} -X -q -tA -v ON_ERROR_STOP=1 -d $DB"
U=00000000-0000-0000-0000-0000000000c1
$P -c "select set_config('billing.test_now','',false); update billing.plans set active = false where id = 'free';
       insert into public.ai_settings(key,value) values ('billing_provider_env','\"live\"') on conflict (key) do update set value='\"live\"';
       insert into public.ai_settings(key,value) values ('billing_enabled','true') on conflict (key) do update set value='true';
       select public.billing_adjust('$U','weekly',null,'conc');" >/dev/null
for i in $(seq 1 8); do $P -c "select public.usage_charge('$U', 1000, 0, 'chat', 'conc-same')" >/dev/null & done; wait
n=$($P -c "select count(*) from billing.usage_ledger where ref = 'conc-same'")
[ "$n" = "1" ] || { echo "C1 FAILED: same request charged $n times"; exit 1; }
for i in $(seq 1 8); do $P -c "select public.usage_charge('$U', 30000, 0, 'chat', 'conc-$i')" >/dev/null & done; wait
used=$($P -c "select tokens from billing.usage_daily where user_id = '$U' and bucket <> 'free'")
[ "$used" -le 200000 ] || { echo "C2 FAILED: daily amount overspent ($used)"; exit 1; }
[ "$used" = "200000" ] || { echo "C2 FAILED: expected exactly 200000 used, got $used"; exit 1; }
bal=$($P -c "select public.billing_ledger_check() = '[]'::jsonb")
[ "$bal" = "t" ] || { echo "C2 FAILED: ledger not balanced"; exit 1; }
pid=$($P -c "select public.billing_payment_create('$U','payg',1000000,null,'sifalo','conc-key-0001',null)->>'purchase_id'")
for i in $(seq 1 6); do $P -c "select public.billing_payment_paid('$pid','sifalo','SID_CONC',2.00,'USD','x','{}')" >/dev/null & done; wait
n=$($P -c "select count(*) from billing.token_balances where payment_id = '$pid'")
[ "$n" = "1" ] || { echo "C3 FAILED: payment credited $n times"; exit 1; }
$P -c "update billing.plans set active = true where id = 'free'" >/dev/null
echo "concurrency C1-C3 pass"
