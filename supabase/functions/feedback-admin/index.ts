// Feedback for the admin dashboard (2026-10-26). The dashboard signs in with email + password like it does for ai-admin;
// this function checks the caller's email against public.ai_admins (the same allowlist ai-admin uses) and then works
// with the service role. Screenshots stay in the private bucket `feedback-screenshots`; the dashboard only ever gets
// short-lived signed URLs. No dependencies: plain fetch to PostgREST, Auth and Storage.
//
// Actions (POST JSON {action, ...}):
//   me                                  -> { email }
//   counts                              -> { new, read, resolved, total }
//   list   { status?, limit?, before? } -> { items: [...feedback row + email, display_name, plan, last_device,
//                                            shots: [{ path, url }] ] }
//   update { id, status?, admin_note? } -> { id, status, admin_note, updated_at }   (admin_note: "" clears it)

const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const BUCKET = "feedback-screenshots";
const SIGN_SECONDS = 60 * 60;
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...CORS, "content-type": "application/json", "cache-control": "no-store" } });
const SH = { apikey: SERVICE, authorization: `Bearer ${SERVICE}`, "content-type": "application/json" };

async function rest(path: string, init: RequestInit = {}) {
  const r = await fetch(`${SB_URL}/rest/v1/${path}`, { ...init, headers: { ...SH, ...(init.headers ?? {}) } });
  const t = await r.text();
  let j: any = null;
  try { j = t ? JSON.parse(t) : null; } catch { j = t; }
  if (!r.ok) throw new Error((j && (j.message || j.error)) || `db ${r.status}`);
  return j;
}
const rpc = (fn: string, args: Record<string, unknown> = {}) => rest(`rpc/${fn}`, { method: "POST", body: JSON.stringify(args) });

/** The admin's email, or null. A project secret key also counts (server-side checks and smoke tests). */
async function adminOf(req: Request): Promise<string | null> {
  const token = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  if (!token) return null;
  if (token === SERVICE) return "service-role";
  const u = await fetch(`${SB_URL}/auth/v1/user`, { headers: { apikey: SERVICE, authorization: `Bearer ${token}` } });
  if (!u.ok) {
    // Not a user session: a project secret key (sb_secret_… or the service_role JWT) is accepted when Auth's admin API
    // accepts it, the same rule push-send uses.
    const k = await fetch(`${SB_URL}/auth/v1/admin/users?page=1&per_page=1`, { headers: { apikey: token, authorization: `Bearer ${token}` } });
    return k.ok ? "service-role" : null;
  }
  const email = String((await u.json())?.email ?? "").toLowerCase();
  if (!email) return null;
  const rows = await rest(`ai_admins?select=email&email=eq.${encodeURIComponent(email)}`);
  return Array.isArray(rows) && rows.length ? email : null;
}

async function sign(paths: string[]): Promise<Record<string, string>> {
  if (!paths.length) return {};
  const r = await fetch(`${SB_URL}/storage/v1/object/sign/${BUCKET}`, {
    method: "POST", headers: SH, body: JSON.stringify({ expiresIn: SIGN_SECONDS, paths }),
  });
  if (!r.ok) return {};
  const out: Record<string, string> = {};
  for (const s of (await r.json()) as any[]) {
    const u = s?.signedURL ?? s?.signedUrl;
    if (s?.path && u && !s.error) out[s.path] = u.startsWith("http") ? u : `${SB_URL}/storage/v1${u}`;
  }
  return out;
}

async function lastDevices(ids: string[]): Promise<Record<string, any>> {
  if (!ids.length) return {};
  const rows = await rest(`user_devices?select=user_id,platform,app_version,last_seen&user_id=in.(${ids.join(",")})&order=last_seen.desc`);
  const out: Record<string, any> = {};
  for (const d of rows ?? []) if (!out[d.user_id]) out[d.user_id] = d;
  return out;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Use POST" }, 405);
  try {
    const admin = await adminOf(req);
    if (!admin) return json({ error: "Not allowed" }, 403);
    const body = await req.json().catch(() => ({}));
    switch (body.action) {
      case "me":
        return json({ email: admin });
      case "counts":
        return json(await rpc("admin_feedback_counts"));
      case "list": {
        const status = ["new", "read", "resolved"].includes(body.status) ? body.status : null;
        const limit = Math.min(Math.max(Number(body.limit) || 100, 1), 500);
        const items = ((await rpc("admin_feedback_list", { p_status: status, p_limit: limit, p_before: body.before || null })) ?? []) as any[];
        const urls = await sign(items.flatMap((i) => i.screenshot_paths ?? []));
        const dev = await lastDevices([...new Set(items.map((i) => i.user_id).filter(Boolean))]);
        for (const i of items) {
          i.shots = (i.screenshot_paths ?? []).map((p: string) => ({ path: p, url: urls[p] ?? null }));
          i.last_device = dev[i.user_id] ?? null;
        }
        return json({ items, signed_for_seconds: SIGN_SECONDS });
      }
      case "update": {
        if (!body.id) return json({ error: "Missing id" }, 400);
        if (body.status != null && !["new", "read", "resolved"].includes(body.status)) return json({ error: "Bad status" }, 400);
        const setNote = Object.prototype.hasOwnProperty.call(body, "admin_note");
        if (setNote && String(body.admin_note ?? "").length > 4000) return json({ error: "Note is too long" }, 400);
        return json(await rpc("admin_feedback_update", {
          p_id: body.id, p_status: body.status ?? null, p_note: setNote ? String(body.admin_note ?? "") : null, p_set_note: setNote,
        }));
      }
    }
    return json({ error: "Unknown action" }, 400);
  } catch (e) {
    return json({ error: String((e as Error)?.message ?? e).slice(0, 300) }, 500);
  }
});
