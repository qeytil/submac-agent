import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'playbook.dart';

/// The site skills this phone has: one JSON playbook per file, under the app's documents.
/// The agent saves them with browser_play (action "save") and replays them with action "run".
///
/// The folder belongs to one account at a time (see [claim]): the account that claimed it. Another account
/// signing in sets it aside (`browser_skills.off.<uid>`, kept, never deleted) and starts clean, so no
/// account's saved flows are ever sent up as another's. Signing back in brings the set-aside folder back.
class SiteSkills {
  SiteSkills._();
  static final SiteSkills I = SiteSkills._();

  /// Set by SkillSync: a skill changed here, so the account should hear about it soon.
  /// Not called while a sync is writing a row the account already has (see SkillSync._applying).
  void Function()? onChanged;

  Directory? _dir;

  /// The documents directory the folder lives in (kept, so [claim] can rebuild the folder after setting the
  /// previous account's one aside).
  Directory? _root;

  @visibleForTesting
  void setDirForTest(Directory d) {
    _dir = d;
    _root = d.parent;
  }

  Future<Directory?> _ensure() async {
    if (_dir != null) return _dir;
    try {
      final root = _root ?? await getApplicationDocumentsDirectory();
      final d = Directory('${root.path}/browser_skills');
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
  /// [at] keeps the playbook's own time (a row adopted from the account), instead of "now".
  /// [notify] false while SkillSync writes a row the account already holds.
  Future<String?> save(Playbook p, {String? at, bool notify = true}) async {
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
      at: at ?? DateTime.now().toIso8601String(),
    );
    try {
      await f.writeAsString(jsonEncode(clean.toJson()));
    } catch (e) {
      return 'Could not save the skill: $e';
    }
    if (notify) onChanged?.call();
    return null;
  }

  Future<void> forget(String id, {bool notify = true}) async {
    final d = await _ensure();
    if (d == null) return;
    try {
      final f = _file(id.trim().toLowerCase(), d);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
    if (notify) onChanged?.call();
  }

  /// Counts a replay: how often it ran, how often it finished without the agent taking over.
  Future<void> bump(Playbook p, {required bool win}) async {
    await save(p.copyWith(runs: p.runs + 1, wins: p.wins + (win ? 1 : 0)));
  }

  // ---------------------------------------------------------------- whose skills these are

  /// The account this phone's skills belong to ('' when nobody has claimed them yet).
  Future<String> owner() async {
    final d = await _ensure();
    if (d == null) return '';
    try {
      final f = File('${d.path}/.owner');
      return f.existsSync() ? f.readAsStringSync().trim() : '';
    } catch (_) {
      return '';
    }
  }

  /// Makes this phone's skills belong to [uid]. Returns false when they cannot (then nothing is sent up):
  /// an account's saved flows must never be uploaded as another account's.
  ///
  /// Another account's folder is set aside, not deleted: `browser_skills.off.<their uid>`, brought back the
  /// next time they sign in here. The empty folder this account starts with is the account's own copy.
  Future<bool> claim(String uid) async {
    if (uid.isEmpty) return false;
    var d = await _ensure();
    if (d == null) return false;
    final cur = await owner();
    if (cur == uid) return true;
    final root = d.parent.path;
    if (cur.isNotEmpty) {
      try {
        final off = Directory('$root/browser_skills.off.$cur');
        if (off.existsSync()) off.deleteSync(recursive: true);
        d.renameSync(off.path);
      } catch (_) {
        return false;
      }
      _dir = null;
      d = await _ensure();
      if (d == null) return false;
      // This account was here before: bring its own folder back.
      final back = Directory('$root/browser_skills.off.$uid');
      if (back.existsSync()) {
        try {
          d.deleteSync(recursive: true);
          back.renameSync('$root/browser_skills');
          _dir = null;
        } catch (_) {}
      }
    }
    final folder = await _ensure();
    if (folder == null) return false;
    try {
      File('${folder.path}/.owner').writeAsStringSync(uid);
    } catch (_) {
      return false;
    }
    return true;
  }
}
