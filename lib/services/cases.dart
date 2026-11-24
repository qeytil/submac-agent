import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'case_abilities.dart';
import 'case_engine.dart';
import 'tools.dart';

/// The Investigation section (private detective): a Case is a long-lived unit with a brief, a status, a mode, a
/// conversation, a body of evidence and its own folder. It mirrors the Projects and Offices services: a
/// `ChangeNotifier` singleton, JSON in SharedPreferences, files under `workspace/cases/<id>/`.
///
/// Nothing here talks to the chat engine; the AppState controller (state/cases_controller.dart) creates the case's
/// conversation and opens it. Cases stay out of the normal chat list through [convIds] (the way bot chats do).
class Case {
  final String id;
  final int number;

  /// A case's counter within its month; the label is built from [created] + [number].
  String title;
  String brief;
  String client;
  String reportedTo;

  /// open | active | cold | solved | closed
  String status;

  /// solo | partner
  String mode;

  /// The case's own conversation (filled by the controller on first open).
  String convId;

  /// '' = default, else a byok ref.
  String modelSetting;

  /// auto | light | deep
  String thinking;

  /// ability id -> off | ask | on (see CaseAbilities).
  Map<String, String> abilities;

  /// Private: blocks report export until unlocked.
  bool locked;

  final DateTime created;
  DateTime updated;

  List<CasePerson> persons;
  List<CaseEvent> timeline;
  List<CaseFinding> findings;
  List<CaseExhibit> exhibits;

  Case({
    required this.id,
    required this.number,
    required this.title,
    this.brief = '',
    this.client = '',
    this.reportedTo = '',
    this.status = 'open',
    this.mode = CaseMode.partner,
    this.convId = '',
    this.modelSetting = '',
    this.thinking = 'auto',
    Map<String, String>? abilities,
    this.locked = false,
    DateTime? created,
    DateTime? updated,
    List<CasePerson>? persons,
    List<CaseEvent>? timeline,
    List<CaseFinding>? findings,
    List<CaseExhibit>? exhibits,
  })  : created = created ?? DateTime.now(),
        updated = updated ?? DateTime.now(),
        abilities = abilities ?? CaseAbilities.defaultLevels(),
        persons = persons ?? [],
        timeline = timeline ?? [],
        findings = findings ?? [],
        exhibits = exhibits ?? [];

  /// "Case 2611-042": YYMM from [created], then the month counter, zero-padded to three.
  String get numberLabel {
    final ym = '${created.year % 100}${created.month.toString().padLeft(2, '0')}';
    return 'Case $ym-${number.toString().padLeft(3, '0')}';
  }

  bool get isOpen => status == 'open' || status == 'active';
  int get openQuestions => findings.where((f) => f.status == 'open').length;

  String get statusWord => switch (status) {
        'open' => 'Open',
        'active' => 'Active',
        'cold' => 'Cold',
        'solved' => 'Solved',
        'closed' => 'Closed',
        _ => status,
      };

  Map<String, dynamic> toJson() => {
        'id': id,
        'number': number,
        'title': title,
        'brief': brief,
        'client': client,
        'reported_to': reportedTo,
        'status': status,
        'mode': mode,
        'conv_id': convId,
        'model': modelSetting,
        'thinking': thinking,
        'abilities': abilities,
        'locked': locked,
        'created': created.toIso8601String(),
        'updated': updated.toIso8601String(),
        'persons': [for (final x in persons) x.toJson()],
        'timeline': [for (final x in timeline) x.toJson()],
        'findings': [for (final x in findings) x.toJson()],
        'exhibits': [for (final x in exhibits) x.toJson()],
      };

  factory Case.fromJson(Map<String, dynamic> j) => Case(
        id: '${j['id']}',
        number: (j['number'] as num?)?.toInt() ?? 1,
        title: '${j['title'] ?? 'Case'}',
        brief: '${j['brief'] ?? ''}',
        client: '${j['client'] ?? ''}',
        reportedTo: '${j['reported_to'] ?? ''}',
        status: '${j['status'] ?? 'open'}',
        mode: '${j['mode'] ?? CaseMode.partner}',
        convId: '${j['conv_id'] ?? ''}',
        modelSetting: '${j['model'] ?? ''}',
        thinking: '${j['thinking'] ?? 'auto'}',
        abilities: CaseAbilities.merge(j['abilities']),
        locked: j['locked'] == true,
        created: DateTime.tryParse('${j['created']}')?.toLocal(),
        updated: DateTime.tryParse('${j['updated']}')?.toLocal(),
        persons: [for (final e in (j['persons'] as List? ?? const [])) CasePerson.fromJson(Map<String, dynamic>.from(e as Map))],
        timeline: [for (final e in (j['timeline'] as List? ?? const [])) CaseEvent.fromJson(Map<String, dynamic>.from(e as Map))],
        findings: [for (final e in (j['findings'] as List? ?? const [])) CaseFinding.fromJson(Map<String, dynamic>.from(e as Map))],
        exhibits: [for (final e in (j['exhibits'] as List? ?? const [])) CaseExhibit.fromJson(Map<String, dynamic>.from(e as Map))],
      );
}

class CaseMode {
  CaseMode._();
  static const solo = 'solo';
  static const partner = 'partner';
}

class CasePerson {
  final String id;
  String name;

  /// subject | witness | contact | unknown
  String role;
  String notes;

  /// Handles, accounts, links.
  List<String> links;

  CasePerson({required this.id, required this.name, this.role = 'unknown', this.notes = '', List<String>? links})
      : links = links ?? [];

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'role': role, 'notes': notes, 'links': links};

  factory CasePerson.fromJson(Map<String, dynamic> j) => CasePerson(
        id: '${j['id']}',
        name: '${j['name'] ?? ''}',
        role: '${j['role'] ?? 'unknown'}',
        notes: '${j['notes'] ?? ''}',
        links: [for (final e in (j['links'] as List? ?? const [])) '$e'],
      );
}

class CaseEvent {
  final String id;
  DateTime at;
  String text;

  /// An exhibit id, or 'note'.
  String source;

  CaseEvent({required this.id, required this.at, required this.text, this.source = 'note'});

  Map<String, dynamic> toJson() => {'id': id, 'at': at.toIso8601String(), 'text': text, 'source': source};

  factory CaseEvent.fromJson(Map<String, dynamic> j) => CaseEvent(
        id: '${j['id']}',
        at: DateTime.tryParse('${j['at']}')?.toLocal() ?? DateTime.now(),
        text: '${j['text'] ?? ''}',
        source: '${j['source'] ?? 'note'}',
      );
}

class CaseFinding {
  final String id;
  String text;

  /// low | med | high
  String confidence;

  /// open | confirmed | dropped
  String status;
  List<String> evidence;

  CaseFinding({required this.id, required this.text, this.confidence = 'low', this.status = 'open', List<String>? evidence})
      : evidence = evidence ?? [];

  Map<String, dynamic> toJson() => {'id': id, 'text': text, 'confidence': confidence, 'status': status, 'evidence': evidence};

  factory CaseFinding.fromJson(Map<String, dynamic> j) => CaseFinding(
        id: '${j['id']}',
        text: '${j['text'] ?? ''}',
        confidence: '${j['confidence'] ?? 'low'}',
        status: '${j['status'] ?? 'open'}',
        evidence: [for (final e in (j['evidence'] as List? ?? const [])) '$e'],
      );
}

class CaseExhibit {
  final String id;
  String path;
  String name;
  DateTime addedAt;
  String sha256;
  String kind;
  String note;

  CaseExhibit({
    required this.id,
    required this.path,
    required this.name,
    required this.addedAt,
    this.sha256 = '',
    this.kind = 'file',
    this.note = '',
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'path': path,
        'name': name,
        'added_at': addedAt.toIso8601String(),
        'sha256': sha256,
        'kind': kind,
        'note': note,
      };

  factory CaseExhibit.fromJson(Map<String, dynamic> j) => CaseExhibit(
        id: '${j['id']}',
        path: '${j['path'] ?? ''}',
        name: '${j['name'] ?? ''}',
        addedAt: DateTime.tryParse('${j['added_at']}')?.toLocal() ?? DateTime.now(),
        sha256: '${j['sha256'] ?? ''}',
        kind: '${j['kind'] ?? 'file'}',
        note: '${j['note'] ?? ''}',
      );
}

class Cases extends ChangeNotifier {
  Cases._();
  static final I = Cases._();

  final List<Case> list = [];
  SharedPreferences? _p;

  static const _storeKey = 'cases_v1';

  Future<void> init() async {
    _p = await SharedPreferences.getInstance();
    try {
      final raw = _p!.getString(_storeKey);
      if (raw != null) {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        list
          ..clear()
          ..addAll([for (final e in (j['cases'] as List? ?? const [])) Case.fromJson(Map<String, dynamic>.from(e as Map))]);
      }
    } catch (_) {}
    for (final c in list) {
      try {
        await Directory(await filesDir(c.id)).create(recursive: true);
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<void> _save() async {
    _p ??= await SharedPreferences.getInstance();
    await _p!.setString(_storeKey, jsonEncode({'cases': [for (final c in list) c.toJson()]}));
    notifyListeners();
  }

  Future<void> save() => _save();

  Case? byId(String? id) {
    if (id == null) return null;
    for (final c in list) {
      if (c.id == id) return c;
    }
    return null;
  }

  Case? byConv(String? convId) {
    if (convId == null || convId.isEmpty) return null;
    for (final c in list) {
      if (c.convId == convId) return c;
    }
    return null;
  }

  /// The case conversations, so the drawer, search and chat list can leave them out (like bot chats).
  Set<String> get convIds => {for (final c in list) if (c.convId.isNotEmpty) c.convId};

  int get openCount => list.where((c) => c.isOpen).length;

  /// The next case number within the current month (kept in prefs, so it never repeats).
  Future<int> _nextNumber() async {
    _p ??= await SharedPreferences.getInstance();
    final now = DateTime.now();
    final key = 'cases_n_${now.year}${now.month.toString().padLeft(2, '0')}';
    final n = (_p!.getInt(key) ?? 0) + 1;
    await _p!.setInt(key, n);
    return n;
  }

  Future<Case> create({required String title, String brief = '', String reportedTo = ''}) async {
    final c = Case(
      id: const Uuid().v4(),
      number: await _nextNumber(),
      title: title.trim().isEmpty ? 'New case' : title.trim(),
      brief: brief.trim(),
      reportedTo: reportedTo.trim(),
    );
    list.insert(0, c);
    try {
      await Directory(await filesDir(c.id)).create(recursive: true);
    } catch (_) {}
    await _save();
    return c;
  }

  Future<void> update(Case c,
      {String? title, String? brief, String? reportedTo, String? status, String? mode, String? model, String? thinking, bool? locked}) async {
    if (title != null && title.trim().isNotEmpty) c.title = title.trim();
    if (brief != null) c.brief = brief.trim();
    if (reportedTo != null) c.reportedTo = reportedTo.trim();
    if (status != null) c.status = status;
    if (mode != null) c.mode = mode;
    if (model != null) c.modelSetting = model;
    if (thinking != null) c.thinking = thinking;
    if (locked != null) c.locked = locked;
    c.updated = DateTime.now();
    await _save();
  }

  Future<void> setAbilities(Case c, Map<String, String> levels) async {
    c.abilities = {...c.abilities, ...levels};
    c.updated = DateTime.now();
    await _save();
  }

  Future<void> setConv(Case c, String convId) async {
    c.convId = convId;
    await _save();
  }

  /// Deletes the case. Its chats stay; its folder is removed unless [keepFolder].
  Future<void> delete(Case c, {bool keepFolder = false}) async {
    list.remove(c);
    if (!keepFolder) {
      try {
        final d = Directory(await filesDir(c.id));
        if (await d.exists()) await d.delete(recursive: true);
      } catch (_) {}
    }
    await _save();
  }

  // ------------------------------------------------------------------ files

  static Future<String> filesDir(String caseId) async => '${await AgentTools.workspaceDir()}/cases/$caseId';

  Future<List<File>> files(String caseId) async {
    final d = Directory(await filesDir(caseId));
    if (!await d.exists()) return [];
    final out = <File>[];
    await for (final e in d.list()) {
      if (e is File) out.add(e);
    }
    out.sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
    return out;
  }

  /// Copies a file into the case folder, records its hash and appends the exhibit.
  Future<CaseExhibit?> addExhibit(Case c, String sourcePath, {String kind = 'file', String note = ''}) async {
    try {
      final dir = await filesDir(c.id);
      await Directory(dir).create(recursive: true);
      final name = sourcePath.split(Platform.pathSeparator).last;
      var target = File('$dir/$name');
      var i = 1;
      while (await target.exists()) {
        final dot = name.lastIndexOf('.');
        target = File(dot > 0 ? '$dir/${name.substring(0, dot)} ($i)${name.substring(dot)}' : '$dir/$name ($i)');
        i++;
      }
      await File(sourcePath).copy(target.path);
      final hash = sha256.convert(await target.readAsBytes()).toString();
      final x = CaseExhibit(id: const Uuid().v4(), path: target.path, name: target.path.split(Platform.pathSeparator).last, addedAt: DateTime.now(), sha256: hash, kind: kind, note: note);
      c.exhibits.add(x);
      c.updated = DateTime.now();
      await _save();
      return x;
    } catch (_) {
      return null;
    }
  }

  Future<void> removeExhibit(Case c, String exhibitId) async {
    c.exhibits.removeWhere((e) => e.id == exhibitId);
    c.updated = DateTime.now();
    await _save();
  }

  // ------------------------------------------------------------------ prompt

  /// What a case chat adds to the system prompt (composed where Projects.promptFor and Bots.promptOf are).
  String promptFor(String? convId) {
    final c = byConv(convId);
    if (c == null) return '';
    final dir = 'cases/${c.id}';
    final sb = StringBuffer()
      ..writeln('# Case ${c.numberLabel}: ${c.title}')
      ..writeln('You are working a case. This chat is the case room; keep everything consistent with the case.')
      ..writeln('Mode: ${c.mode == CaseMode.solo ? 'Solo. Work the case on your own, report at milestones, interrupt only for money, danger or a real fork.' : 'Partner. Work as a team; the user steers, ask focused questions, test their theories.'}');
    if (c.brief.isNotEmpty) sb.writeln('Brief: ${c.brief}');
    if (c.reportedTo.isNotEmpty) sb.writeln('Reported to: ${c.reportedTo}');
    sb.writeln('Status: ${c.status}.');
    sb.writeln(CaseAbilities.promptLine(c.abilities));
    if (c.openQuestions > 0) {
      sb.writeln('Open questions:');
      for (final f in c.findings.where((f) => f.status == 'open')) {
        sb.writeln('- ${f.text} (${f.confidence})');
      }
    }
    sb.writeln(CaseEngine.note());
    sb.writeln('Long jobs: record them with case_job (add, then update to running/done/failed) so they survive restarts.');
    sb.writeln('Case folder: $dir. Save exhibits and reports there. Public sources only; rate every finding and give sources.');
    return sb.toString();
  }
}
