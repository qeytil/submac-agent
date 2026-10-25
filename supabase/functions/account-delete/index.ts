// Deletes the signed-in user's account and everything SubMac keeps for it (Play Store requirement).
import { createClient } from "npm:@supabase/supabase-js@2";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...CORS, "content-type": "application/json" } });

async function wipeFolder(bucket: string, prefix: string) {
  for (let round = 0; round < 50; round++) {
    const { data } = await db.storage.from(bucket).list(prefix, { limit: 1000 });
    if (!data?.length) return;
    const files = data.filter((f) => f.id).map((f) => `${prefix}/${f.name}`);
    const dirs = data.filter((f) => !f.id).map((f) => `${prefix}/${f.name}`);
    for (const d of dirs) await wipeFolder(bucket, d);
    if (files.length) await db.storage.from(bucket).remove(files);
    if (!files.length) return;
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  const token = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
  const { data: u } = await db.auth.getUser(token);
  const user = u?.user;
  if (!user) return json({ error: "Please sign in again." }, 401);
  let body: any = {};
  try { body = await req.json(); } catch { /* empty */ }
  if (body.confirm !== "DELETE") return json({ error: "Confirmation missing." }, 400);
  const uid = user.id;
  try {
    // Take free site links down first (their rows cascade with the user, but the hosted copies would stay up until
    // they expire). Best effort: a failure here never blocks the account deletion.
    try {
      const { data: sites } = await db.from("site_previews").select("site_key").eq("user_id", uid).eq("status", "live");
      for (const s of sites ?? []) {
        await fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/site-preview`, {
          method: "POST",
          headers: { authorization: `Bearer ${token}`, apikey: req.headers.get("apikey") ?? "", "content-type": "application/json" },
          body: JSON.stringify({ action: "remove", site_key: s.site_key }),
        }).catch(() => {});
      }
    } catch { /* keep going */ }
    const { data: mine } = await db.from("bot_store").select("id").eq("author_id", uid);
    const ids = (mine ?? []).map((r: any) => r.id);
    if (ids.length) await db.from("bot_store_hires").delete().in("bot_id", ids);
    await db.from("bot_store_hires").delete().eq("user_id", uid);
    await db.from("bot_store").delete().eq("author_id", uid);
    await db.from("messages").delete().eq("user_id", uid);
    await db.from("conversations").delete().eq("user_id", uid);
    await db.from("memories").delete().eq("user_id", uid);
    await db.from("user_settings").delete().eq("user_id", uid);
    await db.from("ai_user_daily").delete().eq("user_id", uid);
    await db.from("ai_usage").update({ user_id: null }).eq("user_id", uid);
    for (const b of ["attachments", "chat-archives"]) await wipeFolder(b, uid);
    const { error } = await db.auth.admin.deleteUser(uid);
    if (error) throw error;
    return json({ ok: true });
  } catch (e) {
    return json({ error: "Your account couldn't be deleted right now. Please try again." }, 500);
  }
});
