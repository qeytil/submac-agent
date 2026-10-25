// deno test supabase/functions/_shared/payments/payments_test.ts
// Every network call (Supabase REST/Auth and Sifalo) goes through a mocked fetch backed by an in-memory world that
// mimics the billing RPC semantics (billing_payment_paid: once per (provider, ref), amount/currency binding).
import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import { handleCheckout, handleReconcile, handleReturn, handleWebhook, type Deps } from "./core.ts";
import { PROVIDERS } from "./registry.ts";
import { SIFALO_CODES, SIFALO_TIMEOUT_MS, SifaloProvider, sifaloFactory } from "./sifalo.ts";
import { ProviderUnavailable } from "./types.ts";
import type {
  Env, PaymentProvider, ProviderFactory, Registry, StartCheckoutInput, VerifyQuery, VerifyResult,
} from "./types.ts";

// Capture structured logs (also keeps test output clean).
const LOGS: string[] = [];
for (const k of ["log", "warn", "error"] as const) console[k] = (...a: unknown[]) => { LOGS.push(a.map(String).join(" ")); };

const SB = "https://proj.supabase.co";
const SVC = "service-role-key-xxxxxxxxxxxxxxxx";
const USER_TOKEN = "user-access-token-aaaaaaaaaaaaaaaa";
const UID = "11111111-1111-4111-8111-111111111111";
const CRON = "cron-secret-123";
const STG = "https://spay-api.sifalo.net/gateway/";
const LIVE = "https://api.sifalopay.com/gateway/";

// Mock catalogue (mirrors billing.plans + billing.quote): packages at a fixed price, PAYG $2.00 per 1M in 100k steps.
const PACKAGES: Record<string, { usd: number; tokens: number }> = { weekly: { usd: 1.25, tokens: 700_000 }, monthly: { usd: 4.99, tokens: 3_000_000 } };
function quote(plan: string, tokens: unknown): { usd: number; tokens: number } | null {
  if (PACKAGES[plan]) return PACKAGES[plan];
  const n = Number(tokens);
  if (plan !== "payg" || !Number.isSafeInteger(n) || n < 100_000 || n % 100_000 !== 0) return null;
  return { usd: Math.round((n / 1_000_000) * 2 * 100) / 100, tokens: n };
}
const PAYG_1 = { plan: "payg", tokens: 500_000 }; // $1.00
const PAYG_5 = { plan: "payg", tokens: 2_500_000 }; // $5.00
const WRITE_RPCS = new Set(["billing_payment_create", "billing_payment_set_checkout_key", "billing_payment_paid",
  "billing_payment_failed", "billing_payment_touch", "billing_payment_note_ref", "billing_payment_save_response", "billing_payment_expire"]);

interface P {
  id: string; user_id: string; plan_id: string; tokens: number; amount_usd: number; currency: string; status: string;
  provider: string; provider_ref: string | null; checkout_key: string | null; created_at: number;
  pending_ref: string | null; idempotency_key: string | null; fingerprint: string | null; client_response: unknown;
  result: string | null; last_checked_at: number | null; tokens_added: number;
}
interface Pay { sid: string; order_id: string | null; status: string; code: number; amount: string; currency: string; payment_type: string }

class World {
  enabled = true;
  tester = true; // staging: the signed-in user is in billing_testers
  purchases = new Map<string, P>();
  tokens = new Map<string, number>();
  credits = 0;
  calls: Array<{ url: string; body: unknown }> = [];
  pays = new Map<string, Pay>(); // by sid
  latestByOrder = new Map<string, string>();
  perMinute = 10;
  faults: Array<{ on: "verify" | "charge" | "checkout"; kind: "network" | "5xx" | "malformed" | "timeout" | "timeout_after" }> = [];
  delayMs = 0;
  signals: Array<AbortSignal | null | undefined> = [];
  echoOrder = false; // true: verify by sid echoes order_id (Sifalo staging does NOT)
  verifyReplies: Array<Record<string, unknown>> = [];
  n = 0;

  get writes() {
    return this.calls.filter((c) => WRITE_RPCS.has(c.url.replace(`${SB}/rest/v1/rpc/`, "")));
  }
  get sifaloCalls() {
    return this.calls.filter((c) => c.url.startsWith(STG) || c.url.startsWith(LIVE));
  }

  /** Customer pays on the provider page (or an attempt is recorded). */
  pay(orderId: string | null, amount: string, status = "success", code = 601, currency = "USD"): string {
    const sid = `SID${++this.n}`;
    this.pays.set(sid, { sid, order_id: orderId, status, code, amount, currency, payment_type: "EDAHAB" });
    if (orderId) this.latestByOrder.set(orderId, sid);
    return sid;
  }

  rpc(fn: string, a: Record<string, unknown>): unknown {
    const pid = a.p_payment as string;
    switch (fn) {
      case "billing_is_on":
        return { on: this.enabled, tester: this.tester, enabled: this.enabled, testers: this.tester };
      case "billing_payment_create": {
        if (!this.enabled) return { ok: false, reason: "billing_disabled" };
        const idem = a.p_idem as string | null, fp = a.p_fingerprint as string | null;
        const mine = [...this.purchases.values()].filter((x) => x.user_id === a.p_uid);
        const replay = (x: P) => ({ ok: true, replay: true, purchase_id: x.id, amount_usd: x.amount_usd, currency: x.currency, plan_id: x.plan_id,
          product_id: x.plan_id, tokens: x.tokens, provider: x.provider, status: x.status, result: x.result, checkout_key: x.checkout_key,
          response: x.client_response ?? null });
        if (idem) {
          const x = mine.find((y) => y.idempotency_key === idem);
          if (x) {
            return x.plan_id !== a.p_plan || x.fingerprint !== fp || (a.p_tokens != null && x.tokens !== a.p_tokens)
              ? { ok: false, reason: "idempotency_key_reused" } : replay(x);
          }
        } else if (fp) {
          const x = mine.filter((y) => y.fingerprint === fp && !y.idempotency_key && y.status === "pending" && Date.now() - y.created_at < 20_000).at(-1);
          if (x) return replay(x);
        }
        const q = quote(a.p_plan as string, a.p_tokens);
        if (!q) return { ok: false, reason: "unknown_product" };
        if (mine.filter((y) => Date.now() - y.created_at < 60_000).length >= this.perMinute) return { ok: false, reason: "rate_limited" };
        const id = crypto.randomUUID();
        this.purchases.set(id, {
          id, user_id: a.p_uid as string, plan_id: a.p_plan as string, tokens: q.tokens, amount_usd: q.usd,
          currency: "USD", status: "pending", provider: a.p_provider as string, provider_ref: null, checkout_key: null, created_at: Date.now(),
          pending_ref: null, idempotency_key: idem ?? null, fingerprint: fp ?? null, client_response: null, result: null, last_checked_at: null, tokens_added: 0,
        });
        return { ok: true, replay: false, purchase_id: id, amount_usd: q.usd, currency: "USD", plan_id: a.p_plan, product_id: a.p_plan, tokens: q.tokens,
          provider: a.p_provider };
      }
      case "billing_payment_save_response": {
        const p = this.purchases.get(pid);
        if (p) p.client_response = a.p_response;
        return null;
      }
      case "billing_payment_note_ref": {
        const p = this.purchases.get(pid);
        if (p && p.status === "pending") p.pending_ref = a.p_ref as string;
        return null;
      }
      case "billing_payment_failed": {
        const p = this.purchases.get(pid);
        if (p && p.status === "pending") { p.status = "failed"; p.result = a.p_reason as string; }
        return null;
      }
      case "billing_payment_expire": {
        const p = this.purchases.get(pid);
        if (p && p.status === "pending" && Date.now() - p.created_at >= (a.p_min_age_hours as number) * 3600_000) {
          p.status = "failed"; p.result = "expired"; return true;
        }
        return false;
      }
      case "billing_payment_find": {
        const p = this.purchases.get(a.p_payment as string);
        if (!p || (a.p_uid && p.user_id !== a.p_uid)) return null;
        return { ...p, created_at: new Date(p.created_at).toISOString(), last_checked_at: p.last_checked_at ? new Date(p.last_checked_at).toISOString() : null };
      }
      case "billing_payment_set_checkout_key": {
        const p = this.purchases.get(pid);
        if (p && p.status === "pending") p.checkout_key = a.p_key as string;
        return null;
      }
      case "billing_payment_find_by_key": {
        let p: P | undefined = a.p_key ? [...this.purchases.values()].find((x) => x.checkout_key === a.p_key) : undefined;
        if (p && a.p_provider && p.provider !== a.p_provider) p = undefined;
        return p ? { ...p } : null;
      }
      case "billing_payment_touch": {
        const p = this.purchases.get(pid);
        if (p) { p.last_checked_at = Date.now(); p.result = (a.p_result as string) ?? p.result; }
        return null;
      }
      case "billing_payment_pending": {
        const cutoff = Date.now() - (a.p_older_than_minutes as number) * 60_000;
        return [...this.purchases.values()].filter((p) => p.status === "pending" && p.created_at <= cutoff)
          .map((p) => ({ id: p.id, user_id: p.user_id, provider: p.provider, created_at: p.created_at }));
      }
      case "billing_payment_paid": {
        const p = this.purchases.get(pid);
        if (!p) return "no_purchase";
        if (p.provider !== a.p_provider) return "provider_mismatch";
        if (p.status === "paid" || p.status === "reversed") return p.provider_ref === a.p_ref ? "already_paid" : "purchase_paid_other_sid";
        if (!a.p_ref) return "no_sid";
        if ([...this.purchases.values()].some((x) => x.id !== p.id && x.provider === p.provider && x.provider_ref === a.p_ref)) return "sid_reused";
        if (String(a.p_currency ?? "").toUpperCase() !== p.currency) return "currency_mismatch";
        if (a.p_amount == null || Math.round(Number(a.p_amount) * 100) !== Math.round(p.amount_usd * 100)) return "amount_mismatch";
        p.status = "paid";
        p.result = "paid";
        p.provider_ref = a.p_ref as string;
        p.tokens_added = p.tokens;
        this.credits++;
        this.tokens.set(p.user_id, (this.tokens.get(p.user_id) ?? 0) + p.tokens);
        return "paid";
      }
    }
    throw new Error("unmocked rpc " + fn);
  }

  sifalo(base: string, path: string, headers: Headers, body: Record<string, unknown>): Response {
    const j = (o: unknown) => new Response(JSON.stringify(o), { status: 200, headers: { "content-type": "application/json" } });
    if (path === "verify.php") {
      if (headers.get("authorization")) throw new Error("verify.php must not get Basic auth");
      const sid = body.sid ? String(body.sid) : this.latestByOrder.get(String(body.order_id));
      const p = sid ? this.pays.get(sid) : undefined;
      if (!p) return j({ status: "failed", code: 600, response: "not found" });
      // hosted-checkout verify by sid does not echo order_id (as in the docs); wallet charges do
      const { order_id, ...rest } = p;
      const reply = body.order_id || this.echoOrder ? p : rest;
      this.verifyReplies.push(reply);
      return j(reply);
    }
    if (headers.get("authorization") !== "Basic " + btoa("user:key")) return j({ code: 0, response: "bad auth" });
    if (body.gateway === "checkout") return j({ key: `KEY${++this.n}`, token: `TOK${this.n}` });
    // wallet charge
    const map: Record<string, [string, number]> = {
      "252621111111": ["success", 601], "252651111111": ["pending", 603], "252622222222": ["failed", 600], "252644444444": ["failed", 604],
    };
    const acct = String(body.account);
    if (acct === "252600000000") return j({ code: 0, response: "Wrong username or API key" }); // no payment created
    if (acct === "252640404040") return j({ code: "404", response: "Missing fields" });
    if (acct === "252699999999") return j({ code: "999", response: "???" });
    const [status, code] = map[acct] ?? ["failed", 600];
    const sid = this.pay(String(body.order_id), String(body.amount), status, code);
    return j({ code: String(code), sid, response: status });
  }

  fetch = async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const url = String(input instanceof Request ? input.url : input);
    const headers = new Headers(init?.headers);
    const body = init?.body ? JSON.parse(String(init.body)) : null;
    this.calls.push({ url, body });
    if (url === `${SB}/auth/v1/user`) {
      return headers.get("authorization") === `Bearer ${USER_TOKEN}`
        ? Response.json({ id: UID, email: "a@b.c" }) : new Response("{}", { status: 401 });
    }
    if (url.startsWith(`${SB}/rest/v1/rpc/`)) {
      return new Response(JSON.stringify(this.rpc(url.slice(`${SB}/rest/v1/rpc/`.length), body ?? {}) ?? null), { status: 200 });
    }
    for (const base of [STG, LIVE]) {
      if (!url.startsWith(base)) continue;
      this.signals.push(init?.signal);
      const path = url.slice(base.length);
      const op = path === "verify.php" ? "verify" : body?.gateway === "checkout" ? "checkout" : "charge";
      if (this.delayMs) await new Promise((r) => setTimeout(r, this.delayMs));
      const i = this.faults.findIndex((f) => f.on === op);
      if (i >= 0) {
        const f = this.faults.splice(i, 1)[0];
        if (f.kind === "network") throw new TypeError("error sending request: connection refused");
        if (f.kind === "timeout") throw new DOMException("Signal timed out.", "TimeoutError");
        if (f.kind === "timeout_after") { this.sifalo(base, path, headers, body ?? {}); throw new DOMException("Signal timed out.", "TimeoutError"); }
        if (f.kind === "5xx") return new Response("<html>502 Bad Gateway</html>", { status: 502 });
        if (f.kind === "malformed") return new Response("<html>maintenance</html>{", { status: 200 });
      }
      return this.sifalo(base, path, headers, body ?? {});
    }
    throw new Error("unmocked fetch " + url);
  };
}

const ENV: Record<string, string> = {
  SUPABASE_URL: SB, SUPABASE_SERVICE_ROLE_KEY: SVC, SIFALO_API_USER: "user", SIFALO_API_KEY: "key", SIFALO_ENV: "staging", AI_CRON_SECRET: CRON,
};
function deps(w: World, env: Record<string, string | undefined> = ENV, registry?: Registry): Deps {
  return { env: (k) => env[k], fetch: w.fetch, registry };
}
const FN = `${SB}/functions/v1`;
const checkoutReq = (body: unknown, q = "", idem?: string) =>
  new Request(`${FN}/billing-checkout${q}`, {
    method: "POST", body: JSON.stringify(body),
    headers: { authorization: `Bearer ${USER_TOKEN}`, ...(idem ? { "x-idempotency-key": idem } : {}) },
  });
const statusReq = (pid: string) => new Request(`${FN}/billing-checkout?purchase=${pid}`, { headers: { authorization: `Bearer ${USER_TOKEN}` } });
const webhookReq = (q: string, body: unknown) => new Request(`${FN}/billing-webhook${q}`, { method: "POST", body: JSON.stringify(body) });
const cronReq = (secret = CRON, q = "?older_than_minutes=1") => new Request(`${FN}/billing-reconcile${q}`, { method: "POST", headers: { "x-cron-secret": secret } });

async function startHosted(w: World, body: unknown = PAYG_1) {
  const r = await handleCheckout(checkoutReq(body, "", `test-${crypto.randomUUID()}`), deps(w));
  const j = await r.json();
  assertEquals(r.status, 200, JSON.stringify(j));
  return j as { purchase_id: string; url: string };
}

// ------------------------------------------------------------------ Sifalo through the four handlers
Deno.test("success: hosted checkout -> webhook credits once via DB RPC", async () => {
  const w = new World();
  const { purchase_id, url } = await startHosted(w);
  assertStringIncludes(url, "https://pay.sifalo.net/checkout/?key=KEY");
  const start = w.sifaloCalls[0].body as Record<string, string>;
  assertEquals(start.gateway, "checkout");
  assertEquals(start.amount, "1");
  assertStringIncludes(start.return_url, `/billing-return?provider=sifalo&purchase=${purchase_id}&order_id=${purchase_id}`);
  assertStringIncludes(start.webhook_url, `/billing-webhook?provider=sifalo&purchase=${purchase_id}`);
  assertEquals(w.purchases.get(purchase_id)!.checkout_key, "KEY1");

  const sid = w.pay(purchase_id, "1");
  const r = await handleWebhook(webhookReq(`?provider=sifalo&purchase=${purchase_id}`, { sid, status: "success", code: 601, amount: "1", currency: "USD" }), deps(w));
  assertEquals(r.status, 200);
  assertEquals((await r.json()).outcome, "paid");
  assertEquals(w.purchases.get(purchase_id)!.status, "paid");
  assertEquals(w.tokens.get(UID), 500000);
});

Deno.test("duplicate webhook + return: no double credit; return redirects to submac://pay", async () => {
  const w = new World();
  const { purchase_id } = await startHosted(w);
  const sid = w.pay(purchase_id, "1");
  const body = { sid, status: "success", code: 601 };
  for (let i = 0; i < 3; i++) await handleWebhook(webhookReq(`?purchase=${purchase_id}`, body), deps(w));
  const ret = await handleReturn(new Request(`${FN}/billing-return?provider=sifalo&purchase=${purchase_id}&order_id=${purchase_id}&sid=${sid}`), deps(w));
  assertEquals(ret.status, 303);
  assertEquals(ret.headers.get("location"), `submac://pay?status=paid&purchase=${purchase_id}`);
  assertEquals(w.credits, 1);
  assertEquals(w.tokens.get(UID), 500000);
});

Deno.test("webhook found by checkout key only (no purchase in query) still verifies", async () => {
  const w = new World();
  const { purchase_id } = await startHosted(w);
  const sid = w.pay(purchase_id, "1");
  const r = await handleWebhook(webhookReq("", { sid, key: "KEY1", status: "success", code: 601 }), deps(w));
  assertEquals((await r.json()).outcome, "paid");
});

Deno.test("mismatch: wrong amount / currency rejected, stays pending, nothing credited", async () => {
  const w = new World();
  const { purchase_id } = await startHosted(w, PAYG_5);
  const under = w.pay(purchase_id, "0.5");
  let r = await handleWebhook(webhookReq(`?purchase=${purchase_id}`, { sid: under, status: "success", code: 601, amount: "5" }), deps(w));
  assertEquals((await r.json()).outcome, "amount_mismatch");
  const cur = w.pay(purchase_id, "5", "success", 601, "SLSH");
  r = await handleWebhook(webhookReq(`?purchase=${purchase_id}`, { sid: cur }), deps(w));
  assertEquals((await r.json()).outcome, "currency_mismatch");
  assertEquals(w.purchases.get(purchase_id)!.status, "pending");
  assertEquals(w.tokens.get(UID) ?? 0, 0);
  // a correct payment afterwards credits
  const ok = w.pay(purchase_id, "5");
  r = await handleWebhook(webhookReq(`?purchase=${purchase_id}`, { sid: ok }), deps(w));
  assertEquals((await r.json()).outcome, "paid");
  assertEquals(w.tokens.get(UID), 2500000);
});

Deno.test("no order_id in verify: credits when the order lookup names the same sid (staging shape)", async () => {
  const w = new World();
  const { purchase_id } = await startHosted(w, PAYG_5);
  const sid = w.pay(purchase_id, "5"); // verify by sid does not echo order_id; verify by order id finds this sid
  const r = await handleReturn(new Request(`${FN}/billing-return?provider=sifalo&purchase=${purchase_id}&order_id=${purchase_id}&sid=${sid}`), deps(w));
  assertEquals(r.headers.get("location"), `submac://pay?status=paid&purchase=${purchase_id}`);
  const v = w.verifyReplies.at(-2)!; // verify by sid (the last one is the order lookup)
  assertEquals("order_id" in v, false);
  assertEquals(w.verifyReplies.at(-1)!.order_id, purchase_id);
  assertEquals([v.status, v.code, v.amount, v.currency], ["success", 601, "5", "USD"]);
  assertEquals(w.purchases.get(purchase_id)!.status, "paid");
  assertEquals(w.purchases.get(purchase_id)!.provider_ref, sid);
  assertEquals(w.tokens.get(UID), 2500000);
  assertEquals(w.credits, 1);
});

Deno.test("reused sid: a sid already credited to one purchase is rejected on a second purchase", async () => {
  const w = new World();
  const a = await startHosted(w);
  const b = await startHosted(w);
  const sidA = w.pay(a.purchase_id, "1");
  assertEquals((await (await handleWebhook(webhookReq(`?purchase=${a.purchase_id}`, { sid: sidA }), deps(w))).json()).outcome, "paid");
  // same sid, same amount, NEW purchase: not this order's payment -> webhook and return both refused
  const r = await handleWebhook(webhookReq(`?purchase=${b.purchase_id}`, { sid: sidA }), deps(w));
  assertEquals((await r.json()).outcome, "sid_not_for_order");
  const ret = await handleReturn(new Request(`${FN}/billing-return?purchase=${b.purchase_id}&order_id=${b.purchase_id}&sid=${sidA}`), deps(w));
  assertEquals(ret.headers.get("location"), `submac://pay?status=error&purchase=${b.purchase_id}&reason=sid_not_for_order`);
  assertEquals(w.purchases.get(b.purchase_id)!.status, "pending");
  // replaying for the original purchase: already_paid, no double credit
  assertEquals((await (await handleWebhook(webhookReq(`?purchase=${a.purchase_id}`, { sid: sidA }), deps(w))).json()).outcome, "already_paid");
  assertEquals(w.credits, 1);
  assertEquals(w.tokens.get(UID), 500000);
});

Deno.test("no order_id in verify: amount mismatch rejected (stays pending, nothing credited)", async () => {
  const w = new World();
  const { purchase_id } = await startHosted(w, PAYG_5);
  const sid = w.pay(purchase_id, "1"); // paid $1 for a $5 purchase
  const r = await handleWebhook(webhookReq(`?purchase=${purchase_id}`, { sid, amount: "5", currency: "USD", status: "success", code: 601 }), deps(w));
  assertEquals((await r.json()).outcome, "amount_mismatch");
  assertEquals(w.purchases.get(purchase_id)!.status, "pending");
  assertEquals(w.tokens.get(UID) ?? 0, 0);
  // and it can never be moved onto another order whose amount it matches
  const b = await startHosted(w, PAYG_1);
  assertEquals((await (await handleWebhook(webhookReq(`?purchase=${b.purchase_id}`, { sid }), deps(w))).json()).outcome, "sid_not_for_order");
  assertEquals(w.credits, 0);
});

Deno.test("order binding: a sid the provider never linked to this order is not credited", async () => {
  const w = new World();
  const { purchase_id } = await startHosted(w, PAYG_1);
  const stray = w.pay(null, "1"); // someone else's $1 payment (right amount, wrong order)
  const ret = await handleReturn(new Request(`${FN}/billing-return?purchase=${purchase_id}&sid=${stray}`), deps(w));
  assertEquals(ret.headers.get("location"), `submac://pay?status=error&purchase=${purchase_id}&reason=sid_not_for_order`);
  assertEquals((await (await handleWebhook(webhookReq(`?purchase=${purchase_id}`, { sid: stray }), deps(w))).json()).outcome, "sid_not_for_order");
  assertEquals(w.purchases.get(purchase_id)!.status, "pending");
  assertEquals(w.purchases.get(purchase_id)!.result, "sid_not_for_order");
  assertEquals(w.credits, 0);
  // the real payment for the order still credits
  const own = w.pay(purchase_id, "1");
  assertEquals((await (await handleWebhook(webhookReq(`?purchase=${purchase_id}`, { sid: own }), deps(w))).json()).outcome, "paid");
  assertEquals(w.credits, 1);
});

Deno.test("webhook missed: nothing arrives, reconcile (every 10 min) verifies by order id and credits once", async () => {
  const w = new World();
  const { purchase_id } = await startHosted(w, PAYG_5);
  w.pay(purchase_id, "5"); // customer paid; the webhook never came and the browser never returned
  age(w, purchase_id, 11 * 60_000);
  const rc = await (await handleReconcile(cronReq(CRON, "?older_than_minutes=10"), deps(w))).json();
  assertEquals(rc.paid, 1);
  assertEquals(w.purchases.get(purchase_id)!.status, "paid");
  assertEquals(w.tokens.get(UID), 2500000);
  // the next run does nothing more; the app poll says paid with tokens added
  const rc2 = await (await handleReconcile(cronReq(CRON, "?older_than_minutes=10"), deps(w))).json();
  assertEquals(rc2.checked, 0);
  const st = await (await handleCheckout(new Request(`${FN}/billing-checkout?purchase=${purchase_id}`, { headers: { authorization: `Bearer ${USER_TOKEN}` } }), deps(w))).json();
  assertEquals([st.status, st.tokens_added], ["paid", 2500000]);
  assertEquals(w.credits, 1);
});

Deno.test("staging: only billing testers may pay", async () => {
  const w = new World();
  w.tester = false;
  const r = await handleCheckout(checkoutReq(PAYG_1), deps(w));
  assertEquals(r.status, 503);
  assertEquals((await r.json()).error, "billing_disabled");
  assertEquals(w.sifaloCalls.length + w.writes.length, 0);
  // live Sifalo: the same user pays (billing on for everyone)
  const ok = await handleCheckout(checkoutReq(PAYG_1), deps(w, { ...ENV, SIFALO_ENV: "live" }));
  assertEquals(ok.status, 200);
});

Deno.test("return link always goes back to the app (never a JSON page)", async () => {
  const w = new World();
  const pid = "33333333-3333-4333-8333-333333333333";
  const crash: Deps = { ...deps(w), fetch: () => Promise.reject(new TypeError("db down")) };
  const r = await handleReturn(new Request(`${FN}/billing-return?purchase=${pid}&sid=SID1`), crash);
  assertEquals(r.status, 303);
  assertEquals(r.headers.get("location"), `submac://pay?status=pending&purchase=${pid}&reason=processing`);
  const r2 = await handleReturn(new Request(`${FN}/billing-return?provider=nope&order_id=${pid}`), deps(w));
  assertEquals(r2.headers.get("location"), `submac://pay?status=error&purchase=${pid}&reason=unavailable`);
  const r3 = await handleReturn(new Request(`${FN}/billing-return`), deps(w, { ...ENV, BILLING_APP_RETURN_URL: "submac://pay?" }));
  assertEquals(r3.headers.get("location"), "submac://pay?status=error&purchase=");
});

Deno.test("verify echoes a different order_id -> rejected even when amount matches", async () => {
  const w = new World();
  w.echoOrder = true;
  const a = await startHosted(w);
  const b = await startHosted(w);
  const sidA = w.pay(a.purchase_id, "1");
  const r = await handleWebhook(webhookReq(`?purchase=${b.purchase_id}`, { sid: sidA }), deps(w));
  assertEquals((await r.json()).outcome, "order_mismatch");
  assertEquals(w.purchases.get(b.purchase_id)!.status, "pending");
  assertEquals(w.credits, 0);
  // body order_id conflicting with the URL purchase is ignored
  const r2 = await handleWebhook(webhookReq(`?purchase=${b.purchase_id}`, { sid: sidA, order_id: a.purchase_id }), deps(w));
  assertEquals((await r2.json()).outcome, "order_conflict");
  // and the right purchase still credits
  assertEquals((await (await handleWebhook(webhookReq(`?purchase=${a.purchase_id}`, { sid: sidA }), deps(w))).json()).outcome, "paid");
});

Deno.test("forged webhook: body says success but verify says otherwise -> nothing credited, not failed", async () => {
  const w = new World();
  const { purchase_id } = await startHosted(w);
  const r = await handleWebhook(webhookReq(`?purchase=${purchase_id}`, { sid: "FORGED1", status: "success", code: 601, amount: "1", currency: "USD" }), deps(w));
  assertEquals((await r.json()).outcome, "failed");
  assertEquals(w.purchases.get(purchase_id)!.status, "pending"); // forged unknown sid can't fail the purchase
  assertEquals(w.credits, 0);
});

Deno.test("pending: 603 stays pending; reconcile credits once it is paid", async () => {
  const w = new World();
  const { purchase_id } = await startHosted(w);
  const sid = w.pay(purchase_id, "1", "pending", 603);
  const r = await handleWebhook(webhookReq(`?purchase=${purchase_id}`, { sid, status: "pending", code: 603 }), deps(w));
  assertEquals((await r.json()).outcome, "pending");
  const ret = await handleReturn(new Request(`${FN}/billing-return?purchase=${purchase_id}&sid=${sid}`), deps(w));
  assertEquals(ret.headers.get("location"), `submac://pay?status=pending&purchase=${purchase_id}`);
  assertEquals(w.purchases.get(purchase_id)!.status, "pending");
  // customer approves on the phone later; no second webhook (Sifalo fires once) -> reconcile picks it up
  Object.assign(w.pays.get(sid)!, { status: "success", code: 601 });
  w.purchases.get(purchase_id)!.created_at -= 15 * 60_000;
  const rc = await handleReconcile(cronReq(CRON, "?older_than_minutes=10"), deps(w));
  const j = await rc.json();
  assertEquals(rc.status, 200);
  assertEquals(j.paid, 1);
  assertEquals(w.purchases.get(purchase_id)!.status, "paid");
  assertEquals(w.credits, 1);
  // second run: nothing pending
  assertEquals((await (await handleReconcile(cronReq(), deps(w))).json()).checked, 0);
});

Deno.test("reconcile skips purchases younger than N minutes and finds buyers who never returned", async () => {
  const w = new World();
  const young = await startHosted(w);
  const old = await startHosted(w);
  w.pay(old.purchase_id, "1"); // paid, but no webhook and no return
  w.pay(young.purchase_id, "1");
  w.purchases.get(old.purchase_id)!.created_at -= 30 * 60_000;
  const j = await (await handleReconcile(cronReq(CRON, "?older_than_minutes=10"), deps(w))).json();
  assertEquals(j.checked, 1);
  assertEquals(w.purchases.get(old.purchase_id)!.status, "paid");
  assertEquals(w.purchases.get(young.purchase_id)!.status, "pending");
});

Deno.test("failed: declined payment marks the purchase failed; return says failed", async () => {
  const w = new World();
  const { purchase_id } = await startHosted(w);
  const sid = w.pay(purchase_id, "1", "failed", 604);
  const r = await handleWebhook(webhookReq(`?purchase=${purchase_id}`, { sid, status: "failed", code: 604 }), deps(w));
  assertEquals((await r.json()).outcome, "failed");
  assertEquals(w.purchases.get(purchase_id)!.status, "failed");
  const ret = await handleReturn(new Request(`${FN}/billing-return?purchase=${purchase_id}&sid=${sid}`), deps(w));
  assertEquals(ret.headers.get("location"), `submac://pay?status=failed&purchase=${purchase_id}&reason=insufficient_funds`);
  assertEquals(w.credits, 0);
  // a retry on the checkout page that succeeds still credits (failed is not terminal)
  const ok = w.pay(purchase_id, "1");
  await handleWebhook(webhookReq(`?purchase=${purchase_id}`, { sid: ok }), deps(w));
  assertEquals(w.credits, 1);
});

Deno.test("e-wallet direct charge: success credits, pending stays pending, failed fails", async () => {
  const w = new World();
  let j = await (await handleCheckout(checkoutReq({ ...PAYG_1, method: "wallet", wallet: "edahab", account: "252621111111" }), deps(w))).json();
  assertEquals(j.status, "paid");
  assertEquals(w.tokens.get(UID), 500000);
  j = await (await handleCheckout(checkoutReq({ ...PAYG_1, method: "wallet", wallet: "edahab", account: "252651111111" }), deps(w))).json();
  assertEquals(j.status, "pending");
  j = await (await handleCheckout(checkoutReq({ ...PAYG_1, method: "wallet", wallet: "edahab", account: "252622222222" }), deps(w))).json();
  assertEquals(j.status, "failed");
  assertEquals(w.purchases.get(j.purchase_id)!.status, "failed");
  assertEquals(w.credits, 1);
});

Deno.test("checkout input errors: signed out, bad product", async () => {
  const w = new World();
  const r = await handleCheckout(new Request(`${FN}/billing-checkout`, { method: "POST", body: "{}" }), deps(w));
  assertEquals(r.status, 401);
  const r2 = await handleCheckout(checkoutReq({ plan: "payg", tokens: 333 }), deps(w));
  assertEquals(r2.status, 400);
  assertEquals((await r2.json()).error, "unknown_product");
  const r3 = await handleCheckout(checkoutReq({ plan: "payg", tokens: -5 }), deps(w));
  assertEquals(r3.status, 400);
  const r4 = await handleCheckout(checkoutReq({ coins: 100 }), deps(w));
  assertEquals(r4.status, 400); // coins are gone
  assertEquals(w.purchases.size, 0);
  assertEquals(w.sifaloCalls.length, 0);
});

Deno.test("flag off: all four refuse with no provider call and no DB write", async () => {
  const w = new World();
  w.enabled = false;
  const pid = "22222222-2222-4222-8222-222222222222";
  const c = await handleCheckout(checkoutReq(PAYG_1), deps(w));
  assertEquals(c.status, 503);
  assertEquals((await c.json()).error, "billing_disabled");
  const wh = await handleWebhook(webhookReq(`?purchase=${pid}`, { sid: "SID1", status: "success", code: 601 }), deps(w));
  assertEquals(wh.status, 200);
  assertEquals((await wh.json()).error, "billing_disabled");
  const rt = await handleReturn(new Request(`${FN}/billing-return?purchase=${pid}&sid=SID1`), deps(w));
  assertEquals(rt.status, 303);
  assertEquals(rt.headers.get("location"), `submac://pay?status=error&purchase=${pid}&reason=billing_disabled`);
  const rc = await handleReconcile(cronReq(), deps(w));
  assertEquals(rc.status, 503);
  assertEquals((await rc.json()).error, "billing_disabled");
  assertEquals(w.sifaloCalls.length, 0);
  assertEquals(w.writes.length, 0);
});

Deno.test("missing secrets: all four refuse with zero network calls", async () => {
  for (const missing of [["SIFALO_API_KEY"], ["SIFALO_API_USER"], ["SIFALO_ENV"]]) {
    const w = new World();
    const env = { ...ENV };
    for (const k of missing) delete env[k];
    const d = deps(w, env);
    const c = await handleCheckout(checkoutReq(PAYG_1), d);
    assertEquals(c.status, 503);
    assertEquals((await c.json()).error, "payments_not_configured");
    const wh = await handleWebhook(webhookReq("", { sid: "SID1" }), d);
    assertEquals(wh.status, 200);
    assertEquals((await wh.json()).error, "payments_not_configured");
    const rt = await handleReturn(new Request(`${FN}/billing-return?sid=SID1`), d);
    assertEquals([rt.status, rt.headers.get("location")], [303, "submac://pay?status=error&purchase=&reason=unavailable"]);
    assertEquals((await handleReconcile(cronReq(), d)).status, 503);
    assertEquals(w.calls.length, 0, `calls made with ${missing} missing`);
  }
  // placeholders count as missing
  assert(!sifaloFactory.configured((k) => ({ ...ENV, SIFALO_API_KEY: "your-api-key" } as Record<string, string>)[k]));
});

Deno.test("reconcile: bad or missing cron secret refused, no writes", async () => {
  const w = new World();
  assertEquals((await handleReconcile(cronReq("wrong"), deps(w))).status, 401);
  assertEquals((await handleReconcile(new Request(`${FN}/billing-reconcile`, { method: "POST" }), deps(w))).status, 401);
  const noCron = { ...ENV };
  delete noCron.AI_CRON_SECRET;
  assertEquals((await handleReconcile(cronReq(), deps(w, noCron))).status, 503);
  assertEquals(w.writes.length + w.sifaloCalls.length, 0);
});

Deno.test("SIFALO_ENV=live uses the live hosts; unknown provider refused", async () => {
  const w = new World();
  await handleCheckout(checkoutReq(PAYG_1), deps(w, { ...ENV, SIFALO_ENV: "live" }));
  assert(w.sifaloCalls[0].url.startsWith(LIVE));
  const r = await handleCheckout(checkoutReq(PAYG_1, "?provider=nope"), deps(w));
  assertEquals(r.status, 400);
  assertEquals((await r.json()).error, "unknown_provider");
  assert(Object.hasOwn(PROVIDERS, "sifalo"));
});

// ------------------------------------------------------------------ the core with a fake provider
class FakeProvider implements PaymentProvider {
  readonly name = "fakepay";
  readonly supportsOrderLookup = false;
  constructor(private book: Map<string, { order: string; amount: number; status: "paid" | "pending" | "failed" }>) {}
  startCheckout(i: StartCheckoutInput) {
    return Promise.resolve({ redirectUrl: `https://fake.example/pay/${i.purchaseId}?amt=${i.amount}`, providerRef: `sess_${i.purchaseId.slice(0, 8)}` });
  }
  verify(q: VerifyQuery): Promise<VerifyResult> {
    const p = q.providerRef ? this.book.get(q.providerRef) : undefined;
    return Promise.resolve({
      status: p?.status ?? "failed", providerRef: p ? q.providerRef! : null, orderId: p?.order ?? null,
      amount: p?.amount ?? null, currency: p ? "USD" : null, paymentType: "FAKE", raw: { fake: true },
    });
  }
  async parseWebhook(req: Request) {
    const b = await req.json().catch(() => ({}));
    return { providerRef: b.payment ?? null, orderId: b.metadata?.purchase ?? null, checkoutRef: null, raw: b };
  }
  parseReturn(url: URL) {
    return { providerRef: url.searchParams.get("payment"), orderId: null };
  }
}
function fakeRegistry(book: Map<string, { order: string; amount: number; status: "paid" | "pending" | "failed" }>): Registry {
  const fake: ProviderFactory = { name: "fakepay", configured: (env: Env) => !!env("FAKEPAY_KEY"), create: () => new FakeProvider(book) };
  return { ...PROVIDERS, fakepay: fake };
}

Deno.test("fake provider: checkout/return/webhook run through the same core, keyed on (provider, ref)", async () => {
  const w = new World();
  const book = new Map<string, { order: string; amount: number; status: "paid" | "pending" | "failed" }>();
  const env = { ...ENV, FAKEPAY_KEY: "k" };
  const d = deps(w, env, fakeRegistry(book));
  const c = await (await handleCheckout(checkoutReq(PAYG_1, "?provider=fakepay", `fk-${crypto.randomUUID()}`), d)).json();
  assertEquals(c.provider, "fakepay");
  assertStringIncludes(c.url, "https://fake.example/pay/");
  assertEquals(w.purchases.get(c.purchase_id)!.provider, "fakepay");
  assertEquals(w.sifaloCalls.length, 0);

  book.set("pay_1", { order: c.purchase_id, amount: 1, status: "paid" });
  // path routing: /billing-return/fakepay
  const ret = await handleReturn(new Request(`${FN}/billing-return/fakepay?purchase=${c.purchase_id}&payment=pay_1`), d);
  assertEquals(ret.headers.get("location"), `submac://pay?status=paid&purchase=${c.purchase_id}`);
  const mp = w.calls.find((x) => x.url.endsWith("/billing_payment_paid"))!.body as Record<string, unknown>;
  assertEquals(mp.p_provider, "fakepay");
  assertEquals(mp.p_ref, "pay_1");
  // duplicate webhook: already paid
  const wh = await handleWebhook(webhookReq("?provider=fakepay", { payment: "pay_1", metadata: { purchase: c.purchase_id } }), d);
  assertEquals((await wh.json()).outcome, "already_paid");

  // same ref replayed against another fakepay purchase: the provider echoes the real order -> order_mismatch
  const c2 = await (await handleCheckout(checkoutReq(PAYG_1, "?provider=fakepay", `fk-${crypto.randomUUID()}`), d)).json();
  const wh2 = await handleWebhook(webhookReq(`?provider=fakepay&purchase=${c2.purchase_id}`, { payment: "pay_1" }), d);
  assertEquals((await wh2.json()).outcome, "order_mismatch");
  // a ref the provider does not link to any order (and no order lookup): never credited from outside
  book.set("pay_x", { order: "", amount: 1, status: "paid" });
  const wh3 = await handleWebhook(webhookReq(`?provider=fakepay&purchase=${c2.purchase_id}`, { payment: "pay_x" }), d);
  assertEquals((await wh3.json()).outcome, "sid_not_for_order");
  assertEquals(w.credits, 1);

  // a sifalo webhook pointed at a fakepay purchase never credits it
  const c4 = await (await handleCheckout(checkoutReq(PAYG_1, "?provider=fakepay", `fk-${crypto.randomUUID()}`), d)).json();
  const sid = w.pay(c4.purchase_id, "1");
  const wh4 = await handleWebhook(webhookReq(`?provider=sifalo&purchase=${c4.purchase_id}`, { sid }), d);
  assertEquals((await wh4.json()).outcome, "provider_mismatch");

  // fake provider without order lookup: reconcile leaves it pending (needs a ref)
  w.purchases.get(c4.purchase_id)!.created_at -= 60 * 60_000;
  const rc = await (await handleReconcile(cronReq(), d)).json();
  assertEquals(rc.results.find((x: { id: string }) => x.id === c4.purchase_id).outcome, "pending");
  assertEquals(w.credits, 1);
});

Deno.test("fake provider not configured -> refused, sifalo still works", async () => {
  const w = new World();
  const d = deps(w, ENV, fakeRegistry(new Map()));
  const r = await handleCheckout(checkoutReq(PAYG_1, "?provider=fakepay", `fk-${crypto.randomUUID()}`), d);
  assertEquals(r.status, 503);
  assertEquals(w.calls.length, 0);
  assertEquals((await handleCheckout(checkoutReq(PAYG_1), d)).status, 200);
});

Deno.test("PAYMENT_PROVIDER env picks the default provider", async () => {
  const w = new World();
  const d = deps(w, { ...ENV, FAKEPAY_KEY: "k", PAYMENT_PROVIDER: "fakepay" }, fakeRegistry(new Map()));
  const c = await (await handleCheckout(checkoutReq(PAYG_1), d)).json();
  assertEquals(c.provider, "fakepay");
});

// ------------------------------------------------------------------ stress / frustration cases (owner, 2026-10-21)
const walletReq = (account: string, idem?: string, extra: Record<string, unknown> = {}) =>
  checkoutReq({ ...PAYG_1, method: "wallet", wallet: "edahab", account, ...extra }, "", idem);
const age = (w: World, pid: string, ms: number) => { w.purchases.get(pid)!.created_at -= ms; };
const chargeCalls = (w: World) => w.sifaloCalls.filter((c) => (c.body as Record<string, unknown>)?.gateway === "edahab");

Deno.test("timeouts: every Sifalo call carries a 120 s AbortSignal; a slow (eDahab-like) answer still credits", async () => {
  assertEquals(SIFALO_TIMEOUT_MS, 120_000);
  const w = new World();
  w.delayMs = 40;
  const r = await handleCheckout(walletReq("252621111111", "slow-key-0001"), deps(w));
  assertEquals((await r.json()).status, "paid");
  assert(w.signals.length >= 2 && w.signals.every((x) => x instanceof AbortSignal), "signal on every call");
  // the adapter really aborts at its timeout (short timeout injected here) and reports provider_timeout
  const hang: typeof fetch = (_i, init) => new Promise((_res, rej) => init?.signal?.addEventListener("abort", () => rej(init.signal!.reason)));
  const prov = new SifaloProvider((k) => ENV[k], hang, 30);
  let err: unknown = null;
  try { await prov.verify({ providerRef: "SID1" }); } catch (e) { err = e; }
  assert(err instanceof ProviderUnavailable);
  assertEquals((err as ProviderUnavailable).kind, "provider_timeout");
});

Deno.test("retry after timeout: charge went through but answer was lost -> pending, no second charge on retry, reconcile credits once", async () => {
  const w = new World();
  w.faults.push({ on: "charge", kind: "timeout_after" });
  const r1 = await handleCheckout(walletReq("252621111111", "retry-key-0001"), deps(w));
  const j1 = await r1.json();
  assertEquals(r1.status, 202);
  assertEquals([j1.status, j1.state, j1.error], ["pending", "processing", "provider_timeout"]);
  assertEquals(w.purchases.get(j1.purchase_id)!.status, "pending");
  assertEquals(w.credits, 0);
  // user taps "Pay" again with the same idempotency key: same purchase, Sifalo is NOT charged again
  const r2 = await handleCheckout(walletReq("252621111111", "retry-key-0001"), deps(w));
  const j2 = await r2.json();
  assertEquals(j2.purchase_id, j1.purchase_id);
  assertEquals(r2.headers.get("x-idempotent-replay"), "true");
  assertEquals(chargeCalls(w).length, 1);
  // reconcile finds the payment by our order id and credits exactly once
  age(w, j1.purchase_id, 15 * 60_000);
  const rc = await (await handleReconcile(cronReq(CRON, "?older_than_minutes=10"), deps(w))).json();
  assertEquals(rc.paid, 1);
  assertEquals(w.credits, 1);
  const j3 = await (await handleCheckout(walletReq("252621111111", "retry-key-0001"), deps(w))).json();
  assertEquals([j3.status, j3.purchase_id], ["paid", j1.purchase_id]);
  assertEquals(chargeCalls(w).length, 1);
  assertEquals(w.tokens.get(UID), 500000);
});

Deno.test("idempotency key: same key -> same purchase and answer, one charge; same key for another product -> 409", async () => {
  const w = new World();
  const a = await (await handleCheckout(walletReq("252621111111", "idem-key-0001"), deps(w))).json();
  const r = await handleCheckout(walletReq("252621111111", "idem-key-0001"), deps(w));
  const b = await r.json();
  assertEquals([a.status, b.status], ["paid", "paid"]);
  assertEquals(b.purchase_id, a.purchase_id);
  assertEquals(b.replay, true);
  assertEquals(chargeCalls(w).length, 1);
  assertEquals(w.credits, 1);
  const c = await handleCheckout(checkoutReq({ ...PAYG_5, method: "wallet", wallet: "edahab", account: "252621111111" }, "", "idem-key-0001"), deps(w));
  assertEquals(c.status, 409);
  assertEquals((await c.json()).error, "idempotency_key_reused");
  const bad = await handleCheckout(walletReq("252621111111", "short"), deps(w));
  assertEquals(bad.status, 400);
  assertEquals(w.purchases.size, 1);
});

Deno.test("double tap / concurrent checkouts: 5 at once (no key, and same key) -> one purchase, one charge, one credit", async () => {
  const w = new World();
  // Sifalo answers in 50 ms, so every tap reaches the server while the first purchase is still pending (a tap that
  // only arrives after the first one was PAID is a new purchase by design). Without this the test raced crypto.subtle.
  w.delayMs = 50;
  const rs = await Promise.all([1, 2, 3, 4, 5].map(() => handleCheckout(walletReq("252621111111"), deps(w))));
  const js = await Promise.all(rs.map((r) => r.json()));
  assertEquals(new Set(js.map((j) => j.purchase_id)).size, 1);
  assertEquals(chargeCalls(w).length, 1);
  assertEquals(w.credits, 1);
  assertEquals(js.filter((j) => j.replay).length, 4);
  // same with an idempotency key from the client
  const rs2 = await Promise.all([1, 2, 3, 4, 5].map(() => handleCheckout(walletReq("252621111111", "tap-key-00001"), deps(w))));
  const js2 = await Promise.all(rs2.map((r) => r.json()));
  assertEquals(new Set(js2.map((j) => j.purchase_id)).size, 1);
  assertEquals(chargeCalls(w).length, 2);
  assertEquals(w.credits, 2);
  // a different wallet number is a different purchase (not a double tap)
  await handleCheckout(walletReq("252651111111"), deps(w));
  assertEquals(w.purchases.size, 3);
});

Deno.test("concurrent duplicate webhooks + returns at the same moment -> single credit", async () => {
  const w = new World();
  const { purchase_id } = await startHosted(w);
  const sid = w.pay(purchase_id, "1");
  const reqs = [
    ...[1, 2, 3, 4, 5].map(() => handleWebhook(webhookReq(`?provider=sifalo&purchase=${purchase_id}`, { sid, status: "success", code: 601 }), deps(w))),
    ...[1, 2].map(() => handleReturn(new Request(`${FN}/billing-return?provider=sifalo&purchase=${purchase_id}&sid=${sid}`), deps(w))),
  ];
  const out = await Promise.all(reqs);
  const outcomes = await Promise.all(out.slice(0, 5).map(async (r) => (await r.json()).outcome));
  assert(outcomes.every((o) => o === "paid" || o === "already_paid"), outcomes.join());
  assert(outcomes.filter((o) => o === "paid").length <= 1); // a return may win the race; still one credit
  for (const r of out.slice(5)) assertEquals(r.headers.get("location"), `submac://pay?status=paid&purchase=${purchase_id}`);
  assertEquals(w.credits, 1);
  assertEquals(w.tokens.get(UID), 500000);
});

Deno.test("Sifalo down (network / 5xx / malformed / timeout) on verify: stays pending, clear code, no credit, never failed; reconcile credits later", async () => {
  for (const kind of ["network", "5xx", "malformed", "timeout"] as const) {
    const w = new World();
    const { purchase_id } = await startHosted(w);
    const sid = w.pay(purchase_id, "1");
    w.faults.push({ on: "verify", kind });
    const r = await handleWebhook(webhookReq(`?purchase=${purchase_id}`, { sid }), deps(w));
    assertEquals(r.status, 200);
    assertEquals((await r.json()).outcome, "provider_unavailable", kind);
    w.faults.push({ on: "verify", kind });
    const ret = await handleReturn(new Request(`${FN}/billing-return?purchase=${purchase_id}&sid=${sid}`), deps(w));
    const reason = kind === "timeout" ? "provider_timeout" : "provider_unavailable";
    assertEquals(ret.headers.get("location"), `submac://pay?status=pending&purchase=${purchase_id}&reason=${reason}`);
    assertEquals(w.purchases.get(purchase_id)!.status, "pending", kind);
    assertEquals(w.credits, 0);
    // poll shows "processing" with the reason while Sifalo is down
    const st = await (await handleCheckout(statusReq(purchase_id), { ...deps(w), now: () => Date.now() - 60_000 })).json();
    assertEquals([st.status, st.state, st.reason], ["pending", "processing", reason]);
    // Sifalo back: reconcile credits once
    age(w, purchase_id, 15 * 60_000);
    assertEquals((await (await handleReconcile(cronReq(), deps(w))).json()).paid, 1, kind);
    assertEquals(w.credits, 1);
  }
});

Deno.test("Sifalo down on wallet charge / hosted start: pending + clear code; hosted retry with the same key reopens the same purchase", async () => {
  for (const kind of ["network", "5xx", "malformed"] as const) {
    const w = new World();
    w.faults.push({ on: "charge", kind });
    const r = await handleCheckout(walletReq("252621111111", `down-key-${kind}`), deps(w));
    const j = await r.json();
    assertEquals(r.status, 202);
    assertEquals([j.status, j.error], ["pending", "provider_unavailable"]);
    assertEquals(w.purchases.get(j.purchase_id)!.status, "pending");
    assertEquals(w.credits, 0);
  }
  const w = new World();
  w.faults.push({ on: "checkout", kind: "5xx" });
  const r1 = await handleCheckout(checkoutReq(PAYG_1, "", "hosted-key-001"), deps(w));
  const j1 = await r1.json();
  assertEquals(r1.status, 502);
  assertEquals(j1.error, "provider_unavailable");
  assertEquals(w.purchases.get(j1.purchase_id)!.status, "pending");
  const r2 = await handleCheckout(checkoutReq(PAYG_1, "", "hosted-key-001"), deps(w));
  const j2 = await r2.json();
  assertEquals(r2.status, 200);
  assertEquals(j2.purchase_id, j1.purchase_id);
  assertStringIncludes(j2.url, "https://pay.sifalo.net/checkout/?key=");
  assertEquals(w.purchases.size, 1);
});

Deno.test("user closes browser/app mid-payment: reconcile credits (hosted by order lookup, wallet 603 by stored sid)", async () => {
  const w = new World();
  const hosted = await startHosted(w);
  w.pay(hosted.purchase_id, "1"); // paid on the Sifalo page, browser closed: no return, webhook lost
  const wal = await (await handleCheckout(walletReq("252651111111", "close-key-0001"), deps(w))).json();
  assertEquals(wal.state, "waiting_approval");
  assertEquals(w.purchases.get(wal.purchase_id)!.pending_ref !== null, true);
  // approves on the phone after closing the app
  const sid = w.purchases.get(wal.purchase_id)!.pending_ref!;
  Object.assign(w.pays.get(sid)!, { status: "success", code: 601 });
  w.latestByOrder.delete(wal.purchase_id); // even if order lookup knew nothing, the stored sid is enough
  age(w, hosted.purchase_id, 20 * 60_000);
  age(w, wal.purchase_id, 20 * 60_000);
  const rc = await (await handleReconcile(cronReq(), deps(w))).json();
  assertEquals(rc.paid, 2);
  assertEquals(w.credits, 2);
  assertEquals(w.tokens.get(UID), 1000000);
});

Deno.test("pending 603: poll endpoint says waiting_approval, re-verifies at most every 10 s, then paid", async () => {
  const w = new World();
  const j = await (await handleCheckout(walletReq("252651111111", "poll-key-0001"), deps(w))).json();
  assertEquals([j.status, j.state, j.poll_after_seconds], ["pending", "waiting_approval", 5]);
  assertStringIncludes(j.message, "approve");
  const before = w.sifaloCalls.length;
  let st = await (await handleCheckout(statusReq(j.purchase_id), deps(w))).json();
  assertEquals(st.state, "waiting_approval");
  assertEquals(w.sifaloCalls.length, before, "no Sifalo call within 10 s of the last check");
  const sid = w.purchases.get(j.purchase_id)!.pending_ref!;
  Object.assign(w.pays.get(sid)!, { status: "success", code: 601 });
  st = await (await handleCheckout(statusReq(j.purchase_id), { ...deps(w), now: () => Date.now() + 11_000 })).json();
  assertEquals([st.status, st.state, st.tokens_added, st.poll_after_seconds], ["paid", "paid", 500000, null]);
  assertEquals(w.credits, 1);
  // another user's token cannot read it
  const other = new Request(`${FN}/billing-checkout?purchase=${j.purchase_id}`, { headers: { authorization: "Bearer nope-nope-nope-nope-nope" } });
  assertEquals((await handleCheckout(other, deps(w))).status, 401);
});

Deno.test("Sifalo codes mapped: 604 insufficient, 600 declined, 0 config, \"404\" rejected, unknown -> pending", async () => {
  assertEquals(Object.keys(SIFALO_CODES).sort(), ["0", "404", "600", "601", "603", "604"]);
  const w = new World();
  const cases: Array<[string, number, string, string]> = [
    ["252644444444", 402, "failed", "insufficient_funds"], ["252622222222", 402, "failed", "declined"],
    ["252600000000", 503, "failed", "provider_config"], ["252640404040", 502, "failed", "provider_rejected"],
    ["252699999999", 202, "pending", "provider_unavailable"],
  ];
  for (const [acct, http, status, error] of cases) {
    const r = await handleCheckout(walletReq(acct, `code-key-${acct}`), deps(w));
    const j = await r.json();
    assertEquals([r.status, j.status, j.error], [http, status, error], acct);
    assert(typeof j.message === "string" && j.message.length > 10);
    assertEquals(w.purchases.get(j.purchase_id)!.status, status === "failed" ? "failed" : "pending");
  }
  assertStringIncludes((await (await handleCheckout(walletReq("252644444444", "code-key-252644444444"), deps(w))).json()).message, "Not enough balance");
  assertEquals(w.credits, 0);
});

Deno.test("amount tampering: client amount/price ignored, Sifalo is asked for the billing.plans price", async () => {
  const w = new World();
  const j = await (await handleCheckout(walletReq("252621111111", "tamper-key-01", { amount: 0.01, price: 0.01, amount_usd: 0.01, currency: "SLSH" }), deps(w))).json();
  assertEquals(j.amount_usd, 1);
  const charge = chargeCalls(w)[0].body as Record<string, unknown>;
  assertEquals([charge.amount, charge.currency], ["1", "USD"]);
  assertEquals(w.purchases.get(j.purchase_id)!.amount_usd, 1);
  // a verify that reports a lower paid amount never credits
  const { purchase_id } = await startHosted(w, { ...PAYG_5, amount: 1 });
  assertEquals(w.purchases.get(purchase_id)!.amount_usd, 5);
  const low = w.pay(purchase_id, "1");
  assertEquals((await (await handleWebhook(webhookReq(`?purchase=${purchase_id}`, { sid: low, amount: "5" }), deps(w))).json()).outcome, "amount_mismatch");
});

Deno.test("abandoned pendings: reconcile expires after 24 h (after a last verify); paid ones credit; provider down -> kept", async () => {
  const w = new World();
  const dead = await startHosted(w);
  const late = await startHosted(w);
  const down = await startHosted(w);
  const young = await startHosted(w);
  w.pay(late.purchase_id, "1");
  for (const p of [dead, late, down]) age(w, p.purchase_id, 25 * 3600_000);
  age(w, young.purchase_id, 30 * 60_000);
  // the "down" one: Sifalo fails on its order lookup -> never expired while unknown
  const origFetch = w.fetch;
  const deps2: Deps = { ...deps(w), fetch: (i, init) => {
    const b = init?.body ? JSON.parse(String(init.body)) : {};
    if (String(i).endsWith("verify.php") && b.order_id === down.purchase_id) return Promise.resolve(new Response("bad", { status: 503 }));
    return origFetch(i, init);
  } };
  const rc = await (await handleReconcile(cronReq(), deps2)).json();
  const by = (id: string) => rc.results.find((x: { id: string }) => x.id === id)?.outcome;
  assertEquals(by(dead.purchase_id), "expired");
  assertEquals(by(late.purchase_id), "paid");
  assertEquals(by(down.purchase_id), "provider_unavailable");
  assertEquals(by(young.purchase_id), "pending");
  assertEquals(rc.expired, 1);
  assertEquals(w.purchases.get(dead.purchase_id)!.status, "failed");
  assertEquals(w.purchases.get(down.purchase_id)!.status, "pending");
  const st = await (await handleCheckout(statusReq(dead.purchase_id), deps(w))).json();
  assertEquals([st.status, st.state], ["expired", "expired"]);
});

Deno.test("rate limit: more than N checkouts a minute -> 429 rate_limited, no Sifalo call", async () => {
  const w = new World();
  w.perMinute = 3;
  for (let i = 0; i < 3; i++) await startHosted(w);
  const calls = w.sifaloCalls.length;
  const r = await handleCheckout(checkoutReq(PAYG_1, "", "rate-key-0004"), deps(w));
  assertEquals(r.status, 429);
  assertEquals((await r.json()).error, "rate_limited");
  assertEquals(w.sifaloCalls.length, calls);
});

Deno.test("wallet input errors are refused before any purchase row or Sifalo call", async () => {
  const w = new World();
  const a = await handleCheckout(checkoutReq({ ...PAYG_1, method: "wallet", wallet: "mpesa", account: "252621111111" }), deps(w));
  assertEquals([a.status, (await a.json()).error], [400, "unknown_wallet"]);
  const b = await handleCheckout(checkoutReq({ ...PAYG_1, method: "wallet", wallet: "edahab", account: "12" }), deps(w));
  assertEquals([b.status, (await b.json()).error], [400, "bad_wallet_account"]);
  assertEquals(w.writes.length + w.sifaloCalls.length, 0);
});

Deno.test("structured logs: JSON lines, no secrets, wallet numbers masked", async () => {
  LOGS.length = 0;
  const w = new World();
  await handleCheckout(walletReq("252621111111", "log-key-00001"), deps(w));
  await handleCheckout(walletReq("252651111111", "log-key-00002"), deps(w));
  w.faults.push({ on: "verify", kind: "5xx" });
  const { purchase_id } = await startHosted(w);
  await handleWebhook(webhookReq(`?purchase=${purchase_id}`, { sid: "SIDX", authorization: "Bearer leak", api_key: "leak" }), deps(w));
  await handleReconcile(cronReq("wrong"), deps(w));
  assert(LOGS.length >= 5);
  const basic = btoa("user:key");
  for (const line of LOGS) {
    const o = JSON.parse(line);
    assertEquals(o.svc, "billing");
    assert(typeof o.event === "string" && typeof o.level === "string");
    for (const secret of [SVC, USER_TOKEN, basic, CRON, "Bearer leak", "252621111111", "252651111111"]) {
      assert(!line.includes(secret), `log leaks ${secret}: ${line}`);
    }
  }
  assert(LOGS.some((l) => l.includes("****1111")), "masked account logged");
});

Deno.test("reconcile: dedicated BILLING_CRON_SECRET also opens it (AI_CRON_SECRET still works; short one ignored)", async () => {
  const w = new World();
  const env = { ...ENV, BILLING_CRON_SECRET: "billing-cron-secret-0123456789" };
  assertEquals((await handleReconcile(cronReq("billing-cron-secret-0123456789"), deps(w, env))).status, 200);
  assertEquals((await handleReconcile(cronReq(CRON), deps(w, env))).status, 200);
  assertEquals((await handleReconcile(cronReq("nope"), deps(w, env))).status, 401);
  const short = { ...ENV, BILLING_CRON_SECRET: "short" };
  assertEquals((await handleReconcile(cronReq("short"), deps(w, short))).status, 401);
  const onlyBilling: Record<string, string | undefined> = { ...ENV, AI_CRON_SECRET: undefined, BILLING_CRON_SECRET: "billing-cron-secret-0123456789" };
  assertEquals((await handleReconcile(cronReq("billing-cron-secret-0123456789"), deps(w, onlyBilling))).status, 200);
});
