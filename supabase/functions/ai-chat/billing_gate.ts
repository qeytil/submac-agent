// Contract B glue for ai-chat (Dev 1 owns the calls, Dev 2 owns the SQL in migration 20261023_billing_v2.sql).
// Pure helpers, no Supabase dependencies, so they are unit-tested (billing_gate_test.ts).
// deno-lint-ignore-file no-explicit-any

function num(v: unknown, d: number): number { const n = Number(v); return v !== null && v !== undefined && v !== "" && Number.isFinite(n) ? n : d; }

/** Bot-lane sources as billing.is_bot() knows them; any other background work is charged as 'background'. */
export const BOT_SOURCES = new Set(["bot", "bot-cloud", "bot_cloud", "background", "office"]);

/** CB-45: the owner typing in a bot's chat. Billed like the user's own chat ('agent': chat bucket, never refused for the
 *  bot share; billing.is_bot('bot-chat') = false), but kept as its own value in ai_usage.source for analytics. */
export const CHAT_LANE_SOURCES = new Set(["bot-chat"]);

/** True for a source that always bills in the user's chat lane, even when the request says x-telesia-lane: background. */
export function chatLane(source: unknown): boolean { return CHAT_LANE_SOURCES.has(String(source ?? "").toLowerCase()); }

/** The source usage_gate / usage_charge see: the bot lane gets its share of each daily amount (Contract B). */
export function billSource(source: string, background: boolean): string {
  const src = (source || "agent").toLowerCase();
  if (CHAT_LANE_SOURCES.has(src)) return src;
  return background && !BOT_SOURCES.has(src) ? "background" : src;
}

/** The billing functions are not in this database yet (Dev 2's migration not applied): PostgREST says it can't find them. */
export function missingFn(msg: unknown): boolean {
  return /could not find the function|PGRST202|function .* does not exist|usage_(gate|charge)[^ ]* 404/i.test(String(msg ?? ""));
}

/** usage_gate's answer in the shape ai-chat reads (allowance = what this lane may spend today, in raw tokens).
 *  null = billing does not apply to this user (enabled false); "error" = an answer that can't be trusted. */
export function entFromGate(data: any, s: Record<string, any> = {}): Record<string, any> | null | "error" {
  if (!data || typeof data !== "object") return "error";
  if (data.enabled === false) return null;
  if (typeof data.allow !== "boolean") return "error";
  const today = data.allow ? Math.max(0, num(data.today_left, 0)) : 0;
  const tpm = Math.max(1, num(s.billing_live_tokens_per_minute, 40000));
  const plan = ["free", "weekly", "monthly", "payg"].includes(String(data.plan)) ? String(data.plan) : "free";
  const code = data.allow ? null : (["limit_daily", "limit_total", "no_plan"].includes(String(data.code)) ? String(data.code) : "limit_daily");
  return {
    enabled: true, gate: true, allow: data.allow, code, reason: data.reason ?? code,
    allowance: today, bg_allowance: today, used_today: 0, ratio: today <= 0 ? 1 : 0, state: today <= 0 ? "limit" : "ok",
    paid: plan !== "free", plan, total_left: Math.max(0, num(data.total_left, today)), resets_at: typeof data.resets_at === "string" ? data.resets_at : null,
    reply_cap: Math.max(0, num(data.reply_cap, 0)), live_seconds_left: Math.floor((today * 60) / tpm),
    tokens_per_reply: num(s.billing_tokens_per_reply, 3700), free: null, pass: null, pass_left: 0, packs: [], pack_left: 0,
  };
}

// ---- Billing day = EAT (Africa/Mogadishu, UTC+3, no DST): Contract A `x-telesia-resets-at` is the next EAT midnight,
// with billing on or off, and the daily usage counter (ai_user_daily.day, written by ai_record_usage) is the EAT date.
export const EAT_MS = 3 * 3600_000;
/** The EAT calendar date (YYYY-MM-DD) at `now`: the key of today's ai_user_daily / live_call_daily row. */
export function eatDay(now = Date.now()): string { return new Date(now + EAT_MS).toISOString().slice(0, 10); }
/** Next 00:00 EAT after `now`, as UTC ISO (21:00Z of the current EAT date). */
export function nextEatMidnight(now = Date.now()): string {
  const eat = new Date(now + EAT_MS); eat.setUTCHours(24, 0, 0, 0);
  return new Date(eat.getTime() - EAT_MS).toISOString();
}
/** Contract A header value: an ISO instant in EAT with its offset, e.g. 2026-10-24T00:00:00+03:00. A usable reset from
 *  usage_gate is kept (shown in EAT); anything else is the next EAT midnight. */
export function resetsAtHeader(fromGate?: unknown, now = Date.now()): string {
  const t = typeof fromGate === "string" ? Date.parse(fromGate) : NaN;
  const ms = Number.isFinite(t) && t > now ? t : Date.parse(nextEatMidnight(now));
  return new Date(ms + EAT_MS).toISOString().slice(0, 19) + "+03:00";
}
