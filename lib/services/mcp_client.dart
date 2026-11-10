import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import 'mcp_oauth.dart';

/// A tool server the user connected (Model Context Protocol, Streamable HTTP).
class McpServerConfig {
  String id;
  String name;
  String url;
  Map<String, String> headers; // stored encrypted with the rest of the config
  bool enabled;
  /// Sign-in tokens for apps connected by signing in (refresh token, token endpoint, client id).
  Map<String, String> oauth;
  /// Access level (plan 4): true = Telesia may only look things up in this app, never change anything.
  bool readOnly;

  McpServerConfig({required this.id, required this.name, required this.url, Map<String, String>? headers, this.enabled = true, Map<String, String>? oauth, this.readOnly = false})
      : headers = headers ?? {},
        oauth = oauth ?? {};

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'url': url, 'headers': headers, 'enabled': enabled, if (oauth.isNotEmpty) 'oauth': oauth, if (readOnly) 'readOnly': true};

  factory McpServerConfig.fromJson(Map<String, dynamic> j) => McpServerConfig(
        id: (j['id'] ?? const Uuid().v4()).toString(),
        name: (j['name'] ?? 'Server').toString(),
        url: (j['url'] ?? '').toString(),
        headers: Map<String, String>.from((j['headers'] as Map?)?.map((k, v) => MapEntry(k.toString(), v.toString())) ?? {}),
        enabled: j['enabled'] != false,
        oauth: Map<String, String>.from((j['oauth'] as Map?)?.map((k, v) => MapEntry(k.toString(), v.toString())) ?? {}),
        readOnly: j['readOnly'] == true,
      );

  /// Short safe prefix for tool names, e.g. "composio".
  String get slug {
    final s = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
    return s.isEmpty ? 'server' : (s.length > 16 ? s.substring(0, 16) : s);
  }
}

class McpTool {
  final McpServerConfig server;
  final String name;
  final String description;
  final Map<String, dynamic> schema;
  McpTool(this.server, this.name, this.description, this.schema);

  /// Name shown to the model: mcp_<server>__<tool>, max 64 chars.
  String get fnName => fnNameFor(server.slug, name);

  /// Longest tool name the model APIs take.
  static const maxName = 64;

  /// CB-33: cutting at 64 made two long tool names from one app identical, so one shadowed the other.
  /// A long name keeps its first 55 characters, then `_` and 8 hex characters of a hash of the whole name,
  /// so it stays the same on every phone and two different tools never share it. Dispatch already finds the tool by
  /// this exact name in the listed tools (`fnName == name`), so the list is the reverse map back to the real tool name.
  static String fnNameFor(String slug, String tool) {
    final full = 'mcp_${slug}__$tool';
    final n = 'mcp_${slug}__${tool.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}';
    if (n.length <= maxName) return n;
    final h = sha1.convert(utf8.encode(full)).toString().substring(0, 8);
    return '${n.substring(0, maxName - 9)}_$h';
  }

  Map<String, dynamic> toDefinition() {
    final params = Map<String, dynamic>.from(schema)
      ..remove(r'$schema')
      ..remove(r'$id');
    params['type'] ??= 'object';
    params['properties'] ??= <String, dynamic>{};
    var desc = description.isEmpty ? 'Tool "$name" from ${server.name}.' : description;
    if (desc.length > 900) desc = '${desc.substring(0, 900)}…';
    return {
      'type': 'function',
      'function': {'name': fnName, 'description': '[${server.name}] $desc', 'parameters': params},
    };
  }
}

/// Minimal MCP client over Streamable HTTP (JSON-RPC 2.0, JSON or SSE replies).
class McpClient {
  McpClient(this.server);
  final McpServerConfig server;
  String? _session;
  int _id = 0;
  bool _ready = false;

  static final Map<String, McpClient> _clients = {};
  static McpClient of(McpServerConfig s) {
    final c = _clients[s.id];
    if (c != null && c.server.url == s.url) return c;
    return _clients[s.id] = McpClient(s);
  }

  static void reset(String id) => _clients.remove(id);

  /// Called after a sign-in token was refreshed, so the app saves it.
  static void Function()? onTokensChanged;
  bool _refreshing = false;

  Future<dynamic> _rpc(String method, [Map<String, dynamic>? params, bool notify = false]) async {
    final body = <String, dynamic>{'jsonrpc': '2.0', 'method': method, if (params != null) 'params': params};
    final id = ++_id;
    if (!notify) body['id'] = id;
    if (server.oauth.isNotEmpty && McpOAuth.expired(server) && !_refreshing) {
      _refreshing = true;
      try {
        if (await McpOAuth.refresh(server)) onTokensChanged?.call();
      } finally {
        _refreshing = false;
      }
    }
    final r = await http
        .post(Uri.parse(server.url),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json, text/event-stream',
              'MCP-Protocol-Version': '2025-03-26',
              if (_session != null) 'Mcp-Session-Id': _session!,
              ...server.headers,
            },
            body: jsonEncode(body))
        .timeout(const Duration(seconds: 90));
    final sid = r.headers['mcp-session-id'];
    if (sid != null && sid.isNotEmpty) _session = sid;
    if (notify) return null;
    if (r.statusCode == 404 && _session != null) {
      // Session expired: start over once.
      _session = null;
      _ready = false;
      throw _Retry();
    }
    if (r.statusCode == 401 && server.oauth.isNotEmpty && !_refreshing) {
      _refreshing = true;
      try {
        if (await McpOAuth.refresh(server)) {
          onTokensChanged?.call();
          _session = null;
          _ready = false;
          throw _Retry();
        }
      } finally {
        _refreshing = false;
      }
      throw Exception('Signed out of ${server.name}. Open Apps and connect it again.');
    }
    final text = utf8.decode(r.bodyBytes, allowMalformed: true);
    if (r.statusCode >= 400) {
      throw Exception('HTTP ${r.statusCode}: ${text.length > 300 ? text.substring(0, 300) : text}');
    }
    Map<String, dynamic>? msg;
    final ct = r.headers['content-type'] ?? '';
    if (ct.contains('text/event-stream') || text.trimLeft().startsWith('event:') || text.trimLeft().startsWith('data:')) {
      for (final line in const LineSplitter().convert(text)) {
        if (!line.startsWith('data:')) continue;
        try {
          final j = jsonDecode(line.substring(5).trim());
          if (j is Map && j['id'] == id) msg = Map<String, dynamic>.from(j);
        } catch (_) {}
      }
    } else if (text.trim().isNotEmpty) {
      final j = jsonDecode(text);
      if (j is List) {
        for (final e in j) {
          if (e is Map && e['id'] == id) msg = Map<String, dynamic>.from(e);
        }
      } else if (j is Map) {
        msg = Map<String, dynamic>.from(j);
      }
    }
    if (msg == null) throw Exception('No reply from ${server.name}.');
    if (msg['error'] != null) {
      final e = msg['error'];
      throw Exception(e is Map ? (e['message'] ?? e.toString()) : e.toString());
    }
    return msg['result'];
  }

  Future<void> _init() async {
    if (_ready) return;
    await _rpc('initialize', {
      'protocolVersion': '2025-03-26',
      'capabilities': {},
      'clientInfo': {'name': 'Telesia', 'version': '1.4.0'},
    });
    try {
      await _rpc('notifications/initialized', null, true);
    } catch (_) {}
    _ready = true;
  }

  Future<T> _withInit<T>(Future<T> Function() f) async {
    try {
      await _init();
      return await f();
    } on _Retry {
      await _init();
      return await f();
    }
  }

  Future<List<McpTool>> listTools() => _withInit(() async {
        final out = <McpTool>[];
        String? cursor;
        for (var page = 0; page < 10; page++) {
          final res = await _rpc('tools/list', cursor == null ? {} : {'cursor': cursor});
          final tools = (res is Map ? res['tools'] : null) as List? ?? const [];
          for (final t in tools) {
            if (t is! Map) continue;
            out.add(McpTool(server, (t['name'] ?? '').toString(), (t['description'] ?? '').toString(),
                Map<String, dynamic>.from((t['inputSchema'] as Map?) ?? const {'type': 'object', 'properties': {}})));
          }
          cursor = res is Map ? res['nextCursor'] as String? : null;
          if (cursor == null || cursor.isEmpty) break;
        }
        return out;
      });

  Future<String> callTool(String name, Map<String, dynamic> args) => _withInit(() async {
        final res = await _rpc('tools/call', {'name': name, 'arguments': args});
        if (res is! Map) return jsonEncode(res);
        final parts = <String>[];
        for (final c in (res['content'] as List? ?? const [])) {
          if (c is Map && c['type'] == 'text') {
            parts.add((c['text'] ?? '').toString());
          } else if (c is Map && c['type'] == 'resource') {
            parts.add(jsonEncode(c['resource']));
          } else if (c is Map) {
            parts.add('[${c['type']} content]');
          }
        }
        if (parts.isEmpty && res['structuredContent'] != null) parts.add(jsonEncode(res['structuredContent']));
        var text = parts.join('\n');
        if (res['isError'] == true) text = 'Error: $text';
        // Kept short: every result is sent back to the model on later steps.
        if (text.length > 8000) text = '${text.substring(0, 8000)}\n…[truncated: ask the app for less, e.g. a filter or a smaller page]';
        return text;
      });
}

class _Retry implements Exception {}
