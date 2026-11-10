import 'cloud.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:record/record.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'live_audio.dart';
import 'live_retranscribe.dart';
import 'session_rules.dart';
import 'somali.dart';
import 'tools.dart';

class LiveTurn {
  final String role; // 'user' | 'assistant'
  String text;

  /// A caller turn whose live transcript is wrong (Somali heard as Spanish or Hindi) and is being written down
  /// again: captions show a placeholder instead of the wrong words.
  bool fixing = false;
  LiveTurn(this.role, this.text);

  /// What captions show.
  String get shown => fixing ? '\u2026' : text;
}

enum LiveStatus { connecting, listening, speaking, thinking, ended, error }

/// A real-time voice conversation with Gemini Live (WebSocket, PCM audio both ways).
class LiveSession extends ChangeNotifier {
  /// Filled in when the call starts: Telesia Cloud hands out a short-lived pass and the model to use.
  String model = '';
  final String voice;
  final String systemPrompt;
  final bool toolsEnabled;
  final Future<String> Function(String name, Map<String, dynamic> args) runTool;

  /// All tools the chat can use (connectors, apps, web, phone...). Empty = basic tools.
  final List<Map<String, dynamic>> tools;

  /// Writes one caller turn (a WAV clip) down again with a model that knows Somali ([somali] = the caller is known
  /// to speak Somali, so the transcriber is told so). null = keep the live transcript.
  final Future<String> Function(Uint8List wav, bool somali)? retranscribe;

  /// The caller speaks Somali: their turns are written down again (also switched on during the call when either
  /// side's words read as Somali).
  bool somali;

  LiveSession({
    this.tools = const [],
    required this.voice,
    required this.systemPrompt,
    required this.toolsEnabled,
    required this.runTool,
    this.retranscribe,
    this.somali = false,
  });

  static const voices = ['Kore', 'Puck', 'Charon', 'Aoede', 'Fenrir', 'Leda', 'Orus', 'Zephyr'];

  LiveStatus status = LiveStatus.connecting;
  String? error;
  bool muted = false;
  double level = 0; // 0..1, drives the orb
  String toolLabel = '';
  final List<LiveTurn> turns = [];

  final UtteranceClipper _clip = UtteranceClipper();
  final List<_TurnFix> _fixes = [];
  bool _answering = false;

  /// Turns before this index are final and may be saved; a caller turn still being written down again is held back.
  int get settledUpTo {
    var upTo = turns.length;
    for (final f in _fixes) {
      final a = f.anchor;
      final limit = a != null
          ? a - 1
          : (turns.isNotEmpty && turns.last.role == 'user' ? turns.length - 1 : turns.length);
      if (limit < upTo) upTo = limit;
    }
    return math.max(0, upTo);
  }

  /// Waits (up to [timeout]) for caller turns still being written down again.
  Future<void> settleFixes({Duration timeout = const Duration(seconds: 10)}) async {
    if (_fixes.isEmpty) return;
    try {
      await Future.wait([for (final f in List.of(_fixes)) f.done]).timeout(timeout);
    } catch (_) {}
  }

  WebSocketChannel? _ws;
  StreamSubscription? _wsSub;
  final _rec = AudioRecorder();
  StreamSubscription<Uint8List>? _micSub;
  bool _ready = false;
  bool get ready => _ready;
  bool _closed = false;
  /// When the queued speech really ends (long answers arrive far faster than they are spoken).
  final PlaybackClock _clock = PlaybackClock();
  /// Keeps the speaker's own voice (and room noise) from reaching the server while Telesia speaks.
  final EchoGate _gate = EchoGate();
  Timer? _tick;

  /// The model is still sending the current answer (until generationComplete / turnComplete / interrupted).
  bool _generating = false;
  /// Tool steps running right now.
  int _toolsRunning = 0;
  /// goAway received: move to a new line once the answer has arrived, or by this time at the latest.
  DateTime? _goAwayBy;
  /// The line was renewed while an answer was still arriving: ask the model to finish it on the new line.
  bool _resumeCutAnswer = false;
  /// App notes waiting for Telesia to finish speaking (a note sent mid-answer would cut the answer off).
  final List<(String, DateTime)> _pendingNotes = [];

  /// Session resumption (plan 3 step 6): Gemini closes each connection after about 10 minutes (goAway first)
  /// and drops it on bad networks. The call then reconnects with a fresh single-use pass and this handle,
  /// so the conversation carries on where it was.
  String? _handle;
  /// Which connection is current; events from an older socket are ignored.
  int _gen = 0;
  /// Reconnects since the last good setup.
  int _retries = 0;
  static const _maxRetries = 2;
  bool _micOn = false;
  /// True while the line is being renewed (status shows "Reconnecting").
  bool reconnecting = false;
  /// The last close code and reason from Gemini, shown small under the error for testing.
  String? closeInfo;

  /// Call minutes (plan 6 item 3). The server hands out a call id with the first pass; every renewed line
  /// uses it, and the app reports connected time on a heartbeat so today's minutes stay right.
  String? callId;
  /// Connected time of this call, from the first finished setup (includes short reconnects).
  final Stopwatch _talk = Stopwatch();
  bool _connectedOnce = false;
  Timer? _beat;
  int _beatEvery = 30;
  /// When today's minutes run out, from the server's last count (null until the first pass).
  DateTime? _outAt;
  /// A short gentle line on the call screen ("About a minute of calls left today").
  String? notice;
  bool _warned = false;
  bool _endingForTime = false;
  int _shownLeft = -1;

  /// Seconds of calls left today (null before the first pass).
  int? get secondsLeft => _outAt == null ? null : math.max(0, _outAt!.difference(DateTime.now()).inSeconds);

  /// "12 min of calls left today", or the last-minute wording.
  String get minutesLeftText {
    final l = secondsLeft;
    if (l == null) return '';
    if (l <= 60) return 'Less than a minute of calls left today';
    return '${(l / 60).ceil()} min of calls left today';
  }

  void _setLeft(int seconds) {
    _outAt = DateTime.now().add(Duration(seconds: math.max(0, seconds)));
  }

  bool get playing => _clock.isPlaying(DateTime.now());
  bool _disposed = false;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _shutdown();
    super.dispose();
  }

  Future<void> start() async {
    try {
      if (!await _rec.hasPermission()) {
        _fail('Telesia needs the microphone for Live. Allow it in Android settings.');
        return;
      }
      FlutterPcmSound.setLogLevel(LogLevel.none);
      // The player says when its queue runs empty, so "speaking" lasts exactly as long as the speech.
      FlutterPcmSound.setFeedCallback((remaining) {
        if (remaining == 0 && !_closed) _clock.drained(DateTime.now());
      });
      await FlutterPcmSound.setFeedThreshold(0);
      await FlutterPcmSound.setup(sampleRate: 24000, channelCount: 1);
      _tick = Timer.periodic(const Duration(milliseconds: 120), (_) => _onTick());
      await _connect();
    } catch (e) {
      debugPrint('Live connect failed: ${LogScrub.clean(e)}');
      if (_retries < _maxRetries && e is! CloudException) {
        unawaited(_reconnect());
      } else {
        _fail(_friendly(e));
      }
    }
  }

  /// Opens one connection: a fresh single-use pass from Telesia Cloud (a used pass is refused with
  /// "Token has been used too many times"), then the setup, resuming the session when there is a handle.
  Future<void> _connect() async {
    final gen = ++_gen;
    // A renewed line inside a call that has connected keeps its call id; otherwise it is a new call.
    final resume = _connectedOnce && callId != null;
    final pass = await Cloud.liveToken(callId: resume ? callId : null, seconds: resume ? _talk.elapsed.inSeconds : null);
    callId = pass.callId.isEmpty ? callId : pass.callId;
    _beatEvery = pass.heartbeat.clamp(15, 60).toInt();
    _setLeft(pass.secondsLeft);
    if (_closed || gen != _gen) return;
    // A resumed session must keep its model.
    if (model.isEmpty || _handle == null) model = pass.model;
    final uri = Uri.parse('${pass.wsUrl}?access_token=${Uri.encodeQueryComponent(pass.token)}');
    final ws = WebSocketChannel.connect(uri);
    await ws.ready.timeout(const Duration(seconds: 15));
    if (_closed || gen != _gen) {
      try {
        await ws.sink.close();
      } catch (_) {}
      return;
    }
    _ws = ws;
    _wsSub = ws.stream.listen(
      (raw) {
        if (gen == _gen) unawaited(_onMessage(raw));
      },
      onError: (Object e) {
        if (gen == _gen) _onDrop(ws, e);
      },
      onDone: () {
        if (gen == _gen) _onDrop(ws, null);
      },
    );
    ws.sink.add(jsonEncode({'setup': _setup()}));
    // An open line that never finishes setup counts as a drop.
    Timer(const Duration(seconds: 20), () {
      if (_closed || gen != _gen || _ready) return;
      closeInfo = 'setup timed out';
      debugPrint('Live $closeInfo');
      if (_retries < _maxRetries) {
        unawaited(_reconnect());
      } else {
        _fail('The call took too long to connect. Check your internet, then tap Call again.');
      }
    });
  }

  /// The line closed without the user hanging up: log why, then reconnect (twice at most) or explain.
  void _onDrop(WebSocketChannel ws, Object? err) {
    if (_closed) return;
    final code = ws.closeCode;
    final reason = ws.closeReason ?? '';
    var info = 'code ${code ?? '-'}${reason.isEmpty ? '' : ': $reason'}${err == null ? '' : ' ($err)'}';
    // The socket error can carry the call's URL with its access token: never log or keep it.
    info = LogScrub.clean(info);
    if (info.length > 200) info = info.substring(0, 200);
    closeInfo = info;
    debugPrint('Live closed: $info');
    // 1007 = the setup was refused, 1008 = model or access refused: another try would fail the same way.
    final fatal = code == 1007 || code == 1008;
    if (fatal && reconnecting && _handle != null && _retries < _maxRetries) {
      // The old session could not be resumed: start a fresh one rather than end the call.
      _handle = null;
      unawaited(_reconnect());
      return;
    }
    if (!fatal && _retries < _maxRetries) {
      unawaited(_reconnect());
      return;
    }
    _fail(_closeMessage(code, reason));
  }

  /// Renews the line with a fresh pass and the resumption handle. The mic keeps running; audio waits until setup is done.
  Future<void> _reconnect() async {
    if (_closed) return;
    _retries++;
    _gen++; // late events from the old socket are ignored from here on
    _ready = false;
    _goAwayBy = null;
    // Audio already received keeps playing; only an answer still arriving is lost with the old line.
    if (_generating) _resumeCutAnswer = true;
    _generating = false;
    reconnecting = true;
    status = LiveStatus.connecting;
    notifyListeners();
    final oldWs = _ws;
    final oldSub = _wsSub;
    _ws = null;
    _wsSub = null;
    unawaited(() async {
      try {
        await oldSub?.cancel().timeout(const Duration(milliseconds: 800));
      } catch (_) {}
      try {
        await oldWs?.sink.close().timeout(const Duration(milliseconds: 800));
      } catch (_) {}
    }());
    if (_retries > 1) await Future<void>.delayed(const Duration(seconds: 1));
    if (_closed) return;
    try {
      await _connect();
    } catch (e) {
      if (_closed) return;
      debugPrint('Live reconnect failed: ${LogScrub.clean(e)}');
      if (_retries < _maxRetries && e is! CloudException) {
        unawaited(_reconnect());
      } else {
        _fail(_friendly(e));
      }
    }
  }

  static String _friendly(Object e) {
    if (e is CloudException) return e.message;
    return 'The call could not connect. Check your internet, then tap Call again.';
  }

  static String _closeMessage(int? code, String reason) {
    final r = reason.toLowerCase();
    if (r.contains('not found') || r.contains('not supported')) {
      return 'Live voice is being updated right now. Please try again a little later.';
    }
    if (r.contains('quota') || r.contains('exhaust') || r.contains('rate limit')) {
      return 'Live voice is busy right now. Please try again in a minute.';
    }
    if (r.contains('deadline') || r.contains('expire') || r.contains('token')) {
      return 'The call took too long to connect. Check your internet, then tap Call again.';
    }
    if (code == 1007 || code == 1008) return 'Live voice could not start this call. Please try again a little later.';
    return 'The line dropped and could not reconnect. Check your internet, then tap Call again.';
  }

  /// Gemini accepts only part of JSON Schema: keep the parts it knows.
  static Map<String, dynamic> cleanSchema(dynamic s) {
    if (s is! Map) return {'type': 'object', 'properties': <String, dynamic>{}};
    final out = <String, dynamic>{};
    var type = s['type'];
    if (type is List) type = type.firstWhere((e) => e != 'null', orElse: () => 'string');
    if (s['description'] != null) out['description'] = '${s['description']}';
    if (s['enum'] is List) out['enum'] = [for (final e in s['enum'] as List) '$e'];
    if (type == null && s['properties'] is Map) type = 'object';
    if (type == null) {
      // free-form value (any JSON): describe it as text
      out['type'] = 'string';
      out['description'] = '${out['description'] ?? ''} (JSON as text)'.trim();
      return out;
    }
    out['type'] = '$type';
    if (type == 'object') {
      final props = <String, dynamic>{};
      final p = s['properties'];
      if (p is Map) p.forEach((k, v) => props['$k'] = cleanSchema(v));
      if (props.isEmpty) {
        return {'type': 'string', 'description': '${out['description'] ?? ''} (JSON object as text)'.trim()};
      }
      out['properties'] = props;
      if (s['required'] is List) {
        out['required'] = [for (final r in s['required'] as List) if (props.containsKey('$r')) '$r'];
      }
    } else if (type == 'array') {
      out['items'] = s['items'] is Map ? cleanSchema(s['items']) : {'type': 'string'};
    }
    return out;
  }

  Map<String, dynamic> _setup() {
    final decls = <Map<String, dynamic>>[];
    if (toolsEnabled) {
      final seen = <String>{};
      for (final d in (tools.isEmpty ? AgentTools.definitions : tools)) {
        final f = d['function'] as Map<String, dynamic>;
        final name = '${f['name']}';
        if (!seen.add(name)) continue;
        var desc = '${f['description'] ?? ''}';
        if (desc.length > 900) desc = desc.substring(0, 900);
        decls.add({'name': name, 'description': desc, 'parameters': cleanSchema(f['parameters'])});
        if (decls.length >= 120) break;
      }
    }
    return {
      'model': model.startsWith('models/') ? model : 'models/$model',
      'generationConfig': {
        'responseModalities': ['AUDIO'],
        'speechConfig': {
          'voiceConfig': {
            'prebuiltVoiceConfig': {'voiceName': voice}
          }
        },
      },
      'systemInstruction': {
        'parts': [
          {'text': systemPrompt}
        ]
      },
      // Long calls keep going instead of hitting the context limit: the oldest turns slide out.
      'contextWindowCompression': {'slidingWindow': <String, dynamic>{}},
      // Lets a dropped or renewed connection continue the same conversation.
      'sessionResumption': <String, dynamic>{if (_handle != null) 'handle': _handle},
      // Voice detection: the user's start needs a little more than a click or a breath, and a short pause
      // mid-sentence does not end their turn. Talking over Telesia still stops it at once.
      'realtimeInputConfig': liveRealtimeInputConfig,
      'inputAudioTranscription': <String, dynamic>{},
      'outputAudioTranscription': <String, dynamic>{},
      if (decls.isNotEmpty)
        'tools': [
          {'functionDeclarations': decls}
        ],
    };
  }

  Future<void> _startMic() async {
    final stream = await _rec.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: 16000,
      numChannels: 1,
      echoCancel: true,
      noiseSuppress: true,
      autoGain: true,
      // The voice-call mic, where Android's echo canceller works. record_android 1.2.6 (pinned) always uses it;
      // newer versions default to a raw source, so it is asked for explicitly in case the pin is lifted.
      androidConfig: AndroidRecordConfig(audioSource: AndroidAudioSource.voiceCommunication),
    ));
    _micSub = stream.listen(_onMic);
  }

  void _onMic(Uint8List chunk) {
    if (!_ready || _closed) return;
    final rms = pcmRms(chunk);
    final now = DateTime.now();
    final speaking = _clock.isPlaying(now);
    // While Telesia speaks the mic goes out as silence, unless the user clearly talks over it.
    final out = _gate.process(chunk, rms, playing: speaking, speakerLevel: _clock.levelAt(now), muted: muted);
    if (!speaking) level = muted ? 0 : (level * 0.6 + math.min(1.0, rms * 4) * 0.4);
    for (final data in out.send) {
      if (retranscribe != null && !muted) _clip.add(data);
      _send({
        'realtimeInput': {
          'audio': {'data': base64Encode(data), 'mimeType': 'audio/pcm;rate=16000'}
        }
      });
    }
  }

  void _send(Map<String, dynamic> msg) {
    if (_closed) return;
    try {
      _ws?.sink.add(jsonEncode(msg));
    } catch (_) {}
  }

  Future<void> _onMessage(dynamic raw) async {
    final text = raw is String ? raw : utf8.decode(raw as List<int>, allowMalformed: true);
    Map<String, dynamic> m;
    try {
      m = jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    if (m.containsKey('setupComplete')) {
      _ready = true;
      _retries = 0;
      reconnecting = false;
      status = playing ? LiveStatus.speaking : LiveStatus.listening;
      notifyListeners();
      if (_resumeCutAnswer) {
        _resumeCutAnswer = false;
        _queueNote('(Note from the app, not the user: the line was renewed while you were answering, so the user did not '
            'hear the end of your last answer. Finish it from where it stopped, without starting over and without '
            'mentioning the line.)');
      }
      if (!_connectedOnce) {
        // The line is up: minutes start counting now (on the server too).
        _connectedOnce = true;
        _talk.start();
        unawaited(_heartbeat());
        _beat = Timer.periodic(Duration(seconds: _beatEvery), (_) => unawaited(_heartbeat()));
      }
      if (!_micOn) {
        _micOn = true;
        await _startMic();
      }
      return;
    }
    final sru = m['sessionResumptionUpdate'];
    if (sru is Map) {
      final h = sru['newHandle'];
      if (sru['resumable'] == true && h is String && h.isNotEmpty) _handle = h;
    }
    final sc = m['serverContent'] as Map<String, dynamic>?;
    if (sc != null) {
      if (sc['interrupted'] == true) {
        // The user really spoke (the gate only lets a clear voice through): stop speaking and listen.
        _generating = false;
        await _flushPlayback();
        status = LiveStatus.listening;
      }
      final inT = (sc['inputTranscription'] as Map?)?['text'];
      if (inT is String && inT.isNotEmpty) {
        _appendTurn('user', inT);
        // Somali callers: the live transcriber has no Somali, so its words are hidden until written down again.
        final last = turns.last;
        if (retranscribe != null && !muted && (somali || Somali.looksMisheard(last.text))) last.fixing = true;
      }
      final outT = (sc['outputTranscription'] as Map?)?['text'];
      final parts = ((sc['modelTurn'] as Map?)?['parts'] as List?) ?? const [];
      // Telesia starts answering: what the caller said since the last answer is one turn.
      if (!_answering && sc['interrupted'] != true && (parts.isNotEmpty || (outT is String && outT.isNotEmpty))) {
        _answering = true;
        _cutCallerTurn();
      }
      if (outT is String && outT.isNotEmpty) {
        _appendTurn('assistant', outT);
        if (!somali && Somali.detect(turns.last.text)) somali = true;
      }
      if (parts.isNotEmpty && sc['interrupted'] != true) {
        _generating = true;
      }
      for (final p in parts) {
        final inline = (p as Map)['inlineData'] as Map?;
        if (inline != null && inline['data'] is String) {
          final bytes = base64Decode(inline['data'] as String);
          _play(bytes);
        }
      }
      // generationComplete: the whole answer is here (it may still be playing for a while).
      // turnComplete: the server closed the turn. Neither stops playback: the queue plays to the end.
      if (sc['generationComplete'] == true) _generating = false;
      if (sc['turnComplete'] == true) {
        _generating = false;
        _answering = false;
      }
      if (sc['interrupted'] == true) _answering = false;
      notifyListeners();
    }
    final goAway = m['goAway'];
    if (goAway != null && _goAwayBy == null) {
      // Gemini will close this connection soon (about every 10 minutes). Moving at once would lose an answer
      // that is still arriving, so the move waits for it, up to a few seconds before the close.
      final left = parseLiveDuration(goAway is Map ? goAway['timeLeft'] : null) ?? const Duration(seconds: 10);
      final margin = left > const Duration(seconds: 6) ? const Duration(seconds: 3) : const Duration(seconds: 1);
      _goAwayBy = DateTime.now().add(left - margin);
      closeInfo = 'goAway ${goAway is Map ? goAway['timeLeft'] ?? '' : ''}'.trim();
      debugPrint('Live $closeInfo');
      _maybeMoveLine();
    }
    final tc = m['toolCall'] as Map<String, dynamic>?;
    if (tc != null) await _handleTools(tc);
  }

  /// After a goAway: renew the line once the current answer has fully arrived (or time is nearly up).
  void _maybeMoveLine() {
    final by = _goAwayBy;
    if (by == null || _closed || !_ready) return;
    if (!goAwayMoveNow(now: DateTime.now(), deadline: by, generating: _generating, toolRunning: _toolsRunning > 0)) return;
    _goAwayBy = null;
    _retries = 0;
    unawaited(_reconnect());
  }

  void _appendTurn(String role, String text) {
    if (turns.isNotEmpty && turns.last.role == role) {
      turns.last.text += text;
    } else {
      turns.add(LiveTurn(role, text.trimLeft()));
      if (role == 'assistant') {
        for (final f in _fixes) {
          f.anchor ??= turns.length - 1;
        }
      }
    }
  }

  /// Sends the caller's last turn to be written down again, and puts the result in its place. Done for every turn
  /// of a Somali caller, and for any turn whose live transcript looks wrong (Spanish, Hindi or a foreign script),
  /// since the live transcriber has no Somali and that is how Somali comes out of it.
  void _cutCallerTurn() {
    final fn = retranscribe;
    final userAt = turns.lastIndexWhere((t) => t.role == 'user');
    final live = userAt < 0 ? null : turns[userAt];
    if (fn == null) {
      live?.fixing = false;
      return;
    }
    final lastUser = live?.text ?? '';
    if (!somali && Somali.detect(lastUser)) somali = true;
    final unsure = Somali.looksMisheard(lastUser);
    final pcm = _clip.cut();
    if (pcm == null || (!somali && !unsure)) {
      live?.fixing = false;
      return;
    }
    final fix = _TurnFix();
    _fixes.add(fix);
    final knownSomali = somali;
    fix.done = () async {
      try {
        final wav = wavFromPcm16(pcm);
        var text = cleanTurnTranscript(await fn(wav, knownSomali).timeout(const Duration(seconds: 25)));
        // A known Somali caller and still Spanish or Hindi look-alikes: one more try.
        if (knownSomali && Somali.looksMisheard(text)) {
          final again = cleanTurnTranscript(await fn(wav, true).timeout(const Duration(seconds: 25)));
          if (again.isNotEmpty && !Somali.looksMisheard(again)) text = again;
        }
        if (text.isNotEmpty) {
          if (!somali && Somali.detect(text)) somali = true;
          _applyFix(fix, text);
        }
      } catch (_) {
        // Keep the live transcript.
      } finally {
        _fixes.remove(fix);
        _unhide(fix, live);
        notifyListeners();
      }
    }();
  }

  /// After a fix (or a failed one) the caller's turn is shown again.
  void _unhide(_TurnFix fix, LiveTurn? live) {
    live?.fixing = false;
    final end = fix.anchor ?? turns.length;
    if (end > 0 && end <= turns.length && turns[end - 1].role == 'user') turns[end - 1].fixing = false;
  }

  void _applyFix(_TurnFix fix, String text) {
    final end = fix.anchor ?? turns.length;
    // The caller's turn sits right before the answer; with no live transcript at all, it is added there.
    if (end > 0 && end <= turns.length && turns[end - 1].role == 'user') {
      turns[end - 1]
        ..text = text
        ..fixing = false;
      return;
    }
    final at = end.clamp(0, turns.length);
    turns.insert(at, LiveTurn('user', text));
    for (final f in _fixes) {
      final a = f.anchor;
      if (a != null && a >= at) f.anchor = a + 1;
    }
  }

  void _play(Uint8List bytes) {
    if (bytes.isEmpty) return;
    _clock.feed(bytes, DateTime.now());
    status = LiveStatus.speaking;
    level = level * 0.5 + math.min(1.0, pcmRms(bytes) * 4) * 0.5;
    // Own buffer: the plugin sends `bytes.buffer` whole, so never pass a view.
    final own = Uint8List.fromList(bytes);
    FlutterPcmSound.feed(PcmArrayInt16(bytes: own.buffer.asByteData()));
  }

  Future<void> _flushPlayback() async {
    _clock.flush();
    try {
      await FlutterPcmSound.release();
      await FlutterPcmSound.setup(sampleRate: 24000, channelCount: 1);
    } catch (_) {}
  }

  Future<void> _handleTools(Map<String, dynamic> tc) async {
    _toolsRunning++;
    try {
      await _runTools(tc);
    } finally {
      _toolsRunning--;
    }
  }

  Future<void> _runTools(Map<String, dynamic> tc) async {
    final gen = _gen;
    // A tool call ends what the model was sending; it carries on after the result.
    _generating = false;
    final calls = (tc['functionCalls'] as List?) ?? const [];
    final responses = <Map<String, dynamic>>[];
    for (final c in calls) {
      final call = Map<String, dynamic>.from(c as Map);
      final name = (call['name'] ?? '').toString();
      final args = Map<String, dynamic>.from((call['args'] as Map?) ?? const {});
      status = LiveStatus.thinking;
      toolLabel = AgentTools.describe(name, args, done: false);
      notifyListeners();
      final out = await runTool(name, args);
      responses.add({
        'id': call['id'],
        'name': name,
        'response': {'result': out.length > 8000 ? out.substring(0, 8000) : out},
      });
    }
    toolLabel = '';
    if (_closed) return;
    if (gen != _gen) {
      // The line was renewed while the tool ran: the new connection does not know these call ids,
      // so the result goes in as words once it is ready.
      for (var i = 0; i < 80 && !_closed && !_ready; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      var text = responses.map((r) => '${r['name']}: ${(r['response'] as Map)['result']}').join('\n');
      if (text.length > 4000) text = text.substring(0, 4000);
      _queueNote('(The line was renewed while you were working. Result of the action you started: $text)');
      return;
    }
    status = LiveStatus.listening;
    notifyListeners();
    _send({
      'toolResponse': {'functionResponses': responses}
    });
  }

  /// Tells the server how long the call has been connected and hears back how much is left today.
  Future<void> _heartbeat() async {
    final id = callId;
    if (id == null || _closed) return;
    final r = await Cloud.liveUsage(id, _talk.elapsed.inSeconds);
    if (r == null || _closed) return;
    _setLeft(r.secondsLeft);
    if (r.stop) unawaited(_outOfMinutes());
  }

  /// A minute before the end: one gentle word. At the end: a short goodbye, then the call stops.
  void _checkMinutes() {
    final l = secondsLeft;
    if (l == null || !_connectedOnce || _endingForTime) return;
    if (l <= 60 && !_warned) {
      _warned = true;
      notice = 'About a minute of calls left today';
      notifyListeners();
      _queueNote('(Note from the app, not the user: about one minute of call time is left for today. '
          'Mention it kindly in one short sentence, then carry on.)');
    }
    if (l <= 0) unawaited(_outOfMinutes());
  }

  Future<void> _outOfMinutes() async {
    if (_endingForTime || _closed) return;
    _endingForTime = true;
    notice = 'That\'s all the call time for today';
    notifyListeners();
    _sendTurn('(Note from the app, not the user: today\'s call time is over. Say a very short, warm goodbye '
        'and say calls come back tomorrow. Nothing else.)');
    // Let the goodbye play (a few seconds at most), then stop.
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    final until = DateTime.now().add(const Duration(seconds: 8));
    while (!_closed && DateTime.now().isBefore(until) && (playing || status == LiveStatus.speaking)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    _fail(Cloud.calls.value.usedUpMessage);
  }

  void _onTick() {
    if (_closed) return;
    var changed = false;
    _checkMinutes();
    _maybeMoveLine();
    _flushNotes();
    final shown = secondsLeft == null ? -1 : (secondsLeft! <= 60 ? 0 : (secondsLeft! / 60).ceil());
    if (shown != _shownLeft) {
      _shownLeft = shown;
      changed = true;
    }
    if (status == LiveStatus.speaking && !playing) {
      status = LiveStatus.listening;
      changed = true;
    }
    final target = playing ? level : level * 0.7;
    if ((target - level).abs() > 0.01 || level > 0.01) {
      level = target;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  /// Sends app news (a finished task, a question) into the conversation so the voice speaks it.
  /// It waits until Telesia has finished speaking: a new turn sent mid-answer would cut that answer off.
  void inject(String text) => _queueNote(text);

  void _queueNote(String text) {
    if (_closed || text.trim().isEmpty) return;
    _pendingNotes.add((text, DateTime.now()));
    _flushNotes();
  }

  void _flushNotes() {
    if (_pendingNotes.isEmpty || !_ready || _closed) return;
    final now = DateTime.now();
    final may = injectMayGo(
      speaking: playing,
      generating: _generating,
      toolRunning: _toolsRunning > 0,
      waited: now.difference(_pendingNotes.first.$2),
    );
    if (!may) return;
    final notes = [for (final n in _pendingNotes) n.$1];
    _pendingNotes.clear();
    _sendTurn(notes.join('\n'));
  }

  /// Sends one turn now (the user's own typed words, or a note that cannot wait).
  void _sendTurn(String text) {
    if (!_ready || _closed || text.trim().isEmpty) return;
    _send({
      'clientContent': {
        'turns': [
          {
            'role': 'user',
            'parts': [
              {'text': text}
            ]
          }
        ],
        'turnComplete': true,
      }
    });
  }

  /// Typed message from the floating chat box: shown in the captions and answered out loud.
  void sendText(String text) {
    if (!_ready || _closed || text.trim().isEmpty) return;
    turns.add(LiveTurn('user', text.trim()));
    notifyListeners();
    // The user's own words go at once (like talking over Telesia, they may stop the current answer).
    _sendTurn(text.trim());
  }

  void toggleMute() {
    muted = !muted;
    notifyListeners();
  }

  void _fail(String msg) {
    if (_closed) return;
    error = msg;
    reconnecting = false;
    status = LiveStatus.error;
    notifyListeners();
    _shutdown();
  }

  Future<void> end() async {
    if (_closed) return;
    status = LiveStatus.ended;
    notifyListeners();
    await _shutdown();
  }

  Future<void> _shutdown() async {
    if (_closed) return;
    _closed = true;
    _gen++;
    _tick?.cancel();
    _beat?.cancel();
    _talk.stop();
    // Last heartbeat: the call is over, so its time is final (not waited on, hanging up stays instant).
    final id = callId;
    if (id != null) unawaited(Cloud.liveUsage(id, _talk.elapsed.inSeconds, end: true));
    // Every step is time-boxed so hanging up is always instant, even on a bad connection.
    Future<void> boxed(Future<void> Function() f) async {
      try {
        await f().timeout(const Duration(milliseconds: 800));
      } catch (_) {}
    }

    await boxed(() async => _micSub?.cancel());
    await boxed(() => _rec.stop());
    try {
      _rec.dispose();
    } catch (_) {}
    await boxed(() async => _wsSub?.cancel());
    await boxed(() async => _ws?.sink.close());
    await boxed(() => FlutterPcmSound.release());
  }
}

class _TurnFix {
  /// Index of Telesia's answer that followed the caller's turn (null until it starts).
  int? anchor;
  Future<void> done = Future.value();
}
