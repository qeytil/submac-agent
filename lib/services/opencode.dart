import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import 'byok.dart';
import 'byok_opencode.dart';
import 'cloud.dart';
import 'oc_lanes.dart';
import 'submac_gateway.dart';
import 'submac_mcp.dart';
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

  /// SubMac's own tools, offered to opencode as an MCP server (set by the app before the first prompt).
  SubMacMcp? mcp;

  /// The MCP server's state as opencode last reported it (connected | failed | ...), for the status line.
  String mcpStatus = '';

  /// Every event from the engine, decoded (`{type, properties}`).
  Stream<Map<String, dynamic>> get events => _events.stream;

  Map<String, String> get _auth => {'Authorization': 'Basic ${base64Encode(utf8.encode('opencode:$_pass'))}'};
  Uri _u(String path) => Uri.parse('http://127.0.0.1:$_port$path');

  /// Whether any opencode turn is running now (set by the app). The engine is only restarted for new BYOK settings
  /// while this is false, since a restart would cut a running turn off.
  bool Function()? busy;

  /// The BYOK setup the running engine was started with (owner 2026-11-03, docs/byok.md): its fingerprint and the
  /// provider ids it knows.
  String _byokSig = '';
  Set<String> _byokIds = const {};

  /// Starts the engine (once) and keeps the event stream open. When the user's own providers, models or active keys
  /// changed since the engine started, it is restarted (between turns only): opencode reads its config at start.
  ///
  /// [turn]: the caller is about to run a turn. It is counted from the moment the engine is known to stay up (in the
  /// same synchronous step as the restart check), so a second turn starting at the same time can never restart the
  /// engine under it. Every `ensure(turn: true)` that returns must be paired with one [endTurn].
  Future<void> ensure({bool turn = false}) async {
    if (_port != 0) {
      final st = await _ch.invokeMethod('ocStatus');
      if (st is Map && st['running'] == true) {
        final stale = ByokOpencode.signatureOf(ByokStore.I) != _byokSig;
        if (!shouldRestart(stale: stale, turnsInFlight: _turns, appBusy: busy?.call() ?? false)) {
          if (turn) _turns++;
          try {
            await _pushToken();
            if (_sse == null) await _listen();
          } catch (e) {
            if (turn) _turns--;
            rethrow;
          }
          return;
        }
      }
      _port = 0;
    }
    await (_starting ??= _start().whenComplete(() => _starting = null));
    if (turn) _turns++;
  }

  /// Turns running on the engine now (owner chats, bot chats, team members, office jobs), each in its own session.
  /// opencode's server runs sessions side by side; SubMac only has to keep from restarting the engine or re-adding
  /// its MCP server under a turn that is working (bots team audit 2026-11-04: nothing here allows only one turn).
  int _turns = 0;
  int get turnsInFlight => _turns;

  /// One turn started with `ensure(turn: true)` ended.
  void endTurn() {
    if (_turns > 0) _turns--;
  }

  /// Restart for new BYOK settings only when no turn is working (a restart would cut every running session off).
  static bool shouldRestart({required bool stale, required int turnsInFlight, required bool appBusy}) =>
      stale && turnsInFlight == 0 && !appBusy;

  /// SubMac's MCP server may be re-added (to refresh its tool list) only when the caller's own turn is the only one:
  /// re-adding replaces opencode's MCP client, which would cut a call another turn has in flight.
  static bool mayResync(int turnsInFlight) => turnsInFlight <= 1;

  Future<void> _start() async {
    final r = Random.secure();
    _pass = List.generate(32, (_) => r.nextInt(16).toRadixString(16)).join();
    final byok = ByokOpencode.providersOf(ByokStore.I);
    final byokSig = ByokOpencode.signatureOf(ByokStore.I);
    // An engine started elsewhere (the opencode test screen) has another password: start our own.
    await _ch.invokeMethod('ocStop');
    await _pushToken();
    final res = await _ch.invokeMethod('ocStart', {
      'password': _pass,
      'port': 4096 + r.nextInt(2000),
      // opencode works in SubMac's own workspace, so its files show in the Files screen.
      'cwd': await AgentTools.workspaceDir(),
      // The `submac` skill: opencode sees its name and loads it when a task needs the phone's apps (owner, 2026-11-03).
      'skills': const {'submac': SubMacGateway.skill},
      // One provider per allowance lane, each on its own proxy path (owner 2026-11-03, see OcLane).
      'providers': OcLane.providers(),
      'models': OcLane.models,
      // The user's own providers (BYOK, owner 2026-11-03): opencode provider entries as JSON, and their active keys,
      // which go only into the engine's environment (the config names them as {env:…}), never into a file.
      'byokProviders': jsonEncode(byok),
      'byokEnv': ByokOpencode.envOf(ByokStore.I),
    });
    final m = res is Map ? res : const {};
    if (m['ok'] != true) {
      throw OpenCodeError('The engine did not start: ${m['error'] ?? 'no answer in 60 s'}\n${m['log'] ?? ''}'.trim());
    }
    _port = (m['port'] as num).toInt();
    _byokSig = byokSig;
    _byokIds = byok.keys.toSet();
    await _sse?.cancel();
    _sse = null;
    await _listen();
    await _addMcp();
  }

  /// Registers SubMac's MCP server with the engine. The long timeout covers a call that waits on the user's OK or
  /// a browser task (opencode's default of 60 s cut such calls off: "MCP error -32001: Request timed out").
  Future<void> _addMcp() async {
    final s = mcp;
    if (s == null) return;
    final sig = _sigOf(s);
    try {
      await s.start();
      final r = await _client.post(_u('/mcp'),
          headers: {..._auth, 'content-type': 'application/json'},
          body: jsonEncode({
            'name': s.name,
            'config': {
              'type': 'remote',
              'url': s.url,
              'headers': {'Authorization': 'Bearer ${s.token}'},
              'oauth': false,
              'timeout': mcpTimeoutMs,
            },
          }));
      final j = r.statusCode == 200 ? jsonDecode(r.body) : null;
      final st = j is Map ? j[s.name] : null;
      if (r.statusCode == 200) _mcpSig = sig;
      mcpStatus = st is Map ? '${st['status']}${st['error'] == null ? '' : ': ${st['error']}'}' : 'HTTP ${r.statusCode}';
    } catch (e) {
      mcpStatus = 'failed: $e';
    }
  }

  static const mcpTimeoutMs = 30 * 60 * 1000;

  /// The tool names opencode was last given. opencode lists an MCP server's tools once, when it is added, and only
  /// lists again on a tools/list_changed notification (SubMac's server has no stream to send one). So when SubMac's
  /// tools change (an app connected or signed out, its tools loaded, the image model turned on), the server is added
  /// again before the next prompt, which makes opencode list it afresh.
  String _mcpSig = '';
  static String _sigOf(SubMacMcp s) => (s.listed().map((t) => '${t['name']}').toList()..sort()).join(',');

  /// Re-adds SubMac's MCP server when its tool list changed since opencode last listed it. Call between turns only:
  /// re-adding replaces opencode's client, which would cut off a call in flight.
  Future<void> syncMcp() async {
    final s = mcp;
    if (s == null || _port == 0) return;
    if (_sigOf(s) == _mcpSig) return;
    // Other turns are working side by side: the new tool list waits for a turn that runs alone. The gateway still
    // finds and runs every current SubMac tool (find_tools / run_tool read the live list), so nothing is cut off.
    if (!mayResync(_turns)) return;
    await _addMcp();
  }

  /// The SubMac chat a session belongs to, or null.
  String? convOf(String session) {
    final side = _side[session];
    if (side != null) return side;
    for (final e in (_sessions ?? const <String, String>{}).entries) {
      if (e.value == session) return e.key;
    }
    return null;
  }

  /// Answers a permission request: once | always | reject.
  Future<void> replyPermission(String id, String reply) async {
    await _client.post(_u('/permission/$id/reply'),
        headers: {..._auth, 'content-type': 'application/json'}, body: jsonEncode({'reply': reply}));
  }

  /// Answers a question request (one list of chosen labels per question), or rejects it when [answers] is null.
  Future<void> replyQuestion(String id, List<List<String>>? answers) async {
    if (answers == null) {
      await _client.post(_u('/question/$id/reject'), headers: _auth);
      return;
    }
    await _client.post(_u('/question/$id/reply'),
        headers: {..._auth, 'content-type': 'application/json'}, body: jsonEncode({'answers': answers}));
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

  /// A fresh session that belongs to no chat (a team member's part). Delete it with [dropSession] when done, so
  /// sessions never pile up on the phone.
  /// [conv]: the chat its permission and question cards show in (a team member's own chat), so a member's ask never
  /// lands in whatever chat happens to be open.
  Future<String> newSession({String? title, String? conv}) async {
    final r = await _client.post(_u('/session'),
        headers: {..._auth, 'content-type': 'application/json'}, body: jsonEncode({if (title != null) 'title': title}));
    if (r.statusCode != 200) throw OpenCodeError('New session: HTTP ${r.statusCode} ${r.body}');
    final id = '${jsonDecode(r.body)['id']}';
    if (conv != null && conv.isNotEmpty) _side[id] = conv;
    return id;
  }

  /// Sessions made with [newSession] -> the chat their asks show in.
  final Map<String, String> _side = {};

  Future<void> dropSession(String id) async {
    _side.remove(id);
    if (_port == 0) return;
    try {
      await _client.delete(_u('/session/$id'), headers: _auth);
    } catch (_) {}
  }

  /// Sends one user message; the reply arrives on [events]. [system] is appended after opencode's own system prompt
  /// for this turn (SubMac's name only; see SubMacStyle). [model] is the turn's provider and model (OcLane.pick): the
  /// provider decides the allowance lane its model calls bill to (owner 2026-11-03).
  Future<void> prompt(String session, List<Map<String, dynamic>> parts, {String? system, Map<String, String>? model}) async {
    // A BYOK model added while another task kept the engine busy is not in the running engine yet: say so plainly
    // instead of opencode's "model not found".
    final pid = model?['providerID'] ?? '';
    if (pid.startsWith(ByokProvider.prefix) && !_byokIds.contains(pid)) {
      throw OpenCodeError('Your new model settings apply as soon as the task that is running now finishes.');
    }
    await _pushToken();
    final r = await _client.post(_u('/session/$session/prompt_async'),
        headers: {..._auth, 'content-type': 'application/json'}, body: jsonEncode(promptBody(parts, system: system, model: model)));
    if (r.statusCode >= 300) throw OpenCodeError('Prompt: HTTP ${r.statusCode} ${r.body}');
  }

  /// The body of one prompt (pure, for tests). The model is always named (owner 2026-11-03): without it opencode reuses
  /// the session's last model, which would keep a bot's chat on the background lane after a wake.
  static Map<String, dynamic> promptBody(List<Map<String, dynamic>> parts, {String? system, Map<String, String>? model}) => {
        'parts': parts,
        if (system != null && system.isNotEmpty) 'system': system,
        'model': model ?? OcLane.pick(background: false),
      };

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

  /// Tokens the turn used (input + output + reasoning, per assistant message, latest count), so a bot's daily budget
  /// counts opencode work too.
  final _tokens = <String, int>{};
  int get tokens => _tokens.values.fold(0, (a, b) => a + b);

  /// The answer: the text written after the last step (or all text when there were no steps).
  String get answer {
    final list = parts.values.toList();
    final lastTool = list.lastIndexWhere((p) => p.kind == 'tool');
    final after = [for (final p in list.skip(lastTool + 1)) if (p.kind == 'text' && p.text.trim().isNotEmpty) p.text.trim()];
    if (after.isNotEmpty) return after.join('\n\n');
    final all = [for (final p in list) if (p.kind == 'text' && p.text.trim().isNotEmpty) p.text.trim()];
    return all.isEmpty ? '' : all.last;
  }

  /// Feeds one event; returns true when something visible changed.
  bool apply(Map<String, dynamic> j) {
    final props = j['properties'];
    if (props is! Map) return false;
    switch (j['type']) {
      case 'message.updated':
        final info = props['info'];
        if (info is Map && info['sessionID'] == session) {
          if (info['role'] == 'user') _userMsgs.add('${info['id']}');
          final tk = info['tokens'];
          if (info['role'] == 'assistant' && tk is Map) {
            int n(Object? v) => v is num ? v.toInt() : 0;
            _tokens['${info['id']}'] = n(tk['input']) + n(tk['output']) + n(tk['reasoning']);
          }
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
          // opencode's thinking: shown as it streams, like opencode's own desktop chat (owner, 2026-11-03).
          final part = parts[id] ??= OcPart(id, 'reasoning');
          if (p['text'] is String && (p['text'] as String).length >= part.text.length) part.text = p['text'] as String;
          final t = p['time'];
          if (t is Map && t['end'] != null) part.status = 'completed';
          reasoning = part.status != 'completed';
          return true;
        }
        if (type == 'text') {
          if (p['synthetic'] == true) return false;
          (parts[id] ??= OcPart(id, 'text')).text = '${p['text'] ?? ''}';
          for (final r in parts.values) {
            if (r.kind == 'reasoning') r.status = 'completed';
          }
          reasoning = false;
          return true;
        }
        if (type == 'tool') {
          // A step starting closes any thinking before it.
          for (final r in parts.values) {
            if (r.kind == 'reasoning') r.status = 'completed';
          }
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
        final part = parts[id] ??= OcPart(id, reasoning ? 'reasoning' : 'text');
        if (part.kind == 'tool') return false;
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
        // Working again (an idle seen before the prompt started is not the end of this turn).
        if (st['type'] == 'busy') done = false;
        retry = null;
        return false;
      case 'session.idle':
        if (props['sessionID'] == session) {
          done = true;
          return true;
        }
        return false;
      case 'session.error':
        // Only this turn's own session. An error naming no session is no turn's error: it used to end every turn
        // running at that moment (the owner's chat and each bot's), which is a leak between chats.
        if (props['sessionID'] != session) return false;
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
  final String kind; // text | reasoning | tool
  String text = '';
  String tool = '';
  String callId = '';
  String status = '';
  String? title;
  Map<String, dynamic> input = const {};
  String? output;
  bool get finished => status == 'completed' || status == 'error';
}

/// opencode's permission and question requests as SubMac asks (the card above the composer): a command to run asks
/// "Run this command?" with Allow · Always allow · Deny; a question from opencode's question tool shows its choices.
/// The answer goes back to the engine, which then carries on (or stops that step on Deny). Pure, so it is tested
/// without the engine or the app.
class OpenCodeAsks {
  OpenCodeAsks({required this.ask, required this.permit, required this.answer, required this.convOf, this.autopilot});

  /// Autopilot (the composer's Ask · Autopilot switch): a permission is allowed once without asking. Questions from
  /// opencode's question tool still ask, since only the user can answer them.
  final bool Function()? autopilot;

  /// Shows one ask in [convId]'s chat; the chosen option or typed answer, or null when the user skipped it.
  final Future<String?> Function(String convId, String title, String prompt, List<String> options) ask;
  final Future<void> Function(String id, String reply) permit;
  final Future<void> Function(String id, List<List<String>>? answers) answer;
  final String? Function(String session) convOf;

  static const allow = 'Allow';
  static const always = 'Always allow';
  static const deny = 'Deny';
  final _seen = <String>{};

  /// Handles one engine event; returns true when it was a request this handled.
  Future<bool> handle(Map<String, dynamic> e) async {
    final p = e['properties'];
    if (p is! Map) return false;
    final type = e['type'];
    if (type != 'permission.asked' && type != 'question.asked') return false;
    final id = '${p['id'] ?? ''}';
    if (id.isEmpty || !_seen.add(id)) return false;
    final conv = convOf('${p['sessionID'] ?? ''}') ?? '';
    if (type == 'permission.asked') {
      if (autopilot?.call() == true) {
        await permit(id, 'once');
        return true;
      }
      final (title, prompt) = permissionText('${p['permission'] ?? ''}', p['patterns'], p['metadata']);
      final a = await ask(conv, title, prompt, const [allow, always, deny]);
      await permit(id, a == allow ? 'once' : (a == always ? 'always' : 'reject'));
      return true;
    }
    final qs = p['questions'] is List ? p['questions'] as List : const [];
    final answers = <List<String>>[];
    for (final q in qs) {
      if (q is! Map) continue;
      final opts = [
        for (final o in (q['options'] is List ? q['options'] as List : const []))
          if (o is Map && '${o['label'] ?? ''}'.trim().isNotEmpty) '${o['label']}'.trim(),
      ];
      final a = await ask(conv, '${q['question'] ?? q['header'] ?? ''}'.trim(), '', opts);
      if (a == null) {
        await answer(id, null);
        return true;
      }
      answers.add(q['multiple'] == true ? a.split(RegExp(r'\s*,\s*')).where((s) => s.isNotEmpty).toList() : [a]);
    }
    await answer(id, answers);
    return true;
  }

  /// The card's title and detail for one permission (bash, edit, webfetch, external_directory, doom_loop, ...).
  static (String, String) permissionText(String perm, dynamic patterns, dynamic metadata) {
    final pats = patterns is List ? patterns.map((e) => '$e').where((e) => e.isNotEmpty).toList() : const <String>[];
    final meta = metadata is Map ? metadata : const {};
    final what = pats.join('\n');
    switch (perm) {
      case 'bash':
        return ('Run this command?', '${meta['command'] ?? what}');
      case 'edit':
        return ('Change this file?', '${meta['filepath'] ?? what}');
      case 'webfetch':
        return ('Open this web page?', '${meta['url'] ?? what}');
      case 'external_directory':
        return ('Use files outside the workspace?', what);
      case 'doom_loop':
        return ('It keeps repeating the same step. Let it go on?', what);
    }
    return ('Allow $perm?', what);
  }
}
