#!/usr/bin/env bash
# Per-uid test allowance for the chat regression harness (PR-H). Never touches global settings
# (billing.is_unlimited() / ai_settings) and never uses billing_adjust() (that posts a reward_grant to the ledger).
#
#   tools/qa_allowance.sh add    <uid>   insert one billing.token_balances row (source 'admin', 50M tokens, 1 day)
#   tools/qa_allowance.sh revert <uid>   delete the harness rows for that uid (only rows with the harness note)
#   tools/qa_allowance.sh sql add|revert <uid>   print the SQL only (run it from anywhere with DB access)
#   tools/qa_allowance.sh wait           sign in as QA_EMAIL/QA_PW and wait (up to ALLOWANCE_WAIT_MIN minutes,
#                                        default 0) until billing_usage() shows the harness balance; prints the result
#
# How the SQL runs, first match wins:
#   SUPABASE_DB_URL        psql "$SUPABASE_DB_URL"
#   SUPABASE_ACCESS_TOKEN  Supabase Management API  POST /v1/projects/<ref>/database/query
#   neither                prints the SQL and a notice, exits 0 (add it from outside the job, e.g. an operator)
set -euo pipefail
REF="${SUPABASE_REF:-moeemacbvsueekuvfjbo}"
NOTE="qa-regress harness allowance"
AMOUNT="${ALLOWANCE_TOKENS:-50000000}"

uid_ok() { [[ "${1:-}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; }

sql_for() {
  local op="$1" uid="$2"
  uid_ok "$uid" || { echo "bad uid: '$uid'" >&2; exit 2; }
  case "$op" in
    add) echo "insert into billing.token_balances (user_id, amount, left_tokens, expires_at, source, status, note) select '$uid', $AMOUNT, $AMOUNT, now() + interval '1 day', 'admin', 'active', '$NOTE' where not exists (select 1 from billing.token_balances where user_id = '$uid' and note = '$NOTE') returning id;" ;;
    revert) echo "delete from billing.token_balances where user_id = '$uid' and note = '$NOTE' returning id;" ;;
    *) echo "unknown op $op" >&2; exit 2 ;;
  esac
}

run_sql() {
  local q="$1"
  if [ -n "${SUPABASE_DB_URL:-}" ]; then
    psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -At -c "$q"
  elif [ -n "${SUPABASE_ACCESS_TOKEN:-}" ]; then
    curl -sS --fail-with-body -X POST "https://api.supabase.com/v1/projects/$REF/database/query" \
      -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" -H "Content-Type: application/json" \
      -d "$(python3 -c 'import json,sys; print(json.dumps({"query": sys.argv[1]}))' "$q")"
    echo
  else
    echo "::notice::qa_allowance: no SUPABASE_DB_URL or SUPABASE_ACCESS_TOKEN; run this SQL from outside the job:"
    echo "$q"
    return 0
  fi
}

anon() { grep -o "eyJ[^']*" lib/config.dart | head -1; }
base() { grep -o "https://[a-z0-9]*\.supabase\.co" lib/config.dart | head -1; }

usage_now() {
  local tok
  tok=$(curl -sS -X POST "$(base)/auth/v1/token?grant_type=password" -H "apikey: $(anon)" -H "Content-Type: application/json" \
    -d "$(python3 -c 'import json,os; print(json.dumps({"email": os.environ["QA_EMAIL"], "password": os.environ["QA_PW"]}))')" |
    python3 -c 'import json,sys; print(json.load(sys.stdin).get("access_token",""))')
  [ -n "$tok" ] || { echo '{"error":"sign-in failed"}'; return 0; }
  curl -sS -X POST "$(base)/rest/v1/rpc/billing_usage" -H "apikey: $(anon)" -H "Authorization: Bearer $tok" -H "Content-Type: application/json" -d '{}'
}

case "${1:-}" in
  add|revert) run_sql "$(sql_for "$1" "${2:-}")" ;;
  sql) sql_for "${2:-}" "${3:-}" ;;
  wait)
    limit=$(( ${ALLOWANCE_WAIT_MIN:-0} * 60 )); t0=$(date +%s)
    while true; do
      u=$(usage_now)
      left=$(echo "$u" | python3 -c 'import json,sys
try:
  j=json.load(sys.stdin); print(sum(int(b.get("left",0)) for b in j.get("balances",[]) if b.get("source")=="admin"))
except Exception: print(0)')
      if [ "$left" -gt 0 ]; then echo "allowance: harness balance present, left=$left"; break; fi
      if [ $(( $(date +%s) - t0 )) -ge "$limit" ]; then
        echo "::warning::allowance: no harness balance for this account; the run uses the free daily allowance (${u:0:300})"; break
      fi
      echo "allowance: waiting for the harness balance ($(( $(date +%s) - t0 ))s)"; sleep 20
    done ;;
  *) sed -n '2,15p' "$0"; exit 2 ;;
esac
