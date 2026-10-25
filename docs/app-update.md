# In-app updates (branch `feature/app-update`)

> **Since v1.13.53+86 (2026-10-22; current branch build 1.13.56+89) new updates are ONE file in Cloudflare R2.** See "Storage: Cloudflare R2" below.
> The Supabase parts path described further down is kept only for releases saved before the switch.

People on an older SubMac see an update window as soon as the owner publishes a newer build in the dashboard.
The download runs in Android's own downloader (it keeps going when they leave the app), the window shows the
progress, and Install opens Android's installer. A required update blocks the app until it is installed.

## How the owner publishes an update

1. Build the app as usual (the `app-release.apk` from the Dev check or release workflow). It must be signed with
   the pinned SubMac key (the workflows enforce this), and its build number (`+NN` in pubspec) must be higher
   than the last published one. Phones only offer a higher build.
2. Open the dashboard (Worker `submac-proxy-admin`), sign in, tab **Updates**.
3. **Pick the file.** The dashboard reads the version and build straight from inside the file (it also checks the
   app is `com.submac.agent`) and computes the file's sha256 check. If it cannot read them it falls back to the file
   name (`1.13.51+84`), or you type them.
4. **What's new**: a few plain lines. People see this in the window (it scrolls if long).
   The file then goes to Cloudflare R2 through the dashboard in 32 MiB pieces and is stored as one file.
5. **When does it become required?**
   - **Now**: everyone on an older version gets a full-screen "Please update SubMac" with only Download / Install.
   - **From (date and time)**: until then people may tap Later (the window comes back on every start); from then on
     it becomes the full-screen block. The time is in your browser's time zone (shown under the picker).
   - **Never**: people may always skip (the window still comes back on every start).
6. Leave **Publish right away** ticked (or untick to save a draft and publish later from the list) and press
   **Upload and save**. The progress bar shows the upload; a toast says "Published".
7. The list shows every release (draft / published, required state, size). **Edit** changes what's new and the
   required time, **Unpublish** stops offering a build, **Delete** removes it and its file. "Devices by app
   version" shows how many phones run each version (from `user_devices.app_version`).

Rules the phone follows:
- It offers the newest **published** build above its own build number.
- If several newer builds are published, the **earliest required time among them** applies. So a required fix
  stays required even after you publish a newer optional build on top of it.
- Required is decided on the server's clock (the phone's clock is only used to count time since the last check),
  so moving the phone's clock back does not skip a required update.

## Storage: Cloudflare R2 (since 2026-10-22, v1.13.53+86)

Why: this Supabase plan caps one stored file at 50 MB, so builds had to be split into parts and joined on the
phone. R2 has no such cap, so a release is now one public file and the phone downloads it in one go.

- **Bucket** `submac-app-updates` on Cloudflare account b98ff27cdcd4696b015f93a601bcdcda (only for app updates;
  the website bucket `submac-downloads` and submac.site are untouched). Public base
  `https://pub-f8ebeb9291264a2d873d45061a442de0.r2.dev`, stored in `ai_settings.app_updates_public_base`.
  The bucket's location came back as **WNAM** (western North America), even though most users are in East Africa;
  Cloudflare serves the public URL from its edge, but the first byte of an uncached file comes from WNAM.
- **Use a custom domain for production.** `r2.dev` addresses are meant for development: Cloudflare rate-limits
  them and they get no caching. Connect a domain (for example `updates.<domain>`) to the bucket in Cloudflare, then
  change `ai_settings.app_updates_public_base` (and nothing else; the `file_url` check accepts any https host).
  Releases saved before the change keep their old address, so re-publish them or leave r2.dev on.
- **Dashboard Worker** `submac-proxy-admin` (`tools/proxy-admin/worker.mjs`) has an R2 binding `UPDATES` and
  admin-only routes. Every call forwards the caller's own bearer to ai-admin `me`; anyone else gets 403.
  - `POST /api/updates/start` `{version_code, size_bytes}` → `{key, upload_id, part_size, parts}`. The key is
    `android/<build>-<8 hex>/SubMac-<build>.apk`.
  - `PUT /api/updates/part?key&upload_id&n` body = one part of exactly 32 MiB (the last may be smaller), streamed
    straight into R2 → `{partNumber, etag}`.
  - `POST /api/updates/complete` `{key, upload_id, parts}` → `{key, size}`; `abort` `{key, upload_id}`.
  - `POST /api/updates/delete_file` `{key}`: an upload that never became a release (refused with 409 when a
    release still points at it).
  - `POST /api/updates/delete_release` `{id}`: ai-admin deletes the row and returns the R2 key; the Worker deletes
    the object.
- **ai-admin** `release_create` with `storage:'r2'` and `file_key`: checks the key pattern and that the build in
  the key equals the release's build, then HEADs the public URL and requires its size to equal `size_bytes`. The
  row gets `storage='r2'`, `file_url`, `file_key`; `apk_path` is the file's folder and `parts` is the one file, so
  the table's existing checks hold. `release_delete` returns `{storage, file_key}`. All other actions unchanged;
  verify_jwt still on.
- **Dashboard Updates tab** uploads through the Worker (XHR per part, so the progress bar moves; a part is retried
  once; a fresh sign-in is read for every part), computes the sha256 in the browser, then calls `release_create`.
  If anything fails it aborts the upload (or deletes the finished file). Delete goes through the Worker. The list
  shows "one file" for R2 releases and "N parts" for old ones.
- **Phone**: `Release.storage` / `Release.fileUrl`; for `r2` the download is the single `fileUrl`, otherwise the
  Supabase parts as before. `AppUpdater.kt`: with one part it checks the sha256 where the file landed and renames
  it (no copy); several parts are still joined. A 1.13.51+84 build (parts only) would try the R2 key as a Supabase
  path and fail the check; that build was never released to users.
- Migration `supabase/migrations/20261021_app_releases_r2.sql` (additive, applied): `storage`, `file_url`,
  `file_key`, checks, the public-base setting and `latest_release()` returning `storage` and `file_url`.

## How it works (original Supabase parts path; still used for old releases)

Server (Supabase `moeemacbvsueekuvfjbo`, migration `supabase/migrations/20261020_app_releases.sql`, additive):
- Table `app_releases` (version_code unique, version_name, notes, apk_path = upload folder, parts, size_bytes,
  sha256, required_at null = never / <= now = required, published, published_at, created_by, timestamps).
  RLS on, no grants to anon/authenticated: nobody reads or writes it with an app key.
- `latest_release(p_current_code int)` (security definer, anon + authenticated): newest published release above the
  given build, with `required_at` = the earliest deadline of all newer published releases, plus `server_now`.
  Returns `{update:false, server_now}` when there is nothing newer.
- `admin_app_versions()` (service role only): devices per app version for the dashboard.
- Public bucket `app-updates` (Supabase Storage, not the website's R2 / submac.site). Anyone can download by URL.
  Restrictive policies block insert/update/delete with anon or signed-in user keys; uploads only go through signed
  upload URLs that `ai-admin` creates for admins (`ai_admins`).
- **Parts**: this Supabase plan caps one stored file at 50 MB and the app is ~63 MB, so the dashboard uploads the
  file in parts of at most 40 MiB (`android/<build>-<random>/part-00.bin`, `part-01.bin`, …). The phone downloads
  all parts and joins them in order, then checks the sha256 of the whole file. Up to 20 parts (800 MB).
- `ai-admin` actions (new; every existing action unchanged, verify_jwt on): `releases_list`, `release_upload_url`
  (`{version_code, parts}` → one signed URL per part), `release_create` (checks every part is really in the bucket
  with the measured size), `release_edit` (`notes`, `version_name`, `required_at`: `"now"`, ISO time or null),
  `release_publish`, `release_unpublish`, `release_delete` (row + files), `release_file_delete` (an upload that
  never became a release).

App:
- `lib/services/update_logic.dart`: pure logic (version compare, forced by time, state machine
  idle → downloading → downloaded → installing, cancelled as the way back, when the window shows). Tests in
  `test/app_update_test.dart`.
- `lib/services/updater.dart`: `Updater.I`. Checks on every cold start, on resume (at most every 30 minutes) and
  from Settings > App update > Check now. Compares the build number Android reports for the installed app.
  Saves the release and the state (SharedPreferences `app_update_v1`), so an offline start still shows a required
  update, and a restart shows progress or Install straight away.
- `lib/widgets/update_window.dart`: `UpdateLayer` (over every screen, from `MaterialApp.builder` in `main.dart`):
  optional = a card over the dimmed app with Download / Later, Cancel download / Keep going in the background,
  Install / Later; required = a full screen with only Download / Install (and Cancel download while downloading).
  `AppUpdateTile` + `AppUpdateScreen` in Settings (section "SubMac"): this version, Check now, and the same panel.
  English and Somali words (Somali when the reply language is Somali; the app has no other UI translations).
- `android_native/AppUpdater.kt` (channel `submac/update`):
  - `start`: removes old files, hands every part to Android's DownloadManager (to the app's own external files
    folder `updates/`, no storage permission; Android shows its download notification; continues after leaving
    or closing the app).
  - `status`: progress across parts; when all are in, joins them, checks sha256, deletes the parts; a mismatch
    deletes everything (`bad`). `UpdateDone` (manifest receiver for DOWNLOAD_COMPLETE) does the same when SubMac is
    closed and posts "Your SubMac update is ready. Tap to install."
  - `install`: checks sha256 again, then opens Android's installer with `ACTION_VIEW` through the `UpdateFiles`
    content provider (`com.submac.agent.updates`, not exported, one-time read grant; same job as androidx
    FileProvider without adding a dependency). If "Install unknown apps" is off for SubMac it answers
    `needs_permission`; the window explains the switch and opens it, and Install continues by itself on return.
  - `cancel`: removes the downloads and every file. Also used once the phone runs the new build (the file is
    deleted on the first start after updating).
  - Tells Dart when the SubMac screen is freshly opened (the engine can outlive the screen), so the window shows
    again on every start even when Android kept SubMac in memory.
- `tools/patch_android.py`: adds `REQUEST_INSTALL_PACKAGES`, the `UpdateFiles` provider and the `UpdateDone`
  receiver to the manifest.
- No new packages.

## Settings > App update screen (redesigned 2026-10-22, v1.13.56+89)

Same look as the other Settings pages (rounded `sheet` cards with a thin border, small-caps section titles, the serif
page title, light and dark). `AppUpdateScreen` feeds `AppUpdateView` (pure, drawn from `AppUpdateViewData`):
- Header card: logo, "SubMac", this version, and ONE status line with a dot: Up to date / Update available · X /
  Downloading N% / Ready to install / Installing… / Couldn't check right now / See if a newer version is out.
  While downloading, a slim progress bar and "x MB / y MB" sit inside the same card.
- One primary button for the moment: Check for updates → Download · size → (downloading: only a quiet Cancel
  download) → Install; Open settings when Android's "Install unknown apps" switch is needed (explained in its card).
- "What's new" card with wrapped text, then "Details" (version, size, required-from time).
- No addresses, ids, file checks or raw errors are shown; English and Somali words as before.
- Tests: `test/app_update_screen_test.dart` (8 states × 320 dp and 430 dp × light/dark: no overflow, no raw text,
  at most one primary button; status/buttons per state; Somali; note wrapping; button actions).
  `flutter test --update-goldens test/app_update_screen_test.dart` writes screenshots to `test/goldens/`
  (not compared in CI). A few are committed as reference.

## Phone test steps

Prepare two builds signed with the SubMac key: A (this branch, e.g. 1.13.51+84) installed on the phone, and B
with a higher build (bump pubspec and AppConfig.version, run Dev check, download the APK artifact).

1. Install A. Open Settings > App update: shows "This version 1.13.51"; Check now says "You're up to date".
2. Dashboard > Updates: pick B, What's new "Test update", Required **Never**, Publish. Close SubMac fully and open
   it: the update window appears (version, size, what's new, Download / Later).
3. Tap Later: the window goes. Close SubMac (swipe it away) and open it: the window is back.
4. Tap Download: progress moves; Android's notification shows the download. Press Home, wait, come back: progress
   continued (or Install is waiting). Lock the phone during the download: it still finishes.
5. Start again, tap Cancel download: the download stops, the notification goes, the window shows Download again.
   Download again works.
6. Let it finish, tap Later, close SubMac, open it: the window offers **Install** at once (no new download).
7. Tap Install with "Install unknown apps" off for SubMac: the window explains it; Open settings, switch it on,
   go back: Android's installer opens. Cancel the installer: back in SubMac, Install is offered again.
8. Install: the app updates and opens on B; no window; Settings > App update shows B. (The update file is deleted
   on that first start.)
9. Forced: reinstall A (or publish C above B and stay on B). In the dashboard, Edit the release → Required **Now**.
   Close and open SubMac: full-screen "Please update SubMac", no Later, no way into the app; back button does
   not reveal it. Download → Install works from there.
10. Required later: Edit → From = 3 minutes from now. Open SubMac: Later is shown with "Required from …". Wait past
    the time with the app open: within ~30 s the window turns into the full-screen block.
11. Somali: Settings > Reply language Somali → window and Settings entry in Somali.
12. Clean up: Unpublish or Delete the test releases in the dashboard.

## Limits

- Android only (iOS has no in-app install; the window never shows there).
- New updates go to R2 as one file (no 50 MB cap). The r2.dev address is rate-limited and uncached: switch to a
  custom domain before a wide release. The bucket sits in WNAM.
- A Worker request body is capped (100 MB on this plan), which is why parts are 32 MiB; at most 40 parts (1.25 GiB).
- Old Supabase-parts releases still work and are still deleted from Supabase Storage by ai-admin.
- The build number must go up for every published update; phones ignore equal or lower builds (no downgrades).
- The full-screen block is drawn over the app; it does not stop background work that was already running
  (bots, wake word) until the user updates.
- Users who removed SubMac's download from Android's Downloads app see "The download stopped" and can download again.
- HyperOS/MIUI may show their own "Install unknown apps" wording or an extra security scan before installing.
- Not phone-tested yet (no device in this run); the Kotlin side is compiled and checked by the Dev check build.
