#!/usr/bin/env python3
"""Postponed task: make the tree compile. Repair the reachable digital_human services, drop the dead bots-feed
experiment (imported by nothing reachable), and fix its test."""
import io
import os


def sub(path, old, new):
    with io.open(path, encoding='utf-8') as f:
        s = f.read()
    n = s.count(old)
    assert n == 1, path + ' :: expected 1, found ' + str(n) + ' :: ' + repr(old[:60])
    with io.open(path, 'w', encoding='utf-8') as f:
        f.write(s.replace(old, new))


# --- heartbeat.dart
sub('lib/services/digital_human/heartbeat.dart',
    "  Heartbeat({this.idleThreshold = const Duration(minutes: 15)});",
    "  Heartbeat({required this.id, this.idleThreshold = const Duration(minutes: 15)});")
sub('lib/services/digital_human/heartbeat.dart',
    "    if (_asleep) _wake('active');",
    "    if (_asleep) wake('active');")

# --- memory.dart: semantic facts as JSON (SharedPreferences has no getStringMap/setStringMap)
sub('lib/services/digital_human/memory.dart',
    "  Map<String, List<String>> _semantic = {}; // topic -> [facts]",
    "  final Map<String, List<String>> _semantic = {}; // topic -> [facts]")
sub('lib/services/digital_human/memory.dart',
    "    final semRaw = _prefs!.getStringMap(_semKey) ?? {};\n    _semantic.update(_semKey, (v) => v, ifAbsent: () => semRaw);",
    "    final semRaw = _prefs!.getString(_semKey);\n"
    "    if (semRaw != null) {\n"
    "      final m = jsonDecode(semRaw) as Map;\n"
    "      _semantic.clear();\n"
    "      for (final e in m.entries) {\n"
    "        _semantic['${e.key}'] = [for (final x in (e.value as List? ?? const [])) '$x'];\n"
    "      }\n"
    "    }")
sub('lib/services/digital_human/memory.dart',
    "    await _prefs!.setStringMap(_semKey, Map.from(_semantic));",
    "    await _prefs!.setString(_semKey, jsonEncode(_semantic));")

# --- mood.dart: Color comes from dart:ui (no material import); EnergyLevel must init its field
sub('lib/services/digital_human/mood.dart',
    "import 'dart:async';\nimport 'package:flutter/foundation.dart';",
    "import 'dart:async';\nimport 'dart:ui' show Color;\n\nimport 'package:flutter/foundation.dart';")
sub('lib/services/digital_human/mood.dart',
    "  EnergyLevel({this.starting = 1.0});\n\n  double _level;",
    "  EnergyLevel({double starting = 1.0}) : _level = starting.clamp(0.0, 1.0);\n\n  double _level;")

# --- person.dart: build the subsystems at construction so a person works without an async init; drop unused import
sub('lib/services/digital_human/person.dart',
    "import 'dart:async';\nimport 'package:flutter/foundation.dart';\nimport 'package:shared_preferences/shared_preferences.dart';",
    "import 'dart:async';\nimport 'package:shared_preferences/shared_preferences.dart';")
sub('lib/services/digital_human/person.dart',
    "    this.avatarSeed = '',\n    this.personaDescription = '',\n  });",
    "    this.avatarSeed = '',\n    this.personaDescription = '',\n  }) {\n"
    "    heartbeat = Heartbeat(id: id);\n"
    "    awareness = SituationalAwareness(id: id, heartbeat: heartbeat);\n"
    "    memory = LongTermMemory(id: id);\n"
    "    mood = MoodEngine(id: id);\n"
    "  }")
sub('lib/services/digital_human/person.dart',
    "  Future<void> init(SharedPreferences prefs) async {\n"
    "    heartbeat = Heartbeat(id: id);\n"
    "    awareness = SituationalAwareness(id: id, heartbeat: heartbeat);\n"
    "    memory = LongTermMemory(id: id);\n"
    "    mood = MoodEngine(id: id);\n"
    "    createdAt = createdAt ?? DateTime.now();\n"
    "    await memory.init(prefs);\n"
    "    _loadFromPrefs(prefs);\n"
    "  }\n\n"
    "  void _loadFromPrefs(SharedPreferences prefs) {\n"
    "    final raw = prefs.getString('dh_${id}_state');\n"
    "    if (raw == null) return;\n"
    "    try {\n"
    "      final j = {'mood': 'idle', 'energy': 1.0};\n"
    "      // minimal restoration for now\n"
    "    } catch (_) {}\n"
    "  }",
    "  Future<void> init(SharedPreferences prefs) async {\n"
    "    createdAt = createdAt ?? DateTime.now();\n"
    "    await memory.init(prefs);\n"
    "    _loadFromPrefs(prefs);\n"
    "  }\n\n"
    "  void _loadFromPrefs(SharedPreferences prefs) {\n"
    "    final raw = prefs.getString('dh_${id}_state');\n"
    "    if (raw == null) return;\n"
    "    // Mood/energy restoration is added with the bots persistence pass.\n"
    "  }")

# --- registry.dart: drop the unused foundation import
sub('lib/services/digital_human/registry.dart',
    "import 'dart:async';\nimport 'dart:convert';\nimport 'package:flutter/foundation.dart';\nimport 'package:shared_preferences/shared_preferences.dart';",
    "import 'dart:async';\nimport 'dart:convert';\nimport 'package:shared_preferences/shared_preferences.dart';")

# --- digital_human.dart: a library directive so the doc comment is not dangling
sub('lib/services/digital_human/digital_human.dart',
    "/// See docs/digital-human.md for the full vision.\n\nexport 'heartbeat.dart';",
    "/// See docs/digital-human.md for the full vision.\n\nlibrary;\n\nexport 'heartbeat.dart';")

# --- test: Color import and the escaped dollar
sub('test/digital_human_test.dart',
    "import 'package:flutter_test/flutter_test.dart';",
    "import 'dart:ui' show Color;\n\nimport 'package:flutter_test/flutter_test.dart';")
sub('test/digital_human_test.dart',
    r"      mem.remember('message', 'The budget is $500', topic: 'finance');",
    r"      mem.remember('message', 'The budget is \$500', topic: 'finance');")

# --- the dead bots-feed experiment (imported by nothing reachable)
for p in [
    'lib/screens/bots/bot_chat_screen.dart',
    'lib/screens/bots/bot_profile_sheet.dart',
    'lib/screens/bots/bots_feed_screen.dart',
    'lib/widgets/bots/bot_feed_card.dart',
]:
    if os.path.exists(p):
        os.remove(p)

print('postponed-task fixes applied')