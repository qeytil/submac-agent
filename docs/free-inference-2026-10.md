# Free, fast LLM inference for launch (researched 2026-10-21, official pages)

Context: SubMac agent steps send 7-13k-token prompts with tools; submac-fast is short replies. Nothing here was added to the proxy; no new providers or keys.

| Provider | Free limits (official) | Speed / our data | Fit as first route |
|---|---|---|---|
| Groq (free plan) | gpt-oss-120b, gpt-oss-20b, qwen3.8-27b: 30 RPM, 1K RPD, **8K TPM**, 200K TPD, per organization. Source: https://console.groq.com/docs/rate-limits | Very fast (LPU), not measured by us | **No** for smart: one agent step (7-13k tokens) is over the 8K tokens/min cap. OK for tiny calls (titles, moderation check). |
| Cerebras | No permanent free tier: $5 credits for 30 days after adding a card; trial gpt-oss-120b 5 RPM, 30K uncached TPM, 1M TPD. Developer (paid) tier: 1K RPM, 1M TPM, no daily cap. Source: https://inference-docs.cerebras.ai/support/rate-limits | Fastest class (wafer-scale), not measured by us | **No** free option. Best paid upgrade for speed once there is revenue. |
| Google Gemini API (free tier) | Flash / Flash-Lite / 3 Flash Preview are "Free of charge" on the free tier; exact RPM/RPD per project only in AI Studio; RPD resets midnight Pacific; free-tier content is used to improve Google products. Sources: https://ai.google.dev/gemini-api/docs/pricing , https://ai.google.dev/gemini-api/docs/rate-limits | Our 7 days: 3 Flash Preview 74/208 ok, p50 4.3 s (429 quota, 400 missing thought_signature on tool calls, timeouts) | **No** until tool-call thought signatures are passed back; keep as fallback / vision. Privacy note for users on the free tier. |
| OpenRouter `:free` models | 20 RPM; 50 requests/day (under $10 credits bought) or 1,000/day after buying $10 once; per account (more keys/accounts don't add capacity). Source: https://openrouter.ai/docs/api-reference/limits | Our data: frequent 429 free-models-per-day | **No**: 1,000 requests/day for the whole app. Last resort only. |
| NVIDIA NIM (build.nvidia.com) | Free to prototype, up to 40 RPM for most models, no per-token billing; downloadable/production use needs NVIDIA AI Enterprise. Sources: https://build.nvidia.com/docs/api-catalog , https://docs.api.nvidia.com/nim/docs/run-anywhere | Our data: nemotron-3-ultra 204/214 ok, p50 1.5 s (1 key) | **Second route** (now #2 on smart). Terms frame it as prototyping, so not a launch-scale guarantee. |
| Cloudflare Workers AI | 10,000 Neurons/day free (all plans), then $0.011 / 1K Neurons on Workers Paid. gpt-oss-120b = $0.35 / M input, $0.75 / M output (about 0.3M input tokens/day free). Source: https://developers.cloudflare.com/workers-ai/platform/pricing/ | Not measured | **No** free (a few dozen agent steps a day). Cheapest paid gpt-oss-120b on this list. |
| Cloudflare AI Gateway | Core features free (analytics, caching, rate limiting); no inference of its own. Source: https://developers.cloudflare.com/ai-gateway/reference/pricing/ | Adds a hop | Not a speed fix; useful later for logging/caching across providers. |

## Recommendation
1. No single free tier can carry a launch at our prompt sizes. Keep the multi-provider pool: Ollama Cloud gpt-oss:120b / gpt-oss:20b first (fastest measured, 4 keys), NVIDIA second, Poolside / Token Harbor next (all free today). Ollama Cloud's own free limits were not re-checked in this pass.
2. Use Groq free only for small side calls (moderation, titles) if a key is added later; its 8K TPM rules out agent steps.
3. First paid step when there is revenue: Cerebras or Groq developer tier for gpt-oss-120b (speed), or Workers AI gpt-oss-120b (price).
4. Before leaning on Gemini again for tools: pass Gemini 3 `thought_signature` back on tool-call turns (that error alone was 77+ failures in 7 days).
