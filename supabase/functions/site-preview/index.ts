// site-preview: free 7-day preview links for sites SubMac builds, on Cloudflare Pages.
// Every site is one branch of the Pages project `submac-sites`, served at https://<slug>.submac-sites.pages.dev
// (branch previews carry noindex, which suits try-before-you-connect links).
//
// Auth: the gateway checks the JWT (verify_jwt on). User actions need a signed-in user's session.
// The daily sweep needs the cron's shared secret (x-bot-run-secret, checked by bot_run_check).
//
// POST {action:"publish", site_key, title, files:[{path, data /* base64 */}]}
//   -> {ok, url, slug, expires_at}   (same site_key = same link; the expiry does not move on re-publish)
// POST {action:"remove", site_key}   -> {ok}
// POST {action:"list"}               -> {ok, sites:[{site_key, slug, url, title, expires_at, status}]}
// POST {action:"sweep"} + secret     -> removes expired deployments
//
// Secrets: CF_PAGES_TOKEN (Cloudflare API token, Pages: Edit), CF_ACCOUNT_ID. Never logged or returned.
import { createClient } from "npm:@supabase/supabase-js@2";
import { blake3 } from "npm:@noble/hashes@1.4.0/blake3";
import { bytesToHex } from "npm:@noble/hashes@1.4.0/utils";

const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const CF_TOKEN = Deno.env.get("CF_PAGES_TOKEN") ?? "";
const CF_ACCOUNT = Deno.env.get("CF_ACCOUNT_ID") ?? "";
const PROJECT = "submac-sites";
const CF = "https://api.cloudflare.com/client/v4";
const db = createClient(SB_URL, SERVICE, { auth: { persistSession: false } });

const MAX_FILES = 60;
const MAX_BYTES = 5 * 1024 * 1024;     // whole site
const MAX_LIVE = 3;                    // live free links per person
const MAX_PUBLISH_PER_DAY = 30;
const LIFETIME_MS = 7 * 86400_000;

const TYPES: Record<string, string> = {
  html: "text/html", htm: "text/html", css: "text/css", js: "application/javascript", mjs: "application/javascript",
  json: "application/json", txt: "text/plain", xml: "application/xml", svg: "image/svg+xml", png: "image/png",
  jpg: "image/jpeg", jpeg: "image/jpeg", gif: "image/gif", webp: "image/webp", avif: "image/avif", ico: "image/x-icon",
  woff: "font/woff", woff2: "font/woff2", ttf: "font/ttf", otf: "font/otf", mp4: "video/mp4", webm: "video/webm",
  mp3: "audio/mpeg", wav: "audio/wav", pdf: "application/pdf", webmanifest: "application/manifest+json",
};

const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { "content-type": "application/json" } });
const fail = (message: string, status = 400) => json({ ok: false, error: message }, status);

// ---------------------------------------------------------------- helpers
function cleanPath(p: string): string | null {
  let s = String(p ?? "").replace(/\\/g, "/").trim();
  s = s.replace(/^\.?\/+/, "");
  if (!s || s.length > 200) return null;
  const parts = s.split("/");
  if (parts.some((x) => !x || x === "." || x === ".." || x.startsWith("."))) return null;
  if (!/^[A-Za-z0-9._\-/ ]+$/.test(s)) return null;
  return "/" + s;
}
const extOf = (p: string) => (p.includes(".") ? p.split(".").pop()!.toLowerCase() : "");

function slugFrom(title: string): string {
  const base = String(title ?? "")
    .toLowerCase().normalize("NFKD").replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 18).replace(/-+$/g, "");
  const rnd = Array.from(crypto.getRandomValues(new Uint8Array(4)), (b) => "abcdefghijkmnpqrstuvwxyz23456789"[b % 32]).join("");
  return `${base || "site"}-${rnd}`;
}
const urlFor = (slug: string) => `https://${slug}.${PROJECT}.pages.dev`;

async function cf(path: string, init: RequestInit = {}, token = CF_TOKEN): Promise<any> {
  const r = await fetch(path.startsWith("http") ? path : CF + path, {
    ...init,
    headers: { authorization: `Bearer ${token}`, ...(init.headers ?? {}) },
  });
  const t = await r.text();
  let d: any = null;
  try { d = JSON.parse(t); } catch { /* not json */ }
  if (!r.ok || (d && d.success === false)) {
    const msg = d?.errors?.map((e: any) => e.message).join("; ") || t.slice(0, 200) || `HTTP ${r.status}`;
    throw new Error(`Cloudflare: ${msg}`);
  }
  return d;
}

async function deleteDeployment(id: string | null | undefined) {
  if (!id) return;
  try {
    await cf(`/accounts/${CF_ACCOUNT}/pages/projects/${PROJECT}/deployments/${id}?force=true`, { method: "DELETE" });
  } catch (_) { /* already gone */ }
}

/** Direct upload (the same steps wrangler uses): upload token -> missing hashes -> upload -> upsert -> deployment. */
async function deploy(branch: string, files: { path: string; bytes: Uint8Array }[]): Promise<string> {
  const jwt = (await cf(`/accounts/${CF_ACCOUNT}/pages/projects/${PROJECT}/upload-token`)).result.jwt as string;
  const manifest: Record<string, string> = {};
  const byHash = new Map<string, { b64: string; type: string }>();
  for (const f of files) {
    const b64 = b64encode(f.bytes);
    const ext = extOf(f.path);
    const hash = bytesToHex(blake3(new TextEncoder().encode(b64 + ext))).slice(0, 32);
    manifest[f.path] = hash;
    byHash.set(hash, { b64, type: TYPES[ext] ?? "application/octet-stream" });
  }
  const hashes = [...byHash.keys()];
  const missing = (await cf(`/pages/assets/check-missing`, {
    method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ hashes }),
  }, jwt)).result as string[];
  if (missing.length) {
    await cf(`/pages/assets/upload`, {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify(missing.map((h) => ({ key: h, value: byHash.get(h)!.b64, metadata: { contentType: byHash.get(h)!.type }, base64: true }))),
    }, jwt);
  }
  await cf(`/pages/assets/upsert-hashes`, {
    method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ hashes }),
  }, jwt);
  const form = new FormData();
  form.append("manifest", JSON.stringify(manifest));
  form.append("branch", branch);
  const d = await cf(`/accounts/${CF_ACCOUNT}/pages/projects/${PROJECT}/deployments`, { method: "POST", body: form });
  return d.result.id as string;
}

function b64encode(bytes: Uint8Array): string {
  let s = "";
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
}
function b64decode(s: string): Uint8Array {
  const bin = atob(String(s ?? "").replace(/^data:[^,]*,/, "").replace(/\s+/g, ""));
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

const okSecrets = new Map<string, number>();
async function secretOk(sec: string): Promise<boolean> {
  if (!sec || sec.length < 32) return false;
  if ((okSecrets.get(sec) ?? 0) > Date.now()) return true;
  const { data } = await db.rpc("bot_run_check", { p_secret: sec });
  if (data !== true) return false;
  okSecrets.set(sec, Date.now() + 300_000);
  return true;
}

// ---------------------------------------------------------------- actions
async function publish(user: string, body: any) {
  const siteKey = String(body.site_key ?? "").trim().slice(0, 80);
  const title = String(body.title ?? "").trim().slice(0, 80) || "My site";
  if (!siteKey) return fail("site_key is missing");
  const raw = Array.isArray(body.files) ? body.files : [];
  if (!raw.length) return fail("There are no files to publish.");
  if (raw.length > MAX_FILES) return fail(`A free link holds up to ${MAX_FILES} files.`, 413);

  const files: { path: string; bytes: Uint8Array }[] = [];
  let total = 0;
  for (const f of raw) {
    const path = cleanPath(f?.path);
    if (!path) return fail("A file name is not allowed.");
    let bytes: Uint8Array;
    try { bytes = b64decode(f?.data); } catch { return fail("A file could not be read."); }
    total += bytes.length;
    if (total > MAX_BYTES) return fail("This site is bigger than 5 MB, too big for a free link.", 413);
    files.push({ path, bytes });
  }
  if (!files.some((f) => f.path === "/index.html")) return fail("The site needs an index.html page.");
  // Abuse guard: free links on our domain never carry password forms (phishing). Real sign-in pages go on the
  // user's own hosting.
  const dec = new TextDecoder();
  for (const f of files) {
    if (!/\.(html?|js|mjs)$/i.test(f.path)) continue;
    const t = dec.decode(f.bytes).toLowerCase();
    if (/type\s*=\s*["']?password/.test(t) || /\.type\s*=\s*["']password/.test(t)) {
      return fail("Free links can't hold pages that ask for passwords. Publish it to your own Vercel instead.", 422);
    }
  }

  const now = Date.now();
  const since = new Date(now - 86400_000).toISOString();
  const { count: today } = await db.from("site_preview_log").select("id", { count: "exact", head: true })
    .eq("user_id", user).gte("at", since);
  if ((today ?? 0) >= MAX_PUBLISH_PER_DAY) return fail("That's a lot of publishing today. Try again tomorrow.", 429);

  const { data: rows } = await db.from("site_previews").select("*").eq("user_id", user).eq("status", "live");
  const live = (rows ?? []).filter((r: any) => Date.parse(r.expires_at) > now);
  let row: any = live.find((r: any) => r.site_key === siteKey) ?? null;
  if (!row && live.length >= MAX_LIVE) {
    return fail(`You have ${MAX_LIVE} free links already. Remove one, or put this site on your own Vercel.`, 409);
  }

  const slug = row?.slug ?? slugFrom(title);
  const deploymentId = await deploy(slug, files);
  const expiresAt = row?.expires_at ?? new Date(now + LIFETIME_MS).toISOString();
  const record = {
    user_id: user, site_key: siteKey, slug, title, deployment_id: deploymentId, url: urlFor(slug),
    files: files.length, bytes: total, published_at: new Date(now).toISOString(), expires_at: expiresAt, status: "live",
  };
  if (row) {
    await db.from("site_previews").update(record).eq("id", row.id);
    if (row.deployment_id && row.deployment_id !== deploymentId) await deleteDeployment(row.deployment_id);
  } else {
    // An expired link for the same site is replaced by the new one.
    await db.from("site_previews").update({ status: "replaced" }).eq("user_id", user).eq("site_key", siteKey).neq("status", "live");
    const { error } = await db.from("site_previews").insert(record);
    if (error) { await deleteDeployment(deploymentId); throw new Error(error.message); }
  }
  await db.from("site_preview_log").insert({ user_id: user, slug });
  return json({ ok: true, url: urlFor(slug), slug, expires_at: expiresAt });
}

async function remove(user: string, body: any) {
  const siteKey = String(body.site_key ?? "").trim();
  const { data: rows } = await db.from("site_previews").select("*").eq("user_id", user).eq("site_key", siteKey).eq("status", "live");
  for (const r of rows ?? []) {
    await deleteDeployment(r.deployment_id);
    await db.from("site_previews").update({ status: "removed" }).eq("id", r.id);
  }
  return json({ ok: true });
}

async function list(user: string) {
  const { data } = await db.from("site_previews").select("site_key, slug, url, title, expires_at, status, published_at")
    .eq("user_id", user).in("status", ["live", "expired"]).order("published_at", { ascending: false }).limit(50);
  const now = Date.now();
  return json({
    ok: true,
    sites: (data ?? []).map((r: any) => ({ ...r, status: r.status === "live" && Date.parse(r.expires_at) <= now ? "expired" : r.status })),
  });
}

async function sweep() {
  const { data } = await db.from("site_previews").select("id, deployment_id")
    .eq("status", "live").lte("expires_at", new Date().toISOString()).limit(200);
  for (const r of data ?? []) {
    await deleteDeployment(r.deployment_id);
    await db.from("site_previews").update({ status: "expired" }).eq("id", r.id);
  }
  await db.from("site_preview_log").delete().lt("at", new Date(Date.now() - 7 * 86400_000).toISOString());
  return json({ ok: true, expired: (data ?? []).length });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return fail("POST only", 405);
  if (!CF_TOKEN || !CF_ACCOUNT) return fail("Free links are not switched on yet.", 503);
  let body: any;
  try { body = await req.json(); } catch { return fail("Bad request"); }
  const action = String(body?.action ?? "");
  try {
    const runnerSecret = req.headers.get("x-bot-run-secret") ?? "";
    if (action === "sweep") {
      if (!(await secretOk(runnerSecret))) return fail("Not allowed", 401);
      return await sweep();
    }
    let user: string | undefined;
    if (runnerSecret && body?.as_user && (await secretOk(runnerSecret))) {
      user = String(body.as_user); // server-side tests only (needs the runner's Vault secret)
    } else {
      const token = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
      const { data: u } = await db.auth.getUser(token);
      user = u?.user?.id;
    }
    if (!user) return fail("Please sign in again.", 401);
    if (action === "publish") return await publish(user, body);
    if (action === "remove") return await remove(user, body);
    if (action === "list") return await list(user);
    return fail("Unknown action");
  } catch (e) {
    console.error("site-preview", action, String((e as Error)?.message ?? e).slice(0, 300));
    return fail("The free link service is busy. Please try again in a minute.", 502);
  }
});
