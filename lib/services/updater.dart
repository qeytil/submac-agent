import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';
import 'update_logic.dart';

export 'update_logic.dart';

/// In-app updates (branch feature/app-update). Checks `latest_release` on cold start, on resume (at most every
/// 30 minutes) and from Settings > App update. The download itself runs in Android's DownloadManager
/// (android_native/AppUpdater.kt), so it keeps going when the user leaves SubMac. State is saved, so a restart
/// shows the same window: progress, or Install straight away when the file is already here.
class Updater extends ChangeNotifier {
  Updater._();
  static final Updater I = Updater._();

  static const _ch = MethodChannel('submac/update');
  static const _key = 'app_update_v1';
  static const resumeEvery = Duration(minutes: 30);

  bool supported = false;
  int? currentCode;
  String currentName = AppConfig.version;
  Release? release;
  final UpdateMachine machine = UpdateMachine();
  bool dismissed = false;
  bool checking = false;
  bool checkFailed = false;
  DateTime? lastCheck;
  DateTime? _fetchedAt;
  bool _pendingInstall = false;
  bool _started = false;
  Timer? _poll;
  Timer? _tick;
  bool _lastForced = false;

  UpdateState get state => machine.state;
  UpdatePhase get phase => machine.state.phase;

  DateTime get now => effectiveNow(serverNow: release?.serverNow, fetchedAt: _fetchedAt, deviceNow: DateTime.now().toUtc());
  bool get forced => release != null && isForced(release!.requiredAt, now);
  bool get pending => release != null && release!.newerThan(currentCode);
  bool get showWindow => shouldShowWindow(release: release, currentCode: currentCode, forced: forced, dismissed: dismissed);

  /// Once per process, right after runApp.
  Future<void> init() async {
    if (_started) return;
    _started = true;
    try {
      final info = await _ch.invokeMapMethod<String, dynamic>('info');
      currentCode = (info?['code'] as num?)?.toInt();
      final n = info?['name'];
      if (n is String && n.isNotEmpty) currentName = n;
      supported = currentCode != null;
    } catch (_) {
      supported = false; // not Android (or tests): no updates
    }
    if (!supported) return;
    _ch.setMethodCallHandler((call) async {
      // The SubMac screen was opened again (the app kept running in the background): show the window again.
      if (call.method == 'opened') {
        dismissed = false;
        notifyListeners();
        unawaited(resumed(force: true));
      }
      return null;
    });
    await _load();
    if (release != null && !release!.newerThan(currentCode)) {
      // Updated since last time: remove the file and forget the release.
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

  Future<void> download() async {
    final r = release;
    if (r == null || !supported) return;
    if (phase != UpdatePhase.idle && phase != UpdatePhase.cancelled) return;
    machine.start();
    notifyListeners();
    try {
      await _ch.invokeMethod('start', {
        'code': r.versionCode,
        'urls': r.urls(AppConfig.supabaseUrl),
        'sha256': r.sha256,
        'size': r.sizeBytes,
        'title': 'Telesia ${r.versionName}',
      });
    } catch (e) {
      debugPrint('update start failed: $e');
      machine.onNative('failed');
    }
    await _save();
    _watch();
    notifyListeners();
  }

  /// Stops the download. The window comes back so the user can download again any time.
  Future<void> cancel() async {
    try {
      await _ch.invokeMethod('cancel');
    } catch (_) {}
    machine.cancel();
    dismissed = false;
    await _save();
    _watch();
    notifyListeners();
  }

  Future<void> install() async {
    if (phase != UpdatePhase.downloaded) return;
    machine.install();
    notifyListeners();
    String r;
    try {
      r = await _ch.invokeMethod<String>('install') ?? 'not_ready';
    } catch (_) {
      r = 'not_ready';
    }
    machine.onInstallResult(r);
    if (r == 'needs_permission') _pendingInstall = true;
    await _save();
    notifyListeners();
  }

  /// Opens Android's "Install unknown apps" switch for SubMac; Install continues when the user comes back.
  Future<void> openInstallSettings() async {
    _pendingInstall = true;
    try {
      await _ch.invokeMethod('openInstallSettings');
    } catch (_) {}
  }

  /// Later: hides the window until the next start (never for a required update).
  void later() {
    if (forced) return;
    dismissed = true;
    notifyListeners();
  }

  // ---------------- internals ----------------

  Future<void> _syncNative() async {
    if (!supported || state.releaseCode == 0) return;
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
      machine.onNative(st, bytes: (s?['bytes'] as num?)?.toInt() ?? 0, total: (s?['total'] as num?)?.toInt() ?? 0);
      // Back to the window when the download finished or stopped while it was hidden.
      if (before == UpdatePhase.downloading && (phase == UpdatePhase.downloaded || phase == UpdatePhase.cancelled)) dismissed = false;
      await _save();
    } catch (_) {}
    _watch();
  }

  void _watch() {
    if (phase == UpdatePhase.downloading) {
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
      final raw = p.getString(_key);
      if (raw == null) return;
      final j = jsonDecode(raw);
      if (j is! Map) return;
      release = Release.fromRpc(j['release']);
      machine.state = UpdateState.fromJson(j['state']);
      final f = DateTime.tryParse('${j['fetched_at']}');
      _fetchedAt = f?.toUtc();
      if (release == null) machine.state = const UpdateState();
    } catch (_) {}
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

  @override
  void dispose() {
    _poll?.cancel();
    _tick?.cancel();
    super.dispose();
  }
}
