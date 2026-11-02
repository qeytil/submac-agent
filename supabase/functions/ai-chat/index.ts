// SubMac cloud model proxy. The app sends OpenAI-style chat requests for the one public model, `submac`. Routing,
// keys, quotas and metrics are all server-side and edited from the admin dashboard.
//
// Rebuild (2026-10-23, PLAN.md Part 1 / Contract A): one model and a sticky router (router.ts). Any model name starting
// with "submac" (older apps send submac-smart/fast/think/lite/vision/somali) is served by the one route list (alias
// `submac`; until migration 20261023_router_single_model is applied, the submac-smart routes). Removed: the Somali
// swap/detector/hint, vision forcing (now a capability filter), the grace/lite alias (now the same routes with a
// max_tokens cap), think aliases, spare routes from other aliases, and the early "spec" call. The shared current-route
// pointer comes back inside ai_gate; timeouts follow the PLAN 1.3 budget (heartbeat, 25 s hard stop, SSE `error`
// events with fixed codes); req.signal aborts every upstream fetch; nothing is charged when no output was delivered.
// Live tokens: sticky key order, only the key being tried is decrypted, 5 s per Google call, 12 s in total.
//
// Billing (Contract B, volume billing): behind ai_settings.billing_enabled (off in production). With it on, the request is
// checked with public.usage_gate(user_id, source) and charged after with public.usage_charge(user_id, tokens_in,
// tokens_out, source, request_id) (Dev 2, migration 20261023_billing_v2). Raw tokens, no model multipliers. When those
// functions are not in the database yet, billing quietly falls back to the old daily allowance (logged once).

import {
  budgetFrom, cooldownFor, type Done, type Effort, effortOf, thinkingExtra, type ErrCode, FRIENDLY, keysInOrder, localCooldown,
  clampOut, providerOutCap, retryAfterSecs, type Route, type RouterSnap, runChat, snapFrom, withThoughtSignatures,
} from "./router.ts";
import { billSource, BOT_SOURCES, chatLane, EAT_MS, eatDay, entFromGate, missingFn, nextEatMidnight, resetsAtHeader } from "./billing_gate.ts";
import { makeVerifier } from "./jwt_verify.ts";

const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SB_SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const REST = SB_URL + "/rest/v1";
const SH: Record<string, string> = { apikey: SB_SERVICE, authorization: `Bearer ${SB_SERVICE}`, "content-type": "application/json" };
type DbRes = { data: any; error: { message: string } | null };
/** PostgREST RPC with the service key. Never throws. */
async function rpc(fn: string, args: Record<string, unknown> = {}, signal?: AbortSignal): Promise<DbRes> {
  try {
    const r = await fetch(`${REST}/rpc/${fn}`, { method: "POST", headers: SH, body: JSON.stringify(args), signal });
    const t = await r.text();
    let j: any = null;
    try { j = t ? JSON.parse(t) : null; } catch { j = t; }
    if (!r.ok) return { data: null, error: { message: (j && typeof j === "object" && j.message) || `${fn} ${r.status}` } };
    return { data: j, error: null };
  } catch (e) { return { data: null, error: { message: String(e) } }; }
}
/** PostgREST select (path like "ai_keys?select=id&provider_id=eq.<id>"). Never throws; [] on error. */
async function rows(path: string): Promise<any[]> {
  try {
    const r = await fetch(`${REST}/${path}`, { headers: SH });
    if (!r.ok) { await r.body?.cancel(); return []; }
    const j = await r.json();
    return Array.isArray(j) ? j : [];
  } catch { return []; }
}
const ISO = crypto.randomUUID().slice(0, 6); // this isolate, for Server-Timing (shows whether isolates are reused)
let isoHits = 0;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info, x-submac-source, x-submac-chat, x-submac-lane, x-submac-effort, x-region",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Expose-Headers": "x-submac-usage, x-submac-state, x-submac-window, x-submac-bg, x-submac-today-left, x-submac-total-left, x-submac-resets-at, x-submac-plan, x-submac-error, retry-after, server-timing",
};

/** The one public model and its route list (ai_routes alias `submac`). */
const CHAT_ALIAS = "submac";
/** Used only until the migration has added the `submac` alias, so a deploy before the migration keeps working. */
const LEGACY_ALIAS = "submac-smart";
type Alias = { alias: string; max_output_tokens: number; system_hint: string | null; routes: Route[] };
type KeyMeta = { id: string; cooldown_until: string | null };
type Config = { settings: Record<string, any>; aliases: Alias[]; key_meta: Record<string, KeyMeta[]> };

const CFG_TTL = 60_000;
let cache: { at: number; cfg: Config } | null = null;

function warmCfg(): Config | null { return cache && Date.now() - cache.at < CFG_TTL ? cache.cfg : null; }
function setCfg(c: any) {
  if (!c || !Array.isArray(c.aliases)) return;
  for (const a of c.aliases) for (const r of a.routes ?? []) r.keys = [];
  c.key_meta = c.key_meta ?? {};
  cache = { at: Date.now(), cfg: c as Config };
}
/** Routing config without secrets (ai_config_lite), cached per isolate for a minute. */
async function config(): Promise<Config> {
  const w = warmCfg();
  if (w) return w;
  const { data, error } = await rpc("ai_config_lite");
  if (error || !data) { if (cache) return cache.cfg; throw new Error("config: " + (error?.message ?? "empty")); }
  setCfg(data);
  return cache!.cfg;
}

// Decrypted keys per provider, fetched only for providers actually tried (ai_provider_keys), cached 2 min.
const SECRET_TTL = 120_000;
const secretCache = new Map<string, { at: number; keys: Map<string, string> }>();
function putSecrets(data: any) {
  if (!data || typeof data !== "object") return;
  for (const [pid, ks] of Object.entries(data)) {
    const m = new Map<string, string>();
    for (const k of (ks as any[]) ?? []) if (k?.id && k?.key) m.set(String(k.id), String(k.key));
    secretCache.set(pid, { at: Date.now(), keys: m });
  }
}
function secretsFresh(pid: string) { const h = secretCache.get(pid); return !!h && Date.now() - h.at < SECRET_TTL; }
function fillKeys(cfg: Config, r: Route) {
  const sec = secretCache.get(r.provider_id)?.keys;
  r.keys = (cfg.key_meta?.[r.provider_id] ?? []).filter((m) => sec?.has(m.id)).map((m) => ({ id: m.id, key: sec!.get(m.id)!, cooldown_until: m.cooldown_until }));
}
/** Makes sure these routes carry their provider's keys (one RPC for all missing providers). */
async function ensureKeys(cfg: Config, rs: Route[]) {
  const need = [...new Set(rs.map((r) => r.provider_id).filter((p) => p && !secretsFresh(p)))];
  if (need.length) {
    const { data } = await rpc("ai_provider_keys", { p_provider_ids: need });
    putSecrets(data);
  }
  for (const r of rs) fillKeys(cfg, r);
}

function chatAlias(cfg: Config): Alias | undefined {
  return cfg.aliases.find((a) => a.alias === CHAT_ALIAS && a.routes.length) ?? cfg.aliases.find((a) => a.alias === LEGACY_ALIAS);
}

type Gate = { blocked: boolean; burst: number; usage: { tokens: number; requests: number; bg: number }; cap: Cap; router: RouterSnap };
function capFrom(data: any, s: Record<string, any>): Cap {
  const dflt = Number(s.daily_cap_tokens ?? 200000);
  if (data && Number.isFinite(Number(data.cap))) {
    return { cap: Number(data.cap), base: Number(data.base), bonus: Number(data.bonus ?? 0), earned: Number(data.earned ?? 0), granted: Number(data.granted ?? 0),
      max_bonus: Number(data.max_bonus ?? 0), override: data.override == null ? null : Number(data.override), active: data.active ?? {} };
  }
  return { cap: dflt, base: dflt, bonus: 0, earned: 0, granted: 0, max_bonus: 0, override: null, active: {} };
}
const GATE_MS = 2_000;
/** One round trip (2 s limit): blocked, burst, today's usage, cap and the router pointer (+ route rests); plus the config
 *  when cold and the current route's keys. */
async function gate(uid: string, wantConfig: boolean, needTools: boolean): Promise<Gate> {
  const { data, error } = await within(rpc("ai_gate", { p_uid: uid, p_want_config: wantConfig, p_alias: CHAT_ALIAS, p_need_tools: needTools }, AbortSignal.timeout(GATE_MS)),
    GATE_MS + 100, "gate timeout");
  if (error || !data) throw new Error("gate: " + (error?.message ?? "empty"));
  if (data.config) setCfg(data.config);
  if (data.keys) putSecrets(data.keys);
  const u = data.usage ?? {};
  return { blocked: data.blocked === true, burst: Number(data.burst ?? 0),
    usage: { tokens: Number(u.tokens ?? 0), requests: Number(u.requests ?? 0), bg: Number(u.bg ?? 0) },
    cap: capFrom(data.cap, (cache?.cfg.settings ?? {})), router: snapFrom(data.router) };
}

function json(body: unknown, status = 200, extra: Record<string, string> = {}) {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, "content-type": "application/json", ...extra } });
}
/** Every refusal has the same shape: {error: {code: <legacy code the current app reads>, submac_code: <Contract A code>,
 *  message: <fixed friendly text>}} plus x-submac-error; `busy` carries Retry-After 15–30 s with jitter. */
function errJson(status: number, code: ErrCode, legacy: string, message?: string, retry = false, extra: Record<string, string> = {}) {
  const ra = retry ? retryAfterSecs() : 0;
  return json({ error: { code: legacy, submac_code: code, message: message ?? FRIENDLY[code], ...(ra ? { retry_after: ra } : {}) } }, status,
    { "x-submac-error": code, ...(ra ? { "Retry-After": String(ra) } : {}), ...extra });
}

// PLAN 1.8: the token is checked here too (ES256 signature + expiry against the project's JWKS), not only by the
// gateway. Tokens this isolate cannot check (legacy HS256, JWKS unreachable) fall back to the gateway's check.
const jwt = makeVerifier(SB_URL + "/auth/v1/.well-known/jwks.json");
jwt.prefetch();
async function userFromJwt(req: Request): Promise<string | null> {
  const r = await jwt.verify(req.headers.get("authorization"));
  if (!r.uid && (r.reason === "bad_signature" || r.reason === "expired")) console.warn(JSON.stringify({ evt: "jwt_refused", reason: r.reason }));
  return r.uid;
}

// Plan 2.1 part B: bot-run calls this proxy on a user's behalf (their allowance, source 'bot-cloud'). It must carry
// the service-role JWT (checked by the gateway) and the runner's Vault secret (x-submac-internal), plus x-submac-user.
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const internalOk = new Map<string, number>(); // secret -> checked until (ms)
async function internalUser(req: Request): Promise<string | null> {
  const sec = req.headers.get("x-submac-internal") ?? "";
  const u = req.headers.get("x-submac-user") ?? "";
  if (!sec || !UUID_RE.test(u)) return null;
  const t = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
  // The caller holds this project's service key (same env in every function), or a service-role JWT.
  let service = t.length > 20 && t === SB_SERVICE;
  if (!service) {
    try { service = JSON.parse(atob(t.split(".")[1].replace(/-/g, "+").replace(/_/g, "/"))).role === "service_role"; } catch { service = false; }
  }
  if (!service) return null;
  if ((internalOk.get(sec) ?? 0) < Date.now()) {
    const { data } = await rpc("bot_run_check", { p_secret: sec });
    if (data !== true) return null;
    if (internalOk.size > 4) internalOk.clear();
    internalOk.set(sec, Date.now() + 300_000);
  }
  return u.toLowerCase();
}

/** Today's key in ai_user_daily: the EAT date (the daily allowance resets at 00:00 EAT, same as ai_record_usage). */
function today() { return eatDay(); }

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
    const { data, error } = await rpc("ai_user_cap", { p_uid: uid });
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

// ---- Billing (Contract B). Everything here is gated on ai_settings.billing_enabled; while it is off none of these
// functions is called and every answer is exactly what it was before billing existed. The money logic lives in SQL
// (Dev 2): usage_gate answers what the user may spend now (per lane), usage_charge charges one reply idempotently per
// request id (raw tokens; source 'live' = seconds of a call). Day = EAT (Africa/Mogadishu).
function billingOn(s: Record<string, any>): boolean { return s.billing_enabled === true || s.billing_enabled === "true"; }
// deno-lint-ignore no-explicit-any
type Ent = Record<string, any>;
function num(v: unknown, d: number): number { const n = Number(v); return v !== null && v !== undefined && v !== "" && Number.isFinite(n) ? n : d; }
function waitLater(p: Promise<unknown>) {
  // deno-lint-ignore no-explicit-any
  (globalThis as any).EdgeRuntime?.waitUntil?.(p);
}

// Gate cache (load): one usage_gate per user and lane per few seconds (billing_precheck_cache_ms, default 5000) and one
// in flight at a time. A charge marks the entry stale (the next request reads SQL again) but keeps it, with what was
// spent since, as the user's "last known good" for the fallback below (billing_last_good_ms, default 15 min).
type PreEntry = { ent: Ent; at: number; fresh: boolean; spent: number; bgSpent: number };
const preCache = new Map<string, PreEntry>();
const preInflight = new Map<string, Promise<Ent | null | "error">>();
const PRE_CACHE_MAX = 5000;
/** Cache key: the gate answers per lane (bot lane = its share), so foreground and bot lanes are cached apart. */
function preKey(uid: string, src: string) { return BOT_SOURCES.has(src) ? uid + "|bg" : uid; }
function rememberEnt(key: string, ent: Ent) {
  preCache.delete(key);
  if (preCache.size >= PRE_CACHE_MAX) preCache.delete(preCache.keys().next().value!);
  preCache.set(key, { ent, at: Date.now(), fresh: true, spent: 0, bgSpent: 0 });
}
function noteSpend(uid: string, cost: number, bg: boolean) {
  for (const key of [uid, uid + "|bg"]) {
    const e = preCache.get(key);
    if (e) { e.fresh = false; e.spent += cost; if (bg) e.bgSpent += cost; }
  }
}
let missingLogged = false;
function logMissing(fn: string) {
  if (missingLogged) return;
  missingLogged = true;
  console.error(JSON.stringify({ evt: "billing_functions_missing", fn, note: "billing_enabled is on but usage_gate/usage_charge are not deployed; old allowance applies" }));
}
function precheckRpc(uid: string, s: Record<string, any>, src: string): Promise<Ent | null | "error"> {
  const key = preKey(uid, src);
  const running = preInflight.get(key);
  if (running) return running;
  const p = (async (): Promise<Ent | null | "error"> => {
    try {
      // deno-lint-ignore no-explicit-any
      const { data, error } = await within(rpc("usage_gate", { p_user_id: uid, p_source: src }), Math.max(300, num(s.billing_precheck_timeout_ms, 2000)), "gate timeout") as any;
      if (error && missingFn(error.message)) { logMissing("usage_gate"); return null; }
      if (error) return "error";
      return entFromGate(data, s);
    } catch { return "error"; }
  })().finally(() => preInflight.delete(key));
  preInflight.set(key, p);
  return p;
}
/** What this user may spend now. null when billing does not apply (SQL says it is off for this user, or the billing
 *  functions are not deployed yet): then the old daily allowance applies, exactly as before. When usage_gate errors or
 *  times out the answer is never a guessed paid balance: a user whose paid balance was seen recently keeps it (minus what
 *  was spent since); everyone else gets the free tier measured against today's usage counter (ent.degraded says which). */
async function billingPrecheck(uid: string, s: Record<string, any>, legacy?: () => Promise<{ tokens: number; bg: number }>, src = "chat"): Promise<Ent | null> {
  const key = preKey(uid, src);
  const c = preCache.get(key);
  if (c && c.fresh && Date.now() - c.at < Math.max(0, Math.min(60_000, num(s.billing_precheck_cache_ms, 5000)))) return c.ent;
  const r = await precheckRpc(uid, s, src);
  if (r === null) return null;
  if (r !== "error") { rememberEnt(key, r); return r; }
  return await billingFallback(key, s, legacy);
}
async function billingFallback(key: string, s: Record<string, any>, legacy?: () => Promise<{ tokens: number; bg: number }>): Promise<Ent> {
  const uid = key.split("|")[0];
  const c = preCache.get(key);
  const age = c ? Date.now() - c.at : -1;
  console.error(JSON.stringify({ evt: "usage_gate_failed", uid, last_good_age_ms: age }));
  if (c && age < num(s.billing_last_good_ms, 15 * 60_000) && c.ent.paid === true) {
    const allowance = Math.max(0, num(c.ent.allowance, 0) - c.spent);
    const bg = Math.max(0, Math.min(allowance, num(c.ent.bg_allowance, 0) - c.bgSpent));
    return { ...c.ent, allowance, bg_allowance: bg, used_today: num(c.ent.used_today, 0) + c.spent, state: allowance <= 0 ? "limit" : String(c.ent.state ?? "ok"),
      live_seconds_left: Math.max(0, num(c.ent.live_seconds_left, 0) - Math.floor(age / 1000)), total_left: Math.max(0, num(c.ent.total_left, 0) - c.spent),
      degraded: "last_good" };
  }
  const daily = Math.max(0, num(s.billing_free_daily_tokens, 60000));
  const share = Math.max(0, Math.min(1, num(s.background_share, 0.3)));
  let used = 0, bgUsed = 0, unknown = false;
  try { const u = legacy ? await legacy() : await usageOrThrow(uid); used = u.tokens; bgUsed = u.bg; } catch { unknown = true; }
  if (c && c.ent.paid !== true) { used = Math.max(used, num(c.ent.used_today, 0) + c.spent); }
  const allowance = unknown ? 0 : Math.max(0, daily - used);
  const bgAllow = unknown ? 0 : Math.max(0, Math.min(allowance, Math.floor(daily * share) - bgUsed));
  return { enabled: true, gate: true, code: allowance <= 0 ? "limit_daily" : null, plan: "free", total_left: allowance, resets_at: null, reply_cap: 0,
    degraded: "free_fallback", unknown, paid: false, allowance, bg_allowance: bgAllow, used_today: used,
    ratio: allowance <= 0 ? 1 : Math.round((used / Math.max(1, used + allowance)) * 1000) / 1000, state: allowance <= 0 ? "limit" : "ok",
    free: { daily, left: allowance, bg_left: bgAllow }, pass: null, pass_left: 0, pass_today_left: 0, packs: [], pack_left: 0,
    queued_passes: [], live_seconds_left: 0, tokens_per_reply: num(c?.ent.tokens_per_reply, 3700), day: null };
}

// Contract B: one price for everything (raw input + output tokens), no model multipliers. tierOf() stays as a 1x stub
// so the reply cap and the transcribe/image paths read the same way.
type Mult = { pattern: string; tier: string; multiplier: number };
function multipliers(): Promise<Mult[]> { return Promise.resolve([]); }
function tierOf(_model: string, _rows: Mult[]): { tier: string; multiplier: number } { return { tier: "standard", multiplier: 1 }; }

// Charges (never lost): usage_charge (idempotent by request_id), retried once; then parked with usage_charge_enqueue
// (drained by billing_charge_retry_drain); if even that fails the charge waits in this isolate (retried on later
// requests) and is logged in full as `billing_unsaved` so it can be replayed by hand.
type ChargeArgs = { p_user_id: string; p_tokens_in: number; p_tokens_out: number; p_source: string; p_request_id: string };
const unsaved: ChargeArgs[] = [];
let lastFlush = 0;
async function consumeOnce(a: ChargeArgs, s: Record<string, any>): Promise<string | null> {
  try {
    // deno-lint-ignore no-explicit-any
    const { data, error } = await within(rpc("usage_charge", a), Math.max(500, num(s.billing_consume_timeout_ms, 8000)), "charge timeout") as any;
    if (error && missingFn(error.message)) { logMissing("usage_charge"); return null; }
    if (error) return String(error.message ?? error).slice(0, 200) || "error";
    if (data && data.ok === false) {
      if (data.reason === "request_id_conflict" || data.reason === "bad_request") {
        console.error(JSON.stringify({ evt: "billing_refused", uid: a.p_user_id, request_id: a.p_request_id, reason: data.reason }));
        return null;
      }
      return String(data.reason ?? "refused");
    }
    if (Number(data?.unpaid) > 0) {
      // The reply cost more than was left (bounded by the reply cap). SQL logs it as bucket 'unpaid'; never billed.
      console.warn(JSON.stringify({ evt: "billing_unpaid", uid: a.p_user_id, request_id: a.p_request_id, charged: Number(data.charged ?? 0), unpaid: Number(data.unpaid) }));
    }
    return null;
  } catch (e) { return String(e).slice(0, 200); }
}
async function enqueueCharge(a: ChargeArgs, _err: string): Promise<boolean> {
  try {
    // deno-lint-ignore no-explicit-any
    const { data, error } = await within(rpc("usage_charge_enqueue", a), 5000, "enqueue timeout") as any;
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
/** Charges one finished reply: raw prompt + output tokens (Contract B). The request id is minted per request, so a retry
 *  of this call can never charge twice. */
function billingCharge(uid: string, rid: string, tokensIn: number, tokensOut: number, source: string, background: boolean, s: Record<string, any> = {}) {
  const tin = Math.max(0, Math.ceil(Number(tokensIn) || 0)), tout = Math.max(0, Math.ceil(Number(tokensOut) || 0));
  if (!rid || tin + tout <= 0) return;
  noteSpend(uid, tin + tout, background);
  const a: ChargeArgs = { p_user_id: uid, p_tokens_in: tin, p_tokens_out: tout, p_source: billSource(source, background), p_request_id: rid };
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
/** Next EAT midnight (billing day boundary) as ISO. */
function eatReset(): string { return nextEatMidnight(); }
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
/** Contract A balance headers on every chat answer. today-left = what is left of today's allowance; total-left = from
 *  usage_gate when billing is on, else the same as today-left; resets-at = next 00:00 EAT (ISO with +03:00), billing on
 *  or off: usage_gate's resets_at when billing is on, and the legacy daily counter (ai_user_daily.day = EAT date) also
 *  resets at 00:00 EAT. */
function balanceHeaders(ent: Ent | null, st: { cap: number; used: number }): Record<string, string> {
  const today = Math.max(0, Math.floor(st.cap - st.used));
  let total = today, plan = "free";
  if (ent?.gate) {
    // usage_gate (Contract B): total-left, plan and resets-at come straight from SQL; spent since is already in st.
    const spent = Math.max(0, num(ent.allowance, 0) - today);
    total = Math.max(today, Math.floor(num(ent.total_left, today) - spent));
    const reset = resetsAtHeader(ent.resets_at);
    return { "x-submac-today-left": String(today), "x-submac-total-left": String(total), "x-submac-resets-at": reset, "x-submac-plan": String(ent.plan ?? "free") };
  }
  if (ent) {
    const parts = [ent.pass_left, ent.pack_left, ent.free?.left].filter((v) => v !== undefined && v !== null).map(Number).filter(Number.isFinite);
    if (parts.length) total = Math.max(today, Math.floor(parts.reduce((a, b) => a + b, 0)));
    if (ent.pass) plan = /week/i.test(String(ent.pass.product ?? ent.pass.name ?? "")) ? "weekly" : "monthly";
    else if (Number(ent.pack_left ?? 0) > 0) plan = "payg";
  }
  return { "x-submac-today-left": String(today), "x-submac-total-left": String(total), "x-submac-resets-at": resetsAtHeader(), "x-submac-plan": plan };
}
const BAL_EXPOSE = CORS["Access-Control-Expose-Headers"] + ", x-submac-balance";
function balHdr(n: number): Record<string, string> {
  return { "x-submac-balance": String(Math.max(0, Math.floor(n))), "Access-Control-Expose-Headers": BAL_EXPOSE };
}
// What the app can offer on a limit screen: the billing v2 plans (billing.plans; prices come from the app's catalog).
const BUY_OPTIONS = [
  { plan: "weekly", kind: "package", name: "Weekly" }, { plan: "monthly", kind: "package", name: "Monthly" },
  { plan: "payg", kind: "payg", name: "Pay as you go" },
];
function billingOut(e: Ent, s: Record<string, any> = {}) {
  const month = e.paid !== true && e.free && Number(e.free.monthly) > 0 && Number(e.free.month_used ?? 0) >= Number(e.free.monthly);
  const resets = month ? eatMonthReset() : eatReset();
  return { enabled: true, allowance: Number(e.allowance ?? 0), bg_allowance: Number(e.bg_allowance ?? 0), used_today: Number(e.used_today ?? 0),
    ratio: Number(e.ratio ?? 0), state: e.state ?? "ok", paid: e.paid === true, free: e.free ?? null, pass: e.pass ?? null,
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
  if (e.gate) {
    // usage_gate refusal (Contract A codes): limit_daily | limit_total | no_plan, with the fixed friendly text.
    const code: ErrCode = e.code === "limit_total" || e.code === "no_plan" ? e.code : "limit_daily";
    let msg = FRIENDLY[code];
    if (e.degraded === "free_fallback") msg += " (We couldn't confirm your plan just now. If you have one, try again in a minute.)";
    if (typeof s.billing_limit_message === "string" && s.billing_limit_message) msg = s.billing_limit_message;
    return billErr(429, code, msg, e, s, String(e.reason ?? code), {}, { ...hdrs, "x-submac-error": code });
  }
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
  if (e.degraded === "free_fallback") msg += " (We couldn't confirm a pass or pack just now. If you have one, try again in a minute.)";
  if (typeof s.billing_limit_message === "string" && s.billing_limit_message) msg = s.billing_limit_message;
  return billErr(429, "daily_limit", msg, e, s, reason, {}, hdrs);
}
/** Out of balance: a payment made in the last few minutes that is still being confirmed gets its own answer. */
async function pendingPayment(uid: string, s: Record<string, any>): Promise<{ id: string; created_at: string } | null> {
  try {
    // deno-lint-ignore no-explicit-any
    const { data, error } = await within(rpc("billing_payment_pending", { p_older_than_minutes: 0, p_since_hours: 1, p_limit: 100 }), 2000, "pending timeout") as any;
    if (error || !Array.isArray(data)) return null;
    const win = num(s.billing_pending_window_min, 30) * 60_000;
    return data.filter((p: any) => p?.user_id === uid && Date.now() - Date.parse(p.created_at) < win).pop() ?? null;
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
function replyCap(balance: number, mult: number, promptTokens: number, s: Record<string, any>, gateCap = 0): number {
  // Contract B: raw tokens (prompt + reply), one price, so the room is simply what is left after the prompt.
  const room = Math.floor(balance / Math.max(0.01, mult) - promptTokens);
  const capped = gateCap > 0 ? Math.min(room, gateCap) : room;
  return Math.max(Math.max(1, num(s.billing_min_reply_tokens, 512)), capped);
}
const NO_BALANCE = "You've used your allowance for now. Get a pass or a token pack to keep going, or wait for tomorrow's free allowance.";
const CALL_BALANCE = "Your call time is used up. Get a pass or a token pack to keep calling. You can still type to SubMac.";
const BG_PAUSED = "Background tasks are paused until midnight (00:00 EAT) to save your allowance. Your own chats still work.";
// Live: seconds remembered from the last successful charge, used only when usage_charge is down (never cut a call).
const liveLeftCache = new Map<string, { left: number; at: number }>();
function liveLeftGuess(uid: string, s: Record<string, any>): number {
  const c = liveLeftCache.get(uid);
  const grace = Math.max(60, num(s.billing_live_grace_seconds, 300));
  if (!c) return grace;
  return Math.max(grace, c.left - Math.floor((Date.now() - c.at) / 1000));
}

/** Today's legacy usage counter for the billing fallback. Unlike usageOf() (rows() never throws, so a failed read looks
 *  like zero use) this throws when the row cannot be read, so the fallback answers "busy" instead of a full free tier. */
async function usageOrThrow(uid: string) {
  const r = await fetch(`${REST}/ai_user_daily?select=tokens,requests,bg_tokens&user_id=eq.${uid}&day=eq.${today()}&limit=1`, { headers: SH });
  if (!r.ok) { await r.body?.cancel(); throw new Error("usage " + r.status); }
  const j = await r.json();
  const data = Array.isArray(j) ? j[0] : null;
  return { tokens: Number(data?.tokens ?? 0), requests: Number(data?.requests ?? 0), bg: Number(data?.bg_tokens ?? 0) };
}
/** PostgREST insert returning the new row (service key). Never throws. */
async function insertRow(table: string, row: Record<string, unknown>): Promise<DbRes> {
  try {
    const r = await fetch(`${REST}/${table}`, { method: "POST", headers: { ...SH, prefer: "return=representation" }, body: JSON.stringify(row) });
    const j = await r.json().catch(() => null);
    if (!r.ok) return { data: null, error: { message: (j && j.message) || `${table} ${r.status}` } };
    return { data: Array.isArray(j) ? j[0] ?? null : j, error: null };
  } catch (e) { return { data: null, error: { message: String(e) } }; }
}

// ---- Safety flags (admin Users section). Never stores chat text: a cheap keyword screen on the newest user message;
// on a hit, a small check by the same model (max_tokens 120) confirms it and only {category, severity, short reason} is saved via flag_user. ----
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
    await rpc("flag_user", { p_uid: uid, p_category: cat, p_severity: sev, p_source: "moderation", p_reason: reason.slice(0, 200), p_meta: { rule: hit[0] } });
  })().catch(() => {});
  // deno-lint-ignore no-explicit-any
  (globalThis as any).EdgeRuntime?.waitUntil?.(job);
}
async function classify(text: string, cfg: Config): Promise<{ category: string; severity: string; reason: string } | null> {
  const alias = chatAlias(cfg);
  if (!alias) return null;
  const sys = "You are a safety reviewer for an AI assistant app. Decide if the user's message asks for or describes: fraud_scam, illegal (serious crime, weapons, drugs), " +
    "abuse_harassment, minor_sexual (any sexual content involving minors), self_harm (the user may hurt themselves), spam_automation, or none. " +
    "Ordinary questions, fiction, news, safety advice and victims asking for help are none. Reply with JSON only: " +
    '{"category":"<one of the labels>","severity":"low|medium|high","reason":"<at most 12 words describing the behaviour; never quote the message>"}';
  for (const r of alias.routes.filter((x) => x.healthy).concat(alias.routes.filter((x) => !x.healthy)).slice(0, 2)) {
    await ensureKeys(cfg, [r]);
    for (const k of keysInOrder(r).slice(0, 1)) {
      try {
        const ctl = new AbortController(); const t = setTimeout(() => ctl.abort(), 10_000);
        const res = await fetch(r.base_url.replace(/\/$/, "") + "/chat/completions", { method: "POST", signal: ctl.signal,
          headers: { "content-type": "application/json", authorization: `Bearer ${k.key}`, "user-agent": "submac-proxy/1" },
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
  const data = (await rows(`ai_user_daily?select=tokens,requests,bg_tokens&user_id=eq.${uid}&day=eq.${today()}&limit=1`))[0];
  return { tokens: Number(data?.tokens ?? 0), requests: Number(data?.requests ?? 0), bg: Number(data?.bg_tokens ?? 0) };
}

/** Plan 2.2 background lane: bots and offices get background_share (default 0.3) of the daily cap. Their use counts
 *  in the total too; once the share (or the cap) is reached they pause until the next EAT day, while the user's own
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
  const job = rpc("ai_record_usage", { p }).then(() => {}, () => {});
  // deno-lint-ignore no-explicit-any
  (globalThis as any).EdgeRuntime?.waitUntil?.(job);
}
function markKey(id: string, ok: boolean, error: string | null, cooldown: number) {
  if (!ok && cooldown > 0) localCooldown.set(id, Date.now() + cooldown * 1000);
  if (ok) localCooldown.delete(id);
  const job = rpc("ai_mark_key", { p_key_id: id, p_ok: ok, p_error: error ?? "", p_cooldown_seconds: cooldown }).then(() => {}, () => {});
  // deno-lint-ignore no-explicit-any
  (globalThis as any).EdgeRuntime?.waitUntil?.(job);
}

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

// Never wait on a promise forever: some upstreams hold the connection open without sending anything, and an abort
// signal alone has not always freed the request. Race it against a timer.
function within<T>(p: Promise<T>, ms: number, what: string): Promise<T> {
  let t: ReturnType<typeof setTimeout> | undefined;
  return Promise.race([p, new Promise<T>((_, rej) => { t = setTimeout(() => rej(new Error(what)), ms); })]).finally(() => clearTimeout(t));
}


function features(cfg: Config) {
  const s = cfg.settings;
  const has = (a: string) => !!cfg.aliases.find((x) => x.alias === a && x.routes.length);
  return {
    live: s.live_enabled !== false && !!s.live_provider,
    transcribe: s.transcribe_enabled !== false && !!s.live_provider,
    image: has("submac-image"),
    video: false,
    live_voices: ["Kore", "Puck", "Charon", "Aoede", "Fenrir", "Leda", "Orus", "Zephyr"],
  };
}

async function providerKeys(name: string): Promise<{ id: string; key: string }[]> {
  const p = (await rows(`ai_providers?select=id&name=eq.${encodeURIComponent(name)}&enabled=eq.true&limit=1`))[0];
  if (!p) return [];
  const ks = await rows(`ai_keys?select=id,cooldown_until&provider_id=eq.${p.id}&enabled=eq.true`);
  const now = Date.now();
  const usable = (ks ?? []).filter((k: any) => !(k.cooldown_until && Date.parse(k.cooldown_until) > now) && (localCooldown.get(k.id) ?? 0) < now);
  usable.sort(() => Math.random() - 0.5);
  const out: { id: string; key: string }[] = [];
  for (const k of usable.slice(0, 4)) {
    const { data } = await rpc("ai_key_secret", { p_key_id: k.id });
    if (data?.key) out.push({ id: k.id, key: data.key });
  }
  return out;
}

/** Live pool (live_routes), separate from the chat keys. Sticky like the chat router: everyone gets the same order
 *  (lowest priority first, then oldest), so the first usable key is used until it fails and rests, then the next.
 *  Only ids and rests here: the secret is decrypted just for the key being tried. */
async function liveRoutes(): Promise<{ id: string; model: string | null; provider: string }[]> {
  const lrows = await rows("live_routes?select=id,provider,model,priority,cooldown_until,created_at&enabled=eq.true&order=priority.asc,created_at.asc");
  const now = Date.now();
  return (lrows ?? []).filter((r: any) => r.provider === "Google Gemini" &&
    !(r.cooldown_until && Date.parse(r.cooldown_until) > now) && (localCooldown.get("live:" + r.id) ?? 0) < now)
    .slice(0, 6).map((r: any) => ({ id: r.id, model: r.model ?? null, provider: r.provider }));
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
  const job = rpc("live_mark_route", { p_id: id, p_ok: ok, p_error: error ?? "", p_cooldown_seconds: cooldown }).then(() => {}, () => {});
  // deno-lint-ignore no-explicit-any
  (globalThis as any).EdgeRuntime?.waitUntil?.(job);
}

// ---- Call minutes (Plan 6 item 3) ----
type Mins = { ok?: boolean; reason?: string; call_id?: string; enabled?: boolean; limit_minutes?: number; used_seconds?: number;
  seconds_left?: number; minutes_left?: number; resets_at?: string; stop?: boolean; call_seconds?: number; added_seconds?: number };
const HEARTBEAT_S = 30;
function numOrNull(v: unknown): number | null { const n = Number(v); return Number.isFinite(n) && n >= 0 ? Math.floor(Math.min(n, 86400)) : null; }
function minutesUsedMessage() { return "Today's call minutes are used up. They come back at midnight UTC. You can still type to SubMac."; }
/** The minute fields every Live answer carries. */
function minsOut(m: Mins) {
  return { minutes_left: Number(m.minutes_left ?? 0), seconds_left: Number(m.seconds_left ?? 0), limit_minutes: Number(m.limit_minutes ?? 0),
    used_seconds: Number(m.used_seconds ?? 0), live_enabled: m.enabled !== false, resets_at: m.resets_at ?? null };
}
async function minutesOf(uid: string) {
  const { data } = await rpc("live_minutes_left", { p_uid: uid });
  return (data ?? {}) as Mins;
}
/** POST /live-usage {call_id, seconds, end?}: the app's heartbeat (every 30 s while connected, once when the
 *  line connects with seconds 0, and once on hang-up with end: true). The server counts its own time between
 *  heartbeats (at most 120 s per gap); the app's count can only fill a longer gap, never pass the wall time. */
async function liveUsage(uid: string, body: any, billing = false, s: Record<string, any> = {}): Promise<Response> {
  const cid = typeof body?.call_id === "string" ? body.call_id : "";
  if (!cid) return json({ error: { code: "bad_request", message: "call_id needed" } }, 400);
  const { data, error } = await rpc("live_call_beat", { p_uid: uid, p_call: cid, p_reported: numOrNull(body.seconds), p_kind: body?.end === true ? "end" : "beat" });
  if (error) return json({ error: { code: "busy", message: "Couldn't save call time just now." } }, 503);
  const m = data as Mins;
  if (billing) {
    // Billing on: the call is paid from the billing balance; the old daily minutes (live_call_daily) are only counted.
    const charged = m.reason === "no_call" ? null : await liveCharge(uid, cid, m, s);
    if (charged === "error") {
      // usage_charge is down: never cut the call for it. The seconds stay on the call row (live_call_beat); the time shown is the last known balance (or a grace) so the app does not hang up either.
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
    // Billing does not apply: answer as before, but never stop a call on the old daily limit.
    return json({ ok: m.ok !== false, reason: m.reason ?? null, call_id: cid, call_seconds: Number(m.call_seconds ?? 0), added_seconds: Number(m.added_seconds ?? 0),
      stop: m.enabled === false && body?.end !== true, ...minsOut(m), message: null }, m.reason === "no_call" ? 404 : 200);
  }
  return json({ ok: m.ok !== false, reason: m.reason ?? null, call_id: cid, call_seconds: Number(m.call_seconds ?? 0), added_seconds: Number(m.added_seconds ?? 0),
    stop: m.stop === true || (m.enabled === false && body?.end !== true), ...minsOut(m), message: m.stop ? minutesUsedMessage() : null }, m.reason === "no_call" ? 404 : 200);
}

/** Billing on: charges the seconds a heartbeat added through usage_charge(source 'live', tokens_in = seconds; SQL prices
 *  them per minute), idempotent per call + call_seconds, and returns the Live seconds today's balance still covers;
 *  null when SQL says billing is off (or the functions are not deployed); "error" when the charge failed (tried twice). */
async function liveCharge(uid: string, callId: string, m: Mins, s: Record<string, any> = {}): Promise<number | null | "error"> {
  const added = Math.max(0, Math.floor(Number(m.added_seconds ?? 0)));
  const tpm = Math.max(1, num(s.billing_live_tokens_per_minute, 40000));
  const a: ChargeArgs = { p_user_id: uid, p_tokens_in: added, p_tokens_out: 0, p_source: "live", p_request_id: `live:${callId}:${Number(m.call_seconds ?? 0)}` };
  let lastErr = "";
  for (let i = 0; i < 2; i++) {
    let data: any = null, error: { message: string } | null = null;
    if (added > 0) {
      ({ data, error } = await within(rpc("usage_charge", a), 5000, "live charge timeout").then((x) => x, (e: unknown) => ({ data: null, error: { message: String(e) } })));
    } else {
      // Nothing to charge (the line just connected): read what is left.
      ({ data, error } = await within(rpc("usage_gate", { p_user_id: uid, p_source: "live" }), 3000, "live gate timeout").then((x) => x, (e: unknown) => ({ data: null, error: { message: String(e) } })));
      if (data && typeof data === "object" && data.allow === false) data = { ...data, today_left: 0 };
    }
    if (error && missingFn(error.message)) { logMissing("usage_charge"); return null; }
    if (!error && data && data.enabled === false) return null;
    if (!error && data && data.ok !== false && Number.isFinite(Number(data.today_left))) {
      const left = Math.max(0, Math.floor((Number(data.today_left) * 60) / tpm));
      liveLeftCache.delete(uid);
      if (liveLeftCache.size >= PRE_CACHE_MAX) liveLeftCache.delete(liveLeftCache.keys().next().value!);
      liveLeftCache.set(uid, { left, at: Date.now() });
      return left;
    }
    lastErr = error ? String(error.message ?? error).slice(0, 200) : String(data?.reason ?? "refused");
  }
  // Contract B: a Live charge that failed twice is parked with usage_charge_enqueue (same request id, so it can never
  // charge twice); if even that fails it waits in this isolate like a chat charge. The call itself is never cut for it.
  if (added > 0) {
    if (await enqueueCharge(a, lastErr)) console.warn(JSON.stringify({ evt: "billing_queued", uid, request_id: a.p_request_id, error: lastErr }));
    else keepUnsaved(a, lastErr);
  }
  return "error";
}
/** minsOut() with the time left taken from the billing balance (limit_minutes = what is left now). */
function liveMinsOut(m: Mins, left: number) {
  return { ...minsOut(m), minutes_left: Math.floor(left / 60), seconds_left: left, limit_minutes: Math.floor(left / 60), billing: true };
}

async function mediaRoute(req: Request, url: URL, uid: string, cfg: Config): Promise<Response> {
  const s = cfg.settings;
  if (s.kill_switch === true) return json({ error: { code: "paused", message: "SubMac is taking a short break. Please try again in a few minutes." } }, 503);
  const blocked = (await rows(`ai_blocked_users?select=user_id&user_id=eq.${uid}&limit=1`)).length > 0;
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
      const { data, error } = await rpc("live_call_beat", { p_uid: uid, p_call: body.call_id, p_reported: numOrNull(body.seconds), p_kind: "resume" });
      if (error) return json({ error: { code: "busy", message: "Live voice is busy right now. Please try again in a moment." } }, 503);
      mins = data as Mins;
      if (!mins.ok) return json({ error: { code: "call_ended", message: "This call has ended. Tap Call again to start a new one." }, ...minsOut(mins) }, 409);
      if (bill) {
        const c = await liveCharge(uid, String(body.call_id), mins, s);
        // A charge outage never ends a call that is going: the reconnect gets the last known time (or a grace).
        billLeft = c === "error" ? liveLeftGuess(uid, s) : c;
      }
    } else {
      const [{ data, error }, ent0] = await Promise.all([rpc("live_call_start", { p_uid: uid }), bill ? billingPrecheck(uid, s, undefined, "live") : Promise.resolve(null)]);
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
          const { data: row, error: e2 } = await insertRow("live_calls", { user_id: uid });
          if (e2 || !row?.id) return json({ error: { code: "busy", message: "Live voice is busy right now. Please try again in a moment." } }, 503);
          mins = { ...mins, ok: true, call_id: row.id };
        }
      }
    }
    if (mins.enabled === false) return json({ error: { code: "live_off", message: "Calls are switched off for your account. You can still type to SubMac." }, ...minsOut(mins), minutes_left: 0, seconds_left: 0 }, 429);
    if (billLeft !== null) {
      if (billLeft <= 0) {
        // A new call opened by live_call_start that the balance can't pay for is closed with nothing counted.
        if (!resume && mins.call_id) await rpc("live_call_beat", { p_uid: uid, p_call: mins.call_id, p_reported: 0, p_kind: "end" });
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
    // Live has its own pool (live_routes): never the chat keys, and failures here never touch ai_keys.
    // 5 s per Google token call, 12 s in total; the phone hanging up stops it.
    const tLive = Date.now();
    for (const lr of await liveRoutes()) {
      const left = 12_000 - (Date.now() - tLive);
      if (left < 500 || req.signal.aborted) break;
      const sec = await within(rpc("live_route_secret", { p_id: lr.id }, AbortSignal.timeout(Math.min(3000, left))), Math.min(3000, left) + 100, "secret timeout").catch(() => null);
      const key = sec?.data?.key ? String(sec.data.key) : "";
      if (!key) continue;
      const model = lr.model || defModel;
      const exp = new Date(Date.now() + passSecs * 1000).toISOString();
      // newSessionExpireTime: the pass must be opened within 3 min (covers a slow setup); expireTime bounds this connection.
      // Single use: every reconnect (goAway about every 10 min, or a drop) asks for a fresh pass with resume=true.
      const start = new Date(Date.now() + 3 * 60_000).toISOString();
      const per = Math.max(500, Math.min(5_000, 12_000 - (Date.now() - tLive)));
      let r: Response | null = null;
      try {
        r = await fetch("https://generativelanguage.googleapis.com/v1alpha/auth_tokens", {
          method: "POST", headers: { "content-type": "application/json", "x-goog-api-key": key },
          body: JSON.stringify({ uses: 1, expireTime: exp, newSessionExpireTime: start }),
          signal: AbortSignal.any([req.signal, AbortSignal.timeout(per)]),
        });
      } catch (e) { if (req.signal.aborted) break; markLive(lr.id, false, `live token: ${String(e).slice(0, 120)}`, 20); continue; }
      if (!r.ok) { const t = (await r.text().catch(() => "")).slice(0, 200); markLive(lr.id, false, `live token ${r.status} ${t}`, liveCooldown(r.status, t)); continue; }
      const j = await r.json();
      // Write the key's state only when it changes (it was failing before); a plain success writes nothing.
      if (localCooldown.has("live:" + lr.id)) markLive(lr.id, true, null, 0);
      // Logged for stats only: quota_tokens 0, so Live never touches the token allowance.
      record({ user_id: uid, source: "live", alias: resume ? "live-resume" : "live", provider: lr.provider, model, key_id: lr.id, status: 200, prompt_tokens: 0, completion_tokens: 0, quota_tokens: 0, total_ms: Date.now() - t0 });
      return json({ token: j.name, model, expires_at: exp, minutes: Math.ceil(passSecs / 60), call_id: callId, ...(billLeft !== null ? liveMinsOut(mins, billLeft) : minsOut(mins)),
        heartbeat_seconds: HEARTBEAT_S,
        ws_url: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContentConstrained" }, 200,
        billLeft !== null ? balHdr(billLeft) : {});
    }
    // No pass: a new call that never got a line is closed with nothing counted.
    if (!resume && callId) await rpc("live_call_beat", { p_uid: uid, p_call: callId, p_reported: 0, p_kind: "end" });
    record({ user_id: uid, source: "live", alias: "live", provider: "live-pool", status: 503, error: "no usable live route" });
    return json({ error: { code: "busy", message: "Live voice is busy right now. Please try again in a moment." } }, 503);
  }

  // Transcription and pictures still use the token allowance (billing on: the billing balance, charged after).
  if (bill) flushUnsaved(s);
  const mediaSrc = url.pathname.endsWith("/image") ? "image" : "transcribe";
  const [ent, mrows] = bill ? await Promise.all([billingPrecheck(uid, s, undefined, mediaSrc), multipliers()]) : [null, [] as Mult[]];
  const rid = bill ? "media:" + crypto.randomUUID() : "";
  if (ent) {
    if (Number(ent.allowance ?? 0) <= 0) return await emptyReply(uid, ent, s);
  } else {
    const used = await usageOf(uid);
    const st = stateFor(used.tokens, withCap(s, await capOf(uid, s)));
    if (st.state === "limit") return json({ error: { code: "daily_limit", message: s.limit_message } }, 429);
  }

  if (url.pathname.endsWith("/transcribe")) {
    if (!feat.transcribe) return json({ error: { code: "unavailable", message: "Transcription isn't available right now." } }, 503);
    const audio = String(body.audio_base64 ?? "");
    const mime = String(body.mime ?? "audio/mp4");
    if (!audio) return json({ error: { message: "No audio" } }, 400);
    if (audio.length > Number(s.transcribe_max_b64 ?? 26_000_000)) return json({ error: { code: "too_large", message: "This recording is too long to turn into text in one go. Try a shorter one (about 30 minutes or less)." } }, 413);
    const models: string[] = Array.isArray(s.transcribe_models) ? s.transcribe_models : ["gemini-3.5-flash-lite", "gemini-3-flash-preview"];
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
          billingCharge(uid, rid, w, 0, "transcribe", false, s);
          if (ent && text) return json({ text }, 200, balHdr(Number(ent.allowance) - cost));
        }
        if (text) return json({ text });
      }
    }
    return json({ error: { code: "busy", message: "Couldn't turn the recording into text right now. Please try again in a moment." } }, 503);
  }

  // image
  const alias = cfg.aliases.find((a) => a.alias === "submac-image");
  if (!alias?.routes.length) return json({ error: { code: "unavailable", message: "Image creation isn't available yet." } }, 503);
  const imgRoutes = alias.routes;
  for (const r of imgRoutes) {
    await ensureKeys(cfg, [r]);
    for (const k of keysInOrder(r)) {
      const res = await fetch(r.base_url.replace(/\/$/, "") + "/images/generations", {
        method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${k.key}` },
        body: JSON.stringify({ ...(r.extra_body ?? {}), model: r.model, prompt: String(body.prompt ?? ""), n: 1, size: String(body.size ?? "1024x1024"), response_format: "b64_json" }),
      }).catch(() => null);
      if (!res || !res.ok) { markKey(k.id, false, `image ${res?.status ?? 0}`, cooldownFor(res?.status ?? 0)); break; }
      const j = await res.json();
      record({ user_id: uid, source: "image", alias: "submac-image", provider: r.provider, model: r.model, key_id: k.id, status: 200, prompt_tokens: Number(s.image_tokens ?? 4000), completion_tokens: 0, total_ms: Date.now() - t0 });
      if (rid) {
        const icost = Math.ceil(Number(s.image_tokens ?? 4000) * tierOf(r.model, mrows).multiplier);
        billingCharge(uid, rid, Number(s.image_tokens ?? 4000), 0, "image", false, s);
        if (ent) return json(j, 200, balHdr(Number(ent.allowance) - icost));
      }
      return json(j);
    }
  }
  return json({ error: { code: "busy", message: "Image creation is busy right now. Please try again in a moment." } }, 503);
}

/** Server-Timing on every answer (ms): gate = the one DB round trip (checks + router pointer), upstream = until the
 *  model's first real output (all fallbacks), total = until this answer starts. */
Deno.serve(async (req) => {
  const t0 = performance.now();
  const tm: Record<string, number> = {};
  let res: Response;
  try { res = await handle(req, tm); }
  catch (e) {
    // Never raw error text to the app (Contract A): the detail goes to the log only.
    console.error(JSON.stringify({ evt: "ai_chat_error", error: String(e).slice(0, 300) }));
    res = errJson(500, "server", "server");
  }
  tm.total = performance.now() - t0;
  try {
    isoHits++;
    res.headers.set("Server-Timing", Object.entries(tm).map(([k, v]) => `${k};dur=${v.toFixed(1)}`).join(", ") + `, iso;desc="${ISO}-${isoHits}"`);
  } catch { /* immutable headers: leave as is */ }
  return res;
});

type Plan = {
  error?: Response; alias: Alias; routes: Route[]; messages: any[]; max_tokens: number; stream: boolean; needTools: boolean;
  promptEstimate: number; smallestWindow: string; roomOf: (r: Route) => number; passthrough: Record<string, unknown>; effort: Effort | null;
};
/** Billing on (and usage_gate answered): what makePlan needs to keep free users on Standard models, cap the reply by
 *  the balance and refuse a prompt the balance can't pay for. Absent = no billing, unchanged. */
type BillPlan = { ent: Ent; mrows: Mult[]; balance: number; hdrs: Record<string, string> };
/** Allowance state, background room and spendable balance from entitlements (same numbers the v27 billing path used). */
function billCtx(ent: Ent, mrows: Mult[], background: boolean) {
  const st = billState(ent);
  const bgLeft = Math.max(0, Number(ent.bg_allowance ?? 0));
  const balance = background ? Math.min(bgLeft, st.cap - st.used) : st.cap - st.used;
  const bx: BillPlan = { ent, mrows, balance, hdrs: { "x-submac-usage": st.ratio.toFixed(3), "x-submac-state": st.state } };
  return { st, bgLeft, balance, bx };
}
const TOO_LONG_MSG = "Request too large to send in one go. Start a new chat or send less at once."; // the app compacts on this wording
/** Everything about the model call that depends only on the request, the config and the allowance state. One route
 *  list (alias `submac`); the request's needs are capability filters on it: tools, vision when there are pictures,
 *  context fit. The over-limit grace ("light") is the same route list with a short max_tokens, never another model. */
function makePlan(cfg: Config, body: any, state: string, bx?: BillPlan, effort: Effort | null = null): Plan {
  const s = cfg.settings;
  const alias = chatAlias(cfg);
  const empty = { alias: alias as Alias, routes: [], messages: [], max_tokens: 0, stream: false, needTools: false, promptEstimate: 0, smallestWindow: "", roomOf: () => 0, passthrough: {}, effort };
  if (!alias) return { ...empty, error: errJson(503, "busy", "no_alias", undefined, true) };

  let maxOut = alias.max_output_tokens;
  if (state === "light") maxOut = Math.min(maxOut, Number(s.grace_max_output_tokens ?? 400));
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
    return { ...empty, error: errJson(413, "too_long", "too_long", TOO_LONG_MSG) };
  }
  // Billing gates volume, never the model: the list is filtered by capability only. Pictures need a route that can see
  // (a filter, not a separate vision model; a model that can't see would reject or ignore the picture).
  const images = hasImages(messages);
  const routes = alias.routes.filter((r) => (!needTools || r.tools) && (!images || r.vision));
  // Fit check: the prompt (with a safety margin, the estimate is rough) plus room for the reply must fit the model's
  // window. Routes that can't fit are skipped, so a swap never truncates or fails.
  const windowOf = (r: Route) => Number(r.context_window) || 128000;
  const promptNeed = Math.ceil(promptEstimate * 1.15);
  const need = promptNeed + Math.min(max_tokens, 4096);
  const roomW = (r: Route) => Math.max(1024, Math.min(max_tokens, windowOf(r) - promptNeed - 256));
  const roomOf = bx ? (r: Route) => Math.min(roomW(r), replyCap(bx.balance, tierOf(r.model, bx.mrows).multiplier, promptEstimate, s, num(bx.ent.reply_cap, 0))) : roomW;
  // CB-23: the window the app must keep a conversation under is the smallest of ALL the alias's healthy text routes,
  // not just the routes that can serve this request (a photo turn would otherwise report 1M and the next text turn
  // could land on a 128k route).
  const healthyWindows = alias.routes.filter((r) => r.healthy).map(windowOf);
  const smallestWindow = String(Math.min(...(healthyWindows.length ? healthyWindows : alias.routes.map(windowOf)), 1_000_000));
  const fitting = routes.filter((r) => need <= windowOf(r));
  if (routes.length && !fitting.length) {
    return { ...empty, error: errJson(413, "too_long", "too_long", TOO_LONG_MSG, false, { "x-submac-window": smallestWindow }) };
  }
  if (bx) {
    const minMult = fitting.length ? Math.min(...fitting.map((r) => tierOf(r.model, bx.mrows).multiplier)) : 1;
    const needIn = Math.ceil(promptEstimate * minMult);
    if (needIn > bx.balance + Math.max(0, num(s.billing_overrun_tokens, 8000))) {
      return { ...empty, error: billErr(429, "limit_daily", `This message is too big for what's left of your allowance (it needs about ${needIn.toLocaleString("en-US")} tokens, ` +
        `${Math.max(0, Math.floor(bx.balance)).toLocaleString("en-US")} left). Start a new chat or send less at once.`,
        bx.ent, s, "too_big_for_balance", { needed: needIn }, { ...bx.hdrs, "x-submac-error": "limit_daily" }, bx.balance) };
    }
  }
  const passthrough: Record<string, unknown> = {};
  for (const k of ["temperature", "top_p", "tools", "tool_choice", "response_format", "stop", "parallel_tool_calls", "seed"]) {
    if (body[k] !== undefined) passthrough[k] = body[k];
  }
  return { alias, routes: fitting, messages, max_tokens, stream, needTools, promptEstimate, smallestWindow, roomOf, passthrough, effort };
}

function payloadFor(p: Plan, r: Route, s: Record<string, any> = {}) {
  return {
    ...p.passthrough, ...thinkingExtra(r, p.effort), model: r.model, messages: withThoughtSignatures(p.messages, r),
    max_tokens: clampOut(p.roomOf(r), providerOutCap(r, s), routeCap.get(r.route_id)), stream: p.stream,
    ...(p.stream ? { stream_options: { include_usage: true } } : {}),
  };
}
/** The model allows fewer output tokens than asked: remember its limit; true = retry it once, smaller. */
function shrinkFor(p: Plan, s: Record<string, any> = {}) {
  return (r: Route, txt: string): boolean => {
    if (!/max_tokens|max_completion|max_output|output tokens|maximum.{0,40}tokens|tokens.{0,40}(exceed|too large|limit)/i.test(txt)) return false;
    const was = clampOut(p.roomOf(r), providerOutCap(r, s), routeCap.get(r.route_id));
    const m = txt.match(/(?:at most|maximum(?: value)?(?: is| of)?|up to|<=|less than or equal to)\s*(\d{3,6})/i);
    const n = m ? Number(m[1]) : 0;
    const next = n >= 1024 && n < was ? n : (was > 8192 ? 8192 : 4096);
    if (next < was) { routeCap.set(r.route_id, next); return true; }
    return false;
  };
}
/** Counts a failure of the route the shared pointer means; SQL swaps the pointer (compare-and-set) at 3 hard failures
 *  or 2 first-byte timeouts within 60 s and rests the old route 1 -> 2 -> 4 -> 8 -> 15 min. One write per failure. */
function routerReport(routeId: string, kind: "hard" | "fb_timeout", next: string | null) {
  waitLater(rpc("ai_router_report", { p_route_id: routeId, p_kind: kind, p_next_route_id: next }).then(({ data, error }) => {
    if (error) { console.error(JSON.stringify({ evt: "router_report_failed", error: error.message.slice(0, 200) })); return; }
    if (data?.swapped) {
      localCooldown.set("route:" + routeId, Date.now() + Number(data.rest_seconds ?? 60) * 1000);
      console.log(JSON.stringify({ evt: "router_swap", from: routeId, to: data.current_route_id ?? null, kind, rest_seconds: data.rest_seconds ?? null }));
    }
  }, () => {}));
}

/** Swap-back probe result (CB-15): ok -> ai_router_home moves the pointer from -> home (compare-and-set in SQL);
 *  a hard failure / first-byte timeout -> SQL rests the preferred route one ladder step. One write per probe. */
function routerHome(homeId: string, from: string, ok: boolean, kind: "hard" | "fb_timeout" | null) {
  waitLater(rpc("ai_router_home", { p_home: homeId, p_from: from, p_ok: ok, p_kind: kind }).then(({ data, error }) => {
    if (error) { console.error(JSON.stringify({ evt: "router_home_failed", error: error.message.slice(0, 200) })); return; }
    if (data?.swapped) {
      localCooldown.delete("route:" + homeId);
      console.log(JSON.stringify({ evt: "router_swap", from, to: homeId, kind: "home" }));
    } else if (data?.rested) localCooldown.set("route:" + homeId, Date.now() + Number(data.rest_seconds ?? 60) * 1000);
  }, () => {}));
}
/** The alias's preferred route: its first healthy route by priority (ai_config_lite orders routes by priority). */
function homeOf(alias: Alias | null | undefined): string | null {
  return alias?.routes.find((r) => r.healthy)?.route_id ?? null;
}

async function handle(req: Request, tm: Record<string, number>): Promise<Response> {
  const tReq = Date.now();
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const url = new URL(req.url);
  const internal = req.headers.has("x-submac-internal") ? await internalUser(req) : null;
  const uid = internal ?? await userFromJwt(req);
  if (!uid) return json({ error: { code: "auth", message: "Please sign in again." } }, 401);

  if (url.pathname.endsWith("/status")) {
    const tG = performance.now();
    const cold = !warmCfg();
    tm.warm = cold ? 0 : 1;
    let g: Gate, m: Mins;
    const gP = gate(uid, cold, false);
    gP.catch(() => {});
    const entP0 = !cold && billingOn(warmCfg()!.settings) ? billingPrecheck(uid, warmCfg()!.settings, () => gP.then((x) => x.usage)) : null;
    entP0?.catch(() => {});
    try { [g, m] = await Promise.all([gP, minutesOf(uid)]); }
    catch (e) { console.error(JSON.stringify({ evt: "status_gate_failed", error: String(e).slice(0, 200) })); return errJson(503, "busy", "busy", undefined, true); }
    tm.gate = performance.now() - tG;
    const cfg = cache?.cfg;
    if (!cfg) return errJson(503, "busy", "busy", undefined, true);
    const s = cfg.settings;
    const c = capFrom(g.cap, s);
    const sc = withCap(s, c);
    const bgs = backgroundFor(g.usage.tokens, g.usage.bg, sc);
    const ent = billingOn(s) ? await (entP0 ?? billingPrecheck(uid, s, () => Promise.resolve(g.usage))) : null;
    if (ent) {
      tm.billing = performance.now() - tG;
      const bst = billState(ent); const left = Math.max(0, Number(ent.live_seconds_left ?? 0));
      const calls = ent.degraded === "free_fallback" ? { ...minsOut(m), billing: true } : liveMinsOut(m, left);
      return json({ cap: bst.cap, used: bst.used, ratio: bst.ratio, state: bst.state, requests: g.usage.requests, bonus: bonusOut(c), resets: "daily (00:00 EAT)",
        message: s.billing_limit_message ?? NO_BALANCE, features: features(cfg), calls, background_left: Number(ent.bg_allowance ?? 0),
        background: { share: bgs.share, cap: bgs.cap, used: bgs.used, left: Number(ent.bg_allowance ?? 0), ratio: Number(bgs.ratio.toFixed(3)), paused: Number(ent.bg_allowance ?? 0) <= 0 },
        billing: billingOut(ent, s) }, 200, { ...balHdr(bst.allowance), ...balanceHeaders(ent, bst) });
    }
    const stx = stateFor(g.usage.tokens, sc);
    return json({ ...stx, requests: g.usage.requests, bonus: bonusOut(c), resets: "daily (00:00 EAT)", message: s.limit_message, features: features(cfg),
      calls: minsOut(m), background_left: bgs.left,
      background: { share: bgs.share, cap: bgs.cap, used: bgs.used, left: bgs.left, ratio: Number(bgs.ratio.toFixed(3)), paused: bgs.paused } }, 200, balanceHeaders(null, stx));
  }
  const media = req.method === "POST" && /\/(live-token|live-usage|transcribe|image)$/.test(url.pathname);
  if (url.pathname.endsWith("/models") || media || req.method !== "POST") {
    let cfg: Config;
    const tCfg = performance.now();
    try { cfg = await config(); } catch (e) { console.error(JSON.stringify({ evt: "config_failed", error: String(e).slice(0, 200) })); return errJson(503, "busy", "busy", undefined, true); }
    tm.cfg = performance.now() - tCfg;
    if (url.pathname.endsWith("/models")) {
      // One public model. (Image creation keeps its own endpoint.)
      return json({ object: "list", data: [{ id: CHAT_ALIAS, object: "model", owned_by: "submac" }] });
    }
    if (media) return await mediaRoute(req, url, uid, cfg);
    return json({ error: { message: "POST only" } }, 405);
  }

  // ---- Chat. One round trip (ai_gate, 2 s limit): blocked, burst, today's usage, cap and the shared router pointer;
  // on a cold isolate also the config and the current route's keys.
  const BAD = Symbol("bad json");
  const parsed = await req.json().catch(() => BAD);
  const body: any = parsed === BAD || !parsed || typeof parsed !== "object" ? {} : parsed;
  const source = internal ? "bot-cloud" : (req.headers.get("x-submac-source") ?? "agent").slice(0, 20);
  // Background lane (Plan 2.2): the cloud runner, or app work nobody is watching (bot wakes, office work).
  // CB-45: an owner-typed bot chat ('bot-chat') is always the user's lane, never the bot/background share.
  const background = !!internal || ((req.headers.get("x-submac-lane") ?? "").toLowerCase() === "background" && !chatLane(source));
  const lane = background ? "background" : "user";
  // Sticky chats: scoped to the user so two users' ids can never collide.
  const chatHdr = (req.headers.get("x-submac-chat") ?? "").slice(0, 64);
  const chat = chatHdr ? uid + ":" + chatHdr : "";
  // Any "submac*" model name (submac, submac-smart/fast/think/lite/vision/somali from older apps) is the one model.
  const effort = effortOf(req.headers.get("x-submac-effort"));
  const needTools0 = Array.isArray(body.tools) && body.tools.length > 0;

  const warm = warmCfg();
  tm.warm = warm ? 1 : 0;
  const tG = performance.now();
  const gateP = gate(uid, !warm, needTools0);
  gateP.catch(() => {});
  const bill0 = !!warm && billingOn(warm.settings);
  const billP: Promise<[Ent | null, Mult[]]> | null = bill0
    ? Promise.all([billingPrecheck(uid, warm!.settings, () => gateP.then((x) => x.usage), billSource(source, background)), multipliers()]) : null;
  billP?.catch(() => {});
  let g: Gate;
  try { g = await gateP; } catch (e) {
    console.error(JSON.stringify({ evt: "gate_failed", error: String(e).slice(0, 200), ms: Math.round(performance.now() - tG) }));
    return errJson(503, "busy", "busy", undefined, true);
  }
  tm.gate = performance.now() - tG;
  const cfg = cache?.cfg;
  if (!cfg) return errJson(503, "busy", "busy", undefined, true);
  const s = cfg.settings;
  // Checks in the same order as before: paused, blocked, bad JSON, burst, allowance, background share.
  if (s.kill_switch === true) return errJson(503, "busy", "paused", "SubMac is taking a short break. Please try again in a few minutes.", true);
  if (g.blocked) return errJson(403, "blocked", "blocked");
  if (parsed === BAD) return errJson(400, "server", "bad_request", "Invalid JSON");
  const rpm = Number(s.user_rpm ?? 40);
  // Fair use: a burst of requests (a script, a loop) is slowed down before it reaches any model.
  if (rpm > 0 && g.burst >= rpm) {
    return errJson(429, "busy", "slow_down", "That's a lot of requests at once. Give it a few seconds and try again.", false, { "retry-after": "10" });
  }
  const used = g.usage;
  const s2 = withCap(s, capFrom(g.cap, s));
  const bill = billingOn(s);
  let ent: Ent | null = null, mrows: Mult[] = [];
  if (bill) {
    [ent, mrows] = await (billP ?? Promise.all([billingPrecheck(uid, s, () => Promise.resolve(used), billSource(source, background)), multipliers()]));
    tm.billing = performance.now() - tG;
    flushUnsaved(s);
  }
  // Billing on (and precheck answered): the billing balance replaces the old daily allowance and its grace.
  const ctx = ent ? billCtx(ent, mrows, background) : null;
  const st = ctx ? ctx.st : stateFor(used.tokens, s2);
  const bgLeft = ctx ? ctx.bgLeft : 0;
  const balance = ctx ? ctx.balance : 0;
  const balHdrs = balanceHeaders(ent, st);
  const stHdrs = { "x-submac-usage": st.ratio.toFixed(3), "x-submac-state": st.state };
  const withBal = (r: Response) => { for (const [k, v] of Object.entries(balHdrs)) { try { r.headers.set(k, v); } catch { /* immutable */ } } return r; };
  if (ctx && st.state === "limit") {
    const r = withBal(await emptyReply(uid, ent!, s, stHdrs));
    try { if (!r.headers.get("x-submac-error")) r.headers.set("x-submac-error", r.status === 503 ? "busy" : "limit_daily"); } catch { /* immutable */ }
    return r;
  }
  if (st.state === "limit") return withBal(errJson(429, "limit_daily", "daily_limit", s.limit_message ?? FRIENDLY.limit_daily, false, stHdrs));
  const bgs = backgroundFor(used.tokens, used.bg, s2);
  if (ctx && background && bgLeft <= 0) {
    return withBal(billErr(429, "background_paused", BG_PAUSED, ent!, s, "background_share_used", { background_left: 0, resets_at: eatReset() },
      { ...stHdrs, "x-submac-bg": "1.000", "x-submac-error": "limit_daily" }));
  }
  if (!ctx && background && (bgs.paused || st.state === "light")) {
    return withBal(json({ error: { code: "background_paused", submac_code: "limit_daily", message: "Paused until tomorrow to save your daily allowance." },
      background_left: 0, resets_at: eatReset() }, 429, { ...stHdrs, "x-submac-bg": bgs.ratio.toFixed(3), "x-submac-error": "limit_daily" }));
  }
  if (!background && !internal) screenLater(uid, Array.isArray(body.messages) ? body.messages : [], cfg);

  const plan = makePlan(cfg, body, st.state, ctx?.bx, effort);
  if (plan.error) return withBal(plan.error);
  if (!plan.routes.length) {
    console.error(JSON.stringify({ evt: "no_route", images: hasImages(body.messages), tools: plan.needTools }));
    return withBal(errJson(503, "busy", "busy", undefined, true));
  }
  const { stream, promptEstimate, smallestWindow } = plan;
  // One id per request: a retried charge for this reply is a no-op in usage_charge.
  const rid = bill ? "chat:" + crypto.randomUUID() : "";
  const bilHdrs = (cost: number): Record<string, string> => ent ? balHdr(balance - cost) : {};
  const baseHeaders: Record<string, string> = { ...CORS, ...stHdrs, "x-submac-window": smallestWindow, "x-submac-bg": bgs.ratio.toFixed(3), ...bilHdrs(0), ...balHdrs };

  const costOf = (d: Done) => {
    // Nothing reached the client (hang-up before the first word): no charge, no allowance used.
    const delivered = d.status === 200 || d.outChars > 0;
    if (!delivered) return { delivered, pt: 0, ct: 0, w: 0 };
    const pt = d.usage?.prompt_tokens ?? promptEstimate;
    const est = d.data ? estimateTokens(d.data.choices?.[0]?.message) : Math.ceil(d.outChars / 4);
    const ct = Math.max(d.usage?.completion_tokens ?? est, (d.usage?.total_tokens ?? 0) - pt);
    return { delivered, pt, ct, w: quotaOf(s, pt, ct, d.usage) };
  };
  return await runChat({
    routes: plan.routes, snap: g.router, chat, stream, alias: CHAT_ALIAS,
    homeId: homeOf(plan.alias), homeAfterMs: Math.max(60, num(s.router_home_after_s, 900)) * 1000,
    payloadFor: (r) => payloadFor(plan, r, s),
    ensureKeys: (r) => ensureKeys(cfg, [r]),
    shrink: shrinkFor(plan, s), clean, signal: req.signal, t0: tReq, budget: budgetFrom(s, !!internal), headers: baseHeaders,
    deps: {
      fetch: (i, init) => fetch(i, init), now: () => Date.now(), report: routerReport, home: routerHome, markKey,
      attemptFailed: (r, k, status, err) => record({ user_id: uid, source, lane, alias: CHAT_ALIAS, provider: r.provider, model: r.model, key_id: k.id, status, error: err.slice(0, 300), total_ms: Date.now() - tReq }),
      log: (e) => console.log(JSON.stringify(e)),
    },
    onUpstream: () => { tm.upstream = performance.now() - tG; },
    onDone: (d) => {
      const c = costOf(d);
      const g2 = (Date.now() - (d.ttft ? tReq + d.ttft : tReq)) / 1000;
      const genSecs = g2 < 0.25 ? Math.max(0.05, d.total / 1000) : g2;
      record({ user_id: uid, source, lane, alias: CHAT_ALIAS, provider: d.route.provider, model: d.route.model, key_id: d.key.id, status: d.status,
        prompt_tokens: c.pt, completion_tokens: c.ct, ttft_ms: d.ttft || d.total, total_ms: d.total, tps: c.ct / genSecs, attempts: d.attempts,
        error: d.error, quota_tokens: c.w, cached_tokens: cachedOf(d.usage) });
      if (rid && c.delivered && c.pt + c.ct > 0) billingCharge(uid, rid, c.pt, c.ct, source, background, s);
    },
    jsonResponse: (data, d) => {
      const c = costOf(d);
      if (ent) {
        const cost = c.delivered ? c.pt + c.ct : 0; // Contract B: raw tokens, one price
        const after = billState(ent, cost);
        return json(data, 200, { ...balHdrs, "x-submac-usage": after.ratio.toFixed(3), "x-submac-state": after.state, "x-submac-window": smallestWindow,
          "x-submac-bg": (background && bgLeft - cost <= 0 ? 1 : bgs.ratio).toFixed(3), ...bilHdrs(cost), ...balanceHeaders(ent, after) });
      }
      const after = stateFor(used.tokens + c.w, s2);
      return json(data, 200, { ...balanceHeaders(null, after), "x-submac-usage": after.ratio.toFixed(3), "x-submac-state": after.state, "x-submac-window": smallestWindow,
        "x-submac-bg": backgroundFor(after.used, used.bg + (background ? c.w : 0), s2).ratio.toFixed(3) });
    },
  });
}
