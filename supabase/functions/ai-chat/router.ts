// SubMac chat router (PLAN.md 1.1 + 1.3, rebuild 2026-10-23).
//
// One public model ("submac"), one route list, one shared "current route" pointer in the database
// (ai_router_state, returned inside ai_gate). Every request tries the current route first with its per-chat sticky
// key; when that fails the same request moves on to the next healthy route. The shared pointer only moves on clear
// evidence (3 hard failures or 2 first-byte timeouts within 60 s, counted and swapped by ai_router_report with a
// compare-and-set in SQL), and a swapped-out route rests 1 -> 2 -> 4 -> 8 -> 15 min. A 429 on every key of a route is
// overflow (capacity), not breakage: that one request goes to the next route and the pointer stays.
// A 400/422 is a request problem (schema, size), not a route failure: the request moves on but nothing is reported;
// a 404 counts only when the model itself is missing. Swap-back (v42, CB-15): once the preferred route (the alias's
// first healthy route) is not resting and the pointer has been elsewhere for >= router_home_after_s (15 min), the next
// request probes the preferred route first (one key); success moves the pointer home with a compare-and-set
// (ai_router_home), a hard failure / first-byte timeout rests it one step up the ladder.
//
// Timing (all from the request start, t0): 6 s for response headers and 10 s for the first real output per attempt,
// no new attempt after 18 s, hard stop at 25 s (in-flight attempt aborted). Streaming requests get 200 + ": ping" at
// once and every 10 s until the first token and whenever the upstream is quiet 10 s; anything that fails before the
// first token goes out as an SSE `error` event with a fixed code and friendly text (never raw provider text).
// Mid-reply silence 45 s -> cutTail (clean "cut off, continue"). Non-streamed calls: 45 s total. The client hanging up
// (req.signal) aborts every upstream fetch; nothing is charged when no output was delivered.
//
// This file has no Supabase dependencies so it can be tested with a mocked upstream (router_test.ts).

export type Key = { id: string; key: string; cooldown_until: string | null };
export type Route = {
  route_id: string; model_ref: string; model: string; vision: boolean; tools: boolean;
  context_window: number; extra_body: Record<string, unknown> | null; healthy: boolean;
  provider: string; provider_id: string; base_url: string; keys: Key[];
};

/** Router pointer + route rests as returned by ai_router_snapshot() inside ai_gate. */
export type RouterSnap = { current_route_id: string | null; since?: string | null; rest: Record<string, string> };
export const EMPTY_SNAP: RouterSnap = { current_route_id: null, since: null, rest: {} };
export function snapFrom(v: any): RouterSnap {
  if (!v || typeof v !== "object") return { ...EMPTY_SNAP, rest: {} };
  const rest: Record<string, string> = {};
  if (v.rest && typeof v.rest === "object") for (const [k, u] of Object.entries(v.rest)) if (typeof u === "string") rest[k] = u;
  return { current_route_id: typeof v.current_route_id === "string" ? v.current_route_id : null, since: v.since ?? null, rest };
}

// ---------------------------------------------------------------- error codes (Contract A)
export type ErrCode = "busy" | "too_long" | "limit_daily" | "limit_total" | "no_plan" | "blocked" | "server";
export const FRIENDLY: Record<ErrCode, string> = {
  busy: "SubMac is busy right now. Please try again in a moment.",
  too_long: "This is too long to send in one go. Start a new chat or send less at once.",
  limit_daily: "You've used today's replies. They reset at midnight.",
  limit_total: "You've used all the replies in your plan.",
  no_plan: "Get a plan to keep going.",
  blocked: "Your account needs attention. Please contact support.",
  server: "Something went wrong on our side. Please try again.",
};
/** Retry-After for `busy`: 15–30 s with jitter, so a crowd of clients does not come back at the same second. */
export function retryAfterSecs(rand: () => number = Math.random): number { return 15 + Math.floor(rand() * 16); }
/** Gemini 3+ on its OpenAI-compatible endpoint rejects (400 "Function call is missing a thought_signature") any
 *  history whose assistant tool calls carry no `extra_content.google.thought_signature`. Our histories never do (the
 *  calls come from other models, and the app does not keep the signature), so every tool-using step that reached a
 *  Gemini route failed over and cost seconds. Google's documented dummy signature skips the check for calls it did
 *  not make. Other routes get the messages unchanged. */
export const GEMINI_SKIP_SIGNATURE = "skip_thought_signature_validator";
export function isGeminiRoute(r: Pick<Route, "base_url" | "provider" | "model">): boolean {
  return /generativelanguage\.googleapis\.com/i.test(r.base_url ?? "") || (/gemini/i.test(r.provider ?? "") && /^gemini/i.test(r.model ?? ""));
}
export function withThoughtSignatures(messages: any[], r: Pick<Route, "base_url" | "provider" | "model">): any[] {
  if (!Array.isArray(messages) || !isGeminiRoute(r)) return messages;
  let changed = false;
  const out = messages.map((m) => {
    if (!m || m.role !== "assistant" || !Array.isArray(m.tool_calls) || !m.tool_calls.length) return m;
    const calls = m.tool_calls.map((c: any) => {
      if (!c || typeof c !== "object" || c.extra_content?.google?.thought_signature) return c;
      changed = true;
      return { ...c, extra_content: { ...(c.extra_content ?? {}), google: { ...(c.extra_content?.google ?? {}), thought_signature: GEMINI_SKIP_SIGNATURE } } };
    });
    return { ...m, tool_calls: calls };
  });
  return changed ? out : messages;
}

export function sseError(code: ErrCode, retryAfter?: number): string {
  const e: Record<string, unknown> = { code, message: FRIENDLY[code] };
  if (retryAfter) e.retry_after = retryAfter;
  return `event: error\ndata: ${JSON.stringify({ error: e })}\n\n`;
}

// ---------------------------------------------------------------- budgets
export type Budget = {
  headersMs: number; firstOutputMs: number; lastAttemptMs: number; hardStopMs: number; heartbeatMs: number;
  idleMs: number; replyTotalMs: number; nonStreamMs: number; nonStreamAttemptMs: number; maxRoutes: number; maxAttempts: number;
};
const n = (v: unknown, d: number) => { const x = Number(v); return v !== null && v !== undefined && v !== "" && Number.isFinite(x) && x > 0 ? x : d; };
/** Budgets from ai_settings (all optional; defaults are the PLAN.md 1.3 numbers). */
export function budgetFrom(s: Record<string, any> = {}, internal = false): Budget {
  const nonStream = n(s.nonstream_budget_ms, 45_000);
  return {
    headersMs: n(s.router_headers_ms, 6_000),
    firstOutputMs: n(s.router_first_output_ms, 10_000),
    lastAttemptMs: n(s.router_last_attempt_ms, 18_000),
    hardStopMs: n(s.router_hard_stop_ms, 25_000),
    heartbeatMs: n(s.heartbeat_ms, 10_000),
    idleMs: n(s.stream_idle_ms_v2, 45_000),
    // One reply must end before the platform wall clock (150 s on Free): end it cleanly with cutTail.
    replyTotalMs: n(s.reply_total_ms, 140_000),
    // bot-run gives each call 40 s: its non-streamed calls must end before that.
    nonStreamMs: internal ? Math.min(nonStream, n(s.internal_nonstream_budget_ms, 38_000)) : nonStream,
    nonStreamAttemptMs: n(s.nonstream_attempt_ms, 25_000),
    maxRoutes: n(s.router_max_routes, 3),
    maxAttempts: n(s.router_max_attempts, 6),
  };
}

// ---------------------------------------------------------------- keys
export function cooldownFor(status: number): number {
  if (status === 429) return 60;
  if (status === 401 || status === 403) return 3600;
  if (status === 402) return 6 * 3600;
  if (status >= 500 || status === 0) return 20;
  return 0;
}
export const localCooldown = new Map<string, number>(); // key id (or "live:"+id, "route:"+id) -> until (ms), per isolate
const rr = new Map<string, number>();
/** Small stable hash, so the same chat always lands on the same key without any shared state. */
export function hashOf(s: string): number {
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619); }
  return h >>> 0;
}
/** Usable keys for a route. With a chat id the starting key is fixed per chat (sticky), so the provider's prompt cache
 *  keeps working across steps; it only moves when that key fails or rests. Otherwise round robin. */
export function keysInOrder(r: Route, chat = "", anyKey = false, now = Date.now()): Key[] {
  const usable = anyKey ? r.keys : r.keys.filter((k) => {
    const lc = localCooldown.get(k.id) ?? 0;
    const dc = k.cooldown_until ? Date.parse(k.cooldown_until) : 0;
    return lc < now && dc < now;
  });
  if (!usable.length) return [];
  let i: number;
  if (chat) i = hashOf(chat + "|" + r.route_id) % usable.length;
  else { i = (rr.get(r.route_id) ?? 0) % usable.length; rr.set(r.route_id, i + 1); }
  return [...usable.slice(i), ...usable.slice(0, i)];
}

// ---------------------------------------------------------------- route order
export function restedAt(snap: RouterSnap, routeId: string, now: number): boolean {
  const u = snap.rest[routeId];
  return (!!u && Date.parse(u) > now) || (localCooldown.get("route:" + routeId) ?? 0) > now;
}
/** Current route first (when it is in this request's capability-filtered list and not resting), then the rest in
 *  priority order; resting routes only as a last resort. `current` is the route the shared pointer means for this
 *  request (null when the pointer's route can't serve it, e.g. no vision for a photo). */
export function orderRoutes(routes: Route[], snap: RouterSnap, now = Date.now()): { list: Route[]; current: Route | null; pointer: string | null } {
  const ok = routes.filter((r) => !restedAt(snap, r.route_id, now));
  const resting = routes.filter((r) => restedAt(snap, r.route_id, now));
  const cur = ok.find((r) => r.route_id === snap.current_route_id) ?? null;
  // No valid pointer yet (fresh install, or its route was disabled): the first healthy route is "current".
  const pointerValid = !!snap.current_route_id && routes.some((r) => r.route_id === snap.current_route_id);
  const effective = cur ?? (!pointerValid ? (ok.find((r) => r.healthy) ?? ok[0] ?? null) : null);
  const rest = ok.filter((r) => r !== effective);
  const list = [...(effective ? [effective] : []), ...rest.filter((r) => r.healthy), ...rest.filter((r) => !r.healthy), ...resting];
  return { list, current: effective, pointer: effective?.route_id ?? null };
}

/** Swap-back (CB-15): the preferred route to probe first on this request, or null. Only when the shared pointer is
 *  set to another route, the preferred route can serve this request (it is in the capability-filtered list), is not
 *  resting (DB rest expired, no local cooldown), and the pointer has been where it is for at least `afterMs`. */
export function homeProbe(routes: Route[], snap: RouterSnap, homeId: string | null | undefined, afterMs: number, now = Date.now()): Route | null {
  if (!homeId || !snap.current_route_id || snap.current_route_id === homeId) return null;
  const home = routes.find((r) => r.route_id === homeId);
  if (!home || restedAt(snap, homeId, now)) return null;
  const since = snap.since ? Date.parse(snap.since) : NaN;
  if (!Number.isFinite(since) || now - since < afterMs) return null;
  return home;
}

/** 404 counts as a route failure only when the model is missing (not for a wrong path or a missing resource). */
export function modelMissing(text: string): boolean {
  return /model[^\n]{0,80}(not[ _-]?found|does ?n[o']t exist|not exist|unknown|no such|not available|unsupported|is not (found|supported))|(unknown|invalid|no such|unsupported)[ _-]model|no endpoints? found|model_not_found/i.test(text ?? "");
}

// ---------------------------------------------------------------- effort hint
export type Effort = "low" | "normal" | "high";
export function effortOf(h: string | null | undefined): Effort | null {
  const v = (h ?? "").trim().toLowerCase();
  return v === "low" || v === "normal" || v === "high" ? v : null;
}
/** Does this route take an OpenAI-style reasoning_effort? Explicit in extra_body, or a model family known to take it. */
export function takesEffort(r: Route): boolean {
  if (r.extra_body && "reasoning_effort" in r.extra_body) return true;
  return /gemini|gpt-oss|deepseek-v4|nemotron-3|o[1-9]-|gpt-5/i.test(r.model);
}
/** Largest max_tokens a provider accepts: asking for more is a 400 and a wasted first try (Poolside: 32768). Known limits
 *  are built in; ai_settings.provider_max_output_tokens ({"poolside": 32768, ...}) adds or overrides them. A key matches
 *  the provider name or the model id, case-insensitively, as a substring. 0 = no known limit. */
export const PROVIDER_MAX_OUTPUT: Record<string, number> = { poolside: 32768 };
export function providerOutCap(r: Pick<Route, "provider" | "model">, s: Record<string, any> = {}): number {
  const extra = s.provider_max_output_tokens && typeof s.provider_max_output_tokens === "object" && !Array.isArray(s.provider_max_output_tokens)
    ? s.provider_max_output_tokens as Record<string, unknown> : {};
  const caps: Record<string, number> = { ...PROVIDER_MAX_OUTPUT };
  for (const [k, v] of Object.entries(extra)) caps[k.toLowerCase()] = Number(v);
  const hay = (String(r.provider ?? "") + " " + String(r.model ?? "")).toLowerCase();
  let cap = 0;
  for (const [k, v] of Object.entries(caps)) {
    if (!k || !Number.isFinite(v) || v <= 0 || !hay.includes(k)) continue;
    cap = cap ? Math.min(cap, Math.floor(v)) : Math.floor(v);
  }
  return cap;
}
/** max_tokens for one attempt: the room the plan allows, never above the provider's limit or a limit learned from an error. */
export function clampOut(room: number, provCap: number, learned?: number): number {
  let n = room;
  if (provCap > 0) n = Math.min(n, provCap);
  if (learned && learned > 0) n = Math.min(n, learned);
  return n;
}
/** Extra body for the effort hint: low/high map to reasoning_effort; normal keeps the route's own setting. */
export function effortBody(r: Route, e: Effort | null): Record<string, unknown> {
  if (!e || e === "normal" || !takesEffort(r)) return {};
  return { reasoning_effort: e };
}

// ---------------------------------------------------------------- the attempt engine
export type Outcome = "hard" | "fb_timeout";
/** "request": 400/422 (or a 404 that is not a missing model) - a problem with this request, never reported. */
type RouteOutcome = Outcome | "overflow" | "request";
export type Deps = {
  fetch: typeof fetch;
  now: () => number;
  /** Count a failure of the route the pointer means; SQL swaps the pointer (CAS) when the threshold is met. */
  report: (routeId: string, kind: Outcome, nextRouteId: string | null) => void;
  /** Swap-back probe result for the preferred route: ok = answered (CAS pointer from -> home), else rest it. */
  home?: (homeId: string, fromRouteId: string, ok: boolean, kind: Outcome | null) => void;
  markKey: (id: string, ok: boolean, error: string | null, cooldown: number) => void;
  /** A failed attempt (for ai_usage stats). Never raw text to the user. */
  attemptFailed: (r: Route, k: Key, status: number, error: string) => void;
  log?: (evt: Record<string, unknown>) => void;
};
export type Done = {
  route: Route; key: Key; status: number; usage: any; outChars: number; ttft: number; total: number; attempts: number;
  error?: string; fallback: boolean; data?: any;
};
export type ChatRun = {
  routes: Route[]; snap: RouterSnap; chat: string; stream: boolean; alias: string;
  /** The alias's preferred route (first healthy by priority) and how long the pointer must sit elsewhere first. */
  homeId?: string | null; homeAfterMs?: number;
  payloadFor: (r: Route) => Record<string, unknown>;
  ensureKeys: (r: Route) => Promise<void>;
  /** The route allows fewer output tokens than asked: learn its cap; true = retry this key once, smaller. */
  shrink?: (r: Route, errText: string) => boolean;
  clean?: (t: string) => string;
  signal?: AbortSignal; t0: number; budget: Budget; headers: Record<string, string>;
  deps: Deps;
  /** Usage recording + billing. delivered = some output reached the client. */
  onDone: (d: Done) => void;
  /** Non-streamed success: build the JSON response (headers depend on the cost). */
  jsonResponse?: (data: any, d: Done) => Response;
  onUpstream?: () => void;
};

type AttemptOk = { kind: "ok"; res: Response; ctl: AbortController; reader?: ReadableStreamDefaultReader<Uint8Array>; held: Uint8Array[]; data?: any };
type AttemptFail = { kind: "fail"; why: "timeout" | "status" | "network" | "empty" | "bad" | "aborted" | "hard_stop"; status: number; text: string };
type Attempt = AttemptOk | AttemptFail;

function raceSignal<T>(p: Promise<T>, s: AbortSignal): Promise<T> {
  if (s.aborted) return Promise.reject(new Error("aborted"));
  return new Promise<T>((ok, bad) => {
    const on = () => bad(new Error("aborted"));
    s.addEventListener("abort", on, { once: true });
    p.then((v) => { s.removeEventListener("abort", on); ok(v); }, (e) => { s.removeEventListener("abort", on); bad(e); });
  });
}
function link(from: AbortSignal, to: AbortController, why: string) {
  if (from.aborted) to.abort(why); else from.addEventListener("abort", () => to.abort(why), { once: true });
}

const REAL = (peek: string) => /"(content|reasoning_content|reasoning)"\s*:\s*"[^"]/.test(peek) || /"tool_calls"\s*:\s*\[\s*\{/.test(peek) || peek.includes("[DONE]") || peek.length > 200_000;

/**
 * Runs one chat request through the route list. Streaming: returns the SSE response at once (heartbeats while the
 * attempts run). Non-streamed: resolves when an answer (or a friendly error) is ready.
 */
export async function runChat(o: ChatRun): Promise<Response> {
  const { deps, budget } = o;
  const master = new AbortController(); // every upstream fetch hangs off this
  let masterWhy = "";
  const abortAll = (why: string) => { if (!master.signal.aborted) { masterWhy = why; master.abort(why); } };
  if (o.signal) { if (o.signal.aborted) abortAll("client"); else o.signal.addEventListener("abort", () => abortAll("client"), { once: true }); }
  const order = orderRoutes(o.routes, o.snap, deps.now());
  // Swap-back probe: the preferred route goes first (one key); `current` stays the pointer's route for reports.
  const probe = homeProbe(o.routes, o.snap, o.homeId, o.homeAfterMs ?? 15 * 60_000, deps.now());
  if (probe) order.list = [probe, ...order.list.filter((r) => r !== probe)];
  const probeFrom = o.snap.current_route_id;
  const enc = new TextEncoder();
  let attempts = 0;

  /** One attempt: headers within headersMs, first real output within firstOutputMs of the attempt start. */
  const attempt = async (r: Route, k: Key): Promise<Attempt> => {
    const ctl = new AbortController();
    let why = "";
    link(master.signal, ctl, "master");
    const tA = deps.now();
    const stopAt = (ms: number, w: string) => setTimeout(() => { why = w; ctl.abort(w); }, Math.max(0, ms));
    // Non-streamed: the reply arrives whole, so the whole attempt shares one limit instead of headers/first-output.
    const left = o.t0 + budget.nonStreamMs - tA;
    const tHdr = o.stream ? stopAt(budget.headersMs, "timeout") : stopAt(Math.min(budget.nonStreamAttemptMs, left), "timeout");
    const failOf = (e: unknown, status = 0): AttemptFail => {
      if (master.signal.aborted) return { kind: "fail", why: masterWhy === "client" ? "aborted" : "hard_stop", status: 0, text: masterWhy };
      if (why === "timeout") return { kind: "fail", why: "timeout", status: 0, text: "timeout" };
      return { kind: "fail", why: "network", status, text: String(e).slice(0, 160) };
    };
    let res: Response;
    try {
      res = await raceSignal(deps.fetch(r.base_url.replace(/\/$/, "") + "/chat/completions", {
        method: "POST", signal: ctl.signal,
        headers: { "content-type": "application/json", authorization: `Bearer ${k.key}`, "user-agent": "submac-proxy/1" },
        body: JSON.stringify(o.payloadFor(r)),
      }), ctl.signal);
    } catch (e) { clearTimeout(tHdr); return failOf(e); }
    if (o.stream) clearTimeout(tHdr);
    if (!res.ok) {
      clearTimeout(tHdr);
      let txt = "";
      try { txt = (await raceSignal(res.text(), AbortSignal.any([ctl.signal, AbortSignal.timeout(2000)]))).slice(0, 300); } catch { res.body?.cancel().catch(() => {}); }
      return { kind: "fail", why: "status", status: res.status, text: txt };
    }
    if (!o.stream) {
      try {
        const data = await raceSignal(res.json(), ctl.signal);
        clearTimeout(tHdr);
        if (!data?.choices) return { kind: "fail", why: "bad", status: 0, text: "bad response" };
        return { kind: "ok", res, ctl, held: [], data };
      } catch (e) { clearTimeout(tHdr); res.body?.cancel().catch(() => {}); return failOf(e); }
    }
    // Streaming: hold the stream until the first real output, so a dead stream can still fail over.
    const tFirst = stopAt(budget.firstOutputMs - (deps.now() - tA), "timeout");
    const reader = res.body!.getReader();
    const held: Uint8Array[] = []; const dec = new TextDecoder(); let peek = "";
    try {
      for (;;) {
        const x = await raceSignal(reader.read(), ctl.signal);
        if (x.done) break;
        held.push(x.value!); peek += dec.decode(x.value!, { stream: true });
        if (/"error"\s*:/.test(peek) && !/"choices"/.test(peek)) { clearTimeout(tFirst); reader.cancel().catch(() => {}); return { kind: "fail", why: "empty", status: 0, text: "error in stream" }; }
        if (REAL(peek)) { clearTimeout(tFirst); return { kind: "ok", res, ctl, reader, held }; }
      }
    } catch (e) { clearTimeout(tFirst); reader.cancel().catch(() => {}); return failOf(e); }
    clearTimeout(tFirst);
    return { kind: "fail", why: "empty", status: 0, text: "empty stream" };
  };

  /** Walks the route list until one attempt commits. null = nothing worked (or the client left / hard stop). */
  const findAnswer = async (): Promise<{ a: AttemptOk; r: Route; k: Key } | null> => {
    let routesSpent = 0;
    let triedAny = false;
    for (let ri = 0; ri < order.list.length; ri++) {
      const r = order.list[ri];
      if (master.signal.aborted || deps.now() - o.t0 > budget.lastAttemptMs || attempts >= budget.maxAttempts) break;
      await o.ensureKeys(r);
      const probing = !!probe && r === probe && ri === 0;
      let ks = keysInOrder(r, o.chat, false, deps.now()).slice(0, probing ? 1 : 3);
      // Nothing usable anywhere (every key resting): one resting key of the first route is better than "busy".
      if (!ks.length && !triedAny && ri === order.list.length - 1) ks = keysInOrder(r, o.chat, true, deps.now()).slice(0, 1);
      if (!ks.length) continue; // all keys resting = overflow: next route, pointer stays
      let n429 = 0, nHard = 0, tried = 0, auth = 0;
      let outcome: RouteOutcome | null = null;
      const shrunk = new Set<string>();
      for (let ki = 0; ki < ks.length; ki++) {
        const k = ks[ki];
        if (master.signal.aborted || deps.now() - o.t0 > budget.lastAttemptMs || attempts >= budget.maxAttempts) break;
        attempts++; tried++; triedAny = true;
        const a = await attempt(r, k);
        if (a.kind === "ok") {
          // Key state is written only when it changes: a key that was resting (or failing) is cleared here.
          if (k.cooldown_until || localCooldown.has(k.id)) deps.markKey(k.id, true, null, 0);
          if (probing && probeFrom) {
            deps.log?.({ evt: "router_home_probe", route: r.route_id, from: probeFrom, ok: true });
            deps.home?.(r.route_id, probeFrom, true, null);
          }
          return { a, r, k };
        }
        if (a.why === "aborted" || a.why === "hard_stop") return null;
        const err = a.why === "status" ? `${r.provider} ${a.status}: ${a.text}` : `${r.provider}: ${a.text}`;
        deps.attemptFailed(r, k, a.status, err);
        if (a.why === "timeout") { deps.markKey(k.id, false, err, 20); outcome = "fb_timeout"; break; }
        if (a.why === "status") {
          if (a.status === 400 && o.shrink && !shrunk.has(k.id) && o.shrink(r, a.text)) { shrunk.add(k.id); ks.splice(ki + 1, 0, k); tried--; continue; }
          deps.markKey(k.id, false, err, cooldownFor(a.status));
          if (a.status === 429) { n429++; continue; }
          if (a.status === 401 || a.status === 402 || a.status === 403) { auth++; continue; }
          // 400/422: this request's problem (schema, size), not the route's: move on, report nothing (CB-15).
          if (a.status === 400 || a.status === 422) { outcome = "request"; break; }
          // 404: a route failure only when the model is missing; otherwise treat it like a request error.
          if (a.status === 404) { outcome = modelMissing(a.text) ? "hard" : "request"; break; }
        } else deps.markKey(k.id, false, err, 20);
        nHard++;
        if (nHard >= 2) { outcome = "hard"; break; }
      }
      if (!outcome) outcome = tried > 0 && n429 + auth === tried && n429 > 0 ? "overflow" : tried > 0 ? "hard" : null;
      if (!outcome) break; // out of time before trying this route
      if (probing) {
        // A failed probe does not use up a route of this request and never counts against the pointer's route.
        deps.log?.({ evt: "router_home_probe", route: r.route_id, from: probeFrom, ok: false, outcome });
        if (probeFrom && (outcome === "hard" || outcome === "fb_timeout")) {
          localCooldown.set("route:" + r.route_id, deps.now() + 60_000);
          deps.home?.(r.route_id, probeFrom, false, outcome);
        }
        continue;
      }
      if (outcome === "request") {
        routesSpent++;
        deps.log?.({ evt: "router_request_error", route: r.route_id });
        if (routesSpent >= budget.maxRoutes) break;
      } else if (outcome !== "overflow") {
        routesSpent++;
        if (order.current && r.route_id === order.current.route_id) {
          const next = order.list.slice(ri + 1).find((x) => !restedAt(o.snap, x.route_id, deps.now()));
          deps.report(r.route_id, outcome, next?.route_id ?? null);
        }
        if (routesSpent >= budget.maxRoutes) break;
      } else deps.log?.({ evt: "router_overflow", route: r.route_id });
    }
    return null;
  };

  const hardStop = setTimeout(() => abortAll("hard_stop"), Math.max(0, o.t0 + (o.stream ? budget.hardStopMs : budget.nonStreamMs) - deps.now()));
  const fallbackOf = (r: Route) => !!order.current && r.route_id !== order.current.route_id && r !== probe;

  // ---------------- non-streamed
  if (!o.stream) {
    let got: Awaited<ReturnType<typeof findAnswer>> = null;
    try { got = await findAnswer(); } catch (e) { deps.log?.({ evt: "router_error", error: String(e).slice(0, 200) }); }
    clearTimeout(hardStop);
    if (!got) {
      if (masterWhy === "client") return new Response(null, { status: 499, headers: o.headers });
      const ra = retryAfterSecs();
      return new Response(JSON.stringify({ error: { code: "busy", message: FRIENDLY.busy, retry_after: ra } }),
        { status: 503, headers: { ...o.headers, "content-type": "application/json", "Retry-After": String(ra) } });
    }
    o.onUpstream?.();
    const total = deps.now() - o.t0;
    const d: Done = { route: got.r, key: got.k, status: 200, usage: got.a.data?.usage, outChars: 0, ttft: total, total, attempts, fallback: fallbackOf(got.r), data: got.a.data };
    if (d.fallback) deps.log?.({ evt: "router_fallback", route: got.r.route_id, current: order.current?.route_id ?? null });
    got.a.data.model = o.alias;
    for (const ch of got.a.data.choices ?? []) {
      if (typeof ch?.message?.content === "string") {
        ch.message.content = o.clean ? o.clean(ch.message.content) : ch.message.content;
        if (ch.message.tool_calls?.length && !ch.message.content.trim()) ch.message.content = null;
      }
    }
    o.onDone(d);
    return o.jsonResponse ? o.jsonResponse(got.a.data, d)
      : new Response(JSON.stringify(got.a.data), { status: 200, headers: { ...o.headers, "content-type": "application/json" } });
  }

  // ---------------- streamed: 200 + ping now, attempts behind the heartbeat
  let closed = false;
  let lastSent = 0;
  let ctrl!: ReadableStreamDefaultController<Uint8Array>;
  let hb: ReturnType<typeof setInterval> | undefined;
  const send = (s: string | Uint8Array) => {
    if (closed) return false;
    try { ctrl.enqueue(typeof s === "string" ? enc.encode(s) : s); lastSent = deps.now(); return true; } catch { closed = true; return false; }
  };
  const close = () => { if (closed) return; closed = true; if (hb) clearInterval(hb); clearTimeout(hardStop); try { ctrl.close(); } catch { /* gone */ } };
  let onCancel = () => {};

  const pump = async () => {
    let got: Awaited<ReturnType<typeof findAnswer>> = null;
    try { got = await findAnswer(); } catch (e) {
      deps.log?.({ evt: "router_error", error: String(e).slice(0, 200) });
      if (masterWhy !== "client") send(sseError("server"));
      close(); return;
    }
    clearTimeout(hardStop);
    if (!got) {
      if (masterWhy !== "client") send(sseError("busy", retryAfterSecs()));
      close(); return;
    }
    o.onUpstream?.();
    const { a, r, k } = got;
    const reader = a.reader!;
    const fallback = fallbackOf(r);
    if (fallback) deps.log?.({ evt: "router_fallback", route: r.route_id, current: order.current?.route_id ?? null });
    const dec = new TextDecoder();
    let buf = "", usage: any = null, outChars = 0, ttft = 0, sawFinish = false, done = false;
    const cutTail = () => `data: ${JSON.stringify({ id: "cut", object: "chat.completion.chunk", model: o.alias, choices: [{ index: 0, delta: {}, finish_reason: "length" }] })}\n\ndata: [DONE]\n\n`;
    const finish = (status: number, err?: string) => {
      if (done) return; done = true;
      o.onDone({ route: r, key: k, status, usage, outChars, ttft: ttft || deps.now() - o.t0, total: deps.now() - o.t0, attempts, error: err, fallback });
    };
    onCancel = () => { finish(499, "client closed"); reader.cancel().catch(() => {}); a.ctl.abort("client"); };
    const process = (chunk: Uint8Array | null): string => {
      if (chunk) buf += dec.decode(chunk, { stream: true }); else buf += "\n";
      let out = ""; let nl: number;
      while ((nl = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, nl).trim(); buf = buf.slice(nl + 1);
        if (!line) continue;
        if (!line.startsWith("data:")) { if (line.startsWith(":")) out += line + "\n\n"; continue; }
        const d = line.slice(5).trim();
        if (d === "[DONE]") { out += "data: [DONE]\n\n"; continue; }
        let j: any;
        try { j = JSON.parse(d); } catch { out += line + "\n\n"; continue; }
        if (j.usage) usage = j.usage;
        if (j.choices?.[0]?.finish_reason) sawFinish = true;
        j.model = o.alias;
        const delta = j.choices?.[0]?.delta;
        if (delta) {
          if (typeof delta.content === "string" && o.clean) {
            delta.content = o.clean(delta.content);
            if (/^\s*<?\s*\/?\s*｜[^>]*>?\s*$|^\s*<\s*$/.test(delta.content) && delta.content.includes("｜")) delta.content = "";
          }
          const c = (delta.content?.length ?? 0) + (delta.reasoning_content?.length ?? 0) + (delta.reasoning?.length ?? 0) + (delta.tool_calls ? JSON.stringify(delta.tool_calls).length : 0);
          if (c > 0 && !ttft) ttft = deps.now() - o.t0;
          outChars += c;
        }
        out += "data: " + JSON.stringify(j) + "\n\n";
      }
      return out;
    };
    // First (held) bytes.
    const joined = new Uint8Array(a.held.reduce((s, b) => s + b.length, 0));
    { let off = 0; for (const b of a.held) { joined.set(b, off); off += b.length; } }
    const before = outChars;
    const first = process(joined);
    if (first && !send(first)) { outChars = before; finish(499, "client closed"); a.ctl.abort("client"); return; }
    const tCommit = deps.now();
    try {
      for (;;) {
        if (closed) return;
        const left = Math.min(budget.idleMs, budget.replyTotalMs - (deps.now() - tCommit));
        if (left <= 0) throw new Error("reply too long for one call");
        const x = await raceSignal(reader.read(), AbortSignal.any([a.ctl.signal, AbortSignal.timeout(left)]));
        if (x.done) {
          const tail = process(null); if (tail) send(tail);
          if (!sawFinish) send(cutTail());
          finish(200, sawFinish ? undefined : "ended without finish"); close(); return;
        }
        const out = process(x.value!);
        if (out) send(out);
      }
    } catch (e) {
      if (masterWhy === "client" || closed) { finish(499, "client closed"); reader.cancel().catch(() => {}); a.ctl.abort("client"); return; }
      // The upstream died or went quiet mid-reply: end it as "cut off" so the app carries on from where it stopped.
      if (!sawFinish) send(cutTail());
      finish(200, "stream cut: " + String(e).slice(0, 100)); close(); reader.cancel().catch(() => {}); a.ctl.abort("cut");
    }
  };

  const body = new ReadableStream<Uint8Array>({
    start(c) {
      ctrl = c;
      send(": ping\n\n");
      const tick = Math.max(20, Math.min(1000, Math.floor(budget.heartbeatMs / 4)));
      hb = setInterval(() => { if (deps.now() - lastSent >= budget.heartbeatMs) send(": ping\n\n"); }, tick);
      pump().catch(() => close());
    },
    cancel() {
      // The phone hung up: stop everything; finish() charges only output that was actually delivered.
      closed = true; if (hb) clearInterval(hb); clearTimeout(hardStop);
      abortAll("client"); onCancel();
    },
  });
  return new Response(body, { status: 200, headers: { ...o.headers, "content-type": "text/event-stream", "cache-control": "no-cache" } });
}
