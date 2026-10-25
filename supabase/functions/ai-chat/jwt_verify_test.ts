// Run: deno test -A supabase/functions/ai-chat/jwt_verify_test.ts
import { assert, assertEquals } from "jsr:@std/assert@1";
import { makeVerifier } from "./jwt_verify.ts";

const b64u = (b: Uint8Array | string) => {
  const bytes = typeof b === "string" ? new TextEncoder().encode(b) : b;
  let s = ""; for (const x of bytes) s += String.fromCharCode(x);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
};
const kp = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]) as CryptoKeyPair;
const other = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]) as CryptoKeyPair;
const pub = await crypto.subtle.exportKey("jwk", kp.publicKey);
const jwks = { keys: [{ ...pub, kid: "k1", alg: "ES256", use: "sig" }] };
async function sign(payload: any, key = kp.privateKey, header: any = { alg: "ES256", kid: "k1", typ: "JWT" }) {
  const h = b64u(JSON.stringify(header)), p = b64u(JSON.stringify(payload));
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(h + "." + p)));
  return "Bearer " + h + "." + p + "." + b64u(sig);
}
const NOW = 1_800_000_000_000;
const user = { role: "authenticated", sub: "u-1", exp: NOW / 1000 + 3600 };
let fetches = 0;
const okFetch = (async () => { fetches++; return Response.json(jwks); }) as unknown as typeof fetch;
const downFetch = (async () => { fetches++; throw new Error("down"); }) as unknown as typeof fetch;

Deno.test("valid ES256 token with a published key is verified", async () => {
  fetches = 0;
  const v = makeVerifier("x", { fetchFn: okFetch, now: () => NOW });
  const r = await v.verify(await sign(user));
  assertEquals(r, { uid: "u-1", verified: true });
  await v.verify(await sign(user));
  assertEquals(fetches, 1); // JWKS cached
});
Deno.test("forged signature is refused", async () => {
  const v = makeVerifier("x", { fetchFn: okFetch, now: () => NOW });
  const r = await v.verify(await sign(user, other.privateKey));
  assertEquals(r.uid, null); assertEquals(r.reason, "bad_signature");
});
Deno.test("tampered payload is refused", async () => {
  const v = makeVerifier("x", { fetchFn: okFetch, now: () => NOW });
  const t = (await sign(user)).split(".");
  t[1] = b64u(JSON.stringify({ ...user, sub: "someone-else" }));
  const r = await v.verify(t.join("."));
  assertEquals(r.uid, null);
});
Deno.test("expired token is refused", async () => {
  const v = makeVerifier("x", { fetchFn: okFetch, now: () => NOW });
  const r = await v.verify(await sign({ ...user, exp: NOW / 1000 - 120 }));
  assertEquals(r.reason, "expired"); assertEquals(r.uid, null);
});
Deno.test("non-user roles and garbage give no user", async () => {
  const v = makeVerifier("x", { fetchFn: okFetch, now: () => NOW });
  assertEquals((await v.verify(await sign({ role: "anon", exp: NOW / 1000 + 60 }))).uid, null);
  assertEquals((await v.verify("Bearer nope")).uid, null);
  assertEquals((await v.verify(null)).uid, null);
});
Deno.test("JWKS down or legacy HS256: falls back to the gateway's check", async () => {
  const v = makeVerifier("x", { fetchFn: downFetch, now: () => NOW });
  const r = await v.verify(await sign(user));
  assertEquals(r, { uid: "u-1", verified: false, reason: "unverifiable" });
  const v2 = makeVerifier("x", { fetchFn: okFetch, now: () => NOW });
  const hs = "Bearer " + b64u(JSON.stringify({ alg: "HS256", typ: "JWT" })) + "." + b64u(JSON.stringify(user)) + ".sig";
  assertEquals((await v2.verify(hs)).uid, "u-1");
});
Deno.test("unknown kid refetches at most once per 30 s", async () => {
  fetches = 0;
  let t = NOW;
  const v = makeVerifier("x", { fetchFn: okFetch, now: () => t });
  const tok = await sign(user, kp.privateKey, { alg: "ES256", kid: "k9" });
  const r = await v.verify(tok);
  assert(!r.verified); assertEquals(r.uid, "u-1");
  await v.verify(tok); await v.verify(tok);
  assertEquals(fetches, 1);
  t += 31_000; await v.verify(tok);
  assertEquals(fetches, 2);
});
