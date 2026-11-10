// Telesia cloud model proxy. The app sends OpenAI-style chat requests with an alias
// (telesia-smart, telesia-fast, telesia-vision, telesia-lite). Routing, keys, quotas and
// metrics are all server-side and edited from the admin dashboard.
import { createClient } from "npm:@supabase/supabase-js@2";

const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SB_SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const db = createClient(SB_URL, SB_SERVICE, { auth: { persistSession: false } });

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info, x-telesia-source, x-telesia-chat, x-telesia-lane",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Expose-Headers": "x-telesia-usage, x-telesia-state, x-telesia-window, x-telesia-bg, server-timing",
};

type Key = { id: string; key: string; cooldown_until: string | null };
type Route = {
  route_id: string; model_ref: string; model: string; vision: boolean; tools: boolean;
  context_window: number; extra_body: Record<string, unknown> | null; healthy: boolean;
  provider: string; base_url: string; keys: Key[];
};
type Alias = { alias: string; max_output_tokens: number; system_hint: string | null; routes: Route[] };
type Config = { settings: Record<string, any>; aliases: Alias[] };

let cache: { at: number; cfg: Config } | null = null;
const localCooldown = new Map<string, number>(); // key id -> until (ms), instant across requests in this isolate
const rr = new Map<string, number>(); // round robin per route

async function config(): Promise<Config> {
  if (cache && Date.now() - cache.at < 60_000) return cache.cfg;
  const { data, error } = await db.rpc("ai_get_config");
  if (error) { if (cache) return cache.cfg; throw new Error("config: " + error.message); }
  cache = { at: Date.now(), cfg: data as Config };
  return cache.cfg;
}

function json(body: unknown, status = 200, extra: Record<string, string> = {}) {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, "content-type": "application/json", ...extra } });
}

function userFromJwt(req: Request): string | null {
  const a = req.headers.get("authorization") ?? "";
  const t = a.replace(/^Bearer\s+/i, "");
  try {
    const p = JSON.parse(atob(t.split(".")[1].replace(/-/g, "+").replace(/_/g, "/")));
    return p.role === "authenticated" && p.sub ? p.sub : null;
  } catch { return null; }
}

// Plan 2.1 part B: bot-run calls this proxy on a user's behalf (their allowance, source 'bot-cloud'). It must carry
// the service-role JWT (checked by the gateway) and the runner's Vault secret (x-telesia-internal), plus x-telesia-user.
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const internalOk = new Map<string, number>(); // secret -> checked until (ms)
async function internalUser(req: Request): Promise<string | null> {
  const sec = req.headers.get("x-telesia-internal") ?? "";
  const u = req.headers.get("x-telesia-user") ?? "";
  if (!sec || !UUID_RE.test(u)) return null;
  const t = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
  // The caller holds this project's service key (same env in every function), or a service-role JWT.
  let service = t.length > 20 && t === SB_SERVICE;
  if (!service) {
    try { service = JSON.parse(atob(t.split(".")[1].replace(/-/g, "+").replace(/_/g, "/"))).role === "service_role"; } catch { service = false; }
  }
  if (!service) return null;
  if ((internalOk.get(sec) ?? 0) < Date.now()) {
    const { data } = await db.rpc("bot_run_check", { p_secret: sec });
    if (data !== true) return null;
    if (internalOk.size > 4) internalOk.clear();
    internalOk.set(sec, Date.now() + 300_000);
  }
  return u.toLowerCase();
}

function today() { return new Date().toISOString().slice(0, 10); }

// Plan 2.4: each user's cap = (admin override or daily_cap_tokens) + active reward bonuses (earned ones limited by
// reward_max_bonus_per_day, admin grants on top). From ai_user_cap(); cached 30 s per user in this isolate.
type Cap = { cap: number; base: number; bonus: number; earned: number; granted: number; max_bonus: number; override: number | null;
  active: { referral?: number; creator?: number; admin_grant?: number } };
const capCache = new Map<string, { at: number; c: Cap }>();
async function capOf(uid: string, s: Record<string, any>): Promise<Cap> {
  const hit = capCache.get(uid);
  if (hit && Date.now() - hit.at < 30_000) return hit.c;
  const dflt = Number(s.daily_cap_tokens ?? 200000);
  let c: Cap = { cap: dflt, base: dflt, bonus: 0, earned: 0, granted: 0, max_bonus: 0, override: null, active: {} };
  try {
    const { data, error } = await db.rpc("ai_user_cap", { p_uid: uid });
    if (!error && data && Number.isFinite(Number(data.cap))) {
      c = { cap: Number(data.cap), base: Number(data.base), bonus: Number(data.bonus ?? 0), earned: Number(data.earned ?? 0), granted: Number(data.granted ?? 0),
        max_bonus: Number(data.max_bonus ?? 0), override: data.override == null ? null : Number(data.override), active: data.active ?? {} };
    }
  } catch { /* fall back to the default cap */ }
  if (capCache.size > 2000) capCache.clear();
  capCache.set(uid, { at: Date.now(), c });
  return c;
}
/** Settings with this user's cap in daily_cap_tokens, so every allowance rule below uses it. */
function withCap(s: Record<string, any>, c: Cap) { return { ...s, daily_cap_tokens: c.cap }; }
/** "+50k today from 2 hires" style facts for /status. */
function bonusOut(c: Cap) {
  return { bonus_tokens: c.bonus, base_tokens: c.base, cap_tokens: c.cap, earned_tokens: c.earned, granted_tokens: c.granted,
    max_bonus: c.max_bonus, referral: Number(c.active.referral ?? 0), creator: Number(c.active.creator ?? 0), admin_grant: Number(c.active.admin_grant ?? 0) };
}

// ---- Billing (MONETIZATION.md section 4: coins, packs, passes). Everything here is gated on ai_settings.billing_enabled;
// while it is off none of these functions is called and every answer is exactly what it was before billing existed.
// The money logic lives in SQL (public.billing_* service-role RPCs, migration 20261020_billing.sql): precheck returns the
// user's entitlements (burn order free -> pass -> packs), consume charges one reply idempotently per request id, and
// live_charge bills a Live heartbeat (free monthly minutes, then 40k weighted per minute). Day = EAT (Africa/Mogadishu).
function billingOn(s: Record<string, any>): boolean { return s.billing_enabled === true || s.billing_enabled === "true"; }
// deno-lint-ignore no-explicit-any
type Ent = Record<string, any>;
function num(v: unknown, d: number): number { const n = Number(v); return v !== null && v !== undefined && v !== "" && Number.isFinite(n) ? n : d; }
function waitLater(p: Promise<unknown>) {
  // deno-lint-ignore no-explicit-any
  (globalThis as any).EdgeRuntime?.waitUntil?.(p);
}

// Precheck cache (3b, load): one billing_precheck per user per few seconds (billing_precheck_cache_ms, default 5000) and one
// in flight per user at a time. A charge marks the entry stale (the next request reads SQL again) but keeps it, with what was
// spent since, as the user's "last known good" for the fallback below (billing_last_good_ms, default 15 min).
type PreEntry = { ent: Ent; at: number; fresh: boolean; spent: number; bgSpent: number };
const preCache = new Map<string, PreEntry>();
const preInflight = new Map<string, Promise<Ent | null | "error">>();
const PRE_CACHE_MAX = 5000;
function rememberEnt(uid: string, ent: Ent) {
  preCache.delete(uid);
  if (preCache.size >= PRE_CACHE_MAX) preCache.delete(preCache.keys().next().value!);
  preCache.set(uid, { ent, at: Date.now(), fresh: true, spent: 0, bgSpent: 0 });
}
function noteSpend(uid: string, cost: number, bg: boolean) {
  const e = preCache.get(uid);
  if (e) { e.fresh = false; e.spent += cost; if (bg) e.bgSpent += cost; }
}
function precheckRpc(uid: string, s: Record<string, any>): Promise<Ent | null | "error"> {
  const running = preInflight.get(uid);
  if (running) return running;
  const p = (async (): Promise<Ent | null | "error"> => {
    try {
      // deno-lint-ignore no-explicit-any
      const { data, error } = await within(Promise.resolve(db.rpc("billing_precheck", { p_uid: uid }) as any), Math.max(300, num(s.billing_precheck_timeout_ms, 4000)), "precheck timeout") as any;
      if (error || !data) return "error";
      if (data.enabled === false) return null;
      if (!Number.isFinite(Number(data.allowance))) return "error";
      return data as Ent;
    } catch { return "error"; }
  })().finally(() => preInflight.delete(uid));
  preInflight.set(uid, p);
  return p;
}
/** Entitlements for this request. null only when SQL itself says billing is off (settings cache lag): then the old daily
 *  allowance applies, exactly as before. When billing_precheck errors or times out the answer is never the generous legacy
 *  allowance: a user whose paid balance was seen recently keeps it (minus what was spent since); everyone else gets the
 *  free tier, Standard models only, measured against today's usage counter (ent.degraded says which). */
async function billingPrecheck(uid: string, s: Record<string, any>, legacy?: () => Promise<{ tokens: number; bg: number }>): Promise<Ent | null> {
  const c = preCache.get(uid);
  if (c && c.fresh && Date.now() - c.at < Math.max(0, Math.min(60_000, num(s.billing_precheck_cache_ms, 5000)))) return c.ent;
  const r = await precheckRpc(uid, s);
  if (r === null) return null;
  if (r !== "error") { rememberEnt(uid, r); return r; }
  return await billingFallback(uid, s, legacy);
}
async function billingFallback(uid: string, s: Record<string, any>, legacy?: () => Promise<{ tokens: number; bg: number }>): Promise<Ent> {
  const c = preCache.get(uid);
  const age = c ? Date.now() - c.at : -1;
  console.error(JSON.stringify({ evt: "billing_precheck_failed", uid, last_good_age_ms: age }));
  if (c && age < num(s.billing_last_good_ms, 15 * 60_000) && c.ent.paid === true) {
    const allowance = Math.max(0, num(c.ent.allowance, 0) - c.spent);
    const bg = Math.max(0, Math.min(allowance, num(c.ent.bg_allowance, 0) - c.bgSpent));
    return { ...c.ent, allowance, bg_allowance: bg, used_today: num(c.ent.used_today, 0) + c.spent, state: allowance <= 0 ? "limit" : String(c.ent.state ?? "ok"),
      live_seconds_left: Math.max(0, num(c.ent.live_seconds_left, 0) - Math.floor(age / 1000)), degraded: "last_good" };
  }
  const daily = Math.max(0, num(s.billing_free_daily_tokens, 60000));
  const share = Math.max(0, Math.min(1, num(s.background_share, 0.3)));
  let used = 0, bgUsed = 0, unknown = false;
  try { const u = legacy ? await legacy() : await usageOf(uid); used = u.tokens; bgUsed = u.bg; } catch { unknown = true; }
  if (c && c.ent.paid !== true) { used = Math.max(used, num(c.ent.used_today, 0) + c.spent); }
  const allowance = unknown ? 0 : Math.max(0, daily - used);
  const bgAllow = unknown ? 0 : Math.max(0, Math.min(allowance, Math.floor(daily * share) - bgUsed));
  return { enabled: true, degraded: "free_fallback", unknown, paid: false, allowance, bg_allowance: bgAllow, used_today: used,
    ratio: allowance <= 0 ? 1 : Math.round((used / Math.max(1, used + allowance)) * 1000) / 1000, state: allowance <= 0 ? "limit" : "ok",
    coins: num(c?.ent.coins, 0), free: { daily, left: allowance, bg_left: bgAllow }, pass: null, pass_left: 0, pass_today_left: 0, packs: [], pack_left: 0,
    queued_passes: [], live_seconds_left: 0, tokens_per_reply: num(c?.ent.tokens_per_reply, 3700), day: null };
}

type Mult = { pattern: string; tier: string; multiplier: number; re: RegExp | null };
let multCache: { at: number; rows: Mult[] } | null = null;
// Used only while billing_multipliers has never answered in this isolate: the migration's seed rows, so a free user is
// never routed to an Advanced model because the tier table could not be read.
const SEED_MULT: Mult[] = [["*", "standard", 1], ["gemini-3.6-flash", "advanced", 2.5], ["gemini-3-flash-preview", "advanced", 2.5], ["gemini-3.8-flash", "advanced", 2.5]]
  .map(([pattern, tier, multiplier]) => ({ pattern: String(pattern), tier: String(tier), multiplier: Number(multiplier), re: null }));
/** Model multipliers (billing.model_multipliers, rows in effect today), cached 60 s like the config. */
async function multipliers(): Promise<Mult[]> {
  if (multCache && Date.now() - multCache.at < 60_000) return multCache.rows;
  try {
    const { data, error } = await db.rpc("billing_multipliers");
    if (!error && Array.isArray(data?.rows)) {
      const rows: Mult[] = data.rows.map((r: any) => ({ pattern: String(r.pattern), tier: String(r.tier), multiplier: Number(r.multiplier) || 1,
        re: String(r.pattern).includes("%") ? new RegExp("^" + String(r.pattern).split("%").map((p) => p.replace(/[.*+?^${}()|[\]\\]/g, "\\$&").replace(/_/g, ".")).join(".*") + "$") : null }));
      multCache = { at: Date.now(), rows };
    }
  } catch { /* keep the last copy */ }
  return multCache?.rows ?? SEED_MULT;
}
/** Same pick as billing.multiplier_for(): exact model id, then the longest LIKE pattern, then '*'. Unknown = Standard 1x. */
function tierOf(model: string, rows: Mult[]): { tier: string; multiplier: number } {
  let best: Mult | null = null; let rank = -1;
  for (const m of rows) {
    const r = m.pattern === model ? 1_000_000 : (m.re && m.re.test(model)) ? 1000 + m.pattern.length : m.pattern === "*" ? 0 : -1;
    if (r >= 0 && r >= rank) { rank = r; best = m; } // ties: rows come oldest first, so the newest effective_from wins
  }
  return best ? { tier: best.tier, multiplier: best.multiplier } : { tier: "standard", multiplier: 1 };
}

// Charges (3b, never lost): billing_consume, retried once; then parked in billing.consume_retry (billing_consume_enqueue,
// drained idempotently by billing_consume_retry_drain / billing_reconcile_usage); if even that fails the charge waits in this
// isolate (retried on later requests) and is logged in full as `billing_unsaved` so it can be replayed by hand.
type ChargeArgs = { p_uid: string; p_request_id: string; p_weighted: number; p_model: string; p_source: string; p_lane: string; p_multiplier: number | null };
const unsaved: ChargeArgs[] = [];
let lastFlush = 0;
async function consumeOnce(a: ChargeArgs, s: Record<string, any>): Promise<string | null> {
  try {
    // deno-lint-ignore no-explicit-any
    const { data, error } = await within(Promise.resolve(db.rpc("billing_consume", a) as any), Math.max(500, num(s.billing_consume_timeout_ms, 8000)), "consume timeout") as any;
    if (error) return String(error.message ?? error).slice(0, 200) || "error";
    if (Number(data?.unpaid_tokens) > 0) {
      // The reply cost more than was left (bounded by the max_tokens cap below). SQL logs it in billing.consumption; never billed.
      console.warn(JSON.stringify({ evt: "billing_unpaid", uid: a.p_uid, request_id: a.p_request_id, model: a.p_model,
        charged_tokens: Number(data.charged_tokens ?? 0), unpaid_tokens: Number(data.unpaid_tokens) }));
    }
    return null;
  } catch (e) { return String(e).slice(0, 200); }
}
async function enqueueCharge(a: ChargeArgs, err: string): Promise<boolean> {
  try {
    // deno-lint-ignore no-explicit-any
    const { data, error } = await within(Promise.resolve(db.rpc("billing_consume_enqueue", { ...a, p_error: err }) as any), 5000, "enqueue timeout") as any;
    return !error && !!data && (data.queued === true || data.reason === "already_charged");
  } catch { return false; }
}
function keepUnsaved(a: ChargeArgs, err: string) {
  if (unsaved.length >= 1000) console.error(JSON.stringify({ evt: "billing_lost", ...unsaved.shift() }));
  unsaved.push(a);
  console.error(JSON.stringify({ evt: "billing_unsaved", ...a, error: err }));
}
/** Retries charges this isolate could not write anywhere (at most 20, at most every 10 s). */
function flushUnsaved(s: Record<string, any>) {
  if (!unsaved.length || Date.now() - lastFlush < 10_000) return;
  lastFlush = Date.now();
  const batch = unsaved.splice(0, 20);
  waitLater((async () => {
    for (const a of batch) {
      const err = await consumeOnce(a, s);
      if (err !== null && !(await enqueueCharge(a, err))) unsaved.push(a);
    }
  })().catch(() => {}));
}
/** Charges one finished reply. Weighted = the allowance cost (quotaOf); SQL applies the model multiplier from p_model.
 *  The request id is minted here per request, so a retry of this call can never charge twice. `cost` (weighted x multiplier)
 *  only updates the local precheck cache. */
function billingCharge(uid: string, rid: string, weighted: number, model: string, source: string, lane: string, multiplier: number | null = null,
  s: Record<string, any> = {}, cost = 0) {
  const w = Math.max(0, Math.ceil(Number(weighted) || 0));
  if (!rid || w <= 0) return;
  noteSpend(uid, cost > 0 ? cost : w, lane === "background");
  const a: ChargeArgs = { p_uid: uid, p_request_id: rid, p_weighted: w, p_model: model, p_source: source, p_lane: lane, p_multiplier: multiplier };
  waitLater((async () => {
    let err = "";
    for (let i = 0; i < 2; i++) {
      const e = await consumeOnce(a, s);
      if (e === null) return;
      err = e;
      if (i === 0) await new Promise((ok) => setTimeout(ok, Math.max(0, num(s.billing_retry_delay_ms, 200))));
    }
    if (await enqueueCharge(a, err)) { console.warn(JSON.stringify({ evt: "billing_queued", uid, request_id: rid, error: err })); return; }
    keepUnsaved(a, err);
  })().catch(() => {}));
}
/** Allowance state from entitlements, shaped like stateFor() so the headers keep their meaning. */
function billState(e: Ent, extraUsed = 0) {
  const allowance = Math.max(0, Number(e.allowance ?? 0) - extraUsed);
  const used = Number(e.used_today ?? 0) + extraUsed;
  const ratio = allowance <= 0 ? 1 : Math.min(1, used / Math.max(1, used + allowance));
  return { cap: used + allowance, used, ratio, state: allowance <= 0 ? "limit" : String(e.state ?? "ok"), allowance };
}
const EAT_MS = 3 * 3600_000; // billing day = Africa/Mogadishu (UTC+3, no DST)
/** Next EAT midnight (billing day boundary) as ISO. */
function eatReset(): string {
  const eat = new Date(Date.now() + EAT_MS); eat.setUTCHours(24, 0, 0, 0);
  return new Date(eat.getTime() - EAT_MS).toISOString();
}
/** 00:00 EAT on the 1st of next month (free monthly cap) as ISO. */
function eatMonthReset(): string {
  const eat = new Date(Date.now() + EAT_MS);
  return new Date(Date.UTC(eat.getUTCFullYear(), eat.getUTCMonth() + 1, 1) - EAT_MS).toISOString();
}
function inWords(iso: string): string {
  const m = Math.max(1, Math.round((Date.parse(iso) - Date.now()) / 60_000));
  if (m >= 48 * 60) return `${Math.round(m / 1440)} days`;
  const h = Math.floor(m / 60), mm = m % 60;
  return h ? (mm ? `${h} h ${mm} min` : `${h} h`) : `${mm} min`;
}
const BAL_EXPOSE = CORS["Access-Control-Expose-Headers"] + ", x-telesia-balance";
function balHdr(n: number): Record<string, string> {
  return { "x-telesia-balance": String(Math.max(0, Math.floor(n))), "Access-Control-Expose-Headers": BAL_EXPOSE };
}
// What the app can offer on a limit screen (product ids from billing.products; prices come from the app's catalog).
const BUY_OPTIONS = [
  { product: "pass_day", kind: "pass", name: "Day pass" }, { product: "pass_week", kind: "pass", name: "Week pass" },
  { product: "pass_starter", kind: "pass", name: "Starter pass" }, { product: "pack_1m", kind: "pack", name: "1M pack" },
];
function billingOut(e: Ent, s: Record<string, any> = {}) {
  const month = e.paid !== true && e.free && Number(e.free.monthly) > 0 && Number(e.free.month_used ?? 0) >= Number(e.free.monthly);
  const resets = month ? eatMonthReset() : eatReset();
  return { enabled: true, allowance: Number(e.allowance ?? 0), bg_allowance: Number(e.bg_allowance ?? 0), used_today: Number(e.used_today ?? 0),
    ratio: Number(e.ratio ?? 0), state: e.state ?? "ok", paid: e.paid === true, coins: Number(e.coins ?? 0), free: e.free ?? null, pass: e.pass ?? null,
    pass_left: Number(e.pass_left ?? 0), pass_today_left: Number(e.pass_today_left ?? 0), packs: e.packs ?? [], pack_left: Number(e.pack_left ?? 0),
    queued_passes: e.queued_passes ?? [], live_seconds_left: Number(e.live_seconds_left ?? 0), tokens_per_reply: Number(e.tokens_per_reply ?? 3700),
    auto_exchange: e.auto_exchange === true, day: e.day ?? null, resets_at: resets, resets_at_eat: month ? "1st of next month, 00:00 EAT" : "00:00 EAT",
    resets_in_seconds: Math.max(0, Math.round((Date.parse(resets) - Date.now()) / 1000)), degraded: e.degraded ?? null,
    buy: Array.isArray(s.billing_buy_options) ? s.billing_buy_options : BUY_OPTIONS };
}
/** Every billing refusal has the same shape: {error: {code, message}, message, billing: {..., reason}} (+ extras). */
function billErr(status: number, code: string, message: string, e: Ent, s: Record<string, any>, reason: string,
  more: Record<string, unknown> = {}, hdrs: Record<string, string> = {}, balance = 0) {
  return json({ error: { code, message }, message, billing: { ...billingOut(e, s), reason }, ...more }, status, { ...balHdr(balance), ...hdrs });
}
/** daily_limit: why the balance is empty, when it comes back (EAT) and what to buy. */
function limitReply(e: Ent, s: Record<string, any>, hdrs: Record<string, string> = {}) {
  const out = billingOut(e, s);
  let reason: string, msg: string;
  if (e.paid !== true && out.resets_at_eat !== "00:00 EAT") {
    reason = "free_month_used";
    msg = "You've used this month's free allowance. It comes back on the 1st at 00:00 EAT. Get a pass or a token pack to keep going now.";
  } else if (e.paid !== true) {
    reason = "free_day_used";
    msg = `You've used today's free allowance. It comes back at midnight (00:00 EAT), in about ${inWords(out.resets_at)}. Get a pass or a token pack to keep going now.`;
  } else {
    reason = "pass_day_used";
    msg = `You've reached today's limit on your ${String(e.pass?.name ?? "pass")}. It resets at midnight (00:00 EAT), in about ${inWords(out.resets_at)}. A token pack keeps you going now.`;
  }
  if (Number(e.coins ?? 0) > 0) msg += ` You have ${Number(e.coins)} coins: turn them into a pass or a pack in your wallet.`;
  if (e.degraded === "free_fallback") msg += " (We couldn't confirm a pass or pack just now. If you have one, try again in a minute.)";
  if (typeof s.billing_limit_message === "string" && s.billing_limit_message) msg = s.billing_limit_message;
  return billErr(429, "daily_limit", msg, e, s, reason, {}, hdrs);
}
/** Out of balance: a payment made in the last few minutes that is still being confirmed gets its own answer. */
async function pendingPayment(uid: string, s: Record<string, any>): Promise<{ id: string; created_at: string } | null> {
  try {
    // deno-lint-ignore no-explicit-any
    const { data, error } = await within(Promise.resolve(db.rpc("billing_pending_purchases", { p_since_hours: 1, p_uid: uid, p_limit: 5 }) as any), 2000, "pending timeout") as any;
    if (error || !Array.isArray(data)) return null;
    const win = num(s.billing_pending_window_min, 30) * 60_000;
    return data.filter((p: any) => Date.now() - Date.parse(p.created_at) < win).pop() ?? null;
  } catch { return null; }
}
const PENDING_MSG = "Your payment is still being confirmed. This usually takes a minute or two, and your balance updates as soon as it's confirmed. If you didn't finish paying, you can try again from your wallet.";
/** The refusal for an empty balance: payments_pending when a recent payment is still being confirmed, else daily_limit. */
async function emptyReply(uid: string, e: Ent, s: Record<string, any>, hdrs: Record<string, string> = {}): Promise<Response> {
  if (e.unknown) {
    return billErr(503, "busy", "Couldn't check your balance just now. Please try again in a moment.", e, s, "billing_unavailable", {}, { ...hdrs, "Retry-After": "20" });
  }
  const p = e.degraded ? null : await pendingPayment(uid, s);
  if (p) {
    return billErr(429, "payments_pending", PENDING_MSG, e, s, "payment_confirming", { pending: { purchase_id: p.id, created_at: p.created_at }, retry_after_seconds: 30 },
      { ...hdrs, "Retry-After": "30" });
  }
  return limitReply(e, s, hdrs);
}
/** Largest reply (output tokens) the balance pays for on a model with this multiplier, never below a small floor so the
 *  last reply is still useful: overspend is bounded by about (floor + prompt) x multiplier, logged as unpaid_tokens. */
function replyCap(balance: number, mult: number, promptTokens: number, s: Record<string, any>): number {
  const wIn = num(s.input_weight, 0.3), wOut = Math.max(0.01, num(s.output_weight, 1));
  const room = Math.floor((balance / Math.max(0.01, mult) - promptTokens * wIn) / wOut);
  return Math.max(Math.max(1, num(s.billing_min_reply_tokens, 512)), room);
}
const NO_BALANCE = "You've used your allowance for now. Get a pass or a token pack to keep going, or wait for tomorrow's free allowance.";
const CALL_BALANCE = "Your call time is used up. Get a pass or a token pack to keep calling. You can still type to Telesia.";
const BG_PAUSED = "Background tasks are paused until midnight (00:00 EAT) to save your allowance. Your own chats still work.";
const PAID_MODEL = "This model needs a pass or a token pack. Standard models stay free.";
// Live: seconds remembered from the last successful charge, used only when billing_live_charge is down (never cut a call).
const liveLeftCache = new Map<string, { left: number; at: number }>();
function liveLeftGuess(uid: string, s: Record<string, any>): number {
  const c = liveLeftCache.get(uid);
  const grace = Math.max(60, num(s.billing_live_grace_seconds, 300));
  if (!c) return grace;
  return Math.max(grace, c.left - Math.floor((Date.now() - c.at) / 1000));
}

// ---- Safety flags (admin Users section). Never stores chat text: a cheap keyword screen on the newest user message;
// on a hit, a small telesia-fast check confirms it and only {category, severity, short reason} is saved via flag_user. ----
const SCREEN: [string, RegExp][] = [
  ["minor_sexual", /\b(child|children|minor|underage|kid|kids|preteen|\d{1,2}[ -]?(?:yo|y\/o|years?[ -]old))\b[\s\S]{0,80}\b(sex|sexual|nude|naked|porn|explicit|erotic)|\b(sex|sexual|nude|naked|porn|explicit|erotic)\b[\s\S]{0,80}\b(child|children|minor|underage|kid|kids|preteen|\d{1,2}[ -]?(?:yo|y\/o|years?[ -]old))\b/i],
  ["fraud_scam", /\b(phishing|scam (?:people|someone|victims|them)|fake (?:invoice|bank|id|passport|login page|receipt|reviews?)|steal (?:credit cards?|cards?|passwords?|accounts?|identit(?:y|ies))|carding|cvv|money mule|launder(?:ing)? (?:the )?money|ponzi|pump and dump|sim swap)\b/i],
  ["illegal", /\b(make (?:a )?(?:bomb|explosives?|meth|methamphetamine|ricin)|buy (?:drugs|cocaine|heroin|fentanyl)|untraceable (?:gun|weapon)|ghost gun|hire (?:a )?hit ?man|human trafficking|smuggl(?:e|ing) (?:people|drugs))\b/i],
  ["abuse_harassment", /\b(dox(?:x)?(?:ing)?|threaten(?:ing)? to (?:kill|hurt|rape)|i will (?:kill|hurt|rape) (?:you|him|her|them)|harass(?:ment)? campaign|revenge porn|stalk(?:ing)? (?:my ex|her|him))\b/i],
  ["self_harm", /\b(kill myself|suicid(?:e|al)|end my life|self[- ]harm|cut myself|want to die)\b/i],
  ["spam_automation", /\b(mass (?:dm|dms|message|messages|email|emails)|spam (?:bot|messages|people)|bulk (?:sms|email)s?|fake (?:accounts|followers|likes) (?:bot|farm))\b/i],
];
const CATS = ["fraud_scam", "illegal", "abuse_harassment", "minor_sexual", "self_harm", "spam_automation"];
const lastScreen = new Map<string, number>();
function lastUserText(messages: any[]): string {
  for (let i = messages.length - 1; i >= 0; i--) {
    const m = messages[i];
    if (m?.role !== "user") continue;
    if (typeof m.content === "string") return m.content.slice(0, 4000);
    if (Array.isArray(m.content)) return m.content.filter((c: any) => c?.type === "text").map((c: any) => String(c.text ?? "")).join(" ").slice(0, 4000);
    return "";
  }
  return "";
}
function screenLater(uid: string, messages: any[], cfg: Config) {
  const s = cfg.settings;
  if (s.moderation_enabled === false) return;
  const text = lastUserText(messages);
  if (text.length < 8) return;
  const hit = SCREEN.find(([, re]) => re.test(text));
  if (!hit) return;
  if ((lastScreen.get(uid) ?? 0) > Date.now() - 20_000) return;
  if (lastScreen.size > 5000) lastScreen.clear();
  lastScreen.set(uid, Date.now());
  const job = (async () => {
    let cat = hit[0], sev = cat === "minor_sexual" ? "high" : "low", reason = "Keyword screen: possible " + cat.replace("_", " ");
    if (s.moderation_model_check !== false) {
      const v = await classify(text, cfg);
      if (v === null) { /* model unavailable: keep the keyword flag */ }
      else if (v.category === "none") return;
      else { cat = v.category; sev = v.severity; reason = v.reason; }
    }
    await db.rpc("flag_user", { p_uid: uid, p_category: cat, p_severity: sev, p_source: "moderation", p_reason: reason.slice(0, 200), p_meta: { rule: hit[0] } });
  })().catch(() => {});
  // deno-lint-ignore no-explicit-any
  (globalThis as any).EdgeRuntime?.waitUntil?.(job);
}
async function classify(text: string, cfg: Config): Promise<{ category: string; severity: string; reason: string } | null> {
  const alias = cfg.aliases.find((a) => a.alias === "telesia-fast") ?? cfg.aliases.find((a) => a.alias === "telesia-lite");
  if (!alias) return null;
  const sys = "You are a safety reviewer for an AI assistant app. Decide if the user's message asks for or describes: fraud_scam, illegal (serious crime, weapons, drugs), " +
    "abuse_harassment, minor_sexual (any sexual content involving minors), self_harm (the user may hurt themselves), spam_automation, or none. " +
    "Ordinary questions, fiction, news, safety advice and victims asking for help are none. Reply with JSON only: " +
    '{"category":"<one of the labels>","severity":"low|medium|high","reason":"<at most 12 words describing the behaviour; never quote the message>"}';
  for (const r of alias.routes.filter((x) => x.healthy).concat(alias.routes.filter((x) => !x.healthy)).slice(0, 2)) {
    for (const k of keysInOrder(r).slice(0, 1)) {
      try {
        const ctl = new AbortController(); const t = setTimeout(() => ctl.abort(), 10_000);
        const res = await fetch(r.base_url.replace(/\/$/, "") + "/chat/completions", { method: "POST", signal: ctl.signal,
          headers: { "content-type": "application/json", authorization: `Bearer ${k.key}`, "user-agent": "telesia-proxy/1" },
          body: JSON.stringify({ ...(r.extra_body ?? {}), model: r.model, max_tokens: 120, temperature: 0,
            messages: [{ role: "system", content: sys }, { role: "user", content: text.slice(0, 1500) }] }) });
        clearTimeout(t);
        if (!res.ok) { markKey(k.id, false, `moderation ${res.status}`, cooldownFor(res.status)); continue; }
        const j = await res.json();
        record({ user_id: null, source: "moderation", alias: alias.alias, provider: r.provider, model: r.model, key_id: k.id, status: 200,
          prompt_tokens: j.usage?.prompt_tokens ?? 0, completion_tokens: j.usage?.completion_tokens ?? 0, quota_tokens: 0 });
        const out = String(j.choices?.[0]?.message?.content ?? "");
        const m = out.match(/\{[\s\S]*\}/);
        if (!m) continue;
        const v = JSON.parse(m[0]);
        const category = CATS.includes(v.category) ? v.category : "none";
        const severity = ["low", "medium", "high"].includes(v.severity) ? v.severity : "low";
        return { category, severity: category === "minor_sexual" ? "high" : severity, reason: String(v.reason ?? "").replace(/["“”]/g, "").slice(0, 120) || category };
      } catch { /* next */ }
    }
  }
  return null;
}

async function usageOf(uid: string) {
  const { data } = await db.from("ai_user_daily").select("tokens,requests,bg_tokens").eq("user_id", uid).eq("day", today()).maybeSingle();
  return { tokens: Number(data?.tokens ?? 0), requests: Number(data?.requests ?? 0), bg: Number(data?.bg_tokens ?? 0) };
}

/** Plan 2.2 background lane: bots and offices get background_share (default 0.3) of the daily cap. Their use counts
 *  in the total too; once the share (or the cap) is reached they pause until the next UTC day, while the user's own
 *  chats keep the whole cap and the grace after it. */
function backgroundFor(used: number, bgUsed: number, s: Record<string, any>) {
  const cap = Number(s.daily_cap_tokens ?? 200000);
  let share = Number(s.background_share ?? 0.3);
  if (!Number.isFinite(share)) share = 0.3;
  share = Math.max(0, Math.min(1, share));
  const shareCap = Math.floor(cap * share);
  const left = Math.max(0, Math.min(shareCap - bgUsed, cap - used));
  return { share, cap: shareCap, used: bgUsed, left, ratio: shareCap > 0 ? Math.min(1, bgUsed / shareCap) : 1, paused: left <= 0 };
}

function stateFor(used: number, s: Record<string, any>) {
  const cap = Number(s.daily_cap_tokens ?? 200000);
  const grace = Number(s.grace_tokens ?? 0);
  const soft = Number(s.soft_notice_ratio ?? 0.8);
  const ratio = cap > 0 ? used / cap : 0;
  const state = used >= cap + grace ? "limit" : used >= cap ? "light" : ratio >= soft ? "notice" : "ok";
  return { cap, used, ratio: Math.min(1, ratio), state };
}

function hasImages(messages: any[]): boolean {
  return messages?.some((m) => Array.isArray(m?.content) && m.content.some((c: any) => c?.type === "image_url" || c?.type === "input_image"));
}

const JUNK = /<\s*\/?\s*｜[^>]{0,80}>|<\|(?:tool_call|im_start|im_end|end)[^>\n]{0,40}\|>/g;
function clean(t: string): string { return t.replace(JUNK, ""); }

function estimateTokens(v: unknown): number { return Math.ceil(JSON.stringify(v ?? "").length / 4); }

function cooldownFor(status: number): number {
  if (status === 429) return 60;
  if (status === 401 || status === 403) return 3600;
  if (status === 402) return 6 * 3600;
  if (status >= 500 || status === 0) return 20;
  return 0;
}

/** Prompt tokens the provider served from its cache (OpenAI, Gemini and DeepSeek name it differently). */
function cachedOf(usage: any): number {
  return Number(usage?.prompt_tokens_details?.cached_tokens ?? usage?.cached_tokens ?? usage?.prompt_cache_hit_tokens ?? 0) || 0;
}

/** Allowance cost of a reply: the repeated prompt (system + tools + history) costs less than fresh output, and cached input least. */
function quotaOf(s: Record<string, any>, pt: number, ct: number, usage: any): number {
  const cached = cachedOf(usage);
  const wIn = Number(s.input_weight ?? 0.3), wOut = Number(s.output_weight ?? 1), wCache = Number(s.cached_weight ?? 0.1);
  return Math.ceil(Math.max(0, pt - cached) * wIn + cached * wCache + ct * wOut);
}

function record(p: Record<string, unknown>) {
  const job = db.rpc("ai_record_usage", { p }).then(() => {}, () => {});
  // deno-lint-ignore no-explicit-any
  (globalThis as any).EdgeRuntime?.waitUntil?.(job);
}
function markKey(id: string, ok: boolean, error: string | null, cooldown: number) {
  if (!ok && cooldown > 0) localCooldown.set(id, Date.now() + cooldown * 1000);
  if (ok) localCooldown.delete(id);
  const job = db.rpc("ai_mark_key", { p_key_id: id, p_ok: ok, p_error: error ?? "", p_cooldown_seconds: cooldown }).then(() => {}, () => {});
  // deno-lint-ignore no-explicit-any
  (globalThis as any).EdgeRuntime?.waitUntil?.(job);
}

/** Small stable hash, so the same chat always lands on the same key without any shared state. */
function hashOf(s: string): number {
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619); }
  return h >>> 0;
}

/** Usable keys for a route. With a chat id the starting key is fixed per chat (sticky), so the provider's
 *  prompt cache keeps working across steps; it only moves when that key fails or rests. Otherwise round robin. */
/** Repairs chat history every model would reject: tool calls with broken JSON arguments (a reply cut off
 *  mid-call), calls with no result, and results with no call. One bad step must never fail the whole chat. */
function cleanHistory(list: any[]): any[] {
  const out: any[] = [];
  for (let i = 0; i < list.length; i++) {
    const m = list[i];
    if (!m || typeof m !== "object") continue;
    if (m.role === "assistant" && Array.isArray(m.tool_calls) && m.tool_calls.length) {
      const calls = m.tool_calls.filter((c: any) => c && c.id && c.function?.name).map((c: any) => {
        let a = c.function.arguments;
        if (typeof a !== "string") a = JSON.stringify(a ?? {});
        try { const v = JSON.parse(a.trim() || "{}"); if (!v || typeof v !== "object" || Array.isArray(v)) a = "{}"; else if (!a.trim()) a = "{}"; }
        catch { a = "{}"; }
        return { ...c, type: "function", function: { ...c.function, arguments: a } };
      });
      if (!calls.length) { const { tool_calls: _t, ...rest } = m; if (rest.content) out.push(rest); continue; }
      out.push({ ...m, tool_calls: calls });
      // Each call needs its result right after the assistant turn.
      const ids = new Set(calls.map((c: any) => c.id));
      const results: any[] = [];
      let j = i + 1;
      while (j < list.length && list[j]?.role === "tool") { if (ids.has(list[j].tool_call_id)) { results.push(list[j]); ids.delete(list[j].tool_call_id); } j++; }
      out.push(...results);
      for (const id of ids) out.push({ role: "tool", tool_call_id: id, content: "Not run." });
      i = j - 1;
      continue;
    }
    if (m.role === "tool") continue; // a result with no call in front of it
    out.push(m);
  }
  return out;
}

const routeCap = new Map<string, number>(); // route -> largest max_tokens it accepts (learned from its errors)

function keysInOrder(r: Route, chat = "", anyKey = false): Key[] {
  const now = Date.now();
  const usable = anyKey ? r.keys : r.keys.filter((k) => {
    const lc = localCooldown.get(k.id) ?? 0;
    const dc = k.cooldown_until ? Date.parse(k.cooldown_until) : 0;
    return lc < now && dc < now;
  });
  if (!usable.length) return [];
  let i: number;
  if (chat) {
    i = hashOf(chat + "|" + r.route_id) % usable.length;
  } else {
    i = (rr.get(r.route_id) ?? 0) % usable.length;
    rr.set(r.route_id, i + 1);
  }
  return [...usable.slice(i), ...usable.slice(0, i)];
}

// Never wait on a promise forever: some upstreams hold the connection open without sending anything, and an abort
// signal alone has not always freed the request. Race it against a timer.
function within<T>(p: Promise<T>, ms: number, what: string): Promise<T> {
  let t: ReturnType<typeof setTimeout> | undefined;
  return Promise.race([p, new Promise<T>((_, rej) => { t = setTimeout(() => rej(new Error(what)), ms); })]).finally(() => clearTimeout(t));
}

async function fetchWithFirstByte(url: string, init: RequestInit, ms: number) {
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort("first-byte-timeout"), ms);
  try {
    const res = await within(fetch(url, { ...init, signal: ctl.signal }), ms + 1000, "first-byte-timeout");
    return { res, ctl, timer };
  } catch (e) {
    clearTimeout(timer);
    throw e;
  }
}

function features(cfg: Config) {
  const s = cfg.settings;
  const has = (a: string) => !!cfg.aliases.find((x) => x.alias === a && x.routes.length);
  return {
    live: s.live_enabled !== false && !!s.live_provider,
    transcribe: s.transcribe_enabled !== false && !!s.live_provider,
    image: has("telesia-image"),
    video: false,
    live_voices: ["Kore", "Puck", "Charon", "Aoede", "Fenrir", "Leda", "Orus", "Zephyr"],
  };
}

async function providerKeys(name: string): Promise<{ id: string; key: string }[]> {
  const { data: p } = await db.from("ai_providers").select("id").eq("name", name).eq("enabled", true).maybeSingle();
  if (!p) return [];
  const { data: ks } = await db.from("ai_keys").select("id,cooldown_until").eq("provider_id", p.id).eq("enabled", true);
  const now = Date.now();
  const usable = (ks ?? []).filter((k: any) => !(k.cooldown_until && Date.parse(k.cooldown_until) > now) && (localCooldown.get(k.id) ?? 0) < now);
  usable.sort(() => Math.random() - 0.5);
  const out: { id: string; key: string }[] = [];
  for (const k of usable.slice(0, 4)) {
    const { data } = await db.rpc("ai_key_secret", { p_key_id: k.id });
    if (data?.key) out.push({ id: k.id, key: data.key });
  }
  return out;
}

/** Live pool (live_routes), separate from the chat keys. Lowest priority first; rows with the same priority are
 *  shuffled so they share the load; resting rows are skipped. At most 6 tried per pass. */
async function liveRoutes(): Promise<{ id: string; key: string; model: string | null; provider: string }[]> {
  const { data: rows } = await db.from("live_routes").select("id,provider,model,priority,cooldown_until").eq("enabled", true);
  const now = Date.now();
  const usable = (rows ?? []).filter((r: any) => r.provider === "Google Gemini" &&
    !(r.cooldown_until && Date.parse(r.cooldown_until) > now) && (localCooldown.get("live:" + r.id) ?? 0) < now)
    .map((r: any) => ({ r, k: Math.random() })).sort((a, b) => (a.r.priority - b.r.priority) || (a.k - b.k)).map((x) => x.r);
  const out: { id: string; key: string; model: string | null; provider: string }[] = [];
  for (const r of usable.slice(0, 6)) {
    const { data } = await db.rpc("live_route_secret", { p_id: r.id });
    if (data?.key) out.push({ id: r.id, key: data.key, model: r.model ?? null, provider: r.provider });
  }
  return out;
}
/** Rest for a failed Live pass: a spent quota rests an hour, a rate limit a minute, a bad key an hour. */
function liveCooldown(status: number, text: string): number {
  if (status === 429) return /quota|exhaust|per day|daily/i.test(text) ? 3600 : 60;
  if (status === 400 && /api key|API_KEY/i.test(text)) return 3600;
  return cooldownFor(status);
}
function markLive(id: string, ok: boolean, error: string | null, cooldown: number) {
  if (!ok && cooldown > 0) localCooldown.set("live:" + id, Date.now() + cooldown * 1000);
  if (ok) localCooldown.delete("live:" + id);
  const job = db.rpc("live_mark_route", { p_id: id, p_ok: ok, p_error: error ?? "", p_cooldown_seconds: cooldown }).then(() => {}, () => {});
  // deno-lint-ignore no-explicit-any
  (globalThis as any).EdgeRuntime?.waitUntil?.(job);
}

// ---- Call minutes (Plan 6 item 3) ----
type Mins = { ok?: boolean; reason?: string; call_id?: string; enabled?: boolean; limit_minutes?: number; used_seconds?: number;
  seconds_left?: number; minutes_left?: number; resets_at?: string; stop?: boolean; call_seconds?: number; added_seconds?: number };
const HEARTBEAT_S = 30;
function numOrNull(v: unknown): number | null { const n = Number(v); return Number.isFinite(n) && n >= 0 ? Math.floor(Math.min(n, 86400)) : null; }
function minutesUsedMessage() { return "Today's call minutes are used up. They come back at midnight UTC. You can still type to Telesia."; }
/** The minute fields every Live answer carries. */
function minsOut(m: Mins) {
  return { minutes_left: Number(m.minutes_left ?? 0), seconds_left: Number(m.seconds_left ?? 0), limit_minutes: Number(m.limit_minutes ?? 0),
    used_seconds: Number(m.used_seconds ?? 0), live_enabled: m.enabled !== false, resets_at: m.resets_at ?? null };
}
async function minutesOf(uid: string) {
  const { data } = await db.rpc("live_minutes_left", { p_uid: uid });
  return (data ?? {}) as Mins;
}
/** POST /live-usage {call_id, seconds, end?}: the app's heartbeat (every 30 s while connected, once when the
 *  line connects with seconds 0, and once on hang-up with end: true). The server counts its own time between
 *  heartbeats (at most 120 s per gap); the app's count can only fill a longer gap, never pass the wall time. */
async function liveUsage(uid: string, body: any, billing = false, s: Record<string, any> = {}): Promise<Response> {
  const cid = typeof body?.call_id === "string" ? body.call_id : "";
  if (!cid) return json({ error: { code: "bad_request", message: "call_id needed" } }, 400);
  const { data, error } = await db.rpc("live_call_beat", { p_uid: uid, p_call: cid, p_reported: numOrNull(body.seconds), p_kind: body?.end === true ? "end" : "beat" });
  if (error) return json({ error: { code: "busy", message: "Couldn't save call time just now." } }, 503);
  const m = data as Mins;
  if (billing) {
    // Billing on: the call is paid from the billing balance; the old daily minutes (live_call_daily) are only counted.
    const charged = m.reason === "no_call" ? null : await liveCharge(uid, cid, m);
    if (charged === "error") {
      // billing_live_charge is down: never cut the call for it. The seconds stay on the call row and are billed later by
      // billing_live_reconcile; the time shown is the last known balance (or a grace) so the app does not hang up either.
      const guess = liveLeftGuess(uid, s);
      return json({ ok: m.ok !== false, reason: m.reason ?? null, call_id: cid, call_seconds: Number(m.call_seconds ?? 0), added_seconds: Number(m.added_seconds ?? 0),
        stop: m.enabled === false && body?.end !== true, ...liveMinsOut(m, guess), billing_degraded: true,
        message: m.enabled === false && body?.end !== true ? minutesUsedMessage() : null }, 200, balHdr(guess));
    }
    const left = charged;
    if (left !== null) {
      const ending = body?.end === true;
      const stop = !ending && (m.enabled === false || left <= 0);
      return json({ ok: m.ok !== false, reason: m.reason ?? null, call_id: cid, call_seconds: Number(m.call_seconds ?? 0), added_seconds: Number(m.added_seconds ?? 0),
        stop, ...liveMinsOut(m, left), message: stop ? (m.enabled === false ? minutesUsedMessage() : CALL_BALANCE) : null }, 200, balHdr(left));
    }
    // billing_live_charge unavailable: answer as before, but never stop a call on the old daily limit.
    return json({ ok: m.ok !== false, reason: m.reason ?? null, call_id: cid, call_seconds: Number(m.call_seconds ?? 0), added_seconds: Number(m.added_seconds ?? 0),
      stop: m.enabled === false && body?.end !== true, ...minsOut(m), message: null }, m.reason === "no_call" ? 404 : 200);
  }
  return json({ ok: m.ok !== false, reason: m.reason ?? null, call_id: cid, call_seconds: Number(m.call_seconds ?? 0), added_seconds: Number(m.added_seconds ?? 0),
    stop: m.stop === true || (m.enabled === false && body?.end !== true), ...minsOut(m), message: m.stop ? minutesUsedMessage() : null }, m.reason === "no_call" ? 404 : 200);
}

/** Billing on: charges the seconds a heartbeat added (idempotent per call + call_seconds) and returns the Live seconds
 *  the balance still covers; null when SQL says billing is off; "error" when the charge could not be made (tried twice). */
async function liveCharge(uid: string, callId: string, m: Mins): Promise<number | null | "error"> {
  for (let i = 0; i < 2; i++) {
    // deno-lint-ignore no-explicit-any
    const { data, error } = await within(Promise.resolve(db.rpc("billing_live_charge", { p_uid: uid, p_call: callId, p_call_seconds: Number(m.call_seconds ?? 0),
      p_added_seconds: Number(m.added_seconds ?? 0) }) as any), 5000, "live charge timeout").then((x: any) => x, (e: unknown) => ({ data: null, error: e }));
    if (!error && data && data.enabled !== false && Number.isFinite(Number(data.live_seconds_left))) {
      const left = Math.max(0, Number(data.live_seconds_left));
      liveLeftCache.delete(uid);
      if (liveLeftCache.size >= PRE_CACHE_MAX) liveLeftCache.delete(liveLeftCache.keys().next().value!);
      liveLeftCache.set(uid, { left, at: Date.now() });
      return left;
    }
    if (!error && data?.enabled === false) return null;
  }
  return "error";
}
/** minsOut() with the time left taken from the billing balance (limit_minutes = what is left now). */
function liveMinsOut(m: Mins, left: number) {
  return { ...minsOut(m), minutes_left: Math.floor(left / 60), seconds_left: left, limit_minutes: Math.floor(left / 60), billing: true };
}

async function mediaRoute(req: Request, url: URL, uid: string, cfg: Config): Promise<Response> {
  const s = cfg.settings;
  if (s.kill_switch === true) return json({ error: { code: "paused", message: "Telesia is taking a short break. Please try again in a few minutes." } }, 503);
  const { data: blocked } = await db.from("ai_blocked_users").select("user_id").eq("user_id", uid).maybeSingle();
  if (blocked) return json({ error: { code: "blocked", message: "Your account needs attention. Please contact support." } }, 403);
  const feat = features(cfg);
  const t0 = Date.now();
  let body: any = {};
  try { body = await req.json(); } catch { /* empty */ }

  // Live calls are counted in call minutes (live_call_daily), not in the token allowance.
  const bill = billingOn(s);
  if (url.pathname.endsWith("/live-usage")) return await liveUsage(uid, body, bill, s);

  if (url.pathname.endsWith("/live-token")) {
    if (!feat.live) return json({ error: { code: "unavailable", message: "Live voice isn't available right now." } }, 503);
    // resume + call_id: a new line inside a call that is still going (goAway or a drop). Anything else is a new call.
    const resume = body?.resume === true && typeof body?.call_id === "string" && body.call_id.length > 0;
    let mins: Mins;
    // Billing on: the time left comes from the billing balance (free monthly minutes, then 40k weighted per minute),
    // not the old daily minutes. live_call_start / live_call_beat are unchanged and still keep the call rows.
    let billLeft: number | null = null;
    let liveEnt: Ent | null = null;
    if (resume) {
      const { data, error } = await db.rpc("live_call_beat", { p_uid: uid, p_call: body.call_id, p_reported: numOrNull(body.seconds), p_kind: "resume" });
      if (error) return json({ error: { code: "busy", message: "Live voice is busy right now. Please try again in a moment." } }, 503);
      mins = data as Mins;
      if (!mins.ok) return json({ error: { code: "call_ended", message: "This call has ended. Tap Call again to start a new one." }, ...minsOut(mins) }, 409);
      if (bill) {
        const c = await liveCharge(uid, String(body.call_id), mins);
        // A charge outage never ends a call that is going: the reconnect gets the last known time (or a grace).
        billLeft = c === "error" ? liveLeftGuess(uid, s) : c;
      }
    } else {
      const [{ data, error }, ent0] = await Promise.all([db.rpc("live_call_start", { p_uid: uid }), bill ? billingPrecheck(uid, s) : Promise.resolve(null)]);
      if (error) return json({ error: { code: "busy", message: "Live voice is busy right now. Please try again in a moment." } }, 503);
      mins = data as Mins;
      // Precheck down and no recent paid balance: the old call minutes decide (conservative), never a guessed balance.
      const ent = ent0 && ent0.degraded === "free_fallback" ? null : ent0;
      liveEnt = ent;
      if (ent) {
        billLeft = Math.max(0, Number(ent.live_seconds_left ?? 0));
        // live_call_start refuses once the old daily minutes are used; with billing on that limit no longer applies,
        // so the call row is opened here instead (same row live_call_start would insert).
        if (mins.ok === false && mins.reason === "minutes_used" && mins.enabled !== false && billLeft > 0) {
          const { data: row, error: e2 } = await db.from("live_calls").insert({ user_id: uid }).select("id").single();
          if (e2 || !row?.id) return json({ error: { code: "busy", message: "Live voice is busy right now. Please try again in a moment." } }, 503);
          mins = { ...mins, ok: true, call_id: row.id };
        }
      }
    }
    if (mins.enabled === false) return json({ error: { code: "live_off", message: "Calls are switched off for your account. You can still type to Telesia." }, ...minsOut(mins), minutes_left: 0, seconds_left: 0 }, 429);
    if (billLeft !== null) {
      if (billLeft <= 0) {
        // A new call opened by live_call_start that the balance can't pay for is closed with nothing counted.
        if (!resume && mins.call_id) await db.rpc("live_call_beat", { p_uid: uid, p_call: mins.call_id, p_reported: 0, p_kind: "end" });
        if (liveEnt) {
          const p = liveEnt.degraded ? null : await pendingPayment(uid, s);
          if (p) return billErr(429, "payments_pending", PENDING_MSG, liveEnt, s, "payment_confirming", { ...liveMinsOut(mins, 0), pending: { purchase_id: p.id, created_at: p.created_at }, retry_after_seconds: 30 }, { "Retry-After": "30" });
          return billErr(429, "call_minutes", CALL_BALANCE, liveEnt, s, "live_balance_used", liveMinsOut(mins, 0));
        }
        return json({ error: { code: "call_minutes", message: CALL_BALANCE }, message: CALL_BALANCE, ...liveMinsOut(mins, 0) }, 429, balHdr(0));
      }
      mins = { ...mins, seconds_left: billLeft, minutes_left: Math.floor(billLeft / 60) };
    } else if (Number(mins.seconds_left) <= 0) return json({ error: { code: "call_minutes", message: minutesUsedMessage() }, ...minsOut(mins), minutes_left: 0, seconds_left: 0 }, 429);
    const callId = String(mins.call_id ?? body.call_id ?? "");
    const defModel = String(s.live_model ?? "gemini-3.8-live");
    // The pass ends with today's minutes (plus a minute of grace), so the line itself stops at the limit.
    const sessionMins = Number(s.live_session_minutes ?? 15);
    const passSecs = Math.max(60, Math.min(sessionMins * 60, Number(mins.seconds_left) + 60));
    // Live has its own pool (live_routes): never the chat keys, and failures here never touch ai_keys.
    for (const lr of await liveRoutes()) {
      const model = lr.model || defModel;
      const exp = new Date(Date.now() + passSecs * 1000).toISOString();
      // newSessionExpireTime: the pass must be opened within 3 min (covers a slow setup); expireTime bounds this connection.
      // Single use: every reconnect (goAway about every 10 min, or a drop) asks for a fresh pass with resume=true.
      const start = new Date(Date.now() + 3 * 60_000).toISOString();
      let r: Response | null = null;
      try {
        r = await fetch("https://generativelanguage.googleapis.com/v1alpha/auth_tokens", {
          method: "POST", headers: { "content-type": "application/json", "x-goog-api-key": lr.key },
          body: JSON.stringify({ uses: 1, expireTime: exp, newSessionExpireTime: start }),
        });
      } catch (e) { markLive(lr.id, false, `live token: ${String(e).slice(0, 120)}`, 20); continue; }
      if (!r.ok) { const t = (await r.text().catch(() => "")).slice(0, 200); markLive(lr.id, false, `live token ${r.status} ${t}`, liveCooldown(r.status, t)); continue; }
      const j = await r.json();
      markLive(lr.id, true, null, 0);
      // Logged for stats only: quota_tokens 0, so Live never touches the token allowance.
      record({ user_id: uid, source: "live", alias: resume ? "live-resume" : "live", provider: lr.provider, model, key_id: lr.id, status: 200, prompt_tokens: 0, completion_tokens: 0, quota_tokens: 0, total_ms: Date.now() - t0 });
      return json({ token: j.name, model, expires_at: exp, minutes: Math.ceil(passSecs / 60), call_id: callId, ...(billLeft !== null ? liveMinsOut(mins, billLeft) : minsOut(mins)),
        heartbeat_seconds: HEARTBEAT_S,
        ws_url: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContentConstrained" }, 200,
        billLeft !== null ? balHdr(billLeft) : {});
    }
    // No pass: a new call that never got a line is closed with nothing counted.
    if (!resume && callId) await db.rpc("live_call_beat", { p_uid: uid, p_call: callId, p_reported: 0, p_kind: "end" });
    record({ user_id: uid, source: "live", alias: "live", provider: "live-pool", status: 503, error: "no usable live route" });
    return json({ error: { code: "busy", message: "Live voice is busy right now. Please try again in a moment." } }, 503);
  }

  // Transcription and pictures still use the token allowance (billing on: the billing balance, charged after).
  if (bill) flushUnsaved(s);
  const [ent, mrows] = bill ? await Promise.all([billingPrecheck(uid, s), multipliers()]) : [null, [] as Mult[]];
  const rid = bill ? "media:" + crypto.randomUUID() : "";
  if (ent) {
    if (Number(ent.allowance ?? 0) <= 0) return await emptyReply(uid, ent, s);
  } else {
    const used = await usageOf(uid);
    const st = stateFor(used.tokens, withCap(s, await capOf(uid, s)));
    if (st.state === "limit") return json({ error: { code: "daily_limit", message: s.limit_message } }, 429);
  }
  // Free users: Standard (1x) models only.
  const freeOnly = !!ent && ent.paid !== true;

  if (url.pathname.endsWith("/transcribe")) {
    if (!feat.transcribe) return json({ error: { code: "unavailable", message: "Transcription isn't available right now." } }, 503);
    const audio = String(body.audio_base64 ?? "");
    const mime = String(body.mime ?? "audio/mp4");
    if (!audio) return json({ error: { message: "No audio" } }, 400);
    if (audio.length > Number(s.transcribe_max_b64 ?? 26_000_000)) return json({ error: { code: "too_large", message: "This recording is too long to turn into text in one go. Try a shorter one (about 30 minutes or less)." } }, 413);
    let models: string[] = Array.isArray(s.transcribe_models) ? s.transcribe_models : ["gemini-3.5-flash-lite", "gemini-3-flash-preview"];
    if (freeOnly) {
      models = models.filter((m) => tierOf(m, mrows).tier === "standard");
      if (!models.length) return billErr(402, "paid_model", "Turning recordings into text needs a pass or a token pack right now.", ent!, s, "advanced_only", {}, {}, Number(ent!.allowance ?? 0));
    }
    const prompt = String(body.prompt ?? "Transcribe this recording word for word in the language spoken. Label speakers as Speaker 1, Speaker 2... when the voice changes. No summary, transcript only.");
    let attempts = 0;
    for (const model of models) {
      for (const k of await providerKeys(String(s.live_provider))) {
        if (attempts++ >= 5) break;
        const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`, {
          method: "POST", headers: { "content-type": "application/json", "x-goog-api-key": k.key },
          body: JSON.stringify({ contents: [{ parts: [{ text: prompt }, { inline_data: { mime_type: mime, data: audio } }] }] }),
        }).catch((e) => null);
        if (!r || !r.ok) { const st2 = r?.status ?? 0; markKey(k.id, false, `transcribe ${st2}`, cooldownFor(st2)); if (st2 === 404 || st2 === 400) break; continue; }
        const j = await r.json();
        const text = (j.candidates?.[0]?.content?.parts ?? []).map((p: any) => p.text ?? "").join("").trim();
        const um = j.usageMetadata ?? {};
        record({ user_id: uid, source: "transcribe", alias: "transcribe", provider: String(s.live_provider), model, key_id: k.id, status: 200,
          prompt_tokens: um.promptTokenCount ?? Math.ceil(audio.length / 1000), completion_tokens: (um.totalTokenCount ?? 0) - (um.promptTokenCount ?? 0), total_ms: Date.now() - t0, ttft_ms: Date.now() - t0 });
        if (rid) {
          // Same cost ai_record_usage puts on the old allowance (prompt + completion), times the model multiplier.
          const w = Number(um.promptTokenCount ?? Math.ceil(audio.length / 1000)) + Number((um.totalTokenCount ?? 0) - (um.promptTokenCount ?? 0));
          const cost = Math.ceil(w * tierOf(model, mrows).multiplier);
          billingCharge(uid, rid, w, model, "transcribe", "user", null, s, cost);
          if (ent && text) return json({ text }, 200, balHdr(Number(ent.allowance) - cost));
        }
        if (text) return json({ text });
      }
    }
    return json({ error: { code: "busy", message: "Couldn't turn the recording into text right now. Please try again in a moment." } }, 503);
  }

  // image
  const alias = cfg.aliases.find((a) => a.alias === "telesia-image");
  if (!alias?.routes.length) return json({ error: { code: "unavailable", message: "Image creation isn't available yet." } }, 503);
  const imgRoutes = freeOnly ? alias.routes.filter((r) => tierOf(r.model, mrows).tier === "standard") : alias.routes;
  if (freeOnly && !imgRoutes.length) return billErr(402, "paid_model", "Image creation needs a pass or a token pack.", ent!, s, "advanced_only", {}, {}, Number(ent!.allowance ?? 0));
  for (const r of imgRoutes) {
    for (const k of keysInOrder(r)) {
      const res = await fetch(r.base_url.replace(/\/$/, "") + "/images/generations", {
        method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${k.key}` },
        body: JSON.stringify({ ...(r.extra_body ?? {}), model: r.model, prompt: String(body.prompt ?? ""), n: 1, size: String(body.size ?? "1024x1024"), response_format: "b64_json" }),
      }).catch(() => null);
      if (!res || !res.ok) { markKey(k.id, false, `image ${res?.status ?? 0}`, cooldownFor(res?.status ?? 0)); break; }
      const j = await res.json();
      record({ user_id: uid, source: "image", alias: "telesia-image", provider: r.provider, model: r.model, key_id: k.id, status: 200, prompt_tokens: Number(s.image_tokens ?? 4000), completion_tokens: 0, total_ms: Date.now() - t0 });
      const icost = Math.ceil(Number(s.image_tokens ?? 4000) * tierOf(r.model, mrows).multiplier);
      if (rid) billingCharge(uid, rid, Number(s.image_tokens ?? 4000), r.model, "image", "user", null, s, icost);
      if (ent) return json(j, 200, balHdr(Number(ent.allowance) - icost));
      return json(j);
    }
  }
  return json({ error: { code: "busy", message: "Image creation is busy right now. Please try again in a moment." } }, 503);
}

/** Server-Timing on every answer (ms): cfg = settings, checks = the pre-checks (blocked, burst, allowance; run in
 *  parallel), upstream = until the model's first byte (all fallbacks), total = until this answer starts. */
Deno.serve(async (req) => {
  const t0 = performance.now();
  const tm: Record<string, number> = {};
  const res = await handle(req, tm);
  tm.total = performance.now() - t0;
  try {
    res.headers.set("Server-Timing", Object.entries(tm).map(([k, v]) => `${k};dur=${v.toFixed(1)}`).join(", "));
  } catch { /* immutable headers: leave as is */ }
  return res;
});

async function handle(req: Request, tm: Record<string, number>): Promise<Response> {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const url = new URL(req.url);
  const internal = req.headers.has("x-telesia-internal") ? await internalUser(req) : null;
  const uid = internal ?? userFromJwt(req);
  if (!uid) return json({ error: { code: "auth", message: "Please sign in again." } }, 401);

  let cfg: Config;
  const tCfg = performance.now();
  try { cfg = await config(); } catch (e) { return json({ error: { code: "config", message: String(e) } }, 503); }
  tm.cfg = performance.now() - tCfg;
  const s = cfg.settings;

  if (url.pathname.endsWith("/status")) {
    let uP: ReturnType<typeof usageOf>;
    const [u, m, c, ent] = await Promise.all([(uP = usageOf(uid)), minutesOf(uid), capOf(uid, s), billingOn(s) ? billingPrecheck(uid, s, () => uP) : Promise.resolve(null)]);
    const sc = withCap(s, c);
    const bgs = backgroundFor(u.tokens, u.bg, sc);
    if (ent) {
      // Billing on: the allowance, background and call time come from the billing balance; the old fields keep their shape.
      const bst = billState(ent); const left = Math.max(0, Number(ent.live_seconds_left ?? 0));
      // Precheck down (free fallback): Live new calls follow the old call minutes, so show those.
      const calls = ent.degraded === "free_fallback" ? { ...minsOut(m), billing: true } : liveMinsOut(m, left);
      return json({ cap: bst.cap, used: bst.used, ratio: bst.ratio, state: bst.state, requests: u.requests, bonus: bonusOut(c), resets: "daily (00:00 EAT)",
        message: s.billing_limit_message ?? NO_BALANCE, features: features(cfg), calls, background_left: Number(ent.bg_allowance ?? 0),
        background: { share: bgs.share, cap: bgs.cap, used: bgs.used, left: Number(ent.bg_allowance ?? 0), ratio: Number(bgs.ratio.toFixed(3)), paused: Number(ent.bg_allowance ?? 0) <= 0 },
        billing: billingOut(ent, s) }, 200, balHdr(bst.allowance));
    }
    return json({ ...stateFor(u.tokens, sc), requests: u.requests, bonus: bonusOut(c), resets: "daily (00:00 UTC)", message: s.limit_message, features: features(cfg),
      calls: minsOut(m), background_left: bgs.left,
      background: { share: bgs.share, cap: bgs.cap, used: bgs.used, left: bgs.left, ratio: Number(bgs.ratio.toFixed(3)), paused: bgs.paused } });
  }
  if (url.pathname.endsWith("/models")) {
    return json({ object: "list", data: cfg.aliases.map((a) => ({ id: a.alias, object: "model", owned_by: "telesia" })) });
  }
  if (url.pathname.endsWith("/status") === false && req.method === "POST" && /\/(live-token|live-usage|transcribe|image)$/.test(url.pathname)) {
    return await mediaRoute(req, url, uid, cfg);
  }
  if (req.method !== "POST") return json({ error: { message: "POST only" } }, 405);

  if (s.kill_switch === true) return json({ error: { code: "paused", message: "Telesia is taking a short break. Please try again in a few minutes." } }, 503);
  // Independent pre-checks run together (one round trip instead of four); their answers are applied in the same
  // order as before: blocked, bad JSON, burst, allowance.
  const tChecks = performance.now();
  const rpm = Number(s.user_rpm ?? 40);
  const BAD = Symbol("bad json");
  const bill = billingOn(s);
  let legacyP: Promise<[Awaited<ReturnType<typeof usageOf>>, Cap]>;
  const [blockedRes, parsed, rpmRes, [used, ucap], [ent, mrows]] = await Promise.all([
    db.from("ai_blocked_users").select("user_id").eq("user_id", uid).maybeSingle(),
    req.json().catch(() => BAD),
    rpm > 0
      ? db.from("ai_usage").select("id", { count: "exact", head: true })
        .eq("user_id", uid).eq("status", 200).gte("created_at", new Date(Date.now() - 60_000).toISOString())
      : Promise.resolve({ count: 0 }),
    (legacyP = Promise.all([usageOf(uid), capOf(uid, cfg.settings)])),
    // Billing on: entitlements + multipliers in the same round trip as the other checks (no extra latency). If precheck
    // fails, its conservative fallback reads today's usage from the same legacy query (no extra round trip either).
    bill ? Promise.all([billingPrecheck(uid, s, () => legacyP.then((x) => x[0])), multipliers()]) : Promise.resolve([null, [] as Mult[]] as const),
  ]);
  tm.checks = performance.now() - tChecks;
  if (bill) flushUnsaved(s);
  if (blockedRes.data) return json({ error: { code: "blocked", message: "Your account needs attention. Please contact support." } }, 403);
  if (parsed === BAD) return json({ error: { message: "Invalid JSON" } }, 400);
  const body: any = parsed;
  const source = internal ? "bot-cloud" : (req.headers.get("x-telesia-source") ?? "agent").slice(0, 20);
  // Background lane (Plan 2.2): the cloud runner, or app work nobody is watching (bot wakes, office work).
  const background = !!internal || (req.headers.get("x-telesia-lane") ?? "").toLowerCase() === "background";
  const lane = background ? "background" : "user";
  // Sticky chats: scoped to the user so two users' ids can never collide.
  const chatHdr = (req.headers.get("x-telesia-chat") ?? "").slice(0, 64);
  const chat = chatHdr ? uid + ":" + chatHdr : "";

  // Fair use: a burst of requests (a script, a loop) is slowed down before it reaches any model.
  if (rpm > 0 && ((rpmRes as { count: number | null }).count ?? 0) >= rpm) {
    return json({ error: { code: "slow_down", message: "That's a lot of requests at once. Give it a few seconds and try again." } }, 429, { "retry-after": "10" });
  }

  const s2 = withCap(s, ucap);
  // Billing on (and precheck answered): the billing balance replaces the old daily allowance and its grace.
  const st = ent ? billState(ent) : stateFor(used.tokens, s2);
  const bgLeft = ent ? Math.max(0, Number(ent.bg_allowance ?? 0)) : 0;
  const balance = ent ? (background ? Math.min(bgLeft, st.cap - st.used) : st.cap - st.used) : 0;
  if (ent && st.state === "limit") {
    return await emptyReply(uid, ent, s, { "x-telesia-usage": st.ratio.toFixed(3), "x-telesia-state": st.state });
  }
  if (st.state === "limit") {
    return json({ error: { code: "daily_limit", message: s.limit_message ?? "Daily allowance reached." } }, 429,
      { "x-telesia-usage": st.ratio.toFixed(3), "x-telesia-state": st.state });
  }
  const bgs = backgroundFor(used.tokens, used.bg, s2);
  if (!background && !internal) screenLater(uid, Array.isArray(body.messages) ? body.messages : [], cfg);
  if (ent && background && bgLeft <= 0) {
    return billErr(429, "background_paused", BG_PAUSED, ent, s, "background_share_used", { background_left: 0, resets_at: eatReset() },
      { "x-telesia-usage": st.ratio.toFixed(3), "x-telesia-state": st.state, "x-telesia-bg": "1.000" });
  }
  if (!ent && background && (bgs.paused || st.state === "light")) {
    const reset = new Date(); reset.setUTCHours(24, 0, 0, 0);
    return json({ error: { code: "background_paused", message: "Paused until tomorrow to save your daily allowance." },
      background_left: 0, resets_at: reset.toISOString() }, 429,
      { "x-telesia-usage": st.ratio.toFixed(3), "x-telesia-state": st.state, "x-telesia-bg": bgs.ratio.toFixed(3) });
  }

  let aliasName = String(body.model || "telesia-smart");
  if (!aliasName.startsWith("telesia-")) aliasName = "telesia-smart";
  if (hasImages(body.messages) && aliasName !== "telesia-vision") aliasName = "telesia-vision";
  if (st.state === "light") aliasName = hasImages(body.messages) ? "telesia-vision" : String(s.grace_alias ?? "telesia-lite");
  let alias = cfg.aliases.find((a) => a.alias === aliasName) ?? cfg.aliases.find((a) => a.alias === "telesia-smart");
  if (!alias) return json({ error: { code: "no_alias", message: "Model not available." } }, 503);
  // Billing on, free user (no pass, no pack): Standard (1x) models only. If this alias has no Standard route the
  // request goes to grace_alias (telesia-lite) when that has one, else it needs a pass or a pack.
  const freeOnly = !!ent && ent.paid !== true;
  const isStd = (r: Route) => tierOf(r.model, mrows).tier === "standard";
  if (freeOnly && alias.routes.length && !alias.routes.some(isStd)) {
    const alt = hasImages(body.messages) ? null : cfg.aliases.find((a) => a.alias === String(s.grace_alias ?? "telesia-lite") && a.routes.some(isStd));
    if (!alt) {
      const free = cfg.aliases.filter((a) => a.routes.some(isStd) && (!hasImages(body.messages) || a.routes.some((r) => isStd(r) && r.vision))).map((a) => a.alias);
      return billErr(402, "paid_model", PAID_MODEL, ent!, s, "advanced_only", { free_models: free }, {}, balance);
    }
    alias = alt;
  }

  let maxOut = alias.max_output_tokens;
  if (st.state === "light") maxOut = Math.min(maxOut, Number(s.grace_max_output_tokens ?? 400));
  const requested = Number(body.max_tokens ?? body.max_completion_tokens ?? 0);
  const max_tokens = requested > 0 ? Math.min(requested, maxOut) : maxOut;

  const messages = cleanHistory(Array.isArray(body.messages) ? [...body.messages] : []);
  if (alias.system_hint) {
    const i = messages.findIndex((m: any) => m.role === "system");
    if (i >= 0 && typeof messages[i].content === "string") messages[i] = { ...messages[i], content: messages[i].content + "\n\n" + alias.system_hint };
    else messages.unshift({ role: "system", content: alias.system_hint });
  }
  const needTools = Array.isArray(body.tools) && body.tools.length > 0;
  const stream = body.stream === true;
  const promptEstimate = estimateTokens(messages.map((m: any) => typeof m.content === "string" ? m.content : (Array.isArray(m.content) ? m.content.filter((c: any) => c?.type === "text") : m)))
    + (needTools ? estimateTokens(body.tools) : 0);
  if (promptEstimate > Number(s.max_prompt_tokens ?? 120000)) {
    return json({ error: { code: "too_long", message: "Request too large to send in one go. Start a new chat or send less at once." } }, 413);
  }

  // Healthy routes first, unhealthy ones kept as a last resort. Then the other chat aliases' models,
  // so a user with allowance left always gets an answer even when this alias's models are all down.
  const spare: Route[] = [];
  const seen = new Set(alias.routes.map((r) => r.model_ref));
  for (const n of ["telesia-smart", "telesia-fast", "telesia-think", "telesia-vision"]) {
    if (n === alias.alias) continue;
    // Pictures in the chat need a vision model; never fall back to one that can't see.
    for (const r of cfg.aliases.find((a) => a.alias === n)?.routes ?? []) {
      if (seen.has(r.model_ref)) continue;
      seen.add(r.model_ref);
      spare.push({ ...r, extra_body: r.extra_body && "reasoning_effort" in r.extra_body ? null : r.extra_body } as Route);
    }
  }
  const hasImage = messages.some((m: any) => Array.isArray(m.content) && m.content.some((c: any) => c?.type === "image_url"));
  let routes = alias.routes.filter((r) => (!needTools || r.tools) && (!freeOnly || isStd(r)));
  const extra = spare.filter((r) => (!needTools || r.tools) && (!hasImage || r.vision) && (!freeOnly || isStd(r)));
  routes = [...routes.filter((r) => r.healthy), ...extra.filter((r) => r.healthy), ...routes.filter((r) => !r.healthy), ...extra.filter((r) => !r.healthy)];
  // Fit check: the prompt (with a safety margin, the estimate is rough) plus room for the reply must fit
  // the model's window. Routes that can't fit are skipped, so a swap never truncates or fails.
  const windowOf = (r: Route) => Number(r.context_window) || 128000;
  // A route must fit the prompt plus a fair reply; each route then gets as much reply room as its window allows (up to max_tokens).
  const promptNeed = Math.ceil(promptEstimate * 1.15);
  const need = promptNeed + Math.min(max_tokens, 4096);
  const roomOf = (r: Route) => Math.max(1024, Math.min(max_tokens, windowOf(r) - promptNeed - 256));
  // Billing on: a reply may not run far past what is left (overrun bounded; see replyCap). Flag off: roomOf unchanged.
  const roomB = (r: Route) => ent ? Math.min(roomOf(r), replyCap(balance, tierOf(r.model, mrows).multiplier, promptEstimate, s)) : roomOf(r);
  const healthyWindows = routes.filter((r) => r.healthy).map(windowOf);
  // Smallest window among this alias's healthy routes, so the app can size its own budget.
  const smallestWindow = String(Math.min(...(healthyWindows.length ? healthyWindows : routes.map(windowOf)), 1_000_000));
  const fitting = routes.filter((r) => need <= windowOf(r));
  if (routes.length && !fitting.length) {
    // Same wording the app already treats as "compact and retry once".
    return json({ error: { code: "too_long", message: "Request too large to send in one go. Start a new chat or send less at once." } }, 413,
      { "x-telesia-window": smallestWindow });
  }
  routes = fitting;
  if (ent) {
    // Billing on: a message whose prompt alone costs far more than what is left is refused up front (clear reason),
    // so one huge request can't run the balance deep into unpaid tokens.
    const minMult = routes.length ? Math.min(...routes.map((r) => tierOf(r.model, mrows).multiplier)) : 1;
    const needIn = Math.ceil(promptEstimate * num(s.input_weight, 0.3) * minMult);
    if (needIn > balance + Math.max(0, num(s.billing_overrun_tokens, 8000))) {
      return billErr(429, "daily_limit", `This message is too big for what's left of your allowance (it needs about ${needIn.toLocaleString("en-US")} tokens, ` +
        `${Math.max(0, Math.floor(balance)).toLocaleString("en-US")} left). Start a new chat or send less at once, or get a pass or a token pack.`,
        ent, s, "too_big_for_balance", { needed: needIn }, { "x-telesia-usage": st.ratio.toFixed(3), "x-telesia-state": st.state }, balance);
    }
  }

  const passthrough: Record<string, unknown> = {};
  for (const k of ["temperature", "top_p", "tools", "tool_choice", "response_format", "stop", "parallel_tool_calls", "seed"]) {
    if (body[k] !== undefined) passthrough[k] = body[k];
  }
  const firstByteMs = Number(s.first_byte_timeout_ms ?? 12000);
  // Try every route before giving up (not a fixed small number), within an overall time budget.
  const maxAttempts = Math.max(Number(s.max_attempts ?? 6), routes.length * 2 + 2);
  const deadline = Date.now() + Number(s.fallback_budget_ms ?? 75000);
  const t0 = Date.now();
  const tUp = performance.now();
  let attempts = 0;
  let lastErr = "no route available";
  let lastStatus = 503;
  // One id per request: a retried charge for this reply is a no-op in billing_consume.
  // Billing on but precheck unavailable: the old allowance gates the request, the reply is still charged.
  const rid = bill ? "chat:" + crypto.randomUUID() : "";
  const bilHdrs = (cost: number): Record<string, string> => ent ? balHdr(balance - cost) : {};

  const bad = new Set<string>(); // routes that answered with a hard error this request
  const shrunk = new Set<string>(); // routes already retried with a smaller max_tokens
  for (let pass = 0; pass < 2; pass++) {
  for (const r of routes) {
    if (pass === 1 && bad.has(r.route_id)) continue;
    // Second pass: keys resting after a short error get one more try, so a brief blip never ends in "busy".
    const ks = pass === 0 ? keysInOrder(r, chat) : keysInOrder(r, chat, true).slice(0, 1);
    const tryKeys = ks.slice(0, pass === 0 ? 3 : 1);
    for (let ki = 0; ki < tryKeys.length; ki++) {
      const k = tryKeys[ki];
      if (attempts >= maxAttempts || Date.now() > deadline) break;
      attempts++;
      const capTok = routeCap.get(r.route_id);
      const payload = {
        ...passthrough, ...(r.extra_body ?? {}), model: r.model, messages, max_tokens: capTok ? Math.min(capTok, roomB(r)) : roomB(r), stream,
        ...(stream ? { stream_options: { include_usage: true } } : {}),
      };
      let res: Response, ctl: AbortController, timer: number;
      try {
        ({ res, ctl, timer } = await fetchWithFirstByte(r.base_url.replace(/\/$/, "") + "/chat/completions", {
          method: "POST",
          headers: { "content-type": "application/json", authorization: `Bearer ${k.key}`, "user-agent": "telesia-proxy/1" },
          body: JSON.stringify(payload),
        }, firstByteMs) as any);
      } catch (e) {
        lastErr = `${r.provider}: ${String(e).slice(0, 120)}`; lastStatus = 504;
        markKey(k.id, false, lastErr, 20);
        record({ user_id: uid, source, lane, alias: alias.alias, provider: r.provider, model: r.model, key_id: k.id, status: 0, error: lastErr, total_ms: Date.now() - t0 });
        break; // provider is slow: move to the next route instead of the next key
      }
      if (!res.ok) {
        clearTimeout(timer);
        const txt = (await within(res.text(), 15000, "error body timeout").catch(() => "")).slice(0, 300);
        lastErr = `${r.provider} ${res.status}: ${txt}`; lastStatus = res.status;
        const cd = cooldownFor(res.status);
        markKey(k.id, false, lastErr, cd);
        record({ user_id: uid, source, lane, alias: alias.alias, provider: r.provider, model: r.model, key_id: k.id, status: res.status, error: txt });
        // The model allows fewer output tokens than asked: remember its limit and retry it once, smaller.
        if (res.status === 400 && /max_tokens|max_completion|max_output|output tokens|maximum.{0,40}tokens|tokens.{0,40}(exceed|too large|limit)/i.test(txt)
            && !shrunk.has(r.route_id)) {
          shrunk.add(r.route_id); // once per route per request, so this can never loop
          const was = capTok ? Math.min(capTok, roomB(r)) : roomB(r);
          const m = txt.match(/(?:at most|maximum(?: value)?(?: is| of)?|up to|<=|less than or equal to)\s*(\d{3,6})/i);
          const n = m ? Number(m[1]) : 0;
          const next = n >= 1024 && n < was ? n : (was > 8192 ? 8192 : 4096);
          if (next < was) { routeCap.set(r.route_id, next); tryKeys.splice(ki + 1, 0, k); continue; }
        }
        if (res.status === 404 || res.status === 400) { bad.add(r.route_id); break; } // model problem, not key problem
        if (res.status === 401 || res.status === 402 || res.status === 403) continue;
        continue;
      }

      if (!stream) {
        const data = await within(res.json(), 300000, "reply timeout").catch(() => null);
        clearTimeout(timer);
        if (!data?.choices) { lastErr = `${r.provider}: bad response`; markKey(k.id, false, lastErr, 20); continue; }
        markKey(k.id, true, null, 0);
        const total = Date.now() - t0;
        const pt = data.usage?.prompt_tokens ?? promptEstimate;
        const ct = Math.max(data.usage?.completion_tokens ?? estimateTokens(data.choices?.[0]?.message), (data.usage?.total_tokens ?? 0) - pt);
        record({ user_id: uid, source, lane, alias: alias.alias, provider: r.provider, model: r.model, key_id: k.id, status: 200,
          prompt_tokens: pt, completion_tokens: ct, ttft_ms: total, total_ms: total, tps: null, attempts, quota_tokens: quotaOf(s, pt, ct, data.usage), cached_tokens: cachedOf(data.usage) });
        data.model = alias.alias;
        for (const ch of data.choices ?? []) {
          if (typeof ch?.message?.content === "string") {
            ch.message.content = clean(ch.message.content);
            if (ch.message.tool_calls?.length && !ch.message.content.trim()) ch.message.content = null;
          }
        }
        tm.upstream = performance.now() - tUp;
        if (rid) billingCharge(uid, rid, quotaOf(s, pt, ct, data.usage), r.model, source, lane, null, s, Math.ceil(quotaOf(s, pt, ct, data.usage) * tierOf(r.model, mrows).multiplier));
        if (ent) {
          const w = quotaOf(s, pt, ct, data.usage);
          const cost = Math.ceil(w * tierOf(r.model, mrows).multiplier);
          const after = billState(ent, cost);
          return json(data, 200, { "x-telesia-usage": after.ratio.toFixed(3), "x-telesia-state": after.state, "x-telesia-window": smallestWindow,
            "x-telesia-bg": (background && bgLeft - cost <= 0 ? 1 : bgs.ratio).toFixed(3), ...bilHdrs(cost) });
        }
        const after = stateFor(used.tokens + quotaOf(s, pt, ct, data.usage), s2);
        return json(data, 200, { "x-telesia-usage": after.ratio.toFixed(3), "x-telesia-state": after.state, "x-telesia-window": smallestWindow,
          "x-telesia-bg": backgroundFor(after.used, used.bg + (background ? quotaOf(s, pt, ct, data.usage) : 0), s2).ratio.toFixed(3) });
      }

      // Streaming: wait for the first chunk before committing, so a dead stream can still fall back.
      // Commit only once the model sends real output (text, reasoning or a tool call), not just an empty opening chunk.
      const reader = res.body!.getReader();
      let first: ReadableStreamReadResult<Uint8Array> = { done: true, value: undefined } as any;
      const held: Uint8Array[] = [];
      let peek = ""; let real = false; let errInStream = ""; let readErr = "";
      const pdec = new TextDecoder();
      try {
        while (!real) {
          const x = await within(reader.read(), firstByteMs + 3000, "no output in time");
          if (x.done) break;
          held.push(x.value!);
          peek += pdec.decode(x.value!, { stream: true });
          if (/"error"\s*:/.test(peek) && !/"choices"/.test(peek)) { errInStream = peek.slice(0, 200); break; }
          if (/"(content|reasoning_content|reasoning)"\s*:\s*"[^"]/.test(peek) || /"tool_calls"\s*:\s*\[\s*\{/.test(peek) || peek.includes("[DONE]")) real = true;
          if (peek.length > 200_000) real = true;
        }
      } catch (e) { readErr = String(e).slice(0, 120); }
      clearTimeout(timer);
      if (!real) {
        lastErr = `${r.provider}: ${readErr || errInStream || "empty stream"}`; markKey(k.id, false, lastErr, 20);
        record({ user_id: uid, source, lane, alias: alias.alias, provider: r.provider, model: r.model, key_id: k.id, status: 0, error: lastErr });
        reader.cancel().catch(() => {});
        if (readErr) break;
        continue;
      }
      const joined = new Uint8Array(held.reduce((n, b) => n + b.length, 0));
      { let o = 0; for (const b of held) { joined.set(b, o); o += b.length; } }
      first = { done: false, value: joined };
      markKey(k.id, true, null, 0);
      tm.upstream = performance.now() - tUp;

      const enc = new TextEncoder(); const dec = new TextDecoder();
      let sawFinish = false;
      // The upstream died mid-reply: end it as "cut off" so the app carries on from where it stopped instead of failing.
      const cutTail = () => enc.encode(`data: ${JSON.stringify({ id: "cut", object: "chat.completion.chunk", model: alias.alias, choices: [{ index: 0, delta: {}, finish_reason: "length" }] })}\n\ndata: [DONE]\n\n`);
      let buf = ""; let ttft = 0; let tFirstTok = 0; let usage: any = null; let outChars = 0; let charged = false;
      const process = (chunk: Uint8Array | null): Uint8Array => {
        if (chunk) buf += dec.decode(chunk, { stream: true }); else buf += "\n";
        let out = ""; let nl: number;
        while ((nl = buf.indexOf("\n")) >= 0) {
          const raw = buf.slice(0, nl); buf = buf.slice(nl + 1);
          const line = raw.trim();
          if (!line) continue;
          if (!line.startsWith("data:")) { if (line.startsWith(":")) out += line + "\n\n"; continue; }
          const d = line.slice(5).trim();
          if (d === "[DONE]") { out += "data: [DONE]\n\n"; continue; }
          let j: any;
          try { j = JSON.parse(d); } catch { out += line + "\n\n"; continue; }
          if (j.usage) usage = j.usage;
          if (j.choices?.[0]?.finish_reason) sawFinish = true;
          j.model = alias.alias;
          const delta = j.choices?.[0]?.delta;
          if (delta) {
            if (typeof delta.content === "string") { delta.content = clean(delta.content); if (/^\s*<?\s*\/?\s*｜[^>]*>?\s*$|^\s*<\s*$/.test(delta.content) && delta.content.includes("｜")) delta.content = ""; }
            const n = (delta.content?.length ?? 0) + (delta.reasoning_content?.length ?? 0) + (delta.reasoning?.length ?? 0) + (delta.tool_calls ? JSON.stringify(delta.tool_calls).length : 0);
            if (n > 0 && !ttft) { ttft = Date.now() - t0; tFirstTok = Date.now(); }
            outChars += n;
          }
          out += "data: " + JSON.stringify(j) + "\n\n";
        }
        return enc.encode(out);
      };
      const finish = (status: number, err?: string) => {
        const total = Date.now() - t0;
        const pt = usage?.prompt_tokens ?? promptEstimate;
        const ct = Math.max(usage?.completion_tokens ?? Math.ceil(outChars / 4), (usage?.total_tokens ?? 0) - pt);
        const g = (Date.now() - (tFirstTok || t0)) / 1000;
        const genSecs = g < 0.25 ? Math.max(0.05, total / 1000) : g;
        record({ user_id: uid, source, lane, alias: alias.alias, provider: r.provider, model: r.model, key_id: k.id, status,
          prompt_tokens: pt, completion_tokens: ct, ttft_ms: ttft || total, total_ms: total, tps: ct / genSecs, attempts, error: err,
          quota_tokens: quotaOf(s, pt, ct, usage), cached_tokens: cachedOf(usage) });
        // Billing on: charge what was generated. A client hang-up (499) or a cut stream is charged for the output that was
        // actually produced before it stopped (provider usage when it arrived, else the streamed characters / 4) plus the
        // prompt; a reply stopped before any output was produced costs nothing.
        if (rid && !charged && (status === 200 || status === 499)) {
          charged = true;
          if (status === 200 || usage || outChars > 0) {
            const w = quotaOf(s, pt, ct, usage);
            billingCharge(uid, rid, w, r.model, source, lane, null, s, Math.ceil(w * tierOf(r.model, mrows).multiplier));
          }
        }
      };
      const firstOut = process(first.value!);
      const out = new ReadableStream<Uint8Array>({
        start(c) { if (firstOut.length) c.enqueue(firstOut); },
        async pull(c) {
          try {
            // A stream that goes quiet for 90s is treated as cut: the app continues from where it stopped.
            const { done, value } = await within(reader.read(), Number(s.stream_idle_ms ?? 90000), "stream went quiet");
            if (done) {
              const tail = process(null); if (tail.length) c.enqueue(tail);
              if (!sawFinish) c.enqueue(cutTail());
              finish(200, sawFinish ? undefined : "ended without finish"); c.close(); return;
            }
            const o = process(value); if (o.length) c.enqueue(o);
          } catch (e) { if (!sawFinish) c.enqueue(cutTail()); finish(200, "stream cut: " + String(e).slice(0, 100)); c.close(); reader.cancel().catch(() => {}); ctl.abort(); }
        },
        cancel() { finish(499, "client closed"); reader.cancel().catch(() => {}); ctl.abort(); },
      });
      return new Response(out, { headers: { ...CORS, "content-type": "text/event-stream", "cache-control": "no-cache",
        "x-telesia-usage": st.ratio.toFixed(3), "x-telesia-state": st.state, "x-telesia-window": smallestWindow, "x-telesia-bg": bgs.ratio.toFixed(3), ...bilHdrs(0) } });
    }
    if (attempts >= maxAttempts || Date.now() > deadline) break;
  }
  if (attempts >= maxAttempts || Date.now() > deadline) break;
  }
  console.error("ai-chat exhausted", alias.alias, attempts, lastErr.slice(0, 200));
  return json({ error: { code: "busy", message: "Telesia is very busy right now. Please try again in a moment." } },
    lastStatus === 429 ? 503 : 502);
}
