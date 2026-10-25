# Your own AI models from chat (v1.13.91+158)

Owner request 2026-10-24: the agent calls AI models the user brings (base URL + API key), makes media with
them and shows the results as smooth cards. Owner change 12:01: no Settings screen; it all works from chat.

## How it works
- The user writes e.g. "use this provider: base URL https://api.example.com/v1, key sk-…, model flux-pro, make a picture of …".
- Before the message is saved or synced, `AiKeys.redact` (lib/services/ai_keys.dart) moves every API key to the
  phone's encrypted storage (flutter_secure_storage) and replaces it with `[API key hidden key_ref:xxxxxxxxxx]`.
  The model only ever sees the reference; `ai_call` looks the key up on the phone. Keys are scrubbed from every
  error and reply. A key typed on another phone is not on this one: the agent asks for it again.
- Tools (lib/services/ai_models.dart, media tool group):
  - `ai_call`: task text / image / image_edit / speech / transcribe / embed / video (OpenAI-compatible default
    paths) or custom / music (any path + payload + headers; auth header, scheme or URL parameter configurable).
    Async jobs are detected and polled (Replicate `urls.get`, fal `status_url`/`response_url`, BFL `polling_url`,
    OpenAI `/videos/{id}` + `/content`, Google operations, `Location` header, or a `poll_path` template).
    429 waits out Retry-After (≤30 s, twice); one 5xx retry; clear plain-language errors (401/402/404/429/5xx).
    Results (base64, data: URLs, media URLs, binary replies) are saved to `workspace/media/ai_*` and returned as
    `MEDIA_CARD {json}` (kind image / images / audio / video / file(s), files, model, prompt, provider).
    Output links on other hosts are fetched without the key.
  - `ai_providers`: list / save (only after the user says yes) / forget / models (GET /models) / test.
- Calls go straight from the phone to the provider. No SubMac server, no SubMac billing.

## Cards (lib/widgets/media_cards.dart, lib/widgets/media_lightbox.dart)
Styled from a study of hark.com (2026-10-24):
- While it works: one faded status pill in the reply column whose short phrase changes in place
  ("Creating an image" / "Creating your video" / "Waiting in line" → "Getting a file ready"). No spinner, no
  skeleton, no percentages or timers (as Hark).
  The result crossfades in where the pill was (chat entrance: fade + small rise).
- Generated picture: bare, about 288 wide, soft corners (12), no frame, no caption. A set of pictures: a small fanned stack, tiles turned
  ±2–4° and overlapping. Sound: a light chip (speaker glyph, file name, size), no inline player (as Hark).
  Video: a 16:9 frame (the model's still as poster when it sends one, e.g. OpenAI thumbnail) on the chat's card fill (radius 20, no border, no shadow) with an outlined play glyph and one
  quiet rounded-square corner action (More). Files: document tiles.
- Tap: a frosted full-screen view (chat blurred and dimmed behind), picture centred with soft corners, pinch zoom,
  round Close at the top start, the file name centred, Share + a Download pill at the top end (saves to the phone), round chevrons beside the picture for a set.
  Video/sound show the file name as the only title and play with the phone's own controls (sound in a centred pill).
- Hold (or More): View / Make it again / Variations (pictures) / Save to phone / Share. The prompt and model are in
  the accessibility label, not on the card (Hark shows no captions).
- Built from the stored tool result, so cards persist, sync and render in history. Reduced motion and RTL respected.

## Known limits
- Video plays full screen (no inline player: no video plugin in the app); no poster frame unless a picture comes back.
- Music has no standard API: the agent needs the provider's path and payload.

## Not in this PR (from the same study)
- Website build card (multi-phase pill → "Open page" card with live preview), product grid, link deck, email/summary/code
  and calendar cards: they belong to the chat/page card system other branches are changing (fix/media-preview,
  approval cards, design skills), so they are left for a follow-up to avoid two workers on one file.
