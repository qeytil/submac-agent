import 'dart:async';

import 'package:uuid/uuid.dart';

import 'mcp_oauth.dart';
import '../app_state.dart';
import 'mcp_client.dart';

/// Tools that let the user connect apps and MCP servers just by telling the agent in chat or Live.
/// Tokens go straight into encrypted storage.
class SetupTools {
  static Map<String, dynamic> _fn(String name, String desc, Map<String, dynamic> props, [List<String> req = const []]) => {
        'type': 'function',
        'function': {
          'name': name,
          'description': desc,
          'parameters': {'type': 'object', 'properties': props, 'required': req},
        },
      };

  static final definitions = <Map<String, dynamic>>[
    _fn(
      'connect_mcp',
      'Connect an app or MCP server. For ready-made apps just pass app (e.g. "Notion", "Zapier", "Canva", "Airtable", "ClickUp", '
          '"monday.com", "Asana", "Jira & Confluence", "Linear", "Miro", "PayPal", "Stripe", "Square", "Wix", "Webflow", "Granola", '
          '"Intercom", "Vercel", "Supabase", "Cloudflare", "Exa Search", "Hugging Face", "DeepWiki"): the connect sheet shows, the user taps Connect and signs in, no key needed (same as connect_app). '
          'Zapier reaches Gmail, Google Sheets, Calendar, Slack and 8,000 more apps. Or pass a url (and a token if the user has one); '
          'if the server wants a sign-in and no token is given, SubMac opens the sign-in for the user. Its tools become available right away.',
      {
        'app': {'type': 'string', 'description': 'Name of a ready-made app to connect by sign-in.'},
        'name': {'type': 'string'},
        'url': {'type': 'string', 'description': 'Streamable HTTP or SSE endpoint, https://...'},
        'token': {'type': 'string', 'description': 'Bearer token, if any (sent as Authorization: Bearer ...)'},
        'headers': {'type': 'object', 'description': 'Other headers, e.g. {"x-api-key": "..."}'},
      },
      [],
    ),
    _fn('list_mcp', 'List connected MCP servers and whether each one is working.', {}),
  ];

  static const names = {'connect_mcp', 'list_mcp'};

  static String _host(String url) => Uri.tryParse(url)?.host ?? url;

  static Future<String> execute(AppState app, String name, Map<String, dynamic> a) async {
    switch (name) {
      case 'connect_mcp':
        final appName = '${a['app'] ?? ''}'.trim();
        final token = '${a['token'] ?? ''}'.trim();
        final hdrs = a['headers'];
        final preset = appName.isNotEmpty ? McpOAuth.presetFor(appName) : (a['url'] != null ? McpOAuth.presets.where((p) => p.url == '${a['url']}'.trim()).firstOrNull : null);
        // A ready-made app goes through the connect sheet, so the user sees what is being connected and taps Connect.
        if (preset != null && token.isEmpty) return app.requestConnect(preset.name);
        if (appName.isNotEmpty && a['url'] == null) {
          return 'No ready-made connection for "$appName". Ready-made apps: ${McpOAuth.presets.map((p) => p.name).join(', ')}. '
              'Otherwise ask the user for its MCP server link.';
        }
        if (token.isEmpty && (hdrs is! Map || hdrs.isEmpty) && '${a['url'] ?? ''}'.startsWith('http')) {
          final w = await McpOAuth.probe('${a['url']}'.trim());
          if (w != null && w.isNotEmpty) {
            final u = '${a['url']}'.trim();
            final err = await app.connectMcpUrl(u, name: '${a['name'] ?? Uri.tryParse(u)?.host ?? 'Server'}', signIn: true);
            if (err != null) return 'Could not connect: $err';
            await app.refreshMcpTools();
            return 'Connected after the user signed in.';
          }
        }
        return _connectMcp(app, a);
      case 'list_mcp':
        if (app.mcpServers.isEmpty) return 'No MCP servers connected.';
        return [
          for (final s in app.mcpServers)
            '- ${s.name} (${_host(s.url)}): ${s.enabled ? (app.mcpStatus[s.id] ?? 'not checked yet') : 'turned off'}'
        ].join('\n');
    }
    return 'Unknown tool $name';
  }

  static Future<String> _connectMcp(AppState app, Map<String, dynamic> a) async {
    final url = '${a['url'] ?? ''}'.trim();
    if (!url.startsWith('http')) return 'Error: the MCP URL must start with https://';
    final headers = <String, String>{};
    final h = a['headers'];
    if (h is Map) h.forEach((k, v) => headers['$k'] = '$v');
    final token = '${a['token'] ?? ''}'.trim();
    if (token.isNotEmpty) headers['Authorization'] = token.toLowerCase().startsWith('bearer ') ? token : 'Bearer $token';
    final existing = app.mcpServers.where((s) => s.url == url).firstOrNull;
    final cfg = McpServerConfig(
      id: existing?.id ?? const Uuid().v4(),
      name: '${a['name'] ?? ''}'.trim().isEmpty ? _host(url) : '${a['name']}'.trim(),
      url: url,
      headers: headers,
    );
    McpClient.reset(cfg.id);
    try {
      final tools = await McpClient.of(cfg).listTools().timeout(const Duration(seconds: 25));
      await app.upsertMcpServer(cfg);
      final names = tools.map((t) => t.name).take(30).join(', ');
      return 'Connected ${cfg.name} with ${tools.length} tools${names.isEmpty ? '' : ': $names'}. They are ready to use now.';
    } catch (e) {
      McpClient.reset(cfg.id);
      return 'Error: could not connect to ${cfg.name}: $e. Check the URL and token with the user.';
    }
  }
}
