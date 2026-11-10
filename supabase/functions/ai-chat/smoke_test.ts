// End-to-end smoke test of ai-chat/index.ts against a MOCK PostgREST and MOCK model upstreams (no real services).
// Run: NO_PROXY=127.0.0.1 deno test -A supabase/functions/ai-chat/smoke_test.ts   (uses local ports 54990 for the mocks and 54991 for the function)
import { assert, assertEquals, assertMatch } from "jsr:@std/assert@1";

const MOCK = 54990;
const calls: { path: string; body: any }[] = [];
let gateDelay = 0;
let failA = false;
const route = (id: string, model: string, vision: boolean) => ({
  route_id: id, model_ref: "m" + id, model, vision, tools: true, context_window: 128000, extra_body: null, healthy: true,
  provider: id === "A" ? "Poolside" : "P" + id, provider_id: "p" + id, base_url: `http://127.0.0.1:${MOCK}/up/${id}`,
});
const config = {
  settings: { daily_cap_tokens: 200000 },
  aliases: [
    { alias: "telesia", max_output_tokens: 64000, system_hint: null, routes: [route("A", "gpt-oss:120b", false), route("G", "gemini-3-flash-preview", true)] },
    { alias: "telesia-smart", max_output_tokens: 4096, system_hint: null, routes: [route("S", "legacy-smart", false)] },
  ],
  key_meta: { pA: [{ id: "kA", cooldown_until: null }], pG: [{ id: "kG", cooldown_until: null }], pS: [{ id: "kS", cooldown_until: null }] },
};
const sse = (text: string) => `data: ${JSON.stringify({ choices: [{ index: 0, delta: { content: text } }] })}\n\n` +
  `data: ${JSON.stringify({ choices: [{ index: 0, delta: {}, finish_reason: "stop" }], usage: { prompt_tokens: 5, completion_tokens: 2 } })}\n\ndata: [DONE]\n\n`;

const mock = Deno.serve({ port: MOCK, onListen() {} }, async (req) => {
  const u = new URL(req.url);
  const body = await req.json().catch(() => null);
  calls.push({ path: u.pathname, body });
  if (u.pathname === "/rest/v1/rpc/ai_gate") {
    if (gateDelay) await new Promise((ok) => setTimeout(ok, gateDelay));
    return Response.json({ blocked: false, burst: 0, usage: { tokens: 1000, requests: 1, bg: 0 }, cap: { cap: 200000, base: 200000 },
      config: body.p_want_config ? config : null, keys: null, router: { current_route_id: "A", rest: {} } });
  }
  if (u.pathname === "/rest/v1/rpc/ai_provider_keys") return Response.json({ pA: [{ id: "kA", key: "sk-A" }], pG: [{ id: "kG", key: "sk-G" }], pS: [{ id: "kS", key: "sk-S" }] });
  if (u.pathname.startsWith("/rest/v1/rpc/")) return Response.json(null);
  const m = u.pathname.match(/^\/up\/(\w+)\/chat\/completions$/);
  if (m) {
    if (m[1] === "A" && failA) return new Response("{\"error\":\"boom\"}", { status: 500 });
    return new Response(sse("hello from " + m[1]), { headers: { "content-type": "text/event-stream" } });
  }
  return new Response("not found", { status: 404 });
});

const jwt = "x." + btoa(JSON.stringify({ role: "authenticated", sub: "11111111-1111-1111-1111-111111111111" })).replace(/=+$/, "") + ".y";
// Runs index.ts on port FN (Deno.serve is wrapped so the function does not need to know about the test).
const FN = 54991;
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
  method: "POST", headers: { authorization: "Bearer " + jwt, "content-type": "application/json", "x-telesia-chat": "c1", ...extra }, body: JSON.stringify(body),
});
const upstreamBodies = (id: string) => calls.filter((c) => c.path === `/up/${id}/chat/completions`).map((c) => c.body);

Deno.test({ name: "ai-chat smoke (mock DB + mock upstream)", sanitizeOps: false, sanitizeResources: false, fn: async (t) => {
  await ready();
  try {
    await t.step("old alias name -> one model, current route, ping first, Contract A headers, effort hint", async () => {
      const r = await chat({ model: "telesia-think", stream: true, messages: [{ role: "user", content: "hi" }] }, { "x-telesia-effort": "low" });
      assertEquals(r.status, 200);
      for (const h of ["x-telesia-today-left", "x-telesia-total-left", "x-telesia-resets-at", "x-telesia-plan"]) assert(r.headers.get(h), h);
      assertEquals(r.headers.get("x-telesia-today-left"), "199000");
      // Contract A: next 00:00 EAT (= 21:00 UTC) with billing off too; the legacy counter's day is the EAT date.
      const eatNow = new Date(Date.now() + 3 * 3600_000);
      const next = new Date(Date.UTC(eatNow.getUTCFullYear(), eatNow.getUTCMonth(), eatNow.getUTCDate() + 1)).toISOString().slice(0, 10);
      assertEquals(r.headers.get("x-telesia-resets-at"), next + "T00:00:00+03:00");
      assertEquals(Date.parse(r.headers.get("x-telesia-resets-at")!) % 86_400_000, 21 * 3600_000);
      assertEquals(r.headers.get("x-telesia-plan"), "free");
      const text = await r.text();
      assert(text.startsWith(": ping"), text.slice(0, 40));
      assertMatch(text, /hello from A/);
      assertMatch(text, /"model":"telesia"/);
      const b = upstreamBodies("A").at(-1);
      assertEquals(b.model, "gpt-oss:120b");
      assertEquals(b.reasoning_effort, "low");
      assertEquals(b.max_tokens, 32768, "Poolside never gets more than its 32768 output limit (alias asks 64000)");
      assertEquals(upstreamBodies("S").length, 0, "legacy telesia-smart routes unused once alias telesia exists");
    });
    await t.step("photo -> capability filter picks the vision route (no alias forcing)", async () => {
      const r = await chat({ model: "telesia-smart", stream: true, messages: [{ role: "user", content: [{ type: "text", text: "what is this" }, { type: "image_url", image_url: { url: "data:image/png;base64,AA" } }] }] });
      assertMatch(await r.text(), /hello from G/);
      assertEquals(upstreamBodies("G").at(-1).max_tokens, 64000, "no clamp for a provider without a known limit");
    });
    await t.step("current route fails -> same request answered by the next route; failure reported to the router", async () => {
      failA = true;
      const r = await chat({ model: "telesia", stream: true, messages: [{ role: "user", content: "hi again" }] });
      assertMatch(await r.text(), /hello from G/);
      await new Promise((ok) => setTimeout(ok, 200));
      const rep = calls.filter((c) => c.path === "/rest/v1/rpc/ai_router_report").at(-1);
      assertEquals(rep?.body, { p_route_id: "A", p_kind: "hard", p_next_route_id: "G" });
      failA = false;
    });
    await t.step("/models lists the one model", async () => {
      const r = await fetch(`http://127.0.0.1:${FN}/ai-chat/models`, { headers: { authorization: "Bearer " + jwt } });
      assertEquals((await r.json()).data.map((m: any) => m.id), ["telesia"]);
    });
    await t.step("slow gate (> 2 s) -> friendly busy with Retry-After, no raw text", async () => {
      gateDelay = 3000;
      const t0 = Date.now();
      const r = await chat({ model: "telesia", stream: true, messages: [{ role: "user", content: "x" }] });
      const took = Date.now() - t0;
      const j = await r.json();
      gateDelay = 0;
      assertEquals(r.status, 503);
      assert(took < 2800, `gave up at the 2 s gate limit (${took} ms)`);
      assertEquals(j.error.telesia_code, "busy");
      assertEquals(r.headers.get("x-telesia-error"), "busy");
      const ra = Number(r.headers.get("retry-after"));
      assert(ra >= 15 && ra <= 30);
      assert(!/gate|timeout|TypeError/i.test(j.error.message), j.error.message);
    });
  } finally {
    fn.kill(); await fn.status; await mock.shutdown();
  }
} });
