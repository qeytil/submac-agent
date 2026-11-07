import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show GlobalKey, Size;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'browser/actions.dart';
import 'browser/loop_guard.dart';
import 'browser/page_model.dart';
import 'browser/page_script.dart';
import 'browser/net_calls.dart' show NetCall, dataLine, formatFetch, formatNetBody, formatNetList;
import 'browser/extract.dart' show ExtractPage, formatExtract, formatManyExtract, formatSchemaIndex, formatSchemaOpen, parseExtractPage;
import 'browser/human_input.dart' show HumanInput;
import 'browser/heal.dart' show HealedTarget, parseHeal;
import 'browser/playbook.dart' show Playbook, compressSteps, playbookId, resolveStep, withValues;
import 'browser/read_page.dart' show htmlTitle, htmlToText;
import 'browser/site_skills.dart' show SiteSkills;
import 'skill_library.dart' show SkillLibrary;
import 'browser/shots.dart';
import 'system_bridge.dart';
import 'tools.dart' show AgentTools;
import '../ui/i18n.dart';

export 'browser/actions.dart' show BrowserGate, BrowserAction;
export 'browser/page_model.dart' show PageSnapshot, PageElement, StepEffect, PageRisk;

/// One browser tab: its own page, history and controller.
class BrowserTab {
  BrowserTab(this.id, {this.windowId, this.openUrl});
  final int id;
  final int? windowId; // set for pop-ups the page opened itself
  final String? openUrl;
  final key = GlobalKey();
  InAppWebViewController? c;
  Completer<void> ready = Completer<void>();
  Completer<void>? loadStop;
  String url = '';
  String title = '';
  bool loading = false;
  double progress = 0;
  String? lastError;
  final List<String> dialogs = [];

  /// The browser task (subagent) that owns this tab, so parallel tasks never touch each other's pages.
  String? owner;

  /// Its off-screen web view (a HeadlessInAppWebView) when the tab was opened with no screen to draw it on (SubMac
  /// started by an alarm, owner 2026-11-07); null for a normal tab drawn by the browser layer.
  HeadlessInAppWebView? headlessView;
  bool get headless => headlessView != null;

  /// Files the page offered to download (newest last).
  final List<String> offered = [];
  bool desktop = false;

  /// The latest view of this tab (numbers, text) and its screenshot.
  PageSnapshot snap = PageSnapshot.empty;
  List<int>? signature;
  Uint8List? thumb;
  String favicon = '';

  String get host {
    final h = Uri.tryParse(url)?.host ?? '';
    return h.startsWith('www.') ? h.substring(4) : h;
  }
}

/// The agent's built-in browser (browser-use v2).
///
/// How a step works: act on a numbered element with page script first (hit-tested: the point pressed is checked to
/// reach the element itself, not a wrapper or an overlay), check the effect, and only if nothing happened fall back to
/// a real Android touch at the same point. Then wait smartly (DOM quiet + no requests in flight, never a fixed sleep),
/// take the page snapshot and a screenshot TOGETHER, draw the numbers on the screenshot in Dart (set-of-marks; the
/// page is never touched), and report what changed. Every wait has a limit and ends at once on Stop.
class BrowserAgent extends ChangeNotifier {
  BrowserAgent._();
  static final BrowserAgent I = BrowserAgent._();

  /// The web view is mounted (a browser session exists).
  bool active = false;

  /// The full-screen live view is showing on top of the app.
  bool windowOpen = false;
  bool expanded = false;

  /// The user is using the page themselves; the agent waits.
  bool userControl = false;

  final List<BrowserTab> tabs = [];
  int current = 0;
  int _nextId = 1;

  BrowserTab? get tab => tabs.isEmpty ? null : tabs[current.clamp(0, tabs.length - 1)];
  String get url => tab?.url ?? '';
  String get title => tab?.title ?? '';
  bool get loading => tab?.loading ?? false;
  double get progress => tab?.progress ?? 0;
  String get host => tab?.host ?? '';

  Completer<void>? _handBack;
  Timer? _idleTimer;

  /// Latest marked screenshot (small JPEG) and the tool call it belongs to.
  Uint8List? lastShot;
  String? shotForCall;

  /// Live frames (about 1.5 per second) for the chat card while someone is looking at it.
  final ValueNotifier<Uint8List?> frame = ValueNotifier<Uint8List?>(null);

  /// id -> short label from the latest page snapshot.
  final Map<int, String> labels = {};

  /// Text the agent copied (also put on the phone's clipboard).
  String clip = '';

  /// Credentials picked up during this session, per site (never shown to the model).
  final Map<String, Map<String, String>> _creds = {};

  // ---- hooks set by the app ----
  /// Asks the user for a site's login on a secure form. Returns {username,password,save} or null.
  Future<Map<String, String>?> Function(String site)? askLogin;
  Future<Map<String, String>?> Function(String site)? loadSavedLogin;
  Future<void> Function(String site, String user, String pass)? saveLogin;

  /// Asks the user to confirm a saved login before using it. Returns 'use', 'other', or null (not now).
  Future<String?> Function(String site, String user)? confirmLogin;

  /// A page's own confirm() that would send, pay or delete: the app asks the user (approval flow). True = OK.
  Future<bool> Function(String message, String host, String? job)? approveDialog;

  /// True while a sign-in form is up: the full-screen view steps aside so it never covers it.
  bool sheetUp = false;
  void setSheetUp(bool v) {
    if (sheetUp == v) return;
    sheetUp = v;
    notifyListeners();
  }

  final Set<String> _autoLoginTried = {};
  final Set<String> _bannerDone = {};
  static const _navActions = {
    'browser_open', 'browser_click', 'browser_tap_at', 'browser_back', 'browser_forward', 'browser_reload',
    'browser_tabs', 'browser_select', 'browser_act',
  };

  // Limits (every await below uses one of these).
  static const stepLimit = Duration(seconds: 60);
  static const loadLimit = Duration(seconds: 20);
  static const jsLimit = Duration(seconds: 8);
  static const shotLimit = Duration(seconds: 5);
  static const userLimit = Duration(minutes: 10);

  InAppWebViewSettings get settings => InAppWebViewSettings(
        javaScriptEnabled: true,
        domStorageEnabled: true,
        databaseEnabled: true,
        useHybridComposition: false, // texture layer: composes in Flutter's order (never above the app)
        mediaPlaybackRequiresUserGesture: true,
        supportZoom: true,
        builtInZoomControls: true,
        displayZoomControls: false,
        useWideViewPort: true,
        loadWithOverviewMode: true,
        thirdPartyCookiesEnabled: true,
        allowsInlineMediaPlayback: true,
        // Opaque, always: a see-through page let the app's sky show through it (and the page through the sky).
        transparentBackground: false,
        disableDefaultErrorPage: false,
        supportMultipleWindows: true, // pop-ups and target=_blank open as new tabs
        javaScriptCanOpenWindowsAutomatically: true,
        cacheEnabled: true,
      );

  /// The page script, injected before any of the page's own scripts (so request tracking sees every request).
  UnmodifiableListView<UserScript> get userScripts => UnmodifiableListView([
        UserScript(source: PageScript.source, injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START, forMainFrameOnly: true),
      ]);

  // ---- web view callbacks (wired per tab by the BrowserLayer widget) ----
  void onCreated(BrowserTab t, InAppWebViewController c) {
    t.c = c;
    if (!t.ready.isCompleted) t.ready.complete();
  }

  void onLoadStart(BrowserTab t, WebUri? u) {
    t.loading = true;
    if (t.loadStop == null || t.loadStop!.isCompleted) t.loadStop = Completer<void>();
    t.lastError = null;
    if (u != null) t.url = u.toString();
    notifyListeners();
  }

  Future<void> onLoadStop(BrowserTab t, WebUri? u) async {
    t.loading = false;
    if (u != null) t.url = u.toString();
    try {
      t.title = (await t.c?.getTitle().timeout(const Duration(seconds: 2))) ?? t.title;
    } catch (_) {}
    if (t.loadStop != null && !t.loadStop!.isCompleted) t.loadStop!.complete();
    notifyListeners();
  }

  void onProgress(BrowserTab t, int p) {
    t.progress = p / 100;
    if (p >= 100 && t.loadStop != null && !t.loadStop!.isCompleted) t.loadStop!.complete();
    notifyListeners();
  }

  void onUrlChanged(BrowserTab t, WebUri? u) {
    if (u != null) t.url = u.toString();
    notifyListeners();
  }

  void onError(BrowserTab t, WebResourceRequest req, String msg) {
    if (req.isForMainFrame != true) return;
    t.lastError = msg;
    t.loading = false;
    if (t.loadStop != null && !t.loadStop!.isCompleted) t.loadStop!.complete();
    notifyListeners();
  }

  /// A page opened a pop-up or a link in a new window: it becomes a new tab, owned by the same task, and the agent
  /// moves to it.
  Future<bool> onCreateWindow(CreateWindowAction a) async {
    final t = BrowserTab(_nextId++, windowId: a.windowId);
    t.url = a.request.url?.toString() ?? '';
    final opener = tab;
    t.owner = opener?.owner;
    tabs.add(t);
    current = tabs.length - 1;
    if (t.owner != null) _jobTab[t.owner!] = t.id;
    notifyListeners();
    // A pop-up of an off-screen page is off-screen too (nothing would ever draw it).
    if (opener?.headless == true || wantHeadless) {
      try {
        await _headlessTab(t);
      } catch (_) {
        return false;
      }
    }
    return true;
  }

  void onCloseWindow(BrowserTab t) {
    final i = tabs.indexOf(t);
    if (i >= 0) _closeTab(i);
  }

  /// JS alert/prompt: answered automatically and reported to the agent.
  void onDialog(BrowserTab t, String kind, String msg) {
    t.dialogs.add('$kind: ${msg.length > 200 ? msg.substring(0, 200) : msg}');
  }

  /// JS confirm(): a harmless one is accepted; one that would send, pay or delete goes to the user (approval flow).
  Future<bool> onConfirm(BrowserTab t, String msg) async {
    onDialog(t, 'confirm', msg);
    if (!PageRisk.dialogNeedsOk(msg) || approveDialog == null) return true;
    if (Zone.current[#smUnattended] == true) {
      // A scheduled run has nobody to ask: the confirmation is refused, and the job is told why.
      t.dialogs.add('nobody was watching to confirm this (a scheduled run), so it was cancelled');
      return false;
    }
    final ok = await Bounded.run<bool>(approveDialog!(msg, t.host, t.owner), const Duration(minutes: 5), false);
    t.dialogs.add(ok ? 'the user approved it' : 'the user said no, so it was cancelled');
    return ok;
  }

  void onDisposed(BrowserTab t) {
    t.c = null;
    // A new web view for this tab gets a fresh "ready" (the old one stayed completed and handed out a null controller).
    if (t.ready.isCompleted) t.ready = Completer<void>();
  }

  // ---- window controls ----
  void openWindow({bool big = true}) {
    if (!active) return;
    windowOpen = true;
    expanded = true;
    notifyListeners();
  }

  void hideWindow() {
    windowOpen = false;
    expanded = false;
    if (userControl) handBack();
    notifyListeners();
  }

  void toggleExpanded() => windowOpen ? hideWindow() : openWindow();

  void takeOver() {
    userControl = true;
    _handBack = Completer<void>();
    windowOpen = true;
    expanded = true;
    notifyListeners();
  }

  /// Stops the task that is browsing (set by the app while a task drives the browser).
  VoidCallback? onStopTask;

  void handBack() {
    userControl = false;
    if (_handBack != null && !_handBack!.isCompleted) _handBack!.complete();
    notifyListeners();
  }

  /// The user tapped a tab in the full view.
  void showTab(int i) {
    if (i < 0 || i >= tabs.length) return;
    current = i;
    notifyListeners();
  }

  Future<void> close() async {
    _idleTimer?.cancel();
    if (userControl) handBack();
    active = false;
    windowOpen = false;
    expanded = false;
    for (final t in tabs) {
      _disposeHeadless(t);
    }
    tabs.clear();
    current = 0;
    lastShot = null;
    shotForCall = null;
    shotsByCall.clear();
    _jobTab.clear();
    _snapByJob.clear();
    labels.clear();
    _creds.clear();
    _autoLoginTried.clear();
    _bannerDone.clear();
    frame.value = null;
    sheetUp = false;
    _stopFrames();
    notifyListeners();
  }

  /// The task that used the browser ended (done, failed or stopped): get out of the user's way. The full view closes
  /// after a short beat; the tabs stay alive a few minutes for a follow-up, then close. If the user has control,
  /// nothing moves.
  void taskEnded() {
    if (userControl) return;
    Timer(const Duration(milliseconds: 1400), () {
      if (!userControl && windowOpen) hideWindow();
    });
    scheduleIdleClose();
  }

  DateTime? _idleSince;

  void scheduleIdleClose() {
    _idleTimer?.cancel();
    _idleTimer = Timer(const Duration(minutes: 4), () {
      if (windowOpen || userControl) return;
      // A paused task (waiting for an answer, or at a check-in) keeps its page up to 30 minutes.
      if (_jobTab.isNotEmpty && DateTime.now().difference(_idleSince ??= DateTime.now()).inMinutes < 30) {
        scheduleIdleClose();
        return;
      }
      close();
    });
  }

  // ---- live frames for the card ----
  int _watchers = 0;
  Timer? _frameTimer;
  bool _framing = false;

  /// A card or the full view started (or stopped) showing the live page.
  void watch(bool on) {
    _watchers = (_watchers + (on ? 1 : -1)).clamp(0, 99).toInt();
    if (_watchers > 0) {
      _frameTimer ??= Timer.periodic(const Duration(milliseconds: 700), (_) => _grabFrame());
    } else {
      _stopFrames();
    }
  }

  void _stopFrames() {
    _frameTimer?.cancel();
    _frameTimer = null;
  }

  Future<void> _grabFrame() async {
    final t = tab;
    final c = t?.c;
    if (_framing || c == null || !active || windowOpen) return; // the full view shows the real page
    _framing = true;
    try {
      final raw = await Bounded.run<Uint8List?>(
          c.takeScreenshot(screenshotConfiguration: ScreenshotConfiguration(compressFormat: CompressFormat.JPEG, quality: 45)), shotLimit, null);
      if (raw != null) {
        final f = await Shots.frame(raw);
        if (f != null) frame.value = f;
      }
    } finally {
      _framing = false;
    }
  }

  // ---- with no screen (owner 2026-11-07: browser use with the app closed) ----
  /// True when nothing can draw the browser now: SubMac was started by an alarm, or it is in the background. Set by
  /// the app. A tab opened then is an off-screen web view instead of a widget in the browser layer, whose platform
  /// view is only created when a frame is drawn (with no screen it never was, so every step failed on "not ready").
  static bool Function()? noScreen;

  /// The off-screen web view could not start on this phone this session: tasks with no screen go straight to the
  /// read-only mode (FetchBrowser).
  bool headlessFailed = false;

  /// Tests: what starts the off-screen web view of [t] (the real one is HeadlessInAppWebView).
  static Future<void> Function(BrowserTab t)? headlessStarter;

  bool get wantHeadless => noScreen?.call() ?? false;

  Future<void> _startHeadless(BrowserTab t) async {
    final f = headlessStarter;
    if (f != null) return f(t);
    final v = HeadlessInAppWebView(
      windowId: t.windowId,
      initialUrlRequest: t.windowId != null ? null : URLRequest(url: WebUri(t.openUrl ?? 'about:blank')),
      initialSettings: settings,
      initialUserScripts: userScripts,
      // A phone-sized page, so sites serve their mobile layout and screenshots look like the card's.
      initialSize: const Size(412, 915),
      onWebViewCreated: (c) => onCreated(t, c),
      onLoadStart: (c, u) => onLoadStart(t, u),
      onLoadStop: (c, u) => onLoadStop(t, u),
      onProgressChanged: (c, p) => onProgress(t, p),
      onUpdateVisitedHistory: (c, u, _) => onUrlChanged(t, u),
      onReceivedError: (c, req, err) => onError(t, req, err.description),
      onReceivedHttpError: (c, req, res) {
        if ((res.statusCode ?? 0) >= 500) onError(t, req, 'the site answered with error ${res.statusCode}');
      },
      onCreateWindow: (c, a) => onCreateWindow(a),
      onCloseWindow: (c) => onCloseWindow(t),
      onJsAlert: (c, r) async {
        onDialog(t, 'alert', r.message ?? '');
        return JsAlertResponse(handledByClient: true, action: JsAlertResponseAction.CONFIRM);
      },
      onJsConfirm: (c, r) async {
        final ok = await onConfirm(t, r.message ?? '');
        return JsConfirmResponse(handledByClient: true, action: ok ? JsConfirmResponseAction.CONFIRM : JsConfirmResponseAction.CANCEL);
      },
      onJsPrompt: (c, r) async {
        onDialog(t, 'prompt', r.message ?? '');
        return JsPromptResponse(handledByClient: true, action: JsPromptResponseAction.CONFIRM, value: r.defaultValue ?? '');
      },
      onDownloadStartRequest: (c, r) => onDownload(t, r.url.toString(), r.suggestedFilename ?? ''),
    );
    t.headlessView = v;
    await v.run();
  }

  /// Gives tab [t] its off-screen web view and waits for it. Throws when it cannot start (then [headlessFailed]).
  Future<void> _headlessTab(BrowserTab t) async {
    try {
      await _startHeadless(t);
      await t.ready.future.timeout(loadLimit);
    } catch (e) {
      headlessFailed = true;
      _disposeHeadless(t);
      tabs.remove(t);
      if (tabs.isEmpty) active = false;
      current = tabs.isEmpty ? 0 : current.clamp(0, tabs.length - 1).toInt();
      notifyListeners();
      throw StateError('no screen: the off-screen browser could not start ($e)');
    }
  }

  void _disposeHeadless(BrowserTab t) {
    final v = t.headlessView;
    if (v == null) return;
    t.headlessView = null;
    unawaited(v.dispose().catchError((Object _) {}));
  }

  // ---- tabs ----
  Future<BrowserTab> _newTab([String? url]) async {
    final t = BrowserTab(_nextId++, openUrl: url);
    tabs.add(t);
    current = tabs.length - 1;
    active = true;
    notifyListeners();
    if (wantHeadless) {
      await _headlessTab(t);
      return t;
    }
    await t.ready.future.timeout(loadLimit);
    return t;
  }

  void _closeTab(int i) {
    _disposeHeadless(tabs[i]);
    tabs.removeAt(i);
    if (tabs.isEmpty) {
      close();
      return;
    }
    // A tab before the current one moves it back by one; closing the current last tab moves to the new last one.
    if (current > i) {
      current--;
    } else if (current >= tabs.length) {
      current = tabs.length - 1;
    }
    notifyListeners();
  }

  Future<InAppWebViewController> _ensure() async {
    _idleTimer?.cancel();
    final t = tab;
    if (active && t != null) {
      if (t.c == null) await t.ready.future.timeout(loadLimit);
      final c = t.c;
      if (c == null) throw StateError('the browser view is not ready');
      return c;
    }
    active = true;
    final n = await _newTab();
    final c = n.c;
    if (c == null) throw StateError('the browser view is not ready');
    return c;
  }

  Future<void> _waitIfUser() async {
    if (Zone.current[#smUnattended] == true) return; // a scheduled run has nobody to hand the browser to
    if (!userControl || _handBack == null) return;
    await Bounded.orCancel<void>(_handBack!.future, _endOf(jobNow), limit: userLimit);
  }

  // ---- several browser tasks at once ----
  /// The browser task the current call belongs to (set by the task runner through a Zone).
  static String? get jobNow => Zone.current[#smBrowserJob] as String?;
  Future<void> _tail = Future<void>.value();

  /// Each task's own tab.
  final Map<String, int> _jobTab = {};

  /// Screenshots by tool call, so a task always gets its own picture even when others act in between.
  final Map<String, Uint8List> shotsByCall = {};
  final Map<String, PageSnapshot> _snapByJob = {};

  /// What each job has done, as replayable step signatures (the raw material of a site skill).
  final Map<String, List<Map<String, dynamic>>> _rec = {};
  static const _recCap = 80;

  /// Records one action of the running job: kind + label + href, never coordinates.
  void _record(Map<String, dynamic> step) {
    if ('${step['k'] ?? ''}'.contains('password')) return; // a password is never part of a skill
    final l = _rec.putIfAbsent(jobNow ?? '', () => <Map<String, dynamic>>[]);
    l.add(step);
    if (l.length > _recCap) l.removeAt(0);
  }

  /// The steps this job has done so far (what browser_play "save" compresses).
  @visibleForTesting
  List<Map<String, dynamic>> get recorded => List.of(_rec[jobNow ?? ''] ?? const <Map<String, dynamic>>[]);

  /// The signature of element [id] as the page had it when the step ran.
  Map<String, dynamic> _sig(int id) {
    final e = snapFor(jobNow).byId(id);
    if (e == null) return const {};
    return {'k': e.kind, if (e.label.isNotEmpty) 't': e.label, if (e.href.isNotEmpty) 'h': e.href};
  }

  /// A fresh numbered view without a screenshot: replay needs the elements, not pixels.
  Future<PageSnapshot> _refresh(InAppWebViewController c, BrowserTab t) async {
    final raw = await _js(c, 'return JSON.stringify(S.snapshot({max: 140, text: 400}));', limit: const Duration(seconds: 10));
    try {
      final s = PageSnapshot.parse(raw);
      t.snap = s;
      return s;
    } catch (_) {
      return t.snap;
    }
  }
  final Map<String, Completer<void>> _ends = {};

  /// Element labels from the latest view of the given task (or the shared one).
  Map<int, String> labelsFor(String? job) => job == null ? labels : (_snapByJob[job]?.labels ?? labels);

  /// The latest view of the given task (for approval decisions and the card).
  PageSnapshot snapFor(String? job) => (job == null ? tab?.snap : _snapByJob[job]) ?? tab?.snap ?? PageSnapshot.empty;

  /// The tab a task works in (for its card).
  BrowserTab? tabFor(String job) {
    final id = _jobTab[job];
    for (final t in tabs) {
      if (t.id == id) return t;
    }
    return null;
  }

  Future<void> _endOf(String? job) => job == null ? Completer<void>().future : (_ends[job] ??= Completer<void>()).future;
  bool _ended2(String? job) => job != null && _ended.contains(job);

  /// One browser action at a time (the page is shared hardware), while the tasks think in parallel.
  Future<T> _serial<T>(Future<T> Function() f) {
    final prev = _tail;
    final gate = Completer<void>();
    _tail = gate.future;
    return prev.then((_) => f()).whenComplete(gate.complete);
  }

  Future<String> execute(String name, Map<String, dynamic> a, {String? callId, bool shots = true}) {
    final job = jobNow;
    return _serial(() async {
      // A stopped task's queued steps never touch the page.
      if (_ended2(job)) return 'Stopped: this browser task has ended.';
      // The user's turn with the browser is not the step's time: wait for it first (bounded, ends on Stop).
      await _waitIfUser();
      if (_ended2(job)) return 'Stopped: this browser task has ended.';
      _idleSince = null;
      if (job != null) await _enterJob(job);
      final inner = _executeInner(name, a, callId: callId, shots: shots);
      final limit = name == 'browser_login' ? userLimit : stepLimit;
      final done = Completer<String>();
      var timedOut = false;
      Timer? timer;
      void finish(String v) {
        if (done.isCompleted) return;
        timer?.cancel();
        done.complete(v);
      }

      inner.then(finish, onError: (Object e) => finish('Error: $e'));
      if (job != null) _endOf(job).then((_) => finish('Stopped: this browser task has ended.'));
      timer = Timer(limit, () {
        timedOut = true;
        finish('Error: that step did not finish in ${limit.inSeconds} s, so it was stopped. '
            'The page may be frozen: try browser_reload, or another way.');
      });
      final out = await done.future;
      // Keep the page locked until the step really ends (up to 10 s more), so the next step never runs beside it.
      if (timedOut) await Bounded.run<String>(inner, const Duration(seconds: 10), '');
      if (job != null && !_ended2(job)) {
        final t = tab;
        if (t != null && active) {
          t.owner ??= job;
          _jobTab[job] = t.id;
          _snapByJob[job] = t.snap;
        }
      }
      if (callId != null && lastShot != null && shotForCall == callId) {
        shotsByCall[callId] = lastShot!;
        while (shotsByCall.length > 8) {
          shotsByCall.remove(shotsByCall.keys.first);
        }
      }
      return out;
    });
  }

  /// Point the browser at this task's own tab (or give it a fresh one when another task is using the current tab).
  Future<void> _enterJob(String job) async {
    if (!active || tabs.isEmpty) return;
    final mine = _jobTab[job];
    final i = mine == null ? -1 : tabs.indexWhere((t) => t.id == mine);
    if (i >= 0) {
      if (current != i) {
        current = i;
        notifyListeners();
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }
      return;
    }
    final cur = tab;
    final takenByOther = cur != null && cur.owner != null && cur.owner != job && _jobTab.containsKey(cur.owner);
    if (takenByOther) {
      final t = await _newTab();
      t.owner = job;
      _jobTab[job] = t.id;
    } else if (cur != null) {
      cur.owner = job;
      _jobTab[job] = cur.id;
    }
  }

  /// Tasks that have ended. A step of theirs still queued does nothing, and never claims a tab again.
  final Set<String> _ended = {};

  /// A task ended for good (done, failed, stopped) or paused ([ended] false: it keeps nothing running).
  void releaseJob(String job, {bool ended = true}) {
    if (ended) {
      _ended.add(job);
      final e = _ends[job] ??= Completer<void>();
      if (!e.isCompleted) e.complete();
    }
    _jobTab.remove(job);
    _snapByJob.remove(job);
    _rec.remove(job);
    for (final t in tabs) {
      if (t.owner == job) t.owner = null;
    }
    if (userControl && ended && _jobTab.isEmpty) handBack();
  }

  // ---- tools ----
  static const names = {
    'browser_act',
    'browser_download',
    'browser_upload',
    'browser_view',
    'browser_open',
    'browser_tabs',
    'browser_click',
    'browser_tap_at',
    'browser_type',
    'browser_select',
    'browser_scroll',
    'browser_swipe',
    'browser_drag',
    'browser_back',
    'browser_forward',
    'browser_reload',
    'browser_press',
    'browser_wait',
    'browser_find',
    'browser_read',
    'browser_net',
    'browser_fetch',
    'browser_schema',
    'browser_extract',
    'browser_extract_many',
    'browser_play',
    'browser_copy',
    'browser_login',
    'browser_js',
    'browser_close',
  };

  static const _about = {
    'type': 'string',
    'description': 'Only when this posts, sends, submits, applies, buys or deletes something: one short plain question for '
        'the user, e.g. "Post this on LinkedIn?". The app also asks on its own for payment pages.'
  };

  static final List<Map<String, dynamic>> definitions = [
    _fn(
        'browser_act',
        'Do 1-6 actions in order in ONE step, then get the new view and screenshot. Use it to fill a form (type, type, '
            'select, click) or for any single action. Actions after one that changes the page are skipped (you get the new '
            'page instead). Each action: {"do":"click","id":3} | {"do":"type","id":5,"text":"...","submit":false,"append":false} | '
            '{"do":"select","id":7,"option":"Large"} | {"do":"check","id":9} | {"do":"clear","id":5} | '
            '{"do":"scroll","direction":"down","id":4?} | {"do":"key","key":"Enter"} | {"do":"wait","seconds":2,"text":"Saved"?} | '
            '{"do":"find","text":"Shipping"}.',
        {
          'evaluation': {'type': 'string', 'description': 'Did your last action do what you wanted? Success / failure / unsure, in one line.'},
          'memory': {'type': 'string', 'description': 'What to remember from this step (progress, counts, facts), 1-2 lines.'},
          'next_goal': {'type': 'string', 'description': 'What these actions should achieve, one line.'},
          'actions': {
            'type': 'array',
            'items': {'type': 'object'},
          },
          'about': _about,
        },
        ['actions']),
    _fn('browser_open',
        'Open a web page (or search words). Returns the numbered elements, the visible text and a screenshot with the same '
            'numbers. new_tab keeps the current page open in its own tab. read:true is for reading only — it fetches the '
            'page with this session and answers from its text without rendering (one fast step; falls back to rendering '
            'when the page needs scripts).',
        {
          'url': {'type': 'string'},
          'new_tab': {'type': 'boolean'},
          'read': {'type': 'boolean', 'description': 'Reading only, no clicking: answer from a fetch of the page text, no render.'},
        },
        ['url']),
    _fn('browser_tabs', 'Tabs: list, open a new one, switch, or close.', {
      'action': {'type': 'string', 'enum': ['list', 'new', 'switch', 'close']},
      'tab': {'type': 'integer'},
      'url': {'type': 'string'},
    }, ['action']),
    _fn('browser_click', 'Tap one numbered element (checked to hit the element itself). long:true = long-press.', {
      'id': {'type': 'integer'},
      'long': {'type': 'boolean'},
      'about': _about,
    }, ['id']),
    _fn('browser_tap_at',
        'Tap an exact point of the screenshot, in percent (x 0-100 left to right, y 0-100 top to bottom). Only for things '
            'without a number: maps, canvases, embedded frames from other sites.',
        {
          'x': {'type': 'number'},
          'y': {'type': 'number'},
          'long': {'type': 'boolean'},
          'about': _about,
        },
        ['x', 'y']),
    _fn('browser_type', 'Type into a numbered field (replaces its text unless append). submit:true presses Enter.', {
      'id': {'type': 'integer'},
      'text': {'type': 'string'},
      'submit': {'type': 'boolean'},
      'append': {'type': 'boolean'},
      'paste': {'type': 'boolean', 'description': 'Type what you copied with browser_copy.'},
      'about': _about,
    }, ['id']),
    _fn('browser_select', 'Choose an option in a numbered dropdown by its visible text.', {
      'id': {'type': 'integer'},
      'option': {'type': 'string'},
    }, ['id', 'option']),
    _fn('browser_scroll', 'Scroll the page, or inside a numbered box.', {
      'direction': {'type': 'string', 'enum': ['down', 'up', 'left', 'right', 'top', 'bottom']},
      'amount': {'type': 'string', 'enum': ['page', 'half', 'little']},
      'id': {'type': 'integer'},
    }, []),
    _fn('browser_swipe', 'Swipe like a finger on a carousel, story or slider (element number), or between two points in %.', {
      'direction': {'type': 'string', 'enum': ['left', 'right', 'up', 'down']},
      'id': {'type': 'integer'},
      'x': {'type': 'number'},
      'y': {'type': 'number'},
      'x2': {'type': 'number'},
      'y2': {'type': 'number'},
    }, []),
    _fn('browser_drag', 'Drag a numbered slider to a percent (0-100), or a handle to a point in %.', {
      'id': {'type': 'integer'},
      'percent': {'type': 'number'},
      'to_x': {'type': 'number'},
      'to_y': {'type': 'number'},
    }, ['id']),
    _fn('browser_back', 'Go back to the previous page.', {}, []),
    _fn('browser_forward', 'Go forward again.', {}, []),
    _fn('browser_reload', 'Reload the page (blank, stuck or showing an error).', {}, []),
    _fn('browser_press', 'Press a key on the focused element: Enter, Tab, Escape, ArrowDown, ArrowUp, Backspace.', {
      'key': {'type': 'string'},
      'about': _about,
    }, ['key']),
    _fn('browser_wait', 'Wait for text to appear (or go with gone:true), or a few seconds. quiet:true waits until the page '
        'stops talking (no requests in flight, no changes), max 10 s. Max 20 s.', {
      'seconds': {'type': 'number'},
      'text': {'type': 'string'},
      'gone': {'type': 'boolean'},
      'quiet': {'type': 'boolean', 'description': 'Wait until the page goes quiet instead of a fixed time.'},
    }, []),
    _fn('browser_find', 'Find text on the page and scroll to it.', {
      'text': {'type': 'string'},
    }, ['text']),
    _fn('browser_read', 'Read all the text on the current page (long articles, results, terms). full:true lists every '
        'numbered element again after a patch showed only what changed.', {
      'full': {'type': 'boolean', 'description': 'List every element again (the last view showed only changes).'},
    }, []),
    _fn('browser_net', 'List the data calls this page made (the site\'s own APIs) — often the exact answer, no scraping. '
        'With an id, read that call\'s JSON body instead.', {
      'id': {'type': 'integer', 'description': 'Read this call\'s body (from a browser_net list).'},
      'filter': {'type': 'string', 'description': 'Only calls whose url contains this, e.g. "/api/search".'},
      'clear': {'type': 'boolean', 'description': 'Forget the recorded calls.'},
    }, []),
    _fn('browser_fetch', 'Call a url with this page\'s own session (cookies, sign-in) and read the response — the site\'s API, '
        'one step instead of many clicks. GET/HEAD only.', {
      'url': {'type': 'string', 'description': 'Absolute, or relative to the current page (e.g. "/api/items?page=2").'},
      'headers': {'type': 'object', 'description': 'Extra headers, e.g. {"accept": "application/json"}.'},
    }, ['url']),
    _fn('browser_schema',
        'The site\'s own structured data, free: JSON-LD blocks (Product, Article, Event...), the app state the page '
            'carries (__NEXT_DATA__ and friends), OpenGraph metas. No arguments: list what is there. With an index: '
            'read that block in full (usually the exact answer, no scraping).',
        {
          'index': {'type': 'integer', 'description': 'Read this block in full (from a browser_schema list).'},
        },
        []),
    _fn('browser_extract',
        'Pull EVERY matching item on the page in ONE step: rows is a CSS selector matching each item (a product card, '
            'a search result, a table row); fields say what to take from each row — a CSS selector for the text, or '
            '{"sel": "a", "attr": "href"} for a link. Returns JSON. Show the answer to the user as a ```data card.',
        {
          'rows': {'type': 'string', 'description': 'CSS selector matching each item, e.g. ".product-card" or "table tr".'},
          'fields': {'type': 'object', 'description': 'What to take from each row, e.g. {"name": ".title", "price": ".price", "link": {"sel": "a", "attr": "href"}}.'},
          'limit': {'type': 'integer', 'description': 'Cap the rows (default 200).'},
        },
        ['rows', 'fields']),
    _fn('browser_extract_many',
        'The same fields from SEVERAL pages in one step: give links (a list of URLs, or a CSS selector whose links are '
            'collected from this page) and it reads them all — fetched, not rendered — and returns ONE table with a '
            'source column. Up to 8 pages, no tab switching, no waiting for each page to draw. Pages built by scripts '
            'come back as "not read": open those with browser_open and use browser_extract. Show the result as a ```data card.',
        {
          'links': {'type': 'array', 'items': {'type': 'string'}, 'description': 'The page URLs to read.'},
          'from': {'type': 'string', 'description': 'Instead of links: a CSS selector whose links (on this page) to read, e.g. ".result a".'},
          'rows': {'type': 'string', 'description': 'CSS selector matching each item on those pages, e.g. ".product-card".'},
          'fields': {'type': 'object', 'description': 'What to take from each row, e.g. {"name": ".title", "price": ".price"}.'},
          'limit': {'type': 'integer', 'description': 'Cap the rows per page (default 50).'},
          'max_pages': {'type': 'integer', 'description': 'Cap the pages read (default 6, max 8).'},
        },
        ['rows', 'fields']),
    _fn('browser_play',
        'Site skills: a flow you did on this site before replays with no thinking per step. "list" shows the skills saved '
            'for this site; "run" replays one (values override typed fields; it pauses on payment pages for the user\'s OK); '
            '"save" saves the steps you just did (name + what it does); "forget" deletes one. Save after a multi-step flow '
            'worked — the next visit becomes one step. Skills follow the user\'s account: one saved here replays on their '
            'other phones too, and a forgotten one is gone from them as well.',
        {
          'action': {'type': 'string', 'enum': ['list', 'run', 'save', 'forget']},
          'id': {'type': 'string', 'description': 'The skill id (from a list), for run and forget.'},
          'name': {'type': 'string', 'description': 'For save: what the flow does, e.g. "Book a hotel room".'},
          'goal': {'type': 'string', 'description': 'For save: when to use it, one line.'},
          'values': {'type': 'object', 'description': 'For run: replace typed values by field label, e.g. {"Search": "flights to Hargeisa"}.'},
        },
        ['action']),
    _fn('browser_copy', 'Copy the text of a numbered element (or text you give) to paste later; also on the phone clipboard.', {      'id': {'type': 'integer'},
      'text': {'type': 'string'},
    }, []),
    _fn('browser_login',
        'Sign in on the current page: the app fills the user\'s saved login or asks them on a secure form. You never see '
            'the password. Then press the sign-in button yourself; call again if the password comes on a second page.',
        {
          'site': {'type': 'string', 'description': 'Site name for the user, e.g. "LinkedIn".'},
        },
        []),
    _fn('browser_js', 'Last resort: run a short JavaScript function body on the page and get its result. Never for passwords.', {
      'code': {'type': 'string'},
      'about': _about,
    }, ['code']),
    _fn('browser_close', 'Close your tabs when the job is done.', {}, []),
    _fn('browser_download', 'Save a file the page offered (PDF, ticket, invoice) to the user\'s files. Empty url = the last offered.', {
      'url': {'type': 'string'},
      'name': {'type': 'string'},
    }, []),
    _fn('browser_upload', 'Attach a file from the user\'s files to a numbered file-upload field.', {
      'id': {'type': 'integer'},
      'path': {'type': 'string'},
    }, ['id', 'path']),
    _fn('browser_view', 'Switch this tab between the mobile and the desktop site, then reload.', {
      'mode': {'type': 'string', 'enum': ['desktop', 'mobile']},
    }, ['mode']),
  ];

  static Map<String, dynamic> _fn(String name, String desc, Map<String, dynamic> props, List<String> required) => {
        'type': 'function',
        'function': {
          'name': name,
          'description': desc,
          'parameters': {'type': 'object', 'properties': props, 'required': required},
        },
      };

  /// Plain one-line label for the status pill ("Opening amazon.com"), in the app's language.
  String label(String name, Map<String, dynamic> a) {
    String site() {
      final u = (a['url'] ?? '').toString();
      final h = Uri.tryParse(u.startsWith('http') ? u : 'https://$u')?.host ?? '';
      final s = h.isNotEmpty && h.contains('.') ? h : host;
      return s.startsWith('www.') ? s.substring(4) : (s.isEmpty ? tr('the web') : s);
    }

    final labs = labelsFor(jobNow);
    String tapped(dynamic id) {
      final l = labs[id is num ? id.toInt() : int.tryParse('$id') ?? -1] ?? '';
      return l.isEmpty || l.length > 32 ? tr('Tapping on {site}', {'site': site()}) : tr('Tapping "{label}"', {'label': l});
    }

    switch (name) {
      case 'browser_open':
        return tr('Opening {site}', {'site': site()});
      case 'browser_tabs':
        return a['action'] == 'new' ? tr('Opening a new tab') : tr('Switching tabs');
      case 'browser_click':
        return tapped(a['id']);
      case 'browser_act':
        final (acts, err) = BrowserAction.parseBatch(a['actions']);
        if (err != null || acts.isEmpty) return tr('Working on {site}', {'site': site()});
        if (acts.any((x) => x.kind == 'type')) return tr('Filling in on {site}', {'site': site()});
        if (acts.first.kind == 'click' || acts.first.kind == 'check') return tapped(acts.first.args['id']);
        if (acts.first.kind == 'scroll') return tr('Looking through {site}', {'site': site()});
        return tr('Working on {site}', {'site': site()});
      case 'browser_type':
        return tr('Typing on {site}', {'site': site()});
      case 'browser_login':
        return tr('Signing in to {site}', {'site': (a['site'] ?? '').toString().isNotEmpty ? '${a['site']}' : site()});
        case 'browser_read':
        case 'browser_net':
        case 'browser_fetch':
        case 'browser_schema':
        case 'browser_extract':
        case 'browser_extract_many':
        case 'browser_play':
        case 'browser_find':
          return tr('Reading {site}', {'site': site()});
      case 'browser_scroll':
      case 'browser_swipe':
        return tr('Looking through {site}', {'site': site()});
      case 'browser_reload':
        return tr('Reloading {site}', {'site': site()});
      case 'browser_wait':
        return tr('Waiting for {site}', {'site': site()});
      case 'browser_download':
        return tr('Saving a file');
      case 'browser_close':
        return tr('Closing the browser');
      default:
        return tr('Browsing {site}', {'site': site()});
    }
  }

  /// Words or an address -> a URL. Spaces inside a real address are kept (encoded), not turned into a search.
  @visibleForTesting
  static String toUrl(String u) {
    u = u.trim();
    if (u.isEmpty) return u;
    if (u.contains('://') || u.startsWith('about:')) return u.replaceAll(' ', '%20');
    final first = u.split(RegExp(r'[/?#]')).first;
    final looksHost = RegExp(r'^(localhost|[\w-]+(\.[\w-]+)+)(:\d+)?$').hasMatch(first);
    if (!looksHost) return 'https://duckduckgo.com/?q=${Uri.encodeComponent(u)}';
    return 'https://${u.replaceAll(' ', '%20')}';
  }

  Future<String> _executeInner(String name, Map<String, dynamic> a, {String? callId, bool shots = true}) async {
    try {
      if (name == 'browser_close') {
        final job = jobNow;
        if (job != null && _jobTab.keys.any((k) => k != job)) {
          for (var i = tabs.length - 1; i >= 0; i--) {
            if (tabs[i].owner == job) _closeTab(i);
          }
          _jobTab.remove(job);
          return 'Closed your tabs (other tasks are still using the browser).';
        }
        await close();
        return 'Browser closed.';
      }
      if (name == 'browser_tabs') return await _tabs(a, callId: callId, shots: shots);
      if (name == 'browser_open' && a['new_tab'] == true && active && tabs.isNotEmpty) {
        final u = toUrl((a['url'] ?? '').toString());
        if (u.isEmpty) return 'Error: no url';
        final t = await _newTab();
        t.owner = jobNow;
        if (jobNow != null) _jobTab[jobNow!] = t.id;
        await _load(t, u);
        return await observe(callId: callId, shots: shots);
      }
      final c = await _ensure();
      await _waitIfUser();
      final t = tab!;
      final before = await _state(c);
      var note = '';
      switch (name) {
        case 'browser_act':
          final (acts, err) = BrowserAction.parseBatch(a['actions']);
          if (err != null) return err;
          note = await _batch(c, t, acts);
          break;
        case 'browser_open':
          final u = toUrl((a['url'] ?? '').toString());
          if (u.isEmpty) return 'Error: no url';
          if (a['read'] == true) {
            final r = await _fetchRead(u);
            if (r != null) return r;
            note = '(That page is drawn by script, so it was rendered instead of fetched.)';
          }
          await _load(t, u);
          break;
        case 'browser_click':
          final r = await _click(c, t, _intV(a['id']), long: a['long'] == true);
          if (!r.ok) return await _failed(r.text, callId, shots);
          note = r.text;
          break;
        case 'browser_tap_at':
          final r = await _tapAt(c, t, _numD(a['x'], 50) / 100, _numD(a['y'], 50) / 100, long: a['long'] == true);
          if (!r.ok) return 'Error: ${r.text}';
          note = r.text;
          break;
        case 'browser_type':
          var text = (a['text'] ?? '').toString();
          if (a['paste'] == true || text.isEmpty) text = text.isEmpty ? clip : text;
          final r = await _type(c, t, _intV(a['id']), text, submit: a['submit'] == true, append: a['append'] == true);
          if (!r.ok) return await _failed(r.text, callId, shots);
          note = r.text;
          break;
        case 'browser_select':
          final r = await _select(c, t, _intV(a['id']), (a['option'] ?? '').toString());
          if (!r.ok) return await _failed(r.text, callId, shots);
          note = r.text;
          break;
        case 'browser_scroll':
          final r = await _jsMap(c, 'return JSON.stringify(S.scroll(${jsonEncode((a['direction'] ?? 'down').toString())}, '
              '${jsonEncode((a['amount'] ?? 'page').toString())}, ${a['id'] == null ? 'null' : _int(a['id'])}));');
          if (r['ok'] != true) note = '${r['err'] ?? 'could not scroll'}';
          await _settle(c, t, max: 800);
          break;
        case 'browser_swipe':
          note = await _swipe(c, t, a);
          break;
        case 'browser_drag':
          final r = await _jsMap(c,
              'return JSON.stringify(await S.drag(${_int(a['id'])}, ${a['percent'] == null ? 'null' : _num(a['percent'], 50)}, '
              '${a['to_x'] == null ? 'null' : _num(a['to_x'], 50)}, ${a['to_y'] == null ? 'null' : _num(a['to_y'], 50)}));',
              limit: const Duration(seconds: 6));
          if (r['ok'] != true) return await _failed('${r['err'] ?? 'drag failed'}', callId, shots);
          await _settle(c, t, max: 800);
          break;
        case 'browser_back':
          if (await Bounded.run<bool>(c.canGoBack(), const Duration(seconds: 3), false)) {
            t.loadStop = Completer<void>();
            await Bounded.run<void>(c.goBack(), const Duration(seconds: 5), null);
            await _settle(c, t, nav: true);
          } else if (tabs.length > 1 && t.windowId != null) {
            _closeTab(current);
            note = 'That tab had no history, so it was closed and you are back on the previous tab.';
          } else {
            return 'Error: nothing to go back to. Open a page with browser_open instead.';
          }
          break;
        case 'browser_forward':
          if (!await Bounded.run<bool>(c.canGoForward(), const Duration(seconds: 3), false)) return 'Error: nothing to go forward to.';
          t.loadStop = Completer<void>();
          await Bounded.run<void>(c.goForward(), const Duration(seconds: 5), null);
          await _settle(c, t, nav: true);
          break;
        case 'browser_reload':
          t.loadStop = Completer<void>();
          t.lastError = null;
          await Bounded.run<void>(c.reload(), const Duration(seconds: 5), null);
          await _settle(c, t, nav: true);
          break;
        case 'browser_press':
          await _key(c, t, (a['key'] ?? 'Enter').toString());
          break;
        case 'browser_wait':
          note = await _wait(c, t, a);
          break;
        case 'browser_find':
          final r = await _jsMap(c, 'return JSON.stringify(S.find(${jsonEncode((a['text'] ?? '').toString())}));');
          note = r['ok'] == true ? 'Found it; the view is scrolled there.' : 'Not found on this page.';
          await _settle(c, t, max: 500);
          break;
        case 'browser_read':
          if (a['full'] == true) {
            final raw = await _js(c, 'return JSON.stringify(S.snapshot({max: 140, text: 2600}));', limit: const Duration(seconds: 10));
            try {
              final s = PageSnapshot.parse(raw);
              t.snap = s;
              return s.describe();
            } catch (_) {
              return 'Could not read this page. Try browser_reload.';
            }
          }
          final txt = await _js(c, 'return S.readAll(16000);', limit: jsLimit);
          return 'Page: $title — $url\n\n$txt';
        case 'browser_copy':
          var text = (a['text'] ?? '').toString();
          if (a['id'] != null) text = await _js(c, 'return S.text(${_int(a['id'])});');
          if (text.isEmpty || text.startsWith('script error')) return 'Error: nothing to copy there.';
          clip = text;
          await Bounded.run<void>(Clipboard.setData(ClipboardData(text: text)), const Duration(seconds: 2), null);
          return 'Copied ${text.length} characters: "${text.length > 160 ? '${text.substring(0, 160)}…' : text}". '
              'Use browser_type with paste:true to put it in a field.';
        case 'browser_net':
          return await _net(c, a);
        case 'browser_fetch':
          return await _fetchApi(c, a);
        case 'browser_schema':
          return await _schema(c, a);
        case 'browser_extract':
          return await _extract(c, a);
        case 'browser_extract_many':
          return await _extractMany(c, t, a);
        case 'browser_play':
          final p = await _play(c, t, a);
          if (a['action'] != 'run') return p;
          note = p;
          break;
        case 'browser_js':
          final code = (a['code'] ?? '').toString();
          if (code.toLowerCase().contains('password')) return 'Error: reading passwords is not allowed.';
          final r = await Bounded.run<CallAsyncJavaScriptResult?>(c.callAsyncJavaScript(functionBody: code), const Duration(seconds: 10), null);
          await _settle(c, t, max: 800);
          final v = r == null ? 'no result (timed out)' : (r.error != null ? 'script error: ${r.error}' : jsonEncode(r.value));
          note = 'Result: ${v.length > 3000 ? '${v.substring(0, 3000)}…' : v}';
          break;
        case 'browser_download':
          return await _download(t, (a['url'] ?? '').toString(), (a['name'] ?? '').toString());
        case 'browser_upload':
          final r = await _upload(c, _intV(a['id']), (a['path'] ?? '').toString());
          if (r != 'ok') return r.startsWith('Error') ? r : await _failed(r, callId, shots);
          note = 'File attached.';
          await _settle(c, t, max: 800);
          break;
        case 'browser_view':
          final desk = (a['mode'] ?? 'desktop') == 'desktop';
          t.desktop = desk;
          await Bounded.run<void>(
              c.setSettings(settings: settings..preferredContentMode = desk ? UserPreferredContentMode.DESKTOP : UserPreferredContentMode.MOBILE),
              const Duration(seconds: 3),
              null);
          t.loadStop = Completer<void>();
          await Bounded.run<void>(c.reload(), const Duration(seconds: 5), null);
          await _settle(c, t, nav: true);
          note = desk ? 'Now showing the desktop site.' : 'Now showing the mobile site.';
          break;
        case 'browser_login':
          final res = await _login(c, (a['site'] ?? '').toString());
          if (!res.startsWith('ok')) return res;
          await _settle(c, t, max: 500);
          return '${res.substring(3)}\n\n${await observe(callId: callId, shots: shots, before: before)}';
      }
      // Landed on a sign-in page: start the sign-in for the user at once instead of going quiet.
      if (_navActions.contains(name)) {
        final auto = await _autoLogin(c);
        if (auto != null) note = note.isEmpty ? auto : '$note\n$auto';
      }
      final view = await observe(callId: callId, shots: shots, before: before);
      return note.isEmpty ? view : '$note\n$view';
    } on TimeoutException {
      return 'Error: the browser did not respond in time. If the page is stuck, try browser_reload or browser_back.';
    } catch (e) {
      return 'Error: $e. If the page is stuck, try browser_reload or browser_back.';
    }
  }

  // ---- the data ear (browser_net / browser_fetch) ----
  /// The site's own API calls, heard by the page script: list them, read one body, forget them.
  Future<String> _net(InAppWebViewController c, Map<String, dynamic> a) async {
    if (a['clear'] == true) {
      await _js(c, 'return S.netClear();', limit: const Duration(seconds: 3));
      return 'Forgot the recorded data calls (the ear keeps listening).';
    }
    final id = _intV(a['id']);
    if (id > 0) {
      final raw = await _js(c, 'return S.netBody($id);', limit: const Duration(seconds: 5));
      final dynamic j;
      try {
        j = jsonDecode(raw);
      } catch (_) {
        return 'Error: could not read call $id.';
      }
      if (j is! Map) return 'Error: could not read call $id.';
      if (j['err'] == 'gone') return 'Call $id is gone (the ear keeps the last 40). List again with browser_net.';
      return formatNetBody(NetCall.fromJson(Map<String, dynamic>.from(j)));
    }
    final raw = await _js(c, 'return S.netList(${jsonEncode((a['filter'] ?? '').toString())});', limit: const Duration(seconds: 5));
    final List<dynamic> list;
    try {
      list = raw.isEmpty ? const [] : (jsonDecode(raw) as List? ?? const []);
    } catch (_) {
      return 'Error: could not read the page\'s data calls.';
    }
    return formatNetList([for (final e in list) if (e is Map) NetCall.fromJson(Map<String, dynamic>.from(e))]);
  }

  /// Call the site's API with the page's own session (cookies, sign-in): one step instead of many clicks.
  /// Reads only (GET/HEAD) — acting on a site goes through its own controls, which ask the user first.
  Future<String> _fetchApi(InAppWebViewController c, Map<String, dynamic> a) async {
    final u = (a['url'] ?? '').toString().trim();
    if (u.isEmpty) return 'Error: no url given.';
    final m = ((a['method'] ?? 'GET') as String).toUpperCase();
    if (m != 'GET' && m != 'HEAD') {
      return 'Error: browser_fetch reads (GET/HEAD). To act on the site, use its own controls — that asks the user first.';
    }
    final headers = a['headers'] is Map ? {for (final e in (a['headers'] as Map).entries) '${e.key}': '${e.value}'} : <String, String>{};
    final r = await Bounded.run<CallAsyncJavaScriptResult?>(
        c.callAsyncJavaScript(functionBody: '''
      var r = await fetch(u, {method: m, headers: h, credentials: 'include'});
      var t = await r.text();
      var ct = '';
      try { ct = r.headers.get('content-type') || ''; } catch (e) {}
      return JSON.stringify({status: r.status, ct: ct, text: t.length > 24000 ? t.slice(0, 24000) : t});
    ''', arguments: {'u': u, 'm': m, 'h': headers}), const Duration(seconds: 15), null);
    if (r == null) return 'Error: the site did not answer in time.';
    if (r.error != null) {
      return 'Error: ${r.error}. The site may block this call from the page (origin rules) — read it from the page instead.';
    }
    Map<String, dynamic>? j;
    try {
      final v = r.value;
      j = v is String ? Map<String, dynamic>.from(jsonDecode(v) as Map) : (v is Map ? Map<String, dynamic>.from(v) : null);
    } catch (_) {}
    if (j == null) return 'Error: unreadable answer.';
    return formatFetch(method: m, url: u, status: (j['status'] as num?)?.toInt() ?? 0, ct: '${j['ct'] ?? ''}', body: '${j['text'] ?? ''}');
  }

  /// The page's own structured data (JSON-LD, app state): list it, or read one block in full.
  Future<String> _schema(InAppWebViewController c, Map<String, dynamic> a) async {
    final idx = _intV(a['index']);
    if (idx > 0) {
      final raw = await _js(c, 'return S.schemaOpen($idx);', limit: const Duration(seconds: 5));
      return formatSchemaOpen(raw);
    }
    final raw = await _js(c, 'return S.schema();', limit: const Duration(seconds: 5));
    return formatSchemaIndex(raw);
  }

  /// The one-call walker: every element matching `rows` becomes one record of the given fields.
  Future<String> _extract(InAppWebViewController c, Map<String, dynamic> a) async {
    final spec = {'rows': '${a['rows'] ?? ''}', 'fields': a['fields'] is Map ? a['fields'] : <String, dynamic>{}, 'limit': _intV(a['limit'])};
    final raw = await _js(c, 'return S.extract(${jsonEncode(spec)});', limit: const Duration(seconds: 8));
    return formatExtract(raw);
  }

  /// Many pages, one table (P5): the links are fetched together with the WebView's own cookies and each page is
  /// parsed by the same walker in one JS call — no tab per page, no render, no waiting for the page to draw.
  /// Pages that only exist after their scripts run are reported back, not guessed at.
  Future<String> _extractMany(InAppWebViewController c, BrowserTab t, Map<String, dynamic> a) async {
    if (_ended2(jobNow)) return 'Stopped: this browser task has ended.';
    final rows = '${a['rows'] ?? ''}'.trim();
    if (rows.isEmpty) return 'Error: give rows — the CSS selector that matches each item on those pages.';
    final limitRaw = _intV(a['limit']);
    final limit = limitRaw <= 0 ? 50 : limitRaw.clamp(1, 200).toInt();
    final pagesRaw = _intV(a['max_pages']);
    final maxPages = pagesRaw <= 0 ? 6 : pagesRaw.clamp(1, 8).toInt();
    final spec = {
      'rows': rows,
      'fields': a['fields'] is Map ? a['fields'] : <String, dynamic>{},
      'limit': limit,
    };
    var links = <String>[];
    if (a['links'] is List) {
      links = [for (final e in a['links'] as List) '$e'.trim()];
    } else if ('${a['from'] ?? ''}'.trim().isNotEmpty) {
      final sel = '${a['from']}'.trim();
      final raw = await _js(
          c,
          'return JSON.stringify([].slice.call(document.querySelectorAll(${jsonEncode(sel)}), 0, 40)'
              '.map(function(e){return e.href || e.getAttribute("href") || "";}).filter(function(u){return !!u;}));',
          limit: const Duration(seconds: 8));
      try {
        final l = jsonDecode(raw);
        if (l is List) links = [for (final e in l) '$e'.trim()];
      } catch (_) {}
      if (links.isEmpty) {
        return 'No links matched "$sel" on this page. Give links: [...] instead, or check the selector with browser_read.';
      }
    }
    // Real pages only, absolute, once each, in the order given.
    final base = Uri.tryParse(t.url);
    final seen = <String>{};
    final urls = <String>[];
    for (final l in links) {
      if (l.isEmpty) continue;
      final u = Uri.tryParse(l);
      final abs = u == null ? null : (u.hasScheme ? u : base?.resolveUri(u));
      if (abs == null || (abs.scheme != 'http' && abs.scheme != 'https')) continue;
      if (seen.add(abs.toString())) urls.add(abs.toString());
      if (urls.length >= maxPages) break;
    }
    if (urls.isEmpty) return 'Error: no usable http(s) links to read.';
    // Fetched together (fast), parsed one at a time (the page script is one engine).
    final bodies = await Future.wait(urls.map(_httpGet));
    final pages = <ExtractPage>[];
    for (var i = 0; i < urls.length; i++) {
      final res = bodies[i];
      if (res == null) {
        pages.add(ExtractPage(urls[i], error: 'could not be fetched'));
        continue;
      }
      if (_ended2(jobNow)) return 'Stopped: this browser task has ended.';
      final html = res.body.length > 400000 ? res.body.substring(0, 400000) : res.body;
      final raw = await _js(c, 'return S.extractHtml(${jsonEncode(html)}, ${jsonEncode(spec)});', limit: const Duration(seconds: 12));
      final p = parseExtractPage(urls[i], raw);
      // A page that is all script has no items until it runs: say so instead of reporting an empty page.
      if (p.ok && p.rows.isEmpty && html.length < 2000) {
        pages.add(ExtractPage(urls[i], error: 'needs a render'));
        continue;
      }
      pages.add(p);
    }
    return formatManyExtract(pages);
  }

  // ---- site skills (browser_play): list, save what worked, replay with no model calls ----
  /// A saved flow replays step by step against the live page. It never thinks, never spends a model call,
  /// and never decides for the user: on the first step that no longer matches, or when a payment page is
  /// reached, it stops and hands the job back to the agent with the page in front of it (self-heal).
  Future<String> _play(InAppWebViewController c, BrowserTab t, Map<String, dynamic> a) async {
    final action = '${a['action'] ?? 'list'}';
    final host = snapFor(jobNow).host;
    if (action == 'list') {
      final list = await SiteSkills.I.forHost(host);
      if (list.isEmpty) {
        return 'No site skills saved for $host yet. When a multi-step flow works, save it: browser_play action "save" '
            'with a name and what it does.';
      }
      return 'Site skills for $host (run one with browser_play action "run", id):\n'
          '${[for (final p in list) '- ${p.line}${p.goal.isEmpty ? '' : ' — ${p.goal}'}'].join('\n')}';
    }
    if (action == 'forget') {
      final id = '${a['id'] ?? ''}'.trim();
      if (id.isEmpty) return 'Error: give the id of the skill to forget (browser_play action "list" shows them).';
      await SiteSkills.I.forget(id);
      return 'Forgot "$id".';
    }
    if (action == 'save') {
      final name = '${a['name'] ?? ''}'.trim();
      if (name.isEmpty) return 'Error: give the skill a name (what the flow does), e.g. "Book a hotel room".';
      final steps = compressSteps(recorded);
      if (steps.isEmpty) {
        return 'Nothing to save: this job has no click/type/select steps recorded yet. Do the flow first, then save it.';
      }
      final p = Playbook(id: playbookId(name), name: name, site: host, goal: '${a['goal'] ?? ''}'.trim(), steps: steps);
      final err = await SiteSkills.I.save(p);
      if (err != null) return 'Error: $err';
      // Also in "Your own skills", readable: the user sees what the agent learned and can remove it there.
      try {
        await SkillLibrary.I.save(SkillLibrary.agent,
            id: 'web-${p.id}',
            name: 'On $host: $name',
            desc: p.goal.isEmpty ? 'A saved browser flow for $host.' : p.goal,
            body: p.readable,
            tags: ['browser', host]);
      } catch (_) {}
      return 'Saved "${p.name}" as a site skill for $host (${steps.length} steps). It follows the account, so it replays on '
          'the user\'s other phones too. Next time: browser_play action "run", id "${p.id}".';
    }
    // run
    final id = '${a['id'] ?? ''}'.trim();
    Playbook? p;
    if (id.isNotEmpty) p = await SiteSkills.I.byId(id);
    if (p == null) {
      final list = await SiteSkills.I.forHost(host);
      if (list.length == 1) p = list.first;
    }
    if (p == null) {
      return 'Error: no site skill ${id.isEmpty ? '(none given)' : '"$id"'} for $host. List them with browser_play action "list".';
    }
    final values = <String, String>{};
    if (a['values'] is Map) {
      for (final e in (a['values'] as Map).entries) {
        values['${e.key}'] = '${e.value}';
      }
    }
    final steps = withValues(p.steps, values);
    var done = 0;
    var signedIn = false;
    for (var i = 0; i < steps.length; i++) {
      final s = steps[i];
      if (_ended2(jobNow)) return 'Stopped: this browser task has ended.';
      var snap = await _refresh(c, t);
      // A replay that lands on a sign-in page offers the saved login ONCE, as one tap, so a saved flow never
      // stalls on auth (P6). Nothing is used silently: the user still confirms it.
      if (snap.password && !signedIn) {
        signedIn = true;
        final lr = await _login(c, p.site);
        if (!lr.startsWith('ok')) {
          await SiteSkills.I.bump(p, win: false);
          return 'Replay paused at step ${i + 1} of ${steps.length} (${s.line}): this page asks for a sign-in. $lr';
        }
        await _settle(c, t, nav: true);
        snap = await _refresh(c, t);
      }
      if (snap.moneyPage && s.act == 'click') {
        await SiteSkills.I.bump(p, win: false);
        return 'Paused before step ${i + 1} of ${steps.length} (${s.line}): this is a payment page, and the user is asked '
            'before money moves. Finish this step yourself, then the rest.';
      }
      if (s.act == 'scroll') {
        await _js(c, 'return JSON.stringify(S.scroll(${jsonEncode(s.value.isEmpty ? 'down' : s.value)}, "page", null));');
        await _settle(c, t, max: 700);
        done++;
        continue;
      }
      if (s.act == 'key') {
        await _key(c, t, s.value);
        done++;
        continue;
      }
      if (s.act == 'wait') {
        await Future<void>.delayed(Duration(milliseconds: int.tryParse(s.value) ?? 800));
        continue;
      }
      final el = resolveStep(s, snap.elements);
      if (el == null) {
        await SiteSkills.I.bump(p, win: false);
        return 'Replay stopped at step ${i + 1} of ${steps.length} (${s.line}): that control is not on this page now. '
            'Take over from here — do this step yourself and the rest of the goal; saving the skill again records the new path.';
      }
      final ({bool ok, String text}) r;
      if (s.act == 'type') {
        r = await _type(c, t, el.id, s.value, submit: s.submit);
      } else if (s.act == 'select') {
        r = await _select(c, t, el.id, s.value);
      } else {
        r = await _click(c, t, el.id);
      }
      if (!r.ok) {
        await SiteSkills.I.bump(p, win: false);
        return 'Replay stopped at step ${i + 1} of ${steps.length} (${s.line}): ${r.text}. Take over from here.';
      }
      done++;
    }
    await SiteSkills.I.bump(p, win: true);
    return 'Replayed "${p.name}": $done steps with no model calls. Check the result below before you finish.';
  }

  // ---- speed (P4): HTTP-first triage ----
  /// A read-only open answers from a same-session fetch (the WebView's cookies, no CORS, no render):
  /// "Served from fetch, no render". Null means the page needs scripts — render it instead.
  Future<String?> _fetchRead(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return null;
    final res = await _httpGet(url);
    if (res == null) return null; // let the browser show the error page
    if (res.ct.contains('json')) {
      var out = res.body;
      try {
        out = const JsonEncoder.withIndent('  ').convert(jsonDecode(res.body));
      } catch (_) {}
      return 'Served from fetch, no render — ${uri.host} (JSON, ${res.status})\n$url\n\n'
          '${out.length > 8000 ? '${out.substring(0, 8000)}…' : out}';
    }
    if (!res.ct.contains('html') && !res.ct.contains('text')) return null;
    final text = htmlToText(res.body);
    if (text.length < 200) return null; // a script shell: the browser has to draw it
    final title = htmlTitle(res.body);
    return 'Served from fetch, no render — ${title.isEmpty ? uri.host : title}\n$url\n\n$text';
  }

  /// One GET with the WebView's own cookies (same session, no CORS, no render). Null when it fails.
  /// Used by the read-only open and by the many-page extraction.
  Future<({int status, String ct, String body})?> _httpGet(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return null;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final cookies = await CookieManager.instance().getCookies(url: WebUri(url)).timeout(const Duration(seconds: 3));
      final req = await client.getUrl(uri).timeout(const Duration(seconds: 8));
      if (cookies.isNotEmpty) req.headers.set('cookie', cookies.map((c) => '${c.name}=${c.value}').join('; '));
      req.headers.set('user-agent', 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36');
      req.headers.set('accept', 'text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8');
      final res = await req.close().timeout(const Duration(seconds: 15));
      if (res.statusCode >= 400) return null;
      final ct = (res.headers.contentType?.mimeType ?? '').toLowerCase();
      final body = await const Utf8Decoder(allowMalformed: true).bind(res).join().timeout(const Duration(seconds: 10));
      return (status: res.statusCode, ct: ct, body: body);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  // ---- actions ----  /// The result of one action: ok or not, and a line for the model.
  static ({bool ok, String text}) _r(bool ok, String text) => (ok: ok, text: text);

  /// Runs a batch: in order, stopping at the first failure or as soon as the page changes under it.
  Future<String> _batch(InAppWebViewController c, BrowserTab t, List<BrowserAction> acts) async {
    final lines = <String>[];
    final startUrl = t.url;
    for (var k = 0; k < acts.length; k++) {
      if (_ended2(jobNow)) break;
      final x = acts[k];
      final before = x.mayChangePage ? await _state(c) : const <String, dynamic>{};
      ({bool ok, String text}) r;
      switch (x.kind) {
        case 'click':
        case 'check':
          r = await _click(c, t, x.id, long: x.args['long'] == true);
          break;
        case 'type':
          r = await _type(c, t, x.id, '${x.args['text']}', submit: x.args['submit'] == true, append: x.args['append'] == true);
          break;
        case 'select':
          r = await _select(c, t, x.id, '${x.args['option']}');
          break;
        case 'clear':
          final m = await _jsMap(c, 'return JSON.stringify(S.clear(${x.id}));');
          r = _r(m['ok'] == true, m['ok'] == true ? 'Cleared [${x.id}].' : 'Could not clear [${x.id}].');
          break;
        case 'scroll':
          final m = await _jsMap(c, 'return JSON.stringify(S.scroll(${jsonEncode('${x.args['direction'] ?? 'down'}')}, '
              '${jsonEncode('${x.args['amount'] ?? 'page'}')}, ${x.args['id'] == null ? 'null' : _int(x.args['id'])}));');
          await _settle(c, t, max: 600);
          if (m['ok'] == true) _record({'do': 'scroll', 'v': '${x.args['direction'] ?? 'down'}'});
          r = _r(m['ok'] == true, m['ok'] == true ? 'Scrolled ${x.args['direction'] ?? 'down'}.' : '${m['err'] ?? 'Could not scroll'}.');
          break;
        case 'key':
          await _key(c, t, '${x.args['key']}');
          _record({'do': 'key', 'v': '${x.args['key']}'});
          r = _r(true, 'Pressed ${x.args['key']}.');
          break;
        case 'wait':
          r = _r(true, await _wait(c, t, x.args));
          break;
        case 'find':
          final m = await _jsMap(c, 'return JSON.stringify(S.find(${jsonEncode('${x.args['text'] ?? ''}')}));');
          r = _r(m['ok'] == true, m['ok'] == true ? 'Found "${x.args['text']}".' : '"${x.args['text']}" is not on this page.');
          break;
        default:
          r = _r(false, 'Unknown action ${x.kind}.');
      }
      lines.add('${k + 1}. ${r.text}');
      if (!r.ok) {
        if (k < acts.length - 1) lines.add('Stopped here: actions ${k + 2}-${acts.length} were not done.');
        break;
      }
      if (x.mayChangePage && k < acts.length - 1) {
        final after = await _state(c);
        final moved = t.loading || t.url != startUrl || (after['url'] != null && '${after['url']}' != '${before['url']}');
        if (moved) {
          lines.add('The page changed, so actions ${k + 2}-${acts.length} were skipped: look at the new view.');
          break;
        }
      }
    }
    return lines.join('\n');
  }

  /// Click: page script first (hit-tested, the exact element), verify the effect, real touch only if nothing happened.
  ({bool ok, String text}) _clicked(int id, String text) {
    _record({'do': 'click', ..._sig(id)});
    return _r(true, text);
  }

  Future<({bool ok, String text})> _click(InAppWebViewController c, BrowserTab t, int id, {bool long = false}) async {
    final before = await _state(c);
    if (long) {
      final p = await _jsMap(c, 'return JSON.stringify(S.point($id));');
      if (p['ok'] != true) return _r(false, '${p['err'] ?? 'element $id is not there'}');
      if (await _touch(c, t, 'long', _d(p['fx']), _d(p['fy']), id: id) == 'target') {
        await _settle(c, t, nav: true);
        return _clicked(id, 'Long-pressed [$id].');
      }
    }
    final r = await _jsMap(c, 'return JSON.stringify(S.click($id));');
    if (r['ok'] != true) {
      // Self-heal (P6): the number is gone because the page redrew that control. Find it again by what it
      // looked like and tap it once, instead of spending a model turn on re-perceiving the page.
      final he = await _heal(c, id);
      if (he != null) {
        final r2 = await _jsMap(c, 'return JSON.stringify(S.click(${he.id}));');
        if (r2['ok'] == true) {
          await _settle(c, t, nav: true, max: 1500);
          return _clicked(he.id,
              'Tapped [${he.id}] instead: [$id] had been redrawn by the page and was found again by its ${he.how}'
              '${he.label.isEmpty ? '' : ' ("${he.label}")'}.');
        }
      }
      return _r(false, '${r['err'] ?? 'could not tap $id'}');
    }
    await _settle(c, t, nav: true, max: 1500);
    final after = await _state(c);
    if (StepEffect.compare(before, after).any || t.loading || after['net'] != before['net']) return _clicked(id, 'Tapped [$id].');
    // Nothing happened: some sites only listen to real fingers. Tap the same verified point for real.
    if (realHands) {
      final p = await _jsMap(c, 'return JSON.stringify(S.point($id));');
      if (p['ok'] == true) {
        final hit = await _touch(c, t, 'tap', _d(p['fx']), _d(p['fy']), id: id);
        if (hit == 'target') {
          await _settle(c, t, nav: true, max: 1500);
          return _clicked(id, 'Tapped [$id] (with a real touch).');
        }
        if (hit == 'other') return _r(false, 'the tap on [$id] reached something else on top of it; close what covers it, or scroll');
      }
    }
    // The tap landed and nothing changed: if the control has been redrawn since, say where it went so the next
    // step is a number, not another look at the page.
    final he = await _heal(c, id);
    if (he != null) {
      return _clicked(id, 'Tapped [$id], but nothing visible changed. [$id] is gone now and the same control is [${he.id}] — '
          'tap that next.');
    }
    return _clicked(id, 'Tapped [$id], but nothing visible changed.');
  }

  /// The same control, found again by its signature after the page redrew it (P6). Null when it is still there
  /// under the same number, or when nothing on the page matches what it looked like.
  Future<HealedTarget?> _heal(InAppWebViewController c, int id) async =>
      parseHeal(await _jsMap(c, 'return JSON.stringify(S.heal($id));'), id);

  Future<({bool ok, String text})> _tapAt(InAppWebViewController c, BrowserTab t, double fx, double fy, {bool long = false}) async {
    fx = fx.clamp(0.0, 1.0).toDouble();
    fy = fy.clamp(0.0, 1.0).toDouble();
    final what = await _js(c, 'return S.whatAt($fx, $fy);');
    var done = false;
    if (realHands) done = await _touch(c, t, long ? 'long' : 'tap', fx, fy) != 'none';
    if (!done) {
      final r = await _jsMap(c, 'return JSON.stringify(S.tapAt($fx, $fy));');
      if (r['ok'] != true) return _r(false, '${r['err'] ?? 'nothing at that point'}');
    }
    await _settle(c, t, nav: true, max: 1500);
    return _r(true, 'Tapped $what at ${(fx * 100).round()},${(fy * 100).round()}.');
  }

  /// Type: set the value through the page (fast, works with React), check it; real keyboard only if it did not take.
  Future<({bool ok, String text})> _type(InAppWebViewController c, BrowserTab t, int id, String text, {bool submit = false, bool append = false}) async {
    var r = await _jsMap(c, 'return JSON.stringify(S.type($id, ${jsonEncode(text)}, $append));');
    var healedNote = '';
    if (r['ok'] != true && '${r['err']}'.contains('gone')) {
      // Self-heal (P6): the field was redrawn under a new number — find it by its label and type there.
      final he = await _heal(c, id);
      if (he != null) {
        final r2 = await _jsMap(c, 'return JSON.stringify(S.type(${he.id}, ${jsonEncode(text)}, $append));');
        if (r2['ok'] == true) {
          healedNote = ' ([$id] had been redrawn; it is [${he.id}] now)';
          id = he.id;
          r = r2;
        }
      }
    }
    if (r['ok'] != true && realHands) {
      final prep = await _js(c, 'return S.prep($id, $append);');
      if (prep == 'ok' && await _keys(c, t, text: text)) {
        r = {'ok': (await _js(c, 'return S.valueOf($id);')).toLowerCase().contains(text.toLowerCase().substring(0, text.length > 20 ? 20 : text.length))};
      }
    }
    if (r['ok'] != true) return _r(false, '${r['err'] ?? 'the field did not take the text'}');
    if (submit) await _key(c, t, 'Enter');
    await _settle(c, t, nav: submit, max: submit ? 2500 : 500);
    _record({'do': 'type', ..._sig(id), 'v': text, if (submit) 's': true});
    return _r(true, 'Typed into [$id]${submit ? ' and pressed Enter' : ''}.$healedNote');
  }

  Future<({bool ok, String text})> _select(InAppWebViewController c, BrowserTab t, int id, String option) async {
    final r = await _jsMap(c, 'return JSON.stringify(S.select($id, ${jsonEncode(option)}));');
    if (r['custom'] == 1) {
      // Not a real <select>: open it; the options appear as new numbered elements.
      final k = await _click(c, t, id);
      return k.ok ? _r(true, 'Opened [$id]. It is a custom list: tap the option "$option" in the new view.') : k;
    }
    if (r['ok'] != true) return _r(false, '${r['err'] ?? 'could not choose "$option"'}');
    await _settle(c, t, max: 600);
    _record({'do': 'select', ..._sig(id), 'v': '${r['value'] ?? option}'});
    return _r(true, 'Chose "${r['value'] ?? option}" in [$id].');
  }

  Future<void> _key(InAppWebViewController c, BrowserTab t, String k) async {
    final before = await _state(c);
    var sent = false;
    if (realHands) sent = await _keys(c, t, key: k);
    if (sent) await _settle(c, t, nav: k.toLowerCase() == 'enter', max: 800);
    if (!sent || !StepEffect.compare(before, await _state(c)).any) {
      await _js(c, 'return JSON.stringify(S.key(${jsonEncode(k)}));');
      await _settle(c, t, nav: k.toLowerCase() == 'enter', max: 1500);
    }
  }

  Future<String> _wait(InAppWebViewController c, BrowserTab t, Map<String, dynamic> a) async {
    if (a['quiet'] == true) {
      final r = await _js(c, 'return await S.quiet(10000, 400);', limit: const Duration(seconds: 12));
      return r == 'calm'
          ? 'The page went quiet (no requests in flight, no changes). Act now.'
          : 'Waited 10 s; the page is still busy. Act on what is there, or wait once more.';
    }
    final want = (a['text'] ?? '').toString();
    final secs = _numD(a['seconds'], want.isEmpty ? 2 : 10).clamp(0.5, 20.0).toDouble();
    final ms = (secs * 1000).round();
    if (want.isEmpty) {
      await Bounded.sleep(Duration(milliseconds: ms), () => _ended2(jobNow));
      return 'Waited ${secs.round()} s.';
    }
    final gone = a['gone'] == true;
    final r = await _js(c, 'return await S.waitText(${jsonEncode(want)}, $ms, $gone);', limit: Duration(milliseconds: ms + 3000));
    if (r == 'ok') return gone ? '"$want" is gone now.' : '"$want" is on the page now.';
    return gone ? '"$want" is still there after ${secs.round()} s.' : '"$want" did not appear within ${secs.round()} s.';
  }

  Future<String> _swipe(InAppWebViewController c, BrowserTab t, Map<String, dynamic> a) async {
    double? fx, fy, fx2, fy2;
    if (a['x'] != null && a['y'] != null && a['x2'] != null && a['y2'] != null) {
      fx = _numD(a['x'], 50) / 100;
      fy = _numD(a['y'], 50) / 100;
      fx2 = _numD(a['x2'], 50) / 100;
      fy2 = _numD(a['y2'], 50) / 100;
    } else {
      final p = await _jsMap(c, 'return JSON.stringify(S.swipePoints(${jsonEncode((a['direction'] ?? 'left').toString())}, '
          '${a['id'] == null ? 'null' : _int(a['id'])}));');
      if (p['ok'] != true) return '${p['err'] ?? 'nothing to swipe'}';
      fx = _d(p['fx']);
      fy = _d(p['fy']);
      fx2 = _d(p['fx2']);
      fy2 = _d(p['fy2']);
    }
    // A real finger travels a curve with a wobble (and, on a long drag, a small overshoot), as one gesture;
    // how long it takes follows the distance and is never the same twice.
    var ok = false;
    if (realHands) {
      final ms = HumanInput.swipeMs(HumanInput.distance(fx, fy, fx2, fy2));
      ok = await _touch(c, t, 'swipe', fx, fy, fx2: fx2, fy2: fy2, ms: ms, pts: HumanInput.stroke(fx, fy, fx2, fy2)) != 'none';
    }
    if (!ok) await _js(c, 'return JSON.stringify(await S.swipe($fx, $fy, $fx2, $fy2));', limit: const Duration(seconds: 5));
    await _settle(c, t, max: 800);
    return 'Swiped.';
  }

  // ---- real hands: genuine Android touches and keystrokes into the tab's WebView ----
  /// On by default. Used only when page script had no effect (or for long-press and swipes).
  bool realHands = true;

  /// The tab's title carries a mark so the native side picks this tab's WebView even when two show the same page.
  Future<String> _mark(InAppWebViewController c, BrowserTab t) async {
    final m = '\u2063sm${t.id}';
    await _js(c, 'if (document.title.indexOf(${jsonEncode(m)}) < 0) document.title = document.title + ${jsonEncode(m)}; return "";');
    return m;
  }

  Future<void> _unmark(InAppWebViewController c, String m) async {
    if (m.isEmpty) return;
    await _js(c, 'document.title = document.title.split(${jsonEncode(m)}).join(""); return "";');
  }

  /// A real touch at a fraction of the visible page. Returns 'target' when the element [id] (if given) got the trusted
  /// event, 'other' when something else got it, 'none' when no real touch reached the page.
  ///
  /// A tap rests a little longer or shorter each time, and a swipe/drag travels the path in [pts] — curved, with a
  /// wobble and, on a long drag, a small overshoot — as ONE gesture (P6: hands that look like a person's).
  Future<String> _touch(InAppWebViewController c, BrowserTab t, String kind, double fx, double fy,
      {double? fx2, double? fy2, int ms = 320, int? id, List<({double x, double y})>? pts}) async {
    if (!realHands || t.url.isEmpty) return 'none';
    await _js(c, 'return S.armHits();');
    final m = await _mark(c, t);
    final String r;
    if (pts != null && pts.length > 1) {
      r = await SystemBridge.I.webStroke(t.url, pts, ms: ms, mark: m);
    } else {
      final hold = kind == 'long' ? HumanInput.longPressMs() : HumanInput.tapHoldMs();
      r = await SystemBridge.I.webTouch(t.url, kind, fx, fy, x2: fx2, y2: fy2, ms: ms, hold: hold, mark: m);
    }
    await _unmark(c, m);
    if (r != 'ok') return 'none';
    await Future<void>.delayed(const Duration(milliseconds: 60));
    if (t.loading) return 'target'; // it started a navigation (the page script is gone with the old page)
    final hit = await _js(c, 'return S.hitOn(${id ?? -1});');
    if (id == null) return hit == 'none' ? 'none' : 'target';
    return hit == 'target' || hit == 'other' ? hit : 'none';
  }

  /// Real keys into the focused field. Text is typed in bursts with pauses — the way a keyboard app delivers
  /// keys — because one instant paste is not what a person's hands do.
  Future<bool> _keys(InAppWebViewController c, BrowserTab t, {String? text, String? key}) async {
    if (!realHands || t.url.isEmpty) return false;
    final m = await _mark(c, t);
    var ok = true;
    try {
      if (text != null && text.isNotEmpty) {
        for (final p in HumanInput.typing(text)) {
          if (_ended2(jobNow)) {
            ok = false;
            break;
          }
          if (p.delayMs > 0) await Future<void>.delayed(Duration(milliseconds: p.delayMs));
          if (await SystemBridge.I.webType(t.url, p.chunk, mark: m) != 'ok') {
            ok = false;
            break;
          }
        }
      } else {
        ok = await SystemBridge.I.webKey(t.url, key ?? 'enter', mark: m) == 'ok';
      }
    } finally {
      await _unmark(c, m);
    }
    return ok;
  }

  // ---- waiting, state, observing ----
  Future<Map<String, dynamic>> _state(InAppWebViewController c) => _jsMap(c, 'return JSON.stringify(S.state());', limit: const Duration(seconds: 3));

  /// Smart wait: a navigation that starts gets to finish (bounded), then the page must be calm (DOM quiet, no request
  /// in flight). No fixed sleeps. Ends at once when the task is stopped.
  Future<void> _settle(InAppWebViewController c, BrowserTab t, {bool nav = false, int max = 2500}) async {
    if (nav && !t.loading) {
      for (var i = 0; i < 5 && !t.loading; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }
    }
    if (t.loading && t.loadStop != null) {
      await Bounded.orCancel<void>(t.loadStop!.future, _endOf(jobNow), limit: const Duration(seconds: 15));
    }
    if (_ended2(jobNow)) return;
    final cur = t.c;
    if (cur == null) return;
    await _js(cur, 'return await S.quiet($max, 250);', limit: Duration(milliseconds: max + 2000));
  }

  Future<void> _load(BrowserTab t, String u) async {
    final c = t.c;
    if (c == null) throw StateError('the browser view is not ready');
    t.loadStop = Completer<void>();
    t.lastError = null;
    await Bounded.run<void>(c.loadUrl(urlRequest: URLRequest(url: WebUri(u))), const Duration(seconds: 8), null);
    await Bounded.orCancel<void>(t.loadStop!.future, _endOf(jobNow), limit: loadLimit);
    if (!(t.loadStop?.isCompleted ?? true)) t.lastError ??= 'the page took longer than 20 seconds';
    if (t.lastError != null && !_ended2(jobNow)) {
      // Self-heal once: reload.
      t.loadStop = Completer<void>();
      t.lastError = null;
      await Bounded.run<void>(c.reload(), const Duration(seconds: 5), null);
      await Bounded.orCancel<void>(t.loadStop!.future, _endOf(jobNow), limit: loadLimit);
      if (!(t.loadStop?.isCompleted ?? true)) t.lastError ??= 'the page did not load after a reload';
    }
    await _settle(c, t, max: 2000);
  }

  /// Runs page script (the page script is injected again if this page lost it), always with a time limit.
  Future<String> _js(InAppWebViewController c, String body, {Duration limit = jsLimit}) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final r = await c
            .callAsyncJavaScript(
                functionBody: 'if (!window.__sm2 || window.__sm2.v !== ${PageScript.version}) return "__sm_missing__";\n'
                    'const S = window.__sm2;\n$body')
            .timeout(limit);
        if (r?.error != null) return 'script error: ${r!.error}';
        final v = r?.value;
        if (v == '__sm_missing__') {
          await c.evaluateJavascript(source: PageScript.source).timeout(const Duration(seconds: 5));
          continue;
        }
        return v == null ? '' : (v is String ? v : jsonEncode(v));
      } on TimeoutException {
        return 'timeout: the page did not respond (it may be frozen or still loading).';
      } catch (e) {
        return 'script error: $e';
      }
    }
    return 'script error: the page script could not be loaded on this page';
  }

  Future<Map<String, dynamic>> _jsMap(InAppWebViewController c, String body, {Duration limit = jsLimit}) async {
    final raw = await _js(c, body, limit: limit);
    try {
      final j = jsonDecode(raw);
      if (j is Map) return Map<String, dynamic>.from(j);
    } catch (_) {}
    return {'ok': false, 'err': raw.isEmpty ? 'no answer from the page' : raw};
  }

  /// What the agent sees after every step: the effect of the step, the numbered elements, the text in view, and a
  /// FRESH screenshot with the same numbers drawn on it. The snapshot and the screenshot are taken together.
  Future<String> observe({String? callId, bool shots = true, Map<String, dynamic>? before, bool retried = false}) async {
    final t = tab;
    final c = t?.c;
    if (t == null || c == null) return 'Browser is closed.';
    final prev = t.snap;
    final shotF = shots
        ? Bounded.run<Uint8List?>(
            c.takeScreenshot(screenshotConfiguration: ScreenshotConfiguration(compressFormat: CompressFormat.JPEG, quality: 70)), shotLimit, null)
        : Future<Uint8List?>.value(null);
    final raw = await _js(c, 'return JSON.stringify(S.snapshot({max: 140, text: 2600}));', limit: const Duration(seconds: 10));
    PageSnapshot snap;
    try {
      snap = PageSnapshot.parse(raw);
    } catch (_) {
      await shotF;
      return 'Page: $title — $url\n(could not read this page: ${raw.length > 200 ? raw.substring(0, 200) : raw}). Try browser_reload, or browser_back.';
    }
    // A page still drawing itself: give it a moment and look again, once.
    if (!retried && snap.elements.isEmpty && snap.text.isEmpty && t.lastError == null) {
      await shotF;
      await _settle(c, t, max: 2500);
      return observe(callId: callId, shots: shots, before: before, retried: true);
    }
    // A cookie banner in the way: close it once per site (refusing when the site lets us), and look again.
    final b = snap.banner;
    if (b != null && !_bannerDone.contains(snap.host) && !retried) {
      _bannerDone.add(snap.host);
      final r = await _jsMap(c, 'return JSON.stringify(S.click(${b['id']}));');
      if (r['ok'] == true) {
        await shotF;
        await _settle(c, t, max: 1000);
        t.dialogs.add('closed the cookie banner ("${b['name']}")');
        return observe(callId: callId, shots: shots, before: before, retried: true);
      }
    }
    t.snap = snap;
    if (snap.title.isNotEmpty) t.title = snap.title;
    if (snap.favicon.isNotEmpty) t.favicon = snap.favicon;
    labels
      ..clear()
      ..addAll(snap.labels);
    final rawShot = await shotF;
    bool? pixels;
    if (rawShot != null) {
      final set = await Shots.process(rawShot, snap.elements);
      if (set != null) {
        pixels = Shots.changed(t.signature, set.signature);
        t.signature = set.signature;
        t.thumb = set.clean;
        frame.value = set.clean;
        // CB-40: the model gets a picture only when the screen changed since the last one it got.
        if (callId == null || shotForCall == callId || ShotGate.fresh('${t.id}|${t.owner ?? ''}', set.fine)) {
          lastShot = set.marked;
          shotForCall = callId;
        } else {
          ShotGate.noteSame(callId);
          lastShot = null;
          shotForCall = null;
        }
      }
    }
    notifyListeners();
    final sb = StringBuffer();
    if (before != null && before.isNotEmpty) {
      final after = await _state(c);
      if (after['url'] == null) after['url'] = t.url;
      sb.writeln(StepEffect.compare(before, after, pixels: pixels).describe());
    }
    if (tabs.length > 1) sb.writeln('Tab ${t.id} of ${tabs.length} (others: ${[for (final o in tabs) if (o != t) '[${o.id}] ${o.host}'].join(', ')})');
    if (t.lastError != null) {
      sb.writeln('LOAD PROBLEM: ${t.lastError}. Try browser_reload once; if it still fails, browser_back or another site.');
    }
    if (t.dialogs.isNotEmpty) {
      sb.writeln('Notices: ${t.dialogs.join(' | ')}');
      t.dialogs.clear();
    }
    // The data ear: one quiet hint that the site's own APIs are there to be read (P1, browser-godmode).
    if (snap.calls > 0) sb.writeln('Data: ${dataLine(snap.calls)}');
    if (snap.schema.isNotEmpty) sb.writeln('Schema: ${snap.schema} — browser_schema opens one; browser_extract walks the page.');
    sb.writeln(snap.describe(before: prev.url.isEmpty ? null : prev, diff: true));
    if (t.offered.isNotEmpty) sb.writeln('Files offered on this tab: ${t.offered.length} (browser_download saves the newest).');
    if (t.desktop) sb.writeln('(Desktop site mode.)');
    if (snap.moneyPage) sb.writeln('(Payment page: buttons that move on here ask the user first.)');
    if (shots && rawShot == null) sb.writeln('(No screenshot this time: rely on the element list.)');
    if (callId != null && ShotGate.same(callId)) sb.writeln(ShotGate.sameText);
    final out = sb.toString().trimRight();
    return out.length > 10000 ? '${out.substring(0, 10000)}\n…' : out;
  }

  /// An action failed: say why, with the fresh view so the next try uses current numbers.
  Future<String> _failed(String why, String? callId, bool shots) async {
    final view = await observe(callId: callId, shots: shots);
    return 'That did not work: $why.\n$view';
  }

  // ---- files ----
  /// A file the page offered: fetch it with this site's cookies into the user's files.
  Future<String> _download(BrowserTab t, String u, String name) async {
    var url = u.trim();
    if (url.isEmpty && t.offered.isNotEmpty) url = t.offered.last;
    if (url.isEmpty) return 'Error: no file was offered. Tap the download link first, or give its url.';
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return 'Error: that is not a link.';
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final cookies = await CookieManager.instance().getCookies(url: WebUri(url)).timeout(const Duration(seconds: 5));
      final req = await client.getUrl(uri).timeout(const Duration(seconds: 20));
      if (cookies.isNotEmpty) req.headers.set('cookie', cookies.map((k) => '${k.name}=${k.value}').join('; '));
      if (t.url.isNotEmpty) req.headers.set('referer', t.url);
      final res = await req.close().timeout(const Duration(seconds: 60));
      if (res.statusCode >= 400) return 'Error: the site answered ${res.statusCode}.';
      var file = name.trim();
      if (file.isEmpty) {
        final cd = res.headers.value('content-disposition') ?? '';
        file = RegExp('filename\\*?="?(?:UTF-8\'\')?([^";]+)').firstMatch(cd)?.group(1) ?? uri.pathSegments.lastWhere((e) => e.isNotEmpty, orElse: () => 'download');
      }
      file = Uri.decodeComponent(file).replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final dir = Directory('${await AgentTools.workspaceDir()}/downloads');
      await dir.create(recursive: true);
      final out = File('${dir.path}/$file');
      final sink = out.openWrite();
      var n = 0;
      await for (final chunk in res.timeout(const Duration(seconds: 30))) {
        n += chunk.length;
        if (n > 200 * 1024 * 1024) {
          await sink.close();
          await out.delete();
          return 'Error: the file is bigger than 200 MB.';
        }
        sink.add(chunk);
      }
      await sink.close();
      return 'Downloaded "$file" (${(n / 1024).toStringAsFixed(0)} KB) to downloads/$file in the user\'s files.';
    } catch (e) {
      return 'Error: download failed ($e).';
    } finally {
      client.close(force: true);
    }
  }

  /// Put a file from the user's files into a page's file-upload field.
  Future<String> _upload(InAppWebViewController c, int id, String path) async {
    var p = path.trim();
    if (p.isEmpty) return 'Error: give the file path.';
    if (!p.startsWith('/')) p = '${await AgentTools.workspaceDir()}/$p';
    final f = File(p);
    if (!await f.exists()) return 'Error: no file at $path. Use list_dir to find it.';
    final len = await f.length();
    if (len > 15 * 1024 * 1024) return 'Error: files over 15 MB cannot be attached here.';
    final name = p.split('/').last;
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    const types = {
      'pdf': 'application/pdf', 'png': 'image/png', 'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'webp': 'image/webp',
      'gif': 'image/gif', 'doc': 'application/msword', 'txt': 'text/plain', 'csv': 'text/csv', 'mp4': 'video/mp4',
      'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    };
    final b64 = base64Encode(await f.readAsBytes());
    final r = await _jsMap(c, 'return JSON.stringify(S.upload($id, ${jsonEncode(name)}, ${jsonEncode(types[ext] ?? 'application/octet-stream')}, ${jsonEncode(b64)}));',
        limit: const Duration(seconds: 40));
    return r['ok'] == true ? 'ok' : '${r['err'] ?? 'could not attach the file'}';
  }

  void onDownload(BrowserTab t, String url, String name) {
    t.offered.add(url);
    if (t.offered.length > 10) t.offered.removeAt(0);
    onDialog(t, 'download', 'The page offered a file: ${name.isEmpty ? url : name}. Use browser_download to save it.');
  }

  Future<String> _tabs(Map<String, dynamic> a, {String? callId, bool shots = true}) async {
    final act = (a['action'] ?? 'list').toString();
    switch (act) {
      case 'new':
        final u = toUrl((a['url'] ?? '').toString());
        final t = await _newTab();
        t.owner = jobNow;
        if (jobNow != null) _jobTab[jobNow!] = t.id;
        if (u.isNotEmpty) await _load(t, u);
        return observe(callId: callId, shots: shots);
      case 'switch':
        final n = _intV(a['tab']);
        final i = tabs.indexWhere((t) => t.id == n);
        final idx = i >= 0 ? i : n - 1;
        if (idx < 0 || idx >= tabs.length) return 'Error: no tab $n.\n${_tabList()}';
        current = idx;
        if (jobNow != null) {
          tabs[idx].owner = jobNow;
          _jobTab[jobNow!] = tabs[idx].id;
        }
        notifyListeners();
        await Future<void>.delayed(const Duration(milliseconds: 120));
        return observe(callId: callId, shots: shots);
      case 'close':
        if (tabs.isEmpty) return 'No tabs open.';
        final n = a['tab'] == null ? tab!.id : _intV(a['tab']);
        final i = tabs.indexWhere((t) => t.id == n);
        if (i < 0) return 'Error: no tab $n.\n${_tabList()}';
        _closeTab(i);
        if (tabs.isEmpty) return 'Closed the last tab; the browser is closed.';
        if (jobNow != null && tab != null) _jobTab[jobNow!] = tab!.id;
        await Future<void>.delayed(const Duration(milliseconds: 120));
        return 'Tab closed.\n${await observe(callId: callId, shots: shots)}';
      default:
        return tabs.isEmpty ? 'No tabs open.' : _tabList();
    }
  }

  String _tabList() {
    final sb = StringBuffer('Tabs:\n');
    for (var i = 0; i < tabs.length; i++) {
      final t = tabs[i];
      sb.writeln('[${t.id}]${i == current ? ' (current)' : ''} ${t.title.isEmpty ? t.host : t.title} — ${t.url}');
    }
    return sb.toString().trimRight();
  }

  static String _int(dynamic v) => _intV(v).toString();
  static int _intV(dynamic v) => v is num ? v.toInt() : int.tryParse('$v') ?? -1;
  static double _numD(dynamic v, double d) => v is num ? v.toDouble() : double.tryParse('$v') ?? d;
  static String _num(dynamic v, double d) => _numD(v, d).toStringAsFixed(2);
  static double _d(dynamic v) => v is num ? v.toDouble() : double.tryParse('$v') ?? 0.5;

  // ---- sign-in ----
  /// Checks whether the page is a sign-in page and, once per page, starts the sign-in for the user.
  Future<String?> _autoLogin(InAppWebViewController c) async {
    try {
      final r = await _js(c, 'return S.isLogin() ? "1" : "0";', limit: const Duration(seconds: 3));
      if (r != '1') return null;
      final k = '${Uri.tryParse(url)?.host ?? host}${Uri.tryParse(url)?.path ?? ''}';
      if (_autoLoginTried.contains(k)) return null;
      _autoLoginTried.add(k);
      final res = await _login(c, '');
      if (res.startsWith('ok')) return 'This is a sign-in page, so SubMac started the sign-in: ${res.substring(3)}';
      return 'This is a sign-in page. $res';
    } catch (_) {
      return null;
    }
  }

  Future<String> _login(InAppWebViewController c, String siteName) async {
    final site = host.isEmpty ? siteName : host;
    final key = rootDomain(site);
    final end = _endOf(jobNow);
    var cred = _creds[key];
    if (cred == null && loadSavedLogin != null) {
      final saved = await Bounded.run<Map<String, String>?>(loadSavedLogin!(key), const Duration(seconds: 5), null);
      if (saved != null && confirmLogin != null) {
        // A saved login is never used silently: the user confirms it first.
        final pick = await Bounded.orCancel<String?>(confirmLogin!(siteName.isNotEmpty ? siteName : key, saved['username'] ?? ''), end, limit: userLimit);
        if (pick == 'use') {
          cred = saved;
        } else if (pick == null) {
          return 'The user did not sign in now. Ask them in one line what they would like to do.';
        }
        // 'other': fall through to the sign-in form for a different account.
      } else {
        cred = saved;
      }
    }
    if (cred == null) {
      if (askLogin == null) return 'Error: cannot ask the user for a login right now.';
      final shown = siteName.isNotEmpty ? siteName : key;
      final got = await Bounded.orCancel<Map<String, String>?>(askLogin!(shown), end, limit: userLimit);
      if (got == null) return 'The user did not sign in. Ask them in one line what they would like to do.';
      cred = got;
      if (got['save'] == 'true' && saveLogin != null) {
        await Bounded.run<void>(saveLogin!(key, got['username'] ?? '', got['password'] ?? ''), const Duration(seconds: 5), null);
      }
    }
    _creds[key] = cred;
    await _waitIfUser();
    final r = await _js(c, 'return S.login(${jsonEncode(cred['username'] ?? '')}, ${jsonEncode(cred['password'] ?? '')});');
    switch (r) {
      case 'both':
        return 'ok Filled the username and password. Now tap the sign-in button.';
      case 'user':
        return 'ok Filled the username/email. Tap Next/Continue; if a password page follows, call browser_login again.';
      case 'pass':
        return 'ok Filled the password. Now tap the sign-in button.';
      default:
        return 'Error: no login fields found on this page. Open the sign-in page first, then call browser_login.';
    }
  }

  static String rootDomain(String h) {
    final parts = h.toLowerCase().split('.').where((e) => e.isNotEmpty).toList();
    if (parts.length <= 2) return parts.join('.');
    final two = parts.sublist(parts.length - 2).join('.');
    // co.uk, com.so etc.
    if (RegExp(r'^(co|com|org|net|gov|ac|edu)\.[a-z]{2}$').hasMatch(two) && parts.length >= 3) {
      return parts.sublist(parts.length - 3).join('.');
    }
    return two;
  }
}
