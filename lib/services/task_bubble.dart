import 'dart:async';
import 'dart:convert';

import '../app_state.dart';
import 'bots.dart';
import 'browser_agent.dart';
import 'offices.dart';
import 'screen_control.dart';
import 'system_bridge.dart';
import 'tools.dart';
import 'whatsapp.dart';

/// The floating chat while SubMac or a bot drives the screen, and the one place that decides when the
/// "SubMac is using your phone" badge comes down.
///
/// Every screen step (phone control, WhatsApp hands, the browser) passes through [stepStarted]/[stepFinished];
/// a run's end passes through [runEnded]. When no owner is left (or the watchdog drops a quiet one) the badge is
/// taken down and any steps still queued on the phone are cancelled, so it can never linger after a task.
class TaskBubble {
  TaskBubble._();
  static final I = TaskBubble._();

  final ScreenControl sc = ScreenControl();
  AppState? _app;
  Timer? _tick;
  Timer? _debounce;
  String _lastJson = '';
  DateTime _lastPush = DateTime.fromMillisecondsSinceEpoch(0);
  bool _shown = false;

  /// A phone-control step happened since the badge was last taken down.
  bool _badgeMayBeUp = false;
  _Confirm? _confirm;

  /// Steps that move the real screen: phone control, WhatsApp's buttons, the browser.
  static bool isScreenTool(String name) =>
      (name.startsWith('phone_') && name != 'phone_settings') ||
      name == 'open_app' ||
      WhatsAppTools.names.contains(name) ||
      BrowserAgent.names.contains(name);

  /// Steps that use phone control (the badge's own layer).
  static bool usesPhoneControl(String name) =>
      (name.startsWith('phone_') && name != 'phone_settings') || name == 'open_app' || WhatsAppTools.names.contains(name);

  void attach(AppState app) {
    if (_app != null) return;
    _app = app;
    app.addListener(_changed);
    Offices.I.addListener(_changed);
    SystemBridge.I.onBubble = _onAction;
  }

  // ---------------------------------------------------------------- steps and runs

  void stepStarted(String? convId, String name, String label) {
    if (!isScreenTool(name)) return;
    final id = (convId == null || convId.isEmpty) ? ScreenControl.live : convId;
    if (usesPhoneControl(name)) _badgeMayBeUp = true;
    sc.stepStarted(id, label, DateTime.now());
    final app = _app;
    if (app != null && app.runs.any((r) => r.convId == id)) sc.pin(id, DateTime.now());
    _sync();
  }

  void stepFinished(String? convId, String name) {
    if (!isScreenTool(name)) return;
    sc.stepFinished((convId == null || convId.isEmpty) ? ScreenControl.live : convId, DateTime.now());
  }

  /// A run ended (success, failure, cancel, a bot's background run). Its owner stops at once unless another run in
  /// the same chat is still going.
  void runEnded(String convId) {
    final app = _app;
    if (app != null && app.runs.any((r) => r.convId == convId)) return;
    if (_confirm?.convId == convId) _confirm!.answer(false);
    if (sc.end(convId)) _sync();
  }

  /// Stop from the bubble or the badge: every screen task stops and queued phone steps are cancelled.
  void stopAll() {
    final app = _app;
    if (app != null) {
      final ids = sc.owners.map((o) => o.id).toSet();
      for (final r in app.runs.where((r) => r.phone || r.browsing || ids.contains(r.convId)).toList()) {
        app.stopRun(r);
      }
    }
    _confirm?.answer(false);
    sc.clear();
    _badgeMayBeUp = true; // always send the halt, even if this side never saw a step
    _sync();
  }

  /// The app (re)started: nothing can be controlling the screen yet, so clear anything the phone still shows.
  void reset() {
    sc.clear();
    _confirm = null;
    _shown = false;
    _lastJson = '';
    unawaited(SystemBridge.I.screenReset());
  }

  // ---------------------------------------------------------------- asking in the bubble

  /// Asks [req] in the floating bubble when the user is outside SubMac and this chat is driving the screen.
  /// Returns null when the bubble can't ask (the caller asks in the app as before), or when the user opened
  /// SubMac while it waited (the app asks instead).
  Future<bool?> confirm(ActionRequest req, String? convId) async {
    final app = _app;
    if (app == null || !SystemBridge.I.supported || convId == null || app.appVisible || app.liveCtl.active) return null;
    if (sc.owner(convId) == null) return null;
    _confirm?.answer(false);
    final c = _Confirm('c${DateTime.now().millisecondsSinceEpoch}', convId, req);
    _confirm = c;
    _sync(force: true);
    final r = await c.done.future;
    if (identical(_confirm, c)) _confirm = null;
    _sync(force: true);
    return r;
  }

  bool _waiting(String id) {
    if (_confirm?.convId == id) return true;
    final app = _app;
    if (app == null) return false;
    if (app.asks.any((a) => a.convId == id)) return true;
    final bot = Bots.I.byConv(id);
    return bot != null && Offices.I.pending.any((a) => a.botId == bot.id);
  }

  BubbleAsk? _askFor(String id, String who) {
    final c = _confirm;
    if (c != null && c.convId == id) {
      return BubbleAsk(id: c.id, kind: 'confirm', who: who, title: c.req.title, body: c.req.body, editText: c.req.edit?.value);
    }
    final bot = Bots.I.byConv(id);
    if (bot != null) {
      final a = Offices.I.pending.where((x) => x.botId == bot.id).firstOrNull;
      if (a != null) return BubbleAsk(id: a.id, kind: 'approval', who: who, title: a.title, body: a.body, editText: a.editText);
    }
    final q = _app?.asks.where((a) => a.convId == id).firstOrNull;
    if (q != null) {
      final private = q.kind == 'login' || q.kind == 'login_confirm' || q.secret;
      return BubbleAsk(
          id: 'q${q.hashCode}', kind: 'question', who: who, title: q.title, body: private ? '' : q.prompt, options: q.options, needsApp: private);
    }
    return null;
  }

  // ---------------------------------------------------------------- keeping the phone in step

  void _changed() {
    if (!sc.any && !_shown) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _sync);
  }

  /// The app moved to or from the background.
  void visibilityChanged() {
    final c = _confirm;
    // Back in SubMac with a question waiting in the bubble: the app asks it instead.
    if (c != null && (_app?.appVisible ?? false)) c.answer(null);
    _sync(force: true);
  }

  void _sync({bool force = false}) {
    final app = _app;
    final now = DateTime.now();
    final dropped = sc.prune(now, waiting: _waiting);
    if (dropped.isNotEmpty && _confirm != null && dropped.contains(_confirm!.convId)) _confirm!.answer(false);
    if (!sc.any) {
      _tick?.cancel();
      _tick = null;
      if (_badgeMayBeUp) {
        _badgeMayBeUp = false;
        unawaited(SystemBridge.I.screenHalt());
      }
      _hide();
      return;
    }
    _tick ??= Timer.periodic(const Duration(seconds: 5), (_) => _sync());
    if (app == null) return;
    // Prefer the chat that is waiting on the user, then the most recent one.
    final waitingOwner = sc.owners.where((o) => o.id != ScreenControl.live && _waiting(o.id)).firstOrNull;
    final focus = waitingOwner ?? sc.focus();
    if (!bubbleAllowed(appVisible: app.appVisible, hasFocus: focus != null, liveFloating: app.liveCtl.active)) {
      _hide();
      return;
    }
    final id = focus!.id;
    final bot = Bots.I.byConv(id);
    final who = bot?.name ?? 'SubMac';
    final run = app.runs.where((r) => r.convId == id && !r.side).firstOrNull;
    final lines = bubbleLines(app.messagesOf(id).map((m) => (m.role, m.content)));
    final state = bubbleState(
      owner: id,
      who: who,
      step: run?.status ?? focus.label,
      lines: lines,
      ask: _askFor(id, who),
      canType: run != null,
    );
    final json = jsonEncode(state);
    // Unchanged state is re-sent now and then as a heartbeat: the phone hides the bubble if the app goes silent.
    if (!force && json == _lastJson && now.difference(_lastPush) < const Duration(seconds: 20)) return;
    _lastJson = json;
    _lastPush = now;
    _shown = true;
    unawaited(SystemBridge.I.bubbleShow(json));
  }

  void _hide() {
    if (!_shown) return;
    _shown = false;
    _lastJson = '';
    unawaited(SystemBridge.I.bubbleHide());
  }

  // ---------------------------------------------------------------- what the user did in the bubble

  void _onAction(String action, Map<String, dynamic> m) {
    final app = _app;
    if (app == null) return;
    final owner = '${m['owner'] ?? ''}';
    final id = '${m['id'] ?? ''}';
    final text = '${m['text'] ?? ''}'.trim();
    switch (action) {
      case 'stop':
        stopAll();
        break;
      case 'send':
      case 'option':
        if (owner.isNotEmpty && text.isNotEmpty) unawaited(app.steerTask(owner, text));
        break;
      case 'approve':
        if (_confirm?.id == id) {
          final e = _confirm!.req.edit;
          if (e != null && text.isNotEmpty && text != e.value) {
            e.value = text;
            e.edited = true;
          }
          _confirm!.answer(true);
        } else {
          unawaited(Offices.I.answer(id, true, edited: text));
        }
        break;
      case 'edit': // Edit with no text to change: tell the asker the user wants something different.
        if (_confirm?.id == id) {
          _confirm!.req.wantsChange = true;
          _confirm!.answer(false);
        } else {
          unawaited(Offices.I.answer(id, false, change: true));
        }
        break;
      case 'notnow':
        if (_confirm?.id == id) {
          _confirm!.answer(false);
        } else {
          unawaited(Offices.I.answer(id, false));
        }
        break;
      case 'open':
        unawaited(app.openFromBubble(owner));
        break;
    }
    _sync(force: true);
  }
}

class _Confirm {
  _Confirm(this.id, this.convId, this.req);
  final String id;
  final String convId;
  final ActionRequest req;
  final Completer<bool?> done = Completer<bool?>();
  void answer(bool? ok) {
    if (!done.isCompleted) done.complete(ok);
  }
}
