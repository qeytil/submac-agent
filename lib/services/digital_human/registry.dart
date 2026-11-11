/// Registry of all digital persons in the system (owner 2026-11).
///
/// Keeps a map from bot id to [DigitalPerson], creates them lazily, persists
/// their lifecycles across app restarts. Initialized from the existing Bot
/// store so every existing bot gets a living personality layer.
library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'person.dart';

class DigitalHumanRegistry {
  DigitalHumanRegistry._();
  static final DigitalHumanRegistry I = DigitalHumanRegistry._();

  final Map<String, DigitalPerson> _byId = {};
  SharedPreferences? _prefs;

  /// Call once during app startup after LocalStore.init() has run.
  Future<void> init(SharedPreferences prefs) async {
    _prefs = prefs;
    await _loadFromPrefs();
  }

  SharedPreferences? get prefs => _prefs;

  /// Get or create a person. Not thread-safe — called from the main isolate only.
  DigitalPerson byId(String id) => _byId.putIfAbsent(id, () => DigitalPerson(id: id, name: id));

  /// Register a fully defined person (from config or store).
  void register(DigitalPerson person) {
    _byId[person.id] = person;
  }

  /// All registered people, sorted by last-spoken descending so recent activity leads.
  List<DigitalPerson> get all {
    final list = _byId.values.toList();
    list.sort((a, b) {
      final atA = a.lastSpokeAt?.millisecondsSinceEpoch ?? 0;
      final atB = b.lastSpokeAt?.millisecondsSinceEpoch ?? 0;
      return atB.compareTo(atA);
    });
    return list;
  }

  /// How many are currently active (heartbeating, watching).
  int get activeCount => _byId.values.where((p) => p.isActive).length;

  /// Create digital persons from saved state. Called once at startup.
  Future<void> bootstrapFromPrefs() async {
    if (_prefs == null) return;
    final raw = _prefs!.getString('dh_persons');
    if (raw == null) return;
    try {
      final list = jsonDecode(raw) as List;
      for (final entry in list) {
        final j = entry as Map<String, dynamic>;
        final id = '${j['id']}';
        final person = DigitalPerson(
          id: id,
          name: '${j['name'] ?? id}',
          role: '${j['role'] ?? ''}',
          avatarSeed: '${j['avatarSeed'] ?? ''}',
          personaDescription: '${j['persona'] ?? ''}',
        );
        _byId[id] = person;
      }
    } catch (_) {}
  }

  /// Persist all registered persons to SharedPreferences.
  Future<void> save() async {
    if (_prefs == null) return;
    final list = _byId.values.map((p) => <String, dynamic>{
      'id': p.id,
      'name': p.name,
      'role': p.role,
      'avatarSeed': p.avatarSeed,
      'persona': p.personaDescription,
    }).toList();
    await _prefs!.setString('dh_persons', const JsonEncoder.withIndent('  ').convert(list));
  }

  Future<void> _loadFromPrefs() async {
    if (_prefs == null) return;
    await bootstrapFromPrefs();
  }

  /// Wake everyone up (app launch, after prefs are ready).
  Future<void> wakeAll() async {
    for (final p in _byId.values) {
      if (!p.isActive && _prefs != null) {
        await p.init(_prefs!);
        p.wakeUp();
      }
    }
  }

  /// Sleep everyone down (app close/pause).
  Future<void> sleepAll() async {
    for (final p in _byId.values) {
      if (p.isActive) {
        await p.save(_prefs!);
        p.sleepDown();
      }
    }
    await save(); // persist registry itself
  }

  void clear() => _byId.clear();
}
