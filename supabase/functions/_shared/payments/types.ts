// Provider-neutral payment types. A payment provider is one adapter file implementing PaymentProvider plus a
// ProviderFactory registered in registry.ts. The core (core.ts) and the four billing-* edge functions never know
// which provider they talk to.

/** Reads one environment variable (Deno.env.get in production, a map in tests). */
export type Env = (key: string) => string | undefined;
export type FetchFn = typeof fetch;

export type PayStatus = "paid" | "pending" | "failed";

/**
 * Machine-readable reasons the app maps to friendly text (see FAILURE_MESSAGES in core.ts).
 * insufficient_funds (Sifalo 604) | declined (600 / any failed) | provider_config (Sifalo 0: wrong API user/key) |
 * provider_rejected (Sifalo "404": missing fields) | provider_timeout | provider_unavailable (network, 5xx, malformed).
 */
export type FailReason = "insufficient_funds" | "declined" | "provider_config" | "provider_rejected";

/** The provider answered and definitely did NOT take money (bad credentials, missing fields). Safe to fail. */
export class ProviderRefused extends Error {
  constructor(readonly reason: FailReason, message: string) {
    super(message);
    this.name = "ProviderRefused";
  }
}

/** The provider could not be reached or answered something we cannot read. The outcome is UNKNOWN: never fail or
 *  credit on this; leave the purchase pending for reconcile. */
export class ProviderUnavailable extends Error {
  constructor(readonly kind: "provider_timeout" | "provider_unavailable", message: string) {
    super(message);
    this.name = "ProviderUnavailable";
  }
}

export interface StartCheckoutInput {
  purchaseId: string; // our billing.purchases.id; providers should echo it back as their order id
  amount: number; // major units, e.g. 1.99
  currency: string; // ISO code, "USD"
  returnUrl: string; // browser comes back here (billing-return)
  webhookUrl: string; // provider POSTs here (billing-webhook)
}

export interface StartCheckoutResult {
  redirectUrl: string; // send the customer's browser here
  providerRef: string; // the provider's checkout/session reference (stored in billing.purchases.checkout_key)
}

/** Ask the provider for its own record of one payment: by payment ref (preferred) or by our order id. */
export interface VerifyQuery {
  providerRef?: string | null;
  orderId?: string | null;
}

export interface VerifyResult {
  status: PayStatus; // paid ONLY when the provider's source of truth says so
  providerRef: string | null; // the provider's payment id (Sifalo sid); null when nothing was found
  orderId: string | null; // our purchase id as the provider recorded it, when it returns one
  amount: number | null; // what the customer actually paid (major units)
  currency: string | null;
  paymentType: string | null; // e.g. EDAHAB / ZAAD / CARD
  reason?: FailReason | null; // why it failed (status "failed" only)
  raw: unknown; // provider response, stored as verify_payload
}

/** What an (untrusted) webhook body points at. The core re-verifies before anything is credited. */
export interface WebhookInfo {
  providerRef: string | null;
  orderId: string | null;
  checkoutRef: string | null;
  raw: unknown;
}

export interface ReturnInfo {
  providerRef: string | null;
  orderId: string | null;
}

export interface WalletChargeInput {
  purchaseId: string;
  amount: number;
  currency: string;
  account: string; // wallet number
  method: string; // provider-specific wallet gateway (Sifalo: waafi | edahab | pbwallet)
  webhookUrl: string;
}

export interface WalletChargeResult {
  /** paid/pending/failed as the provider said; "unknown" = an answer we cannot classify (stay pending, reconcile). */
  status: PayStatus | "unknown";
  reason?: FailReason | null;
  providerRef: string | null;
  message: string | null;
  raw: unknown;
}

export interface RefundInput {
  providerRef: string; // original successful payment
  amount: number;
  currency: string;
  orderId: string;
  method?: string | null;
}

export interface RefundResult {
  ok: boolean;
  providerRef: string | null; // the refund's own reference
  raw: unknown;
}

export interface PaymentProvider {
  readonly name: string; // lowercase id, also billing.purchases.provider
  /** true when verify({orderId}) works (lets reconcile find payments whose buyer never came back). */
  readonly supportsOrderLookup: boolean;
  startCheckout(input: StartCheckoutInput): Promise<StartCheckoutResult>;
  verify(query: VerifyQuery): Promise<VerifyResult>;
  parseWebhook(req: Request): Promise<WebhookInfo>;
  parseReturn(url: URL): ReturnInfo;
  chargeWallet?(input: WalletChargeInput): Promise<WalletChargeResult>;
  /** Checks wallet method/account BEFORE a purchase row exists. null = ok, else an error code. */
  walletInputError?(method: string, account: string): string | null;
  refund?(input: RefundInput): Promise<RefundResult>;
}

export interface ProviderFactory {
  readonly name: string;
  /** Secrets present (no network). When false every billing function refuses for this provider. */
  configured(env: Env): boolean;
  /** Test mode (Sifalo staging): only billing testers may pay. */
  isTest?(env: Env): boolean;
  create(env: Env, fetchFn: FetchFn): PaymentProvider;
}

export type Registry = Record<string, ProviderFactory>;
