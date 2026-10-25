// billing-return: provider-neutral (see _shared/payments/core.ts). Provider = ?provider=<name> | /billing-return/<name> |
// env PAYMENT_PROVIDER | 'sifalo'. Refuses when the provider's secrets are missing or billing is off (billing_is_on).
import { handleReturn } from "../_shared/payments/core.ts";

Deno.serve((req) => handleReturn(req, { env: (k) => Deno.env.get(k), fetch: (...a) => fetch(...a) }));
