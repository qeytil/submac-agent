import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'system_bridge.dart';

enum WakeSetup { off, downloading, paused, unpacking, ready, error }

/// "Hello SubMac": downloads the offline voice pack once (auto-start, pausable),
/// then keeps the listener running in Android.
class WakeWord extends ChangeNotifier {
  WakeWord._();
  static final I = WakeWord._();

  static const modelUrl = 'https://alphacephei.com/vosk/models/vosk-model-small-en-us-0.15.zip';
  static const modelName = 'vosk-model-small-en-us-0.15';

  bool enabled = false;
  double sensitivity = 0.6;
  bool screenOff = true;
  WakeSetup setup = WakeSetup.off;
  int received = 0;
  int total = 0;
  String? error;
  String listenState = 'off';

  late SharedPreferences _p;
  http.Client? _client;
  bool _pauseAsked = false;
  bool _stopAsked = false;

  double get progress => total > 0 ? (received / total).clamp(0.0, 1.0) : 0;

  Future<Directory> _dir() async {
    final d = Directory('${(await getApplicationSupportDirectory()).path}/wake');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<String> _modelDir() async => '${(await _dir()).path}/$modelName';

  Future<bool> modelReady() async => File('${await _modelDir()}/conf/model.conf').exists();

  Future<void> init() async {
    _p = await SharedPreferences.getInstance();
    enabled = _p.getBool('wake.enabled') ?? false;
    sensitivity = _p.getDouble('wake.sens') ?? 0.6;
    screenOff = _p.getBool('wake.screenOff') ?? true;
    SystemBridge.I.onWakeState = (s) {
      listenState = s;
      notifyListeners();
    };
    if (!enabled) return;
    if (await modelReady()) {
      setup = WakeSetup.ready;
      await _startListening();
    } else if (_p.getBool('wake.dlPaused') ?? false) {
      setup = WakeSetup.paused;
      final f = File('${(await _dir()).path}/model.zip.part');
      if (await f.exists()) received = await f.length();
      total = _p.getInt('wake.total') ?? 0;
    } else {
      unawaited(download());
    }
    notifyListeners();
  }

  /// Turning it on starts the download right away (the user can pause or stop it).
  Future<void> setEnabled(bool v) async {
    enabled = v;
    await _p.setBool('wake.enabled', v);
    notifyListeners();
    if (!v) {
      _stopAsked = true;
      _client?.close();
      await SystemBridge.I.wakeStop();
      if (setup != WakeSetup.ready) setup = WakeSetup.off;
      notifyListeners();
      return;
    }
    if (await modelReady()) {
      setup = WakeSetup.ready;
      notifyListeners();
      await _startListening();
    } else {
      unawaited(download());
    }
  }

  Future<void> setSensitivity(double v) async {
    sensitivity = v;
    await _p.setDouble('wake.sens', v);
    await SystemBridge.I.wakeSensitivity(v);
    notifyListeners();
  }

  Future<void> setScreenOff(bool v) async {
    screenOff = v;
    await _p.setBool('wake.screenOff', v);
    notifyListeners();
    if (enabled && setup == WakeSetup.ready) {
      await SystemBridge.I.wakeStop();
      await _startListening();
    }
  }

  Future<void> _startListening() async {
    await SystemBridge.I.wakeStart(await _modelDir(), sensitivity, screenOff: screenOff);
  }

  void pauseDownload() {
    if (setup != WakeSetup.downloading) return;
    _pauseAsked = true;
    _client?.close();
  }

  /// Stops and deletes the partial download; the feature stays off until turned on again.
  Future<void> stopDownload() async {
    _stopAsked = true;
    _client?.close();
    try {
      final f = File('${(await _dir()).path}/model.zip.part');
      if (await f.exists()) await f.delete();
    } catch (_) {}
    received = 0;
    total = 0;
    setup = WakeSetup.off;
    enabled = false;
    await _p.setBool('wake.enabled', false);
    await _p.setBool('wake.dlPaused', false);
    notifyListeners();
  }

  /// Downloads (resuming where it stopped), unpacks, then starts listening.
  Future<void> download() async {
    if (setup == WakeSetup.downloading || setup == WakeSetup.unpacking) return;
    _pauseAsked = false;
    _stopAsked = false;
    error = null;
    setup = WakeSetup.downloading;
    await _p.setBool('wake.dlPaused', false);
    notifyListeners();
    final dir = await _dir();
    final part = File('${dir.path}/model.zip.part');
    var tries = 0;
    while (true) {
      final client = http.Client();
      _client = client;
      try {
        final have = await part.exists() ? await part.length() : 0;
        final req = http.Request('GET', Uri.parse(modelUrl));
        if (have > 0) req.headers['Range'] = 'bytes=$have-';
        final res = await client.send(req).timeout(const Duration(seconds: 30));
        if (res.statusCode != 200 && res.statusCode != 206) throw HttpException('HTTP ${res.statusCode}');
        final resumed = res.statusCode == 206;
        received = resumed ? have : 0;
        total = (res.contentLength ?? 0) + (resumed ? have : 0);
        await _p.setInt('wake.total', total);
        final sink = part.openWrite(mode: resumed ? FileMode.append : FileMode.write);
        var lastNotify = DateTime.now();
        try {
          await for (final chunk in res.stream) {
            sink.add(chunk);
            received += chunk.length;
            if (DateTime.now().difference(lastNotify).inMilliseconds > 250) {
              lastNotify = DateTime.now();
              notifyListeners();
            }
          }
        } finally {
          await sink.close();
        }
        client.close();
        break;
      } catch (e) {
        client.close();
        if (_stopAsked) return;
        if (_pauseAsked) {
          setup = WakeSetup.paused;
          await _p.setBool('wake.dlPaused', true);
          notifyListeners();
          return;
        }
        // Flaky network: wait and resume from where it stopped.
        if (++tries > 6) {
          setup = WakeSetup.error;
          error = 'The voice pack download keeps failing. Check your connection and tap Resume.';
          await _p.setBool('wake.dlPaused', true);
          notifyListeners();
          return;
        }
        await Future.delayed(Duration(seconds: 2 * tries));
        if (_stopAsked || _pauseAsked) {
          if (_pauseAsked) {
            setup = WakeSetup.paused;
            await _p.setBool('wake.dlPaused', true);
            notifyListeners();
          }
          return;
        }
      }
    }
    // Unpack
    setup = WakeSetup.unpacking;
    notifyListeners();
    try {
      final zip = File('${dir.path}/model.zip');
      if (await zip.exists()) await zip.delete();
      await part.rename(zip.path);
      await SystemBridge.I.unzip(zip.path, dir.path);
      await zip.delete();
      if (!await modelReady()) throw StateError('the voice pack looks incomplete');
      setup = WakeSetup.ready;
      notifyListeners();
      if (enabled) await _startListening();
    } catch (e) {
      setup = WakeSetup.error;
      error = 'The voice pack didn\'t unpack. Turn Hello SubMac off and on to try again.';
      notifyListeners();
    }
  }

  /// Live started: give it the mic. Live ended: start listening again.
  Future<void> liveStarted() => SystemBridge.I.wakePause();
  Future<void> liveEnded() async {
    if (enabled && setup == WakeSetup.ready) await SystemBridge.I.wakeResume();
  }

  String get statusLine {
    switch (setup) {
      case WakeSetup.off:
        return 'Off';
      case WakeSetup.downloading:
        return total > 0
            ? 'Getting the voice pack… ${(progress * 100).round()}% of ${(total / 1048576).toStringAsFixed(0)} MB'
            : 'Getting the voice pack…';
      case WakeSetup.paused:
        return 'Paused at ${(progress * 100).round()}%';
      case WakeSetup.unpacking:
        return 'Almost ready…';
      case WakeSetup.error:
        return error ?? 'Something went wrong';
      case WakeSetup.ready:
        if (!enabled) return 'Ready (off)';
        switch (listenState) {
          case 'listening':
            return 'Listening for “Hello SubMac”';
          case 'paused':
            return 'Paused while Live is on';
          case 'call':
            return 'Paused during your call';
          case 'mic_busy':
            return 'Waiting for the mic (another app is using it)';
          case 'needs_tap':
            return 'Android paused it. Turn it off and on again.';
          case 'loading':
            return 'Starting…';
          case 'retrying':
            return 'Restarting the mic…';
          default:
            return 'On';
        }
    }
  }
}
