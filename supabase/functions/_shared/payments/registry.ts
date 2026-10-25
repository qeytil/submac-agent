// Payment provider registry. To add a provider: write ./<name>.ts implementing PaymentProvider + ProviderFactory,
// add it here, set its secrets. Nothing else changes (see MONETIZATION.md "How to add a new payment provider").
import type { Env, ProviderFactory, Registry } from "./types.ts";
import { sifaloFactory } from "./sifalo.ts";

export const PROVIDERS: Registry = {
  [sifaloFactory.name]: sifaloFactory,
};

export const DEFAULT_PROVIDER = "sifalo";
const NAME = /^[a-z][a-z0-9_]{1,31}$/;

/**
 * Provider for this request: ?provider=<name>, else a path suffix (/billing-webhook/<name>), else env PAYMENT_PROVIDER,
 * else 'sifalo'. Returns null when the name is not registered.
 */
export function providerName(url: URL, env: Env): string {
  const q = url.searchParams.get("provider");
  if (q) return q.toLowerCase();
  const parts = url.pathname.split("/").filter(Boolean);
  const i = parts.findIndex((p) => p.startsWith("billing-"));
  if (i >= 0 && parts[i + 1]) return parts[i + 1].toLowerCase();
  return (env("PAYMENT_PROVIDER") ?? DEFAULT_PROVIDER).trim().toLowerCase() || DEFAULT_PROVIDER;
}

export function lookupProvider(registry: Registry, name: string): ProviderFactory | null {
  return NAME.test(name) && Object.hasOwn(registry, name) ? registry[name] : null;
}
