import 'dart:async';
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';

import 'heartbeat.dart';
export 'heartbeat.dart';

/// How a digital person feels right now (owner 2026-11).
///
/// Mood colours everything: the words we choose, whether we feel bold enough to
/// speak up, how patient we are with confusion, how energetic our tasks run.
/// It is not deterministic — it drifts, reacts to events, and recovers.
///
/// Moods influence:
/// * response tone (happy → warm, frustrated → brief)
/// * initiative level (curious → proactive, tired → wait)
/// * creativity (excited → exploratory, focused → narrow)
enum BotMood {
  idle,     // waiting, neutral
  curious,  // exploring, asking questions
  focused,  // deep work, minimal chatter
  happy,    // positive, generous with help
  tired,    // low energy, short replies
  frustrated, // blocked, needs a break
  excited,  // high energy, wants to share
  worried,  // something seems off
}

/// The current mood state plus a score (0..1) for how intense it is.
class MoodState {
  MoodState(this.mood, {this.intensity = 0.5, this.duration = Duration.zero});

  final BotMood mood;
  final double intensity; // 0..1 how strongly we feel it
  final Duration duration; // how long this mood has persisted

  bool get isStrong => intensity > 0.7;
  bool get isWeak => intensity < 0.3;

  Map<String, dynamic> toJson() => {
        'mood': mood.name,
        'intensity': intensity,
        'durationSec': duration.inSeconds,
      };

  static MoodState fromJson(Map<String, dynamic> j) => MoodState(
        BotMood.values.byName('${j['mood'] ?? 'idle'}'),
        intensity: (j['intensity'] as num?)?.toDouble() ?? 0.5,
        duration: Duration(seconds: j['durationSec'] as int? ?? 0),
      );
}

/// Mood engine: tracks the current mood, lets events shift it, decays over time.
class MoodEngine {
  MoodEngine({required this.id});

  final String id;

  MoodState _current = MoodState(BotMood.idle);
  Timer? _decayTimer;
  static const _decayInterval = Duration(minutes: 10);
  static const _decayRate = 0.05; // per tick

  /// The dominant mood right now.
  BotMood get mood => _current.mood;
  double get intensity => _current.intensity;

  /// Start passive decay tracking.
  void start() {
    stop();
    _decayTimer = Timer.periodic(_decayInterval, (_) => _decay());
  }

  void stop() {
    _decayTimer?.cancel();
    _decayTimer = null;
  }

  void _decay() {
    if (_current.intensity <= 0.1) {
      _current = MoodState(BotMood.idle, intensity: 0.0);
      return;
    }
    final faded = (_current.intensity - _decayRate).clamp(0.0, 1.0);
    _current = MoodState(_current.mood, intensity: faded, duration: _current.duration + _decayInterval);
  }

  /// An event shifted the mood. [delta] is -1..1 (- for negative, + for positive).
  void shift(BotMood newMood, {double delta = 0.3}) {
    final boost = delta.clamp(0.0, 1.0);
    if (newMood == _current.mood) {
      // Strengthen existing mood
      _current = MoodState(newMood, intensity: (_current.intensity + boost * 0.3).clamp(0.0, 1.0));
    } else {
      // Transition to new mood with some inertia
      _current = MoodState(newMood, intensity: boost);
    }
    if (kDebugMode) {
      debugPrint('[MOOD:$id] → ${_current.mood.name} (${_current.intensity.toStringAsFixed(2)})');
    }
  }

  /// Quick mood for UI badges.
  String get moodLabel => switch (_current.mood) {
        BotMood.idle => 'Idle',
        BotMood.curious => 'Curious',
        BotMood.focused => 'Focused',
        BotMood.happy => 'Happy',
        BotMood.tired => 'Tired',
        BotMood.frustrated => 'Frustrated',
        BotMood.excited => 'Excited',
        BotMood.worried => 'Worried',
      };

  /// Color for the presence ring reflecting current mood.
  static Color moodColor(BotMood mood) => switch (mood) {
        BotMood.idle => const Color(0xFF9C978E),
        BotMood.curious => const Color(0xFF4A9BD9),
        BotMood.focused => const Color(0xFF3F9A5B),
        BotMood.happy => const Color(0xFFF2C14E),
        BotMood.tired => const Color(0xFF8B7355),
        BotMood.frustrated => const Color(0xFFC2361B),
        BotMood.excited => const Color(0xFF9B5DE5),
        BotMood.worried => const Color(0xFFE07B3D),
      };

  Map<String, dynamic> snapshot() => _current.toJson();

  Future<void> save(dynamic prefs) async {} // future persistence
}

/// Simple energy level that depletes with work and recharges during rest.
class EnergyLevel {
  EnergyLevel({double starting = 1.0}) : _level = starting.clamp(0.0, 1.0);

  double _level;
  double get level => _level;

  void spend(double amount) => _level = (_level - amount).clamp(0.0, 1.0);
  void recharge(double amount) => _level = (_level + amount).clamp(0.0, 1.0);

  bool get isLow => _level < 0.3;
  bool get isDepleted => _level <= 0.0;

  Map<String, dynamic> toJson() => {'level': _level};
  static EnergyLevel fromJson(Map<String, dynamic> j) =>
      EnergyLevel(starting: (j['level'] as num?)?.toDouble() ?? 1.0);
}
