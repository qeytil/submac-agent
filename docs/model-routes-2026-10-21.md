# Model route order change, 2026-10-21 (reversible)

Changed directly in `ai_routes` (priority, enabled) on project moeemacbvsueekuvfjbo, the same columns the admin dashboard edits.
Nothing deleted; pricing, allowances, keys and models untouched. The proxy still tries healthy routes first (bench-set `ai_models.healthy`), then the other chat aliases' healthy routes, then unhealthy ones, so priority decides order inside each group.

Basis: last 7 days of `ai_usage` (real traffic, excluding bench/moderation) plus the hourly bench rows:
- submac-smart: Ollama gpt-oss:120b p50 first token 524 ms, 12/12 ok (bench 150/154, ~0.9 s); NVIDIA nemotron-3-ultra p50 1.5 s / p90 5.5 s, 204/214 ok (1 key); Gemini 3 Flash Preview 74/208 ok (400 'missing thought_signature' on tool calls, 429 quota, first-byte timeouts), p50 4.3 s; Dahl DeepSeek-V4-Flash p50 13.2 s, 64/118 ok, 1.77 tries (429 'model_concurrency', 503).
- submac-fast: Ollama gpt-oss:20b p50 721 ms, 95/102 ok; Agnes 2.5 Flash p50 1.2 s; Dahl MiniMax-M2.7 median total 37 s at 2.71 tries.
- Poolside laguna-s-2.1 and Token Harbor deepseek-v4.x: 154/154 on the bench (~1.0 s / ~1.4-2.2 s).

| alias | before (priority provider model [state]) | after |
|---|---|---|
| submac-fast | 10 Ollama Cloud gpt-oss:20b<br>20 Agnes AI agnes-2.5-flash<br>30 NVIDIA NIM openai/gpt-oss-20b<br>40 Dahl MiniMaxAI/MiniMax-M2.7<br>50 Google Gemini gemini-3.5-flash-lite<br>60 Ollama Cloud gemma4:31b<br>70 OpenRouter cohere/north-mini-code:free<br>80 anymodel am/free<br>90 Token Harbor deepseek-v4-flash:free | 10 Ollama Cloud gpt-oss:20b<br>20 Agnes AI agnes-2.5-flash<br>30 Token Harbor deepseek-v4-flash:free<br>40 Google Gemini gemini-3.5-flash-lite<br>50 Ollama Cloud gemma4:31b<br>60 NVIDIA NIM openai/gpt-oss-20b<br>70 OpenRouter cohere/north-mini-code:free<br>80 anymodel am/free<br>90 Dahl MiniMaxAI/MiniMax-M2.7 [OFF] |
| submac-lite | 10 Google Gemini gemini-3.5-flash-lite<br>20 Ollama Cloud gpt-oss:20b<br>30 Agnes AI agnes-2.5-flash<br>40 OpenRouter liquid/lfm-2.5-2.6b:free | 10 Ollama Cloud gpt-oss:20b<br>20 Agnes AI agnes-2.5-flash<br>30 Google Gemini gemini-3.5-flash-lite<br>40 OpenRouter liquid/lfm-2.5-2.6b:free |
| submac-smart | 5 Google Gemini gemini-3-flash-preview<br>10 Dahl deepseek-ai/DeepSeek-V4-Flash-0731<br>20 NVIDIA NIM nvidia/nemotron-3-ultra-550b-a55b<br>30 OpenRouter nvidia/nemotron-3-ultra-550b-a55b:free<br>40 Google Gemini gemini-3.6-flash<br>50 NVIDIA NIM nvidia/nemotron-3-super-120b-a12b<br>60 Ollama Cloud gpt-oss:120b<br>70 Token Harbor deepseek-v4.1-flash:free<br>90 OpenRouter nvidia/nemotron-3-super-120b-a12b:free<br>100 Agnes AI agnes-3.0-flash<br>110 Poolside poolside/laguna-s-2.1 | 10 Ollama Cloud gpt-oss:120b<br>20 NVIDIA NIM nvidia/nemotron-3-ultra-550b-a55b<br>30 Poolside poolside/laguna-s-2.1<br>40 Token Harbor deepseek-v4.1-flash:free<br>50 OpenRouter nvidia/nemotron-3-ultra-550b-a55b:free<br>60 NVIDIA NIM nvidia/nemotron-3-super-120b-a12b<br>70 Agnes AI agnes-3.0-flash<br>80 Google Gemini gemini-3-flash-preview<br>90 Google Gemini gemini-3.6-flash<br>100 OpenRouter nvidia/nemotron-3-super-120b-a12b:free<br>110 Dahl deepseek-ai/DeepSeek-V4-Flash-0731 [OFF] |
| submac-think | 10 Google Gemini gemini-3-flash-preview<br>20 Ollama Cloud gpt-oss:120b<br>30 NVIDIA NIM nvidia/nemotron-3-ultra-550b-a55b<br>40 Token Harbor deepseek-v4.1-flash:free<br>50 OpenRouter nvidia/nemotron-3-ultra-550b-a55b:free | 10 Ollama Cloud gpt-oss:120b<br>20 NVIDIA NIM nvidia/nemotron-3-ultra-550b-a55b<br>30 Token Harbor deepseek-v4.1-flash:free<br>40 Google Gemini gemini-3-flash-preview<br>50 OpenRouter nvidia/nemotron-3-ultra-550b-a55b:free |
| submac-vision | 10 NVIDIA NIM nvidia/nemotron-3.5-super-vl-120b-a12b<br>20 Google Gemini gemini-3.5-flash-lite<br>30 Google Gemini gemini-3-flash-preview<br>40 Ollama Cloud gemma4:31b<br>50 Google Gemini gemini-3.6-flash<br>60 Agnes AI agnes-2.5-flash<br>70 OpenRouter nvidia/nemotron-3.5-super-vl:free<br>80 BazaarLink qwen/qwen3.7-flash:free | 10 Ollama Cloud gemma4:31b<br>20 NVIDIA NIM nvidia/nemotron-3.5-super-vl-120b-a12b<br>30 Google Gemini gemini-3.5-flash-lite<br>40 Agnes AI agnes-2.5-flash<br>50 BazaarLink qwen/qwen3.7-flash:free<br>60 Google Gemini gemini-3-flash-preview<br>70 Google Gemini gemini-3.6-flash<br>80 OpenRouter nvidia/nemotron-3.5-super-vl:free |

Disabled (kept, not deleted): Dahl DeepSeek-V4-Flash on submac-smart, Dahl MiniMax-M2.7 on submac-fast. Gemini routes demoted to the bottom of smart/think and below the faster vision routes.

Risk to watch: Ollama Cloud now leads smart, think, fast and lite (4 keys). If it rate-limits, keys rest 60 s and the next route (NVIDIA / Agnes) takes over within the same request.

## Revert
Run this SQL (service role / SQL editor) to restore the exact previous order:

```sql
-- revert 2026-10-21 route reorder
update ai_routes set priority=60, enabled=true where id='c9332e83-72c9-44c9-a3c9-d11c76c0d9d3';
update ai_routes set priority=20, enabled=true where id='d9fa054d-ab51-4884-8c94-ecb8bf773407';
update ai_routes set priority=110, enabled=true where id='182c1e62-aef1-4274-bcb8-1e4e1ccdace2';
update ai_routes set priority=70, enabled=true where id='a375c1a0-7a0f-41cf-a55f-356b463f369d';
update ai_routes set priority=30, enabled=true where id='b248837d-545c-4fbc-964c-70f7c9a9e2a0';
update ai_routes set priority=50, enabled=true where id='602b4343-2971-4731-a7ec-089563c01d89';
update ai_routes set priority=100, enabled=true where id='ac030941-fc99-4112-9583-2e0f147ff246';
update ai_routes set priority=5, enabled=true where id='407c1b7a-3a74-4360-a1ec-2b4bacfc1c06';
update ai_routes set priority=40, enabled=true where id='5144bbd8-a850-4ae9-9364-b0161fef9d98';
update ai_routes set priority=90, enabled=true where id='0fb3c708-2611-478c-95a9-5e7d202dace9';
update ai_routes set priority=10, enabled=true where id='e964ffa0-9f5d-41e5-af52-fa63ee954d12';
update ai_routes set priority=10, enabled=true where id='9235fd26-8bbd-4896-aee9-175241cb6f23';
update ai_routes set priority=20, enabled=true where id='d5b57831-0845-497b-87d0-8ce6bcb2009b';
update ai_routes set priority=90, enabled=true where id='4f5b542d-4505-48db-8353-6c18d5efe6d9';
update ai_routes set priority=50, enabled=true where id='f42ae6ae-70fa-4dd1-ba12-0e718023017c';
update ai_routes set priority=60, enabled=true where id='72e94e27-908c-4ff1-9c42-fe4628ac9ec9';
update ai_routes set priority=30, enabled=true where id='dcc57943-f436-46b5-a158-d6f85c652826';
update ai_routes set priority=70, enabled=true where id='16b76149-bc21-4142-ac39-9ce0d14e5744';
update ai_routes set priority=80, enabled=true where id='553b9bbf-1035-4128-80a9-bf537cfd325c';
update ai_routes set priority=40, enabled=true where id='d66d2a32-4fc7-4386-be74-692e49b9bc4f';
update ai_routes set priority=20, enabled=true where id='5e841354-fe65-4438-8ce6-5472a99e2830';
update ai_routes set priority=30, enabled=true where id='a78fd1a2-0019-4069-9e9b-74d7abd54c7a';
update ai_routes set priority=40, enabled=true where id='8c290eea-506b-4ea5-b76b-86edb5985ae0';
update ai_routes set priority=10, enabled=true where id='d9bf6a89-5c3e-4030-a096-2fba3ad0502c';
update ai_routes set priority=50, enabled=true where id='6e213743-4002-4e4e-bb37-b1d0567a80d3';
update ai_routes set priority=40, enabled=true where id='2a044768-60e5-421c-b591-95fde2c6e7b4';
update ai_routes set priority=10, enabled=true where id='cced38a0-7cb9-4551-af98-abdd77adad16';
update ai_routes set priority=20, enabled=true where id='68c1d57c-f36c-4804-8f4c-cf73f3309a76';
update ai_routes set priority=60, enabled=true where id='f74624ea-b6ee-4f11-b07c-aa0ebd8b94dd';
update ai_routes set priority=80, enabled=true where id='a40c2900-bd59-49fb-998c-48898412cd1f';
update ai_routes set priority=30, enabled=true where id='8a5878ca-d19b-4ad2-8c81-b30ab4a11bd0';
update ai_routes set priority=50, enabled=true where id='eba4b1c5-61b0-4938-9ece-4dd5d1c385f1';
update ai_routes set priority=70, enabled=true where id='4261ac6d-d7f3-4c43-b2f1-577e227e29f4';
update ai_routes set priority=20, enabled=true where id='15fd3394-3fd1-4d02-b2bd-b66dc9e328e2';
update ai_routes set priority=30, enabled=true where id='14a09bf5-539b-47d5-ba6c-7c59a5a5df17';
update ai_routes set priority=10, enabled=true where id='a6b8ef17-c655-4cf9-95a3-d3ee4510fa9d';
update ai_routes set priority=40, enabled=true where id='7c8acf81-2c99-482c-a3e3-c35e68c493cb';
```
