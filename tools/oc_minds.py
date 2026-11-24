#!/usr/bin/env python3
"""Bots as digital humans (workstream A): give every bot a DigitalPerson with persisted mood/energy/memory and a
self-line in its prompt. New files are committed separately; this script only edits existing files."""
import io


def sub(path, old, new):
    with io.open(path, encoding='utf-8') as f:
        s = f.read()
    n = s.count(old)
    assert n == 1, path + ' :: expected 1, found ' + str(n) + ' :: ' + repr(old[:60])
    with io.open(path, 'w', encoding='utf-8') as f:
        f.write(s.replace(old, new))


# registry.dart: ensure() creates a person with a real name/role
sub('lib/services/digital_human/registry.dart',
    "  /// Get or create a person. Not thread-safe — called from the main isolate only.\n"
    "  DigitalPerson byId(String id) => _byId.putIfAbsent(id, () => DigitalPerson(id: id, name: id));",
    "  /// Get or create a person. Not thread-safe — called from the main isolate only.\n"
    "  DigitalPerson byId(String id) => _byId.putIfAbsent(id, () => DigitalPerson(id: id, name: id));\n\n"
    "  /// Get the person for [id], creating it with the nicer [name]/[role] when it is not there yet (a bot knows its own\n"
    "  /// name; the lazy [byId] would call it by its id).\n"
    "  DigitalPerson ensure(String id, {String name = '', String role = ''}) {\n"
    "    final existing = _byId[id];\n"
    "    if (existing != null) return existing;\n"
    "    final p = DigitalPerson(id: id, name: name.trim().isEmpty ? id : name.trim(), role: role);\n"
    "    _byId[id] = p;\n"
    "    return p;\n"
    "  }")

# person.dart: persist and restore mood/energy/lastSpoke/createdAt
sub('lib/services/digital_human/person.dart',
    "import 'dart:async';\nimport 'package:shared_preferences/shared_preferences.dart';",
    "import 'dart:async';\nimport 'dart:convert';\nimport 'package:shared_preferences/shared_preferences.dart';")
sub('lib/services/digital_human/person.dart',
    "  void _loadFromPrefs(SharedPreferences prefs) {\n"
    "    final raw = prefs.getString('dh_${id}_state');\n"
    "    if (raw == null) return;\n"
    "    // Mood/energy restoration is added with the bots persistence pass.\n"
    "  }",
    "  void _loadFromPrefs(SharedPreferences prefs) {\n"
    "    final raw = prefs.getString('dh_${id}_state');\n"
    "    if (raw == null) return;\n"
    "    try {\n"
    "      final j = jsonDecode(raw) as Map;\n"
    "      final e = (j['energy'] as num?)?.toDouble();\n"
    "      if (e != null) energy.set(e);\n"
    "      final m = '${j['mood'] ?? ''}';\n"
    "      if (m.isNotEmpty) mood.restore(m, (j['moodIntensity'] as num?)?.toDouble() ?? 0.5);\n"
    "      final ls = DateTime.tryParse('${j['lastSpokeAt'] ?? ''}');\n"
    "      if (ls != null) lastSpokeAt = ls;\n"
    "      final ca = DateTime.tryParse('${j['createdAt'] ?? ''}');\n"
    "      if (ca != null) createdAt = ca;\n"
    "    } catch (_) {}\n"
    "  }")
sub('lib/services/digital_human/person.dart',
    "  Future<void> save(SharedPreferences prefs) async {\n    await memory.save();\n  }",
    "  Future<void> save(SharedPreferences prefs) async {\n"
    "    await memory.save();\n"
    "    try {\n"
    "      await prefs.setString('dh_${id}_state', jsonEncode({\n"
    "        'mood': mood.mood.name,\n"
    "        'moodIntensity': mood.intensity,\n"
    "        'energy': energy.level,\n"
    "        'lastSpokeAt': lastSpokeAt?.toIso8601String(),\n"
    "        'createdAt': createdAt?.toIso8601String(),\n"
    "      }));\n"
    "    } catch (_) {}\n"
    "  }")

# mood.dart: restore a mood; set energy
sub('lib/services/digital_human/mood.dart',
    "  Map<String, dynamic> snapshot() => _current.toJson();",
    "  /// Restore a saved mood (the bots' persistence pass): the matching mood with its intensity.\n"
    "  void restore(String moodName, double intensity) {\n"
    "    for (final m in BotMood.values) {\n"
    "      if (m.name == moodName) {\n"
    "        _current = MoodState(m, intensity: intensity.clamp(0.0, 1.0));\n"
    "        return;\n"
    "      }\n"
    "    }\n"
    "  }\n\n"
    "  Map<String, dynamic> snapshot() => _current.toJson();")
sub('lib/services/digital_human/mood.dart',
    "  void spend(double amount) => _level = (_level - amount).clamp(0.0, 1.0);\n"
    "  void recharge(double amount) => _level = (_level + amount).clamp(0.0, 1.0);",
    "  void spend(double amount) => _level = (_level - amount).clamp(0.0, 1.0);\n"
    "  void recharge(double amount) => _level = (_level + amount).clamp(0.0, 1.0);\n"
    "  void set(double v) => _level = v.clamp(0.0, 1.0);")

# bots.dart: the bot's own prompt carries its self-line
sub('lib/services/bots.dart',
    "import 'no_reply.dart';\nimport 'house_rules.dart';",
    "import 'no_reply.dart';\nimport 'house_rules.dart';\nimport 'digital_human/bot_minds.dart';")
sub('lib/services/bots.dart',
    "            'Your own folder for notes, drafts and files: ${botFolder(b)}/ (relative to your working directory). Keep long work there.\\n\\n'\n"
    "            'Your name is ${b.name}. Never say you are an AI model or Telesia; you are ${b.name}.'",
    "            'Your own folder for notes, drafts and files: ${botFolder(b)}/ (relative to your working directory). Keep long work there.\\n\\n'\n"
    "            '${BotMinds.I.selfLine(b.id, name: b.name, role: b.role)}\\n\\n'\n"
    "            'Your name is ${b.name}. Never say you are an AI model or Telesia; you are ${b.name}.'")

# app_state.dart: the part imports bot_minds
sub('lib/app_state.dart',
    "import 'services/case_tools.dart';",
    "import 'services/case_tools.dart';\nimport 'services/digital_human/bot_minds.dart';")

# agent_runner.dart: a bot turn is a lived moment kept in its mind
sub('lib/state/agent_runner.dart',
    "    final brief = Bots.I.agentBriefOf(b);",
    "    final brief = Bots.I.agentBriefOf(b);\n"
    "    // Digital human: this turn is the bot living a moment — mark it and keep the owner's message in its memory.\n"
    "    BotMinds.I.spoke(b.id, name: b.name, role: b.role);\n"
    "    if (ownerSaid != null && ownerSaid.content.trim().isNotEmpty) {\n"
    "      BotMinds.I.remember(b.id, ownerSaid.content.trim(), type: 'message', topic: 'chat');\n"
    "    }\n"
    "    unawaited(BotMinds.I.save(b.id));")

print('bot minds wired')