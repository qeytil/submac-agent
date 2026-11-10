# Site publishing (v1.13.37+70, branch feature/site-publish)

Owner request 2026-10-20: sites Telesia builds get an easy in-app preview and one-tap publishing, frictionless for non-technical users, no features that don't work.

## What the user sees
- **Preview**: any .html opens in `SitePreviewScreen` (Phone / Tablet / Computer width, Reload, zoom) with a **Publish** button (Update once live) and the live link + days left.
- **Page card** in chat: Open · **Publish** · Share.
- **Publish sheet** (`showPublishSheet`): two choices, the choice is remembered per site.
  - **Free Telesia link**: `https://<slug>.telesia-sites.pages.dev`, no sign-up, 7 days from the first publish (re-publishing updates the same link and keeps the date; after it ends, Publish again starts a new 7 days). Branch previews carry `x-robots-tag: noindex`.
  - **Your Vercel**: one-tap Vercel sign-in (existing MCP preset `mcp.vercel.com`) if not connected, then the app reads the site files and calls the connection's `deploy_to_vercel` (target production, project name from the title) and waits for READY (get_deployment). Domain is managed in Vercel.
  - Ends on "Your site is online": Open, Copy link, Share.
- **Your sites** (Files > globe icon): every site, status line ("Free link · 6 days left", "On your Vercel", "Free link ended"), Preview / Open / Share / Update / Make it a project / Take the free link down / Remove.
- **Make it a project**: after a site's 3rd publish, if its chat is not in a project, one sheet offers it once ("Make it a project" / "Not now"). Yes = new project named after the site, chat assigned, top-level site files copied into project files.
- Agent prompt (```page guide): tells the user to tap Publish, never invents a link, keeps the same `<title>` on edits (a changed page from chat is a new file; same title in the pages folder = same site, same address), and asks to connect Supabase only when the site must store data.

## Files
- `lib/services/sites.dart`: Site model + registry (SharedPreferences `sites_v1`), file collection (page alone in pages/ or workspace goes up as index.html; a page in its own folder goes up with the folder; max 60 files / 5 MB), free link calls, Vercel deploy, project offer.
- `lib/screens/site_screens.dart`: SitePreviewScreen, publish sheet, project offer, SitesScreen.
- `supabase/functions/site-preview/index.ts`: publish / remove / list for signed-in users, daily sweep. Pages Direct Upload (upload-token, check-missing, upload, upsert-hashes, deployment with manifest + branch). Limits: 3 live free links per person, 30 publishes/day, 60 files, 5 MB, index.html required, safe paths only.
- `supabase/migrations/20261020_site_previews.sql`: `site_previews` (own-row read RLS, no client writes), `site_preview_log`, cron `site-preview-sweep` 02:20 UTC (reuses bot_run_anon_key + bot_run_secret).

## Live infrastructure (done 2026-10-20)
- Cloudflare Pages project `telesia-sites` (account b98ff27c…, production branch main, unused).
- Supabase secrets `CF_PAGES_TOKEN`, `CF_ACCOUNT_ID` on moeemacbvsueekuvfjbo; function `site-preview` deployed (verify_jwt on); migration applied.
- Server test: publish → 200 at the link with noindex, re-publish same link with new content, remove → 404, sweep auth OK. Test rows removed.

## Not tested yet
- The app build on a real phone (Flutter can't run in Hark's sandbox; Dev check via workflow_dispatch on the branch).
- Vercel path end to end with a real Vercel account (file format is read from the connection's own tool schema; binary files need an `encoding` field there, otherwise the sheet suggests the free link).

## Later
- A `publish_site` agent tool (voice: "put it online").
- Own domains on Telesia hosting (Cloudflare for SaaS on a separate domain), Cloudflare/Netlify as hosts once a reliable upload path exists.
