// PLAN 1.8: ai-chat checks the user's token itself instead of trusting only the gateway (verify_jwt stays on too).
// Supabase Auth signs session tokens with ES256; the public keys are at <SUPABASE_URL>/auth/v1/.well-known/jwks.json.
// - ES256 token with a known key: signature and expiry must be valid, otherwise the request is refused.
// - Anything we cannot check here (legacy HS256 token, key not published, JWKS unreachable): the gateway already
//   verified it (verify_jwt on), so it is accepted and logged once per isolate. This never makes chat fail closed
//   because of a JWKS outage.

export type JwtResult = { uid: string | null; verified: boolean; reason?: string };

type Jwk = JsonWebKey & { kid?: string; alg?: string };
const b64urlBytes = (s: string): Uint8Array => {
  const b = atob(s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4));
  const out = new Uint8Array(b.length);
  for (let i = 0; i < b.length; i++) out[i] = b.charCodeAt(i);
  return out;
};
const b64urlJson = (s: string): any => JSON.parse(new TextDecoder().decode(b64urlBytes(s)));

export function makeVerifier(jwksUrl: string, opts: { fetchFn?: typeof fetch; now?: () => number; ttlMs?: number; timeoutMs?: number } = {}) {
  const fetchFn = opts.fetchFn ?? fetch;
  const now = opts.now ?? (() => Date.now());
  const ttl = opts.ttlMs ?? 600_000;
  const timeout = opts.timeoutMs ?? 1500;
  let keys = new Map<string, CryptoKey>();
  let fetchedAt = 0;
  let failedAt = 0;
  let inflight: Promise<void> | null = null;
  const warned = new Set<string>();
  const warnOnce = (why: string) => {
    if (warned.has(why)) return;
    warned.add(why);
    console.warn(JSON.stringify({ evt: "jwt_unverified", reason: why }));
  };

  async function load(): Promise<void> {
    try {
      const r = await fetchFn(jwksUrl, { signal: AbortSignal.timeout(timeout) });
      if (!r.ok) throw new Error("jwks " + r.status);
      const j = await r.json();
      const next = new Map<string, CryptoKey>();
      for (const k of (Array.isArray(j?.keys) ? j.keys : []) as Jwk[]) {
        if (k.kty !== "EC" || k.crv !== "P-256" || !k.kid) continue;
        try {
          next.set(k.kid, await crypto.subtle.importKey("jwk", { kty: k.kty, crv: k.crv, x: k.x, y: k.y }, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]));
        } catch { /* skip a bad key */ }
      }
      keys = next;
      fetchedAt = now();
      failedAt = 0;
    } catch {
      failedAt = now();
    }
  }
  function refresh(force = false): Promise<void> {
    const fresh = fetchedAt && now() - fetchedAt < ttl;
    const coolingDown = failedAt && now() - failedAt < 60_000;
    if ((fresh && !force) || coolingDown) return Promise.resolve();
    if (force && fetchedAt && now() - fetchedAt < 30_000) return Promise.resolve(); // unknown kid: at most one refetch per 30 s
    if (!inflight) inflight = load().finally(() => { inflight = null; });
    return inflight;
  }

  async function verify(authHeader: string | null): Promise<JwtResult> {
    const t = (authHeader ?? "").replace(/^Bearer\s+/i, "");
    const parts = t.split(".");
    if (parts.length !== 3) return { uid: null, verified: false, reason: "malformed" };
    let payload: any;
    try { payload = b64urlJson(parts[1]); } catch { return { uid: null, verified: false, reason: "malformed" }; }
    const uid = payload?.role === "authenticated" && typeof payload?.sub === "string" && payload.sub ? payload.sub as string : null;
    if (!uid) return { uid: null, verified: false, reason: "not_a_user" };
    if (typeof payload.exp === "number" && payload.exp * 1000 < now() - 30_000) return { uid: null, verified: false, reason: "expired" };
    let header: any;
    try { header = b64urlJson(parts[0]); } catch { header = null; }
    if (header?.alg !== "ES256" || typeof header?.kid !== "string") { warnOnce("alg:" + String(header?.alg ?? "none")); return { uid, verified: false, reason: "unverifiable" }; }
    await refresh();
    let key = keys.get(header.kid);
    if (!key) { await refresh(true); key = keys.get(header.kid); }
    if (!key) { warnOnce(fetchedAt ? "unknown_kid" : "jwks_unavailable"); return { uid, verified: false, reason: "unverifiable" }; }
    let ok = false;
    try {
      ok = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, b64urlBytes(parts[2]), new TextEncoder().encode(parts[0] + "." + parts[1]));
    } catch { ok = false; }
    if (!ok) return { uid: null, verified: false, reason: "bad_signature" };
    return { uid, verified: true };
  }

  return { verify, prefetch: () => { refresh().catch(() => {}); } };
}
