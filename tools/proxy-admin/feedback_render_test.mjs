import fs from "fs";
// Render check for the Feedback tab with fake data: node tools/proxy-admin/feedback_render_test.mjs
const html = fs.readFileSync(process.argv[2] || new URL("./index.html", import.meta.url), "utf8");
let js = html.split('<script type="module">')[1].split("</script>")[0];
js = js.replace(/import \{ createClient \} from "https:\/\/esm.sh\/@supabase\/supabase-js@2";/, "")
       .replace(/\nboot\(\);\s*$/, "\n");
const els = {};
const el = (id) => (els[id] ||= { id, innerHTML: "", textContent: "", value: "", style: {}, classList: { s: new Set(["hide"]), add(c) { this.s.add(c); }, remove(c) { this.s.delete(c); }, contains(c) { return this.s.has(c); } } });
globalThis.document = { querySelector: (s) => el(s.replace("#", "")), getElementById: el, addEventListener: () => {} };
globalThis.window = globalThis;
globalThis.location = { reload() {} };
globalThis.createClient = () => ({ auth: { getSession: async () => ({ data: { session: { access_token: "t" } } }), onAuthStateChange() {} } });
const calls = [];
globalThis.fetch = async (url, init) => {
  const b = JSON.parse(init.body); calls.push([url, b]);
  if (url.endsWith("feedback-admin")) {
    if (b.action === "counts") return { ok: true, json: async () => ({ new: 1, read: 0, resolved: 1, total: 2 }) };
    if (b.action === "list") return { ok: true, json: async () => ({ items: [
      { id: "f1", user_id: "u1", message: "Chat froze <script>alert(1)</script>\nsecond line", category: "bug", app_version: "1.13.104", build_number: "174", device_model: "Google Pixel 8", os_version: "Android 15 (SDK 35)", locale: "so (en-US)", status: "new", admin_note: null, created_at: "2026-10-26T10:00:00Z", email: "a@example.com", display_name: "Amina", plan: null, user_created_at: "2026-10-01T00:00:00Z", shots: [{ path: "u1/f/1.png", url: "https://x.supabase.co/storage/v1/object/sign/feedback-screenshots/u1/f/1.png?token=abc" }], last_device: { last_seen: "2026-10-26T09:00:00Z", app_version: "1.13.103" } },
      { id: "f2", user_id: "u2", message: "Nice", category: null, status: "resolved", admin_note: "thanks", created_at: "2026-10-25T10:00:00Z", email: null, display_name: null, plan: "Weekly", shots: [{ path: "u2/x.png", url: null }], updated_at: "2026-10-26T10:00:00Z" },
    ] }) };
    if (b.action === "update") { const cur = (globalThis.__srv ||= {})[b.id] ||= { status: "new", admin_note: null }; if (b.status) cur.status = b.status; if ("admin_note" in b) cur.admin_note = b.admin_note || null; return { ok: true, json: async () => ({ id: b.id, ...cur, updated_at: "2026-10-26T11:00:00Z" }) }; }
  }
  return { ok: true, json: async () => ({}) };
};
globalThis.setInterval = () => 0;
const run = new Function(js + "\n;globalThis.__S = S; globalThis.__feedback = feedback; globalThis.__loadFbCount = loadFbCount; globalThis.__renderTabs = renderTabs;");
run();
const S = globalThis.__S;
S.data = { settings: [], providers: [], models: [], aliases: [], routes: [] };
S.tab = "feedback";
await globalThis.__loadFbCount();
globalThis.__renderTabs();
const tabs = el("tabs").innerHTML;
console.log("tab badge:", /Feedback <span class="pill warn"[^>]*>1<\/span>/.test(tabs));
globalThis.render();
await new Promise((r) => setTimeout(r, 20));
const v = el("view").innerHTML;
const checks = {
  two_items: (v.match(/class="fb /g) || []).length === 2,
  escaped: v.includes("&lt;script&gt;") && !v.includes("<script>alert"),
  img: v.includes('<img src="https://x.supabase.co/storage/v1/object/sign/feedback-screenshots/u1/f/1.png?token=abc"'),
  missing_shot: v.includes("screenshot missing"),
  user: v.includes("Amina · a@example.com") && v.includes("(deleted account)"),
  details: v.includes("1.13.104 (174)") && v.includes("Google Pixel 8 · Android 15 (SDK 35)") && v.includes("so (en-US)") && v.includes("Free / none") && v.includes("plan Weekly"),
  unread_line: v.includes("1 unread"),
  actions: v.includes("fbSet('f1','resolved'") && v.includes("fbSet('f2','new'") && v.includes("fbNote('f1'"),
};
console.log(checks);
el("fbn_f1").value = "called the user";
await globalThis.fbNote("f1", { disabled: false });
await globalThis.fbSet("f1", "resolved", { disabled: false });
console.log("updates sent:", JSON.stringify(calls.filter(([u, b]) => b.action === "update").map(([, b]) => b)));
console.log("after:", S.fb[0].status, S.fb[0].admin_note);
globalThis.fbZoom("https://x/y.png");
console.log("lightbox:", el("lightbox").innerHTML, !el("lightbox").classList.contains("hide"));
const ok = Object.values(checks).every(Boolean) && S.fb[0].status === "resolved" && S.fb[0].admin_note === "called the user";
console.log(ok ? "RENDER TEST PASS" : "RENDER TEST FAIL"); process.exit(ok ? 0 : 1);
