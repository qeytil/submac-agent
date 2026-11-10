# First-launch intro, agreement on the sign-in screen, sign-in to chat (2026-10-26)

Owner ask: "the first time app launch we want Animation drawing Telesia then our logo with professional clean intro style,
then the login and the age consent should be in the auth screen not seperate after auth, and after auth, smooth animation
should open chat screen" + "That drawing intro should have smooth satisfying sound with haptic, not ropotic, smooth modern
sound effect".

## Intro (lib/screens/intro_screen.dart, timeline in lib/ui/intro_motion.dart)
- Plays once per install, only when nobody is signed in (`shouldShowIntro`). Flag `intro_seen_v1` (SharedPreferences),
  set on finish or skip; read in main() before the first frame, so later cold starts never wait. Someone updating the
  app while signed in never sees it (flag set quietly).
- White page. 0–1500 ms "Telesia" revealed left to right by a soft mask with a thin #86c0f3 pen line on the edge;
  1500–1800 the word fades/shrinks; 1700–2200 the logo tile scales 0.82→1 and fades in; 2200–2450 the white dot drops
  in and settles (impact at 2295); hold; 3000 ms done; 600 ms hand-over to sign-in. Tap anywhere to skip.
- Logo: assets/intro/telesia_tile.svg (the new 1024 logo without its dot, via flutter_svg); the dot is painted in code
  so it lands last.
- Remove animations: the finished logo fades in (900 ms total), one selection tick, no sound.
- Haptics: `HapticFeedback.selectionClick` as the reveal passes each of the 6 letters, one `mediumImpact` when the dot lands.
- Sound: assets/intro/intro_sound.m4a (3.3 s, AAC 64 kb/s mono, 27 KB, -17.5 LUFS, true peak about -5 dBFS, nothing
  above 4 kHz), synthesized by tools/intro_sound.py (no samples, no licence). Revised 2026-10-26 after the owner's
  listen ("the starting whoosh seems slobby"): the noise whoosh and shimmer are gone. Instead, one soft rounded pluck
  per letter, on the haptic ticks (IntroMotion.ticks(): 0.302, 0.520, 0.677, 0.823, 0.980, 1.198 s), rising A4 B4 C#5
  E5 F#5 A5 (sine + a little 2nd harmonic, 3 ms attack, ~150 ms exponential decay, about 12 dB under the chime,
  velocity rising across the word); then the warm A4 and E5 bloom (unchanged) at 1.75 s and 2.30 s, low pad, short reverb.
  Played with **audioplayers 6.8.1 (new dependency)**: Android usage `assistanceSonification` / content `sonification`
  (system stream, so silent/vibrate mutes it) with `gainTransientMayDuck` focus (music ducks briefly, never stops);
  iOS `ambient` category (mixes, follows the mute switch). Any load/play error is swallowed; skip stops it at once.

## Agreement on the sign-in screen (lib/screens/auth_screen.dart, lib/main.dart)
- Before: Supabase auth `user_metadata` `{consent_v: 2, age_18: true, consent_at: ISO-UTC}` (`AuthRules.consentData`),
  written by `signUp(data:)` for email sign-ups and by `updateUser(data:)` on the separate post-sign-in ConsentScreen
  (Google sign-ins, older accounts, new consentVersion). `AuthRules.hasConsent` gated the app. No DB column or RPC.
- Now: the same tick (same words, same Terms/Privacy links, now in en/so/ar) is on the welcome page and on the log-in
  and sign-up forms. Google, Continue (log in / sign up) and Forgot password are off until it is ticked; the tick
  carries across the pages. Pressing one of them remembers the tick (`ConsentPending`, prefs `consent_ticked_at`,
  24 h) so it survives the Google browser trip and an app restart during email verification.
- After sign-in (`gateStep`): already agreed → chat (never asked again); not agreed + ticked here → `ConsentRecorder`
  saves `AuthRules.consentData()` with the same `updateUser(data:)` write, showing only the logo (error → Try again /
  Sign out); not agreed + not ticked here (only a session kept from an older version) → the sign-in screen's own
  agreement view (`AuthScreen(confirmOnly: true)`, "Agree and continue", same write). ConsentScreen is removed.
- Email sign-up still sends the agreement in `signUp(data:)`.

## Sign-in to chat
`GateSwitch` (AnimatedSwitcher) fades the new page in while it settles from 0.97 scale over 600 ms (ease in-out);
the old page fades out. Used between every auth state (sign-in, verify, saving, chat) and for intro → sign-in.
Remove animations: instant switch.

## Tests
test/intro_auth_flow_test.dart (18): first launch only + flag, timeline haptics (6 ticks, 1 impact at the landing)
through the platform channel, sound play at start and stop on skip (fake IntroSound), failing sound, reduce motion,
auth buttons off until ticked (Google, log in, forgot, sign up), en/so/ar sentence keeps both links, gate steps,
consent saved with the same fields, retry on failure, tick expiry, fade+scale to chat.
