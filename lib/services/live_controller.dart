import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../app_state.dart';
import 'cloud.dart';
import 'live_session.dart';
import 'live_tasks.dart';
import 'screen_control.dart';
import 'task_bubble.dart';
import 'somali.dart';
import 'system_bridge.dart';
import 'wake_word.dart';
import '../ui/haptics.dart';

/// Owns the Live call, so it keeps going when the Live screen closes:
/// full screen in the app, a floating card over other apps, or a small dot.
class LiveController extends ChangeNotifier {
  LiveController(this.app);
  final AppState app;

  LiveSession? session;
  /// Shown over other apps instead of the Live screen.
  bool floating = false;
  String overlayMode = 'popup';
  /// The Live screen is on top in the app.
  bool screenOpen = false;
  /// Asks the app to show the Live screen (set by main.dart).
  void Function()? openScreen;

  Timer? _push;
  int _lastPushedTurns = -1;
  String _lastStatus = '';
  bool _ending = false;

  bool get active => session != null;

  static final Map<String, dynamic> endCallTool = <String, dynamic>{
    'type': 'function',
    'function': <String, dynamic>{
      'name': 'end_call',
      'description': 'End this voice call. Use it when the user says to end, hang up, stop or close the call, '
          'or says goodbye and clearly wants to finish. Say a short goodbye first, then call this.',
      'parameters': <String, dynamic>{'type': 'object', 'properties': <String, dynamic>{}},
    },
  };

  /// Starts a call. [floating] shows it over other apps (wake word, "Float").
  /// The bot on this call (null for a normal SubMac call).
  String? botId;

  Future<String?> start({bool floating = false, String mode = 'popup', String? persona, String? voice, String? opening, String? convId, String? bot}) async {
    if (session != null) {
      if (floating && !this.floating) await float(mode: mode);
      return null;
    }
    if (!app.liveAvailable) return 'needs_key';
    _again = () => start(mode: mode, persona: persona, voice: voice, opening: opening, convId: convId, bot: bot);
    botId = bot;
    final s = LiveSession(
      voice: (voice != null && voice.isNotEmpty) ? voice : app.liveVoice,
      systemPrompt: '${persona == null || persona.isEmpty ? '' : '$persona\n\n'}${app.liveSystemPrompt(convId: convId)}\n'
          '- When the user wants to end the call (end the call, hang up, bye, that is all), say a short goodbye and call end_call.\n'
          '- You can change Telesia settings with app_settings when the user asks (theme, voice, wake word sensitivity, approval mode...).',
      toolsEnabled: true,
      runTool: _runTool,
      tools: <Map<String, dynamic>>[endCallTool, ...app.liveTools()],
      // Somali callers (and any turn the live transcript gets wrong): written down again by a model that knows Somali.
      retranscribe: Cloud.features.value.transcribe
          ? (wav, somali) => Cloud.transcribe(wav,
              mime: 'audio/wav', prompt: somali ? Somali.liveTurnPrompt : Somali.liveTurnPromptAuto)
          : null,
      somali: app.speaksSomali(convId),
    );
    session = s;
    _ending = false;
    _callStart = DateTime.now();
    _checkedTurn = -1;
    _lastPushedTurns = -1;
    app.beginLiveCall();
    // A bot's call is saved in that bot's own chat.
    if (convId != null && convId.isNotEmpty) app.liveConvId = convId;
    app.onLiveTaskNews = s.inject;
    s.addListener(_onChange);
    await WakeWord.I.liveStarted();
    await SystemBridge.I.liveHold(true);
    if (floating) await float(mode: mode);
    notifyListeners();
    unawaited(s.start());
    if (opening != null && opening.isNotEmpty) {
      unawaited(() async {
        for (var i = 0; i < 60 && session == s && !s.ready; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
        if (session == s && s.ready) s.inject(opening);
      }());
    }
    return null;
  }

  /// Tools that act on the phone's real screen: Live steps aside (floating card) first, so they see and tap the
  /// app the user means instead of SubMac's own Live screen.
  static const screenTools = {
    'phone_screen', 'phone_tap', 'phone_type', 'phone_scroll', 'phone_gesture', 'phone_long_press', 'phone_wait', 'phone_nav',
    'open_app', 'whatsapp',
  };

  /// One tool step longer than this answers early (the step keeps going on the phone), so the voice never sits silent
  /// and the session is never stuck waiting.
  static const stepLimit = Duration(seconds: 40);

  Future<String> _runTool(String name, Map<String, dynamic> args) async {
    if (name == 'end_call') {
      unawaited(_endAfterGoodbye());
      return 'Ending the call now. Say a very short goodbye (a few words) and nothing else.';
    }
    final bid = botId;
    if (name == 'recall') return app.recall('${args['query'] ?? ''}', botId: bid);
    if (screenTools.contains(name) && session != null && !floating) {
      // Out of the way: float the call, or at least move SubMac to the back, so the real app is on screen.
      if (!await float(mode: 'orb')) await SystemBridge.I.moveToBack();
      await Future<void>.delayed(const Duration(milliseconds: 350));
    }
    final job = app.runToolWithApproval(name, args, convId: bid == null ? null : app.botConvFor(bid));
    try {
      return await job.timeout(stepLimit);
    } on TimeoutException {
      final s = session;
      unawaited(job.then((out) {
        // The step finished after the early answer: tell the model what happened.
        if (session == s && s != null) {
          s.inject('(Result of the slow step $name that finished just now, from the app: '
              '${out.length > 1500 ? '${out.substring(0, 1500)}…' : out})');
        }
      }));
      return 'This step ($name) is still running on the phone; it is slow. Say "one moment" and wait for its result, which '
          'arrives as a note from the app. Do not say it runs in the background and do not repeat it.';
    }
  }

  // ---------------------------------------------------------------- the background-claim guard

  DateTime _callStart = DateTime.now();
  int _checkedTurn = -1;
  bool _correcting = false;

  /// The voice said it is working "in the background" with no real task behind it: correct it at once.
  void _guard(LiveSession s) {
    if (_correcting || s.turns.isEmpty) return;
    final i = s.turns.length - 1;
    final t = s.turns[i];
    if (t.role != 'assistant' || i == _checkedTurn) return;
    final fix = LiveGuard.correction(t.text, taskStarted: app.liveTasks.anySince(_callStart));
    if (fix == null) return;
    _checkedTurn = i;
    _correcting = true;
    unawaited(() async {
      // Let the sentence finish, then put it right.
      final until = DateTime.now().add(const Duration(seconds: 6));
      while (session == s && DateTime.now().isBefore(until) && (s.playing || s.status == LiveStatus.speaking)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      if (session == s) s.inject(fix);
      _correcting = false;
    }());
  }

  /// Lets the goodbye play, then hangs up.
  Future<void> _endAfterGoodbye() async {
    final s = session;
    if (s == null) return;
    await Future.delayed(const Duration(milliseconds: 1500));
    final until = DateTime.now().add(const Duration(seconds: 8));
    while (session == s && DateTime.now().isBefore(until) && (s.playing || s.status == LiveStatus.speaking)) {
      await Future.delayed(const Duration(milliseconds: 200));
    }
    if (session == s) await end();
  }

  void _onChange() {
    final s = session;
    if (s == null) return;
    final upTo = math.min(s.turns.length - 1, s.settledUpTo);
    if (upTo > 0) app.saveLiveTurns(s.turns, upTo);
    _guard(s);
    if (s.status == LiveStatus.ended && !_ending) {
      unawaited(end());
      return;
    }
    if (floating) _schedulePush();
    notifyListeners();
  }

  String statusText(LiveSession s) {
    switch (s.status) {
      case LiveStatus.connecting:
        return s.reconnecting ? 'Reconnecting' : 'Connecting';
      case LiveStatus.listening:
        return s.muted ? 'Muted' : 'Listening';
      case LiveStatus.speaking:
        return 'Speaking';
      case LiveStatus.thinking:
        return s.toolLabel.isEmpty ? 'Thinking' : s.toolLabel;
      case LiveStatus.ended:
        return 'Ending';
      case LiveStatus.error:
        return 'Live stopped';
    }
  }

  void _schedulePush() {
    if (_push?.isActive ?? false) return;
    _push = Timer(const Duration(milliseconds: 90), _pushOverlay);
  }

  void _pushOverlay() {
    final s = session;
    if (s == null || !floating) return;
    String caption = '', you = '';
    for (final t in s.turns.reversed) {
      if (t.role == 'assistant' && caption.isEmpty) caption = t.text.trim();
      if (t.role == 'user' && you.isEmpty) you = t.shown.trim();
      if (caption.isNotEmpty && you.isNotEmpty) break;
    }
    final st = s.error ?? statusText(s);
    final changed = st != _lastStatus || s.turns.length != _lastPushedTurns;
    _lastStatus = st;
    _lastPushedTurns = s.turns.length;
    unawaited(SystemBridge.I.overlayUpdate(
      status: st,
      level: s.level,
      caption: changed || caption.isNotEmpty ? caption : '',
      you: you,
      muted: s.muted,
      thinking: s.status == LiveStatus.thinking || s.status == LiveStatus.connecting,
    ));
  }

  /// Floats Live over other apps. Returns false when "Display over other apps" is not allowed yet.
  Future<bool> float({String mode = 'popup'}) async {
    if (session == null) return false;
    bool ok;
    try {
      ok = await SystemBridge.I.overlayShow(mode).timeout(const Duration(seconds: 3));
    } catch (_) {
      ok = false;
    }
    if (!ok) return false;
    floating = true;
    overlayMode = mode;
    _pushOverlay();
    notifyListeners();
    return true;
  }

  /// Back into the app: hide the floating card and show the Live screen.
  Future<void> unfloat({bool showScreen = true}) async {
    floating = false;
    unawaited(SystemBridge.I.overlayHide());
    if (showScreen) {
      await SystemBridge.I.bringToFront(route: 'live');
      openScreen?.call();
    }
    notifyListeners();
  }

  /// Events from the floating card.
  void onOverlay(String action, String? text) {
    final s = session;
    switch (action) {
      case 'end':
        unawaited(end());
        break;
      case 'open':
        unawaited(unfloat());
        break;
      case 'mute':
        s?.toggleMute();
        break;
      case 'text':
        if (s != null && text != null && text.trim().isNotEmpty) s.sendText(text.trim());
        break;
      case 'mode':
        overlayMode = text ?? 'popup';
        break;
    }
  }

  /// The wake word fired: start Live floating (or bring it up if it's already on).
  Future<void> onWake() async {
    SubHaptics.call();
    if (session != null) {
      if (floating) {
        await SystemBridge.I.overlayShow('popup');
      } else if (!screenOpen) {
        await float();
      }
      return;
    }
    final r = await start(floating: true);
    if (r == 'needs_key' || !floating) {
      // Voice not available right now, or no overlay permission: open the app instead.
      await SystemBridge.I.overlayHide();
      await SystemBridge.I.bringToFront(route: 'live');
      openScreen?.call();
    }
  }

  /// The app went to the background with Live on the screen: keep it as a small dot.
  Future<void> onAppHidden() async {
    if (session != null && !floating && screenOpen) await float(mode: 'orb');
  }

  /// How to place the last call again (same bot, voice and chat).
  Future<String?> Function()? _again;

  /// True while a dropped call is being placed again, so the Live screen stays open.
  bool restarting = false;

  /// "Call again" after a dropped call: ends what is left of it and starts the same call fresh.
  Future<void> restart() async {
    final again = _again;
    if (again == null || restarting) return;
    restarting = true;
    final wasFloating = floating;
    try {
      await end();
      // Let the old session's cleanup start before the new one opens the microphone.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      _ending = false;
      await again();
      if (wasFloating) await float();
    } finally {
      restarting = false;
      notifyListeners();
    }
  }

  Future<void> end() async {
    final s = session;
    if (s == null || _ending) return;
    _ending = true;
    SubHaptics.call();
    final turns = s.turns;
    s.removeListener(_onChange);
    session = null;
    if (app.onLiveTaskNews == s.inject) app.onLiveTaskNews = null;
    _push?.cancel();
    if (floating) {
      floating = false;
      unawaited(SystemBridge.I.overlayHide());
    }
    notifyListeners();
    // The call's screen steps (no chat of their own) end with the call, not 2 minutes later by the watchdog (T-19).
    TaskBubble.I.runEnded(ScreenControl.live);
    // Taken now: a call placed again right after this one sets its own bot.
    final bid = botId;
    botId = null;
    // The screen closes at once; the cleanup runs behind it.
    unawaited(() async {
      try {
        await s.end().timeout(const Duration(seconds: 4));
      } catch (_) {}
      unawaited(() async {
        // Somali turns still being written down again are put right before the call is saved.
        await s.settleFixes();
        final conv = await app.saveLiveTranscript(turns);
        if (bid != null) {
          await app.botCallEnded(bid, turns.length);
        } else {
          await app.liveCallEnded(turns, conv);
        }
      }());
      // A new call already started (Call again): it holds the microphone now, so leave it be.
      if (session == null) {
        try {
          await SystemBridge.I.liveHold(false);
          await WakeWord.I.liveEnded();
        } catch (_) {}
      }
      Future.delayed(const Duration(seconds: 2), s.dispose);
    }());
  }
}
