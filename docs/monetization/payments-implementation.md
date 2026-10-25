# Monetization — payments implementation (section 7, added 2026-10-21)

Companion to `MONETIZATION.md` (that file is kept identical to the copy on `main` so dev→main merges cleanly).

> Update 2026-10-21 (step 5, owner-approved): Sifalo verify.php returns no order_id, so rule 3 below is now: credit when verify says
> status=success/code 601, amount + currency equal the purchase's, and the sid was never used by any purchase (unique (provider, provider_ref));
> an echoed order_id/sid that differs is rejected. Reconcile also accepts `BILLING_CRON_SECRET`. See `supabase/functions/_shared/payments/core.ts`.

## 7. Implementation (payments)

### Layout (submac-agent repo, `supabase/`)
- `migrations/20261020_billing.sql` — billing schema, products, wallets, `billing.mark_paid` (credit once, amount/currency binding, ledger outbox).
- `migrations/20261021_billing_providers.sql` — ADDITIVE: `billing.purchases.provider` (default `'sifalo'`) + `provider_ref`;
  unique `(provider, provider_ref)`; service-role RPCs `billing_create_purchase_v2`, `billing_find_purchase_v2`,
  `billing_mark_paid_v2` (credits once per `(provider, provider_ref)`, then delegates to `billing.mark_paid`),
  `billing_pending_purchases_v2`. `sifalo_sid` keeps working: raw sid for Sifalo, `'<provider>:<ref>'` for other providers.
- `functions/_shared/payments/`
  - `types.ts` — the `PaymentProvider` / `ProviderFactory` interfaces.
  - `core.ts` — provider-neutral logic + the four handlers (checkout, webhook, return, reconcile).
  - `registry.ts` — provider registry; request picks `?provider=<name>` → path `/billing-<fn>/<name>` → env `PAYMENT_PROVIDER` → `sifalo`.
  - `sifalo.ts` — Sifalo adapter (hosted checkout, verify.php, e-wallet charge, refund). Env `SIFALO_API_USER`, `SIFALO_API_KEY`, `SIFALO_ENV=staging|live`.
  - `db.ts` — PostgREST/Auth over fetch (no SDK, so each function bundles to one file).
  - `payments_test.ts` — `deno test` with mocked fetch (Sifalo + a fake provider).
- `functions/billing-checkout|billing-webhook|billing-return|billing-reconcile/index.ts` — one-line wrappers, provider-neutral.

### Rules every provider path follows (core.ts)
1. Refuse (clear error, no provider call, no DB write) when the provider's secrets are missing or `ai_settings.billing_enabled` is not true.
2. Never trust a webhook body or return-URL params. Always re-verify with the provider's source of truth (`verify`).
3. A ref from outside must be bound to the purchase: the provider echoes our order id, or its latest payment for our order id is that ref.
4. Credit only through `billing_mark_paid_v2` (row lock, once per `(provider, provider_ref)`, amount + currency must match, ledger row).
5. Mark failed only when the failing ref is the provider's latest attempt for that order (forged refs can't fail a purchase). Failed is not terminal.
6. Webhook always answers HTTP 200. Reconcile (cron, header `x-cron-secret: AI_CRON_SECRET`) re-verifies pending purchases older than N minutes.

### How to add a new payment provider
1. Create `supabase/functions/_shared/payments/<name>.ts` (name: lowercase `[a-z][a-z0-9_]{1,31}`) exporting a class that implements
   `PaymentProvider` and a `ProviderFactory`:
   - `name`, `supportsOrderLookup` (true if you can look a payment up by our order id — lets reconcile find buyers who never came back);
   - `startCheckout({purchaseId, amount, currency, returnUrl, webhookUrl})` → `{redirectUrl, providerRef}` (`providerRef` = the
     provider's checkout/session id; saved as `checkout_key`). Pass `purchaseId` to the provider as its order id / metadata;
   - `verify({providerRef} | {orderId})` → `{status: paid|pending|failed, providerRef, orderId, amount, currency, paymentType, raw}` —
     `paid` only from the provider's server-side source of truth; `amount` in major units;
   - `parseWebhook(req)` → `{providerRef, orderId, checkoutRef, raw}` (treat it as untrusted hints; signature checks can go here too);
   - `parseReturn(url)` → `{providerRef, orderId}`;
   - optional `chargeWallet(...)` (direct charge) and `refund(...)`;
   - `configured(env)` returns false unless all its secrets are set (then every function refuses for that provider).
2. Register it in `registry.ts` (`PROVIDERS[<name>] = <name>Factory`).
3. Add tests next to `payments_test.ts` (copy the Sifalo cases: success, duplicate, mismatch, pending, failed, flag-off, missing secrets).
4. Set the provider's secrets (`supabase secrets set ...`). Optionally `PAYMENT_PROVIDER=<name>` to make it the default.
5. Bundle and redeploy the four `billing-*` functions (they import the registry). No DB migration is needed: `provider` is free text
   validated by format, and idempotency is per `(provider, provider_ref)`.
6. The app calls `billing-checkout?provider=<name>`; return/webhook URLs are generated with the same `provider` parameter.
