// Minimal Supabase access over fetch (PostgREST RPC + Auth), service role. No SDK, so the functions bundle to one
// file and tests can mock every call through one fetch.
import type { Env, FetchFn } from "./types.ts";

export class Db {
  constructor(private url: string, private key: string, private fetchFn: FetchFn) {}

  static fromEnv(env: Env, fetchFn: FetchFn): Db | null {
    const url = (env("SUPABASE_URL") ?? "").replace(/\/+$/, "");
    const key = env("SUPABASE_SERVICE_ROLE_KEY") ?? "";
    return url && key ? new Db(url, key, fetchFn) : null;
  }

  private headers(): Record<string, string> {
    return { apikey: this.key, authorization: `Bearer ${this.key}`, "content-type": "application/json" };
  }

  async rpc<T = unknown>(fn: string, args: Record<string, unknown>): Promise<T> {
    const r = await this.fetchFn(`${this.url}/rest/v1/rpc/${fn}`, {
      method: "POST", headers: this.headers(), body: JSON.stringify(args),
    });
    const text = await r.text();
    if (!r.ok) throw new Error(`rpc ${fn} failed (${r.status}): ${text.slice(0, 200)}`);
    return (text ? JSON.parse(text) : null) as T;
  }

  /**
   * billing_is_on(uid): on = billing applies (on for everyone, or uid is a tester while Sifalo is staging);
   * tester = uid is in billing_testers. No uid (webhook, return, reconcile): on when enabled or any tester exists.
   */
  async billingStatus(uid: string | null = null): Promise<{ on: boolean; tester: boolean; enabled: boolean }> {
    const r = await this.rpc<Record<string, unknown> | null>("billing_is_on", { p_uid: uid });
    return { on: r?.on === true, tester: r?.tester === true, enabled: r?.enabled === true };
  }

  /** Signed-in user from a user access token (null when invalid). */
  async getUser(token: string): Promise<{ id: string; email: string | null } | null> {
    if (!token || token.length < 20) return null;
    const r = await this.fetchFn(`${this.url}/auth/v1/user`, { headers: { apikey: this.key, authorization: `Bearer ${token}` } });
    if (!r.ok) return null;
    const u = await r.json().catch(() => null) as { id?: string; email?: string } | null;
    return u?.id ? { id: u.id, email: u.email ?? null } : null;
  }

  functionsBase(env: Env): string {
    return (env("BILLING_FUNCTIONS_URL") ?? `${this.url}/functions/v1`).replace(/\/+$/, "");
  }
}
