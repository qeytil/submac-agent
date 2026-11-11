import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'heartbeat.dart';
import 'awareness.dart';
import 'memory.dart';
import 'mood.dart';

/// One digital person — alive, aware, remembering, feeling (owner 2026-11).
///
/// A [DigitalPerson] is not a function you call. It is a colleague who lives in
/// the app, runs its own heartbeat, watches the world, remembers what matters,
/// and speaks when something is worth saying. The user talks to it in chat;
/// the person also talks to itself (and others) when no one is prompting.
class DigitalPerson {
  DigitalPerson({
    required this.id,
    required this.name,
    this.role = '',
    this.avatarSeed = '',
    this.personaDescription = '',
  });

  // --- Identity ---
  final String id;
  final String name;
  final String role;
  final String avatarSeed;
  final String personaDescription;

  // --- Life subsystems ---
  late final Heartbeat heartbeat;
  late final SituationalAwareness awareness;
  late final LongTermMemory memory;
  late final MoodEngine mood;
  late final EnergyLevel energy = EnergyLevel();

  // --- Active state ---
  bool _active = false;
  bool get isActive => _active;
  DateTime? createdAt;
  DateTime? lastSpokeAt;

  // --- Computed presence ---
  /// What the world sees: online, thinking, working, offline.
  PresenceState get presence {
    if (!_active) return PresenceState.offline;
    if (heartbeat.isAlive && mood.mood != BotMood.idle) {
      if (mood.mood == BotMood.focused) return PresenceState.working;
      if (mood.mood == BotMood.curious) return PresenceState.thinking;
      return PresenceState.online;
    }
    return PresenceState.online;
  }

  /// Initialize all subsystems. Call once at app start.
  Future<void> init(SharedPreferences prefs) async {
    heartbeat = Heartbeat(id: id);
    awareness = SituationalAwareness(id: id, heartbeat: heartbeat);
    memory = LongTermMemory(id: id);
    mood = MoodEngine(id: id);
    createdAt = createdAt ?? DateTime.now();
    await memory.init(prefs);
    _loadFromPrefs(prefs);
  }

  void _loadFromPrefs(SharedPreferences prefs) {
    final raw = prefs.getString('dh_${id}_state');
    if (raw == null) return;
    try {
      final j = {'mood': 'idle', 'energy': 1.0};
      // minimal restoration for now
    } catch (_) {}
  }

  Future<void> save(SharedPreferences prefs) async {
    await memory.save();
  }

  /// Mark that we just said or did something.
  void markSpoken() {
    lastSpokeAt = DateTime.now();
    heartbeat.markActive();
    energy.spend(0.05);
  }

  /// Start the person running (watching, ticking).
  void wakeUp() {
    _active = true;
    heartbeat.start();
    awareness.start();
    mood.start();
  }

  /// Stop the person (app closing, user disabled).
  void sleepDown() {
    _active = false;
    heartbeat.stop();
    awareness.stop();
    mood.stop();
  }

  Map<String, dynamic> snapshot() => {
        'id': id,
        'name': name,
        'role': role,
        'active': _active,
        'presence': presence.name,
        'mood': mood.mood.name,
        'moodIntensity': mood.intensity,
        'energy': energy.level,
        'idleMin': heartbeat.idleTime.inMinutes,
        'memoryEpisodes': memory.episodeCount,
        'lastSpokenAt': lastSpokeAt?.toIso8601String(),
      };
}

/// What other people see when they look at a bot's status dot.
enum PresenceState {
  offline, // not running
  online,  // awake, idle
  thinking, // curious, exploring
  working, // focused on a task
}
