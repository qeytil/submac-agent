# Flutter 3.47.8 upgrade (v1.13.99+169)

Why: Genkit Dart 1.0 (the new on-device agent core) needs Dart ^3.12. Flutter 3.47.8 (Dart 3.13.7, 2026-10-23) is the
latest stable and satisfies it. No product behaviour changes are intended in this PR.

## Toolchain
- All workflows: `flutter-version: '3.47.8'` (analyze-only, dev-check, build-apk, grok-bots-check, qa-emulator, reel). Java 17 unchanged.
- `flutter create` now makes a Kotlin-DSL Android project (its template asks for AGP 9.1 / Gradle 9.3 / Kotlin 2.4).
  flutter_inappwebview_android 1.1.3 (the browser agent's WebView, newest stable) does not build on AGP 9
  (`proguard-android.txt` is refused), so `patch_android.py` pins the newest AGP 8 line instead:
  **AGP 8.13.0, Gradle 8.14.3, Kotlin 2.2.20** (was AGP 8.1). Move to AGP 9 once the WebView plugin ships a stable fix.
- `tools/patch_android.py` patches `app/build.gradle.kts` (still handles the old Groovy file):
  pinned SubMac signing key, minSdk 24, targetSdk 34 (unchanged), compileSdk = Flutter's default (was 35),
  ABI filters, vosk + jna, compressed native libs (`useLegacyPackaging`, same APK layout as before).
- Gradle memory back to the old budget (`-Xmx4G`, Kotlin daemon 2 GB): the 3.47 template's 8 GB (inherited by the Kotlin
  daemon) swapped the 16 GB CI runner and the build hung. Build APK steps now have a 40 min timeout and log memory once a minute.
- `tools/verify_apk.sh` (manifest, pinned signature, zipalign 16 KB, ELF 16 KB) is unchanged and still runs STRICT in dev-check/build-apk.

## Packages
- SDK constraint `>=3.12.0 <4.0.0`. The old `dependency_overrides` for 3.24.5/AGP 8.1 are gone; one new one:
  `permission_handler_android: 13.0.1`. permission_handler 13 / android 14 need compileSdk 37 (unsupported on AGP 8.13) and
  android 13.0.2 uses Android 17's `ACCESS_LOCAL_NETWORK`, so the app takes **permission_handler 12.0.1 + android 13.0.1** (was 11.3.1).
- Library modules compile against at least SDK 36 (`patch_android.py` raises older ones, e.g. flutter_pcm_sound's 33; never lowers).
- Bumped: speech_to_text 7, record 7, share_plus 12, file_picker 11, firebase_core 4 / messaging 16,
  google_mlkit_text_recognition 0.17, archive 4, syncfusion_flutter_pdf 33, video_player 2.14, image 4.12, flutter_svg 2.3,
  supabase_flutter 2.18, flutter_lints 6, and minor bumps for the rest.
- flutter_secure_storage goes to **10.x, not 11**: 11 drops the EncryptedSharedPreferences reader, so a direct 9→11 jump would
  lose saved keys and logins. 10 migrates them. `encryptedSharedPreferences: true` stays (with an ignore) until every phone ran a v10 build.

## Code changes (mechanical)
- `FilePicker.platform.pickFiles` → `FilePicker.pickFiles`; `DialogTheme`/`CardTheme` → `…ThemeData`.
- Deprecations: `withOpacity` → `withValues(alpha:)`, `Share.*` → `SharePlus.instance.share(ShareParams…)`,
  `onPopInvoked` → `onPopInvokedWithResult`, speech `listen` options → `SpeechListenOptions`, Matrix4 `translateByDouble/scaleByDouble`,
  `Color.opacity/alpha` → `.a`, Supabase `anonKey` → `publishableKey` (same key value).
- Left as is (with ignore): RadioListTile `groupValue/onChanged` (RadioGroup would change the row), FCM `getToken/onTokenRefresh` are not deprecated in 16.x.

## Phone tests
See the PR description.
