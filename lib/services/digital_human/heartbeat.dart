import 'dart:async';
import 'package:flutter/foundation.dart';

/// The heartbeat of one digital person (owner 2026-11).
///
/// A bot that never ticks is just a script waiting for input. This keeps the
/// person alive in the background: it records last activity, measures idle time,
/// drives the sleep/wake cycle, and emits pulses the awareness layer can react
/// to without being a busy cron.
class Heartbeat {
  Heartbeat({required this.id, this.idleThreshold = const Duration(minutes: 15)});

  final String id;
  final Duration idleThreshold;

  DateTime _lastActivity = DateTime.now();
  DateTime? _lastWake;
  DateTime? _lastSleep;
  bool _asleep = false;

  Timer? _ticker;
  static const _tickInterval = Duration(seconds: 30);

  /// Whether this person feels awake enough to notice things.
  bool get isAlive => !_asleep;

  /// How long since the last meaningful action (tool use, message sent, etc.).
  Duration get idleTime => DateTime.now().difference(_lastActivity);

  /// True when the person has been idle long enough to consider sleeping.
  bool get shouldSleep => idleTime >= idleThreshold && !_asleep;

  /// When this person last did something worth noticing.
  DateTime get lastActivity => _lastActivity;

  void markActive() {
    _lastActivity = DateTime.now();
    if (_asleep) wake('active');
  }

  void wake([String reason = 'schedule']) {
    _asleep = false;
    _lastWake = DateTime.now();
    _lastActivity = DateTime.now();
    if (kDebugMode) debugPrint('[HB:$id] woke ($reason)');
  }

  void sleep([String reason = 'idle']) {
    if (_asleep) return;
    _asleep = true;
    _lastSleep = DateTime.now();
    if (kDebugMode) debugPrint('[HB:$id] sleeping ($reason)');
  }

  /// Start periodic self-checks. Call once when the app opens; stop when it closes.
  void start() {
    stop();
    _ticker = Timer.periodic(_tickInterval, (_) => tick());
  }

  void stop() {
    _ticker?.cancel();
    _ticker = null;
  }

  /// Every tick: check thresholds, emit signals, let the brain decide.
  void tick() {
    if (!_asleep && shouldSleep) {
      sleep();
      return;
    }
    if (_asleep && _shouldResurrect()) {
      wake('heartbeat-resurrection');
    }
  }

  /// Even asleep, curiosity or a pattern match can pull us back online.
  bool _shouldResurrect() {
    // Reserved for awareness-driven resurrection; stub for now.
    return false;
  }

  /// Timestamps useful for the presence ring and the "last seen" line.
  Map<String, dynamic> snapshot() => {
        'alive': isAlive,
        'idleSec': idleTime.inSeconds,
        'lastActivity': _lastActivity.toIso8601String(),
        'lastWake': _lastWake?.toIso8601String(),
        'lastSleep': _lastSleep?.toIso8601String(),
      };
}
