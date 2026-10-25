// Contract B glue: usage_gate answers -> what ai-chat spends, sources for the bot lane, "not deployed yet" detection.
// Run: deno test supabase/functions/ai-chat/billing_gate_test.ts
import { assert, assertEquals } from "jsr:@std/assert@1";
import { billSource, entFromGate, missingFn } from "./billing_gate.ts";

Deno.test("gate: billing off for this user -> null (the old allowance applies)", () => {
  assertEquals(entFromGate({ allow: true, enabled: false, plan: "free", reply_cap: 8192 }), null);
});

Deno.test("gate: allow -> allowance, plan, total, reply cap and live seconds", () => {
  const e = entFromGate({ allow: true, enabled: true, code: null, today_left: 120000, total_left: 900000, resets_at: "2026-10-23T21:00:00+00:00",
    plan: "weekly", reply_cap: 8192 }, { billing_live_tokens_per_minute: 40000 }) as Record<string, any>;
  assertEquals(e.allowance, 120000);
  assertEquals(e.state, "ok");
  assertEquals(e.plan, "weekly");
  assertEquals(e.paid, true);
  assertEquals(e.total_left, 900000);
  assertEquals(e.reply_cap, 8192);
  assertEquals(e.live_seconds_left, 180);
  assertEquals(e.code, null);
});

Deno.test("gate: deny keeps the Contract A code and spends nothing", () => {
  for (const code of ["limit_daily", "limit_total", "no_plan"]) {
    const e = entFromGate({ allow: false, enabled: true, code, today_left: 5000, total_left: 0, plan: "free", reply_cap: 0 }) as Record<string, any>;
    assertEquals(e.allowance, 0);
    assertEquals(e.state, "limit");
    assertEquals(e.code, code);
  }
  const odd = entFromGate({ allow: false, enabled: true, code: "weird" }) as Record<string, any>;
  assertEquals(odd.code, "limit_daily");
});

Deno.test("gate: garbage is an error, never a free pass", () => {
  assertEquals(entFromGate(null), "error");
  assertEquals(entFromGate("x"), "error");
  assertEquals(entFromGate({ enabled: true }), "error");
});

Deno.test("sources: background work uses the bot lane, the user's own chat does not", () => {
  assertEquals(billSource("agent", false), "agent");
  assertEquals(billSource("agent", true), "background");
  assertEquals(billSource("bot-cloud", true), "bot-cloud");
  assertEquals(billSource("office", true), "office");
  assertEquals(billSource("", false), "agent");
});

Deno.test("missing functions are detected (migration not applied yet)", () => {
  assert(missingFn("Could not find the function public.usage_gate(p_source, p_user_id) in the schema cache"));
  assert(missingFn("PGRST202"));
  assert(missingFn("usage_gate 404"));
  assert(!missingFn("gate timeout"));
  assert(!missingFn("usage_gate 500"));
});

// ---- EAT day (Contract A resets-at, ai_user_daily key)
import { eatDay, nextEatMidnight, resetsAtHeader } from "./billing_gate.ts";

Deno.test("eat day: the EAT date flips at 21:00 UTC", () => {
  assertEquals(eatDay(Date.parse("2026-10-23T20:59:59Z")), "2026-10-23");
  assertEquals(eatDay(Date.parse("2026-10-23T21:00:00Z")), "2026-10-24");
  assertEquals(eatDay(Date.parse("2026-10-23T00:30:00Z")), "2026-10-23");
});

Deno.test("eat day: next midnight is 21:00 UTC of the current EAT date", () => {
  assertEquals(nextEatMidnight(Date.parse("2026-10-23T11:00:00Z")), "2026-10-23T21:00:00.000Z");
  assertEquals(nextEatMidnight(Date.parse("2026-10-23T21:00:00Z")), "2026-10-24T21:00:00.000Z");
  assertEquals(nextEatMidnight(Date.parse("2026-10-23T22:30:00Z")), "2026-10-24T21:00:00.000Z");
  assertEquals(nextEatMidnight(Date.parse("2026-12-31T21:30:00Z")), "2027-01-01T21:00:00.000Z");
});

Deno.test("resets-at header: next EAT midnight with +03:00, billing off or a gate value that can't be used", () => {
  const now = Date.parse("2026-10-23T11:00:00Z");
  assertEquals(resetsAtHeader(undefined, now), "2026-10-24T00:00:00+03:00");
  assertEquals(resetsAtHeader("Sat 2026-10-24 12:00 AM EAT (UTC+03:00)", now), "2026-10-24T00:00:00+03:00");
  assertEquals(resetsAtHeader("2026-10-22T21:00:00+00:00", now), "2026-10-24T00:00:00+03:00", "a past reset is never shown");
  assertEquals(resetsAtHeader("2026-10-23T21:00:00+00:00", now), "2026-10-24T00:00:00+03:00", "usage_gate value kept, shown in EAT");
  assertEquals(Date.parse(resetsAtHeader(undefined, now)), Date.parse("2026-10-23T21:00:00Z"));
});
