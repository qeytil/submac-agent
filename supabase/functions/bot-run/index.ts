// bot-run (Plan 2.1 part B): the cloud brain. Runs bots' cloud jobs (routines, follow-ups, heartbeats) while the
// owner's phone is off. Called every 5 minutes by pg_cron + pg_net (migration 20261019_bot_run.sql).
//
// Auth: the gateway checks a JWT (verify_jwt on; the cron sends the public anon key), and this function refuses any
// call without the runner's Vault secret in `x-bot-run-secret` (checked in the database by bot_run_check).
//
// POST {} (cron)                    -> runs due bots when ai_settings.bot_cloud_runner is true
// POST {only_user: uuid, limit?}    -> runs only that user's due bots, even while the switch is off (tests)
//
// Per bot: claim + 5 min lock (bot_run_claim) -> due jobs from `schedule` (phone-local routine times via
// tz_offset_min, UTC follow-ups, heartbeat) minus run_state.done -> allowance and token budget checks -> heartbeat:
// a tiny check first (model "submac", small max_tokens); routines and follow-ups go straight to work -> work through ai-chat (internal call,
// the user's allowance, source 'bot-cloud'), cloud-safe tools only, at most 6 steps -> journal / memory / desk rows
// with origin 'cloud' -> run_state.done, last_run_at, next_run_at, lock cleared -> push (push-send) for messages.
// Never writes messages, setup, schedule or device_id.
import { createClient } from "npm:@supabase/supabase-js@2";
import { createHash } from "node:crypto";

const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const db = createClient(SB_URL, SERVICE, { auth: { persistSession: false } });

const MAX_BOTS = 10;          // per invocation
const CONCURRENCY = 3;        // bots worked at the same time
const MAX_JOBS_PER_BOT = 3;   // per invocation; the rest wait for the next round
const MAX_STEPS = 8;          // model steps per job (web reading takes a few)
const JOB_TOKEN_CAP = 60_000; // prompt + reply tokens per job
// Reply room per model step (was 1200, which cut long bot replies short; owner 2026-11-06). ai-chat clamps it to the
// route's own maximum and the reply cap. A reply that still stops for length is continued up to MAX_CONTINUES times.
const STEP_MAX_TOKENS = 16_384;
const MAX_CONTINUES = 2;
const CONTINUE = "Your previous reply was cut off because it reached the output length limit. Continue exactly where it stopped: do not repeat anything, just go on from the last word.";
// Timing (PLAN.md 1.3): per model call 40 s (ai-chat ends non-streamed calls at 38 s for this runner), per job 120 s,
// no new jobs after 60 s of a round, and nothing past 140 s of the round (edge wall clock is 150 s).
const DEADLINE_MS = 60_000;   // stop starting new jobs (and bots) after this
const MODEL_TIMEOUT_MS = 40_000;
const JOB_MS = 120_000;
const ROUND_WALL_MS = 140_000;
const MODEL = "submac";       // the one public model; ai-chat's router picks the route
const GRACE_MS = 3 * 3600_000;        // a routine time missed by more than this is skipped, not run late
const FOLLOWUP_STALE_MS = 3 * 86400_000;
const DAY_MS = 86400_000;

const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { "content-type": "application/json" } });
const iso = (ms: number) => new Date(ms).toISOString();
const cut = (s: string, n: number) => (s.length > n ? s.slice(0, n) : s);
const str = (v: unknown) => (v === null || v === undefined ? "" : String(v));
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const md5 = (s: string) => createHash("md5").update(s).digest("hex");
const rid = (p: string) => p + crypto.randomUUID().replace(/-/g, "").slice(0, 22);
/** The allowance day: EAT date (Africa/Mogadishu, UTC+3), the key of ai_user_daily since 20261023_eat_day.sql. */
const eatDay = (ms = Date.now()) => iso(ms + 3 * 3600_000).slice(0, 10);

// ---------------------------------------------------------------- auth
const okSecrets = new Map<string, number>();
async function secretOk(sec: string): Promise<boolean> {
  if (!sec || sec.length < 32) return false;
  if ((okSecrets.get(sec) ?? 0) > Date.now()) return true;
  const { data } = await db.rpc("bot_run_check", { p_secret: sec });
  if (data !== true) return false;
  if (okSecrets.size > 4) okSecrets.clear();
  okSecrets.set(sec, Date.now() + 300_000);
  return true;
}

// ---------------------------------------------------------------- secrets never leave as text
const SECRET_RES = [
  /\b(?:sk|pk|rk)-[A-Za-z0-9_-]{16,}/g, /AIza[0-9A-Za-z_-]{30,}/g, /\beyJ[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/g,
  /\b(?:ghp|gho|ghs|github_pat|xox[abprs])[_-][A-Za-z0-9_-]{16,}/g, /\bsb_(?:secret|publishable)_[A-Za-z0-9_-]{10,}/g,
  /\b(password|passwd|pwd|api[ _-]?key|access[ _-]?token|secret|token)\s*[:=]\s*\S+/gi,
];
function scrub(s: string): string {
  let t = s;
  for (const re of SECRET_RES) t = t.replace(re, (m, g1) => (typeof g1 === "string" && /[:=]/.test(m) ? `${g1}: [hidden]` : "[hidden]"));
  return t;
}

// ---------------------------------------------------------------- time (routine times are phone-local)
const DAY_NAMES = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"];
/** Monday = 1 ... Sunday = 7, like Dart. */
const weekday = (d: Date) => (d.getUTCDay() === 0 ? 7 : d.getUTCDay());
function onDay(days: string, wd: number): boolean {
  switch ((days || "daily").toLowerCase()) {
    case "daily": return true;
    case "weekdays": return wd <= 5;
    case "weekends": return wd >= 6;
  }
  const want = new Set(days.toLowerCase().split(/[ ,]+/).filter(Boolean).map((e) => e.slice(0, 3)));
  return want.has(DAY_NAMES[wd - 1]);
}
function hm(time: string): [number, number] {
  const p = str(time).split(":");
  const h = Number.parseInt(p[0] ?? "", 10), m = Number.parseInt(p[1] ?? "", 10);
  return [Number.isFinite(h) ? Math.min(23, Math.max(0, h)) : 9, Number.isFinite(m) ? Math.min(59, Math.max(0, m)) : 0];
}
/** UTC ms of the routine's local time on the local day `i` days from now's local day. */
function occOn(nowMs: number, off: number, i: number, h: number, m: number): { ms: number; wd: number } {
  const local = new Date(nowMs + off * 60_000);
  const mid = Date.UTC(local.getUTCFullYear(), local.getUTCMonth(), local.getUTCDate() + i);
  return { ms: mid + (h * 60 + m) * 60_000 - off * 60_000, wd: weekday(new Date(mid)) };
}
function lastOccurrence(job: any, nowMs: number, off: number): number | null {
  const [h, m] = hm(job.time);
  for (let i = 0; i > -9; i--) {
    const o = occOn(nowMs, off, i, h, m);
    if (o.ms <= nowMs && onDay(str(job.days), o.wd)) return o.ms;
  }
  return null;
}
function nextOccurrence(job: any, afterMs: number, off: number): number | null {
  const [h, m] = hm(job.time);
  for (let i = 0; i < 9; i++) {
    const o = occOn(afterMs, off, i, h, m);
    if (o.ms > afterMs && onDay(str(job.days), o.wd)) return o.ms;
  }
  return null;
}
function localHour(ms: number, off: number) { return new Date(ms + off * 60_000).getUTCHours(); }
function quietAt(ms: number, off: number, qf: number, qt: number): boolean {
  if (qf === qt) return false;
  const h = localHour(ms, off);
  return qf > qt ? (h >= qf || h < qt) : (h >= qf && h < qt);
}
/** Moves a time out of quiet hours to a few minutes after they end (like the phone). */
function outOfQuiet(ms: number, off: number, qf: number, qt: number, botId: string): number {
  if (!quietAt(ms, off, qf, qt)) return ms;
  const local = new Date(ms + off * 60_000);
  const jitter = 5 + (parseInt(md5(botId).slice(0, 4), 16) % 20);
  let d = Date.UTC(local.getUTCFullYear(), local.getUTCMonth(), local.getUTCDate(), qt, jitter) - off * 60_000;
  if (d <= ms) d += DAY_MS;
  return d;
}

// ---------------------------------------------------------------- settings and allowance
type Settings = { runner: boolean; cap: number; kill: boolean; share: number };
async function settings(): Promise<Settings> {
  const { data } = await db.from("ai_settings").select("key,value").in("key", ["bot_cloud_runner", "daily_cap_tokens", "kill_switch", "background_share"]);
  const m = new Map((data ?? []).map((r: any) => [r.key, r.value]));
  let share = Number(m.get("background_share") ?? 0.3);
  if (!Number.isFinite(share)) share = 0.3;
  return { runner: m.get("bot_cloud_runner") === true, cap: Number(m.get("daily_cap_tokens") ?? 200000), kill: m.get("kill_switch") === true,
    share: Math.max(0, Math.min(1, share)) };
}
/** Plan 2.2 background lane: bots pause once their share of the day (background_share of the cap, bg_tokens) or the
 *  user's whole allowance is used, so the user's own chats keep the rest. ai-chat enforces the same (background_paused). */
let SHARE = 0.3;
async function allowanceLeft(uid: string, cap: number): Promise<boolean> {
  const { data } = await db.from("ai_user_daily").select("tokens,bg_tokens").eq("user_id", uid).eq("day", eatDay()).maybeSingle();
  return Number(data?.tokens ?? 0) < cap && Number(data?.bg_tokens ?? 0) < Math.floor(cap * SHARE);
}
const PAUSE_NOTE = "Paused until tomorrow to save your daily allowance.";

// ---------------------------------------------------------------- model (through ai-chat, the user's allowance)
type ModelOut = { ok: boolean; status: number; code?: string; msg?: any; tokens: number; finish?: string };
async function callModel(ctx: Ctx, body: Record<string, unknown>, until = Number.MAX_SAFE_INTEGER): Promise<ModelOut> {
  const ms = Math.min(MODEL_TIMEOUT_MS, until - Date.now());
  if (ms < 5_000) return { ok: false, status: 0, code: "job_time", tokens: 0 };
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort("timeout"), ms);
  try {
    const r = await fetch(`${SB_URL}/functions/v1/ai-chat`, {
      method: "POST", signal: ctl.signal,
      headers: {
        "content-type": "application/json", authorization: `Bearer ${SERVICE}`, apikey: SERVICE,
        "x-submac-internal": ctx.secret, "x-submac-user": ctx.uid, "x-submac-chat": cut("bot:" + ctx.botId, 64),
      },
      body: JSON.stringify({ ...body, stream: false }),
    });
    const j: any = await r.json().catch(() => ({}));
    if (!r.ok) return { ok: false, status: r.status, code: str(j?.error?.code) || `http_${r.status}`, tokens: 0 };
    const u = j.usage ?? {};
    const tokens = Number(u.total_tokens ?? 0) || (Number(u.prompt_tokens ?? 0) + Number(u.completion_tokens ?? 0));
    return { ok: true, status: 200, msg: j.choices?.[0]?.message ?? {}, tokens, finish: str(j.choices?.[0]?.finish_reason) || undefined };
  } catch (e) {
    return { ok: false, status: 0, code: "network:" + cut(String(e), 60), tokens: 0 };
  } finally { clearTimeout(timer); }
}

// ---------------------------------------------------------------- per-bot context
type Ctx = {
  uid: string; botId: string; secret: string; name: string; setup: any; knowledge: any[]; off: number;
  memory: { id: string; t: string }[]; desk: Map<string, any>; journal: { at: string; kind: string; text: string }[];
  wrote: { memory: number; desk: number; journal: number }; handed: boolean;
  /** The job being worked, and what hand_to_phone left for the phone to do (owner 2026-11-02: bots must finish work). */
  job?: { id: string; do: string; kind: string }; handoff?: { needs: string; why: string };
  /** Deadline of the job being worked (ms): min(job start + 120 s, round start + 140 s). */
  until: number;
};

async function loadContext(ctx: Ctx) {
  const [mem, desk, jr] = await Promise.all([
    db.from("cloud_bot_memory").select("item_id,data,created_at").eq("user_id", ctx.uid).eq("bot_id", ctx.botId).eq("deleted", false)
      .order("created_at", { ascending: true }).limit(1000),
    db.from("cloud_bot_desk").select("item_id,data").eq("user_id", ctx.uid).eq("bot_id", ctx.botId).eq("deleted", false).limit(1000),
    db.from("cloud_bot_journal").select("at,kind,text").eq("user_id", ctx.uid).eq("bot_id", ctx.botId).order("at", { ascending: false }).limit(8),
  ]);
  ctx.memory = (mem.data ?? []).map((r: any) => ({ id: r.item_id, t: str(r.data?.t).trim() })).filter((m) => m.t);
  ctx.desk = new Map((desk.data ?? []).map((r: any) => [r.item_id, r.data ?? {}]));
  ctx.journal = (jr.data ?? []).reverse().map((r: any) => ({ at: r.at, kind: r.kind, text: str(r.text) }));
}

const openTasks = (ctx: Ctx) => [...ctx.desk.values()].filter((t) => str(t.s || "todo") !== "done" && str(t.t).trim());

function lessonsOf(setup: any): string[] {
  const l = Array.isArray(setup?.les) ? setup.les : [];
  return l.map((x: any) => ({ t: str(x?.t).trim(), u: Number(x?.u ?? 0) })).filter((x: any) => x.t)
    .sort((a: any, b: any) => b.u - a.u).slice(0, 12).map((x: any) => cut(x.t, 300));
}

/** Stable part first (only what the owner set up, so it stays the same from run to run and the provider's prompt cache
 *  keeps it): who it is, how it works, the cloud limits and the outcome tags. Mirrors stablePromptOf in bots.dart. */
function stablePrompt(ctx: Ctx): string {
  const s = ctx.setup ?? {};
  const name = str(s.name || ctx.name || "Bot"), role = str(s.role);
  const trusted = str(s.tr) === "trusted";
  const out: string[] = [];
  out.push("# Who you are",
    `You are ${name}, the user's ${role || "colleague"}. You work for them inside SubMac like a trusted employee: ` +
    "you own your job, take initiative, remember what matters and keep every promise.");
  if (str(s.persona).trim()) out.push(cut(str(s.persona).trim(), 4000));
  out.push(`Stay in character: you are ${name}, never "an AI" or SubMac. Write like a person texting a colleague: short, warm, specific; headings only in a report.`);
  if (str(s.mission).trim()) out.push("", "Your job for this user: " + cut(str(s.mission).trim(), 1500));
  if (str(s.ins).trim()) out.push("", "# Your instructions (from the owner, always follow them)", cut(str(s.ins).trim(), 8000));
  out.push("", "# How you work",
    "- Multi-step work: put the real steps on bot_desk, work through them, keep each status current. Small things need no list.",
    "- Learn a preference, goal, deadline or fact about their work: bot_remember at once (never keys, passwords or codes).",
    "- Check your work before you deliver: exactly what was asked, facts and numbers right. Never invent facts; say what you could not check.",
    `- Your trust level is ${trusted ? "Trusted: routine changes run; money, sending, posting and deleting still get the owner's approval card" : "New: every action that changes something gets the owner's approval card first"}. ` +
    "The card (Approve · Edit · Not now) appears on their phone by itself, so never ask twice in text.",
    "- Never say something is done, sent or running unless a tool result shows it.",
    "- What the user reads: the outcome first, then only the details that matter (short list if needed). Plain words in the owner's language " +
    "(Somali, Arabic, English...); never mention tools, steps or systems; no filler, no emoji.",
    "", "# Working in the cloud (now)",
    "The owner's phone may be off. Here you have web_search and fetch_url (the web: search, read pages and APIs), bot_remember, " +
    "bot_desk, knowledge_search / knowledge_read and hand_to_phone. No browser, apps, phone, files, calls or texts, and no new routines or follow-ups.",
    "- Do the job now, fully, with these tools: research, check the site, read the sources, then report the result itself.",
    "- Never send a message that only says you are starting, have queued something, or will report later. Message with the result, or stay @silent.",
    "- Only if the job truly needs the phone, an app, a browser or an approval: call hand_to_phone once with what and why, and end with @silent; " +
    "the phone does the job itself and tells the user the result.",
    "", "# How you finish",
    "Write what the user should see (if anything), then ONE tag alone on the very last line:",
    "@silent = nothing worth telling",
    "@note = worth keeping in your chat with the user, not worth a notification",
    "@message = worth reaching them now: ONE short, specific message (under 300 characters) with the result itself",
    "You cannot call from the cloud: if a call is needed, end with @message and say you would like to talk.");
  return out.join("\n").trim();
}

/** What it learned and works with (changes now and then), then memory, desk, recent journal and this wake. */
function freshPrompt(ctx: Ctx, wake: string): string {
  const s = ctx.setup ?? {};
  const out: string[] = [];
  const kn = Array.isArray(ctx.knowledge) ? ctx.knowledge.filter((k: any) => str(k?.text).trim()) : [];
  if (kn.length || s.sb === true) {
    out.push("# Your knowledge");
    if (kn.length) {
      out.push(`You carry ${kn.length} piece(s) of knowledge. Search them with knowledge_search and read them with knowledge_read before you answer anything they may cover.`);
      for (const k of kn.slice(0, 25)) out.push(`- [${str(k.id)}] ${cut(str(k.title || "Note"), 120)}`);
    } else out.push("You have no knowledge added yet.");
    if (s.sb === true) out.push("Knowledge sandbox is ON: answer only from your knowledge; if it is not there, say so plainly.");
    out.push("");
  }
  const apps = Array.isArray(s.apps) ? s.apps.map((a: any) => str(a?.name || a?.ref)).filter(Boolean) : [];
  if (apps.length) out.push("# Your apps", apps.slice(0, 20).join(", ") + ". Their sign-ins live on the owner's phone, so not in this run.", "");
  const les = lessonsOf(s);
  if (les.length) out.push("# Lessons you learned (follow them)", ...les.map((l) => "- " + l), "");
  out.push("# What you know about the user and the work");
  const mem = ctx.memory.slice(-60);
  if (mem.length) for (const m of mem) out.push("- " + cut(m.t, 500)); else out.push("Nothing yet.");
  const tasks = openTasks(ctx);
  out.push("", "# Your desk (open tasks)");
  if (tasks.length) for (const t of tasks.slice(0, 30)) out.push(`- [${str(t.id)}] (${str(t.s || "todo")}) ${cut(str(t.t), 300)}${str(t.n).trim() ? " — " + cut(str(t.n), 200) : ""}`);
  else out.push("Empty.");
  if (ctx.journal.length) {
    out.push("", "# Your recent journal");
    for (const j of ctx.journal) out.push(`- ${localStamp(Date.parse(j.at), ctx.off)} ${j.kind}: ${cut(j.text, 240)}`);
  }
  out.push("", wake);
  return out.join("\n");
}

function localStamp(ms: number, off: number): string {
  if (!Number.isFinite(ms)) return "";
  return iso(ms + off * 60_000).slice(0, 16).replace("T", " ");
}

// ---------------------------------------------------------------- tools (cloud-safe only)
const TOOLS = [
  { type: "function", function: { name: "bot_remember", description: "Save one short fact you learned about the user or the work (one line).",
    parameters: { type: "object", properties: { text: { type: "string" } }, required: ["text"] } } },
  { type: "function", function: { name: "bot_desk", description: "Your task board. action add (text), update (id, status todo|doing|waiting, note) or done (id, note).",
    parameters: { type: "object", properties: { action: { type: "string", enum: ["add", "update", "done"] }, id: { type: "string" },
      text: { type: "string" }, status: { type: "string", enum: ["todo", "doing", "waiting", "done"] }, note: { type: "string" } }, required: ["action"] } } },
  { type: "function", function: { name: "knowledge_search", description: "Search your own knowledge pieces.",
    parameters: { type: "object", properties: { query: { type: "string" } }, required: ["query"] } } },
  { type: "function", function: { name: "knowledge_read", description: "Read one knowledge piece by id (from offset).",
    parameters: { type: "object", properties: { id: { type: "string" }, offset: { type: "integer" } }, required: ["id"] } } },
  { type: "function", function: { name: "web_search", description: "Search the web. Returns titles, links and snippets; then read the best with fetch_url.",
    parameters: { type: "object", properties: { query: { type: "string" } }, required: ["query"] } } },
  { type: "function", function: { name: "fetch_url", description: "Read a web page or API URL as plain text (offset reads further).",
    parameters: { type: "object", properties: { url: { type: "string" }, offset: { type: "integer" } }, required: ["url"] } } },
  { type: "function", function: { name: "hand_to_phone", description: "This job needs an app, a browser, the phone or an approval, which the cloud does not have. Say what and why; the phone then does the whole job and reports.",
    parameters: { type: "object", properties: { needs: { type: "string", description: "app: <name> | browser | phone: <what> | approval" }, why: { type: "string" } }, required: ["needs"] } } },
];

// ---------------------------------------------------------------- the web (owner 2026-11-02: a bot's background work
// needs the web; without it every real job was "handed to the phone" and never done)
const UA = "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Mobile Safari/537.36";
const decodeHtml = (s: string) => s.replace(/&amp;/g, "&").replace(/&quot;/g, '"').replace(/&#x27;|&#39;/g, "'").replace(/&lt;/g, "<")
  .replace(/&gt;/g, ">").replace(/&nbsp;/g, " ").replace(/&#(\d+);/g, (m, n) => { const c = Number(n); return c > 0 && c < 0x110000 ? String.fromCodePoint(c) : m; });
const stripTags = (h: string) => decodeHtml(h.replace(/<[^>]+>/g, "")).replace(/\s+/g, " ").trim();

async function getText(url: string, ms = 15_000, init: RequestInit = {}): Promise<{ status: number; text: string; type: string }> {
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), ms);
  try {
    const r = await fetch(url, { ...init, signal: ctl.signal, redirect: "follow", headers: { "user-agent": UA, "accept-language": "en,*;q=0.5", ...(init.headers ?? {}) } });
    const reader = r.body?.getReader();
    let text = "", size = 0;
    const dec = new TextDecoder();
    while (reader) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.length;
      text += dec.decode(value, { stream: true });
      if (size > 3_000_000) { try { await reader.cancel(); } catch { /* */ } break; }
    }
    return { status: r.status, text, type: r.headers.get("content-type") ?? "" };
  } finally { clearTimeout(timer); }
}

export function parseBing(s: string, n: number): { title: string; url: string; snippet: string }[] {
  const out: { title: string; url: string; snippet: string }[] = [];
  for (const blk of s.split('<li class="b_algo"').slice(1)) {
    if (out.length >= n) break;
    const m = /<a[^>]*href="([^"]+)"[^>]*>(?:(?!<\/a>)[\s\S])*?<h2[^>]*>([\s\S]*?)<\/h2>/.exec(blk) ?? /<h2[^>]*>\s*<a[^>]*href="([^"]+)"[^>]*>([\s\S]*?)<\/a>/.exec(blk);
    if (!m) continue;
    let url = decodeHtml(m[1]);
    const ck = /[?&]u=a1([^&]+)/.exec(url);
    if (url.includes("/ck/a?") && ck) { try { url = atob(ck[1].replace(/-/g, "+").replace(/_/g, "/")); } catch { /* keep */ } }
    if (!url.startsWith("http") || url.includes("bing.com/")) continue;
    const sn = /<p[^>]*>([\s\S]*?)<\/p>/.exec(blk);
    out.push({ title: stripTags(m[2]), url, snippet: sn ? stripTags(sn[1]) : "" });
  }
  return out;
}

export function parseDdg(s: string, n: number): { title: string; url: string; snippet: string }[] {
  const out: { title: string; url: string; snippet: string }[] = [];
  const links = [...s.matchAll(/<a[^>]*class=["']result__a["'][^>]*href=["']([^"']+)["'][^>]*>([\s\S]*?)<\/a>/g)];
  const snips = [...s.matchAll(/class=["']result__snippet["'][^>]*>([\s\S]*?)<\/(?:a|div|td)>/g)];
  for (let i = 0; i < links.length && out.length < n; i++) {
    let href = decodeHtml(links[i][1]);
    const u = /uddg=([^&]+)/.exec(href);
    if (u) href = decodeURIComponent(u[1]);
    if (href.startsWith("//")) href = "https:" + href;
    if (href.includes("duckduckgo.com/y.js")) continue;
    out.push({ title: stripTags(links[i][2]), url: href, snippet: snips[i] ? stripTags(snips[i][1]) : "" });
  }
  return out;
}

async function webSearch(q: string): Promise<string> {
  const query = q.trim();
  if (!query) return "Error: empty query";
  const brave = Deno.env.get("BRAVE_SEARCH_KEY") ?? "";
  const tries: [string, () => Promise<{ title: string; url: string; snippet: string }[]>][] = [];
  if (brave) tries.push(["Brave", async () => {
    const r = await getText(`https://api.search.brave.com/res/v1/web/search?q=${encodeURIComponent(query)}&count=8`, 12_000, { headers: { "X-Subscription-Token": brave, accept: "application/json" } });
    const j = JSON.parse(r.text);
    return (j?.web?.results ?? []).map((x: any) => ({ title: str(x.title), url: str(x.url), snippet: stripTags(str(x.description)) }));
  }]);
  tries.push(["Bing", async () => parseBing((await getText(`https://www.bing.com/search?q=${encodeURIComponent(query)}&setlang=en&count=10`, 12_000)).text, 8)]);
  tries.push(["DuckDuckGo", async () => parseDdg((await getText("https://html.duckduckgo.com/html/", 12_000, { method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" }, body: `q=${encodeURIComponent(query)}&kl=wt-wt` })).text, 8)]);
  for (const [, f] of tries) {
    try {
      const r = await f();
      if (r.length) return r.slice(0, 8).map((x, i) => `${i + 1}. ${cut(x.title, 140)}\n${x.url}\n${cut(x.snippet, 300)}`).join("\n\n");
    } catch { /* next engine */ }
  }
  return "Error: web search found nothing just now. Read a site you know with fetch_url instead.";
}

export function htmlToText(html: string): string {
  const title = /<title[^>]*>([\s\S]*?)<\/title>/i.exec(html);
  const body = html.replace(/<(script|style|noscript|svg|head)[\s\S]*?<\/\1>/gi, " ")
    .replace(/<(br|\/p|\/div|\/li|\/h[1-6]|\/tr)[^>]*>/gi, "\n").replace(/<[^>]+>/g, " ");
  const text = decodeHtml(body).split("\n").map((l) => l.replace(/[ \t]+/g, " ").trim()).filter(Boolean).join("\n");
  return (title ? "Title: " + stripTags(title[1]) + "\n" : "") + text;
}

async function fetchUrl(url: string, offset: number): Promise<string> {
  let u: URL;
  try { u = new URL(url); } catch { return "Error: not a valid URL."; }
  if (u.protocol !== "https:" && u.protocol !== "http:") return "Error: only http(s) links.";
  // Never the project's own internals or private networks from the server.
  if (/^(localhost|127\.|10\.|192\.168\.|169\.254\.|172\.(1[6-9]|2\d|3[01])\.|\[?::1)/.test(u.hostname) || u.hostname.endsWith(".supabase.co") || u.hostname.endsWith(".internal")) {
    return "Error: that address cannot be read from here.";
  }
  const r = await getText(u.toString(), 15_000);
  const text = /html/i.test(r.type) || /^\s*</.test(r.text) ? htmlToText(r.text) : r.text;
  const off = Math.max(0, offset | 0);
  const part = text.slice(off, off + 7000);
  return `HTTP ${r.status}${off ? ` (from ${off} of ${text.length})` : ""}\n${part}${off + part.length < text.length ? `\n…[${text.length - off - part.length} more characters: offset ${off + part.length}]` : ""}`;
}

async function journal(ctx: Ctx, kind: string, text: string, chat = ""): Promise<string> {
  const id = rid("cl");
  const { error } = await db.from("cloud_bot_journal").insert({
    user_id: ctx.uid, bot_id: ctx.botId, item_id: id, at: iso(Date.now()), kind,
    text: cut(scrub(text).trim(), 2000), chat: cut(scrub(chat).trim(), 20000), device_id: "", origin: "cloud",
  });
  if (error) throw new Error("journal: " + error.message);
  ctx.wrote.journal++;
  ctx.journal.push({ at: iso(Date.now()), kind, text: cut(text, 240) });
  return id;
}

async function runTool(ctx: Ctx, name: string, args: any): Promise<string> {
  try {
    if (name === "bot_remember") {
      const t = str(args?.text).replace(/\s+/g, " ").trim();
      if (!t) return "Nothing to save.";
      if (scrub(t) !== t) return "Not saved: it looks like it holds a key, password or code.";
      const line = cut(t, 500);
      const key = md5(line.trim().toLowerCase()).slice(0, 24); // same key the phone uses (BotSync.memKey)
      if (ctx.memory.some((m) => m.id === key)) return "Already known.";
      if (ctx.memory.length >= 990) return "Memory is full.";
      const { error } = await db.from("cloud_bot_memory").upsert({ user_id: ctx.uid, bot_id: ctx.botId, item_id: key, data: { t: line },
        deleted: false, device_id: "", origin: "cloud" }, { onConflict: "user_id,bot_id,item_id" });
      if (error) return "Could not save: " + error.message;
      ctx.memory.push({ id: key, t: line });
      ctx.wrote.memory++;
      return "Saved.";
    }
    if (name === "bot_desk") {
      const action = str(args?.action);
      let task: any;
      if (action === "add") {
        const text = cut(scrub(str(args?.text).trim()), 500);
        if (!text) return "A task needs text.";
        if (openTasks(ctx).some((x) => str(x.t).toLowerCase() === text.toLowerCase())) return "That task is already on the desk.";
        if (ctx.desk.size >= 990) return "Desk is full.";
        const id = "c" + Date.now().toString(36) + Math.floor(Math.random() * 1e4).toString(36);
        task = { id, t: text, s: "todo", n: cut(scrub(str(args?.note)), 500), u: iso(Date.now()) };
      } else {
        const id = str(args?.id);
        const cur = ctx.desk.get(id);
        if (!cur) return `No task with id ${id}. Open tasks: ${openTasks(ctx).map((x) => x.id).join(", ") || "none"}.`;
        const status = action === "done" ? "done" : (["todo", "doing", "waiting", "done"].includes(str(args?.status)) ? str(args.status) : str(cur.s || "todo"));
        task = { ...cur, id, s: status, n: args?.note !== undefined ? cut(scrub(str(args.note)), 500) : str(cur.n), u: iso(Date.now()) };
        if (args?.text) task.t = cut(scrub(str(args.text)), 500);
      }
      const { error } = await db.from("cloud_bot_desk").upsert({ user_id: ctx.uid, bot_id: ctx.botId, item_id: task.id, data: task,
        deleted: false, device_id: "", origin: "cloud" }, { onConflict: "user_id,bot_id,item_id" });
      if (error) return "Could not save: " + error.message;
      ctx.desk.set(task.id, task);
      ctx.wrote.desk++;
      return `Desk updated: [${task.id}] ${task.s}.`;
    }
    if (name === "knowledge_search") {
      const q = str(args?.query).toLowerCase().split(/\W+/).filter((w) => w.length > 2);
      const hits = (ctx.knowledge ?? []).map((k: any) => {
        const text = str(k?.text), low = (str(k?.title) + " " + text).toLowerCase();
        const score = q.reduce((n, w) => n + (low.split(w).length - 1), 0);
        const at = q.length ? Math.max(0, low.indexOf(q.find((w) => low.includes(w)) ?? "") - 150) : 0;
        return { id: str(k?.id), title: str(k?.title), score, snip: text.slice(at, at + 400) };
      }).filter((h: any) => h.score > 0).sort((a: any, b: any) => b.score - a.score).slice(0, 5);
      return hits.length ? hits.map((h: any) => `[${h.id}] ${h.title}: …${h.snip}…`).join("\n\n") : "Nothing found in your knowledge.";
    }
    if (name === "knowledge_read") {
      const k = (ctx.knowledge ?? []).find((x: any) => str(x?.id) === str(args?.id));
      if (!k) return "No knowledge piece with that id.";
      const off = Math.max(0, Number(args?.offset ?? 0) || 0);
      const text = str(k.text);
      const part = text.slice(off, off + 6000);
      return `${str(k.title)} (${off}-${off + part.length} of ${text.length}):\n${part}`;
    }
    if (name === "web_search") return await webSearch(str(args?.query));
    if (name === "fetch_url") return await fetchUrl(str(args?.url), Number(args?.offset ?? 0) || 0);
    if (name === "hand_to_phone") {
      if (ctx.handed) return "Already handed to the phone.";
      ctx.handed = true;
      const needs = cut(str(args?.needs).trim() || "the phone", 120), why = cut(str(args?.why).trim(), 400);
      ctx.handoff = { needs, why };
      await journal(ctx, "note", `Handed to the phone: needs ${needs}${why ? ". " + why : ""}`);
      return "Handed over. The phone will do this whole job and tell the user the result. End now with @silent.";
    }
    return "Unknown tool.";
  } catch (e) {
    return "Tool failed: " + cut(String(e), 120);
  }
}

// ---------------------------------------------------------------- jobs
type Due = { job: any; type: string; mark: number };
type JobResult = { id: string; type: string; outcome: string; tokens: number; steps: number; pushed?: number; push_note?: string; error?: string };

function parseOutcome(reply: string): { kind: string; text: string } {
  const lines = reply.trim().split("\n");
  const last = (lines[lines.length - 1] ?? "").trim();
  const m = /^@(silent|note|message|call)\b:?\s*(.*)$/i.exec(last);
  const body = (m ? lines.slice(0, -1) : lines).join("\n").trim();
  if (!m) {
    const t = reply.trim();
    if (!t || t === "SILENT" || t === "NO_CHANGE") return { kind: "silent", text: "" };
    return { kind: "note", text: t };
  }
  const kind = m[1].toLowerCase();
  return { kind: kind === "call" ? "message" : kind, text: body || (m[2] ?? "").trim() };
}

/** Heartbeat: a tiny check first (same model, small max_tokens). Most wakes end here. */
async function worthIt(ctx: Ctx): Promise<{ yes: boolean; what: string; tokens: number; ok: boolean; code?: string }> {
  const s = ctx.setup ?? {};
  const tasks = openTasks(ctx).slice(0, 12).map((t) => `- (${str(t.s || "todo")}) ${cut(str(t.t), 160)}`).join("\n") || "none";
  const recent = ctx.journal.slice(-5).map((j) => `- ${localStamp(Date.parse(j.at), ctx.off)} ${j.kind}: ${cut(j.text, 140)}`).join("\n") || "none";
  const mem = ctx.memory.slice(-8).map((m) => "- " + cut(m.t, 160)).join("\n") || "none";
  const prompt = `You decide if ${str(s.name || ctx.name)} (${str(s.role) || "assistant"}) should do background work right now, without the web or the phone.\n` +
    `Mission: ${cut(str(s.mission) || "(none)", 300)}\nInstructions: ${cut(str(s.ins) || "(none)", 400)}\nOpen desk tasks:\n${tasks}\n` +
    `Recent journal:\n${recent}\nSome memory:\n${mem}\nNow (user's local time): ${localStamp(Date.now(), ctx.off)}\n\n` +
    "Is there something genuinely useful to do now (progress on an open task, a promise, a deadline)? Never busywork. " +
    "Reply exactly NO, or YES: <the one thing to do, in one line>.";
  const r = await callModel(ctx, { model: MODEL, messages: [{ role: "user", content: prompt }], max_tokens: 60, temperature: 0 }, ctx.until);
  if (!r.ok) return { yes: false, what: "", tokens: 0, ok: false, code: r.code };
  const t = str(r.msg?.content).trim();
  const m = /^\W*yes\b\W*(.*)$/is.exec(t);
  return { yes: !!m, what: m ? cut(m[1].trim(), 300) : "", tokens: r.tokens, ok: true };
}

async function work(ctx: Ctx, instruction: string, reason: string, kind: string, budgetLeft: number): Promise<{ ok: boolean; code?: string; reply: string; tokens: number; steps: number }> {
  const s = ctx.setup ?? {};
  const now = Date.now();
  const quiet = quietAt(now, ctx.off, Number(s.qf ?? 22), Number(s.qt ?? 7));
  const what = instruction.trim() ? "Do this now: " + cut(instruction.trim(), 2000) :
    "This is your regular check-in. If there is something genuinely useful to do, do it; if not, end at once with @silent.";
  const style = kind === "message" ? "This routine always ends with @message (one short, specific message)." : "";
  const wake = `# Now\n[Woken in the cloud: ${reason}. ${localStamp(now, ctx.off)} (user's local time)]\n${what}\n\n` +
    "You are working in the background: the user is not watching. Work fully on your own, no questions unless essential. " +
    (quiet ? "It is the user's quiet hours: do not use @message; @note or @silent only. " : "") + style;
  const messages: any[] = [{ role: "system", content: stablePrompt(ctx) }, { role: "user", content: freshPrompt(ctx, wake) }];
  let tokens = 0;
  for (let step = 1; step <= MAX_STEPS; step++) {
    const last = step === MAX_STEPS || tokens >= Math.min(JOB_TOKEN_CAP, budgetLeft);
    if (last && step > 1) messages.push({ role: "user", content: "Step limit reached: finish now with what you have, ending with one tag line." });
    const r = await callModel(ctx, { model: MODEL, messages, max_tokens: STEP_MAX_TOKENS, tools: TOOLS, tool_choice: last ? "none" : "auto" }, ctx.until);
    // Out of job time after real work: end with what we have instead of failing the whole job.
    if (!r.ok && r.code === "job_time" && step > 1) return { ok: true, reply: "", tokens, steps: step };
    if (!r.ok) return { ok: false, code: r.code, reply: "", tokens, steps: step };
    tokens += r.tokens;
    const msg = r.msg ?? {};
    const calls = Array.isArray(msg.tool_calls) ? msg.tool_calls : [];
    if (!calls.length || last) {
      // Cut for length: continue the reply instead of ending on half a sentence (owner 2026-11-06).
      let reply = str(msg.content);
      let fin = r.finish;
      for (let i = 0; i < MAX_CONTINUES && (fin === "length" || fin === "max_tokens") && reply; i++) {
        const more = await callModel(ctx, { model: MODEL, messages: [...messages, { role: "assistant", content: reply }, { role: "user", content: CONTINUE }],
          max_tokens: STEP_MAX_TOKENS, tool_choice: "none", tools: TOOLS }, ctx.until);
        if (!more.ok) break;
        tokens += more.tokens;
        reply += str(more.msg?.content);
        fin = more.finish;
      }
      return { ok: true, reply, tokens, steps: step };
    }
    messages.push({ role: "assistant", content: msg.content ?? null, tool_calls: calls });
    for (const c of calls.slice(0, 6)) {
      let args: any = {};
      try { args = JSON.parse(str(c?.function?.arguments) || "{}"); } catch { /* bad args */ }
      const out = await runTool(ctx, str(c?.function?.name), args);
      messages.push({ role: "tool", tool_call_id: str(c?.id), content: cut(out, 8000) });
    }
  }
  return { ok: true, reply: "", tokens, steps: MAX_STEPS };
}

async function push(ctx: Ctx, title: string, body: string, messageId: string): Promise<{ sent: number; note: string }> {
  try {
    const conv = str(ctx.setup?.conv);
    const r = await fetch(`${SB_URL}/functions/v1/push-send`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${SERVICE}`, apikey: SERVICE },
      body: JSON.stringify({ user_id: ctx.uid, title: cut(title, 200), body: cut(body, 1000),
        data: { bot_id: ctx.botId, ...(conv ? { chat_id: conv } : {}), kind: "info", message_id: messageId } }),
    });
    const j: any = await r.json().catch(() => ({}));
    return { sent: Number(j?.sent ?? 0), note: r.ok ? str(j?.note || (j?.failed ? `failed ${j.failed}` : "")) : `push-send ${r.status}` };
  } catch (e) { return { sent: 0, note: cut(String(e), 80) }; }
}

/** Due jobs now, and the state changes for jobs that are skipped (too late, stale). */
function dueJobs(row: any, state: any, nowMs: number): Due[] {
  const off = Number(row.tz_offset_min ?? 0);
  const setup = row.setup ?? {};
  const qf = Number(setup.qf ?? 22), qt = Number(setup.qt ?? 7);
  const done = (state.done ??= {});
  const seen = (state.seen ??= {});
  const out: Due[] = [];
  for (const job of Array.isArray(row.schedule) ? row.schedule : []) {
    const id = str(job?.id);
    if (!id) continue;
    if (job.type === "routine") {
      const sig = `${id}|${str(job.time)}|${str(job.days)}`;
      if (!seen[sig]) {
        // First sight: owed from the phone's own "next" (the next time it would have rung), never earlier.
        const nx = Date.parse(str(job.next));
        seen[sig] = iso(Math.min(nowMs, Number.isFinite(nx) ? nx : nowMs) - 1000);
      }
      const occ = lastOccurrence(job, nowMs, off);
      if (occ === null || occ < Date.parse(seen[sig])) continue;
      const d = Date.parse(str(done[id]));
      if (Number.isFinite(d) && d >= occ) continue;
      if (nowMs - occ > GRACE_MS) { done[id] = iso(occ); continue; } // too late to be useful: skip it
      out.push({ job, type: "routine", mark: occ });
    } else if (job.type === "followup") {
      if (done[id]) continue;
      const at = Date.parse(str(job.at));
      if (!Number.isFinite(at) || at > nowMs) continue;
      if (nowMs - at > FOLLOWUP_STALE_MS) { done[id] = iso(nowMs); continue; }
      out.push({ job, type: "followup", mark: nowMs });
    } else if (job.type === "heartbeat") {
      const at = heartbeatAt(job, state, nowMs, off, qf, qt, row.bot_id);
      if (at !== null && at <= nowMs && !quietAt(nowMs, off, qf, qt)) out.push({ job, type: "heartbeat", mark: nowMs });
    }
  }
  const order: Record<string, number> = { followup: 0, routine: 1, heartbeat: 2 };
  return out.sort((a, b) => order[a.type] - order[b.type]);
}

function heartbeatAt(job: any, state: any, nowMs: number, off: number, qf: number, qt: number, botId: string): number | null {
  const every = Number(job.every_hours ?? 0);
  if (!(every > 0)) return null;
  const d = Date.parse(str(state.done?.hb));
  const nx = Date.parse(str(job.next));
  let at = Number.isFinite(d) ? d + every * 3600_000 : (Number.isFinite(nx) ? nx : nowMs);
  if (Number.isFinite(d) && Number.isFinite(nx) && nx > at) at = nx; // the phone moved it later (e.g. it woke itself)
  return outOfQuiet(at, off, qf, qt, botId);
}

function nextRunAt(row: any, state: any, nowMs: number, leftover: boolean): string | null {
  const off = Number(row.tz_offset_min ?? 0);
  const setup = row.setup ?? {};
  const qf = Number(setup.qf ?? 22), qt = Number(setup.qt ?? 7);
  let best: number | null = leftover ? nowMs + 60_000 : null;
  const take = (ms: number | null) => { if (ms !== null && Number.isFinite(ms) && (best === null || ms < best)) best = ms; };
  for (const job of Array.isArray(row.schedule) ? row.schedule : []) {
    const id = str(job?.id);
    if (job.type === "routine") take(nextOccurrence(job, nowMs, off));
    else if (job.type === "followup") { if (!state.done?.[id]) take(Math.max(Date.parse(str(job.at)), nowMs + 60_000)); }
    else if (job.type === "heartbeat") { const at = heartbeatAt(job, state, nowMs, off, qf, qt, row.bot_id); if (at !== null) take(Math.max(at, nowMs + 60_000)); }
  }
  return best === null ? null : iso(best);
}

async function runBot(row: any, secret: string, cap: number, t0: number): Promise<any> {
  const nowMs = Date.now();
  const state: any = (row.run_state && typeof row.run_state === "object") ? structuredClone(row.run_state) : {};
  const ctx: Ctx = { uid: row.user_id, botId: row.bot_id, secret, name: str(row.name), setup: row.setup ?? {}, knowledge: Array.isArray(row.knowledge) ? row.knowledge : [],
    off: Number(row.tz_offset_min ?? 0), memory: [], desk: new Map(), journal: [], wrote: { memory: 0, desk: 0, journal: 0 }, handed: false,
    until: t0 + ROUND_WALL_MS };
  const results: JobResult[] = [];
  let leftover = false, worked = false;
  try {
    const due = ctx.setup.active === false ? [] : dueJobs(row, state, nowMs);
    if (due.length) {
      await loadContext(ctx);
      const tok = (state.tok && state.tok.day === eatDay()) ? state.tok : { day: eatDay(), n: 0 };
      state.tok = tok;
      const budgetK = Number(ctx.setup.tb ?? 0);
      for (const [i, d] of due.entries()) {
        const id = str(d.job.id);
        if (i >= MAX_JOBS_PER_BOT || Date.now() - t0 > DEADLINE_MS) { leftover = true; break; }
        worked = true;
        ctx.until = Math.min(Date.now() + JOB_MS, t0 + ROUND_WALL_MS);
        // Allowance and the bot's own budget: pause politely (one note a day), the job is skipped like on the phone.
        const budgetLeft = budgetK > 0 ? budgetK * 1000 - tok.n : Number.MAX_SAFE_INTEGER;
        if (budgetLeft <= 0 || !(await allowanceLeft(ctx.uid, cap))) {
          const why = budgetLeft <= 0 ? "budget" : "allowance";
          if (state.paused?.day !== eatDay()) {
            await journal(ctx, "note", why === "budget" ? "Skipped work in the cloud: today's token budget is used up." : PAUSE_NOTE);
            state.paused = { day: eatDay(), why };
          }
          state.done[id] = iso(d.mark);
          results.push({ id, type: d.type, outcome: "paused", tokens: 0, steps: 0 });
          continue;
        }
        let instruction = str(d.job.do), reason = "", tokens = 0, steps = 0;
        if (d.type === "heartbeat") {
          const chk = await worthIt(ctx);
          tokens += chk.tokens; steps++;
          if (!chk.ok) { results.push(...(await failed(ctx, state, d, chk.code ?? "error", tokens))); tok.n += tokens; continue; }
          if (!chk.yes) {
            state.done.hb = iso(d.mark); tok.n += tokens;
            results.push({ id, type: d.type, outcome: "idle", tokens, steps });
            continue;
          }
          instruction = chk.what; reason = "your regular check-in (you decided this is worth doing now)";
        } else reason = d.type === "routine" ? `routine (${str(d.job.time)} ${str(d.job.days)})` : "a follow-up you set";
        const kind = str(d.job.kind || "work");
        ctx.handed = false; ctx.handoff = undefined; ctx.job = { id, do: instruction, kind };
        const w = await work(ctx, instruction, reason, kind, budgetLeft - tokens);
        tokens += w.tokens; steps += w.steps; tok.n += tokens;
        if (!w.ok) { results.push(...(await failed(ctx, state, d, w.code ?? "error", tokens))); continue; }
        state.done[id] = iso(d.mark);
        delete state.retry?.[id];
        const quiet = quietAt(Date.now(), ctx.off, Number(ctx.setup.qf ?? 22), Number(ctx.setup.qt ?? 7));
        let out = parseOutcome(w.reply);
        // Handed to the phone: the phone runs the job and messages the result, so the cloud never sends a "starting"
        // or "I will report back" message the user then has to chase (owner 2026-11-02).
        // A tool sets ctx.handoff inside the model loop; TypeScript cannot see that and narrows it to null here.
        const handoff = (ctx as Ctx).handoff;
        if (handoff) {
          state.handoff ??= {};
          state.handoff[id] = { do: cut(instruction, 2000), kind, needs: handoff.needs, why: handoff.why, at: iso(Date.now()) };
          results.push({ id, type: d.type, outcome: "handoff", tokens, steps });
          continue;
        }
        if (kind === "message" && out.kind === "silent" && out.text) out = { kind: "message", text: out.text };
        if (out.kind === "message" && quiet) out = { kind: "note", text: out.text };
        const label = d.type === "heartbeat" ? "Check-in" : d.type === "routine" ? `Routine ${str(d.job.time)}` : "Follow-up";
        const res: JobResult = { id, type: d.type, outcome: out.kind, tokens, steps };
        if (out.kind === "silent" || !out.text.trim()) {
          res.outcome = "silent";
          if (d.type !== "heartbeat") await journal(ctx, "work", `${label} done in the cloud: nothing worth your time.`);
        } else {
          const text = out.text.trim();
          const jid = await journal(ctx, out.kind === "message" ? "message" : "note", `${label} (cloud): ${cut(text.replace(/\s+/g, " "), 300)}`, text);
          if (out.kind === "message") ({ sent: res.pushed, note: res.push_note } = await push(ctx, str(ctx.setup.name || ctx.name || "SubMac"), cut(text.replace(/\s+/g, " "), 300), jid));
        }
        results.push(res);
      }
    }
  } catch (e) {
    results.push({ id: "-", type: "-", outcome: "error", tokens: 0, steps: 0, error: cut(String(e), 200) });
    leftover = true;
  } finally {
    // Done bookkeeping: prune follow-up marks the phone has had a week to see; keep the rest small.
    const ids = new Set((Array.isArray(row.schedule) ? row.schedule : []).map((j: any) => str(j?.id)));
    for (const [k, v] of Object.entries(state.done ?? {})) if (!ids.has(k) && Date.now() - Date.parse(str(v)) > 7 * DAY_MS) delete state.done[k];
    for (const [k, v] of Object.entries(state.handoff ?? {})) if (Date.now() - Date.parse(str((v as any)?.at)) > 2 * DAY_MS) delete state.handoff[k];
    const sigs = Object.keys(state.seen ?? {});
    for (const k of sigs) if (!ids.has(k.split("|")[0])) delete state.seen[k];
    if (results.some((r) => r.outcome === "retry")) leftover = true;
    if (results.length) state.last = { at: iso(Date.now()), jobs: results.map((r) => `${r.id}:${r.outcome}`).slice(0, 6), tokens: results.reduce((n, r) => n + r.tokens, 0) };
    const upd: Record<string, unknown> = { run_state: state, run_lock_until: null, next_run_at: ctx.setup.active === false ? null : nextRunAt(row, state, Date.now(), leftover) };
    if (worked) upd.last_run_at = iso(Date.now());
    const { error } = await db.from("cloud_bots").update(upd).eq("user_id", row.user_id).eq("bot_id", row.bot_id);
    if (error) results.push({ id: "-", type: "save", outcome: "error", tokens: 0, steps: 0, error: error.message });
  }
  return { bot_id: row.bot_id, jobs: results, wrote: ctx.wrote };
}

/** A job the model could not do: the allowance ran out (pause note), or the proxy was busy (one retry next round,
 *  then it is marked missed). */
async function failed(ctx: Ctx, state: any, d: Due, code: string, tokens: number): Promise<JobResult[]> {
  const id = str(d.job.id);
  if (code === "daily_limit" || code === "background_paused") {
    if (state.paused?.day !== eatDay()) { await journal(ctx, "note", PAUSE_NOTE); state.paused = { day: eatDay(), why: "allowance" }; }
    state.done[id] = iso(d.mark);
    return [{ id, type: d.type, outcome: "paused", tokens, steps: 0, error: code }];
  }
  state.retry ??= {};
  const n = Number(state.retry[id] ?? 0) + 1;
  if (n >= 2 || code === "blocked" || code === "auth") {
    delete state.retry[id];
    state.done[id] = iso(d.mark);
    if (d.type !== "heartbeat") await journal(ctx, "missed", `Couldn't do a ${d.type === "routine" ? "routine" : "follow-up"} in the cloud (the model was busy).`);
    return [{ id, type: d.type, outcome: "missed", tokens, steps: 0, error: code }];
  }
  state.retry[id] = n;
  return [{ id, type: d.type, outcome: "retry", tokens, steps: 0, error: code }];
}

// ---------------------------------------------------------------- handler
Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  const secret = req.headers.get("x-bot-run-secret") ?? "";
  if (!(await secretOk(secret))) return json({ error: "unauthorized" }, 401);
  const t0 = Date.now();
  let body: any = {};
  try { body = await req.json(); } catch { /* cron sends {} */ }
  const only = UUID.test(str(body?.only_user)) ? str(body.only_user) : null;
  const s = await settings();
  SHARE = s.share;
  if (s.kill) return json({ ok: true, skipped: "kill_switch" });
  if (!s.runner && !only) return json({ ok: true, skipped: "runner_off" });
  const limit = Math.max(1, Math.min(MAX_BOTS, Number(body?.limit ?? MAX_BOTS) || MAX_BOTS));
  const { data: rows, error } = await db.rpc("bot_run_claim", { p_limit: limit, p_user: only });
  if (error) return json({ error: "claim: " + error.message }, 500);
  const list = (rows ?? []) as any[];
  const results: any[] = [];
  let i = 0;
  const lane = async () => {
    while (i < list.length) {
      const row = list[i++];
      if (Date.now() - t0 > DEADLINE_MS) {
        await db.from("cloud_bots").update({ run_lock_until: null }).eq("user_id", row.user_id).eq("bot_id", row.bot_id);
        results.push({ bot_id: row.bot_id, jobs: [], deferred: true });
        continue;
      }
      results.push(await runBot(row, secret, s.cap, t0));
    }
  };
  await Promise.all(Array.from({ length: Math.min(CONCURRENCY, list.length) }, lane));
  return json({ ok: true, bots: list.length, ms: Date.now() - t0, results });
});
