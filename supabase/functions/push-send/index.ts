// push-send (plan 2.1): sends a push to every phone of one user through FCM HTTP v1.
// Server to server only: the caller must present the service role key (future bot-run, cron, dashboard).
//
// POST { user_id: uuid, title: string, body: string, data?: { bot_id?, chat_id?, kind?, ...strings } }
// -> { ok, sent, failed, removed }
//
// Messages are data-only (title/body ride in `data`) so the app's PushReceiver draws them with its own calm
// notifications whether Telesia is open or closed. Tokens FCM reports as UNREGISTERED are deleted.
// Secret: FCM_SERVICE_ACCOUNT (the Firebase service account JSON). Never logged.
import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const db = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });

const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { "content-type": "application/json" } });

type ServiceAccount = { client_email: string; private_key: string; project_id: string; token_uri?: string };

let account: ServiceAccount | null = null;
function serviceAccount(): ServiceAccount {
  if (account) return account;
  const raw = Deno.env.get("FCM_SERVICE_ACCOUNT");
  if (!raw) throw new Error("FCM_SERVICE_ACCOUNT is not set");
  const a = JSON.parse(raw) as ServiceAccount;
  if (!a.client_email || !a.private_key || !a.project_id) throw new Error("FCM_SERVICE_ACCOUNT is incomplete");
  account = a;
  return a;
}

// ---------- auth: service role only ----------
function sameText(a: string, b: string): boolean {
  if (!a || !b || a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

// Keys already proven to be service role (by SHA-256), so the auth probe runs once per key per instance.
const proven = new Set<string>();

async function sha256(s: string): Promise<string> {
  const h = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)));
  return Array.from(h, (b) => b.toString(16).padStart(2, "0")).join("");
}

/**
 * Service role only. Fast path: the bearer equals this project's SUPABASE_SERVICE_ROLE_KEY.
 * Otherwise (a newer sb_secret_ key, or another valid service-role JWT) ask Auth's admin API with that key:
 * only a service-role/secret key may list users, so anon keys and user sessions get 401 here.
 */
async function isServiceRole(req: Request): Promise<boolean> {
  const bearer = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  if (!bearer || bearer.length < 20) return false;
  if (SERVICE_KEY && sameText(bearer, SERVICE_KEY)) return true;
  const h = await sha256(bearer);
  if (proven.has(h)) return true;
  if (!SUPABASE_URL) return false;
  try {
    const r = await fetch(`${SUPABASE_URL}/auth/v1/admin/users?page=1&per_page=1`, {
      headers: { apikey: bearer, authorization: `Bearer ${bearer}` },
    });
    await r.body?.cancel();
    if (r.status === 200) {
      if (proven.size > 50) proven.clear();
      proven.add(h);
      return true;
    }
  } catch { /* treat as not authorized */ }
  return false;
}

// ---------- Google OAuth: signed JWT -> access token ----------
const b64url = (bytes: Uint8Array) =>
  btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const b64urlText = (s: string) => b64url(new TextEncoder().encode(s));

function pemToDer(pem: string): ArrayBuffer {
  const body = pem.replace(/-----BEGIN [^-]+-----/, "").replace(/-----END [^-]+-----/, "").replace(/\s+/g, "");
  const bin = atob(body);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out.buffer;
}

let cached: { token: string; exp: number } | null = null;

async function accessToken(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cached && cached.exp - 120 > now) return cached.token;
  const sa = serviceAccount();
  const tokenUri = sa.token_uri || "https://oauth2.googleapis.com/token";
  const header = b64urlText(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claims = b64urlText(JSON.stringify({
    iss: sa.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: tokenUri,
    iat: now,
    exp: now + 3600,
  }));
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToDer(sa.private_key),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = new Uint8Array(await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(`${header}.${claims}`)));
  const assertion = `${header}.${claims}.${b64url(sig)}`;
  const r = await fetch(tokenUri, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion }),
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok || !j.access_token) throw new Error(`Google token error ${r.status}: ${j.error ?? ""}`);
  cached = { token: j.access_token as string, exp: now + Number(j.expires_in ?? 3600) };
  return cached.token;
}

// ---------- FCM HTTP v1 ----------
type SendResult = { ok: boolean; unregistered: boolean; status: number; error?: string };

function isUnregistered(status: number, err: any): boolean {
  const details: any[] = err?.error?.details ?? [];
  if (details.some((d) => d?.errorCode === "UNREGISTERED")) return true;
  return status === 404 && err?.error?.status === "NOT_FOUND";
}

async function sendOne(token: string, data: Record<string, string>): Promise<SendResult> {
  const sa = serviceAccount();
  const doSend = async () =>
    fetch(`https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`, {
      method: "POST",
      headers: { authorization: `Bearer ${await accessToken()}`, "content-type": "application/json" },
      body: JSON.stringify({ message: { token, data, android: { priority: "HIGH", ttl: "86400s" } } }),
    });
  let r = await doSend();
  if (r.status === 401) {
    cached = null; // token expired early: sign a fresh one once
    r = await doSend();
  }
  if (r.ok) return { ok: true, unregistered: false, status: r.status };
  const err = await r.json().catch(() => ({}));
  return { ok: false, unregistered: isUnregistered(r.status, err), status: r.status, error: err?.error?.status ?? `${r.status}` };
}

// ---------- handler ----------
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (req) => {
  if (!(await isServiceRole(req))) return json({ error: "unauthorized" }, 401);
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  let body: any;
  try {
    body = await req.json();
  } catch {
    return json({ error: "bad json" }, 400);
  }
  const userId = `${body?.user_id ?? ""}`;
  const title = `${body?.title ?? ""}`.slice(0, 200);
  const text = `${body?.body ?? ""}`.slice(0, 1000);
  if (!UUID.test(userId)) return json({ error: "user_id must be a uuid" }, 400);
  if (!title && !text) return json({ error: "title or body required" }, 400);

  // FCM data values must be strings; keep it small (FCM limit is 4 KB).
  const data: Record<string, string> = {};
  if (body?.data && typeof body.data === "object") {
    for (const [k, v] of Object.entries(body.data as Record<string, unknown>)) {
      if (v === null || v === undefined) continue;
      if (k.startsWith("google.") || k.startsWith("gcm.") || k === "from" || k === "message_type" || k === "collapse_key") continue;
      data[k] = typeof v === "string" ? v : JSON.stringify(v);
    }
  }
  data.title = title;
  data.body = text;
  if (!data.message_id) data.message_id = crypto.randomUUID();
  if (new TextEncoder().encode(JSON.stringify(data)).length > 3800) return json({ error: "payload too large" }, 413);

  const { data: rows, error } = await db.from("push_tokens").select("token").eq("user_id", userId);
  if (error) return json({ error: "token lookup failed" }, 500);
  const tokens = (rows ?? []).map((r: any) => r.token as string).filter(Boolean);
  if (!tokens.length) return json({ ok: true, sent: 0, failed: 0, removed: 0, note: "no tokens for user" });

  try {
    serviceAccount();
  } catch (e) {
    return json({ error: `${(e as Error).message}` }, 500);
  }

  let sent = 0, failed = 0;
  const dead: string[] = [];
  const errors: string[] = [];
  const results = await Promise.allSettled(tokens.map((t) => sendOne(t, data)));
  results.forEach((r, i) => {
    if (r.status === "fulfilled" && r.value.ok) {
      sent++;
      return;
    }
    failed++;
    if (r.status === "fulfilled") {
      if (r.value.unregistered) dead.push(tokens[i]);
      if (r.value.error) errors.push(r.value.error);
    } else {
      errors.push(`${(r.reason as Error)?.message ?? r.reason}`.slice(0, 120));
    }
  });
  let removed = 0;
  if (dead.length) {
    const { error: delErr } = await db.from("push_tokens").delete().in("token", dead);
    if (!delErr) removed = dead.length;
  }
  return json({ ok: sent > 0, sent, failed, removed, errors: [...new Set(errors)].slice(0, 5) });
});
