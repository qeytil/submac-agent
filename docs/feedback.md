# In-app feedback (2026-10-26)

Owner ask: "add feedback feature that the user can write there feedback and attach screenshots then send, that feedback
will reach me in admin dashboard feedback section with the user details".

## App (this PR, branch `feat/feedback`)
- Settings › Help › **Send feedback** opens `FeedbackScreen` (lib/screens/feedback_screen.dart). The old mailto row is
  now "Email us". The drawer has no Help/Settings sub-items, so there is no drawer entry.
- Optional category (Problem / Idea / Other), a required multi-line message (max 5000), up to 5 screenshots from the
  gallery or the camera (the app's existing `image_picker`, quality 85, max 2048 px), thumbnails with a remove button.
- Send: uploads each picture to `feedback-screenshots/<uid>/<feedback id>/`, then inserts one `public.feedback` row with
  app version, build number, device model, OS version and locale. Progress bar + step text, then a "Thank you" state.
- Errors (offline, signed out, daily limit, too big, not a picture, server) show in the screen's words; offline and
  server errors offer **Try again**. A retry never uploads a picture twice (same feedback id, `FeedbackSender` keeps the
  uploaded paths); a picture removed before the retry is deleted after the send.
- The draft (text, category, pictures) is saved in the app's private files (`FileFeedbackDraftStore`) while typing,
  before each send and when the screen closes, and cleared only after a successful send.
- Words: lib/ui/feedback_words.dart (`ft()`), English/Somali/Arabic, own table like BillingCopy/ErrorCopy so the shared
  Strings table is untouched. Somali and Arabic need a native read.
- Device details: `submac/update` → `info` now also returns `manufacturer`, `model`, `release` (android_native/AppUpdater.kt).
  Off Android the OS falls back to `Platform.operatingSystemVersion`.
- Tests: test/feedback_test.dart (sender with a fake backend, error mapping, device row, words coverage, 9 widget tests).

## Server (applied to production 2026-10-26, additive only)
- Migration `supabase/migrations/20261026_feedback.sql`, recorded as `20261026120000 feedback_20261026`.
  Rollback: `supabase/rollback/20261026_feedback_rollback.sql` (empty the bucket through the Storage API first).
- `public.feedback`: user inserts only own rows (status `new`, no admin note, screenshots under `<uid>/`), max 20 per
  24 h, reads own rows; no user update/delete. `on delete cascade` with the auth user.
- Bucket `feedback-screenshots`: private, 5 MB per file, png/jpeg/webp/gif/heic/heif; users insert/select/delete only
  under `<uid>/` (max 50 uploads per 24 h).
- Admin: functions `admin_feedback_list/counts/update` (service_role only) behind the new edge function
  `feedback-admin` (verify_jwt on), which checks the caller's email against `ai_admins` exactly like `ai-admin`, and
  returns rows with email, display name, plan, last device and one-hour signed screenshot links.

## Dashboard (separate PR, branch `feat/feedback-dashboard`)
- tools/proxy-admin: a **Feedback** tab with an unread badge, status filter, newest first, screenshots (click to
  enlarge), user details, Mark read / Resolve / Reopen and an admin note. worker.mjs CSP allows `img-src https://*.supabase.co`
  for the signed links. Needs a Worker redeploy (wrangler) to go live; it does not depend on the app merge.

## Known follow-ups
- `account-delete` does not wipe `feedback-screenshots/<uid>/` yet (rows cascade; the files would stay). One line:
  add "feedback-screenshots" to the bucket list on the `wipeFolder` line, then redeploy account-delete.
