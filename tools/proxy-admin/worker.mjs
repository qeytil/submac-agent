import HTML from "./index.html";
const SEC = {
  "content-type": "text/html; charset=utf-8",
  "x-frame-options": "DENY",
  "x-content-type-options": "nosniff",
  "referrer-policy": "no-referrer",
  "cache-control": "no-store",
  "content-security-policy": "default-src 'self'; script-src 'self' 'unsafe-inline' https://esm.sh; connect-src 'self' https://*.supabase.co https://esm.sh; style-src 'self' 'unsafe-inline'; img-src 'self' data: https://*.supabase.co; frame-ancestors 'none'",
};

// ---------- /api/updates/*: app update files into Cloudflare R2 (binding UPDATES -> bucket submac-app-updates) ----------
// The dashboard streams the file here in 32 MiB parts (R2 multipart upload), so one release is ONE public file and the
// phone downloads it in one go. Only admins: the caller's own sign-in is checked by ai-admin "me" on every request.
const PART = 32 * 1024 * 1024; // every part but the last has exactly this size (R2 needs equal parts, >= 5 MiB)
const MAX_PARTS = 40; // 1.25 GiB, far above any app file
const KEY = /^android\/([0-9]+)-[0-9a-f]{8}\/SubMac-([0-9]+)\.apk$/;
const J = (b, status = 200) => new Response(JSON.stringify(b), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } });

async function admin(req, env, action = "me", body = {}) {
  const auth = req.headers.get("authorization") || "";
  if (!/^Bearer\s+\S+/i.test(auth)) return { ok: false, status: 401 };
  const r = await fetch(env.SB_URL + "/functions/v1/ai-admin", {
    method: "POST",
    headers: { "content-type": "application/json", authorization: auth, apikey: env.SB_ANON },
    body: JSON.stringify({ action, ...body }),
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok || j.error) return { ok: false, status: r.status === 403 || r.status === 401 ? 403 : 502, error: j.error };
  return { ok: true, data: j };
}

function goodKey(key) {
  const m = KEY.exec(String(key || ""));
  return !!m && m[1] === m[2];
}

async function updates(req, env, op) {
  if (!env.UPDATES) return J({ error: "Update storage is not connected." }, 500);
  const me = await admin(req, env);
  if (!me.ok) return J({ error: "Not allowed" }, 403);
  const url = new URL(req.url);
  if (op === "part") {
    if (req.method !== "PUT") return J({ error: "Use PUT" }, 405);
    const key = url.searchParams.get("key"), uploadId = url.searchParams.get("upload_id"), n = Number(url.searchParams.get("n"));
    if (!goodKey(key) || !uploadId || !Number.isInteger(n) || n < 1 || n > MAX_PARTS) return J({ error: "Bad part." }, 400);
    const len = Number(req.headers.get("content-length") || 0);
    if (!len || len > PART) return J({ error: "Each part must be at most 32 MiB." }, 400);
    const up = env.UPDATES.resumeMultipartUpload(key, uploadId);
    const part = await up.uploadPart(n, req.body); // streamed straight into R2
    return J({ partNumber: part.partNumber, etag: part.etag });
  }
  if (req.method !== "POST") return J({ error: "Use POST" }, 405);
  const body = await req.json().catch(() => ({}));
  switch (op) {
    case "start": {
      const code = Number(body.version_code), size = Number(body.size_bytes);
      if (!Number.isInteger(code) || code <= 0) return J({ error: "Version number (build) is missing." }, 400);
      if (!Number.isInteger(size) || size <= 0 || size > PART * MAX_PARTS) return J({ error: "The file size is not right." }, 400);
      const rnd = [...crypto.getRandomValues(new Uint8Array(4))].map((b) => b.toString(16).padStart(2, "0")).join("");
      const key = `android/${code}-${rnd}/SubMac-${code}.apk`;
      const up = await env.UPDATES.createMultipartUpload(key, {
        httpMetadata: { contentType: "application/vnd.android.package-archive", contentDisposition: `attachment; filename="SubMac-${code}.apk"` },
        customMetadata: { by: String(me.data.email || ""), size: String(size) },
      });
      return J({ key, upload_id: up.uploadId, part_size: PART, parts: Math.max(1, Math.ceil(size / PART)) });
    }
    case "complete": {
      if (!goodKey(body.key) || !body.upload_id || !Array.isArray(body.parts) || !body.parts.length) return J({ error: "Bad upload." }, 400);
      const parts = body.parts.map((p) => ({ partNumber: Number(p.partNumber), etag: String(p.etag) })).sort((a, b) => a.partNumber - b.partNumber);
      const up = env.UPDATES.resumeMultipartUpload(body.key, body.upload_id);
      const obj = await up.complete(parts);
      return J({ ok: true, key: obj.key, size: obj.size, etag: obj.httpEtag });
    }
    case "abort": {
      if (!goodKey(body.key) || !body.upload_id) return J({ error: "Bad upload." }, 400);
      try { await env.UPDATES.resumeMultipartUpload(body.key, body.upload_id).abort(); } catch { /* already gone */ }
      return J({ ok: true });
    }
    case "delete_file": {
      // A file that never became a release (the owner gave up half way). Refused if a release still points at it.
      if (!goodKey(body.key)) return J({ error: "Bad file." }, 400);
      const list = await admin(req, env, "releases_list");
      if (!list.ok) return J({ error: "Not allowed" }, 403);
      if ((list.data.releases || []).some((r) => r.file_key === body.key)) return J({ error: "That file belongs to a release; delete the release instead." }, 409);
      await env.UPDATES.delete(body.key);
      return J({ ok: true });
    }
    case "delete_release": {
      // ai-admin deletes the row (and any Supabase parts) and hands back the R2 key, which is removed here.
      if (!body.id) return J({ error: "Bad release." }, 400);
      const del = await admin(req, env, "release_delete", { id: body.id });
      if (!del.ok) return J({ error: del.error || "Not allowed" }, del.status || 403);
      const key = del.data.file_key;
      if (del.data.storage === "r2" && goodKey(key)) await env.UPDATES.delete(key);
      return J({ ok: true, storage: del.data.storage || null, file_key: key || null });
    }
  }
  return J({ error: "Not found" }, 404);
}

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    const m = /^\/api\/updates\/(start|part|complete|abort|delete_file|delete_release)$/.exec(url.pathname);
    if (m) {
      try { return await updates(req, env, m[1]); } catch (e) { return J({ error: String((e && e.message) || e).slice(0, 300) }, 500); }
    }
    if (url.pathname !== "/") return new Response("Not found", { status: 404 });
    const page = HTML.replace("__SB_URL__", env.SB_URL).replace("__SB_ANON__", env.SB_ANON);
    return new Response(page, { headers: SEC });
  },
  async scheduled(event, env, ctx) {
    ctx.waitUntil(fetch(env.SB_URL + "/functions/v1/ai-admin", {
      method: "POST",
      headers: { "content-type": "application/json", authorization: "Bearer " + env.SB_ANON, apikey: env.SB_ANON, "x-cron-secret": env.CRON_SECRET },
      body: JSON.stringify({ action: "bench" }),
    }));
  },
};
