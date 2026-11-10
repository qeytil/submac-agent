// Telesia proxy admin API: used by the Cloudflare dashboard (admin login) and the hourly benchmark (cron secret).
import { createClient } from "npm:@supabase/supabase-js@2";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const CRON_SECRET = Deno.env.get("AI_CRON_SECRET") ?? "";
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info, x-cron-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...CORS, "content-type": "application/json" } });

async function isAdmin(req: Request): Promise<string | null> {
  const token = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!token) return null;
  const { data } = await db.auth.getUser(token);
  const email = data?.user?.email?.toLowerCase();
  if (!email) return null;
  const { data: a } = await db.from("ai_admins").select("email").eq("email", email).maybeSingle();
  return a ? email : null;
}

function must<T>(r: { data: T; error: any }): T {
  if (r.error) throw new Error(r.error.message);
  return r.data;
}

const BENCH_PROMPTS = [
  { name: "short", messages: [{ role: "user", content: "In one sentence, what is a good habit for staying focused?" }], max_tokens: 120 },
  { name: "long", messages: [{ role: "user", content: "Write a friendly 150-word note explaining how to plan a productive week." }], max_tokens: 400 },
];

async function callModel(base: string, key: string, model: string, extra: any, messages: any[], max_tokens: number, timeoutMs = 30000) {
  const t0 = Date.now();
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), timeoutMs);
  try {
    const res = await fetch(base.replace(/\/$/, "") + "/chat/completions", {
      method: "POST", signal: ctl.signal,
      headers: { "content-type": "application/json", authorization: `Bearer ${key}`, "user-agent": "telesia-proxy/1" },
      body: JSON.stringify({ ...(extra ?? {}), model, messages, max_tokens, stream: true, stream_options: { include_usage: true } }),
    });
    if (!res.ok) return { ok: false, status: res.status, error: (await res.text()).slice(0, 200), total_ms: Date.now() - t0 };
    const reader = res.body!.getReader(); const dec = new TextDecoder();
    let buf = "", ttft = 0, tFirst = 0, chars = 0, text = "", usage: any = null;
    while (true) {
      if (Date.now() - t0 > timeoutMs) { reader.cancel().catch(() => {}); return { ok: false, status: 0, error: "too slow (over " + timeoutMs / 1000 + "s)", total_ms: Date.now() - t0, ttft_ms: ttft || null }; }
      const { done, value } = await reader.read();
      if (done) break;
      buf += dec.decode(value, { stream: true });
      let nl: number;
      while ((nl = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, nl).trim(); buf = buf.slice(nl + 1);
        if (!line.startsWith("data:")) continue;
        const d = line.slice(5).trim(); if (d === "[DONE]") continue;
        try {
          const j = JSON.parse(d); if (j.usage) usage = j.usage;
          const dl = j.choices?.[0]?.delta; if (!dl) continue;
          const n = (dl.content?.length ?? 0) + (dl.reasoning_content?.length ?? 0) + (dl.reasoning?.length ?? 0);
          if (n && !ttft) { ttft = Date.now() - t0; tFirst = Date.now(); }
          chars += n; if (dl.content) text += dl.content;
        } catch { /* partial */ }
      }
    }
    const total = Date.now() - t0;
    const pt = usage?.prompt_tokens ?? 0;
    const ct = Math.max(usage?.completion_tokens ?? Math.ceil(chars / 4), (usage?.total_tokens ?? 0) - pt);
    const gen = (Date.now() - (tFirst || t0)) / 1000;
    const tps = ct / (gen < 0.25 ? Math.max(0.05, total / 1000) : gen);
    return { ok: text.length > 0 || chars > 0, status: 200, ttft_ms: ttft || total, total_ms: total, tps, prompt_tokens: pt, completion_tokens: ct, text: text.slice(0, 300) };
  } catch (e) {
    return { ok: false, status: 0, error: String(e).slice(0, 200), total_ms: Date.now() - t0 };
  } finally { clearTimeout(timer); }
}

async function bench() {
  const settings = Object.fromEntries((must(await db.from("ai_settings").select("key,value")) as any[]).map((r) => [r.key, r.value]));
  const base = settings.baseline ?? { ttft_p95_ms: 1500, tps_min: 40 };
  const models = must(await db.from("ai_models").select("id,model_id,enabled,ai_providers!inner(name,enabled)").eq("enabled", true)) as any[];
  const results: any[] = [];
  await Promise.all(models.filter((m) => m.ai_providers.enabled).map(async (m) => {
    const { data: mk } = await db.rpc("ai_model_with_keys", { p_model_ref: m.id });
    const keys = mk?.keys ?? [];
    if (!keys.length) return;
    const key = keys[Math.floor(Math.random() * keys.length)];
    let okCount = 0, ttfts: number[] = [];
    for (const p of BENCH_PROMPTS) {
      const r: any = await callModel(mk.base_url, key.key, mk.model, mk.extra_body, p.messages, p.max_tokens, 25000);
      await db.rpc("ai_record_usage", { p: { source: "bench", alias: p.name, provider: mk.provider, model: mk.model, key_id: key.id, status: r.ok ? 200 : (r.status || 0),
        prompt_tokens: r.prompt_tokens ?? 0, completion_tokens: r.completion_tokens ?? 0, ttft_ms: r.ttft_ms ?? null, total_ms: r.total_ms, tps: r.tps ?? null, error: r.error ?? null } });
      if (r.ok) { okCount++; ttfts.push(r.ttft_ms); }
      results.push({ provider: mk.provider, model: mk.model, prompt: p.name, ...r, text: undefined });
    }
    // Healthy = answered both prompts and first token within 3x the baseline target.
    const healthy = okCount === BENCH_PROMPTS.length && Math.max(...ttfts) <= Number(base.ttft_p95_ms ?? 1500) * 3;
    await db.from("ai_models").update({ healthy, last_check_at: new Date().toISOString() }).eq("id", m.id);
  }));
  return results;
}

/** A user id from body.user_id, or looked up by body.email. */
async function userIdOf(body: any): Promise<string | null> {
  if (body.user_id) return String(body.user_id);
  if (!body.email) return null;
  const want = String(body.email).toLowerCase();
  for (let page = 1; page <= 20; page++) {
    const { data } = await db.auth.admin.listUsers({ page, perPage: 1000 });
    const id = data?.users?.find((u) => u.email?.toLowerCase() === want)?.id;
    if (id) return id;
    if (!data?.users?.length || data.users.length < 1000) break;
  }
  return null;
}

// ---------- Users section: messages to users ("From Telesia") ----------
const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SB_SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

async function allUserIds(): Promise<string[]> {
  const out: string[] = [];
  for (let page = 1; page <= 50; page++) {
    const { data } = await db.auth.admin.listUsers({ page, perPage: 1000 });
    for (const u of data?.users ?? []) out.push(u.id);
    if (!data?.users?.length || data.users.length < 1000) break;
  }
  return out;
}

/** One push through push-send (service key). Returns sent | no_device | failed. */
async function pushOne(uid: string, title: string, body: string, inboxId: string): Promise<string> {
  try {
    const r = await fetch(SB_URL + "/functions/v1/push-send", { method: "POST",
      headers: { "content-type": "application/json", authorization: "Bearer " + SB_SERVICE, apikey: SB_SERVICE },
      body: JSON.stringify({ user_id: uid, title, body: body.slice(0, 300), data: { kind: "info", inbox_id: inboxId, open: "inbox" } }) });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) return "failed";
    if (Number(j.sent ?? 0) > 0) return "sent";
    return Number(j.failed ?? 0) > 0 ? "failed" : "no_device";
  } catch { return "failed"; }
}

async function sendMessage(admin: string, body: any) {
  const title = String(body.title ?? "").trim().slice(0, 200);
  const text = String(body.body ?? "").trim().slice(0, 4000);
  const delivery = ["push", "chat", "both"].includes(body.delivery) ? body.delivery : "both";
  if (!title) throw new Error("Write a title");
  let ids: string[] = [];
  let audience = "selected";
  if (body.audience === "all") { ids = await allUserIds(); audience = "all"; }
  else {
    ids = Array.isArray(body.user_ids) ? body.user_ids.map(String) : [];
    if (body.email) { const one = await userIdOf({ email: body.email }); if (one) ids.push(one); }
    ids = [...new Set(ids.filter((x) => /^[0-9a-f-]{36}$/i.test(x)))];
    audience = ids.length === 1 ? "one" : "selected";
  }
  if (!ids.length) throw new Error("Pick at least one user");
  const msg = must(await db.from("admin_messages").insert({ title, body: text, delivery, audience, recipients: ids.length, created_by: admin }).select().single()) as any;
  const push = delivery !== "chat";
  const rows = ids.map((u) => ({ user_id: u, kind: "admin_message", message_id: msg.id, title, body: text, in_chat: delivery !== "push", push }));
  const inserted: any[] = [];
  for (let i = 0; i < rows.length; i += 500) inserted.push(...(must(await db.from("user_inbox").insert(rows.slice(i, i + 500)).select("id,user_id")) as any[]));
  let sent = 0, failed = 0, none = 0;
  if (push) {
    for (let i = 0; i < inserted.length; i += 10) {
      const part = inserted.slice(i, i + 10);
      const res = await Promise.all(part.map((r) => pushOne(r.user_id, title, text, r.id)));
      for (let k = 0; k < part.length; k++) {
        const st = res[k];
        if (st === "sent") sent++; else if (st === "failed") failed++; else none++;
        await db.from("user_inbox").update({ push_status: st }).eq("id", part[k].id);
      }
    }
    await db.from("admin_messages").update({ push_sent: sent, push_failed: failed, push_no_device: none }).eq("id", msg.id);
  }
  return { ok: true, id: msg.id, recipients: ids.length, push_sent: sent, push_failed: failed, push_no_device: none };
}

async function grantReward(admin: string, body: any) {
  const uid = await userIdOf(body);
  if (!uid) throw new Error("User not found");
  const amount = Math.round(Number(body.amount_per_day));
  const days = Math.round(Number(body.days));
  if (!Number.isFinite(amount) || amount < 1000 || amount > 100000000) throw new Error("Amount per day must be 1,000 or more");
  if (!Number.isFinite(days) || days < 1 || days > 3650) throw new Error("Days must be 1 to 3650");
  const note = String(body.note ?? "").trim().slice(0, 300);
  const k = amount >= 1000000 ? (amount / 1000000).toFixed(1).replace(/\.0$/, "") + "M" : amount >= 1000 ? Math.floor(amount / 1000) + "k" : String(amount);
  const title = String(body.title ?? "").trim() || "A gift from Telesia";
  const text = `+${k} extra a day for ${days} day${days === 1 ? "" : "s"}, on top of your daily allowance.` + (body.show_note && note ? ` ${note}` : "");
  const id = must(await db.rpc("reward_grant", { p_uid: uid, p_kind: "admin_grant", p_amount: amount, p_days: days, p_referral: null,
    p_note: note || null, p_by: admin, p_title: title.slice(0, 200), p_body: text }));
  return { ok: true, id, user_id: uid };
}

async function liveList() {
  return must(await db.from("live_routes").select("id,provider,label,model,key_preview,priority,enabled,cooldown_until,fail_count,last_error,last_ok_at,last_fail_at,created_at")
    .order("priority").order("created_at")) as any[];
}

// ---------- Updates section: in-app updates (table app_releases, public bucket app-updates) ----------
// Supabase caps one stored file at 50 MB on this plan, so the dashboard uploads a build in parts (<= 40 MiB each)
// into one folder; the app downloads the parts and joins them, then checks the whole file's sha256.
const REL_BUCKET = "app-updates";
const REL_PART_MAX = 40 * 1024 * 1024;
const REL_FIELDS = "id,version_code,version_name,notes,apk_path,parts,size_bytes,sha256,required_at,published,published_at,created_by,created_at,updated_at,storage,file_url,file_key";
// New releases: ONE file in Cloudflare R2 (bucket telesia-app-updates), uploaded by the dashboard Worker
// (telesia-proxy-admin, /api/updates/*). The key is made by the Worker; its public base is ai_settings.app_updates_public_base.
const REL_R2_KEY = /^android\/([0-9]+)-[0-9a-f]{8}\/Telesia-([0-9]+)\.apk$/;
async function relR2Base(): Promise<string> {
  const { data } = await db.from("ai_settings").select("value").eq("key", "app_updates_public_base").maybeSingle();
  const base = typeof data?.value === "string" ? data.value.replace(/\/+$/, "") : "";
  if (!/^https:\/\/[A-Za-z0-9.-]+$/.test(base)) throw new Error("The update file address is not set up (app_updates_public_base).");
  return base;
}
const REL_FOLDER = /^android\/[A-Za-z0-9._+-]+$/;
const relPublicUrl = (path: string) => `${SB_URL}/storage/v1/object/public/${REL_BUCKET}/${path}`;

function relRequiredAt(v: unknown): string | null {
  if (v === null || v === undefined || v === "" || v === "never") return null;
  if (v === "now") return new Date().toISOString();
  const d = new Date(String(v));
  if (isNaN(d.getTime())) throw new Error("Pick a valid date and time for when the update becomes required.");
  return d.toISOString();
}

async function relRemoveFolder(folder: string) {
  if (!REL_FOLDER.test(folder)) return;
  const { data } = await db.storage.from(REL_BUCKET).list(folder, { limit: 100 });
  // The folder's parts, plus an object stored under the folder name itself (a stray single-file upload).
  const paths = [...(data ?? []).map((o) => `${folder}/${o.name}`), folder];
  await db.storage.from(REL_BUCKET).remove(paths);
}

async function releases(admin: string, action: string, body: any): Promise<Response> {
  switch (action) {
    case "releases_list": {
      const rows = must(await db.from("app_releases").select(REL_FIELDS).order("version_code", { ascending: false })) as any[];
      const devices = await db.rpc("admin_app_versions").then((r) => r.data ?? [], () => []);
      return json({ releases: rows, devices, now: new Date().toISOString(), base_url: relPublicUrl("") });
    }
    case "release_upload_url": {
      // One signed upload URL per part, all in a fresh folder. Uploading needs no key: the URL carries a short-lived token.
      const code = Number(body.version_code);
      if (!Number.isInteger(code) || code <= 0) throw new Error("Version number (build) is missing.");
      const n = Number(body.parts ?? 1);
      if (!Number.isInteger(n) || n < 1 || n > 20) throw new Error("The file is too big (at most 20 parts of 40 MB).");
      const folder = `android/${code}-${crypto.randomUUID().slice(0, 8)}`;
      const parts = [];
      for (let i = 0; i < n; i++) {
        const path = `${folder}/part-${String(i).padStart(2, "0")}.bin`;
        const { data, error } = await db.storage.from(REL_BUCKET).createSignedUploadUrl(path);
        if (error) throw new Error(error.message);
        parts.push({ path, signed_url: data.signedUrl });
      }
      return json({ folder, part_max: REL_PART_MAX, parts });
    }
    case "release_create": {
      const code = Number(body.version_code);
      if (!Number.isInteger(code) || code <= 0) throw new Error("Version number (build) is missing.");
      const name = String(body.version_name ?? "").trim();
      if (!name) throw new Error("Version name is missing.");
      const sha = String(body.sha256 ?? "").toLowerCase();
      if (!/^[0-9a-f]{64}$/.test(sha)) throw new Error("File check (sha256) is missing.");
      if (body.storage === "r2") {
        // One file already in R2 (the Worker streamed it there). Check it is really public, with the right size.
        const key = String(body.file_key ?? "");
        const m = REL_R2_KEY.exec(key);
        if (!m || Number(m[1]) !== code || Number(m[2]) !== code) throw new Error("Upload the file first.");
        const size = Number(body.size_bytes);
        if (!Number.isInteger(size) || size <= 0) throw new Error("The uploaded file size does not match. Upload it again.");
        const url = `${await relR2Base()}/${key}`;
        const head = await fetch(url, { method: "HEAD" });
        if (!head.ok) throw new Error("The uploaded file was not found. Upload it again.");
        if (Number(head.headers.get("content-length") ?? -1) !== size) throw new Error("The uploaded file size does not match. Upload it again.");
        const publishR2 = body.published === true;
        const row = must(await db.from("app_releases").insert({
          // apk_path = the file's folder and parts = the one file, so the table's existing checks hold; the phone uses file_url.
          version_code: code, version_name: name, notes: String(body.notes ?? "").slice(0, 4000), apk_path: key.slice(0, key.lastIndexOf("/")),
          parts: [{ path: key, size, url }], size_bytes: size,
          sha256: sha, required_at: relRequiredAt(body.required_at), published: publishR2, published_at: publishR2 ? new Date().toISOString() : null,
          created_by: admin, storage: "r2", file_url: url, file_key: key,
        }).select(REL_FIELDS).single());
        return json({ ok: true, release: row });
      }
      const folder = String(body.apk_path ?? "");
      if (!REL_FOLDER.test(folder)) throw new Error("Upload the file first.");
      const want = Array.isArray(body.parts) ? body.parts : [];
      if (!want.length || want.length > 20) throw new Error("Upload the file first.");
      // Every part must really be in the bucket, with the size the dashboard measured.
      const parts: { path: string; size: number }[] = [];
      for (const p of want) {
        const path = String(p?.path ?? "");
        if (!path.startsWith(folder + "/") || !/^[A-Za-z0-9._\/+-]+$/.test(path)) throw new Error("Bad part path.");
        const head = await fetch(relPublicUrl(path), { method: "HEAD" });
        if (!head.ok) throw new Error("Part of the uploaded file was not found. Upload it again.");
        const size = Number(head.headers.get("content-length") ?? 0);
        if (Number(p.size) !== size) throw new Error("The uploaded file size does not match. Upload it again.");
        parts.push({ path, size });
      }
      const total = parts.reduce((a, p) => a + p.size, 0);
      if (body.size_bytes && Number(body.size_bytes) !== total) throw new Error("The uploaded file size does not match. Upload it again.");
      const publish = body.published === true;
      const row = must(await db.from("app_releases").insert({
        version_code: code, version_name: name, notes: String(body.notes ?? "").slice(0, 4000), apk_path: folder, parts, size_bytes: total,
        sha256: sha, required_at: relRequiredAt(body.required_at), published: publish, published_at: publish ? new Date().toISOString() : null, created_by: admin,
      }).select(REL_FIELDS).single());
      return json({ ok: true, release: row });
    }
    case "release_edit": {
      const patch: Record<string, unknown> = { updated_at: new Date().toISOString() };
      if (body.notes !== undefined) patch.notes = String(body.notes).slice(0, 4000);
      if (body.version_name !== undefined) patch.version_name = String(body.version_name).trim();
      if (body.required_at !== undefined) patch.required_at = relRequiredAt(body.required_at);
      return json({ ok: true, release: must(await db.from("app_releases").update(patch).eq("id", body.id).select(REL_FIELDS).single()) });
    }
    case "release_publish":
      return json({ ok: true, release: must(await db.from("app_releases").update({ published: true, published_at: new Date().toISOString(), updated_at: new Date().toISOString() }).eq("id", body.id).select(REL_FIELDS).single()) });
    case "release_unpublish":
      return json({ ok: true, release: must(await db.from("app_releases").update({ published: false, updated_at: new Date().toISOString() }).eq("id", body.id).select(REL_FIELDS).single()) });
    case "release_delete": {
      // Supabase parts are removed here; an R2 file is removed by the dashboard Worker, which gets its key back.
      const row = must(await db.from("app_releases").select("apk_path,storage,file_key").eq("id", body.id).maybeSingle()) as any;
      must(await db.from("app_releases").delete().eq("id", body.id));
      if (row?.storage === "r2") return json({ ok: true, storage: "r2", file_key: row.file_key ?? null });
      if (row?.apk_path) await relRemoveFolder(row.apk_path);
      return json({ ok: true, storage: row ? "supabase" : null, file_key: null });
    }
    case "release_file_delete": {
      // An upload that never became a release (the owner gave up half way).
      const folder = String(body.apk_path ?? "");
      if (!REL_FOLDER.test(folder)) throw new Error("Bad folder.");
      const used = must(await db.from("app_releases").select("id").eq("apk_path", folder)) as any[];
      if (used.length) throw new Error("That file belongs to a release; delete the release instead.");
      await relRemoveFolder(folder);
      return json({ ok: true });
    }
  }
  return json({ error: "Unknown action" }, 400);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  let body: any = {};
  try { body = await req.json(); } catch { /* empty */ }
  const action = body.action as string;

  const cronOk = CRON_SECRET && req.headers.get("x-cron-secret") === CRON_SECRET;
  if (cronOk && action === "bench") {
    const scan = await db.rpc("admin_anomaly_scan").then((r) => r.data, () => null);
    return json({ ok: true, results: await bench(), scan });
  }
  const admin = await isAdmin(req);
  if (!admin) return json({ error: "Not allowed" }, 403);

  try {
    switch (action) {
      case "me": return json({ email: admin });
      case "get_all": {
        const [providers, keys, models, aliases, routes, settings] = await Promise.all([
          db.from("ai_providers").select("*").order("name"),
          db.from("ai_keys").select("id,provider_id,label,key_preview,enabled,cooldown_until,fail_count,last_error,last_ok_at,last_fail_at,created_at").order("created_at"),
          db.from("ai_models").select("*").order("model_id"),
          db.from("ai_aliases").select("*").order("alias"),
          db.from("ai_routes").select("*").order("priority"),
          db.from("ai_settings").select("*").order("key"),
        ]);
        return json({ providers: must(providers), keys: must(keys), models: must(models), aliases: must(aliases), routes: must(routes), settings: must(settings), live_routes: await liveList() });
      }
      case "upsert_provider": {
        const p = body.provider; const row = { name: p.name, base_url: p.base_url, enabled: p.enabled ?? true, notes: p.notes ?? null, updated_at: new Date().toISOString() };
        const r = p.id ? await db.from("ai_providers").update(row).eq("id", p.id).select().single() : await db.from("ai_providers").insert(row).select().single();
        return json(must(r));
      }
      case "delete_provider": must(await db.rpc("ai_delete_provider", { p_id: body.id })); return json({ ok: true });
      case "add_key": return json({ id: must(await db.rpc("ai_add_key", { p_provider: body.provider_id, p_label: body.label ?? "key", p_key: String(body.key).trim() })) });
      case "replace_key": must(await db.rpc("ai_update_key", { p_key_id: body.id, p_key: String(body.key).trim() })); return json({ ok: true });
      case "update_key": {
        const patch: any = {}; if (body.label !== undefined) patch.label = body.label; if (body.enabled !== undefined) patch.enabled = body.enabled;
        if (body.clear_cooldown) { patch.cooldown_until = null; patch.fail_count = 0; patch.last_error = null; }
        must(await db.from("ai_keys").update(patch).eq("id", body.id)); return json({ ok: true });
      }
      case "delete_key": must(await db.rpc("ai_delete_key", { p_key_id: body.id })); return json({ ok: true });
      case "upsert_model": {
        const m = body.model; const row: any = { provider_id: m.provider_id, model_id: m.model_id, label: m.label ?? null, enabled: m.enabled ?? true,
          vision: !!m.vision, tools: m.tools ?? true, context_window: Number(m.context_window ?? 128000), extra_body: m.extra_body ?? null, notes: m.notes ?? null };
        const r = m.id ? await db.from("ai_models").update(row).eq("id", m.id).select().single() : await db.from("ai_models").insert(row).select().single();
        return json(must(r));
      }
      case "delete_model": must(await db.from("ai_models").delete().eq("id", body.id)); return json({ ok: true });
      case "upsert_alias": {
        const a = body.alias; const row = { alias: a.alias, description: a.description ?? null, max_output_tokens: Number(a.max_output_tokens ?? 1024), system_hint: a.system_hint ?? null, enabled: a.enabled ?? true };
        const r = a.original && a.original !== a.alias ? await db.from("ai_aliases").update(row).eq("alias", a.original).select().single() : await db.from("ai_aliases").upsert(row).select().single();
        return json(must(r));
      }
      case "delete_alias": must(await db.from("ai_aliases").delete().eq("alias", body.alias)); return json({ ok: true });
      case "set_routes": {
        // body.routes: [{model_ref, enabled}] in priority order
        must(await db.from("ai_routes").delete().eq("alias", body.alias));
        const rows = (body.routes ?? []).map((r: any, i: number) => ({ alias: body.alias, model_ref: r.model_ref, priority: (i + 1) * 10, enabled: r.enabled ?? true }));
        if (rows.length) must(await db.from("ai_routes").insert(rows));
        return json({ ok: true });
      }
      case "set_setting": must(await db.from("ai_settings").upsert({ key: body.key, value: body.value, updated_at: new Date().toISOString() })); return json({ ok: true });
      case "test_model": {
        const { data: mk } = await db.rpc("ai_model_with_keys", { p_model_ref: body.model_ref });
        if (!mk?.keys?.length) return json({ ok: false, error: "No enabled keys for this provider" });
        const key = body.key_id ? mk.keys.find((k: any) => k.id === body.key_id) : mk.keys[0];
        const r = await callModel(mk.base_url, key.key, mk.model, mk.extra_body, [{ role: "user", content: body.prompt || "Say hello in five words." }], 200);
        return json({ ...r, key_label: key.label });
      }
      case "test_key": {
        const { data: ks } = await db.rpc("ai_key_secret", { p_key_id: body.id });
        if (!ks) return json({ ok: false, error: "Key not found" });
        const { data: m } = await db.from("ai_models").select("model_id,extra_body").eq("provider_id", ks.provider_id).eq("enabled", true).limit(1).maybeSingle();
        if (!m) return json({ ok: false, error: "Add a model to this provider first" });
        const r = await callModel(ks.base_url, ks.key, m.model_id, m.extra_body, [{ role: "user", content: "Say OK" }], 20);
        await db.rpc("ai_mark_key", { p_key_id: body.id, p_ok: r.ok, p_error: r.error ?? "", p_cooldown_seconds: 0 });
        return json({ ...r, model: m.model_id });
      }
      case "list_remote_models": {
        const { data: p } = await db.from("ai_providers").select("base_url").eq("id", body.provider_id).single();
        const { data: k } = await db.from("ai_keys").select("id").eq("provider_id", body.provider_id).eq("enabled", true).limit(1).maybeSingle();
        const ks = k ? (await db.rpc("ai_key_secret", { p_key_id: k.id })).data : null;
        const res = await fetch(p!.base_url.replace(/\/$/, "") + "/models", { headers: ks?.key ? { authorization: `Bearer ${ks.key}` } : {} });
        const j = await res.json().catch(() => ({}));
        return json({ ids: (j.data ?? j.models ?? []).map((x: any) => x.id ?? x.name).filter(Boolean).sort() });
      }
      // Live pool (live_routes): its own keys and models, apart from chat. Order = priority (lower first, ties share load).
      case "live_list": return json({ routes: await liveList(), live_model: (await db.from("ai_settings").select("value").eq("key", "live_model").maybeSingle()).data?.value ?? null });
      case "live_add": {
        // body: {key, label?, model?, priority?} or {copy_from, model, label?, priority?} (same key with another model)
        const prio = body.priority === undefined || body.priority === null ? null : Number(body.priority);
        if (body.copy_from) return json({ id: must(await db.rpc("live_copy_route", { p_from: body.copy_from, p_label: body.label ?? "", p_model: body.model ?? "", p_priority: prio })) });
        const key = String(body.key ?? "").trim();
        if (!key) return json({ error: "Paste a key" }, 400);
        const next = prio ?? (((await db.from("live_routes").select("priority").order("priority", { ascending: false }).limit(1).maybeSingle()).data?.priority ?? 0) + 10);
        return json({ id: must(await db.rpc("live_add_route", { p_label: body.label ?? "live key", p_key: key, p_model: body.model ?? "", p_priority: next, p_provider: body.provider ?? "Google Gemini" })) });
      }
      case "live_update": {
        // body: {id, label?, enabled?, model? ("" or null = live_model default), priority?, clear_rest?}
        const patch: any = {};
        if (body.label !== undefined) patch.label = body.label;
        if (body.enabled !== undefined) patch.enabled = !!body.enabled;
        if (body.model !== undefined) patch.model = body.model ? String(body.model).trim() : null;
        if (body.priority !== undefined) patch.priority = Number(body.priority);
        if (body.clear_rest) { patch.cooldown_until = null; patch.fail_count = 0; patch.last_error = null; }
        must(await db.from("live_routes").update(patch).eq("id", body.id)); return json({ ok: true });
      }
      case "live_replace_key": must(await db.rpc("live_replace_key", { p_id: body.id, p_key: String(body.key).trim() })); return json({ ok: true });
      case "live_delete": must(await db.rpc("live_delete_route", { p_id: body.id })); return json({ ok: true });
      case "live_order": {
        // body.ids: route ids top to bottom -> priority 10, 20, 30 (a strict fallback order).
        const ids: string[] = body.ids ?? [];
        for (let i = 0; i < ids.length; i++) must(await db.from("live_routes").update({ priority: (i + 1) * 10 }).eq("id", ids[i]));
        return json({ ok: true });
      }
      case "live_set_model": must(await db.from("ai_settings").upsert({ key: "live_model", value: String(body.model).trim(), updated_at: new Date().toISOString() })); return json({ ok: true });
      case "live_test":
      case "test_live": {
        // Starts a real Live session with a short-lived pass from the Live pool (as the app does) and waits for the model to be ready.
        const { data: settings } = await db.from("ai_settings").select("key,value").in("key", ["live_model"]);
        const st = Object.fromEntries((settings ?? []).map((r: any) => [r.key, r.value]));
        let rid = body.id as string | undefined;
        if (!rid) rid = (await db.from("live_routes").select("id").eq("enabled", true).order("priority").order("created_at").limit(1).maybeSingle()).data?.id;
        if (!rid) return json({ ok: false, error: "No Live keys yet. Add one in the Live pool." });
        const { data: ks } = await db.rpc("live_route_secret", { p_id: rid });
        if (!ks?.key) return json({ ok: false, error: "Live key not found" });
        const t0 = Date.now();
        const tr = await fetch("https://generativelanguage.googleapis.com/v1alpha/auth_tokens", { method: "POST",
          headers: { "content-type": "application/json", "x-goog-api-key": ks.key },
          body: JSON.stringify({ uses: 1, expireTime: new Date(Date.now() + 600000).toISOString() }) });
        if (!tr.ok) {
          const err = "token " + tr.status + " " + (await tr.text()).slice(0, 200);
          await db.rpc("live_mark_route", { p_id: rid, p_ok: false, p_error: err, p_cooldown_seconds: 0 });
          return json({ ok: false, id: rid, error: err });
        }
        const tok = (await tr.json()).name;
        const model = body.model || ks.model || st.live_model;
        const result: any = await new Promise((resolve) => {
          const ws = new WebSocket("wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContentConstrained?access_token=" + encodeURIComponent(tok));
          const timer = setTimeout(() => { try { ws.close(); } catch { /* */ } resolve({ ok: false, error: "timeout" }); }, 15000);
          ws.onopen = () => ws.send(JSON.stringify({ setup: { model: "models/" + model, generationConfig: { responseModalities: ["AUDIO"] } } }));
          ws.onmessage = async (ev) => {
            const txt = typeof ev.data === "string" ? ev.data : await new Response(ev.data).text();
            if (txt.includes("setupComplete")) { clearTimeout(timer); ws.close(); resolve({ ok: true, ms: Date.now() - t0 }); }
          };
          ws.onclose = (ev) => { clearTimeout(timer); resolve({ ok: false, error: "closed " + ev.code + " " + ev.reason }); };
          ws.onerror = () => { /* onclose follows */ };
        });
        await db.rpc("live_mark_route", { p_id: rid, p_ok: !!result.ok, p_error: result.error ?? "", p_cooldown_seconds: 0 });
        return json({ id: rid, model, ...result });
      }
      // Call minutes (Plan 6 item 3). Day = EAT day (Africa/Mogadishu), like the token allowance.
      case "live_minutes_get": {
        const v = (await db.from("ai_settings").select("value").eq("key", "live_daily_minutes").maybeSingle()).data?.value;
        return json({ live_daily_minutes: v === undefined || v === null ? 15 : Number(v) });
      }
      case "live_minutes_set": {
        const m = Number(body.minutes);
        if (!Number.isFinite(m) || m < 0 || m > 1440) return json({ error: "Minutes must be 0 to 1440" }, 400);
        must(await db.from("ai_settings").upsert({ key: "live_daily_minutes", value: Math.round(m), updated_at: new Date().toISOString() }));
        return json({ ok: true, live_daily_minutes: Math.round(m) });
      }
      case "live_user_set": {
        // body: {user_id | email, minutes? (number, or null = back to the default), enabled? (bool), note?}
        const uid = await userIdOf(body);
        if (!uid) return json({ error: "User not found" }, 404);
        const cur = (await db.from("live_user_limits").select("*").eq("user_id", uid).maybeSingle()).data as any;
        const row: any = { user_id: uid, daily_minutes: cur?.daily_minutes ?? null, live_enabled: cur?.live_enabled ?? true, note: cur?.note ?? null, updated_at: new Date().toISOString() };
        if (body.minutes !== undefined) {
          if (body.minutes === null || body.minutes === "") row.daily_minutes = null;
          else { const m = Number(body.minutes); if (!Number.isFinite(m) || m < 0 || m > 1440) return json({ error: "Minutes must be 0 to 1440" }, 400); row.daily_minutes = Math.round(m); }
        }
        if (body.enabled !== undefined) row.live_enabled = !!body.enabled;
        if (body.note !== undefined) row.note = body.note ? String(body.note).slice(0, 200) : null;
        if (row.daily_minutes === null && row.live_enabled && !row.note) must(await db.from("live_user_limits").delete().eq("user_id", uid));
        else must(await db.from("live_user_limits").upsert(row));
        return json({ ok: true, user_id: uid, minutes: (await db.rpc("live_minutes_left", { p_uid: uid })).data });
      }
      case "live_user_clear": must(await db.from("live_user_limits").delete().eq("user_id", body.user_id)); return json({ ok: true });
      case "live_user_minutes": {
        // One user's minutes today: {user_id | email}
        const uid = await userIdOf(body);
        if (!uid) return json({ error: "User not found" }, 404);
        return json({ user_id: uid, ...((await db.rpc("live_minutes_left", { p_uid: uid })).data ?? {}) });
      }
      case "live_minutes_today": return json(must(await db.rpc("live_minutes_report")));
      // Plan 2.6: bot events per kind (events, users, bots) over the last 7 or 30 days, plus the reply rate.
      case "events_summary": return json(must(await db.rpc("events_summary", { p_days: Number(body.days ?? 7) === 30 ? 30 : 7 })));
      case "live_reset_user_today": must(await db.from("live_call_daily").delete().eq("user_id", body.user_id).eq("day", new Date(Date.now() + 3 * 3600_000).toISOString().slice(0, 10))); return json({ ok: true });
      case "stats": return json(must(await db.rpc("ai_stats", { p_hours: Number(body.hours ?? 24) })));
      case "bench": return json({ ok: true, results: await bench() });
      case "block_user": {
        const uid = await userIdOf(body);
        if (!uid) return json({ error: "User not found" }, 404);
        must(await db.from("ai_blocked_users").upsert({ user_id: uid, reason: body.reason ?? null })); return json({ ok: true });
      }
      case "unblock_user": must(await db.from("ai_blocked_users").delete().eq("user_id", body.user_id)); return json({ ok: true });
      case "blocked": return json(must(await db.from("ai_blocked_users").select("*")));
      // ---------- Users section ----------
      case "users_list": return json(must(await db.rpc("admin_users_list", { p_search: String(body.search ?? ""), p_limit: Number(body.limit ?? 300), p_offset: Number(body.offset ?? 0) })));
      case "user_detail": {
        const uid = await userIdOf(body);
        if (!uid) return json({ error: "User not found" }, 404);
        return json(must(await db.rpc("admin_user_detail", { p_uid: uid })));
      }
      case "user_suspend": {
        const uid = await userIdOf(body);
        if (!uid) return json({ error: "User not found" }, 404);
        must(await db.from("ai_blocked_users").upsert({ user_id: uid, reason: body.reason ? String(body.reason).slice(0, 300) : "suspended by " + admin }));
        must(await db.from("admin_notes").insert({ user_id: uid, note: "Suspended" + (body.reason ? ": " + String(body.reason).slice(0, 300) : ""), created_by: admin }));
        return json({ ok: true });
      }
      case "user_unsuspend": {
        must(await db.from("ai_blocked_users").delete().eq("user_id", body.user_id));
        must(await db.from("admin_notes").insert({ user_id: body.user_id, note: "Unsuspended", created_by: admin }));
        return json({ ok: true });
      }
      case "user_set_cap": {
        // body: {user_id, cap: number | null (null = back to the default)}
        if (body.cap === null || body.cap === "" || body.cap === undefined) must(await db.from("ai_user_limits").delete().eq("user_id", body.user_id));
        else {
          const cap = Math.round(Number(body.cap));
          if (!Number.isFinite(cap) || cap < 0 || cap > 1000000000) return json({ error: "Cap must be 0 to 1,000,000,000" }, 400);
          must(await db.from("ai_user_limits").upsert({ user_id: body.user_id, daily_cap_tokens: cap, note: body.note ?? null, updated_at: new Date().toISOString() }));
        }
        must(await db.from("admin_notes").insert({ user_id: body.user_id, note: "Daily cap " + (body.cap == null || body.cap === "" ? "back to default" : "set to " + Number(body.cap).toLocaleString("en-US")), created_by: admin }));
        return json({ ok: true });
      }
      case "user_note_add": {
        const note = String(body.note ?? "").trim().slice(0, 2000);
        if (!note) return json({ error: "Write a note" }, 400);
        must(await db.from("admin_notes").insert({ user_id: body.user_id, note, created_by: admin })); return json({ ok: true });
      }
      case "user_note_delete": must(await db.from("admin_notes").delete().eq("id", body.id)); return json({ ok: true });
      case "flag_resolve": must(await db.from("safety_flags").update({ resolved: body.resolved !== false, resolved_by: body.resolved !== false ? admin : null, resolved_at: body.resolved !== false ? new Date().toISOString() : null }).eq("id", body.id)); return json({ ok: true });
      case "flag_add": {
        const id = must(await db.rpc("flag_user", { p_uid: body.user_id, p_category: body.category ?? "other", p_severity: body.severity ?? "low", p_source: "admin", p_reason: String(body.reason ?? "").slice(0, 200), p_meta: { by: admin } }));
        return json({ ok: true, id });
      }
      case "flags_list": {
        let q = db.from("safety_flags").select("*").order("created_at", { ascending: false }).limit(Number(body.limit ?? 300));
        if (body.open !== false) q = q.eq("resolved", false);
        const flags = must(await q) as any[];
        const ids = [...new Set(flags.map((f) => f.user_id))];
        const emails: Record<string, string> = {};
        for (const u of ids) { const { data } = await db.auth.admin.getUserById(u); emails[u] = data?.user?.email ?? ""; }
        return json(flags.map((f) => ({ ...f, email: emails[f.user_id] })));
      }
      case "anomaly_scan": return json(must(await db.rpc("admin_anomaly_scan")));
      case "bot_unpublish": {
        const row = must(await db.from("bot_store").update({ published: false, updated_at: new Date().toISOString() }).eq("id", body.id).select("author_id,name").single()) as any;
        must(await db.from("admin_notes").insert({ user_id: row.author_id, note: `Unpublished bot "${row.name}"` + (body.reason ? ": " + String(body.reason).slice(0, 300) : ""), created_by: admin }));
        return json({ ok: true });
      }
      // ---------- rewards ----------
      case "rewards_list": return json(must(await db.rpc("admin_rewards_list", { p_state: ["active", "revoked", "expired"].includes(body.state) ? body.state : "all", p_limit: Number(body.limit ?? 300) })));
      case "reward_revoke": {
        must(await db.from("reward_ledger").update({ revoked: true, status: "revoked", revoked_at: new Date().toISOString(), revoked_by: admin,
          revoke_reason: body.reason ? String(body.reason).slice(0, 300) : null }).eq("id", body.id));
        return json({ ok: true });
      }
      case "reward_restore": must(await db.from("reward_ledger").update({ revoked: false, status: "active", revoked_at: null, revoked_by: null, revoke_reason: null }).eq("id", body.id)); return json({ ok: true });
      case "reward_grant": return json(await grantReward(admin, body));
      case "rewards_settings": {
        const keys = ["reward_enabled", "reward_referral_tokens", "reward_referral_days", "reward_creator_tokens", "reward_creator_days", "reward_max_bonus_per_day", "reward_max_lifetime", "reward_max_new_per_day", "reward_invite_window_days"];
        const rows = must(await db.from("ai_settings").select("key,value").in("key", keys)) as any[];
        return json(Object.fromEntries(rows.map((r) => [r.key, r.value])));
      }
      // ---------- messages ----------
      case "message_send": return json(await sendMessage(admin, body));
      case "messages_list": {
        const list = must(await db.from("admin_messages").select("*").order("created_at", { ascending: false }).limit(Number(body.limit ?? 100))) as any[];
        for (const m of list) {
          const { count } = await db.from("user_inbox").select("id", { count: "exact", head: true }).eq("message_id", m.id).not("read_at", "is", null);
          m.read = count ?? 0;
          if (m.audience !== "all") {
            const rs = must(await db.from("user_inbox").select("user_id").eq("message_id", m.id).limit(5)) as any[];
            m.to = [];
            for (const r of rs) { const { data } = await db.auth.admin.getUserById(r.user_id); m.to.push(data?.user?.email ?? r.user_id); }
          }
        }
        return json(list);
      }
      case "message_edit": {
        const title = String(body.title ?? "").trim().slice(0, 200);
        const text = String(body.body ?? "").trim().slice(0, 4000);
        if (!title) return json({ error: "Write a title" }, 400);
        const now = new Date().toISOString();
        must(await db.from("admin_messages").update({ title, body: text, edited_at: now }).eq("id", body.id));
        must(await db.from("user_inbox").update({ title, body: text, updated_at: now }).eq("message_id", body.id));
        return json({ ok: true });
      }
      case "message_delete": {
        const now = new Date().toISOString();
        must(await db.from("admin_messages").update({ deleted_at: now }).eq("id", body.id));
        must(await db.from("user_inbox").update({ deleted: true, updated_at: now }).eq("message_id", body.id));
        return json({ ok: true });
      }
      case "reset_user_today": must(await db.from("ai_user_daily").delete().eq("user_id", body.user_id).eq("day", new Date(Date.now() + 3 * 3600_000).toISOString().slice(0, 10))); return json({ ok: true });
      // In-app updates (dashboard "Updates" tab).
      case "releases_list": case "release_upload_url": case "release_create": case "release_edit":
      case "release_publish": case "release_unpublish": case "release_delete": case "release_file_delete":
        return await releases(admin, action, body);
      default: return json({ error: "Unknown action" }, 400);
    }
  } catch (e) {
    return json({ error: String((e as Error).message ?? e) }, 400);
  }
});
