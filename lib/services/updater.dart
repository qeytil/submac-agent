import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';
import 'update_logic.dart';

export 'update_logic.dart';

/// Words the native side shows in notifications, in the app's language (filled by the update window, which knows it).
typedef NativeUpdateWords = Map<String, String> Function(String versionName);

/// In-app updates. Checks `latest_release` on cold start, on resume (at most every 30 minutes) and from Settings >
/// App update. The download runs natively (android_native/AppUpdater.kt) in a small foreground service, part by
/// part with HTTP Range, so it keeps going when the user leaves SubMac and continues where it stopped after a lost
/// connection or a failure. State is saved, so a restart shows the same window.
class Updater extends ChangeNotifier {
  Updater._();
  static final Updater I = Updater._();

  static const _ch = MethodChannel('submac/update');
  static const _key = 'app_update_v1';
  static const _snoozeKey = 'app_update_snooze_v1';
  static const _lastRunKey = 'app_update_last_run_code';
  static const _shownKey = 'app_update_whats_new_shown';
  static const resumeEvery = Duration(minutes: 30);

  bool supported = false;
  int? currentCode;
  String currentName = AppConfig.version;
  Release? release;
  final UpdateMachine machine = UpdateMachine();

  /// Later in this run (cleared when SubMac is opened again). The persisted part is [snooze].
  bool dismissed = false;
  Snooze? snooze;
  bool checking = false;
  bool checkFailed = false;
  DateTime? lastCheck;
  DateTime? _fetchedAt;
  bool _pendingInstall = false;
  bool _started = false;
  Timer? _poll;
  Timer? _tick;
  bool _lastForced = false;
  bool _installBusy = false;

  /// Free bytes the last free-space check asked for (for the "free up about X MB" line).
  int neededBytes = 0;

  /// "What's new in X" to show once after updating (null when nothing to show).
  Release? whatsNew;

  /// Set by the UI layer: the notification words in the app's language.
  NativeUpdateWords? words;

  UpdateState get state => machine.state;
  UpdatePhase get phase => machine.state.phase;

  DateTime get now => effectiveNow(serverNow: release?.serverNow, fetchedAt: _fetchedAt, deviceNow: DateTime.now().toUtc());
  bool get forced => release != null && isForced(release!.requiredAt, now);
  bool get pending => release != null && release!.newerThan(currentCode);
  bool get showWindow =>
      shouldShowWindow(release: release, currentCode: currentCode, forced: forced, dismissed: dismissed, snooze: snooze, now: DateTime.now().toUtc());

  /// The real build's version, before anything reports it (touch_device). Safe to call more than once.
  static Future<void> loadBuildVersion() async {
    try {
      final info = await _ch.invokeMapMethod<String, dynamic>('info').timeout(const Duration(seconds: 3));
      final n = buildVersionName(info?['name'], '');
      if (n.isNotEmpty) {
        AppConfig.buildVersion = n;
        I.currentName = n;
      }
    } catch (_) {}
  }

  /// Once per process, right after runApp.
  Future<void> init() async {
    if (_started) return;
    _started = true;
    try {
      final info = await _ch.invokeMapMethod<String, dynamic>('info');
      currentCode = (info?['code'] as num?)?.toInt();
      final n = buildVersionName(info?['name'], '');
      if (n.isNotEmpty) {
        currentName = n;
        AppConfig.buildVersion = n;
      }
      supported = currentCode != null;
    } catch (_) {
      supported = false; // not Android (or tests): no updates
    }
    if (!supported) return;
    _ch.setMethodCallHandler((call) async {
      // The SubMac screen was opened again (the app kept running in the background): a fresh start, so a pending
      // window shows again unless that version is snoozed.
      if (call.method == 'opened') {
        dismissed = false;
        notifyListeners();
        unawaited(resumed(force: true));
      }
      return null;
    });
    await _load();
    await _whatsNewCheck();
    if (release != null && !release!.newerThan(currentCode)) {
      // Updated since last time: remove the files and forget the release.
      await _clearFiles();
      release = null;
      machine.onRelease(null, currentCode);
      await _save();
    }
    notifyListeners();
    await _syncNative();
    unawaited(check());
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      // A deadline passing while the app is open turns the window into the full-screen block.
      if (forced != _lastForced) {
        _lastForced = forced;
        notifyListeners();
      }
    });
  }

  /// From the app's resume hook. Checks the server at most every 30 minutes unless [force].
  Future<void> resumed({bool force = false}) async {
    if (!supported) return;
    machine.onResumed();
    try {
      final info = await _ch.invokeMapMethod<String, dynamic>('info');
      final can = info?['canInstall'] == true;
      final code = (info?['code'] as num?)?.toInt();
      if (code != null) currentCode = code;
      if (_pendingInstall && can) {
        // Back from Android's "Install unknown apps" page with the switch on: carry on installing.
        _pendingInstall = false;
        await _syncNative();
        if (phase == UpdatePhase.downloaded) unawaited(install());
      }
    } catch (_) {}
    await _syncNative();
    notifyListeners();
    final last = lastCheck;
    if (force || last == null || DateTime.now().difference(last) >= resumeEvery) await check();
  }

  /// Asks the server for the newest published release above this build.
  Future<void> check({bool manual = false}) async {
    if (!supported || checking) return;
    checking = true;
    checkFailed = false;
    if (manual) notifyListeners();
    try {
      final r = await Supabase.instance.client.rpc('latest_release', params: {'p_current_code': currentCode ?? 0}).timeout(const Duration(seconds: 15));
      final rel = Release.fromRpc(r);
      lastCheck = DateTime.now();
      _fetchedAt = DateTime.now().toUtc();
      final serverNow = r is Map ? DateTime.tryParse('${r['server_now']}')?.toUtc() : null;
      final cleanup = machine.onRelease(rel, currentCode);
      if (cleanup) await _clearFiles();
      if (rel == null) {
        release = null;
      } else {
        release = Release.fromRpc({...rel.toJson(), 'server_now': (serverNow ?? rel.serverNow)?.toIso8601String()});
      }
      // A newer version clears an old "Later".
      if (snooze != null && (release == null || snooze!.code != release!.versionCode)) {
        snooze = null;
        await _saveSnooze();
      }
      _lastForced = forced;
      await _save();
      await _syncNative();
    } catch (e) {
      checkFailed = true;
      debugPrint('update check failed: $e');
    } finally {
      checking = false;
      notifyListeners();
    }
  }

  /// Download, or continue a stopped/failed download from the bytes already on the phone.
  Future<void> download() async {
    final r = release;
    if (r == null || !supported) return;
    if (phase != UpdatePhase.idle && phase != UpdatePhase.cancelled) return;
    if (state.issue == UpdateIssue.badSignature) return;
    // What is already here, and is there room for the rest (about 2x the APK while the parts are joined)?
    final sizes = r.singleFile ? [r.sizeBytes] : [for (final p in r.parts) p.size];
    var have = <int>[];
    var finished = <bool>[];
    var free = -1;
    try {
      final f = await _ch.invokeMapMethod<String, dynamic>('files', {'code': r.versionCode, 'count': sizes.length});
      have = [for (final x in (f?['have'] as List? ?? const [])) (x as num).toInt()];
      finished = [for (final x in (f?['done'] as List? ?? const [])) x == true];
      free = (f?['free'] as num?)?.toInt() ?? -1;
    } catch (_) {}
    final plan = planResume(expected: sizes, have: have, finished: finished);
    final already = plan.fold<int>(0, (a, p) => a + p.offset);
    if (!hasRoomFor(size: r.sizeBytes, free: free, have: already)) {
      neededBytes = bytesNeeded(size: r.sizeBytes, have: already);
      machine.lowStorage();
      await _save();
      notifyListeners();
      return;
    }
    machine.start();
    notifyListeners();
    try {
      final w = words?.call(r.versionName) ?? const <String, String>{};
      final res = await _ch.invokeMethod<String>('start', {
        'code': r.versionCode,
        'urls': r.urls(AppConfig.supabaseUrl),
        'sizes': sizes,
        'offsets': [for (final p in plan) p.offset],
        'done': [for (final p in plan) p.done],
        'sha256': r.sha256,
        'size': r.sizeBytes,
        'title': w['title'] ?? 'SubMac ${r.versionName}',
        'words': w,
      });
      if (res == 'no_space') {
        // The native check counts the bytes on disk the same way; it only differs when space ran out meanwhile.
        neededBytes = bytesNeeded(size: r.sizeBytes, have: already);
        machine.lowStorage();
      }
    } catch (e) {
      debugPrint('update start failed: $e');
      machine.onNative('failed', reason: 'unknown');
    }
    await _save();
    _watch();
    notifyListeners();
  }

  /// Retry after a stop: same as [download] (it resumes).
  Future<void> retry() => download();

  /// Stops the download. What arrived stays, so Download continues from there.
  Future<void> cancel() async {
    try {
      await _ch.invokeMethod('stop');
    } catch (_) {}
    machine.cancel();
    dismissed = false;
    await _save();
    _watch();
    notifyListeners();
  }

  /// Checks the file (sha256, then the signing certificate against the installed app) and opens the installer.
  Future<void> install() async {
    if (phase != UpdatePhase.downloaded || _installBusy) return;
    _installBusy = true;
    _poll?.cancel();
    _poll = null;
    try {
      machine.install();
      notifyListeners();
      VerifyVerdict v;
      try {
        v = verifyVerdict(await _ch.invokeMapMethod<String, dynamic>('verify'), expectedSha: release?.sha256);
      } catch (_) {
        v = VerifyVerdict.notReady;
      }
      machine.onVerified(v);
      if (v == VerifyVerdict.badHash) await _clearFiles();
      if (v != VerifyVerdict.ok) return;
      notifyListeners();
      String r;
      try {
        r = await _ch.invokeMethod<String>('install') ?? 'not_ready';
      } catch (_) {
        r = 'not_ready';
      }
      machine.onInstallResult(r);
      if (r == 'needs_permission') _pendingInstall = true;
    } finally {
      _installBusy = false;
      await _save();
      notifyListeners();
    }
  }

  /// Opens Android's "Install unknown apps" switch for SubMac; Install continues when the user comes back.
  Future<void> openInstallSettings() async {
    _pendingInstall = true;
    try {
      await _ch.invokeMethod('openInstallSettings');
    } catch (_) {}
  }

  /// Later: hides the window for this version for [snoozeLength] (and until SubMac is opened again when that is
  /// zero). Never for a required update.
  Future<void> later() async {
    final r = release;
    if (forced || r == null) return;
    dismissed = true;
    snooze = snoozeFor(r, DateTime.now().toUtc(), forced: forced);
    notifyListeners();
    await _saveSnooze();
  }

  /// The "What's new" sheet was seen.
  Future<void> whatsNewSeen() async {
    final w = whatsNew;
    whatsNew = null;
    notifyListeners();
    if (w == null) return;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt(_shownKey, w.versionCode);
    } catch (_) {}
  }

  // ---------------- internals ----------------

  Future<void> _whatsNewCheck() async {
    try {
      final p = await SharedPreferences.getInstance();
      final last = p.getInt(_lastRunKey);
      whatsNew = whatsNewToShow(saved: release, currentCode: currentCode, lastRunCode: last, shownCode: p.getInt(_shownKey));
      if (currentCode != null && last != currentCode) await p.setInt(_lastRunKey, currentCode!);
    } catch (_) {}
  }

  Future<void> _syncNative() async {
    if (!supported || state.releaseCode == 0 || _installBusy) return;
    try {
      final s = await _ch.invokeMapMethod<String, dynamic>('status');
      final st = '${s?['state'] ?? 'none'}';
      final code = (s?['code'] as num?)?.toInt() ?? 0;
      if (code != 0 && code != state.releaseCode && st != 'none') {
        // Files of another release: remove them.
        await _clearFiles();
        return;
      }
      final before = phase;
      machine.onNative(
        st,
        bytes: (s?['bytes'] as num?)?.toInt() ?? 0,
        total: (s?['total'] as num?)?.toInt() ?? 0,
        reason: s?['reason'],
        code: (s?['reason_code'] as num?)?.toInt() ?? 0,
        http: (s?['http'] as num?)?.toInt() ?? 0,
      );
      // Back to the window when the download finished or stopped while it was hidden.
      if ((before == UpdatePhase.downloading || before == UpdatePhase.verifying) &&
          (phase == UpdatePhase.downloaded || phase == UpdatePhase.cancelled)) {
        dismissed = false;
      }
      await _save();
    } catch (_) {}
    _watch();
  }

  void _watch() {
    // Poll while the native side downloads, or joins and checks the parts (verifying, outside [install]).
    if (phase == UpdatePhase.downloading || (phase == UpdatePhase.verifying && !_installBusy)) {
      _poll ??= Timer.periodic(const Duration(seconds: 1), (_) async {
        await _syncNative();
        notifyListeners();
      });
    } else {
      _poll?.cancel();
      _poll = null;
    }
  }

  Future<void> _clearFiles() async {
    try {
      await _ch.invokeMethod('cancel');
    } catch (_) {}
  }

  Future<void> _load() async {
    try {
      final p = await SharedPreferences.getInstance();
      snooze = Snooze.fromJson(_json(p.getString(_snoozeKey)));
      final j = _json(p.getString(_key));
      if (j is! Map) return;
      release = Release.fromRpc(j['release']);
      machine.state = UpdateState.fromJson(j['state']);
      final f = DateTime.tryParse('${j['fetched_at']}');
      _fetchedAt = f?.toUtc();
      if (release == null) machine.state = const UpdateState();
      // A check that was interrupted by closing the app: offer Install again (it checks the file first).
      if (machine.state.phase == UpdatePhase.verifying && machine.state.bytes > 0 && machine.state.bytes == machine.state.total) {
        machine.state = machine.state.copyWith(phase: UpdatePhase.downloaded);
      }
    } catch (_) {}
  }

  static dynamic _json(String? raw) {
    if (raw == null) return null;
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  Future<void> _save() async {
    try {
      final p = await SharedPreferences.getInstance();
      if (release == null) {
        await p.remove(_key);
        return;
      }
      await p.setString(_key, jsonEncode({'release': release!.toJson(), 'state': state.toJson(), 'fetched_at': _fetchedAt?.toIso8601String()}));
    } catch (_) {}
  }

  Future<void> _saveSnooze() async {
    try {
      final p = await SharedPreferences.getInstance();
      if (snooze == null) {
        await p.remove(_snoozeKey);
      } else {
        await p.setString(_snoozeKey, jsonEncode(snooze!.toJson()));
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _poll?.cancel();
    _tick?.cancel();
    super.dispose();
  }
}
