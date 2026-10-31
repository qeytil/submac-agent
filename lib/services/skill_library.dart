import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import 'apk_build.dart';
import 'design_skills.dart';

/// One entry of the shared skill library (the index line; the full instructions download on install or use).
class LibSkill {
  LibSkill({
    required this.id,
    required this.name,
    required this.cat,
    this.sub = '',
    this.desc = '',
    this.tags = const [],
    this.powers = const [],
    this.level = 'basic',
    this.v = 1,
    this.local = false,
  });
  final String id;
  final String name;
  final String cat;
  final String sub;
  final String desc;
  final List<String> tags;
  final List<String> powers;
  final String level;
  final int v;

  /// Saved on this phone by the agent itself (skill_save), not from the shared library.
  final bool local;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'cat': cat, 'sub': sub, 'desc': desc, 'tags': tags, 'powers': powers, 'level': level, 'v': v, if (local) 'local': true};
  static LibSkill fromJson(Map<String, dynamic> j) => LibSkill(
        id: '${j['id']}',
        name: '${j['name'] ?? j['id']}',
        cat: '${j['cat'] ?? j['category'] ?? 'other'}',
        sub: '${j['sub'] ?? ''}',
        desc: '${j['desc'] ?? ''}',
        tags: [for (final t in (j['tags'] as List? ?? const [])) '$t'],
        powers: [for (final t in (j['powers'] as List? ?? const [])) '$t'],
        level: '${j['level'] ?? 'basic'}',
        v: (j['v'] as num?)?.toInt() ?? 1,
        local: j['local'] == true,
      );

  String get line => '$id: $name. $desc';
}

/// The shared skill library: hundreds of expert playbooks in a public bucket. The agent and every bot can search it,
/// read a skill when a task needs it, and install skills so they are always at hand.
class SkillLibrary extends ChangeNotifier {
  SkillLibrary._();
  static final SkillLibrary I = SkillLibrary._();

  static const base = '${AppConfig.supabaseUrl}/storage/v1/object/public/skills';
  /// Who a skill is installed for: the main agent, or a bot by its id.
  static const agent = 'agent';

  static const catLabels = {
    'mobile': 'Phone apps',
    'browser': 'Browser',
    'platforms': 'Platforms',
    'business': 'Business',
    'entrepreneur': 'Entrepreneur',
    'marketing': 'Marketing',
    'seo': 'SEO',
    'creator': 'Content creators',
    'developer': 'Developers',
    'trading': 'Trading',
    'productivity': 'Productivity',
    'study': 'Study',
    'writing': 'Writing',
    'life': 'Everyday life',
    'somalia': 'Somalia',
    'mine': 'Your own skills',
  };

  /// Skills that ship inside the app: always listed and readable, even offline or before the library index loads.
  static final List<LibSkill> builtIn = [for (final m in [...ApkBuild.skills, ...DesignSkills.skills]) LibSkill.fromJson(m)];

  /// The full instructions of a built-in skill, or null.
  static String? builtInBody(String id) => ApkBuild.bodyOf(id) ?? DesignSkills.bodyOf(id);

  final List<LibSkill> skills = [...builtIn];
  final Map<String, List<String>> installed = {};
  DateTime? fetched;
  bool loading = false;
  String? error;
  SharedPreferences? _p;
  Directory? _dir;

  List<String> get categories {
    final have = skills.map((s) => s.cat).toSet();
    return [for (final c in catLabels.keys) if (have.contains(c)) c, for (final c in have) if (!catLabels.containsKey(c)) c];
  }

  static String label(String cat) => catLabels[cat] ?? (cat.isEmpty ? 'Other' : '${cat[0].toUpperCase()}${cat.substring(1)}');

  LibSkill? byId(String id) => skills.where((s) => s.id == id).firstOrNull;
  List<String> of(String target) => installed[target] ?? const [];
  bool has(String target, String id) => of(target).contains(id);

  Future<void> init() async {
    _p = await SharedPreferences.getInstance();
    try {
      _dir = Directory('${(await getApplicationDocumentsDirectory()).path}/skill_library');
      if (!_dir!.existsSync()) _dir!.createSync(recursive: true);
    } catch (_) {}
    try {
      final j = jsonDecode(_p!.getString('skill_lib_index') ?? '{}') as Map;
      _readIndex(Map<String, dynamic>.from(j));
      fetched = DateTime.tryParse('${_p!.getString('skill_lib_at')}');
    } catch (_) {}
    try {
      final m = jsonDecode(_p!.getString('skill_lib_installed') ?? '{}') as Map;
      for (final e in m.entries) {
        installed['${e.key}'] = [for (final x in e.value as List) '$x'];
      }
    } catch (_) {}
    // Skills saved on this phone (skill_save) are listed again before any library index loads.
    try {
      for (final e in _dir!.listSync()) {
        if (e is! File || !e.path.endsWith('.json')) continue;
        try {
          final j = jsonDecode(e.readAsStringSync()) as Map;
          if (j['local'] == true) {
            final s = LibSkill.fromJson(Map<String, dynamic>.from(j));
            skills.removeWhere((x) => x.id == s.id);
            skills.add(s);
          }
        } catch (_) {}
      }
    } catch (_) {}
    // A fresh index once a day, in the background.
    if (fetched == null || DateTime.now().difference(fetched!).inHours >= 24) unawaited(refresh());
  }

  void _readIndex(Map<String, dynamic> j) {
    final list = j['skills'] as List?;
    if (list == null) return;
    // Skills the agent saved itself (skill_save) outlive every library refresh and id clash with the index.
    final mine = skills.where((s) => s.local).toList();
    skills
      ..clear()
      ..addAll([for (final e in list) LibSkill.fromJson(Map<String, dynamic>.from(e as Map))]);
    // Built-in skills stay (the app's own copy wins over a library entry with the same id).
    skills.removeWhere((s) => builtIn.any((b) => b.id == s.id) || s.local);
    skills.addAll(builtIn);
    skills.addAll(mine);
  }

  Future<bool> refresh() async {
    if (loading) return false;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final r = await http.get(Uri.parse('$base/index.json?t=${DateTime.now().millisecondsSinceEpoch ~/ 3600000}')).timeout(const Duration(seconds: 20));
      if (r.statusCode != 200) throw 'The library answered ${r.statusCode}';
      final j = Map<String, dynamic>.from(jsonDecode(utf8.decode(r.bodyBytes)) as Map);
      _readIndex(j);
      fetched = DateTime.now();
      await _p?.setString('skill_lib_index', jsonEncode({'skills': skills.map((s) => s.toJson()).toList()}));
      await _p?.setString('skill_lib_at', fetched!.toIso8601String());
      // Installed skills that changed get their new version.
      for (final ids in installed.values) {
        for (final id in ids) {
          final s = byId(id);
          final f = _file(id);
          if (s != null && f != null && f.existsSync()) {
            try {
              final old = jsonDecode(f.readAsStringSync()) as Map;
              if (((old['v'] as num?)?.toInt() ?? 1) < s.v) f.deleteSync();
            } catch (_) {}
          }
        }
      }
      return true;
    } catch (e) {
      error = 'The skill library needs the internet. It loads once you\'re back online.';
      return false;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  File? _file(String id) => _dir == null ? null : File('${_dir!.path}/${id.replaceAll(RegExp(r'[^a-z0-9_-]'), '_')}.json');

  /// Tests: where skills saved by the agent go.
  @visibleForTesting
  void setDirForTest(Directory d) => _dir = d;

  /// The full instructions of a skill (from the phone when downloaded before, otherwise from the library).
  Future<String?> body(String id) async {
    final own = builtInBody(id);
    if (own != null) return own;
    final f = _file(id);
    try {
      if (f != null && f.existsSync()) return '${(jsonDecode(await f.readAsString()) as Map)['body'] ?? ''}';
    } catch (_) {}
    if (fetched == null && skills.length <= builtIn.length) await refresh();
    try {
      final r = await http.get(Uri.parse('$base/s/$id.json')).timeout(const Duration(seconds: 20));
      if (r.statusCode != 200) return null;
      final text = utf8.decode(r.bodyBytes);
      final j = jsonDecode(text) as Map;
      await f?.writeAsString(text);
      return '${j['body'] ?? ''}';
    } catch (_) {
      return null;
    }
  }

  Future<String?> install(String target, String id) async {
    final s = byId(id);
    if (s == null) return 'No skill "$id" in the library.';
    final b = await body(id);
    if (b == null || b.isEmpty) return '"${s.name}" needs the internet to download. Try again once you\'re online.';
    final l = installed.putIfAbsent(target, () => []);
    if (!l.contains(id)) l.add(id);
    while (l.length > 60) {
      l.removeAt(0);
    }
    await _save();
    return null;
  }

  /// Saves a method the agent built and tested as its own skill (`skill_save`). Stored only on this phone,
  /// in the same folder and JSON format as downloaded skills, so skill_use, the installed list and the
  /// search read it back with no server and no new code path.
  Future<String?> save(String target, {required String id, required String name, required String desc, required String body, List<String> tags = const []}) async {
    // The messy id is cleaned hard: every stray mark becomes a dash, runs collapse, edges trim
    // ("CV to PDF!" -> "cv-to-pdf"), so the saved skill reads back under the id it advertises.
    final clean = id.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9_-]'), '-').replaceAll(RegExp(r'-{2,}'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    if (clean.length < 3 || clean.length > 40) return 'The skill id needs 3 to 40 letters, numbers or dashes (like "cv-to-pdf").';
    if (body.trim().length < 20) return 'The skill is too short to reuse. Write the whole method: the steps, the script itself, how to run it.';
    final existing = byId(clean);
    if (existing != null && !existing.local) return '"$clean" is taken by a library skill. Pick another id.';
    final f = _file(clean);
    if (f == null) return 'Could not reach this phone\'s storage.';
    final text = body.trim();
    final j = <String, dynamic>{
      'id': clean,
      'name': name.trim().isEmpty ? clean : name.trim(),
      'cat': 'mine',
      'sub': '',
      'desc': desc.trim(),
      'tags': tags.take(8).toList(),
      'powers': const <String>[],
      'level': 'basic',
      'v': (existing?.v ?? 0) + 1,
      'local': true,
      'body': text.length > 40000 ? text.substring(0, 40000) : text,
    };
    await f.writeAsString(jsonEncode(j));
    final s = LibSkill.fromJson(j);
    skills.removeWhere((e) => e.id == clean);
    skills.add(s);
    final l = installed.putIfAbsent(target, () => []);
    if (!l.contains(clean)) l.add(clean);
    // A skill the agent wrote itself is never evicted by the 60-skill cap; library installs make room first.
    while (l.length > 60) {
      final own = l.indexWhere((x) => byId(x)?.local == true);
      l.removeAt(own < 0 ? 0 : own);
    }
    await _save();
    return null;
  }

  Future<void> uninstall(String target, String id) async {
    installed[target]?.remove(id);
    await _save();
  }

  /// Puts back the skills a bot had (kept per account at sign-out, R2 item 3). No download: their text is cached.
  void adopt(String target, List<String> ids) {
    if (ids.isEmpty) return;
    installed[target] = [...ids];
    unawaited(_save());
  }

  /// A bot was removed: its skills go too.
  Future<void> forget(String target) async {
    if (installed.remove(target) != null) await _save();
  }

  Future<void> _save() async {
    await _p?.setString('skill_lib_installed', jsonEncode(installed));
    notifyListeners();
  }

  static const _stop = {
    'the', 'and', 'for', 'with', 'you', 'your', 'can', 'how', 'what', 'this', 'that', 'from', 'are', 'was', 'have', 'has', 'please',
    'want', 'need', 'help', 'make', 'get', 'give', 'tell', 'about', 'some', 'into', 'out', 'all', 'any', 'one', 'my', 'me', 'it', 'is',
    'to', 'of', 'in', 'on', 'at', 'an', 'or', 'do', 'be', 'so', 'if', 'we', 'us', 'our', 'now', 'then', 'just', 'like', 'also',
    'waxaan', 'rabaa', 'ii', 'iga', 'iyo', 'ka', 'ku', 'la', 'oo', 'ee', 'ah', 'waa', 'maxaa', 'sidee', 'fadlan', 'igu', 'aan',
  };

  /// Library skills that clearly fit a message (for a quiet hint before the agent starts), best first.
  List<LibSkill> suggestFor(String text, {int limit = 3}) {
    if (text.trim().length < 12) return const [];
    final words = text.toLowerCase().split(RegExp(r'[^a-z0-9\u0600-\u06ff]+')).where((w) => w.length > 2 && !_stop.contains(w)).toSet();
    if (words.isEmpty) return const [];
    final scored = <MapEntry<LibSkill, double>>[];
    for (final s in skills) {
      final name = s.name.toLowerCase(), sub = s.sub.toLowerCase();
      final tags = s.tags.map((t) => t.toLowerCase()).toList();
      var score = 0.0;
      for (final w in words) {
        if (tags.any((t) => t == w || t.split(' ').contains(w))) score += 3;
        if (RegExp('\\b${RegExp.escape(w)}').hasMatch(name)) score += 3;
        if (sub == w) score += 1;
      }
      // Whole multi-word tags in the message ("mobile money", "business plan") are strong signals.
      final low = text.toLowerCase();
      for (final t in tags) {
        if (t.contains(' ') && low.contains(t)) score += 3;
      }
      if (score >= 6) scored.add(MapEntry(s, score));
    }
    scored.sort((a, b) => b.value.compareTo(a.value));
    return [for (final e in scored.take(limit)) e.key];
  }

  /// Best matches for a request, by name, tags, subgroup and description.
  List<LibSkill> search(String query, {String cat = '', int limit = 8}) {
    final words = query.toLowerCase().split(RegExp(r'[^a-z0-9\u0600-\u06ff]+')).where((w) => w.length > 1).toSet();
    final pool = cat.isEmpty ? skills : skills.where((s) => s.cat == cat || label(s.cat).toLowerCase() == cat.toLowerCase());
    if (words.isEmpty) return pool.take(limit).toList();
    final scored = <MapEntry<LibSkill, double>>[];
    for (final s in pool) {
      final name = s.name.toLowerCase(), sub = s.sub.toLowerCase(), desc = s.desc.toLowerCase();
      final tags = s.tags.map((t) => t.toLowerCase()).toSet();
      var score = 0.0;
      for (final w in words) {
        if (name.contains(w)) score += 3;
        if (sub.contains(w)) score += 2.5;
        if (tags.any((t) => t.contains(w))) score += 2;
        if (desc.contains(w)) score += 1;
        if (s.id.contains(w)) score += 0.5;
      }
      if (score > 0) scored.add(MapEntry(s, score));
    }
    scored.sort((a, b) => b.value.compareTo(a.value));
    return [for (final e in scored.take(limit)) e.key];
  }

  /// For the system prompt: what this agent or bot has installed, and that the library exists.
  String promptFor(String target) {
    final mine = [for (final id in of(target)) byId(id)].whereType<LibSkill>().toList();
    final sb = StringBuffer('# Skill library\n')
      ..writeln('A shared library of ${skills.length <= builtIn.length ? 'hundreds of' : skills.length} expert playbooks (phone apps like WhatsApp, TikTok, '
          'Instagram, X, Reddit, LinkedIn; browser jobs; platforms; business, marketing, SEO, trading, coding, content creation and more). '
          'Also local Somali skills: Somali writing, mobile money bookkeeping (EVC Plus, Zaad, e-Dahab, Sahal), shops and debts, invoices, '
          'selling on social media, import costing, business plans and Islamic finance, hagbad savings, Form 4 exam tutoring, homework from '
          'photos, English coaching, scholarships, teacher kits, jobs and CVs, freelancing, government papers, simple agreements, faraid, '
          'seasons and farming, livestock, first aid, local business websites, WhatsApp Business, news digests, weddings and diaspora travel.\n'
          'Built in (always available): ${ApkBuild.skillId} (build an Android APK on GitHub Actions; Somali: ${ApkBuild.skillIdSo}); '
          '${DesignSkills.webId} (finished, well-designed websites), ${DesignSkills.uiId} (app screens and interfaces), '
          '${DesignSkills.reviewId} (check visual work before delivering), ${DesignSkills.repliesId} (the right form for an answer), '
          '${DesignSkills.timingId} (progress and final replies), ${DesignSkills.docsId} (polished documents and slides), '
          '${DesignSkills.chartsId} (honest charts).\n'
          'Rule: before any real task (not small talk) where a proven method helps, check the library: if "Skills that may fit" lists one, read '
          'it with skill_use first; otherwise call skill_search with the task in a few words. Follow the skill, adapting to what the user asked '
          '(their words win). Install skills they will need again with skill_install. When you built and tested something that would help again '
          '(a script, a recipe, a checklist), save it as your own tool with skill_save — the next task like it starts from skill_use, not from '
          'zero. Skip all this for simple questions you can answer directly. Never mention the library unless it helps the user.');
    if (mine.isNotEmpty) {
      sb.writeln('Installed (read one with skill_use before you do that kind of task):');
      for (final s in mine.take(40)) {
        sb.writeln('- ${s.line}');
      }
    }
    return sb.toString().trim();
  }

  static Map<String, dynamic> _fn(String name, String desc, Map<String, dynamic> props, [List<String> req = const []]) => {
        'type': 'function',
        'function': {
          'name': name,
          'description': desc,
          'parameters': {'type': 'object', 'properties': props, 'required': req},
        },
      };

  static const names = {'skill_search', 'skill_use', 'skill_install', 'skill_remove', 'skill_save'};

  static final List<Map<String, dynamic>> definitions = [
    _fn('skill_search', 'Search the shared skill library for a proven playbook. Returns ids and one-line descriptions.', {
      'query': {'type': 'string', 'description': 'What the task is about, e.g. "post a reel on instagram"'},
      'category': {'type': 'string', 'description': 'Optional: mobile, browser, business, marketing, seo, trading, writing, life, somalia'},
    }, ['query']),
    _fn('skill_use', 'Read the full instructions of a library skill by id, then follow them for the task.', {
      'id': {'type': 'string'},
    }, ['id']),
    _fn('skill_install', 'Install a library skill so it is always listed for you.', {
      'id': {'type': 'string'},
    }, ['id']),
    _fn('skill_remove', 'Uninstall one of your skills.', {
      'id': {'type': 'string'},
    }, ['id']),
    _fn('skill_save', 'Save a method you built and tested as your own reusable skill, so the next such task starts from skill_use, '
        'with the whole method written out. Saved on this phone.', {
      'id': {'type': 'string', 'description': 'Letters-numbers-dashes, e.g. "cv-to-pdf"'},
      'name': {'type': 'string', 'description': 'e.g. "CV to PDF converter"'},
      'desc': {'type': 'string', 'description': 'One line: what it does and when to use it'},
      'body': {'type': 'string', 'description': 'The whole method: steps, the script, how to run it, what to watch for'},
    }, ['id', 'name', 'desc', 'body']),
  ];

  Future<String> execute(String name, Map<String, dynamic> a, String target, {String who = 'you'}) async {
    final id = '${a['id'] ?? ''}'.trim();
    switch (name) {
      case 'skill_search':
        if (skills.length <= builtIn.length) await refresh();
        if (skills.isEmpty) return error ?? 'The skill library is not reachable right now. Do the task with your own know-how.';
        final found = search('${a['query'] ?? ''}', cat: '${a['category'] ?? ''}'.trim());
        if (found.isEmpty) return 'No skill matches. Do the task with your own know-how.';
        return [
          for (final s in found) '- ${s.line}${has(target, s.id) ? ' (installed)' : ''}${s.powers.isEmpty ? '' : ' [needs: ${s.powers.join(', ')}]'}',
        ].join('\n');
      case 'skill_use':
        final s = byId(id);
        final b = await body(id);
        if (b == null || b.isEmpty) return 'Could not open "$id". Search again or do the task with your own know-how.';
        return '# Skill: ${s?.name ?? id}\n$b\n\n(Follow it, adapting to what the user asked. Their words beat the skill.)';
      case 'skill_install':
        final e = await install(target, id);
        return e ?? 'Installed "${byId(id)?.name ?? id}" for $who.';
      case 'skill_remove':
        await uninstall(target, id);
        return 'Removed.';
      case 'skill_save':
        final e = await save(target,
            id: '${a['id'] ?? ''}',
            name: '${a['name'] ?? ''}',
            desc: '${a['desc'] ?? ''}',
            body: '${a['body'] ?? ''}',
            tags: [for (final t in (a['tags'] as List? ?? const [])) '$t']);
        return e ?? 'Saved "${a['name'] ?? a['id']}" as your own skill. It is listed for $who from now on; read it back with skill_use.';
    }
    return 'Unknown skill tool.';
  }
}
