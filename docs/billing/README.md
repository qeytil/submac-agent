# Billing (Dev 2)

PLAN.md PART 2 + Contracts A/B. Server: `supabase/migrations/20261023_billing_v2.sql` (one migration: removes the old
billing, creates this one, schedules the jobs). Edge: `supabase/functions/_shared/payments/` + `billing-*`.
App: `lib/services/billing/`, `lib/screens/billing/`.

## Products (`billing.plans`)

| Plan | Price | Total | Daily | Valid |
|---|---|---|---|---|
| Free | — | 1M a month | 60k | — |
| Weekly | $1.25 | 700k | 200k | 7 days |
| Monthly | $4.99 | 3M | 250k | 30 days |
| Monthly Plus (off) | $9.99 | 6M | 500k | 30 days |
| Pay as you go | $2.00 per 1M | 1M–50M, 100k steps | — | 12 months |

- Spending order: free daily → packages (soonest-ending first, within each daily amount) → PAYG (soonest-expiring first).
- A package bought while one runs starts when it ends (daily amounts never stack).
- Bots (`bot`, `bot-cloud`, `background`, `office`): at most 50% of each daily amount. PAYG has no bot cap.
- Live voice: 40k per minute. Tokens are raw input + output, no cached discount, no model multipliers.
- Day: midnight Africa/Mogadishu (EAT). The UI counts replies (3,700 tokens ≈ 1 reply), never tokens outside PAYG.

## Contract B (ai-chat, Dev 1; service role)

```sql
public.usage_gate(user_id, source)  -> {allow, enabled, code, reason, today_left, total_left, resets_at, plan, reply_cap}
public.usage_charge(user_id, tokens_in, tokens_out, source, request_id)
                                    -> {ok, charged, free, package, payg, unpaid, today_left, total_left, resets_at, plan, duplicate}
public.usage_charge_enqueue(...)    -- same arguments; when usage_charge failed. Retried every 5 min, same request_id.
```

- `code`: `limit_daily` (`reason = 'bot_share'` for bots), `limit_total`, `no_plan`. `reply_cap` = min(8192, today left).
- Idempotent by `request_id` (another user's id: `request_id_conflict`). The last reply may overrun: logged, never billed.
- Live: `usage_charge(uid, <seconds>, 0, 'live', 'live:<call>:<seconds so far>')`.
- Headers (Contract A): `x-submac-today-left`, `x-submac-total-left`, `x-submac-resets-at`, `x-submac-plan`.

## Switch

- `billing_enabled` can be true only when `billing_provider_env` = `live`. While Sifalo is staging, only users in
  `billing_testers` (uuid list) have billing (for the staging end-to-end purchase); everyone else is unbilled.
- Edge functions read `billing_is_on(uid)`. With `SIFALO_ENV=staging` only testers can check out.

## Payments

- Always re-verify with Sifalo; unknown ≠ failed; double-tap and idempotency guards; credit once per provider ref.
- A ref from outside (return URL, webhook) must be the provider's payment for that order (verify by order id), else
  `sid_not_for_order`.
- `billing-return` always redirects to the app (`submac://pay?status=…&purchase=…`), never a JSON page.

## Jobs (pg_cron)

`billing-reconcile` every 10 min (re-check pending payments, expire abandoned ones after 24 h; needs vault secrets
`bot_run_anon_key` + `billing_cron_secret`), `billing-charge-retry` every 5 min, `billing-ledger-sync` every 30 min,
`billing-renewal-reminders` hourly (inbox message the day before a package ends; no auto-charge).

## Admin (service role)

`billing_plan_update(id, patch)`, `billing_admin_payments(status, uid, limit)`,
`billing_payment_reverse(payment, 'refund'|'clawback', reason, by)` and `billing_adjust(uid, plan, tokens, note)` (both write
reversing ledger rows), `billing_ledger_check()` (empty = balanced).

## App

`billing_usage()` (Plan & usage + catalogue), `billing_activity()`, `billing_deletion_warning()` →
`Billing.I.deletionWarning()` (one line for the delete-account dialog, or null). Strings: `billing_copy.dart` (English + Somali).

## Tests

```
PGHOST=… PGPORT=… PGUSER=postgres bash supabase/tests/run_billing_tests.sh   # throwaway PostgreSQL only
deno test -A supabase/functions/_shared/payments/payments_test.ts
flutter test test/billing
```
