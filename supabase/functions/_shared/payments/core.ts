// Provider-neutral billing payment core: the four billing-* edge functions are thin wrappers around these handlers.
//
// Trust model (same as telesia.site lib/fulfil.js):
// * Webhook bodies and return-URL parameters are never trusted. Every path re-verifies with the provider's own
//   source of truth (provider.verify) and only then calls billing_payment_paid, which credits once per
//   (provider, provider_ref), locks the purchase row (FOR UPDATE) and rejects amount/currency mismatches.
// * Crediting rule (owner-approved 2026-10-21): provider says paid (Sifalo status=success AND code=601), verified amount +
//   currency exactly equal the purchase's (price always from billing.plans, never from the client), and the payment
//   ref was never used by any purchase. If the provider echoes an order id it must equal the purchase id; if it echoes
//   a different ref than the one asked about, reject. (Sifalo verify.php does not echo order_id.)
// * A purchase is only marked failed when the provider definitely declined OUR attempt (our own server charge, or the
//   provider's latest attempt for our order). A forged unknown ref can never fail someone's purchase. Failed is not
//   terminal: a later verified payment still credits.
// * Unknown outcomes (timeout after 120 s, network error, 5xx, malformed JSON, unrecognised code) NEVER fail and never
//   credit: the purchase stays pending, the app gets a clear code, and reconcile / the status poll verifies later.
//
// Stress cases handled here + in migrations/20261021_billing_hardening.sql:
// * retries: client x-idempotency-key (or body.idempotency_key) -> same purchase, never a second charge; the answer is
//   rebuilt from the purchase's current state. Same key for another plan/amount -> 409.
// * double tap without a key: same product/method/wallet within billing_doubletap_seconds (20) -> same purchase.
// * concurrency: create is serialised per user by an advisory lock; credit is serialised by the purchase row lock and
//   the unique (provider, provider_ref) index.
// * per-user checkout rate limit: billing_checkout_per_minute (10) + billing_max_pending_per_hour (10).
// * pending (603): GET billing-checkout?purchase=<id> is the app's poll endpoint (state waiting_approval); it re-verifies
//   at most every 10 s.
// * abandoned: reconcile verifies pendings and marks those older than 24 h expired (failed + result 'expired').
// * logs: one JSON line per event, secrets and authorization never logged, wallet numbers masked.
//
// * order binding: a payment ref that comes from outside (return URL, webhook) must be the provider's own payment for
//   this order (verify by order id names the same ref), else it is not credited ('sid_not_for_order').
// * staging (Sifalo SIFALO_ENV=staging): only billing_testers may pay; billing_enabled itself cannot be on (DB guard).
//
// Refusal: every handler refuses (clear error, no provider call, no DB write) when the provider's secrets are missing
// or billing is off (billing_is_on). billing-return always sends the browser back to the app, never a JSON page.
import { ProviderRefused, ProviderUnavailable } from "./types.ts";
import type { Env, FetchFn, PaymentProvider, ProviderFactory, Registry } from "./types.ts";
import { Db } from "./db.ts";
import { lookupProvider, providerName, PROVIDERS } from "./registry.ts";

export interface Deps {
  env: Env;
  fetch: FetchFn;
  registry?: Registry;
  now?: () => number;
}

export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const REF = /^[A-Za-z0-9_\-.:]{1,128}$/;
const DEVICE = /^[A-Za-z0-9_-]{6,64}$/;
export const IDEM = /^[A-Za-z0-9_.:-]{8,100}$/;
const POLL_REVERIFY_MS = 10_000;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info, x-cron-secret, x-idempotency-key",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

/** Friendly, user-facing text per state / error code. The app may localise by code. */
export const USER_MESSAGES: Record<string, string> = {
  paid: "Payment received. Thank you!",
  waiting_approval: "Check your phone and approve the payment to finish.",
  processing: "We're confirming your payment. This can take a minute.",
  insufficient_funds: "Not enough balance in your wallet. Add money to your wallet and try again.",
  declined: "The payment was declined or cancelled. No money was taken.",
  expired: "This payment was not completed in time. Please start again.",
  provider_timeout: "The payment service is slow right now. If you approved the payment, it will be added automatically within a few minutes.",
  provider_unavailable: "The payment service is not responding right now. If you approved the payment, it will be added automatically within a few minutes.",
  provider_config: "Payments are temporarily unavailable. Please try again later.",
  provider_rejected: "We could not start this payment. Please try again.",
  rate_limited: "Too many payment attempts. Please wait a minute and try again.",
  idempotency_key_reused: "This payment request was already used for something else. Please start again.",
  payment_mismatch: "We could not match this payment to your order. Contact support if money was taken.",
  billing_disabled: "Billing is not enabled yet.",
  error: "Something went wrong. Please try again.",
};
const FAIL_REASONS = new Set(["insufficient_funds", "declined", "provider_config", "provider_rejected"]);

export function json(body: unknown, status = 200, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", ...CORS, ...extra } });
}

function refusal(status: number, error: string, message?: string): Response {
  return json({ ok: false, error, message: message ?? USER_MESSAGES[error] ?? USER_MESSAGES.error }, status);
}

// ---------------------------------------------------------------- structured logs (never secrets)
const SECRET_KEY = /authorization|api[_-]?key|apikey|secret|token|password|bearer|service[_-]?role|cookie/i;
const ACCOUNT_KEY = /^(account|wallet_account|msisdn|phone)$/i;

export function redact(v: unknown, depth = 0): unknown {
  if (v == null || typeof v === "number" || typeof v === "boolean") return v;
  if (typeof v === "string") return v.length > 300 ? v.slice(0, 300) + "…" : v;
  if (depth > 3) return "[…]";
  if (Array.isArray(v)) return v.slice(0, 20).map((x) => redact(x, depth + 1));
  if (typeof v === "object") {
    const out: Record<string, unknown> = {};
    for (const [k, x] of Object.entries(v as Record<string, unknown>)) {
      if (SECRET_KEY.test(k)) out[k] = "[redacted]";
      else if (ACCOUNT_KEY.test(k)) out[k] = maskAccount(x);
      else out[k] = redact(x, depth + 1);
    }
    return out;
  }
  return String(v);
}

export function maskAccount(v: unknown): string | null {
  const s = v == null ? "" : String(v).replace(/[^0-9]/g, "");
  return s ? "****" + s.slice(-4) : null;
}

export function log(level: "info" | "warn" | "error", event: string, fields: Record<string, unknown> = {}): void {
  const line = JSON.stringify({ ts: new Date().toISOString(), level, svc: "billing", event, ...(redact(fields) as object) });
  if (level === "error") console.error(line);
  else if (level === "warn") console.warn(line);
  else console.log(line);
}

function sameText(a: string, b: string): boolean {
  if (!a || !b || a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

function cleanRef(v: unknown): string | null {
  const s = v == null ? "" : String(v).trim();
  return REF.test(s) ? s : null;
}

function cleanUuid(v: unknown): string | null {
  const s = typeof v === "string" ? v.trim() : "";
  return UUID.test(s) ? s.toLowerCase() : null;
}

async function sha16(s: string): Promise<string> {
  const d = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)));
  return [...d.slice(0, 8)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

type Gate =
  | { ok: true; factory: ProviderFactory; provider: PaymentProvider; db: Db }
  | { ok: false; res: Response };

/** Step 1 of every handler: provider known + secrets present + DB configured. No network. */
function gateConfig(deps: Deps, name: string, webhookStyle = false): Gate {
  const reg = deps.registry ?? PROVIDERS;
  const out = (status: number, error: string, message: string): Gate =>
    ({ ok: false, res: webhookStyle ? json({ ok: false, error, message }, 200) : refusal(status, error, message) });
  const factory = lookupProvider(reg, name);
  if (!factory) return out(400, "unknown_provider", `Unknown payment provider '${name}'.`);
  if (!factory.configured(deps.env)) return out(503, "payments_not_configured", `Payments are not configured (${name} secrets missing).`);
  const db = Db.fromEnv(deps.env, deps.fetch);
  if (!db) return out(503, "payments_not_configured", "Server database settings missing.");
  return { ok: true, factory, provider: factory.create(deps.env, deps.fetch), db };
}

interface Purchase {
  id: string; user_id: string; product_id: string; kind: string; amount_usd: number | string; currency: string;
  status: string; provider: string; provider_ref: string | null; pending_ref?: string | null; checkout_key: string | null;
  result?: string | null; plan_id?: string | null; tokens?: number | null; tokens_added?: number; created_at?: string; paid_at?: string | null; last_checked_at?: string | null;
}

export type CreditOutcome =
  | "paid" | "already_paid" | "pending" | "failed" | "bad_request" | "no_purchase" | "provider_mismatch"
  | "purchase_paid_other_sid" | "order_mismatch" | "sid_not_for_order" | "sid_reused" | "amount_mismatch"
  | "currency_mismatch" | "no_sid" | "ref_mismatch" | "provider_unavailable" | "error";

/** What the app sees for one purchase. */
export function stateOf(p: Pick<Purchase, "status" | "result">): { status: string; state: string; reason: string | null; message: string } {
  const r = p.result ?? null;
  if (p.status === "paid") return { status: "paid", state: "paid", reason: null, message: USER_MESSAGES.paid };
  if (p.status === "reversed") return { status: "reversed", state: "reversed", reason: null, message: "This payment was refunded or reversed." };
  if (p.status === "failed") {
    if (r === "expired") return { status: "expired", state: "expired", reason: "expired", message: USER_MESSAGES.expired };
    const reason = r && FAIL_REASONS.has(r) ? r : "declined";
    return { status: "failed", state: "failed", reason, message: USER_MESSAGES[reason] };
  }
  if (r === "pending") return { status: "pending", state: "waiting_approval", reason: null, message: USER_MESSAGES.waiting_approval };
  if (r === "provider_timeout" || r === "provider_unavailable") {
    return { status: "pending", state: "processing", reason: r, message: USER_MESSAGES[r] };
  }
  return { status: "pending", state: "processing", reason: null, message: USER_MESSAGES.processing };
}

async function verifySafe(provider: PaymentProvider, q: { providerRef?: string | null; orderId?: string | null }) {
  try {
    return { ok: true as const, v: await provider.verify(q) };
  } catch (e) {
    if (e instanceof ProviderUnavailable) return { ok: false as const, kind: e.kind };
    throw e;
  }
}

/**
 * Verify one purchase with its provider and credit it through the DB RPC only.
 * ref: a payment ref from outside (return URL / webhook) or from our own server call (trusted=true), or null to use
 * the ref of our own server charge (pending_ref) or look the payment up by our order id.
 */
export async function verifyAndCredit(db: Db, provider: PaymentProvider, purchaseId: string, ref: string | null,
  opts: { trusted?: boolean } = {}): Promise<{ outcome: CreditOutcome; detail?: string }> {
  const pid = cleanUuid(purchaseId);
  if (!pid) return { outcome: "bad_request" };
  if (ref != null && ref !== "" && !cleanRef(ref)) return { outcome: "bad_request" };
  ref = cleanRef(ref);
  let trusted = !!opts.trusted;

  const p = await db.rpc<Purchase | null>("billing_payment_find", { p_payment: pid });
  if (!p) return { outcome: "no_purchase" };
  if (p.provider !== provider.name) return { outcome: "provider_mismatch" };
  if (p.status === "paid" || p.status === "reversed") {
    return { outcome: ref && p.provider_ref !== ref ? "purchase_paid_other_sid" : "already_paid" };
  }
  const unavailable = async (kind: string) => {
    await db.rpc("billing_payment_touch", { p_payment: pid, p_result: kind });
    log("warn", "verify.provider_unavailable", { purchase: pid, provider: provider.name, kind });
    return { outcome: "provider_unavailable" as CreditOutcome, detail: kind };
  };

  if (!ref && p.pending_ref) {
    ref = cleanRef(p.pending_ref);
    trusted = true; // stored only from our own server-side charge
  }
  if (!ref) {
    if (!provider.supportsOrderLookup) {
      await db.rpc("billing_payment_touch", { p_payment: pid, p_result: "pending" });
      return { outcome: "pending", detail: "no_ref" };
    }
    const byOrder = await verifySafe(provider, { orderId: pid });
    if (!byOrder.ok) return await unavailable(byOrder.kind);
    ref = byOrder.v.providerRef;
    if (!ref) {
      await db.rpc("billing_payment_touch", { p_payment: pid, p_result: p.result === "pending" ? "pending" : "no_payment_yet" });
      return { outcome: "pending", detail: "no_payment_yet" };
    }
    trusted = true; // the provider's own latest attempt for our order id
  }
  const callerRef = !trusted;

  const vr = await verifySafe(provider, { providerRef: ref });
  if (!vr.ok) return await unavailable(vr.kind);
  const v = vr.v;
  log("info", "verify.result", { purchase: pid, provider: provider.name, ref, status: v.status, reason: v.reason ?? null, amount: v.amount, currency: v.currency });
  if (v.status !== "paid") {
    if (v.status === "pending") {
      await db.rpc("billing_payment_touch", { p_payment: pid, p_result: "pending" });
      return { outcome: "pending" };
    }
    let latestIsThis = !callerRef;
    if (callerRef && provider.supportsOrderLookup) {
      const latest = await verifySafe(provider, { orderId: pid }).catch(() => null);
      latestIsThis = !!latest?.ok && latest.v.providerRef === ref && latest.v.status !== "paid";
    }
    const reason = v.reason ?? "declined";
    if (latestIsThis) await db.rpc("billing_payment_failed", { p_payment: pid, p_reason: reason, p_payload: v.raw ?? {} });
    else await db.rpc("billing_payment_touch", { p_payment: pid, p_result: "verify_failed" });
    return { outcome: "failed", detail: reason };
  }

  if (v.orderId && v.orderId.toLowerCase() !== pid) {
    await db.rpc("billing_payment_touch", { p_payment: pid, p_result: "order_mismatch" });
    return { outcome: "order_mismatch" };
  }
  // Order binding: a ref from outside must be the provider's payment for THIS order.
  if (callerRef && !v.orderId) {
    const own = provider.supportsOrderLookup ? await verifySafe(provider, { orderId: pid }) : null;
    if (own && !own.ok) return await unavailable(own.kind);
    if (!own || own.v.providerRef !== ref) {
      await db.rpc("billing_payment_touch", { p_payment: pid, p_result: "sid_not_for_order" });
      log("warn", "verify.sid_not_for_order", { purchase: pid, provider: provider.name, ref });
      return { outcome: "sid_not_for_order" };
    }
  }
  if (v.providerRef && v.providerRef !== ref) {
    await db.rpc("billing_payment_touch", { p_payment: pid, p_result: "ref_mismatch" });
    return { outcome: "ref_mismatch" };
  }

  const result = await db.rpc<string>("billing_payment_paid", {
    p_payment: pid, p_provider: provider.name, p_ref: ref, p_amount: v.amount, p_currency: v.currency,
    p_payment_type: v.paymentType, p_payload: v.raw ?? {},
  });
  log(result === "paid" || result === "already_paid" ? "info" : "warn", "credit.result", { purchase: pid, provider: provider.name, ref, result });
  return { outcome: (result as CreditOutcome) ?? "error" };
}

/** What the app is told. Unknown provider state is "pending" (never failed, never paid). */
export function publicStatus(o: CreditOutcome): "paid" | "pending" | "failed" | "error" {
  if (o === "paid" || o === "already_paid") return "paid";
  if (o === "pending" || o === "provider_unavailable") return "pending";
  if (o === "failed") return "failed";
  return "error";
}

// ============================================================================ billing-checkout
// POST (user JWT) { plan: "weekly" | "monthly" | "payg", tokens?: number (payg only), device_id?, method?: "checkout" | "wallet", account?, wallet? }
//   header x-idempotency-key (or body.idempotency_key): same key -> same purchase, never charged twice.
//   ?provider=<name> optional. -> { ok, purchase_id, provider, status, state, url? , error?, message }
//   Any client "amount"/"price" field is ignored: the price always comes from billing.plans.
// GET (user JWT) ?purchase=<id> -> poll endpoint { ok, purchase_id, status, state, reason, message, poll_after_seconds }
export async function handleCheckout(req: Request, deps: Deps): Promise<Response> {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method === "GET") return await handleStatus(req, deps);
  if (req.method !== "POST") return refusal(405, "method_not_allowed", "Use POST.");
  const url = new URL(req.url);
  const g = gateConfig(deps, providerName(url, deps.env));
  if (!g.ok) return g.res;
  const { provider, db } = g;

  const token = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  const user = await db.getUser(token);
  if (!user) return refusal(401, "auth_required", "Please sign in.");
  const st = await db.billingStatus(user.id);
  if (!st.on) return refusal(503, "billing_disabled");
  if (g.factory.isTest?.(deps.env) && !st.tester) {
    log("warn", "checkout.staging_not_tester", { user: user.id, provider: provider.name });
    return refusal(503, "billing_disabled");
  }

  const body = await req.json().catch(() => ({})) as Record<string, unknown>;
  const idemIn = req.headers.get("x-idempotency-key") ?? (typeof body.idempotency_key === "string" ? body.idempotency_key : null);
  if (idemIn != null && !IDEM.test(idemIn)) return refusal(400, "bad_idempotency_key", "x-idempotency-key must be 8-100 chars [A-Za-z0-9_.:-].");
  // What to buy: a package (plan "weekly" | "monthly" ...) or pay as you go (plan "payg" + tokens). The price always
  // comes from billing.plans; any amount/price the client sends is ignored.
  const plan = typeof body.plan === "string" ? body.plan : null;
  if (!plan || !/^[a-z][a-z0-9_]{1,31}$/.test(plan)) return refusal(400, "bad_product", "Unknown plan.");
  const tokensIn = body.tokens == null ? null : Number(body.tokens);
  if (tokensIn != null && (!Number.isSafeInteger(tokensIn) || tokensIn <= 0)) return refusal(400, "bad_product", "Unknown amount.");
  const product = tokensIn == null ? plan : `${plan}:${tokensIn}`;
  const method = body.method === "wallet" ? "wallet" : "checkout";
  if (method === "wallet" && !provider.chargeWallet) return refusal(400, "wallet_unsupported", "This provider has no direct wallet charge.");
  const account = String(body.account ?? "").replace(/[^0-9]/g, "");
  const wallet = String(body.wallet ?? "").toLowerCase();
  if (method === "wallet") {
    const bad = provider.walletInputError?.(wallet, account) ?? null;
    if (bad) return refusal(400, bad, bad === "unknown_wallet" ? "Choose eDahab, Waafi or Premier Wallet." : "Enter a valid wallet number.");
  }
  const device = typeof body.device_id === "string" && DEVICE.test(body.device_id) ? body.device_id : null;
  const fingerprint = method === "wallet" ? `wallet|${product}|${wallet}|${await sha16(account)}` : `checkout|${product}`;

  const created = await db.rpc<Record<string, unknown>>("billing_payment_create", {
    p_uid: user.id, p_plan: plan, p_tokens: tokensIn, p_device: device, p_provider: provider.name, p_idem: idemIn, p_fingerprint: fingerprint,
  });
  if (!created?.ok) {
    const reason = String(created?.reason ?? "error");
    const status = reason === "billing_disabled" ? 503 : reason === "rate_limited" ? 429 : reason === "idempotency_key_reused" ? 409 : 400;
    log("warn", "checkout.refused", { user: user.id, product, method, reason });
    return refusal(status, reason, USER_MESSAGES[reason] ?? "Could not start this purchase.");
  }
  const pid = String(created.purchase_id);
  const amount = Number(created.amount_usd);
  const currency = String(created.currency ?? "USD");
  const replay = created.replay === true;
  const base = db.functionsBase(deps.env);
  const p = encodeURIComponent(provider.name);
  const returnUrl = `${base}/billing-return?provider=${p}&purchase=${pid}&order_id=${pid}`;
  const webhookUrl = `${base}/billing-webhook?provider=${p}&purchase=${pid}`;
  const common = { purchase_id: pid, provider: provider.name, plan_id: created.plan_id ?? created.product_id, product_id: created.product_id,
    tokens: created.tokens, amount_usd: amount, currency };
  log("info", replay ? "checkout.replay" : "checkout.created", { user: user.id, purchase: pid, product, method, account: method === "wallet" ? account : undefined, idem: !!idemIn });

  // Saved answer + current state. Saved only for final outcomes; a replay is always rebuilt from the purchase row.
  const finish = async (http: number, out: Record<string, unknown>, save = true): Promise<Response> => {
    if (save) await db.rpc("billing_payment_save_response", { p_payment: pid, p_response: { http, body: out } }).catch(() => {});
    return json(out, http, replay ? { "x-idempotent-replay": "true" } : {});
  };

  if (replay) {
    const cur = await db.rpc<Purchase | null>("billing_payment_find", { p_payment: pid, p_uid: user.id });
    const saved = (created.response as { http?: number; body?: Record<string, unknown> } | null)?.body ?? null;
    const st = stateOf(cur ?? { status: String(created.status ?? "pending"), result: (created.result as string) ?? null });
    const restartHosted = method === "checkout" && st.status === "pending" && !cur?.checkout_key && !saved?.url;
    if (!restartHosted) {
      const out = { ...(saved ?? {}), ok: st.state !== "failed" && st.state !== "expired", ...common, ...st, replay: true,
        in_progress: !saved && st.status === "pending" };
      return json(out, st.status === "pending" ? 202 : st.status === "failed" || st.status === "expired" ? 402 : 200, { "x-idempotent-replay": "true" });
    }
    // a hosted checkout whose page never opened (provider was down): open it now for the SAME purchase (no charge risk)
  }

  if (method === "wallet") {
    let charge;
    try {
      charge = await provider.chargeWallet!({ purchaseId: pid, amount, currency, account, method: wallet, webhookUrl });
    } catch (e) {
      const kind = e instanceof ProviderUnavailable ? e.kind : "provider_unavailable";
      if (!(e instanceof ProviderUnavailable)) log("error", "wallet.charge_error", { purchase: pid, error: String((e as Error)?.message ?? e) });
      await db.rpc("billing_payment_touch", { p_payment: pid, p_result: kind }).catch(() => {});
      log("warn", "wallet.charge_unknown", { purchase: pid, kind });
      // Outcome unknown: the customer may still approve. Stay pending; poll / reconcile verifies. Never charge again.
      return await finish(202, { ok: true, ...common, status: "pending", state: "processing", error: kind, reason: kind, message: USER_MESSAGES[kind], poll_after_seconds: 5 });
    }
    log("info", "wallet.charge", { purchase: pid, status: charge.status, reason: charge.reason ?? null, ref: charge.providerRef, code: (charge.raw as Record<string, unknown> | null)?.code ?? null });
    if (charge.providerRef) await db.rpc("billing_payment_note_ref", { p_payment: pid, p_ref: charge.providerRef });
    if (charge.status === "failed") {
      const reason = charge.reason ?? "declined";
      await db.rpc("billing_payment_failed", { p_payment: pid, p_reason: reason, p_payload: charge.raw ?? {} });
      if (reason === "provider_config") log("error", "provider.config_error", { provider: provider.name, purchase: pid });
      const http = reason === "provider_config" ? 503 : reason === "provider_rejected" ? 502 : 402;
      return await finish(http, { ok: false, ...common, status: "failed", state: "failed", error: reason, reason, message: USER_MESSAGES[reason] });
    }
    if (charge.status === "unknown") {
      await db.rpc("billing_payment_touch", { p_payment: pid, p_result: "provider_unavailable" });
      return await finish(202, { ok: true, ...common, status: "pending", state: "processing", error: "provider_unavailable", reason: "provider_unavailable", message: USER_MESSAGES.provider_unavailable, poll_after_seconds: 5 });
    }
    if (!charge.providerRef) {
      await db.rpc("billing_payment_touch", { p_payment: pid, p_result: charge.status === "pending" ? "pending" : "provider_unavailable" });
      const st = stateOf({ status: "pending", result: charge.status === "pending" ? "pending" : null });
      return await finish(202, { ok: true, ...common, ...st, poll_after_seconds: 5 });
    }
    const r = await verifyAndCredit(db, provider, pid, charge.providerRef, { trusted: true });
    return await walletAnswer(r, pid, common, finish);
  }

  try {
    const s = await provider.startCheckout({ purchaseId: pid, amount, currency, returnUrl, webhookUrl });
    await db.rpc("billing_payment_set_checkout_key", { p_payment: pid, p_key: s.providerRef });
    return await finish(200, { ok: true, ...common, url: s.redirectUrl, status: "pending", state: "checkout_opened", message: "Complete the payment on the Sifalo page." });
  } catch (e) {
    if (e instanceof ProviderRefused) {
      await db.rpc("billing_payment_failed", { p_payment: pid, p_reason: e.reason, p_payload: { error: e.reason } });
      log("error", "checkout.provider_refused", { purchase: pid, reason: e.reason });
      return await finish(e.reason === "provider_config" ? 503 : 502, { ok: false, ...common, status: "failed", state: "failed", error: e.reason, reason: e.reason, message: USER_MESSAGES[e.reason] });
    }
    const kind = e instanceof ProviderUnavailable ? e.kind : "provider_unavailable";
    log("warn", "checkout.start_unavailable", { purchase: pid, kind, error: String((e as Error)?.message ?? e) });
    await db.rpc("billing_payment_touch", { p_payment: pid, p_result: kind }).catch(() => {});
    // Not saved: a retry with the same key re-opens the page for this same purchase. No page = no money taken.
    return await finish(502, { ok: false, ...common, status: "pending", state: "processing", error: kind, reason: kind, message: "We could not open the payment page. Please try again in a minute." }, false);
  }
}

async function walletAnswer(r: { outcome: CreditOutcome; detail?: string }, pid: string, common: Record<string, unknown>,
  finish: (http: number, out: Record<string, unknown>, save?: boolean) => Promise<Response>): Promise<Response> {
  const o = r.outcome;
  if (o === "paid" || o === "already_paid") return await finish(200, { ok: true, ...common, status: "paid", state: "paid", result: o, message: USER_MESSAGES.paid });
  if (o === "pending") return await finish(202, { ok: true, ...common, status: "pending", state: "waiting_approval", message: USER_MESSAGES.waiting_approval, poll_after_seconds: 5 });
  if (o === "provider_unavailable") {
    const kind = r.detail ?? "provider_unavailable";
    return await finish(202, { ok: true, ...common, status: "pending", state: "processing", error: kind, reason: kind, message: USER_MESSAGES[kind] ?? USER_MESSAGES.processing, poll_after_seconds: 5 });
  }
  if (o === "failed") {
    const reason = r.detail ?? "declined";
    return await finish(402, { ok: false, ...common, status: "failed", state: "failed", error: reason, reason, message: USER_MESSAGES[reason] ?? USER_MESSAGES.declined });
  }
  log("warn", "wallet.unexpected_outcome", { purchase: pid, outcome: o });
  return await finish(409, { ok: false, ...common, status: "error", state: "error", error: "payment_mismatch", result: o, message: USER_MESSAGES.payment_mismatch });
}

// GET billing-checkout?purchase=<id> (user JWT): the app polls this while it shows "approve on your phone".
async function handleStatus(req: Request, deps: Deps): Promise<Response> {
  const url = new URL(req.url);
  const pid = cleanUuid(url.searchParams.get("purchase"));
  const g = gateConfig(deps, providerName(url, deps.env));
  if (!g.ok) return g.res;
  const { db } = g;
  const token = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  const user = await db.getUser(token);
  if (!user) return refusal(401, "auth_required", "Please sign in.");
  if (!(await db.billingStatus(user.id)).on) return refusal(503, "billing_disabled");
  if (!pid) return refusal(400, "bad_request", "purchase is required.");
  let p = await db.rpc<Purchase | null>("billing_payment_find", { p_payment: pid, p_uid: user.id });
  if (!p) return refusal(404, "not_found", "Purchase not found.");
  const now = (deps.now ?? Date.now)();
  const last = Date.parse(p.last_checked_at ?? p.created_at ?? "") || 0;
  if (p.status === "pending" && now - last >= POLL_REVERIFY_MS) {
    const f = lookupProvider(deps.registry ?? PROVIDERS, p.provider);
    if (f && f.configured(deps.env)) {
      const prov = f.create(deps.env, deps.fetch);
      if (p.pending_ref || prov.supportsOrderLookup) {
        await verifyAndCredit(db, prov, pid, null).catch((e) => log("error", "status.verify_error", { purchase: pid, error: String((e as Error)?.message ?? e) }));
        p = (await db.rpc<Purchase | null>("billing_payment_find", { p_payment: pid, p_uid: user.id })) ?? p;
      }
    }
  }
  const st = stateOf(p);
  return json({ ok: true, purchase_id: pid, plan_id: p.plan_id ?? p.product_id, product_id: p.product_id, provider: p.provider,
    tokens: p.tokens ?? null, tokens_added: p.tokens_added ?? 0,
    ...st, poll_after_seconds: st.status === "pending" ? 5 : null });
}

// ============================================================================ billing-webhook
// POST from the provider. Body is UNTRUSTED. Always HTTP 200.
export async function handleWebhook(req: Request, deps: Deps): Promise<Response> {
  try {
    if (req.method !== "POST") return json({ ok: false, error: "method_not_allowed" }, 200);
    const url = new URL(req.url);
    const g = gateConfig(deps, providerName(url, deps.env), true);
    if (!g.ok) return g.res;
    const { provider, db } = g;
    if (!(await db.billingStatus()).on) return json({ ok: false, error: "billing_disabled", message: USER_MESSAGES.billing_disabled }, 200);

    const info = await provider.parseWebhook(req);
    const fromQuery = cleanUuid(url.searchParams.get("purchase"));
    const fromBody = cleanUuid(info.orderId);
    log("info", "webhook.received", { provider: provider.name, purchase: fromQuery ?? fromBody, ref: info.providerRef });
    if (fromQuery && fromBody && fromQuery !== fromBody) return json({ ok: true, outcome: "order_conflict" }, 200);
    let pid = fromQuery ?? fromBody;
    if (!pid && info.checkoutRef) {
      const p = await db.rpc<Purchase | null>("billing_payment_find_by_key", { p_key: info.checkoutRef, p_provider: provider.name });
      pid = p?.id ?? null;
    }
    if (!pid && info.providerRef) {
      const v = await provider.verify({ providerRef: info.providerRef }).catch(() => null);
      pid = cleanUuid(v?.orderId);
    }
    if (!pid) return json({ ok: true, outcome: "unmatched" }, 200);
    const r = await verifyAndCredit(db, provider, pid, info.providerRef);
    return json({ ok: true, outcome: r.outcome }, 200);
  } catch (e) {
    log("error", "webhook.error", { error: String((e as Error)?.message ?? e) });
    return json({ ok: false, error: "internal" }, 200);
  }
}

// ============================================================================ billing-return
// GET from the customer's browser: ?provider=&purchase=&order_id=&sid=... -> ALWAYS 303 back to the app
// (BILLING_APP_RETURN_URL, default telesia://pay) ?status=paid|pending|failed|error&purchase=..[&reason=..]. Never a JSON page:
// a config problem, billing off or a crash still goes back to the app (status=error, the app checks the payment itself).
export async function handleReturn(req: Request, deps: Deps): Promise<Response> {
  const url = new URL(req.url);
  let pid = cleanUuid(url.searchParams.get("purchase")) ?? cleanUuid(url.searchParams.get("order_id"));
  let status = "error";
  let reason: string | null = null;
  try {
    const g = gateConfig(deps, providerName(url, deps.env));
    if (!g.ok) {
      reason = "unavailable";
    } else if (!(await g.db.billingStatus()).on) {
      reason = "billing_disabled";
    } else {
      const info = g.provider.parseReturn(url);
      pid = pid ?? cleanUuid(info.orderId);
      if (pid) {
        const r = await verifyAndCredit(g.db, g.provider, pid, info.providerRef);
        status = publicStatus(r.outcome);
        if (r.outcome === "failed" || r.outcome === "provider_unavailable") reason = r.detail ?? null;
        else if (status === "error") reason = r.outcome;
      }
    }
  } catch (e) {
    log("error", "return.error", { purchase: pid, error: String((e as Error)?.message ?? e) });
    status = "pending"; // we could not tell: the app keeps checking, reconcile settles it
    reason = "processing";
  }
  const app = (deps.env("BILLING_APP_RETURN_URL") ?? "telesia://pay").replace(/\?$/, "");
  const dest = `${app}?status=${status}&purchase=${encodeURIComponent(pid ?? "")}${reason ? `&reason=${encodeURIComponent(reason)}` : ""}`;
  return new Response(null, { status: 303, headers: { location: dest, "cache-control": "no-store" } });
}

// ============================================================================ billing-reconcile
// Cron-safe: re-verify pending purchases older than N minutes, and mark abandoned ones (older than expire_after_hours,
// default 24, env BILLING_PENDING_EXPIRE_HOURS) expired after one last verify. Header x-cron-secret = AI_CRON_SECRET or
// BILLING_CRON_SECRET (optional dedicated secret, >= 16 chars).
// Query/body: older_than_minutes (default 10), since_hours (72), limit (10, max 50), expire_after_hours (24).
export async function handleReconcile(req: Request, deps: Deps): Promise<Response> {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const reg = deps.registry ?? PROVIDERS;
  const configured = Object.values(reg).filter((f) => f.configured(deps.env));
  if (!configured.length) return refusal(503, "payments_not_configured", "No payment provider is configured.");
  const db = Db.fromEnv(deps.env, deps.fetch);
  if (!db) return refusal(503, "payments_not_configured", "Server database settings missing.");
  // AI_CRON_SECRET (shared with ai-admin) or a dedicated BILLING_CRON_SECRET (optional) both open reconcile.
  const secrets = [deps.env("AI_CRON_SECRET") ?? "", deps.env("BILLING_CRON_SECRET") ?? ""].filter((x) => x.length >= 16 || x === deps.env("AI_CRON_SECRET"));
  const usable = secrets.filter((x) => !!x);
  if (!usable.length) return refusal(503, "cron_not_configured", "AI_CRON_SECRET is not set.");
  const given = req.headers.get("x-cron-secret") ?? "";
  if (!usable.some((x) => sameText(given, x))) {
    log("warn", "reconcile.bad_secret", {});
    return refusal(401, "unauthorized", "Bad cron secret.");
  }
  if (!(await db.billingStatus()).on) return refusal(503, "billing_disabled");

  const url = new URL(req.url);
  const body = req.method === "POST" ? await req.json().catch(() => ({})) as Record<string, unknown> : {};
  const num = (k: string, d: number) => {
    const v = Number(url.searchParams.get(k) ?? body[k] ?? d);
    return Number.isFinite(v) ? v : d;
  };
  const older = Math.max(1, Math.min(1440, num("older_than_minutes", 10)));
  const since = Math.max(1, Math.min(720, num("since_hours", 72)));
  const limit = Math.max(1, Math.min(50, num("limit", 10)));
  const expireH = Math.max(1, Math.min(24, num("expire_after_hours", Number(deps.env("BILLING_PENDING_EXPIRE_HOURS") ?? 24) || 24)));

  const started = Date.now();
  const results: Array<{ id: string; provider: string; outcome: string }> = [];
  const providers = new Map<string, PaymentProvider>();
  const providerFor = (name: string): PaymentProvider | null => {
    const f = lookupProvider(reg, name);
    if (!f || !f.configured(deps.env)) return null;
    if (!providers.has(f.name)) providers.set(f.name, f.create(deps.env, deps.fetch));
    return providers.get(f.name)!;
  };
  const seen = new Set<string>();

  // 1) abandoned: one last verify, then expire (a payment found now still credits; provider down -> keep pending)
  const stale = await db.rpc<Array<{ id: string; provider: string }>>("billing_payment_pending", {
    p_older_than_minutes: expireH * 60, p_since_hours: 720, p_limit: limit, p_provider: null,
  });
  for (const p of stale ?? []) {
    seen.add(p.id);
    if (Date.now() - started > 100_000) { results.push({ id: p.id, provider: p.provider, outcome: "deferred" }); continue; }
    const prov = providerFor(p.provider);
    let outcome: string = "provider_not_configured";
    if (prov) {
      try {
        const r = await verifyAndCredit(db, prov, p.id, null);
        outcome = r.outcome;
        if (["pending", "failed"].includes(r.outcome)) {
          const done = await db.rpc<boolean>("billing_payment_expire", { p_payment: p.id, p_min_age_hours: expireH });
          if (done) outcome = "expired";
        }
      } catch (e) {
        log("error", "reconcile.error", { purchase: p.id, error: String((e as Error)?.message ?? e) });
        outcome = "error";
      }
    }
    results.push({ id: p.id, provider: p.provider, outcome });
  }

  // 2) recent pendings
  const pending = await db.rpc<Array<{ id: string; provider: string }>>("billing_payment_pending", {
    p_older_than_minutes: older, p_since_hours: since, p_limit: limit, p_provider: null,
  });
  for (const p of pending ?? []) {
    if (seen.has(p.id)) continue;
    if (Date.now() - started > 100_000) { results.push({ id: p.id, provider: p.provider, outcome: "deferred" }); continue; }
    const prov = providerFor(p.provider);
    if (!prov) { results.push({ id: p.id, provider: p.provider, outcome: "provider_not_configured" }); continue; }
    try {
      const r = await verifyAndCredit(db, prov, p.id, null);
      results.push({ id: p.id, provider: p.provider, outcome: r.outcome });
    } catch (e) {
      log("error", "reconcile.error", { purchase: p.id, error: String((e as Error)?.message ?? e) });
      results.push({ id: p.id, provider: p.provider, outcome: "error" });
    }
  }
  const count = (s: string) => results.filter((r) => r.outcome !== "expired" && publicStatus(r.outcome as CreditOutcome) === s).length;
  const summary = { ok: true, checked: results.length, paid: count("paid"), pending: count("pending"), failed: count("failed"),
    expired: results.filter((r) => r.outcome === "expired").length, results };
  log("info", "reconcile.summary", { checked: summary.checked, paid: summary.paid, pending: summary.pending, failed: summary.failed, expired: summary.expired });
  return json(summary);
}
