// CB-45 on the deployable bundle: 'bot-chat' bills in the user's chat lane (like 'agent'), is not a bot source, and an
// x-submac-lane: background header cannot push it into the bot share. Loads the bundle with Deno.serve stubbed.
// Run: deno test --no-check -A supabase/live/ai-chat-v43_bot_chat_test.ts   (BUNDLE=./ai-chat-v42.js shows the old behaviour)
// deno-lint-ignore-file no-explicit-any
import { assert, assertEquals } from "jsr:@std/assert@1";
const file = Deno.env.get("BUNDLE") ?? "./ai-chat-v43.js";
const src = await Deno.readTextFile(new URL(file, import.meta.url));
Deno.env.set("SUPABASE_URL", "http://x"); Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "k");
const realServe = Deno.serve; (Deno as any).serve = () => ({});
const mod = await import("data:application/javascript;base64," + btoa(unescape(encodeURIComponent(src + "\nexport { billSource, BOT_SOURCES, preKey };"))));
(Deno as any).serve = realServe;
// billing.is_bot(p_source) in the DB = lower(coalesce(p_source,'')) in ('bot','bot-cloud','bot_cloud','background','office')
const DB_BOT = new Set(["bot", "bot-cloud", "bot_cloud", "background", "office"]);
const isBot = (s: string) => DB_BOT.has(s.toLowerCase());

Deno.test({ name: "CB-45 bundle: bundle BOT_SOURCES == DB billing.is_bot list; 'bot-chat' is not a bot source", sanitizeOps: false, sanitizeResources: false, fn: () => {
  assertEquals([...mod.BOT_SOURCES].sort(), [...DB_BOT].sort());
  assertEquals(isBot("bot-chat"), false);
} });

Deno.test({ name: "CB-45 bundle: 'bot-chat' bills as itself in the chat lane, user or background lane header", sanitizeOps: false, sanitizeResources: false, fn: () => {
  for (const bg of [false, true]) {
    assertEquals(mod.billSource("bot-chat", bg), "bot-chat");
    assertEquals(isBot(mod.billSource("bot-chat", bg)), false);
  }
  assertEquals(mod.preKey("u1", mod.billSource("bot-chat", true)), "u1"); // chat precheck cache, not "u1|bg"
  // unchanged lanes
  assertEquals(mod.billSource("agent", false), "agent");
  assertEquals(mod.billSource("agent", true), "background");
  assertEquals(mod.billSource("bot", false), "bot");
  assertEquals(mod.billSource("office", true), "office");
} });

Deno.test({ name: "CB-45 bundle: the request handler drops the background lane for 'bot-chat'", sanitizeOps: false, sanitizeResources: false, fn: () => {
  const line = src.split("\n").find((l) => l.includes("const background = !!internal")) ?? "";
  assert(/&& !chatLane\(source\)/.test(line), line);
} });
