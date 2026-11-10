# Telesia

Agentic chat app (Android first, iOS later) built with Flutter. Version **1.4.0**.

- ChatGPT-style UX: sidebar history, model picker, streaming replies, attachments, custom instructions, Live voice.
- Replies: a short answer first, then cards (summary, draft, links, plan, choices, table, photos, images, receipt with Undo, confirm, file, code with Run). Cards render only when complete, with a shimmer placeholder and a soft spring fade-in.
- Agent tools (on-device): shell, files, Trash, fetch page, images, web search (DuckDuckGo, optional Brave/Tavily key), weather (Open-Meteo), Wikipedia, currency (open.er-api.com), maps (Nominatim), RSS, YouTube transcripts, memory (remember/forget), phone actions via Android intents (alarm, timer, calendar, call/SMS drafts, open link/app, share), text in photos (ML Kit OCR), PDF text.
- Connectors: any MCP server over Streamable HTTP (Composio preset with `x-consumer-api-key`), GitHub and Notion tokens. Risky actions ask first in Ask mode.
- Any OpenAI-compatible provider (OpenAI, OpenRouter, Groq, Gemini, DeepSeek, Together, Ollama…) with optional per-provider limits (RPM/TPM/RPD), automatic waiting and retry, and a backup model. API keys stay encrypted on device.
- Share to Telesia from any app; Files screen for Telesia files and phone storage.
- Supabase: email auth, chats/messages/settings/memories in Postgres with RLS, attachments in the private `attachments` bucket.
- CI: every push to `main` builds a signed release APK (Actions artifact + GitHub Release). Android native bridge lives in `android_native/MainActivity.kt` and is copied in by CI.

Supabase project ref: `moeemacbvsueekuvfjbo` (eu-central-1). Schema: `supabase/schema.sql` + `supabase/migrations/`.
