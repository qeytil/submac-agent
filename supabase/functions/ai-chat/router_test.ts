// Local tests for the sticky router with a mocked upstream (no network, no database).
// Run: deno test supabase/functions/ai-chat/router_test.ts
import { assert, assertEquals, assertMatch } from "jsr:@std/assert@1";
import {
  budgetFrom, type Budget, type ChatRun, type Deps, type Done, effortBody, GEMINI_SKIP_SIGNATURE, localCooldown, orderRoutes, type Route, runChat, type RouterSnap,
  withThoughtSignatures,
} from "./router.ts";

const route = (id: string, keys = 2, extra: Partial<Route> = {}): Route => ({
  route_id: id, model_ref: "m-" + id, model: "model-" + id, vision: false, tools: true, context_window: 128000, extra_body: null,
  healthy: true, provider: "P" + id, provider_id: "p-" + id, base_url: "http://" + id,
  keys: Array.from({ length: keys }, (_, i) => ({ id: `${id}-k${i}`, key: `sk-${id}-${i}`, cooldown_until: null })), ...extra,
});

// The mocks and readAll leave short sleep timers behind on purpose (a lost race); they are test-only, so the op sanitizer is off.
const test = (name: string, fn: () => Promise<void> | void) => Deno.test({ name, fn, sanitizeOps: false, sanitizeResources: false });

const enc = new TextEncoder();
const chunk = (text: string) => `data: ${JSON.stringify({ choices: [{ index: 0, delta: { content: text } }] })}\n\n`;
const finishChunk = `data: ${JSON.stringify({ choices: [{ index: 0, delta: {}, finish_reason: "stop" }], usage: { prompt_tokens: 10, completion_tokens: 3 } })}\n\ndata: [DONE]\n\n`;
const sleep = (ms: number, signal?: AbortSignal) => new Promise<void>((ok, bad) => {
  const t = setTimeout(ok, ms);
  signal?.addEventListener("abort", () => { clearTimeout(t); bad(new Error("aborted")); }, { once: true });
});

type Step = { wait: number; data: string };
/** An SSE body that sends each step after its wait; stops when the request is aborted. */
function sse(steps: Step[], signal: AbortSignal, onAbort?: () => void): Response {
  const body = new ReadableStream<Uint8Array>({
    async start(c) {
      signal.addEventListener("abort", () => { onAbort?.(); try { c.error(new Error("aborted")); } catch { /* closed */ } }, { once: true });
      try {
        for (const s of steps) { await sleep(s.wait, signal); c.enqueue(enc.encode(s.data)); }
        c.close();
      } catch { /* aborted */ }
    },
  });
  return new Response(body, { status: 200, headers: { "content-type": "text/event-stream" } });
}

type Behaviour = (key: string, signal: AbortSignal) => Promise<Response>;
function mockFetch(byRoute: Record<string, Behaviour>, log: string[]): typeof fetch {
  return (async (input: string | URL | Request, init?: RequestInit) => {
    const url = String(input);
    const id = url.replace("http://", "").split("/")[0];
    const key = String((init?.headers as Record<string, string>).authorization).replace("Bearer ", "");
    log.push(`${id}:${key}`);
    return await byRoute[id](key, init!.signal!);
  }) as typeof fetch;
}
const ok = (text = "Hi"): Behaviour => (_k, s) => Promise.resolve(sse([{ wait: 5, data: chunk(text) }, { wait: 5, data: finishChunk }], s));
const status = (code: number): Behaviour => () => Promise.resolve(new Response(`{"error":"x${code}"}`, { status: code }));
const hang: Behaviour = (_k, s) => new Promise((_, bad) => s.addEventListener("abort", () => bad(new Error("aborted")), { once: true }));

const FAST: Budget = { ...budgetFrom({}), headersMs: 150, firstOutputMs: 250, lastAttemptMs: 400, hardStopMs: 600, heartbeatMs: 60, idleMs: 300, nonStreamMs: 600, nonStreamAttemptMs: 300 };

type Probe = { reports: [string, string, string | null][]; marks: [string, boolean, number][]; done: Done[]; fetched: string[] };
function run(routes: Route[], snap: RouterSnap, byRoute: Record<string, Behaviour>, opts: Partial<ChatRun> = {}): { p: Promise<Response>; probe: Probe } {
  const probe: Probe = { reports: [], marks: [], done: [], fetched: [] };
  const deps: Deps = {
    fetch: mockFetch(byRoute, probe.fetched), now: () => Date.now(),
    report: (r, k, n) => probe.reports.push([r, k, n]),
    // Same as index.ts markKey: a failure rests the key in this isolate at once.
    markKey: (id, okv, _e, cd) => { probe.marks.push([id, okv, cd]); if (!okv && cd > 0) localCooldown.set(id, Date.now() + cd * 1000); if (okv) localCooldown.delete(id); },
    attemptFailed: () => {},
  };
  const p = runChat({
    routes, snap, chat: "user1:chat1", stream: true, alias: "submac",
    payloadFor: (r) => ({ model: r.model, messages: [] }), ensureKeys: () => Promise.resolve(),
    t0: Date.now(), budget: FAST, headers: {}, deps, onDone: (d) => probe.done.push(d), ...opts,
  });
  return { p, probe };
}
async function readAll(res: Response, max = 5000): Promise<string> {
  const r = res.body!.getReader(); const dec = new TextDecoder(); let out = "";
  const until = Date.now() + max;
  for (;;) {
    const x = await Promise.race([r.read(), sleep(Math.max(0, until - Date.now())).then(() => ({ done: true, value: undefined }))]);
    if (x.done) break;
    out += dec.decode(x.value as Uint8Array);
  }
  return out;
}
const snap = (current: string | null, rest: Record<string, string> = {}): RouterSnap => ({ current_route_id: current, rest });

test("sticky pick: the pointer's route goes first, the same chat keeps its key, success writes nothing", async () => {
  localCooldown.clear();
  const A = route("A"), B = route("B"), C = route("C");
  const keysSeen = new Set<string>();
  for (let i = 0; i < 3; i++) {
    const { p, probe } = run([A, B, C], snap("B"), { A: ok(), B: ok(), C: ok() });
    const res = await p;
    assertEquals(res.status, 200);
    const text = await readAll(res);
    assertMatch(text, /"content":"Hi"/);
    assertEquals(probe.fetched.length, 1);
    assert(probe.fetched[0].startsWith("B:"), "current route B tried first");
    keysSeen.add(probe.fetched[0]);
    assertEquals(probe.reports.length, 0);
    assertEquals(probe.marks.length, 0, "no key write on a plain success");
    assertEquals(probe.done[0].status, 200);
    assertEquals(probe.done[0].fallback, false);
  }
  assertEquals(keysSeen.size, 1, "per-chat sticky key");
  // No pointer yet: the first healthy route is current.
  assertEquals(orderRoutes([A, B, C], snap(null)).list.map((r) => r.route_id), ["A", "B", "C"]);
  // A resting route goes to the back.
  assertEquals(orderRoutes([A, B, C], snap("A", { A: new Date(Date.now() + 60_000).toISOString() })).list.map((r) => r.route_id), ["B", "C", "A"]);
});

test("hard failures: the same request moves on; the current route is reported once per request (SQL swaps at 3)", async () => {
  localCooldown.clear();
  const A = route("A"), B = route("B");
  // A JS copy of the SQL rule (3 hard failures in 60 s, compare-and-set) to show the pointer moving after the 3rd request.
  let pointer = "A"; let fails = 0;
  const store = (r: string, kind: string, next: string | null) => { if (r !== pointer) return; if (kind === "hard" && ++fails >= 3 && next) { pointer = next; fails = 0; } };
  for (let i = 1; i <= 4; i++) {
    const { p, probe } = run([A, B], snap(pointer), { A: status(503), B: ok("from B") });
    const res = await p;
    const text = await readAll(res);
    assertMatch(text, /from B/, "answered by the next healthy route in the same request");
    for (const [r, k, n] of probe.reports) store(r, k, n);
    if (i <= 3) {
      assertEquals(probe.reports, [["A", "hard", "B"]]);
      assertEquals(probe.done[0].fallback, true);
      localCooldown.clear(); // keys' 20 s rests would otherwise hide A; the swap rule is what is under test
    } else {
      assertEquals(probe.fetched.every((f) => f.startsWith("B:")), true, "after the swap B is current");
      assertEquals(probe.reports.length, 0);
    }
    if (i === 3) assertEquals(pointer, "B", "pointer swapped after the 3rd hard failure");
  }
});

test("first-byte timeout is reported as fb_timeout and the request still answers", async () => {
  localCooldown.clear();
  const A = route("A", 1), B = route("B", 1);
  const silent: Behaviour = (_k, s) => Promise.resolve(sse([{ wait: 10_000, data: chunk("late") }], s));
  const { p, probe } = run([A, B], snap("A"), { A: silent, B: ok("B ok") });
  const text = await readAll(await p);
  assertMatch(text, /B ok/);
  assertEquals(probe.reports, [["A", "fb_timeout", "B"]]);
});

test("overflow: 429 on every key goes to the next route without reporting (pointer stays)", async () => {
  localCooldown.clear();
  const A = route("A", 3), B = route("B");
  const { p, probe } = run([A, B], snap("A"), { A: status(429), B: ok("overflowed") });
  const text = await readAll(await p);
  assertMatch(text, /overflowed/);
  assertEquals(probe.reports.length, 0, "no pointer movement on overflow");
  assertEquals(probe.fetched.filter((f) => f.startsWith("A:")).length, 3, "all of A's keys tried");
  assert(probe.marks.filter(([id, okv, cd]) => id.startsWith("A-") && !okv && cd === 60).length === 3, "429 rests each key 60 s");
  // Next request: A's keys are resting, so it goes straight to B, still without a report.
  const second = run([A, B], snap("A"), { A: status(429), B: ok("again") });
  await readAll(await second.p);
  assertEquals(second.probe.fetched.every((f) => f.startsWith("B:")), true);
  assertEquals(second.probe.reports.length, 0);
});

test("hard stop: nothing answers -> ping, then a busy error event before the 25 s mark (scaled), upstream aborted", async () => {
  localCooldown.clear();
  let aborted = 0;
  const slowHeaders: Behaviour = (_k, s) => new Promise((_, bad) => s.addEventListener("abort", () => { aborted++; bad(new Error("aborted")); }, { once: true }));
  const A = route("A", 1), B = route("B", 1), C = route("C", 1), D = route("D", 1);
  const t = Date.now();
  // Headers arrive, then nothing: each attempt waits for first output; the hard stop must cut the last one in flight.
  const trickle: Behaviour = (_k, s) => { s.addEventListener("abort", () => aborted++, { once: true }); return Promise.resolve(sse([{ wait: 10_000, data: chunk("x") }], s)); };
  const { p, probe } = run([A, B, C, D], snap("A"), { A: slowHeaders, B: trickle, C: trickle, D: trickle },
    { budget: { ...FAST, headersMs: 140, firstOutputMs: 230, lastAttemptMs: 380, hardStopMs: 500 } });
  const res = await p;
  assertEquals(res.status, 200);
  assert(Date.now() - t < 100, "200 + headers go out at once");
  const text = await readAll(res, 3000);
  const took = Date.now() - t;
  assert(text.startsWith(": ping"), "ping first");
  assertMatch(text, /event: error\ndata: \{"error":\{"code":"busy","message":"SubMac is busy right now\. Please try again in a moment\.","retry_after":(1[5-9]|2\d|30)\}\}/);
  assert(took >= 480 && took < 800, `ended at the hard stop (${took} ms)`);
  assert(aborted >= 3, "in-flight attempts aborted");
  assertEquals(probe.done.length, 0, "no usage/charge when nothing was delivered");
  assert(!/sk-|P[A-D]|model-/.test(text), "no raw provider text");
});

test("heartbeat: pings until the first token and while the upstream is quiet", async () => {
  localCooldown.clear();
  const A = route("A", 1);
  const slow: Behaviour = (_k, s) => Promise.resolve(sse([
    { wait: 200, data: ": keepalive-from-upstream-ignored-by-count\n\n" }, { wait: 10, data: chunk("one") },
    { wait: 220, data: chunk("two") }, { wait: 5, data: finishChunk },
  ], s));
  const { p } = run([A], snap("A"), { A: slow }, { budget: { ...FAST, heartbeatMs: 50, firstOutputMs: 1000, lastAttemptMs: 2000, hardStopMs: 3000, idleMs: 2000 } });
  const text = await readAll(await p, 3000);
  const before = text.slice(0, text.indexOf('"one"'));
  const between = text.slice(text.indexOf('"one"'), text.indexOf('"two"'));
  assert((before.match(/^: ping$/gm) ?? []).length >= 3, "pings before the first token: " + JSON.stringify(before));
  assert((between.match(/^: ping$/gm) ?? []).length >= 2, "pings while the reply is quiet");
  assertMatch(text, /\[DONE\]/);
});

test("mid-reply silence -> cutTail (finish_reason length), charged for what was delivered", async () => {
  localCooldown.clear();
  const A = route("A", 1);
  const stall: Behaviour = (_k, s) => Promise.resolve(sse([{ wait: 5, data: chunk("partial") }, { wait: 10_000, data: chunk("never") }], s));
  const { p, probe } = run([A], snap("A"), { A: stall }, { budget: { ...FAST, idleMs: 150 } });
  const text = await readAll(await p, 2000);
  assertMatch(text, /"finish_reason":"length"/);
  assertEquals(probe.done.length, 1);
  assertEquals(probe.done[0].status, 200);
  assert(probe.done[0].outChars > 0);
});

test("client abort before the first token: upstream aborted, nothing recorded", async () => {
  localCooldown.clear();
  let upstreamAborted = false;
  const A = route("A", 1);
  const late: Behaviour = (_k, s) => Promise.resolve(sse([{ wait: 400, data: chunk("too late") }], s, () => { upstreamAborted = true; }));
  const client = new AbortController();
  const { p, probe } = run([A], snap("A"), { A: late }, { signal: client.signal, budget: { ...FAST, firstOutputMs: 1000, lastAttemptMs: 2000, hardStopMs: 3000 } });
  const res = await p;
  const reader = res.body!.getReader();
  await reader.read(); // the ping
  client.abort(); // the phone hangs up (req.signal)
  await reader.cancel();
  await sleep(50);
  assert(upstreamAborted, "upstream fetch aborted");
  assertEquals(probe.done.length, 0, "no usage and no charge when nothing was delivered");
  assertEquals(probe.reports.length, 0, "a hang-up is not a route failure");
});

test("client abort mid-reply: upstream aborted, recorded as 499 with the delivered output only", async () => {
  localCooldown.clear();
  let upstreamAborted = false;
  const A = route("A", 1);
  const longReply: Behaviour = (_k, s) => Promise.resolve(sse([{ wait: 5, data: chunk("first") }, { wait: 300, data: chunk("second") }], s, () => { upstreamAborted = true; }));
  const client = new AbortController();
  const { p, probe } = run([A], snap("A"), { A: longReply }, { signal: client.signal });
  const res = await p;
  const reader = res.body!.getReader(); const dec = new TextDecoder(); let got = "";
  while (!got.includes("first")) got += dec.decode((await reader.read()).value);
  client.abort();
  await reader.cancel();
  await sleep(50);
  assert(upstreamAborted);
  assertEquals(probe.done.length, 1);
  assertEquals(probe.done[0].status, 499);
  assertEquals(probe.done[0].outChars, "first".length);
});

test("non-streamed: busy JSON with Retry-After 15–30 s; success rewrites the model name", async () => {
  localCooldown.clear();
  const A = route("A", 1), B = route("B", 1);
  const bad = run([A, B], snap("A"), { A: status(500), B: status(502) }, { stream: false });
  const r1 = await bad.p;
  assertEquals(r1.status, 503);
  const ra = Number(r1.headers.get("Retry-After"));
  assert(ra >= 15 && ra <= 30);
  const j = await r1.json();
  assertEquals(j.error.code, "busy");
  localCooldown.clear();
  const good = run([A], snap("A"), { A: () => Promise.resolve(Response.json({ model: "model-A", choices: [{ message: { content: "yo" } }], usage: { prompt_tokens: 1, completion_tokens: 1 } })) }, { stream: false });
  const r2 = await good.p;
  const j2 = await r2.json();
  assertEquals(j2.model, "submac");
  assertEquals(good.probe.done[0].status, 200);
});

test("non-streamed hang: ends at the total budget", async () => {
  localCooldown.clear();
  const t = Date.now();
  const { p } = run([route("A", 1)], snap("A"), { A: hang }, { stream: false, budget: { ...FAST, nonStreamMs: 300, nonStreamAttemptMs: 1000 } });
  const r = await p;
  assertEquals(r.status, 503);
  assert(Date.now() - t < 600);
});

test("effort hint maps to reasoning_effort only where the route takes it", () => {
  assertEquals(effortBody(route("A", 1, { model: "gemini-3-flash-preview" }), "low"), { reasoning_effort: "low" });
  assertEquals(effortBody(route("A", 1, { model: "gpt-oss:120b" }), "high"), { reasoning_effort: "high" });
  assertEquals(effortBody(route("A", 1, { model: "gemini-3-flash-preview" }), "normal"), {});
  assertEquals(effortBody(route("A", 1, { model: "agnes-3.0-flash" }), "low"), {});
  assertEquals(effortBody(route("A", 1, { model: "x", extra_body: { reasoning_effort: "medium" } }), "low"), { reasoning_effort: "low" });
});

test("budgets default to the PLAN 1.3 numbers", () => {
  const b = budgetFrom({});
  assertEquals([b.headersMs, b.firstOutputMs, b.lastAttemptMs, b.hardStopMs, b.heartbeatMs, b.idleMs, b.nonStreamMs], [6000, 10000, 18000, 25000, 10000, 45000, 45000]);
  assertEquals(budgetFrom({}, true).nonStreamMs, 38000);
});

// ---- Provider output limits (a request above the limit is a 400 and a wasted first try)
import { clampOut, providerOutCap } from "./router.ts";

test("output cap: Poolside is clamped to 32768, others are not; settings add or override", () => {
  assertEquals(providerOutCap({ provider: "Poolside", model: "poolside/laguna-s-2.1" }), 32768);
  assertEquals(providerOutCap({ provider: "Google Gemini", model: "gemini-3-flash-preview" }), 0);
  assertEquals(providerOutCap({ provider: "NVIDIA NIM", model: "x" }, { provider_max_output_tokens: { "nvidia nim": 16384 } }), 16384);
  assertEquals(providerOutCap({ provider: "Poolside", model: "p" }, { provider_max_output_tokens: { poolside: 65536 } }), 65536);
  assertEquals(providerOutCap({ provider: "Poolside", model: "p" }, { provider_max_output_tokens: "junk" }), 32768);
  assertEquals(clampOut(64000, 32768), 32768);
  assertEquals(clampOut(64000, 0), 64000);
  assertEquals(clampOut(64000, 32768, 8192), 8192);
  assertEquals(clampOut(2000, 32768), 2000);
});

// 2026-10-23 15:31 UTC: "Google Gemini 400: Function call is missing a thought_signature" on an agent step with tool
// history; the request only got an answer from the fourth route after 14.9 s.
test("gemini routes get the dummy thought signature on history tool calls; others are untouched", () => {
  const msgs = [
    { role: "user", content: "find hotels" },
    { role: "assistant", content: null, tool_calls: [{ id: "c1", type: "function", function: { name: "web_search", arguments: "{}" } },
      { id: "c2", type: "function", function: { name: "fetch_url", arguments: "{}" }, extra_content: { google: { thought_signature: "real" } } }] },
    { role: "tool", tool_call_id: "c1", content: "r1" },
    { role: "tool", tool_call_id: "c2", content: "r2" },
  ];
  const gem = route("G", 1, { provider: "Google Gemini", model: "gemini-3.5-flash-lite", base_url: "https://generativelanguage.googleapis.com/v1beta/openai" });
  const out = withThoughtSignatures(msgs, gem);
  assertEquals(out[1].tool_calls[0].extra_content.google.thought_signature, GEMINI_SKIP_SIGNATURE);
  assertEquals(out[1].tool_calls[1].extra_content.google.thought_signature, "real");
  assertEquals((msgs[1] as any).tool_calls[0].extra_content, undefined, "the shared plan messages are not mutated");
  assert(withThoughtSignatures(msgs, route("O")) === msgs);
  const noTools = [{ role: "user", content: "hi" }];
  assert(withThoughtSignatures(noTools, gem) === noTools);
});

// ---- S-1 / CB-15 (ai-chat v42): request errors are not route failures; timed swap-back to the preferred route
import { homeProbe, modelMissing } from "./router.ts";

test("CB-15: 400 and 422 move the request on but are never reported; the pointer stays", async () => {
  for (const code of [400, 422]) {
    localCooldown.clear();
    const A = route("A", 1), B = route("B", 1);
    const { p, probe } = run([A, B], snap("A"), { A: status(code), B: ok("B answers") });
    const text = await readAll(await p);
    assertMatch(text, /B answers/);
    assertEquals(probe.reports.length, 0, `${code} is a request error, not a route failure`);
  }
});

test("CB-15: 404 counts only when the model is missing", async () => {
  localCooldown.clear();
  const A = route("A", 1), B = route("B", 1);
  const missing: Behaviour = () => Promise.resolve(new Response(`{"error":{"message":"model 'gpt-x' not found"}}`, { status: 404 }));
  const r1 = run([A, B], snap("A"), { A: missing, B: ok() });
  await readAll(await r1.p);
  assertEquals(r1.probe.reports, [["A", "hard", "B"]]);
  localCooldown.clear();
  const r2 = run([A, B], snap("A"), { A: status(404), B: ok() });
  await readAll(await r2.p);
  assertEquals(r2.probe.reports.length, 0, "a plain 404 is not a route failure");
  assert(modelMissing("The model `x` does not exist"));
  assert(modelMissing('{"error":{"code":"model_not_found"}}'));
  assert(!modelMissing('{"error":"x404"}'));
});

test("CB-15 swap-back: rest expired + 15 min on the fallback -> the preferred route is probed first; success moves the pointer home", async () => {
  localCooldown.clear();
  const H = route("H", 2), F = route("F", 2);
  const old = new Date(Date.now() - 16 * 60_000).toISOString();
  const homes: [string, string, boolean, string | null][] = [];
  // JS copy of the ai_router_home compare-and-set.
  let pointer = "F";
  const s = (): RouterSnap => ({ current_route_id: pointer, since: old, rest: {} });
  const fetched: string[] = [];
  const deps: Deps = {
    fetch: mockFetch({ H: ok("home"), F: ok("fallback") }, fetched), now: () => Date.now(),
    report: () => {}, markKey: () => {}, attemptFailed: () => {},
    home: (h, from, okv, kind) => { homes.push([h, from, okv, kind]); if (okv && from === pointer) pointer = h; },
  };
  const res = await runChat({ routes: [H, F], snap: s(), chat: "u:c", stream: true, alias: "submac", homeId: "H", homeAfterMs: 15 * 60_000,
    payloadFor: (r) => ({ model: r.model }), ensureKeys: () => Promise.resolve(), t0: Date.now(), budget: FAST, headers: {}, deps, onDone: () => {} });
  const text = await readAll(res);
  assertMatch(text, /home/);
  assertEquals(fetched.length, 1);
  assert(fetched[0].startsWith("H:"), "preferred route probed first");
  assertEquals(homes, [["H", "F", true, null]]);
  assertEquals(pointer, "H", "pointer moved home");
  // Next request: H is current, no probe and no further home call.
  const fetched2: string[] = []; const homes2: unknown[] = [];
  const res2 = await runChat({ routes: [H, F], snap: s(), chat: "u:c", stream: true, alias: "submac", homeId: "H", homeAfterMs: 15 * 60_000,
    payloadFor: (r) => ({ model: r.model }), ensureKeys: () => Promise.resolve(), t0: Date.now(), budget: FAST, headers: {},
    deps: { ...deps, fetch: mockFetch({ H: ok("home"), F: ok("fallback") }, fetched2), home: (...a) => homes2.push(a) }, onDone: () => {} });
  await readAll(res2);
  assertEquals(homes2.length, 0);
  assert(fetched2[0].startsWith("H:"));
});

test("CB-15 swap-back: no probe while the preferred route rests or before 15 min; a failed probe rests it and the request still answers", async () => {
  localCooldown.clear();
  const H = route("H", 2), F = route("F", 2);
  const old = new Date(Date.now() - 16 * 60_000).toISOString();
  const recent = new Date(Date.now() - 5 * 60_000).toISOString();
  const later = new Date(Date.now() + 60_000).toISOString();
  assertEquals(homeProbe([H, F], { current_route_id: "F", since: recent, rest: {} }, "H", 15 * 60_000), null, "too soon");
  assertEquals(homeProbe([H, F], { current_route_id: "F", since: old, rest: { H: later } }, "H", 15 * 60_000), null, "still resting");
  assertEquals(homeProbe([H, F], { current_route_id: "H", since: old, rest: {} }, "H", 15 * 60_000), null, "already home");
  assertEquals(homeProbe([F], { current_route_id: "F", since: old, rest: {} }, "H", 15 * 60_000), null, "home can't serve this request");
  assertEquals(homeProbe([H, F], { current_route_id: "F", since: old, rest: {} }, "H", 15 * 60_000)?.route_id, "H");
  // The probe fails hard: one key only, the request moves on to the current route, no report against F, H rests.
  const fetched: string[] = []; const homes: unknown[] = []; const reports: unknown[] = [];
  const deps: Deps = {
    fetch: mockFetch({ H: status(503), F: ok("fallback") }, fetched), now: () => Date.now(),
    report: (...a) => reports.push(a), markKey: () => {}, attemptFailed: () => {}, home: (...a) => homes.push(a),
  };
  const res = await runChat({ routes: [H, F], snap: { current_route_id: "F", since: old, rest: {} }, chat: "u:c", stream: true, alias: "submac",
    homeId: "H", homeAfterMs: 15 * 60_000, payloadFor: (r) => ({ model: r.model }), ensureKeys: () => Promise.resolve(), t0: Date.now(),
    budget: FAST, headers: {}, deps, onDone: () => {} });
  assertMatch(await readAll(res), /fallback/);
  assertEquals(fetched.filter((f) => f.startsWith("H:")).length, 1, "the probe uses one key");
  assertEquals(homes, [["H", "F", false, "hard"]]);
  assertEquals(reports.length, 0, "a failed probe never counts against the pointer's route");
  assertEquals(homeProbe([H, F], { current_route_id: "F", since: old, rest: {} }, "H", 15 * 60_000), null, "local cooldown stops re-probing in this isolate");
});
