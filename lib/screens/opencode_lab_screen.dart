import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import '../services/cloud.dart';
import '../ui/i18n.dart';

/// opencode on the phone: the test screen (owner, 2026-11-02). Starts the bundled opencode server, checks
/// /global/health, opens a session and streams the reply to one prompt from the server's event stream (/event).
/// Proves the engine runs on this phone before the chat moves over to it.
class OpenCodeLabScreen extends StatefulWidget {
  const OpenCodeLabScreen({super.key});

  @override
  State<OpenCodeLabScreen> createState() => _OpenCodeLabScreenState();
}

/// The assistant's reply to one prompt, built from opencode's event stream (kept pure for tests). Text parts arrive
/// as `message.part.updated` (whole text) and `message.part.delta` (streamed pieces); the user's own message is
/// skipped; a tool call shows as one line; `session.idle` ends the reply.
class OpenCodeReply {
  OpenCodeReply(this.session);
  final String session;
  final _userMsgs = <String>{};
  final _order = <String>[];
  final _parts = <String, String>{};
  bool done = false;

  String get text => _order.map((k) => _parts[k] ?? '').where((t) => t.trim().isNotEmpty).join('\n');

  /// Feeds one SSE `data:` payload; returns true when the visible text changed.
  bool apply(String data) {
    Map j;
    try {
      final d = jsonDecode(data);
      if (d is! Map) return false;
      j = d;
    } catch (_) {
      return false;
    }
    final props = j['properties'];
    if (props is! Map) return false;
    switch (j['type']) {
      case 'message.updated':
        final info = props['info'];
        if (info is Map && info['sessionID'] == session && info['role'] == 'user') _userMsgs.add('${info['id']}');
        return false;
      case 'message.part.updated':
        final p = props['part'];
        if (p is! Map || p['sessionID'] != session || _userMsgs.contains('${p['messageID']}')) return false;
        final id = '${p['id']}';
        String? t;
        if (p['type'] == 'text') t = '${p['text'] ?? ''}';
        if (p['type'] == 'tool') t = '[tool ${p['tool']}: ${(p['state'] as Map?)?['status'] ?? ''}]';
        if (t == null) return false;
        if (!_parts.containsKey(id)) _order.add(id);
        _parts[id] = t;
        return true;
      case 'message.part.delta':
        if (props['sessionID'] != session || props['field'] != 'text' || _userMsgs.contains('${props['messageID']}')) return false;
        final id = '${props['partID']}';
        if (!_parts.containsKey(id)) _order.add(id);
        _parts[id] = '${_parts[id] ?? ''}${props['delta'] ?? ''}';
        return true;
      case 'session.idle':
        if (props['sessionID'] == session) done = true;
        return false;
      case 'session.error':
        if (props['sessionID'] != null && props['sessionID'] != session) return false;
        final err = props['error'];
        final msg = err is Map ? '${(err['data'] as Map?)?['message'] ?? err['name'] ?? err}' : '$err';
        if (!_parts.containsKey('error')) _order.add('error');
        _parts['error'] = '[error: $msg]';
        done = true;
        return true;
      case 'session.status':
        final st = props['status'];
        if (props['sessionID'] != session || st is! Map || st['type'] != 'retry') return false;
        if (!_parts.containsKey('retry')) _order.add('retry');
        _parts['retry'] = '[retry ${st['attempt'] ?? ''}: ${st['message'] ?? ''}]';
        return true;
    }
    return false;
  }
}

class _OpenCodeLabScreenState extends State<OpenCodeLabScreen> {
  static const _ch = MethodChannel('telesia/native');
  final _prompt = TextEditingController(text: 'In two sentences: who are you, and what tools do you have?');
  final _client = http.Client();
  String _status = 'Not started';
  String _log = '';
  String _reply = '';
  bool _busy = false;
  int _port = 0;
  String _pass = '';
  StreamSubscription<String>? _sse;
  final _clock = Stopwatch();

  Map<String, String> get _auth => {'Authorization': 'Basic ${base64Encode(utf8.encode('opencode:$_pass'))}'};
  String get _url => 'http://127.0.0.1:$_port';

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _sse?.cancel();
    _client.close();
    _prompt.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final s = Map<String, dynamic>.from(await _ch.invokeMethod('ocStatus') as Map);
      setState(() {
        _status = s['installed'] != true ? 'opencode is not in this build' : (s['running'] == true ? 'Running on port ${s['port']}' : 'Ready to start');
        _log = '${s['log'] ?? ''}';
      });
    } catch (e) {
      setState(() => _status = 'Status failed: $e');
    }
  }

  Future<void> _start() async {
    setState(() {
      _busy = true;
      _status = 'Starting opencode…';
    });
    _clock
      ..reset()
      ..start();
    try {
      final r = Random.secure();
      _pass = List.generate(24, (_) => r.nextInt(16).toRadixString(16)).join();
      final token = await Cloud.token();
      final res = Map<String, dynamic>.from(await _ch.invokeMethod('ocStart', {
        'baseUrl': '${AppConfig.supabaseUrl}/functions/v1/ai-chat',
        'token': token,
        'password': _pass,
        'port': 4096 + r.nextInt(800),
      }) as Map);
      _port = (res['port'] as num?)?.toInt() ?? 0;
      setState(() {
        _status = res['ok'] == true
            ? 'Healthy in ${(_clock.elapsedMilliseconds / 1000).toStringAsFixed(1)} s: ${res['health']}'
            : 'Failed: ${res['error'] ?? 'no health answer in 60 s'}';
        _log = '${res['log'] ?? ''}';
      });
    } catch (e) {
      setState(() => _status = 'Failed: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _send() async {
    if (_port == 0) return;
    setState(() {
      _busy = true;
      _reply = '';
    });
    _clock
      ..reset()
      ..start();
    try {
      final s = await _client.post(Uri.parse('$_url/session'), headers: {..._auth, 'content-type': 'application/json'}, body: '{}');
      if (s.statusCode != 200) throw 'session ${s.statusCode}: ${s.body}';
      final session = '${jsonDecode(s.body)['id']}';
      final done = Completer<void>();
      final reply = OpenCodeReply(session);
      await _sse?.cancel();
      final req = http.Request('GET', Uri.parse('$_url/event'))..headers.addAll({..._auth, 'accept': 'text/event-stream'});
      final resp = await _client.send(req);
      _sse = resp.stream.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        if (!line.startsWith('data:')) return;
        final data = line.substring(5).trim();
        if (reply.apply(data) && mounted) setState(() => _reply = reply.text);
        if (reply.done && !done.isCompleted) done.complete();
      }, onError: (Object e) {
        if (!done.isCompleted) done.completeError(e);
      });
      final p = await _client.post(Uri.parse('$_url/session/$session/prompt_async'),
          headers: {..._auth, 'content-type': 'application/json'},
          body: jsonEncode({
            'parts': [
              {'type': 'text', 'text': _prompt.text.trim()}
            ]
          }));
      if (p.statusCode >= 300) throw 'prompt ${p.statusCode}: ${p.body}';
      await done.future.timeout(const Duration(minutes: 3));
      final secs = (_clock.elapsedMilliseconds / 1000).toStringAsFixed(1);
      setState(() => _status = 'Reply finished in $secs s');
      if (_reply.trim().isEmpty) {
        // No streamed text: show what the session holds (an error from the model shows up here).
        final m = await _client.get(Uri.parse('$_url/session/$session/message'), headers: _auth);
        setState(() => _reply = m.body.length > 3000 ? m.body.substring(m.body.length - 3000) : m.body);
      }
    } catch (e) {
      setState(() => _status = 'Send failed: $e');
    } finally {
      setState(() => _busy = false);
      await _refresh();
    }
  }

  Future<void> _stop() async {
    await _sse?.cancel();
    await _ch.invokeMethod('ocStop');
    _port = 0;
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final mono = Theme.of(context).textTheme.bodySmall?.copyWith(fontFamily: 'monospace');
    return Scaffold(
      appBar: AppBar(title: const Text('opencode test')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(_status, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 12),
          Wrap(spacing: 8, children: [
            FilledButton(onPressed: _busy ? null : _start, child: Text(tr('Start'))),
            OutlinedButton(onPressed: _busy || _port == 0 ? null : _send, child: const Text('Send prompt')),
            TextButton(onPressed: _busy ? null : _stop, child: Text(tr('Stop'))),
          ]),
          const SizedBox(height: 12),
          TextField(controller: _prompt, minLines: 2, maxLines: 5, decoration: const InputDecoration(labelText: 'Prompt')),
          const SizedBox(height: 16),
          if (_reply.isNotEmpty) ...[
            Text(tr('Reply'), style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 4),
            SelectableText(_reply),
            const SizedBox(height: 16),
          ],
          Text('Server log', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 4),
          SelectableText(_log.isEmpty ? '(empty)' : _log, style: mono),
        ],
      ),
    );
  }
}
