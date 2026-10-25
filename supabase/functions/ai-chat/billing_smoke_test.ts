// ai-chat with billing ON (Contract B) against a MOCK PostgREST and MOCK upstream: usage_gate before, usage_charge after,
// Contract A codes on refusal, and a graceful fall back when Dev 2's functions are not deployed yet.
// Run: NO_PROXY=127.0.0.1 deno test -A supabase/functions/ai-chat/billing_smoke_test.ts   (ports 54992 mock, 54993 function)
// deno-lint-ignore-file no-explicit-any
import { assert, assertEquals, assertMatch } from "jsr:@std/assert@1";

const MOCK = 54992;
const calls: { path: string; body: any }[] = [];
let gateMode: "missing" | "allow" | "deny" = "missing";
let chargeFail = false;
const route = { route_id: "A", model_ref: "mA", model: "gpt-oss:120b", vision: true, tools: true, context_window: 128000, extra_body: null, healthy: true,
  provider: "PA", provider_id: "pA", base_url: `http://127.0.0.1:${MOCK}/up/A` };
const config = {
  settings: { daily_cap_tokens: 200000, billing_enabled: true, billing_precheck_cache_ms: 0 },
  aliases: [{ alias: "submac", max_output_tokens: 4096, system_hint: null, routes: [route] }],
  key_meta: { pA: [{ id: "kA", cooldown_until: null }] },
};
const sse = (text: string) => `data: ${JSON.stringify({ choices: [{ index: 0, delta: { content: text } }] })}\n\n` +
  `data: ${JSON.stringify({ choices: [{ index: 0, delta: {}, finish_reason: "stop" }], usage: { prompt_tokens: 50, completion_tokens: 7 } })}\n\ndata: [DONE]\n\n`;
const missing = (fn: string) => Response.json({ code: "PGRST202", message: `Could not find the function public.${fn} in the schema cache` }, { status: 404 });

const mock = Deno.serve({ port: MOCK, onListen() {} }, async (req) => {
  const u = new URL(req.url);
  const body = await req.json().catch(() => null);
  calls.push({ path: u.pathname, body });
  if (u.pathname === "/rest/v1/rpc/ai_gate") {
    return Response.json({ blocked: false, burst: 0, usage: { tokens: 1000, requests: 1, bg: 0 }, cap: { cap: 200000, base: 200000 },
      config: body.p_want_config ? config : null, keys: null, router: { current_route_id: "A", rest: {} } });
  }
  if (u.pathname === "/rest/v1/rpc/ai_provider_keys") return Response.json({ pA: [{ id: "kA", key: "sk-A" }] });
  if (u.pathname === "/rest/v1/rpc/usage_gate") {
    if (gateMode === "missing") return missing("usage_gate(p_source, p_user_id)");
    if (gateMode === "deny") return Response.json({ allow: false, enabled: true, code: "limit_total", today_left: 0, total_left: 0, plan: "free", reply_cap: 0, resets_at: "2026-10-23T21:00:00+00:00" });
    return Response.json({ allow: true, enabled: true, code: null, today_left: 50000, total_left: 700000, plan: "monthly", reply_cap: 8192, resets_at: "2026-10-23T21:00:00+00:00" });
  }
  if (u.pathname === "/rest/v1/rpc/usage_charge") {
    if (gateMode === "missing") return missing("usage_charge");
    if (chargeFail) return Response.json({ message: "boom" }, { status: 500 });
    return Response.json({ ok: true, enabled: true, charged: (body.p_tokens_in ?? 0) + (body.p_tokens_out ?? 0), unpaid: 0, today_left: 1, total_left: 1, plan: "monthly" });
  }
  if (u.pathname === "/rest/v1/rpc/usage_charge_enqueue") return Response.json({ queued: true });
  if (u.pathname === "/rest/v1/rpc/live_call_beat") return Response.json({ ok: true, enabled: true, call_seconds: 60, added_seconds: 30, used_seconds: 60, limit_seconds: 600 });
  if (u.pathname.startsWith("/rest/v1/rpc/")) return Response.json(null);
  if (u.pathname === "/rest/v1/ai_blocked_users") return Response.json([]);
  if (u.pathname === "/up/A/chat/completions") return new Response(sse("hello from A"), { headers: { "content-type": "text/event-stream" } });
  return new Response("not found", { status: 404 });
});

const jwt = "x." + btoa(JSON.stringify({ role: "authenticated", sub: "22222222-2222-2222-2222-222222222222" })).replace(/=+$/, "") + ".y";
const FN = 54993;
const wrapper = await Deno.makeTempFile({ suffix: ".ts" });
await Deno.writeTextFile(wrapper, `const o = Deno.serve.bind(Deno); (Deno as any).serve = (h: any) => o({ port: ${FN}, onListen() {} }, h);\nawait import(${JSON.stringify(new URL("./index.ts", import.meta.url).href)});\n`);
const fn = new Deno.Command(Deno.execPath(), {
  args: ["run", "-A", wrapper],
  env: { NO_PROXY: "127.0.0.1,localhost", no_proxy: "127.0.0.1,localhost", SUPABASE_URL: `http://127.0.0.1:${MOCK}`, SUPABASE_SERVICE_ROLE_KEY: "service-key-for-tests-only" },
  stdout: "null", stderr: "null",
}).spawn();
async function ready() {
  for (let i = 0; i < 100; i++) {
    try { const r = await fetch(`http://127.0.0.1:${FN}/x`, { method: "OPTIONS" }); await r.body?.cancel(); return; } catch { await new Promise((ok) => setTimeout(ok, 100)); }
  }
  throw new Error("function did not start");
}
const chat = (body: unknown, extra: Record<string, string> = {}) => fetch(`http://127.0.0.1:${FN}/ai-chat`, {
  method: "POST", headers: { authorization: "Bearer " + jwt, "content-type": "application/json", "x-submac-chat": "c1", ...extra }, body: JSON.stringify(body),
});
const rpcCalls = (fn: string) => calls.filter((c) => c.path === `/rest/v1/rpc/${fn}`);
const settle = () => new Promise((ok) => setTimeout(ok, 300));

Deno.test({ name: "ai-chat billing on (usage_gate / usage_charge)", sanitizeOps: false, sanitizeResources: false, fn: async (t) => {
  await ready();
  try {
    await t.step("functions not deployed yet -> the reply still goes out on the old allowance, no coin RPCs", async () => {
      gateMode = "missing";
      const r = await chat({ model: "submac", stream: true, messages: [{ role: "user", content: "hi" }] });
      assertEquals(r.status, 200);
      assertMatch(await r.text(), /hello from A/);
      assertEquals(r.headers.get("x-submac-plan"), "free");
      assert(rpcCalls("usage_gate").length >= 1, "usage_gate asked");
      for (const old of ["billing_precheck", "billing_multipliers", "billing_consume", "billing_consume_enqueue"]) assertEquals(rpcCalls(old).length, 0, old);
    });
    await t.step("allow -> Contract A headers from the gate; charged once with raw tokens and a request id", async () => {
      gateMode = "allow";
      const before = rpcCalls("usage_charge").length;
      const r = await chat({ model: "submac", stream: true, messages: [{ role: "user", content: "hello there" }] });
      assertEquals(r.status, 200);
      assertMatch(await r.text(), /hello from A/);
      assertEquals(r.headers.get("x-submac-plan"), "monthly");
      assertEquals(r.headers.get("x-submac-today-left"), "50000");
      assertEquals(r.headers.get("x-submac-total-left"), "700000");
      assertEquals(r.headers.get("x-submac-resets-at"), "2026-10-24T00:00:00+03:00");
      assertEquals(rpcCalls("usage_gate").at(-1)!.body, { p_user_id: "22222222-2222-2222-2222-222222222222", p_source: "agent" });
      await settle();
      const charges = rpcCalls("usage_charge").slice(before);
      assertEquals(charges.length, 1);
      const c = charges[0].body;
      assertEquals([c.p_tokens_in, c.p_tokens_out, c.p_source], [50, 7, "agent"]);
      assertMatch(c.p_request_id, /^chat:/);
    });
    await t.step("background lane -> gate and charge use the bot source", async () => {
      const before = rpcCalls("usage_charge").length;
      const r = await chat({ model: "submac", stream: true, messages: [{ role: "user", content: "bot wake" }] }, { "x-submac-lane": "background" });
      await r.text();
      assertEquals(rpcCalls("usage_gate").at(-1)!.body.p_source, "background");
      await settle();
      assertEquals(rpcCalls("usage_charge").slice(before)[0]?.body.p_source, "background");
    });
    await t.step("deny -> 429 with the Contract A code and friendly text, no model call", async () => {
      gateMode = "deny";
      const ups = calls.filter((c) => c.path.startsWith("/up/")).length;
      const r = await chat({ model: "submac", stream: true, messages: [{ role: "user", content: "more" }] });
      const j = await r.json();
      assertEquals(r.status, 429);
      assertEquals(j.error.code, "limit_total");
      assertEquals(r.headers.get("x-submac-error"), "limit_total");
      assert(!/coin|pass|pack/i.test(j.error.message), j.error.message);
      assertEquals(calls.filter((c) => c.path.startsWith("/up/")).length, ups);
    });
    await t.step("Live: usage_charge(source live) per heartbeat; a charge that fails twice is parked with usage_charge_enqueue (same request id)", async () => {
      gateMode = "allow";
      const post = () => fetch(`http://127.0.0.1:${FN}/ai-chat/live-usage`, { method: "POST",
        headers: { authorization: "Bearer " + jwt, "content-type": "application/json" }, body: JSON.stringify({ call_id: "call-1", seconds: 60 }) });
      let r = await post();
      assertEquals(r.status, 200);
      const ok = await r.json();
      assertEquals(ok.billing, true);
      const ch = rpcCalls("usage_charge").at(-1)!.body;
      assertEquals(ch, { p_user_id: "22222222-2222-2222-2222-222222222222", p_tokens_in: 30, p_tokens_out: 0, p_source: "live", p_request_id: "live:call-1:60" });
      chargeFail = true;
      const before = rpcCalls("usage_charge_enqueue").length;
      r = await post();
      const j = await r.json();
      chargeFail = false;
      assertEquals(r.status, 200, "a charge outage never cuts the call");
      assertEquals(j.billing_degraded, true);
      const q = rpcCalls("usage_charge_enqueue").slice(before);
      assertEquals(q.length, 1);
      assertEquals(q[0].body.p_request_id, "live:call-1:60");
      assertEquals(q[0].body.p_source, "live");
    });
  } finally {
    fn.kill(); await fn.status; await mock.shutdown();
  }
} });
