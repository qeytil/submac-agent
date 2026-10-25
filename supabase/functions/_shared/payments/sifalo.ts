// Sifalo Pay adapter (https://developer.sifalopay.com). Ported from submac.site lib/sifalo.js + lib/fulfil.js.
//   start:   POST {gateway}/ (Basic user:key) {amount, gateway:"checkout", currency, return_url, webhook_url} -> {key, token}
//   pay:     {checkout}/?key=&token=
//   verify:  POST {gateway}/verify.php {sid} | {order_id}  (NO Basic auth) -> paid only if status=success && code=601
//            staging verify by sid returns {sid, account, payment_type, amount, currency, response, status, code}: no order_id
//   wallet:  POST {gateway}/ (Basic) {account, gateway: waafi|edahab|pbwallet, amount, currency, order_id, webhook_url}
//   refund:  POST {gateway}/ (Basic) {amount, gateway, currency, payment_type:"refund", sid, order_id}
// Webhooks are UNSIGNED and fire once: the core never trusts them and always re-verifies by sid.
// Env: SIFALO_API_USER, SIFALO_API_KEY, SIFALO_ENV = staging | live (anything else = not configured).
import { ProviderRefused, ProviderUnavailable } from "./types.ts";
import type {
  Env, FailReason, FetchFn, PaymentProvider, ProviderFactory, RefundInput, RefundResult, ReturnInfo, StartCheckoutInput,
  StartCheckoutResult, VerifyQuery, VerifyResult, WalletChargeInput, WalletChargeResult, WebhookInfo,
} from "./types.ts";

export const SIFALO_HOSTS = {
  staging: { gateway: "https://spay-api.sifalo.net/gateway/", checkout: "https://pay.sifalo.net/checkout/" },
  live: { gateway: "https://api.sifalopay.com/gateway/", checkout: "https://pay.sifalo.com/checkout/" },
} as const;

// Sifalo docs (decline-and-timeout): total HTTP timeout 120 s; eDahab can take about a minute. On timeout: verify
// before charging again (we never re-charge: the purchase stays pending and reconcile verifies it).
export const SIFALO_TIMEOUT_MS = 120_000;
const SID = /^[A-Za-z0-9_\-.:]{1,128}$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const WALLET_GATEWAYS = new Set(["waafi", "edahab", "pbwallet"]);

function bad(v: string | undefined): boolean {
  return !v || !v.trim() || /^your[-_]/i.test(v) || /placeholder/i.test(v);
}

export function sifaloMode(env: Env): "staging" | "live" | null {
  const m = (env("SIFALO_ENV") ?? "").trim().toLowerCase();
  return m === "staging" || m === "live" ? m : null;
}

export function cleanSid(v: unknown): string | null {
  const s = v == null ? "" : String(v).trim();
  return SID.test(s) ? s : null;
}

function cleanUuid(v: unknown): string | null {
  const s = typeof v === "string" ? v.trim() : "";
  return UUID.test(s) ? s.toLowerCase() : null;
}

/** "1.99", "0.25", "10" (Sifalo examples use plain strings). */
export function sifaloAmount(n: number): string {
  return n.toFixed(2).replace(/\.00$/, "");
}

/**
 * Sifalo codes (https://developer.sifalopay.com/docs/decline-and-timeout.md), most calls answer HTTP 200 + `code`:
 *   601 success | 603 waiting on phone approval (poll verify, never charge again) | 604 insufficient balance |
 *   600 failed | 0 wrong username or API key | "404" missing or empty fields.
 * Verify: success/601 paid, pending/603 pending, failed/600|604 declined or insufficient.
 */
export const SIFALO_CODES: Record<string, { status: "paid" | "pending" | "failed"; reason: FailReason | null; meaning: string }> = {
  "601": { status: "paid", reason: null, meaning: "success" },
  "603": { status: "pending", reason: null, meaning: "waiting on phone approval" },
  "604": { status: "failed", reason: "insufficient_funds", meaning: "insufficient balance" },
  "600": { status: "failed", reason: "declined", meaning: "failed" },
  "0": { status: "failed", reason: "provider_config", meaning: "wrong username or API key" },
  "404": { status: "failed", reason: "provider_rejected", meaning: "missing or empty fields" },
};

function codeOf(d: Record<string, unknown>): string | null {
  const c = d.code;
  if (c == null || c === "") return null;
  const s = String(c).trim();
  return /^[0-9]{1,4}$/.test(s) ? String(Number(s)) : null;
}

/** Verify answer -> status. Throws ProviderUnavailable when the answer is not a recognisable verify reply. */
function mapVerify(d: Record<string, unknown>): { status: "paid" | "pending" | "failed"; reason: FailReason | null } {
  const s = String(d.status ?? "").toLowerCase();
  const c = codeOf(d);
  if (s === "success" && c === "601") return { status: "paid", reason: null };
  if (s === "pending" || c === "603") return { status: "pending", reason: null };
  if (s === "failed") return { status: "failed", reason: c === "604" ? "insufficient_funds" : "declined" };
  if (s === "success") return { status: "failed", reason: "declined" }; // success without 601 is never paid
  throw new ProviderUnavailable("provider_unavailable", "unrecognised verify answer");
}

async function readJson(r: Response): Promise<Record<string, unknown> | null> {
  const text = await r.text().catch(() => "");
  try {
    const j = JSON.parse(text);
    return j && typeof j === "object" && !Array.isArray(j) ? j as Record<string, unknown> : null;
  } catch {
    return null;
  }
}

export class SifaloProvider implements PaymentProvider {
  readonly name = "sifalo";
  readonly supportsOrderLookup = true;
  private hosts: { gateway: string; checkout: string };
  private auth: string;

  constructor(env: Env, private fetchFn: FetchFn, private timeoutMs = SIFALO_TIMEOUT_MS) {
    const mode = sifaloMode(env);
    if (!mode || bad(env("SIFALO_API_USER")) || bad(env("SIFALO_API_KEY"))) throw new Error("Sifalo is not configured");
    this.hosts = SIFALO_HOSTS[mode];
    this.auth = "Basic " + btoa(`${env("SIFALO_API_USER")}:${env("SIFALO_API_KEY")}`);
  }

  /** POST to the gateway with the 120 s timeout. Network error / timeout / 5xx / non-JSON -> ProviderUnavailable. */
  private async gatewayPost(body: Record<string, unknown>, withAuth: boolean, path = ""): Promise<Record<string, unknown>> {
    const headers: Record<string, string> = { "content-type": "application/json" };
    if (withAuth) headers.authorization = this.auth;
    let r: Response;
    try {
      r = await this.fetchFn(this.hosts.gateway + path, {
        method: "POST", headers, body: JSON.stringify(body), signal: AbortSignal.timeout(this.timeoutMs),
      });
    } catch (e) {
      const name = (e as Error)?.name ?? "";
      if (name === "TimeoutError" || name === "AbortError") throw new ProviderUnavailable("provider_timeout", "Sifalo timed out");
      throw new ProviderUnavailable("provider_unavailable", "Sifalo unreachable");
    }
    if (r.status >= 500) {
      await r.body?.cancel().catch(() => {});
      throw new ProviderUnavailable("provider_unavailable", `Sifalo HTTP ${r.status}`);
    }
    const d = await readJson(r);
    if (!d) throw new ProviderUnavailable("provider_unavailable", `Sifalo sent a non-JSON answer (HTTP ${r.status})`);
    return d;
  }

  async startCheckout(i: StartCheckoutInput): Promise<StartCheckoutResult> {
    const d = await this.gatewayPost({
      amount: sifaloAmount(i.amount), gateway: "checkout", currency: i.currency,
      order_id: i.purchaseId, // not in the documented checkout fields; harmless if ignored, lets verify echo it if kept
      return_url: i.returnUrl, webhook_url: i.webhookUrl,
    }, true);
    if (!d.key || !d.token) {
      const c = codeOf(d);
      if (c === "0") throw new ProviderRefused("provider_config", "Sifalo refused: wrong API user/key (code 0)");
      if (c === "404") throw new ProviderRefused("provider_rejected", "Sifalo refused: missing or empty fields (code 404)");
      throw new ProviderUnavailable("provider_unavailable", `Sifalo checkout start failed (code ${c ?? "?"})`);
    }
    return {
      redirectUrl: `${this.hosts.checkout}?key=${encodeURIComponent(String(d.key))}&token=${encodeURIComponent(String(d.token))}`,
      providerRef: String(d.key),
    };
  }

  async verify(q: VerifyQuery): Promise<VerifyResult> {
    const sid = cleanSid(q.providerRef);
    const order = cleanUuid(q.orderId);
    if (!sid && !order) throw new Error("verify needs a sid or an order id");
    const d = await this.gatewayPost(sid ? { sid } : { order_id: order }, false, "verify.php");
    const m = mapVerify(d);
    const amount = d.amount == null || d.amount === "" ? null : Number(d.amount);
    return {
      status: m.status,
      reason: m.reason,
      providerRef: cleanSid(d.sid),
      orderId: d.order_id != null && String(d.order_id).trim() !== "" ? String(d.order_id).trim() : null,
      amount: amount != null && Number.isFinite(amount) ? amount : null,
      currency: typeof d.currency === "string" && d.currency ? d.currency : null,
      paymentType: typeof d.payment_type === "string" ? d.payment_type : null,
      raw: d,
    };
  }

  async parseWebhook(req: Request): Promise<WebhookInfo> {
    const text = (await req.text().catch(() => "")).slice(0, 20000);
    let body: Record<string, unknown> = {};
    try {
      const j = JSON.parse(text);
      if (j && typeof j === "object") body = j;
    } catch {
      try { body = Object.fromEntries(new URLSearchParams(text)); } catch { body = {}; }
    }
    let orderId: string | null = null;
    for (const k of ["order_id", "orderId", "reference"]) {
      orderId = orderId ?? cleanUuid(body[k]);
    }
    const key = typeof body.key === "string" && body.key.length < 512 ? body.key : null;
    return { providerRef: cleanSid(body.sid ?? body.SID ?? body.transaction_id), orderId, checkoutRef: key, raw: body };
  }

  parseReturn(url: URL): ReturnInfo {
    return { providerRef: cleanSid(url.searchParams.get("sid")), orderId: cleanUuid(url.searchParams.get("order_id")) };
  }

  walletInputError(method: string, account: string): string | null {
    if (!WALLET_GATEWAYS.has(method)) return "unknown_wallet";
    if (!/^[0-9]{8,15}$/.test(account)) return "bad_wallet_account";
    return null;
  }

  async chargeWallet(i: WalletChargeInput): Promise<WalletChargeResult> {
    if (!WALLET_GATEWAYS.has(i.method)) throw new Error("unknown wallet method");
    if (!/^[0-9]{8,15}$/.test(i.account)) throw new Error("bad wallet account");
    const d = await this.gatewayPost({
      account: i.account, gateway: i.method, amount: sifaloAmount(i.amount), currency: i.currency,
      order_id: i.purchaseId, webhook_url: i.webhookUrl,
    }, true);
    const known = SIFALO_CODES[codeOf(d) ?? ""];
    return {
      status: known ? known.status : "unknown",
      reason: known?.reason ?? null,
      providerRef: cleanSid(d.sid),
      message: typeof d.response === "string" ? d.response.slice(0, 200) : null,
      raw: d,
    };
  }

  async refund(i: RefundInput): Promise<RefundResult> {
    // Sifalo needs the same wallet gateway as the original payment (waafi | edahab | pbwallet).
    const method = (i.method ?? "").toLowerCase();
    if (!WALLET_GATEWAYS.has(method)) throw new Error("refund needs the original wallet gateway");
    const d = await this.gatewayPost({
      amount: sifaloAmount(i.amount), gateway: method, currency: i.currency, payment_type: "refund",
      sid: i.providerRef, order_id: `${i.orderId}-R`,
    }, true);
    return { ok: codeOf(d) === "601", providerRef: cleanSid(d.sid), raw: d };
  }
}

export const sifaloFactory: ProviderFactory = {
  name: "sifalo",
  configured: (env) => sifaloMode(env) !== null && !bad(env("SIFALO_API_USER")) && !bad(env("SIFALO_API_KEY")),
  isTest: (env) => sifaloMode(env) === "staging",
  create: (env, fetchFn) => new SifaloProvider(env, fetchFn),
};
