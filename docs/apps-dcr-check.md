# Sign-in apps: dynamic registration check (2026-10-18)

Plan 4 step 2 asks to test every one-tap MCP preset in `lib/services/mcp_oauth.dart` before launch.
Method (from a server, same steps the phone takes): POST `initialize` without a token, read the 401 `WWW-Authenticate` resource metadata,
fetch the protected-resource and authorization-server metadata, then register a public client named "Telesia" with the phone's
loopback redirect `http://127.0.0.1:53682/callback` (PKCE, no secret).

Result: **99 presets checked. 90 need sign-in and accept dynamic registration. 9 answer without any sign-in. 0 failed.**

- Sign-in works (90): zapier, notion, canva, airtable, clickup, monday, asana, atlassian, linear, miro, granola, krisp, jotform, intercom, close, paypal, stripe, square, wix, webflow, vercel, supabase, neon, cloudflare, sentry, apify, tavily, make, pipedream, todoist, basecamp, calcom, fireflies, otter, mem, supermemory, productboard, attio, folk, apollo, hunter, klaviyo, ramp, mercury, paddle, razorpay, recurly, shipstation, kajabi, workable, greenhouse, vanta, wordpress, framer, lovable, gitbook, mintlify, vimeo, frameio, spline, lottiefiles, replicate, pcloud, ilovepdf, meetup, mapbox, consensus, parallel, brightdata, alphavantage, dataforseo, netlify, railway, gitlab, postman, clerk, retool, posthog, amplitude, mixpanel, resend, mux, newrelic, grafana, axiom, honeycomb, buildkite, gitguardian, jam, globalping.
- No sign-in needed (9): zenrows, kiwi, instacart, dice, jina, exa, huggingface, deepwiki, context7. They connect directly; the Connect button should skip the browser for them.
- Also support Client ID Metadata Documents (future option, no registration call at all): notion, canva, airtable, monday, linear, granola, cloudflare, sentry, apify, tavily, todoist, basecamp, fireflies, folk, klaviyo, paddle, recurly, shipstation, lovable, spline, lottiefiles, pcloud, ilovepdf, railway, clerk, posthog, resend, grafana, axiom, honeycomb, exa, huggingface, context7.
- Failed: none.

Re-run before release: the probe script pattern is in this doc's history (requests + the steps above). A preset that starts failing should be hidden from the Sign in tab.

## Added 2026-10-20 (ECO, branch feature/agent-loop, v1.13.50+83)
Same method (probe script: `initialize` without a token, protected-resource and authorization-server metadata, register "Telesia" with the loopback redirect; for open servers `initialize` + `tools/list`).
- Sign-in works (4): dropbox `https://mcp.dropbox.com/mcp`, buffer `https://mcp.buffer.com/mcp`, typeform `https://api.typeform.com/mcp` (replaces the key-paste Typeform for new connections), invideo `https://mcp.invideo.io/mcp`.
- No sign-in needed (4): godaddy `https://api.godaddy.com/v1/domains/mcp` (domains_suggest, domains_check_availability), coingecko `https://mcp.api.coingecko.com/mcp` (search_docs, execute), peek `https://mcp.peek.com` (search_experiences, experience_availability ...), mslearn `https://learn.microsoft.com/api/mcp` (microsoft_docs_search, microsoft_docs_fetch, microsoft_code_sample_search).
- Rejected: gamma (refuses the loopback redirect), figma and similarweb (registration forbidden), box and trello (no dynamic registration), cloudinary and instantdomainsearch (no metadata), eventbrite (answers but lists no tools), squarespace and findadomain (work, but duplicate GoDaddy's domain search), semrush and ahrefs (work, but paid SEO suites; can be added later).
