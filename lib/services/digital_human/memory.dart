import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'heartbeat.dart';
export 'heartbeat.dart';

/// Long-term memory for one digital person (owner 2026-11).
///
/// Not just chat logs. Three layers:
///
/// * **Episodic** — what happened (past conversations, events, tasks completed).
/// * **Semantic** — facts about the user, their preferences, their world.
/// * **Reflective** — what we learned today, patterns we noticed, things to remember tomorrow.
///
/// Memories are associative: you can recall by topic, by time, or by feeling.
class LongTermMemory {
  LongTermMemory({required this.id, this.maxEntries = 200});

  final String id;
  final int maxEntries;

  List<_MemoryEntry> _episodes = [];
  Map<String, List<String>> _semantic = {}; // topic -> [facts]
  List<String> _reflections = [];

  SharedPreferences? _prefs;

  Future<void> init(SharedPreferences prefs) async {
    _prefs = prefs;
    await _load();
  }

  Future<void> _load() async {
    if (_prefs == null) return;
    final raw = _prefs!.getString(_memKey);
    if (raw == null) return;
    try {
      final list = jsonDecode(raw) as List;
      _episodes = list.map((e) => _MemoryEntry.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {}
    final semRaw = _prefs!.getString(_semKey);
    if (semRaw != null) {
      try {
        final m = jsonDecode(semRaw) as Map<String, dynamic>;
        _semantic = m.map((k, v) => MapEntry(k, List<String>.from(v as List)));
      } catch (_) {}
    }
    final refRaw = _prefs!.getString(_refKey);
    if (refRaw != null) {
      _reflections = List<String>.from(jsonDecode(refRaw) as List);
    }
  }

  Future<void> save() async {
    if (_prefs == null) return;
    await _prefs!.setString(_memKey, jsonEncode(_episodes.map((e) => e.toJson()).toList()));
    await _prefs!.setString(_semKey, jsonEncode(_semantic));
    await _prefs!.setString(_refKey, jsonEncode(_reflections));
  }

  static const _memKey = 'dh_memory_episodes';
  static const _semKey = 'dh_memory_semantic';
  static const _refKey = 'dh_memory_reflections';

  /// Remember an episode: a message exchanged, a task done, something observed.
  void remember(String type, String content, {String topic = ''}) {
    _episodes.insert(0, _MemoryEntry(type: type, content: content, topic: topic));
    if (_episodes.length > maxEntries) _episodes.removeLast();
  }

  /// Store a fact about the user or the world.
  void learn(String topic, String fact) {
    _semantic.putIfAbsent(topic, () => []).add(fact);
    if (_semantic[topic]!.length > 50) _semantic[topic]!.removeAt(0);
  }

  /// Free-form reflection: overnight journaling, pattern detection results.
  void reflect(String thought) {
    _reflections.insert(0, thought);
    if (_reflections.length > 30) _reflections.removeLast();
  }

  /// Recall memories associated with a topic.
  List<String> recall(String topic) {
    final results = <String>[];
    for (final e in _episodes) {
      if (e.topic.toLowerCase().contains(topic.toLowerCase()) ||
          e.content.toLowerCase().contains(topic.toLowerCase())) {
        results.add(e.content);
      }
    }
    results.addAll(_semantic[topic.toLowerCase()] ?? []);
    return results.take(10).toList();
  }

  /// Recent episodes for the profile view.
  List<Map<String, dynamic>> recentEpisodes([int n = 5]) =>
      _episodes.take(n).map((e) => e.toJson()).toList();

  int get episodeCount => _episodes.length;
  int get factCount => _semantic.values.fold(0, (s, l) => s + l.length);
  int get reflectionCount => _reflections.length;

  Future<void> clear() async {
    _episodes.clear();
    _semantic.clear();
    _reflections.clear();
    await save();
  }
}

class _MemoryEntry {
  _MemoryEntry({required this.type, required this.content, this.topic = '', DateTime? at})
      : at = at ?? DateTime.now();

  final String type; // 'message', 'task', 'observation', 'reflection'
  final String content;
  final String topic;
  final DateTime at;

  Map<String, dynamic> toJson() => {
        'type': type,
        'content': content,
        'topic': topic,
        'at': at.toIso8601String(),
      };

  static _MemoryEntry fromJson(Map<String, dynamic> j) => _MemoryEntry(
        type: '${j['type'] ?? 'observation'}',
        content: '${j['content'] ?? ''}',
        topic: '${j['topic'] ?? ''}',
        at: DateTime.tryParse('${j['at']}') ?? DateTime.now(),
      );
}
