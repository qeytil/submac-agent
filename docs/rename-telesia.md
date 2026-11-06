# Rename: SubMac → Telesia

Owner chose the name **Telesia** on 2026-11-05 (from *telos*, getting things done). This file is the plan and the
state of the rename. Nothing is deployed and no DNS is changed without the owner's OK each time.
submac.site belongs to another project now: never touch its worker, routes or DNS.

## Layers

| Layer | What | State |
|---|---|---|
| R1 | Every user-visible word "SubMac" in the app → "Telesia": screens, notifications, Android labels (launcher, widget, a11y service), the assistant's own name line, i18n (Somali, Arabic), Kotlin strings, MCP/OAuth client name | Done on branch `feat/telesia` (script `telesia_rename.py`, whole word, code lines only). Not merged: waits for the owner (see decisions) |
| R2 | Web pages (Terms, Privacy, bot share `/b/<code>`, invite `/download`, assetlinks) on a new Cloudflare Worker, brand Telesia | Source on `feat/store-host` (BRAND = Telesia, placeholder base `https://telesia.submac-owner.workers.dev`). Not deployed |
| R3 | Logo, wordmark, launcher icon, intro animation, notification icon | Not started: needs a Telesia logo from the owner (the intro draws the word letter by letter, tuned for 6 letters; Telesia has 7) |
| R4 | Wake word "Hello SubMac" → "Hello Telesia" | Not started: Vosk only knows dictionary words, so the phrase must be re-chosen and tested on clips like the 112-clip set used for "sub mac" (WakeService.kt) |
| R5 | Server side: ai-chat house rules and bot-run prompts still say SubMac; rewards SQL `invite_link` names submac.site | Needs owner approval (edge function deploy, SQL) |
| R6 | Store listing, release names in apk.yml ("SubMac Agent x.y.z") | After R1–R3 |

## Kept on purpose (changing them breaks installs or saved data)

- Android package `com.submac.agent` and the signing key: a new package id is a new app (no update path, data lost).
- The `submac://` link scheme, the model alias `submac`, tool prefix `submac_`, prefs keys, Kotlin class names (SubMacApp, SubMacA11y), notification channel ids.
- User-Agent strings (`SubMacAgent/1.6`).
- Files already saved under `Download/SubMac`: new saves go to `Download/Telesia`.
- Chats already titled "SubMac team" keep their title; new ones are called "Telesia team".

## Domain

RDAP on 2026-11-06 11:20 +03:30: telesia.app, telesia.ai, telesia.io unregistered; telesia.com registered by someone
else. Do not point the app at telesia.app until the owner has bought it (an unowned domain in assetlinks and share
links could be taken by anyone).

## Owner decisions needed

1. Buy telesia.app (or pick another domain), or stay on the free `telesia.submac-owner.workers.dev` for now.
2. Support email (the app and worker still say contact@submac.site).
3. Review the rewritten Terms and Privacy text in `web/worker/app-web.js` (the original text was lost).
4. Rewards SQL: new `invite_link` base for invites.
5. Merge R1 now (app says Telesia with the old logo and "Hello SubMac" wake word) or wait for R3/R4.
6. A Telesia logo/wordmark (R3) and a wake phrase to test (R4).
