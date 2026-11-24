import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import 'byok.dart';
import 'byok_opencode.dart';
import 'chat_compact.dart';
import 'cloud.dart';
import 'oc_lanes.dart';
import 'thinking_level.dart';
import 'output_limits.dart';
import 'telesia_gateway.dart';
import 'telesia_mcp.dart';
import 'tools.dart';

/// The opencode engine on the phone (owner, 2026-11-02): Telesia's chat runs on opencode, unchanged (its own prompts,
/// tools and behaviour). The server is started by the Android side (OpenCode.kt) on 127.0.0.1 behind a password;
/// model calls go to the app's local proxy, which forwards them to ai-chat with a fresh access token (LocalProxy.kt).
///
/// One opencode session per Telesia chat. Events come from one shared `/event` stream.
class OpenCodeEngine {
  OpenCodeEngine._();
  static final OpenCodeEngine I = OpenCodeEngine._();

  static const _ch = MethodChannel('telesia/native');
  static const _prefsKey = 'opencode.sessions.v1';

  final _client = http.Client();
  int _port = 0;
  String _pass = '';
  Future<void>? _starting;
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  StreamSubscription<String>? _sse;
  Map<String, String>? _sessions;

  /// Telesia's own tools, offered to opencode as an MCP server (set by the app before the first prompt).
  TelesiaMcp? mcp;

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
  /// opencode's server runs sessions side by side; Telesia only has to keep from restarting the engine or re-adding
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

  /// Telesia's MCP server may be re-added (to refresh its tool list) only when the caller's own turn is the only one:
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
      // opencode works in Telesia's own workspace, so its files show in the Files screen.
      'cwd': await AgentTools.workspaceDir(),
      // The `telesia` skill: opencode sees its name and loads it when a task needs the phone's apps (owner, 2026-11-03).
      'skills': const {'telesia': TelesiaGateway.skill},
      // One provider per allowance lane, each on its own proxy path (owner 2026-11-03, see OcLane).
      'providers': OcLane.providers(),
      'models': OcLane.models,
      // The user's own providers (BYOK, owner 2026-11-03): opencode provider entries as JSON, and their active keys,
      // which go only into the engine's environment (the config names them as {env:…}), never into a file.
      'byokProviders': jsonEncode(byok),
      'byokEnv': ByokOpencode.envOf(ByokStore.I),
      // How long a reply may be (owner 2026-11-06, see OutputLimits): Telesia's models get an explicit output limit
      // (the server clamps it per route), and opencode's own ceiling (32,000 unless set) is raised to the largest
      // limit of any configured model, so no reply is cut at 32,000 or at a flat default.
      ...startLimits(ByokOpencode.maxOutputOf(ByokStore.I)),
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

  /// The output-limit arguments of `ocStart` (pure, for tests): Telesia's models' limit and opencode's ceiling.
  static Map<String, int> startLimits(int byokMax) => {
        'modelOutput': OutputLimits.telesia,
        'outputTokenMax': OutputLimits.engineMax([byokMax]),
      };

  /// Registers Telesia's MCP server with the engine. The long timeout covers a call that waits on the user's OK or
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
  /// lists again on a tools/list_changed notification (Telesia's server has no stream to send one). So when Telesia's
  /// tools change (an app connected or signed out, its tools loaded, the image model turned on), the server is added
  /// again before the next prompt, which makes opencode list it afresh.
  String _mcpSig = '';
  static String _sigOf(TelesiaMcp s) => (s.listed().map((t) => '${t['name']}').toList()..sort()).join(',');

  /// Re-adds Telesia's MCP server when its tool list changed since opencode last listed it. Call between turns only:
  /// re-adding replaces opencode's client, which would cut off a call in flight.
  Future<void> syncMcp() async {
    final s = mcp;
    if (s == null || _port == 0) return;
    if (_sigOf(s) == _mcpSig) return;
    // Other turns are working side by side: the new tool list waits for a turn that runs alone. The gateway still
    // finds and runs every current Telesia tool (find_tools / run_tool read the live list), so nothing is cut off.
    if (!mayResync(_turns)) return;
    await _addMcp();
  }

  /// The Telesia chat a session belongs to, or null.
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
    }, onDone: _streamLost, onError: (_) => _streamLost(), cancelOnError: true);
  }

  /// How many times the event stream dropped since the app started (bug hunt 2026-11-06). A turn waiting on events
  /// that never come (the socket closed while the phone slept, the engine restarted) notices it by this count and
  /// recovers with [recover] instead of showing "Working" forever.
  int streamDrops = 0;

  void _streamLost() {
    _sse = null;
    streamDrops++;
  }

  /// Opens the event stream again when it dropped (no-op while it is up or the engine never started).
  Future<void> relisten() async {
    if (_port == 0 || _sse != null) return;
    try {
      await _listen();
    } catch (_) {}
  }

  /// The session's state as the engine reports it now: idle | busy | retry, or null when the engine did not answer.
  /// opencode lists only sessions that are not idle.
  Future<String?> statusOf(String session) async {
    if (_port == 0) return null;
    try {
      final r = await _client.get(_u('/session/status'), headers: _auth).timeout(const Duration(seconds: 5));
      if (r.statusCode != 200) return null;
      return OpenCodeTurn.statusIn(jsonDecode(r.body), session);
    } catch (_) {
      return null;
    }
  }

  /// A turn whose events stopped coming: reconnects the stream, then asks the engine itself. When the session is
  /// idle its messages are read back into [turn] (so the answer shows) and the turn ends; when the engine is gone the
  /// turn ends with an error. Returns true when [turn] ended.
  Future<bool> recover(OpenCodeTurn turn, {required DateTime since}) async {
    await relisten();
    final st = await statusOf(turn.session);
    if (st == null) {
      try {
        final run = await _ch.invokeMethod('ocStatus');
        if (run is Map && run['running'] == true) return false;
      } catch (_) {}
      turn.error ??= 'The engine stopped while it was working. Send your message again to retry.';
      return true;
    }
    if (st != 'idle') return false;
    try {
      final r = await _client.get(_u('/session/${turn.session}/message'), headers: _auth).timeout(const Duration(seconds: 10));
      if (r.statusCode == 200) turn.applySnapshot(jsonDecode(r.body), since: since);
    } catch (_) {}
    turn.done = true;
    return true;
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

  /// The opencode session of a Telesia chat (made on first use; made again if the engine lost it).
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
  /// for this turn (Telesia's name only; see TelesiaStyle). [model] is the turn's provider and model (OcLane.pick): the
  /// provider decides the allowance lane its model calls bill to (owner 2026-11-03).
  Future<void> prompt(String session, List<Map<String, dynamic>> parts,
      {String? system, Map<String, String>? model, String? variant}) async {
    // A BYOK model added while another task kept the engine busy is not in the running engine yet: say so plainly
    // instead of opencode's "model not found".
    final pid = model?['providerID'] ?? '';
    if (pid.startsWith(ByokProvider.prefix) && !_byokIds.contains(pid)) {
      throw OpenCodeError('Your new model settings apply as soon as the task that is running now finishes.');
    }
    await _pushToken();
    final r = await _client.post(_u('/session/$session/prompt_async'),
        headers: {..._auth, 'content-type': 'application/json'},
        body: jsonEncode(promptBody(parts, system: system, model: model, variant: variant)));
    if (r.statusCode >= 300) throw OpenCodeError('Prompt: HTTP ${r.statusCode} ${r.body}');
  }

  /// The body of one prompt (pure, for tests). The model is always named (owner 2026-11-03): without it opencode reuses
  /// the session's last model, which would keep a bot's chat on the background lane after a wake.
  static Map<String, dynamic> promptBody(List<Map<String, dynamic>> parts,
          {String? system, Map<String, String>? model, String? variant}) =>
      {
        'parts': parts,
        if (system != null && system.isNotEmpty) 'system': system,
        'model': model ?? OcLane.pick(background: false),
        // How hard the model should think: opencode's own model variant (owner 2026-11-10).
        if (variant != null && variant.isNotEmpty) 'variant': variant,
      };

  /// The reasoning variants the engine has for one model, from its own `/provider` answer (owner 2026-11-11):
  /// opencode names them by effort (low/medium/high, sometimes minimal/max) per model family. Empty for a model
  /// that does not think. Cached for the engine's life, which is as long as the model list stays the same.
  final Map<String, List<String>> _variants = {};

  Future<List<String>> variantsOf(String providerID, String modelID) async {
    final key = '$providerID/$modelID';
    final known = _variants[key];
    if (known != null) return known;
    if (_port == 0 || providerID.isEmpty || modelID.isEmpty) return const [];
    var out = const <String>[];
    try {
      final r = await _client.get(_u('/provider'), headers: _auth).timeout(const Duration(seconds: 10));
      if (r.statusCode == 200) out = Thinking.variantsIn(jsonDecode(r.body), providerID, modelID);
    } catch (_) {}
    _variants[key] = out;
    return out;
  }

  /// Stops the reply being written in [session].
  Future<void> abort(String session) async {
    try {
      await _client.post(_u('/session/$session/abort'), headers: _auth);
    } catch (_) {}
  }

  /// Asks the engine to fold the older part of [session] into a summary: opencode's own summarize. [model] is
  /// the turn's provider and model (OcLane.pick). True when the engine accepted it.
  Future<bool> compact(String session, Map<String, String> model) async {
    if (_port == 0) return false;
    try {
      final r = await _client
          .post(_u('/session/$session/summarize'),
              headers: {..._auth, 'content-type': 'application/json'},
              body: jsonEncode({'providerID': model['providerID'], 'modelID': model['modelID'], 'auto': false}))
          .timeout(const Duration(seconds: 20));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// The engine's own summary of [session] (the newest message it marked `summary: true`), or null when it has
  /// none yet.
  Future<String?> summaryOf(String session) async {
    if (_port == 0) return null;
    try {
      final r = await _client.get(_u('/session/$session/message'), headers: _auth).timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return null;
      return ChatCompact.summaryIn(jsonDecode(r.body));
    } catch (_) {
      return null;
    }
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

/// When a waiting turn asks the engine directly instead of waiting on events (bug hunt 2026-11-06): not in the first
/// seconds after the prompt (the session may not have started), at most every 10 s, and only when the event stream
/// dropped or nothing visible changed for 30 s (a long silent step just answers "busy").
class OcWatch {
  static const settle = Duration(seconds: 8);
  static const every = Duration(seconds: 10);
  static const quiet = Duration(seconds: 30);

  static bool due({required DateTime now, required DateTime sent, required DateTime seen, required DateTime checked, required bool dropped}) {
    if (now.difference(sent) < settle) return false;
    if (now.difference(checked) < every) return false;
    return dropped || now.difference(seen) >= quiet;
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

  /// Child sessions this turn started (opencode's own subagents, the `task` tool): their tool steps are folded
  /// in too, so a subagent's work is not hidden (owner 2026-11-24). id -> the subagent's name.
  final children = <String, String>{};

  /// True for this turn's own session and for any subagent session it started.
  bool _mine(Object? sid) => sid == session || children.containsKey('$sid');

  /// The name of the subagent a part came from, or '' for the turn's own parts.
  String childName(OcPart p) => p.child == null ? '' : (children[p.child!] ?? 'subagent');

  bool done = false;
  String? error;
  String? retry;
  bool reasoning = false;

  /// Input tokens of the newest assistant message: how full the window is, as the engine counts it.
  int contextUsed = 0;

  /// The engine folded this session's older part (its own auto-compaction, or Telesia's before a turn): its
  /// marker part arrived, and the summary message it wrote ([summaryMsg], [summary]).
  bool compacted = false;
  String? summaryMsg;
  String? summary;

  /// Tokens the turn used (input + output + reasoning, per assistant message, latest count), so a bot's daily budget
  /// counts opencode work too.
  final _tokens = <String, int>{};
  int get tokens => _tokens.values.fold(0, (a, b) => a + b);

  /// The newest assistant message (by its created time, then id) and how it finished (`stop`, `tool-calls`,
  /// `length`, ...; null while it is still being written).
  String? _lastMsg;
  int _lastCreated = -1;
  String? _lastFinish;

  /// How the newest assistant message finished.
  String? get lastFinish => _lastFinish;

  /// The reply stopped because it ran out of room (owner 2026-11-06). opencode ends the turn quietly then; the
  /// caller continues it ([shouldContinue], [beginContinue]).
  bool get cutOff => !_awaitingNext && ReplyContinuation.isCut(_lastFinish);

  /// How many times this turn was continued after a cut.
  int continues = 0;

  /// Sent "continue": the cut message no longer counts until the next assistant message starts.
  bool _awaitingNext = false;

  /// The text part the next text continues (the cut reply's last text), until that next text arrives.
  String? _glueTo;

  /// The turn ended because the reply ran out of room, and it may still be continued.
  bool get shouldContinue => done && error == null && cutOff && continues < ReplyContinuation.maxContinues;

  /// Still cut after every continuation: the chat says the reply may be incomplete.
  bool get leftCut => done && error == null && cutOff && continues >= ReplyContinuation.maxContinues;

  /// Before the caller sends [ReplyContinuation.prompt] to the session: the turn works again, the cut message stops
  /// counting, and the next text is glued to the cut text (when the cut reply ended in text).
  void beginContinue() {
    continues++;
    done = false;
    _awaitingNext = true;
    final last = parts.values.isEmpty ? null : parts.values.last;
    _glueTo = last != null && last.kind == 'text' && last.child == null ? last.id : null;
  }

  /// The first text part of a chain of continued parts ([OcPart.continues]).
  OcPart rootOf(OcPart p) {
    var r = p;
    var guard = 0;
    while (r.continues != null && parts[r.continues] != null && guard++ < 50) {
      r = parts[r.continues]!;
    }
    return r;
  }

  /// The whole text of the chain starting at [root]: each continuation joined on as written.
  String chainText(OcPart root) {
    var text = root.text;
    var cur = root.id;
    var guard = 0;
    while (guard++ < 50) {
      final next = parts.values.where((p) => p.continues == cur).firstOrNull;
      if (next == null) break;
      text = ReplyContinuation.join(text, next.text);
      cur = next.id;
    }
    return text;
  }

  /// The answer: the text written after the last step (or all text when there were no steps). A reply continued
  /// after a cut reads as one text.
  String get answer {
    final list = parts.values.toList();
    final lastTool = list.lastIndexWhere((p) => p.kind == 'tool');
    String textOf(OcPart p) => chainText(p).trim();
    bool head(OcPart p) => p.kind == 'text' && p.child == null && p.continues == null && textOf(p).isNotEmpty;
    final after = [for (final p in list.skip(lastTool + 1)) if (head(p)) textOf(p)];
    if (after.isNotEmpty) return after.join('\n\n');
    final all = [for (final p in list) if (head(p)) textOf(p)];
    return all.isEmpty ? '' : all.last;
  }

  /// A new text part: glued to the cut text when it is the first text after a continue.
  OcPart _newText(String id) {
    final p = OcPart(id, 'text');
    final g = _glueTo;
    if (g != null && parts[g] != null) p.continues = g;
    _glueTo = null;
    return p;
  }

  /// The state of [session] in the engine's `/session/status` answer (a map of session id to `{type}`): sessions
  /// missing from it are idle.
  static String? statusIn(Object? body, String session) {
    if (body is! Map) return null;
    final st = body[session];
    if (st == null) return 'idle';
    return st is Map ? '${st['type'] ?? 'busy'}' : 'busy';
  }

  /// Folds the session's messages as the engine stores them (`[{info, parts}]`) into this turn: the parts of the
  /// assistant messages started at or after [since]. Used when live events were missed (see OpenCodeEngine.recover).
  /// Returns true when something visible changed.
  bool applySnapshot(Object? body, {required DateTime since}) {
    if (body is! List) return false;
    final from = since.millisecondsSinceEpoch;
    var changed = false;
    for (final m in body) {
      if (m is! Map) continue;
      final info = m['info'];
      if (info is! Map || info['sessionID'] != session || info['role'] != 'assistant') continue;
      final t = info['time'];
      final created = t is Map && t['created'] is num ? (t['created'] as num).toInt() : 0;
      if (created < from) continue;
      if (apply({'type': 'message.updated', 'properties': {'info': info}})) changed = true;
      final ps = m['parts'];
      if (ps is! List) continue;
      for (final p in ps) {
        if (p is Map && apply({'type': 'message.part.updated', 'properties': {'part': p}})) changed = true;
      }
    }
    // Read after the fact: nothing is still being thought.
    for (final r in parts.values) {
      if (r.kind == 'reasoning') r.status = 'completed';
    }
    reasoning = false;
    return changed;
  }

  void _noteFinish(Map info) {
    final id = '${info['id']}';
    final t = info['time'];
    final created = t is Map && t['created'] is num ? (t['created'] as num).toInt() : 0;
    final newer = _lastMsg == null || created > _lastCreated || (created == _lastCreated && id.compareTo(_lastMsg!) > 0);
    if (id == _lastMsg) {
      _lastFinish = info['finish'] is String ? info['finish'] as String : null;
    } else if (newer) {
      // A new assistant message: after a continue, the cut one stops counting.
      if (_lastMsg != null) _awaitingNext = false;
      _lastMsg = id;
      _lastCreated = created;
      _lastFinish = info['finish'] is String ? info['finish'] as String : null;
    }
  }

  /// Feeds one event; returns true when something visible changed.
  bool apply(Map<String, dynamic> j) {
    final props = j['properties'];
    if (props is! Map) return false;
    switch (j['type']) {
      case 'session.created':
      case 'session.updated':
        // A subagent's own session: remember it (and its name) so its steps fold into this turn.
        final sinfo = props['info'];
        if (sinfo is Map && sinfo['id'] != null) {
          final sid = '${sinfo['id']}';
          final pid = '${sinfo['parentID'] ?? ''}';
          if (sid != session && (pid == session || children.containsKey(pid))) {
            final name = '${sinfo['title'] ?? ''}'.trim();
            if (!children.containsKey(sid) || (name.isNotEmpty && children[sid] != name)) {
              children[sid] = name.isEmpty ? 'subagent' : name;
              return true;
            }
          }
        }
        return false;
      case 'message.updated':
        final info = props['info'];
        if (info is Map && _mine(info['sessionID'])) {
          if (info['role'] == 'user') _userMsgs.add('${info['id']}');
          // A subagent's messages only mark their own user prompts; the finish and tokens counted are this turn's.
          if (info['sessionID'] != session) return false;
          if (info['role'] == 'assistant') {
            _noteFinish(info);
            // The engine's own summary of the folded part: the message it marks `summary: true`. Its words become
            // the compact note, never a reply of the model.
            if (info['summary'] == true) {
              compacted = true;
              summaryMsg = '${info['id']}';
            }
          }
          final tk = info['tokens'];
          if (info['role'] == 'assistant' && tk is Map) {
            int n(Object? v) => v is num ? v.toInt() : 0;
            _tokens['${info['id']}'] = n(tk['input']) + n(tk['output']) + n(tk['reasoning']);
            if (n(tk['input']) > 0) contextUsed = n(tk['input']);
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
        if (p is! Map || !_mine(p['sessionID'])) return false;
        final id = '${p['id']}';
        final type = '${p['type']}';
        final child = p['sessionID'] == session ? null : '${p['sessionID']}';
        // The engine folded the older part of this chat: the marker part says so, even though it rides inside a
        // user message (owner 2026-11-10).
        if (type == 'compaction') {
          compacted = true;
          return true;
        }
        if (_userMsgs.contains('${p['messageID']}')) return false;
        if (type == 'reasoning') {
          // opencode's thinking: shown as it streams, like opencode's own desktop chat (owner, 2026-11-03).
          final part = parts[id] ??= (OcPart(id, 'reasoning')..child = child);
          if (p['text'] is String && (p['text'] as String).length >= part.text.length) part.text = p['text'] as String;
          final t = p['time'];
          if (t is Map && t['end'] != null) part.status = 'completed';
          reasoning = part.status != 'completed';
          return true;
        }
        if (type == 'text') {
          if (p['synthetic'] == true) return false;
          // The words of the engine's own summary: kept as the compact note, never shown as a reply.
          if (summaryMsg != null && '${p['messageID']}' == summaryMsg) {
            summary = '${p['text'] ?? ''}';
            return true;
          }
          final part = parts[id] ??= (child == null ? _newText(id) : (OcPart(id, 'text')..child = child));
          part.text = '${p['text'] ?? ''}';
          final t = p['time'];
          if (t is Map && t['end'] != null) part.status = 'completed';
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
          // A step after a continue: the next text is a new paragraph, not the cut text going on.
          if (!parts.containsKey(id)) _glueTo = null;
          final part = parts[id] ??= (OcPart(id, 'tool')..child = child);
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
        if (!_mine(props['sessionID']) || props['field'] != 'text' || _userMsgs.contains('${props['messageID']}')) return false;
        final id = '${props['partID']}';
        final child = props['sessionID'] == session ? null : '${props['sessionID']}';
        final part = parts[id] ??= (child != null
            ? (OcPart(id, 'text')..child = child)
            : (reasoning ? OcPart(id, 'reasoning') : _newText(id)));
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

  /// The subagent session this part came from (null for the turn's own parts).
  String? child;

  /// A text part that goes on from where a cut reply stopped ([OpenCodeTurn.beginContinue]): the id of the text part
  /// it continues. Shown and read as one text with it.
  String? continues;
  bool get finished => status == 'completed' || status == 'error';
}

/// opencode's permission and question requests as Telesia asks (the card above the composer): a command to run asks
/// "Run this command?" with Allow · Always allow · Deny; a question from opencode's question tool shows its choices.
/// The answer goes back to the engine, which then carries on (or stops that step on Deny). Pure, so it is tested
/// without the engine or the app.
class OpenCodeAsks {
  OpenCodeAsks({required this.ask, required this.permit, required this.answer, required this.convOf, this.autopilot, this.unattended, this.refused});

  /// A run nobody is watching (a bot's scheduled task with Telesia closed, 2026-11-05): returns how to answer a
  /// permission ('once' | 'reject', see BgRun.permission) without showing a card, or null when someone can answer.
  /// [perm] is '' for a question from opencode's question tool (always skipped then: only the owner could answer).
  final String? Function(String conv, String perm)? unattended;

  /// Told when an unattended run was refused something, with the card's title and detail, so the owner gets one
  /// notification saying what was needed.
  final void Function(String conv, String title, String detail)? refused;

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
        // Autopilot (Full access) allows work without asking, never a loop: opencode asks doom_loop when the same tool
        // call repeats three times in a row, and allowing it let a bot repeat the same save without end (2026-11-06).
        await permit(id, '${p['permission'] ?? ''}' == 'doom_loop' ? 'reject' : 'once');
        return true;
      }
      final (title, prompt) = permissionText('${p['permission'] ?? ''}', p['patterns'], p['metadata']);
      // Nobody is watching: answered at once, never a card the run would wait on until the app opens.
      final bg = unattended?.call(conv, '${p['permission'] ?? ''}');
      if (bg != null) {
        if (bg != 'once') refused?.call(conv, title, prompt);
        await permit(id, bg == 'once' ? 'once' : 'reject');
        return true;
      }
      final a = await ask(conv, title, prompt, const [allow, always, deny]);
      await permit(id, a == allow ? 'once' : (a == always ? 'always' : 'reject'));
      return true;
    }
    final qs = p['questions'] is List ? p['questions'] as List : const [];
    // A question in a run nobody is watching is skipped at once (the model carries on with its best judgment).
    if (unattended?.call(conv, '') != null) {
      await answer(id, null);
      return true;
    }
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
