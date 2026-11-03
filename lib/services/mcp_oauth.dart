import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'mcp_client.dart';

/// A ready-made app the user connects by signing in (no keys, no developer setup).
class McpPreset {
  const McpPreset(this.id, this.name, this.url, this.blurb, this.category, {this.signIn = true, this.keyHeader, this.keyHint = '', this.keyHelp = ''});
  final String id;
  final String name;
  final String url;
  final String blurb;
  final String category;
  /// false = works straight away, nothing to sign in to.
  final bool signIn;

  /// Set for an app connected with a key the user pastes (no sign-in page): the header the key is sent in.
  final String? keyHeader;

  /// What the key looks like (e.g. "ck_..."), and where to find it.
  final String keyHint;
  final String keyHelp;

  bool get needsKey => keyHeader != null;
}

/// Sign-in for MCP servers (OAuth 2.1: discovery, dynamic client registration, PKCE).
/// The browser comes back to a tiny server on the phone itself (127.0.0.1), so nothing
/// has to be registered with any company and no keys are ever typed.
class McpOAuth {
  static const presets = <McpPreset>[
    // Composio Connect: one key, the user's own Composio apps (owner, 2026-11-03: "add it as app, so I just put the key").
    McpPreset('composio', 'Composio', 'https://connect.composio.dev/mcp', 'Gmail, GitHub, Slack and 1,000+ apps from your Composio account',
        'Everything',
        signIn: false,
        keyHeader: 'x-consumer-api-key',
        keyHint: 'ck_…',
        keyHelp: 'Copy it from dashboard.composio.dev, under Connect, then AI clients.'),
    McpPreset('zapier', 'Zapier', 'https://mcp.zapier.com/api/mcp/mcp', 'Gmail, Sheets, Calendar, Slack and 8,000 more apps', 'Everything'),
    McpPreset('notion', 'Notion', 'https://mcp.notion.com/mcp', 'Read and write your pages and databases', 'Work'),
    McpPreset('canva', 'Canva', 'https://mcp.canva.com/mcp', 'Find, create and edit your designs', 'Create'),
    McpPreset('airtable', 'Airtable', 'https://mcp.airtable.com/mcp', 'Your bases, tables and records', 'Work'),
    McpPreset('clickup', 'ClickUp', 'https://mcp.clickup.com/mcp', 'Tasks, docs and lists', 'Work'),
    McpPreset('monday', 'monday.com', 'https://mcp.monday.com/mcp', 'Boards, items and updates', 'Work'),
    McpPreset('asana', 'Asana', 'https://mcp.asana.com/mcp', 'Projects and tasks', 'Work'),
    McpPreset('atlassian', 'Jira & Confluence', 'https://mcp.atlassian.com/v1/mcp', 'Issues, pages and spaces', 'Work'),
    McpPreset('linear', 'Linear', 'https://mcp.linear.app/mcp', 'Issues, projects and cycles', 'Work'),
    McpPreset('miro', 'Miro', 'https://mcp.miro.com/', 'Your boards and sticky notes', 'Create'),
    McpPreset('granola', 'Granola', 'https://mcp.granola.ai/mcp', 'Your meeting notes', 'Work'),
    McpPreset('krisp', 'Krisp', 'https://mcp.krisp.ai/mcp', 'Meeting notes and transcripts', 'Work'),
    McpPreset('jotform', 'Jotform', 'https://mcp.jotform.com/', 'Forms and their answers', 'Work'),
    McpPreset('intercom', 'Intercom', 'https://mcp.intercom.com/mcp', 'Customer chats and contacts', 'Business'),
    McpPreset('close', 'Close CRM', 'https://mcp.close.com/mcp', 'Leads, deals and calls', 'Business'),
    McpPreset('paypal', 'PayPal', 'https://mcp.paypal.com/mcp', 'Invoices, payments and orders', 'Business'),
    McpPreset('stripe', 'Stripe', 'https://mcp.stripe.com', 'Customers, payments and invoices', 'Business'),
    McpPreset('square', 'Square', 'https://mcp.squareup.com/mcp', 'Sales, items and customers', 'Business'),
    McpPreset('wix', 'Wix', 'https://mcp.wix.com/mcp', 'Your Wix sites, store and bookings', 'Websites'),
    McpPreset('webflow', 'Webflow', 'https://mcp.webflow.com/mcp', 'Your Webflow sites and content', 'Websites'),
    McpPreset('vercel', 'Vercel', 'https://mcp.vercel.com', 'Deployments and projects', 'Developers'),
    McpPreset('supabase', 'Supabase', 'https://mcp.supabase.com/mcp', 'Databases and projects', 'Developers'),
    McpPreset('neon', 'Neon', 'https://mcp.neon.tech/mcp', 'Postgres databases', 'Developers'),
    McpPreset('cloudflare', 'Cloudflare', 'https://mcp.cloudflare.com/mcp', 'Sites, DNS and Workers', 'Developers'),
    McpPreset('sentry', 'Sentry', 'https://mcp.sentry.dev/mcp', 'App errors and issues', 'Developers'),
    McpPreset('apify', 'Apify', 'https://mcp.apify.com', 'Ready-made web scrapers', 'Research'),
    McpPreset('tavily', 'Tavily', 'https://mcp.tavily.com/mcp', 'Deep web search', 'Research'),
    McpPreset('make', 'Make', 'https://mcp.make.com', 'Run your Make automations across 2,000+ apps', 'Everything'),
    McpPreset('pipedream', 'Pipedream', 'https://mcp.pipedream.net/v2', 'Thousands of apps through one sign-in', 'Everything'),
    McpPreset('todoist', 'Todoist', 'https://ai.todoist.net/mcp', 'Your to-dos and projects', 'Work'),
    McpPreset('basecamp', 'Basecamp', 'https://mcp.basecamp.com/mcp', 'Projects, to-dos and messages', 'Work'),
    McpPreset('calcom', 'Cal.com', 'https://mcp.cal.com/mcp', 'Your bookings and availability', 'Work'),
    McpPreset('fireflies', 'Fireflies', 'https://api.fireflies.ai/mcp', 'Meeting recordings and notes', 'Work'),
    McpPreset('otter', 'Otter.ai', 'https://mcp.otter.ai/mcp', 'Meeting transcripts and summaries', 'Work'),
    McpPreset('mem', 'Mem', 'https://mcp.mem.ai/mcp', 'Your notes', 'Work'),
    McpPreset('supermemory', 'Supermemory', 'https://mcp.supermemory.ai/mcp', 'Your saved memories and links', 'Work'),
    McpPreset('productboard', 'Productboard', 'https://mcp.productboard.com/mcp', 'Product ideas and feedback', 'Work'),
    McpPreset('attio', 'Attio', 'https://mcp.attio.com/mcp', 'Your CRM: people, companies, deals', 'Business'),
    McpPreset('folk', 'folk', 'https://mcp.folk.app/mcp', 'Contacts and pipelines', 'Business'),
    McpPreset('apollo', 'Apollo', 'https://mcp.apollo.io/mcp', 'Find leads and contacts', 'Business'),
    McpPreset('hunter', 'Hunter', 'https://mcp.hunter.io/mcp', 'Find and check email addresses', 'Business'),
    McpPreset('klaviyo', 'Klaviyo', 'https://mcp.klaviyo.com/mcp', 'Email and SMS marketing', 'Business'),
    McpPreset('ramp', 'Ramp', 'https://mcp.ramp.com/mcp', 'Company cards and spending', 'Business'),
    McpPreset('mercury', 'Mercury', 'https://mcp.mercury.com/mcp', 'Business bank accounts', 'Business'),
    McpPreset('paddle', 'Paddle', 'https://mcp.paddle.com/mcp', 'Products, prices and payments', 'Business'),
    McpPreset('razorpay', 'Razorpay', 'https://mcp.razorpay.com/mcp', 'Payments and payouts', 'Business'),
    McpPreset('recurly', 'Recurly', 'https://mcp.recurly.com/mcp', 'Subscriptions and billing', 'Business'),
    McpPreset('shipstation', 'ShipStation', 'https://mcp.shipstation.com/mcp', 'Orders, labels and shipping', 'Business'),
    McpPreset('kajabi', 'Kajabi', 'https://mcp.kajabi.com/mcp', 'Your courses and members', 'Business'),
    McpPreset('workable', 'Workable', 'https://mcp.workable.com/mcp', 'Jobs and candidates', 'Business'),
    McpPreset('greenhouse', 'Greenhouse', 'https://mcp.greenhouse.io/mcp', 'Hiring and candidates', 'Business'),
    McpPreset('vanta', 'Vanta', 'https://mcp.vanta.com/mcp', 'Security and compliance', 'Business'),
    McpPreset('wordpress', 'WordPress.com', 'https://public-api.wordpress.com/wpcom/v2/mcp/v1', 'Your WordPress.com sites and posts', 'Websites'),
    McpPreset('framer', 'Framer', 'https://mcp.framer.com/mcp', 'Your Framer sites', 'Websites'),
    McpPreset('lovable', 'Lovable', 'https://mcp.lovable.dev/mcp', 'Apps you built with Lovable', 'Websites'),
    McpPreset('gitbook', 'GitBook', 'https://mcp.gitbook.com/mcp', 'Your docs', 'Websites'),
    McpPreset('mintlify', 'Mintlify', 'https://mcp.mintlify.com/mcp', 'Your docs sites', 'Websites'),
    McpPreset('vimeo', 'Vimeo', 'https://mcp.vimeo.com/mcp', 'Your videos', 'Create'),
    McpPreset('frameio', 'Frame.io', 'https://mcp.frame.io/mcp', 'Video reviews and comments', 'Create'),
    McpPreset('spline', 'Spline', 'https://mcp.spline.design/mcp', '3D scenes', 'Create'),
    McpPreset('lottiefiles', 'LottieFiles', 'https://mcp.lottiefiles.com/mcp', 'Animations', 'Create'),
    McpPreset('replicate', 'Replicate', 'https://mcp.replicate.com/mcp', 'Run thousands of AI models', 'Create'),
    McpPreset('pcloud', 'pCloud', 'https://mcp.pcloud.com/mcp', 'Your cloud files', 'Files'),
    McpPreset('ilovepdf', 'iLovePDF', 'https://mcp.ilovepdf.com/mcp', 'Merge, split and convert PDFs', 'Files'),
    McpPreset('meetup', 'Meetup', 'https://mcp.meetup.com/mcp', 'Groups and events near you', 'Life'),
    McpPreset('mapbox', 'Mapbox', 'https://mcp.mapbox.com/mcp', 'Maps, places and directions', 'Life'),
    McpPreset('consensus', 'Consensus', 'https://mcp.consensus.app/mcp', 'Answers from scientific papers', 'Research'),
    McpPreset('parallel', 'Parallel Search', 'https://search-mcp.parallel.ai/mcp', 'Fast web search', 'Research'),
    McpPreset('brightdata', 'Bright Data', 'https://mcp.brightdata.com/mcp', 'Data from any website', 'Research'),
    McpPreset('alphavantage', 'Alpha Vantage', 'https://mcp.alphavantage.co/mcp', 'Stock and market data', 'Research'),
    McpPreset('dataforseo', 'DataForSEO', 'https://mcp.dataforseo.com/mcp', 'Search rankings and keywords', 'Research'),
    McpPreset('zenrows', 'ZenRows', 'https://mcp.zenrows.com/mcp', 'Read pages that block bots', 'Research'),
    McpPreset('netlify', 'Netlify', 'https://mcp.netlify.com/mcp', 'Sites and deploys', 'Developers'),
    McpPreset('railway', 'Railway', 'https://mcp.railway.app/mcp', 'Apps and databases', 'Developers'),
    McpPreset('gitlab', 'GitLab', 'https://gitlab.com/api/v4/mcp', 'Projects, issues and merge requests', 'Developers'),
    McpPreset('postman', 'Postman', 'https://mcp.postman.com/mcp', 'APIs and collections', 'Developers'),
    McpPreset('clerk', 'Clerk', 'https://mcp.clerk.com/mcp', 'Your app users', 'Developers'),
    McpPreset('retool', 'Retool', 'https://mcp.retool.com/mcp', 'Internal apps', 'Developers'),
    McpPreset('posthog', 'PostHog', 'https://mcp.posthog.com/mcp', 'Product analytics', 'Developers'),
    McpPreset('amplitude', 'Amplitude', 'https://mcp.amplitude.com/mcp', 'Product analytics', 'Developers'),
    McpPreset('mixpanel', 'Mixpanel', 'https://mcp.mixpanel.com/mcp', 'Product analytics', 'Developers'),
    McpPreset('resend', 'Resend', 'https://mcp.resend.com/mcp', 'Send emails from your domain', 'Developers'),
    McpPreset('mux', 'Mux', 'https://mcp.mux.com/mcp', 'Video hosting', 'Developers'),
    McpPreset('newrelic', 'New Relic', 'https://mcp.newrelic.com/mcp', 'App monitoring', 'Developers'),
    McpPreset('grafana', 'Grafana', 'https://mcp.grafana.com/mcp', 'Dashboards and alerts', 'Developers'),
    McpPreset('axiom', 'Axiom', 'https://mcp.axiom.co/mcp', 'Logs and events', 'Developers'),
    McpPreset('honeycomb', 'Honeycomb', 'https://mcp.honeycomb.io/mcp', 'Traces and debugging', 'Developers'),
    McpPreset('buildkite', 'Buildkite', 'https://mcp.buildkite.com/mcp', 'Builds and pipelines', 'Developers'),
    McpPreset('gitguardian', 'GitGuardian', 'https://mcp.gitguardian.com/mcp', 'Leaked secrets', 'Developers'),
    McpPreset('jam', 'Jam', 'https://mcp.jam.dev/mcp', 'Bug reports', 'Developers'),
    McpPreset('globalping', 'Globalping', 'https://mcp.globalping.dev/mcp', 'Test sites from around the world', 'Developers'),
    // v1.13.48 (ECO, checked 2026-10-20: discovery + dynamic registration, or open without sign-in; see docs/apps-dcr-check.md).
    McpPreset('dropbox', 'Dropbox', 'https://mcp.dropbox.com/mcp', 'Find, read and share your files', 'Files'),
    McpPreset('buffer', 'Buffer', 'https://mcp.buffer.com/mcp', 'Plan and schedule your social posts', 'Business'),
    McpPreset('typeform', 'Typeform', 'https://api.typeform.com/mcp', 'Forms, surveys and their answers', 'Work'),
    McpPreset('invideo', 'invideo AI', 'https://mcp.invideo.io/mcp', 'Turn an idea into a finished video', 'Create'),
    McpPreset('kiwi', 'Kiwi.com flights', 'https://mcp.kiwi.com', 'Search cheap flights, no sign-in', 'Life', signIn: false),
    McpPreset('instacart', 'Instacart', 'https://mcp.instacart.com/mcp', 'Recipes and shopping lists, no sign-in', 'Life', signIn: false),
    McpPreset('dice', 'Dice jobs', 'https://mcp.dice.com/mcp', 'Search tech jobs, no sign-in', 'Life', signIn: false),
    McpPreset('jina', 'Jina Reader', 'https://mcp.jina.ai/sse', 'Read any web page or PDF, no sign-in', 'Research', signIn: false),
    McpPreset('exa', 'Exa Search', 'https://mcp.exa.ai/mcp', 'Smart web search, no sign-in', 'Research', signIn: false),
    McpPreset('huggingface', 'Hugging Face', 'https://huggingface.co/mcp', 'AI models, datasets and Spaces', 'Research', signIn: false),
    McpPreset('deepwiki', 'DeepWiki', 'https://mcp.deepwiki.com/mcp', 'Explains any GitHub project', 'Research', signIn: false),
    McpPreset('godaddy', 'GoDaddy domains', 'https://api.godaddy.com/v1/domains/mcp', 'Check and find website names, no sign-in', 'Websites', signIn: false),
    McpPreset('coingecko', 'CoinGecko', 'https://mcp.api.coingecko.com/mcp', 'Live crypto prices and markets, no sign-in', 'Research', signIn: false),
    McpPreset('peek', 'Peek experiences', 'https://mcp.peek.com', 'Tours and things to do when you travel, no sign-in', 'Life', signIn: false),
    McpPreset('mslearn', 'Microsoft Learn', 'https://learn.microsoft.com/api/mcp', 'How-tos for Excel, Word, Windows and more, no sign-in', 'Research', signIn: false),
    McpPreset('context7', 'Context7', 'https://mcp.context7.com/mcp', 'Up-to-date docs for code libraries', 'Developers', signIn: false),
  ];

  static McpPreset? presetFor(String nameOrId) {
    final q = nameOrId.trim().toLowerCase();
    for (final p in presets) {
      if (p.id == q || p.name.toLowerCase() == q || p.name.toLowerCase().startsWith(q)) return p;
    }
    return null;
  }

  static const _port = 53682;

  // Stress handling: the sign-in that is waiting on the browser, so it can be cancelled, and
  // ended on its own when the user comes back to SubMac without finishing.
  static Completer<Map<String, String>>? _pending;
  static HttpServer? _live;
  static _BackWatch? _watch;

  /// What the user sees when they come back without finishing.
  static const notFinished = 'Sign-in wasn\'t finished. Tap Try again when you\'re ready.';

  /// True while a sign-in waits on the browser.
  static bool get waiting => _pending != null && !_pending!.isCompleted;

  /// Ends the sign-in that is waiting (Cancel button, or the user came back without finishing).
  static void cancel([String why = notFinished]) {
    final c = _pending;
    if (c != null && !c.isCompleted) c.complete({'error': 'cancelled', 'error_description': why});
  }
  static String get redirect => 'http://127.0.0.1:$_port/callback';

  static String _rand(int n) {
    final r = Random.secure();
    return base64UrlEncode(List<int>.generate(n, (_) => r.nextInt(256))).replaceAll('=', '');
  }

  static Future<Map<String, dynamic>?> _json(String url) async {
    try {
      final r = await http.get(Uri.parse(url), headers: {'Accept': 'application/json'}).timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) return null;
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      return j is Map ? Map<String, dynamic>.from(j) : null;
    } catch (_) {
      return null;
    }
  }

  static String _origin(String url) {
    final u = Uri.parse(url);
    return '${u.scheme}://${u.host}${u.hasPort && u.port != 443 && u.port != 80 ? ':${u.port}' : ''}';
  }

  /// Does this server need a sign-in? Returns the WWW-Authenticate header when it does, '' when it is open.
  static Future<String?> probe(String url) async {
    try {
      final r = await http
          .post(Uri.parse(url),
              headers: {'Content-Type': 'application/json', 'Accept': 'application/json, text/event-stream'},
              body: jsonEncode({
                'jsonrpc': '2.0',
                'id': 1,
                'method': 'initialize',
                'params': {'protocolVersion': '2025-03-26', 'capabilities': {}, 'clientInfo': {'name': 'SubMac Agent', 'version': '1.8'}},
              }))
          .timeout(const Duration(seconds: 20));
      if (r.statusCode == 401 || r.statusCode == 403) return r.headers['www-authenticate'] ?? 'Bearer';
      return '';
    } catch (_) {
      return null;
    }
  }

  /// Full sign-in. Opens the browser, waits for the user, returns the tokens to store.
  static Future<Map<String, String>> signIn(String serverUrl, {required String appName, Future<void> Function()? backToApp}) async {
    final www = await probe(serverUrl) ?? 'Bearer';
    // 1) Where to sign in.
    String? prmUrl = RegExp(r'resource_metadata="([^"]+)"').firstMatch(www)?.group(1);
    final scopeHint = RegExp(r'scope="([^"]+)"').firstMatch(www)?.group(1);
    final origin = _origin(serverUrl);
    final path = Uri.parse(serverUrl).path;
    Map<String, dynamic>? prm = prmUrl == null ? null : await _json(prmUrl);
    prm ??= await _json('$origin/.well-known/oauth-protected-resource${path == '/' ? '' : path}');
    prm ??= await _json('$origin/.well-known/oauth-protected-resource');
    final asList = (prm?['authorization_servers'] as List?)?.map((e) => '$e').toList() ?? const <String>[];
    final candidates = <String>{...asList, origin};
    Map<String, dynamic>? meta;
    for (final as in candidates) {
      final base = as.endsWith('/') ? as.substring(0, as.length - 1) : as;
      final o = _origin(base);
      final p = base.substring(o.length);
      for (final u in [
        '$o/.well-known/oauth-authorization-server$p',
        '$base/.well-known/oauth-authorization-server',
        '$o/.well-known/openid-configuration$p',
        '$base/.well-known/openid-configuration',
      ]) {
        final m = await _json(u);
        if (m != null && m['authorization_endpoint'] != null && m['token_endpoint'] != null) {
          // Prefer a server that lets new apps register themselves.
          if (meta == null || (meta['registration_endpoint'] == null && m['registration_endpoint'] != null)) meta = m;
          break;
        }
      }
      if (meta != null && meta['registration_endpoint'] != null) break;
    }
    if (meta == null) throw Exception('$appName does not offer a sign-in SubMac can use.');
    final reg = meta['registration_endpoint'] as String?;
    if (reg == null) throw Exception('$appName only works with apps it has approved one by one, so it cannot be connected by sign-in yet.');

    final regScopes = scopeHint ?? ((prm?['scopes_supported'] as List?)?.join(' ') ?? '');
    // 2) Register SubMac with this server (automatic, nothing for the user to do).
    final regRes = await http
        .post(Uri.parse(reg),
            headers: {'Content-Type': 'application/json', 'Accept': 'application/json'},
            body: jsonEncode({
              'client_name': 'SubMac Agent',
              'client_uri': 'https://submac.site',
              'redirect_uris': [redirect],
              'grant_types': ['authorization_code', 'refresh_token'],
              'response_types': ['code'],
              'token_endpoint_auth_method': 'none',
              if (regScopes.isNotEmpty) 'scope': regScopes,
            }))
        .timeout(const Duration(seconds: 20));
    if (regRes.statusCode >= 300) throw Exception('$appName refused the connection (${regRes.statusCode}).');
    final client = Map<String, dynamic>.from(jsonDecode(regRes.body) as Map);
    final clientId = '${client['client_id'] ?? ''}';
    final clientSecret = client['client_secret'] == null ? '' : '${client['client_secret']}';
    if (clientId.isEmpty) throw Exception('$appName did not accept SubMac.');

    // 3) Sign in, in the browser, with PKCE.
    final verifier = _rand(48);
    final challenge = base64UrlEncode(sha256.convert(ascii.encode(verifier)).bytes).replaceAll('=', '');
    final state = _rand(16);
    final resource = '${prm?['resource'] ?? serverUrl}';
    final scopes = scopeHint ?? ((prm?['scopes_supported'] as List?)?.join(' ') ?? '');
    final auth = Uri.parse(meta['authorization_endpoint'] as String).replace(queryParameters: {
      ...Uri.parse(meta['authorization_endpoint'] as String).queryParameters,
      'response_type': 'code',
      'client_id': clientId,
      'redirect_uri': redirect,
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
      'state': state,
      'resource': resource,
      if (scopes.isNotEmpty) 'scope': scopes,
    });

    // A sign-in left open (the user went back, then tapped Connect again) is closed first, never blocking this one.
    if (waiting) cancel('Started again.');
    try {
      await _live?.close(force: true);
    } catch (_) {}
    _live = null;
    HttpServer? srv;
    try {
      srv = await HttpServer.bind(InternetAddress.loopbackIPv4, _port, shared: true);
    } catch (_) {
      throw Exception('Another sign-in is still finishing. Wait a few seconds, then tap Try again.');
    }
    _live = srv;
    final got = Completer<Map<String, String>>();
    _pending = got;
    srv.listen((req) async {
      if (req.uri.path != '/callback') {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      final q = req.uri.queryParameters;
      final ok = q['code'] != null && q['state'] == state;
      req.response.headers.contentType = ContentType.html;
      req.response.write('<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">'
          '<body style="font-family:sans-serif;background:#faf9f6;color:#121110;display:flex;align-items:center;justify-content:center;height:90vh;text-align:center">'
          '<div><div style="width:14px;height:14px;border-radius:50%;background:#c2361b;margin:0 auto 18px"></div>'
          '<h2 style="font-weight:500">${ok ? '$appName is connected' : 'Sign-in was not finished'}</h2>'
          '<p style="color:#6b665c">You can go back to SubMac.</p></div></body>');
      await req.response.close();
      if (!got.isCompleted) got.complete(Map<String, String>.from(q));
    });
    try {
      final opened = await launchUrl(auth, mode: LaunchMode.externalApplication);
      if (!opened) throw Exception('The browser didn\'t open. Check a browser is installed, then tap Try again.');
      _watch ??= _BackWatch()..attach();
      _watch!.arm();
      final q = await got.future.timeout(const Duration(minutes: 5), onTimeout: () => {'error': 'timeout', 'error_description': notFinished});
      if (q['error'] != null) {
        final why = q['error_description'] ?? '';
        throw Exception(q['error'] == 'access_denied' ? 'You said no on $appName\'s page, so nothing was connected.' : (why.isEmpty ? notFinished : why));
      }
      if (q['state'] != state || q['code'] == null) throw Exception(notFinished);
      if (backToApp != null) unawaited(backToApp());

      // 4) Trade the code for tokens.
      final tok = await _token(meta['token_endpoint'] as String, {
        'grant_type': 'authorization_code',
        'code': q['code']!,
        'redirect_uri': redirect,
        'code_verifier': verifier,
        'resource': resource,
      }, clientId, clientSecret);
      return {
        ...tok,
        'token_endpoint': meta['token_endpoint'] as String,
        'client_id': clientId,
        if (clientSecret.isNotEmpty) 'client_secret': clientSecret,
        'resource': resource,
      };
    } finally {
      _watch?.disarm();
      if (identical(_pending, got)) _pending = null;
      if (identical(_live, srv)) _live = null;
      await srv.close(force: true);
    }
  }

  static Future<Map<String, String>> _token(String endpoint, Map<String, String> form, String clientId, String secret) async {
    Future<http.Response> post(bool basic) => http
        .post(Uri.parse(endpoint),
            headers: {
              'Content-Type': 'application/x-www-form-urlencoded',
              'Accept': 'application/json',
              if (basic) 'Authorization': 'Basic ${base64Encode(utf8.encode('${Uri.encodeComponent(clientId)}:${Uri.encodeComponent(secret)}'))}',
            },
            body: {...form, if (!basic) 'client_id': clientId, if (!basic && secret.isNotEmpty) 'client_secret': secret})
        .timeout(const Duration(seconds: 20));
    var r = await post(false);
    if ((r.statusCode == 401 || r.statusCode == 400) && secret.isNotEmpty) r = await post(true);
    if (r.statusCode >= 300) {
      throw Exception('Sign-in could not be completed (${r.statusCode}).');
    }
    final j = Map<String, dynamic>.from(jsonDecode(r.body) as Map);
    final access = '${j['access_token'] ?? ''}';
    if (access.isEmpty) throw Exception('No access was granted.');
    final exp = (j['expires_in'] as num?)?.toInt();
    return {
      'access_token': access,
      if (j['refresh_token'] != null) 'refresh_token': '${j['refresh_token']}',
      if (exp != null) 'expires_at': '${DateTime.now().add(Duration(seconds: exp - 60)).millisecondsSinceEpoch}',
    };
  }

  /// Gets a fresh access token with the saved refresh token. Returns false when the user must sign in again.
  static Future<bool> refresh(McpServerConfig s) async {
    final o = s.oauth;
    final rt = o['refresh_token'];
    final te = o['token_endpoint'];
    if (rt == null || te == null) return false;
    try {
      final tok = await _token(te, {
        'grant_type': 'refresh_token',
        'refresh_token': rt,
        if (o['resource'] != null) 'resource': o['resource']!,
      }, o['client_id'] ?? '', o['client_secret'] ?? '');
      s.oauth.addAll(tok);
      s.headers['Authorization'] = 'Bearer ${tok['access_token']}';
      return true;
    } catch (_) {
      return false;
    }
  }

  static bool expired(McpServerConfig s) {
    final e = int.tryParse(s.oauth['expires_at'] ?? '');
    return e != null && DateTime.now().millisecondsSinceEpoch > e;
  }
}


/// Notices the user coming back to SubMac while a sign-in still waits. The browser's redirect
/// lands within a moment of finishing, so a return with no answer after a short grace means
/// the user backed out: the sign-in ends and the app shows Try again instead of "Connecting" forever.
class _BackWatch with WidgetsBindingObserver {
  bool _armed = false;
  bool _left = false;
  Timer? _grace;

  void attach() => WidgetsBinding.instance.addObserver(this);

  void arm() {
    _armed = true;
    _left = false;
    _grace?.cancel();
  }

  void disarm() {
    _armed = false;
    _grace?.cancel();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (!_armed) return;
    if (s == AppLifecycleState.paused || s == AppLifecycleState.hidden) {
      _left = true;
      _grace?.cancel();
    } else if (s == AppLifecycleState.resumed && _left) {
      _grace?.cancel();
      _grace = Timer(const Duration(seconds: 4), () {
        if (_armed && McpOAuth.waiting) McpOAuth.cancel();
      });
    }
  }
}
