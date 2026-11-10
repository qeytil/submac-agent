# Third-party code, packages and borrowed ideas

Only permissive licenses (MIT, BSD, Apache-2.0, ISC, CC0). Each entry: name, version or date, license, source, what we use.

## Agent loop (branch feature/agent-loop, 2026-10-20)
No code was copied; `lib/services/agent_loop.dart` is our own Dart. These projects and write-ups shaped the design:

| Idea | From | License | Source | Where in Telesia |
|---|---|---|---|---|
| Stuck patterns (same action+observation, same action+error 3x, alternating A-B 6 steps) and their thresholds | OpenHands Software Agent SDK `StuckDetector` (2025-2026) | MIT | https://github.com/OpenHands/software-agent-sdk/blob/main/openhands-sdk/openhands/sdk/conversation/stuck_detector.py , https://docs.openhands.dev/sdk/guides/agent-stuck-detector | `LoopGuard` |
| Canonical (key-sorted) serialization to compare tool calls; identical-call limit 3 | Roo Code `ToolRepetitionDetector` | Apache-2.0 | https://github.com/RooCodeInc/Roo-Code/blob/main/src/core/tools/ToolRepetitionDetector.ts | `LoopGuard.canonicalArgs` |
| Several tool calls from one reply run in parallel | smolagents `ToolCallingAgent` (v1.18.0, PR #1412) | Apache-2.0 | https://github.com/huggingface/smolagents/pull/1412 | `ParallelPlan` (we add the read-only rule and barriers) |
| Parallel tool execution node | LangGraph `ToolNode` | MIT | https://github.com/langchain-ai/langgraph | `ParallelPlan` |
| Observation masking: keep the last N observations, elide older ones | SWE-agent `LastNObservations` | MIT | https://github.com/SWE-agent/SWE-agent/blob/main/sweagent/agent/history_processors.py | `ResultClip.old` + existing "last 3 whole" rule |
| Turn limit with graceful end | OpenAI Agents SDK `max_turns` | MIT | https://github.com/openai/openai-agents-python | `StepBudget` |
| Stable prompt prefix for the KV cache, no timestamps up front, append-only context, todo recitation at the end, keep errors in context, restorable compression | Manus blog "Context Engineering for AI Agents" (Yichao Ji, 2025-07-18) | blog post, ideas only (no code) | https://manus.im/blog/Context-Engineering-for-AI-Agents-Lessons-from-Building-Manus | `TailNote`, `Recite` |

## Chat feel (branch feature/agent-loop, UX, 2026-10-20)
No new packages and no copied code. Ideas only:

| Idea | From | License | Source | Where in Telesia |
|---|---|---|---|---|
| Render a streaming markdown reply as memoized blocks so only the last block re-renders | Vercel AI SDK cookbook "Memoize markdown blocks" | Apache-2.0 (repo) | https://github.com/vercel/ai | `StreamingMarkdown`, `splitMarkdownChunks` |


## Tools, skills and one-tap apps (branch feature/agent-loop, ECO, 2026-10-20, v1.13.50+83)

### Packages (pub.dev)
| Package | Version | License | Source | What for |
|---|---|---|---|---|
| html | 0.15.6 (constraint ^0.15.4) | MIT | https://pub.dev/packages/html , https://github.com/dart-lang/html | `lib/services/readable.dart`: web pages as readable text (main article, headings, lists, tables) for `fetch_url` and EPUB chapters |
| csslib | 1.0.2 (pulled in by html) | BSD-3-Clause | https://pub.dev/packages/csslib | dependency of html only |
| xml | 6.5.0 (was already in the app through flutter_svg; now direct, ^6.5.0) | MIT | https://pub.dev/packages/xml | `lib/services/doc_text.dart`: Word, Excel, PowerPoint, OpenDocument and EPUB text |
| archive | 3.6.1 (already a direct dependency) | MIT | https://pub.dev/packages/archive | unzips the office files above |

Pure Dart, no native code, no network calls of their own. Resolves with Flutter 3.24.5 (Dart 3.5).

Considered and not added: `google_mlkit_barcode_scanning` 0.12.1 (reading QR codes from photos; MIT, matches our ML Kit commons 0.8.1) because it adds a native model to the APK and the release check enforces 16 KB page alignment, which we could not verify without a device build; `math_expressions`, `excel`, `csv`, `intl` date parsing: Telesia's own `math_expr.dart`, `doc_maker.dart` and the new `calc.dart` already cover these without another package.

### Skills in the public library (index v3, 433 skills; sources in `tools/skills/thirdparty/build.py`)
Each skill was rewritten for Telesia's tools and everyday users and keeps a credit line in its body plus `source`, `license`, `author` fields in its file.

| Library id | Adapted from | License | Source (commit) |
|---|---|---|---|
| prd-brainstorm-to-plan | skills/brainstorming | MIT, (c) 2025 Jesse Vincent | https://github.com/obra/superpowers (bb92a77) |
| dev-implementation-plan | skills/writing-plans | MIT, (c) 2025 Jesse Vincent | same |
| dev-systematic-debugging | skills/systematic-debugging | MIT, (c) 2025 Jesse Vincent | same |
| dev-test-first | skills/test-driven-development | MIT, (c) 2025 Jesse Vincent | same |
| prd-check-before-done | skills/verification-before-completion | MIT, (c) 2025 Jesse Vincent | same |
| cre-distinctive-design | skills/frontend-design (folder LICENSE.txt) | Apache-2.0, Anthropic | https://github.com/anthropics/skills (dbd4588) |
| prd-design-themes | skills/theme-factory (10 themes' colours and fonts) | Apache-2.0, Anthropic | same |
| biz-team-updates | skills/internal-comms (+ examples) | Apache-2.0, Anthropic | same |
| cre-poster-art-direction | skills/canvas-design | Apache-2.0, Anthropic | same |
| wri-humanize-text | marketing-skill/skills/content-humanizer | MIT, (c) 2025 Alireza Rezvani | https://github.com/alirezarezvani/claude-skills (19392f7) |
| mkt-cold-email | marketing-skill/skills/cold-email | MIT, (c) 2025 Alireza Rezvani | same |
| biz-proposal-contract | business-growth/skills/contract-and-proposal-writer | MIT, (c) 2025 Alireza Rezvani | same |
| biz-tender-response | commercial/skills/rfp-responder | MIT, (c) 2025 Alireza Rezvani | same |
| stu-literature-review | research/litreview | MIT, (c) 2025 Alireza Rezvani | same |
| stu-deep-research | research/deep-research | MIT, (c) 2025 Alireza Rezvani | same |
| ent-roast-my-idea | productivity/roast | MIT, (c) 2025 Alireza Rezvani | same |

Apache-2.0 notice: the four Anthropic-derived skills are modified versions (rewritten); the licence text is at the source folder's LICENSE.txt. Not imported: anthropics/skills docx/pdf/pptx/xlsx (source-available, not open source), folders without their own licence file (e.g. doc-coauthoring), and skills needing desktop toolchains.

### One-tap apps (MCP presets; remote services, nothing bundled)
Checked 2026-10-20 with the same steps as `docs/apps-dcr-check.md`: dropbox, buffer, typeform, invideo (sign-in with dynamic registration); godaddy (domain search), coingecko (crypto prices), peek (things to do), mslearn (Microsoft Learn docs) open without sign-in and list their tools.

### Logos
dropbox, buffer, godaddy: Simple Icons 16.35.0 (CC0-1.0, https://simpleicons.org). coingecko, peek, invideo, mslearn: each site's own icon (favicon, 128 px), used only to label the app, like the other pictures in `assets/logos`.

## In-app updates (branch feature/app-update, 2026-10-20, v1.13.51+84)
- No new packages. Uses Android's own DownloadManager and PackageInstaller (via ACTION_VIEW), and packages already in the app (`supabase_flutter`, `shared_preferences`).
- `android_native/AppUpdater.kt` `UpdateFiles` is our own small content provider (same idea as androidx `FileProvider`, Apache-2.0, nothing copied); the dashboard reads the app's version from the file with our own small zip + binary-XML reader (format knowledge only, no code taken).
- R2 switch (2026-10-22, v1.13.53+86): no new packages or borrowed code. Uses Cloudflare Workers' built-in R2 binding API (multipart upload) and the browser's Web Crypto / XMLHttpRequest.


## Prompt understanding and safety (branch feature/prompt-safety, 2026-10-22, v1.13.52+85 to v1.13.58+91)
- No new packages and no copied code. The constraint reader, request recital and identity/safety rule are our own Dart. Ideas only: reciting the goal near the end of the context (Manus "Context Engineering" blog, already credited above) and treating fetched content as data (common prompt-injection guidance, e.g. OWASP Top 10 for LLM Applications, CC BY-SA, ideas only, no text taken). The v1.13.58+91 error scrub adds nothing third-party either.

## Remote APK builds (branch feature/build-apk, 2026-10-22, v1.13.63+96)
No code copied. The workflow templates in `lib/services/apk_build.dart` and `lib/services/code_git.dart` are our own text; they reference these GitHub Actions by tag (run on the user's GitHub, not shipped in the app):

| Action | License | Source | Used for |
|---|---|---|---|
| actions/checkout@v4, actions/setup-java@v4, actions/setup-node@v4, actions/upload-artifact@v4 | MIT | https://github.com/actions | checkout, Java, Node, the APK artifact |
| subosito/flutter-action@v2 | MIT | https://github.com/subosito/flutter-action | Flutter SDK on the runner |
| gradle/actions/setup-gradle@v4 | MIT | https://github.com/gradle/actions | Gradle cache and setup |

Signing uses apksigner/zipalign from the runner's Android SDK build-tools, and the Release step uses the runner's preinstalled `gh` CLI (no third-party release action).

## Bring your own key (branch feat/byok, 2026-11-03, v1.13.118+188)
No new packages and no copied code. Provider presets, model-list parsing and the opencode provider config (`lib/services/byok*.dart`) are our own Dart, written from each provider's public API docs.

### Logos
anthropic, deepseek, googlegemini, lmstudio, mistralai, moonshotai, nvidia, ollama, openai, opencode, openrouter, xai (12 files in `assets/logos/`): Simple Icons (CC0-1.0, https://simpleicons.org, https://github.com/simple-icons/simple-icons), unmodified single-path SVGs, used only to label each provider. Trademarks stay with their owners.
