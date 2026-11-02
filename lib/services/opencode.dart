import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import 'cloud.dart';
import 'tools.dart';

/// The opencode engine on the phone (owner, 2026-11-02): SubMac's chat runs on opencode, unchanged (its own prompts,
/// tools and behaviour). The server is started by the Android side (OpenCode.kt) on 127.0.0.1 behind a password;
/// model calls go to the app's local proxy, which forwards them to ai-chat with a fresh access token (LocalProxy.kt).
///
/// One opencode session per SubMac chat. Events come from one shared `/event` stream.
class OpenCodeEngine {
  OpenCodeEngine._();
  static final OpenCodeEngine I = OpenCodeEngine._();

  static const _ch = MethodChannel('submac/native');
  static const _prefsKey = 'opencode.sessions.v1';

  final _client = http.Client();
  int _port = 0;
  String _pass = '';
  Future<void>? _starting;
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  StreamSubscription<String>? _sse;
  Map<String, String>? _sessions;

  /// Every event from the engine, decoded (`{type, properties}`).
  Stream<Map<String, dynamic>> get events => _events.stream;

  Map<String, String> get _auth => {'Authorization': 'Basic ${base64Encode(utf8.encode('opencode:$_pass'))}'};
  Uri _u(String path) => Uri.parse('http://127.0.0.1:$_port$path');

  /// Starts the engine (once) and keeps the event stream open.
  Future<void> ensure() async {
    if (_port != 0) {
      final st = await _ch.invokeMethod('ocStatus');
      if (st is Map && st['running'] == true) {
        await _pushToken();
        if (_sse == null) await _listen();
        return;
      }
      _port = 0;
    }
    await (_starting ??= _start().whenComplete(() => _starting = null));
  }

  Future<void> _start() async {
    final r = Random.secure();
    _pass = List.generate(32, (_) => r.nextInt(16).toRadixString(16)).join();
    // An engine started elsewhere (the opencode test screen) has another password: start our own.
    await _ch.invokeMethod('ocStop');
    await _pushToken();
    final res = await _ch.invokeMethod('ocStart', {
      'password': _pass,
      'port': 4096 + r.nextInt(2000),
      // opencode works in SubMac's own workspace, so its files show in the Files screen.
      'cwd': await AgentTools.workspaceDir(),
    });
    final m = res is Map ? res : const {};
    if (m['ok'] != true) {
      throw OpenCodeError('The engine did not start: ${m['error'] ?? 'no answer in 60 s'}\n${m['log'] ?? ''}'.trim());
    }
    _port = (m['port'] as num).toInt();
    await _sse?.cancel();
    _sse = null;
    await _listen();
  }

  /// The proxy adds the user's access token to every model call; refreshed before each prompt.
  Future<void> _pushToken() async {
    final t = await Cloud.token();
    await _ch.invokeMethod('ocToken', {'baseUrl': '${AppConfig.supabaseUrl}/functions/v1/ai-chat', 'token': t});
  }

  Future<void> _listen() async {
    final req = http.Request('GET', _u('/event'))..headers.addAll({..._auth, 'accept': 'text/event-stream'});
    final resp = await _client.send(req);
    if (resp.statusCode != 200) throw OpenCodeError('Event stream: HTTP ${resp.statusCode}');
    _sse = resp.stream.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      if (!line.startsWith('data:')) return;
      try {
        final j = jsonDecode(line.substring(5).trim());
        if (j is Map<String, dynamic>) _events.add(j);
      } catch (_) {}
    }, onDone: () => _sse = null, onError: (_) => _sse = null, cancelOnError: true);
  }

  Future<Map<String, String>> _map() async {
    if (_sessions != null) return _sessions!;
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_prefsKey);
      _sessions = raw == null ? {} : Map<String, String>.from(jsonDecode(raw) as Map);
    } catch (_) {
      _sessions = {};
    }
    return _sessions!;
  }

  Future<void> _saveMap() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_prefsKey, jsonEncode(_sessions ?? {}));
    } catch (_) {}
  }

  /// The opencode session of a SubMac chat (made on first use; made again if the engine lost it).
  Future<String> sessionFor(String convId, {String? title}) async {
    final m = await _map();
    final known = m[convId];
    if (known != null) {
      final r = await _client.get(_u('/session/$known'), headers: _auth);
      if (r.statusCode == 200) return known;
    }
    final r = await _client.post(_u('/session'),
        headers: {..._auth, 'content-type': 'application/json'}, body: jsonEncode({if (title != null) 'title': title}));
    if (r.statusCode != 200) throw OpenCodeError('New session: HTTP ${r.statusCode} ${r.body}');
    final id = '${jsonDecode(r.body)['id']}';
    m[convId] = id;
    await _saveMap();
    return id;
  }

  /// Sends one user message; the reply arrives on [events].
  Future<void> prompt(String session, List<Map<String, dynamic>> parts) async {
    await _pushToken();
    final r = await _client.post(_u('/session/$session/prompt_async'),
        headers: {..._auth, 'content-type': 'application/json'}, body: jsonEncode({'parts': parts}));
    if (r.statusCode >= 300) throw OpenCodeError('Prompt: HTTP ${r.statusCode} ${r.body}');
  }

  /// Stops the reply being written in [session].
  Future<void> abort(String session) async {
    try {
      await _client.post(_u('/session/$session/abort'), headers: _auth);
    } catch (_) {}
  }

  /// Forgets a chat's session (the chat was deleted).
  Future<void> forget(String convId) async {
    final m = await _map();
    final id = m.remove(convId);
    await _saveMap();
    if (id != null && _port != 0) {
      try {
        await _client.delete(_u('/session/$id'), headers: _auth);
      } catch (_) {}
    }
  }
}

class OpenCodeError implements Exception {
  OpenCodeError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// One reply turn, folded from engine events (pure, so it can be tested without the engine). Text parts become chat
/// text; tool parts become a tool call and its result; the user's own message is skipped; `session.idle` or an error
/// ends the turn.
class OpenCodeTurn {
  OpenCodeTurn(this.session);
  final String session;
  final _userMsgs = <String>{};

  /// Parts in the order they first appeared: id -> part.
  final parts = <String, OcPart>{};
  bool done = false;
  String? error;
  String? retry;
  bool reasoning = false;

  /// Feeds one event; returns true when something visible changed.
  bool apply(Map<String, dynamic> j) {
    final props = j['properties'];
    if (props is! Map) return false;
    switch (j['type']) {
      case 'message.updated':
        final info = props['info'];
        if (info is Map && info['sessionID'] == session) {
          if (info['role'] == 'user') _userMsgs.add('${info['id']}');
          final err = info['error'];
          if (info['role'] == 'assistant' && err is Map && err['name'] != 'MessageAbortedError') {
            error = '${(err['data'] as Map?)?['message'] ?? err['name']}';
            return true;
          }
        }
        return false;
      case 'message.part.updated':
        final p = props['part'];
        if (p is! Map || p['sessionID'] != session || _userMsgs.contains('${p['messageID']}')) return false;
        final id = '${p['id']}';
        final type = '${p['type']}';
        if (type == 'reasoning') {
          reasoning = true;
          return true;
        }
        if (type == 'text') {
          if (p['synthetic'] == true) return false;
          (parts[id] ??= OcPart(id, 'text')).text = '${p['text'] ?? ''}';
          reasoning = false;
          return true;
        }
        if (type == 'tool') {
          final st = p['state'] is Map ? p['state'] as Map : const {};
          final part = parts[id] ??= OcPart(id, 'tool');
          part.tool = '${p['tool'] ?? ''}';
          part.callId = '${p['callID'] ?? id}';
          part.status = '${st['status'] ?? ''}';
          part.title = st['title'] is String ? st['title'] as String : null;
          if (st['input'] is Map) part.input = Map<String, dynamic>.from(st['input'] as Map);
          if (st['output'] != null) part.output = '${st['output']}';
          if (st['error'] != null) part.output = '${st['error']}';
          reasoning = false;
          return true;
        }
        return false;
      case 'message.part.delta':
        if (props['sessionID'] != session || props['field'] != 'text' || _userMsgs.contains('${props['messageID']}')) return false;
        final id = '${props['partID']}';
        final part = parts[id];
        if (part == null || part.kind != 'text') {
          // A delta for a part we have not seen yet (or a reasoning part): only text parts are shown.
          if (part == null && !reasoning) (parts[id] = OcPart(id, 'text')).text = '${props['delta'] ?? ''}';
          return part == null && !reasoning;
        }
        part.text += '${props['delta'] ?? ''}';
        return true;
      case 'session.status':
        final st = props['status'];
        if (props['sessionID'] != session || st is! Map) return false;
        if (st['type'] == 'retry') {
          retry = '${st['message'] ?? ''}';
          return true;
        }
        if (st['type'] == 'idle') {
          done = true;
          return true;
        }
        retry = null;
        return false;
      case 'session.idle':
        if (props['sessionID'] == session) {
          done = true;
          return true;
        }
        return false;
      case 'session.error':
        if (props['sessionID'] != null && props['sessionID'] != session) return false;
        final err = props['error'];
        if (err is Map && err['name'] == 'MessageAbortedError') return false;
        error = err is Map ? '${(err['data'] as Map?)?['message'] ?? err['name'] ?? err}' : '$err';
        return true;
    }
    return false;
  }
}

class OcPart {
  OcPart(this.id, this.kind);
  final String id;
  final String kind; // text | tool
  String text = '';
  String tool = '';
  String callId = '';
  String status = '';
  String? title;
  Map<String, dynamic> input = const {};
  String? output;
  bool get finished => status == 'completed' || status == 'error';
}
