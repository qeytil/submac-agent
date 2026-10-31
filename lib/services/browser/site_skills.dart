import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'playbook.dart';

/// The site skills this phone has: one JSON playbook per file, under the app's documents.
/// The agent saves them with browser_play (action "save") and replays them with action "run".
class SiteSkills {
  SiteSkills._();
  static final SiteSkills I = SiteSkills._();

  Directory? _dir;

  @visibleForTesting
  void setDirForTest(Directory d) => _dir = d;

  Future<Directory?> _ensure() async {
    if (_dir != null) return _dir;
    try {
      final d = Directory('${(await getApplicationDocumentsDirectory()).path}/browser_skills');
      if (!d.existsSync()) d.createSync(recursive: true);
      _dir = d;
    } catch (_) {}
    return _dir;
  }

  File _file(String id, Directory d) => File('${d.path}/${id.replaceAll(RegExp(r'[^a-z0-9_-]'), '_')}.json');

  /// Every saved playbook, newest first.
  Future<List<Playbook>> all() async {
    final d = await _ensure();
    if (d == null) return const [];
    final out = <Playbook>[];
    try {
      for (final e in d.listSync()) {
        if (e is! File || !e.path.endsWith('.json')) continue;
        try {
          final j = jsonDecode(e.readAsStringSync());
          if (j is Map) {
            final p = Playbook.fromJson(Map<String, dynamic>.from(j));
            if (p != null) out.add(p);
          }
        } catch (_) {}
      }
    } catch (_) {}
    out.sort((a, b) => b.at.compareTo(a.at));
    return out;
  }

  static String hostOf(String host) => host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');

  /// Playbooks recorded on this host (a subdomain matches its own host; the host matches a saved subdomain too).
  Future<List<Playbook>> forHost(String host) async {
    final h = hostOf(host);
    if (h.isEmpty) return const [];
    final out = <Playbook>[];
    for (final p in await all()) {
      final s = hostOf(p.site);
      if (s.isEmpty) continue;
      if (s == h || h.endsWith('.$s') || s.endsWith('.$h')) out.add(p);
    }
    return out;
  }

  Future<Playbook?> byId(String id) async {
    final d = await _ensure();
    if (d == null) return null;
    final f = _file(id.trim().toLowerCase(), d);
    try {
      if (!f.existsSync()) return null;
      final j = jsonDecode(await f.readAsString());
      return j is Map ? Playbook.fromJson(Map<String, dynamic>.from(j)) : null;
    } catch (_) {
      return null;
    }
  }

  /// Writes the playbook. Returns an error line, or null when saved.
  Future<String?> save(Playbook p) async {
    final d = await _ensure();
    if (d == null) return 'Could not reach this phone\'s storage.';
    if (p.steps.isEmpty) return 'There are no steps to save yet.';
    if (p.site.isEmpty) return 'Save it while the site is open (the host names the skill).';
    final id = playbookId(p.id.isEmpty ? p.name : p.id);
    final f = _file(id, d);
    final clean = Playbook(
      id: id,
      name: p.name.trim().isEmpty ? id : p.name.trim(),
      site: hostOf(p.site),
      goal: p.goal,
      steps: p.steps,
      runs: p.runs,
      wins: p.wins,
      at: DateTime.now().toIso8601String(),
    );
    try {
      await f.writeAsString(jsonEncode(clean.toJson()));
      return null;
    } catch (e) {
      return 'Could not save the skill: $e';
    }
  }

  Future<void> forget(String id) async {
    final d = await _ensure();
    if (d == null) return;
    try {
      final f = _file(id.trim().toLowerCase(), d);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  /// Counts a replay: how often it ran, how often it finished without the agent taking over.
  Future<void> bump(Playbook p, {required bool win}) async {
    await save(p.copyWith(runs: p.runs + 1, wins: p.wins + (win ? 1 : 0)));
  }
}
