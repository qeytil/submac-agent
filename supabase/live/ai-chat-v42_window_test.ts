// CB-23: x-telesia-window = smallest window over ALL the alias's healthy text routes (loads the deployable bundle with
// Deno.serve stubbed and exposes makePlan).
import { assertEquals } from "jsr:@std/assert@1";
const src = await Deno.readTextFile(new URL(Deno.env.get("BUNDLE") ?? "./ai-chat-v42.js", import.meta.url));
Deno.env.set("SUPABASE_URL", "http://x"); Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "k");
const realServe = Deno.serve; (Deno as any).serve = () => ({});
const mod = await import("data:application/javascript;base64," + btoa(unescape(encodeURIComponent(src + "\nexport { makePlan };"))));
(Deno as any).serve = realServe;
const R = (id: string, cw: number, vision: boolean, healthy = true) => ({ route_id: id, model: "m" + id, vision, tools: true, context_window: cw, healthy, keys: [] });
const cfg = { settings: {}, aliases: [{ alias: "telesia", max_output_tokens: 8192, system_hint: null,
  routes: [R("gem", 1048576, true), R("gem2", 1048576, true), R("oll", 128000, false), R("bad", 32000, false, false)] }] };
const msg = (img: boolean) => ({ messages: [{ role: "user", content: img ? [{ type: "text", text: "what is this" }, { type: "image_url", image_url: { url: "data:image/png;base64,AAAA" } }] : "hi" }] });
Deno.test({ name: "CB-23: a photo request reports the smallest healthy TEXT window (128000), not the vision routes' 1M", sanitizeOps: false, sanitizeResources: false, fn: () => {
  const pv = mod.makePlan(cfg, msg(true), "ok", null);
  assertEquals(pv.routes.map((r: any) => r.route_id), ["gem", "gem2"]);
  assertEquals(pv.smallestWindow, "128000");
  const pt = mod.makePlan(cfg, msg(false), "ok", null);
  assertEquals(pt.smallestWindow, "128000");
} });
