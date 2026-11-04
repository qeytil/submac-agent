import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// SubMac's own MCP server, on the phone (owner, 2026-11-02: "opencode is a complete agent, we just give it our
/// SubMac MCP").
///
/// opencode connects to it as a remote MCP server (Streamable HTTP, JSON responses) on 127.0.0.1 behind a bearer
/// token, and SubMac's tools sit behind it: the server only lists them and hands each call to [call], which runs it
/// through SubMac's own gate, so a risky call shows SubMac's approval card before it runs.
///
/// Pure dart:io (no Flutter), so it is tested end to end without the app.
class SubMacMcp {
  SubMacMcp({required this.tools, required this.call, this.name = 'submac', this.version = '1'});

  /// The tools to offer, in OpenAI function form (`{type: function, function: {name, description, parameters}}`)
  /// or plain `{name, description, parameters}`. Read on every `tools/list`, so a change shows on the next listing.
  final List<Map<String, dynamic>> Function() tools;

  /// Runs one tool call and returns what the model reads.
  final Future<String> Function(String name, Map<String, dynamic> args) call;
  final String name;
  final String version;

  static const protocol = '2025-06-18';
  static const _known = {'2024-11-05', '2025-03-26', '2025-06-18'};

  HttpServer? _server;
  String _token = '';

  int get port => _server?.port ?? 0;
  String get token => _token;
  String get url => 'http://127.0.0.1:$port/mcp';
  bool get running => _server != null;

  /// Starts the server (once) on a free port of 127.0.0.1.
  Future<void> start() async {
    if (_server != null) return;
    final r = Random.secure();
    _token = List.generate(32, (_) => r.nextInt(16).toRadixString(16)).join();
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = s;
    s.listen((req) => unawaited(_handle(req).catchError((Object _) {})));
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    if (req.uri.path != '/mcp') return _end(res, 404);
    if (req.headers.value('authorization') != 'Bearer $_token') return _end(res, 401);
    if (req.method == 'GET') return _end(res, 405); // no server-sent stream: every answer comes back in its POST
    if (req.method == 'DELETE') return _end(res, 200);
    if (req.method != 'POST') return _end(res, 405);
    dynamic body;
    try {
      body = jsonDecode(await utf8.decoder.bind(req).join());
    } catch (_) {
      return _json(res, _error(null, -32700, 'Parse error'));
    }
    if (body is List) {
      final out = <Map<String, dynamic>>[];
      for (final m in body) {
        final a = await _one(m);
        if (a != null) out.add(a);
      }
      if (out.isEmpty) return _end(res, 202);
      return _json(res, out);
    }
    final a = await _one(body);
    if (a == null) return _end(res, 202);
    return _json(res, a);
  }

  /// One JSON-RPC message: its answer, or null for a notification.
  Future<Map<String, dynamic>?> _one(dynamic m) async {
    if (m is! Map) return _error(null, -32600, 'Invalid request');
    final id = m['id'];
    final method = '${m['method'] ?? ''}';
    final params = m['params'] is Map ? Map<String, dynamic>.from(m['params'] as Map) : <String, dynamic>{};
    if (id == null) return null; // notifications/initialized, cancelled, ...
    switch (method) {
      case 'initialize':
        final want = '${params['protocolVersion'] ?? ''}';
        return _ok(id, {
          'protocolVersion': _known.contains(want) ? want : protocol,
          'capabilities': {
            'tools': {'listChanged': false},
          },
          'serverInfo': {'name': name, 'version': version},
          'instructions': 'SubMac: tools that act on this phone and the user\'s SubMac account. The chat shows pictures, '
              '.svg/.html/.png/.mp4 files you make when you name their path (see the submac skill).',
        });
      case 'ping':
        return _ok(id, {});
      case 'tools/list':
        return _ok(id, {'tools': listed()});
      case 'tools/call':
        final tool = '${params['name'] ?? ''}';
        if (!listed().any((t) => t['name'] == tool)) {
          return _ok(id, {
            'content': [
              {'type': 'text', 'text': 'Unknown tool: $tool'}
            ],
            'isError': true,
          });
        }
        final args = params['arguments'] is Map ? Map<String, dynamic>.from(params['arguments'] as Map) : <String, dynamic>{};
        try {
          final out = await call(tool, args);
          return _ok(id, {
            'content': [
              {'type': 'text', 'text': out}
            ],
            'isError': out.startsWith('Error'),
          });
        } catch (e) {
          return _ok(id, {
            'content': [
              {'type': 'text', 'text': 'Error in $tool: $e'}
            ],
            'isError': true,
          });
        }
      case 'resources/list':
        return _ok(id, {'resources': []});
      case 'prompts/list':
        return _ok(id, {'prompts': []});
    }
    return _error(id, -32601, 'Method not found: $method');
  }

  /// The tools as MCP lists them (`{name, description, inputSchema}`).
  List<Map<String, dynamic>> listed() {
    final out = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final t in tools()) {
      final f = t['function'] is Map ? Map<String, dynamic>.from(t['function'] as Map) : t;
      final n = '${f['name'] ?? ''}';
      if (n.isEmpty || !seen.add(n)) continue;
      final schema = f['parameters'] is Map ? Map<String, dynamic>.from(f['parameters'] as Map) : <String, dynamic>{};
      schema['type'] ??= 'object';
      schema['properties'] ??= <String, dynamic>{};
      out.add({'name': n, 'description': '${f['description'] ?? ''}', 'inputSchema': schema});
    }
    return out;
  }

  Map<String, dynamic> _ok(dynamic id, Map<String, dynamic> result) => {'jsonrpc': '2.0', 'id': id, 'result': result};
  Map<String, dynamic> _error(dynamic id, int code, String msg) => {
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': code, 'message': msg},
      };

  Future<void> _json(HttpResponse res, Object body) async {
    res.statusCode = 200;
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode(body));
    await res.close();
  }

  Future<void> _end(HttpResponse res, int code) async {
    res.statusCode = code;
    await res.close();
  }
}
