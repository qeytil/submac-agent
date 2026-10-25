// billing-webhook: provider-neutral (see _shared/payments/core.ts). Provider = ?provider=<name> | /billing-webhook/<name> |
// env PAYMENT_PROVIDER | 'sifalo'. Refuses when the provider's secrets are missing or billing is off (billing_is_on).
import { handleWebhook } from "../_shared/payments/core.ts";

Deno.serve((req) => handleWebhook(req, { env: (k) => Deno.env.get(k), fetch: (...a) => fetch(...a) }));
