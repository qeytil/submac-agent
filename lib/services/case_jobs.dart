import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'case_notify.dart';
import 'cases.dart';

/// One named job of a case (docs/investigation.md §20, §23): a heavy or long step kept in the case's own queue so it
/// survives restarts and the section can say, in one line, where it stands.
class CaseJob {
  final String id;
  String title;
  String tool;
  String input;

  /// phone | actions | codespaces | box
  String lane;

  /// queued | running | done | failed | paused
  String status;
  String output;
  final DateTime at;
  DateTime? endedAt;

  CaseJob({
    required this.id,
    required this.title,
    this.tool = '',
    this.input = '',
    this.lane = 'phone',
    this.status = 'queued',
    this.output = '',
    DateTime? at,
    this.endedAt,
  }) : at = at ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'tool': tool,
        'input': input,
        'lane': lane,
        'status': status,
        'output': output,
        'at': at.toIso8601String(),
        'ended_at': endedAt?.toIso8601String(),
      };

  factory CaseJob.fromJson(Map<String, dynamic> j) => CaseJob(
        id: '${j['id']}',
        title: '${j['title'] ?? 'Job'}',
        tool: '${j['tool'] ?? ''}',
        input: '${j['input'] ?? ''}',
        lane: '${j['lane'] ?? 'phone'}',
        status: '${j['status'] ?? 'queued'}',
        output: '${j['output'] ?? ''}',
        at: DateTime.tryParse('${j['at']}')?.toLocal(),
        endedAt: DateTime.tryParse('${j['ended_at'] ?? ''}')?.toLocal(),
      );
}

/// The Investigation job queue, kept on the phone (`case_jobs_v1`). One list per case; finished jobs are the history
/// the Work section shows.
class CaseJobs extends ChangeNotifier {
  CaseJobs._();
  static final I = CaseJobs._();

  static const _key = 'case_jobs_v1';
  final Map<String, List<CaseJob>> _byCase = {};
  SharedPreferences? _p;
  bool _loaded = false;

  Future<void> init() async {
    if (_loaded) return;
    _loaded = true;
    try {
      _p = await SharedPreferences.getInstance();
      final raw = _p!.getString(_key);
      if (raw != null) {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        for (final e in (j['cases'] as Map? ?? const {}).entries) {
          final list = [for (final x in (e.value as List? ?? const [])) CaseJob.fromJson(Map<String, dynamic>.from(x as Map))];
          _byCase['${e.key}'] = list;
        }
      }
    } catch (_) {}
    notifyListeners();
  }

  List<CaseJob> of(String caseId) => _byCase[caseId] ?? const [];

  bool anyOpen(String caseId) => of(caseId).any((j) => j.status == 'queued' || j.status == 'running');

  Future<CaseJob> add(String caseId, {required String title, String tool = '', String input = '', String lane = 'phone'}) async {
    final job = CaseJob(id: '${DateTime.now().microsecondsSinceEpoch}', title: title.trim().isEmpty ? 'Job' : title.trim(), tool: tool, input: input, lane: lane);
    (_byCase[caseId] ??= []).add(job);
    await _save();
    return job;
  }

  Future<void> update(String caseId, String jobId, {String? status, String? output}) async {
    final list = _byCase[caseId];
    if (list == null) return;
    for (final j in list) {
      if (j.id != jobId) continue;
      if (status != null) {
        j.status = status;
        if (status == 'done' || status == 'failed') j.endedAt = DateTime.now();
      }
      if (output != null) j.output = output.trim();
      await _save();
      if (status == 'done') {
        final c = Cases.I.byId(caseId);
        if (c != null) await CaseNotify.milestone(c, 'Job done: ${j.title}${j.output.isEmpty ? '' : ' — ${j.output}'}');
      }
      return;
    }
  }

  Future<void> clearFinished(String caseId) async {
    final list = _byCase[caseId];
    if (list == null) return;
    list.removeWhere((j) => j.status == 'done' || j.status == 'failed');
    await _save();
  }

  Future<void> _save() async {
    _p ??= await SharedPreferences.getInstance();
    try {
      await _p!.setString(_key, jsonEncode({'cases': {for (final e in _byCase.entries) e.key: [for (final j in e.value) j.toJson()]}}));
    } catch (_) {}
    notifyListeners();
  }
}