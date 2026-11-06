# Media providers

Owner request (2026-11-04): "add media generation provider configuration, so a bot or the agent can use that if I
say use, because now the provider configuration is only for chat completion".

Shipped in 1.13.132+202 (branch feat/media-providers-2, ported from feat/media-providers onto main eb108db).

## What the user sees

Settings → **Media models** (`lib/screens/media_models_screen.dart`). One section per capability:

| Capability | `MediaKind` | Examples |
|---|---|---|
| Images | `image` | OpenAI gpt-image-1, Gemini (Nano Banana), OpenRouter, fal.ai FLUX, Replicate, Stability, xAI Grok Imagine, Together FLUX, any OpenAI-compatible images server |
| Video | `video` | Gemini Omni Flash, Google Veo (long-running), OpenAI Sora, xAI video, fal.ai Kling, Replicate, Runway, OpenAI-compatible video |
| Speech | `speech` | OpenAI TTS, ElevenLabs, Gemini TTS, OpenAI-compatible speech |
| Music & sound | `audio` | ElevenLabs sound effects and music, fal.ai stable-audio, Replicate music |

Each provider has a name, base URL, model, optional voice/size, its key, and can be the default for its capability.
"Test" makes one small call and reports the provider's own error line (never the key).

## Where things live

- `lib/services/media_providers.dart`: `MediaKind`, `MediaWire` (the wire protocol per vendor), `MediaPresets`, `MediaProvider`, `MediaProviderStore` (config in prefs, ids `media-<4..24 [a-z0-9]>`).
- Keys: the phone's encrypted storage, one entry per key, apart from the config. A provider may borrow the key of a BYOK chat provider (`MediaPresets.byokPresetsFor`) or of another media provider of the same vendor.
- `lib/services/media_gen.dart`: builds each request, polls long jobs (Veo, Sora, fal queue, Replicate, Runway, xAI), downloads results and saves them. Calls go straight from the phone to the provider: nothing passes SubMac's servers and nothing is billed by SubMac.
- Tool: `media_generate` (definitions from `MediaGen.definitions`), offered to the agent and to bots only when the user has a provider for that capability. `generate_image` falls back to the user's image provider when the server has no picture model (no `submac-image` route).
- Output folder: owner chats → `media/`; a bot's private chat → its own folder; team work → the team's folder (`_mediaFolder` in tool_router.dart). Results come back as cards in the calling chat (`media_cards.dart`).
- A stopped turn (Stop, or team work ended) ends long jobs (`_callerStopped`); progress shows on the chat's working line.

## Tests

`test/media_providers_test.dart` (41 tests): each wire protocol against a mock HTTP client, polling, key borrowing,
id pattern, error lines without the key, shape/ratio helpers (the `WxH` / `W:H` regex fix in `media_gen.dart`).

## Not done

- No device check yet: add one provider per capability on the phone and ask the agent and a bot to "use" it.
- Server-side picture route (`submac-image`) still off; needs the owner's OK (DB rows only).
