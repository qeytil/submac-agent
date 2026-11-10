// The per-run checkpoint journal: one append-only JSONL file per run, written as the run goes (model steps, tool
// starts and ends with each tool's effect class, approvals waiting, a heartbeat, the end). If Android kills the app in
// the middle of a run, the next start finds the file without an end line and a stale heartbeat, and the run resumes:
// nothing is run again by the app. A cut-off read-only or idempotent call is answered "safe to call again", a cut-off side
// effect (send, pay, post…) "unknown whether it happened, check first", a waiting approval "not done"; then the model goes on.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models.dart';
import 'core.dart';
import 'tool_effects.dart';

class RunJournal extends RunLog {
  RunJournal._(this.file, this.runId, this.convId, this.kind);

  final File file;
  final String runId;
  final String convId;

  /// 'main' (a chat with Telesia or a bot), 'member' (a team member's part), 'browser' (the browser sub-agent).
  final String kind;
  Timer? _beat;
  bool _closed = false;

  /// Where journals live (the app's files folder + /runs). Set at app start; null in tests that do not need one.
  static Directory? root;

  /// Points [root] at the app's support folder (+ /runs). Called once at app start.
  static Future<void> useAppFolder() async {
    try {
      root ??= Directory('${(await getApplicationSupportDirectory()).path}/runs');
    } catch (_) {}
  }

  /// How long without a heartbeat before an unfinished run counts as killed.
  static const stale = Duration(seconds: 20);

  /// Opens a journal for a new run (or a resumed one: the same file, appended).
  static Future<RunJournal?> open({required String runId, required String convId, String kind = 'main', Map<String, Object?> meta = const {}, Directory? dir}) async {
    final d = dir ?? root;
    if (d == null) return null;
    try {
      await d.create(recursive: true);
      final f = File('${d.path}/$runId.jsonl');
      final j = RunJournal._(f, runId, convId, kind);
      final resumed = await f.exists();
      // A kill may have left half a line at the end: the next line starts fresh.
      if (resumed) f.writeAsStringSync('\n', mode: FileMode.append, flush: true);
      j._write({'t': resumed ? 'resume' : 'header', 'run': runId, 'conv': convId, 'kind': kind, 'at': _now(), ...meta});
      j._beat = Timer.periodic(const Duration(seconds: 10), (_) => j.beat());
      return j;
    } catch (_) {
      return null;
    }
  }

  static String _now() => DateTime.now().toUtc().toIso8601String();

  void _write(Map<String, Object?> line) {
    if (_closed) return;
    try {
      file.writeAsStringSync('${jsonEncode(line)}\n', mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  static String _clip(String s, int n) => s.length <= n ? s : '${s.substring(0, n)}…';

  void beat() => _write({'t': 'beat', 'at': _now()});

  @override
  Future<void> modelStep(Reply r) async => _write({
        't': 'model',
        'step': r.step,
        'at': _now(),
        'text': _clip(r.text, 4000),
        'calls': [for (final c in r.calls) c.toJson()],
        'in': r.tokensIn,
        'out': r.tokensOut,
      });

  @override
  Future<void> toolStart(ToolCall c) async => _write({
        't': 'tool_start',
        'id': c.id,
        'name': c.name,
        'args': _clip(c.arguments, 8000),
        'effect': ToolEffects.label(ToolEffects.of(c.name)),
        'at': _now(),
      });

  @override
  Future<void> toolEnd(ToolCall c, String output) async => _write({'t': 'tool_end', 'id': c.id, 'out': _clip(output, 2000), 'at': _now()});

  @override
  Future<void> interrupt(ToolCall c, Map<String, dynamic> data) async =>
      _write({'t': 'interrupt', 'id': c.id, 'name': c.name, 'args': _clip(c.arguments, 8000), 'data': data, 'at': _now()});

  @override
  Future<void> status(String s) async => _write({'t': 'status', 's': s, 'at': _now()});

  /// The run ended (done, stopped, failed, halted, or handed to a resume). Ends the heartbeat.
  Future<void> close(String status) async {
    _write({'t': 'end', 's': status, 'at': _now()});
    _beat?.cancel();
    _closed = true;
  }

  /// Unfinished runs whose heartbeat is older than [staleAfter]: the app was killed while they ran.
  static Future<List<PendingRun>> pending({Directory? dir, Duration staleAfter = stale, DateTime? now}) async {
    final d = dir ?? root;
    if (d == null || !await d.exists()) return [];
    final out = <PendingRun>[];
    final at = now ?? DateTime.now().toUtc();
    await for (final e in d.list()) {
      if (e is! File || !e.path.endsWith('.jsonl')) continue;
      final p = await PendingRun.read(e);
      if (p == null || p.ended) continue;
      if (at.difference(p.lastBeat) < staleAfter) continue;
      out.add(p);
    }
    out.sort((a, b) => a.lastBeat.compareTo(b.lastBeat));
    return out;
  }

  /// Old journals are kept a week (for support), then removed.
  static Future<void> prune({Directory? dir, Duration keep = const Duration(days: 7)}) async {
    final d = dir ?? root;
    if (d == null || !await d.exists()) return;
    final cut = DateTime.now().subtract(keep);
    await for (final e in d.list()) {
      try {
        if (e is File && (await e.lastModified()).isBefore(cut)) await e.delete();
      } catch (_) {}
    }
  }
}

/// A run read back from its journal.
class PendingRun {
  PendingRun._(this.file, this.runId, this.convId, this.kind, this.started, this.lastBeat, this.ended, this.unfinished, this.waiting, this.steps, this.meta);
  final File file;
  final String runId, convId, kind;
  final DateTime started, lastBeat;
  final bool ended;

  /// Tool calls that started and never ended (the app died while they ran).
  final List<ToolCall> unfinished;

  /// Approvals that were waiting on the user when the app died.
  final List<ToolCall> waiting;

  /// Model steps that finished.
  final int steps;
  final Map<String, Object?> meta;

  static Future<PendingRun?> read(File f) async {
    try {
      final lines = await f.readAsLines();
      String? run, conv, kind;
      DateTime? started, beat;
      var ended = false, steps = 0;
      final meta = <String, Object?>{};
      final open = <String, ToolCall>{};
      final asks = <String, ToolCall>{};
      for (final l in lines) {
        if (l.trim().isEmpty) continue;
        final Map<String, dynamic> j;
        try {
          j = jsonDecode(l) as Map<String, dynamic>;
        } catch (_) {
          continue; // a line cut by the kill
        }
        final at = DateTime.tryParse('${j['at']}');
        if (at != null) beat = at;
        switch (j['t']) {
          case 'header':
          case 'resume':
            run ??= '${j['run']}';
            conv ??= '${j['conv']}';
            kind ??= '${j['kind']}';
            started ??= at;
            ended = false;
            for (final k in j.keys) {
              if (!const {'t', 'run', 'conv', 'kind', 'at'}.contains(k)) meta[k] = j[k];
            }
          case 'model':
            steps++;
          case 'tool_start':
            open['${j['id']}'] = ToolCall(id: '${j['id']}', name: '${j['name']}', arguments: '${j['args'] ?? '{}'}');
          case 'tool_end':
            open.remove('${j['id']}');
            asks.remove('${j['id']}');
          case 'interrupt':
            asks['${j['id']}'] = ToolCall(id: '${j['id']}', name: '${j['name']}', arguments: '${j['args'] ?? '{}'}');
          case 'end':
            ended = true;
        }
      }
      if (run == null || conv == null || started == null || beat == null) return null;
      return PendingRun._(f, run, conv, kind ?? 'main', started, beat, ended, open.values.toList(), asks.values.where((c) => !open.containsKey(c.id)).toList(), steps, meta);
    } catch (_) {
      return null;
    }
  }

  /// How each cut-off call is settled before the run goes on: run it again (read/idempotent) or tell the model it is
  /// unknown whether it happened (side effect). Approvals that were waiting are reported as not done.
  ResumePlan plan() => ResumePlan(
        rerun: [for (final c in unfinished) if (ToolEffects.rerunnable(c.name)) c],
        settle: {
          for (final c in unfinished)
            if (!ToolEffects.rerunnable(c.name)) c.id: ToolEffects.interrupted(c.name),
          for (final c in waiting) c.id: ToolEffects.approvalLost,
        },
      );

  /// Marks this journal as handled (resumed, or given up), so it is never picked up twice.
  Future<void> markHandled(String how) async {
    try {
      // Starts on a fresh line: the kill may have left half a line at the end.
      await file.writeAsString('\n${jsonEncode({'t': 'end', 's': how, 'at': DateTime.now().toUtc().toIso8601String()})}\n', mode: FileMode.append, flush: true);
    } catch (_) {}
  }
}

class ResumePlan {
  ResumePlan({required this.rerun, required this.settle});

  /// Calls to run again before the model continues.
  final List<ToolCall> rerun;

  /// Call id → the result text the model gets instead of running it.
  final Map<String, String> settle;

  /// The result text for one call the chat shows without an answer. Nothing is ever run here: a cut-off side effect
  /// is reported as unknown, a cut-off read or idempotent call as safe to call again, a waiting approval as not done,
  /// and a call the journal never saw start as not done.
  String textFor(ToolCall c) {
    final s = settle[c.id];
    if (s != null) return s;
    if (rerun.any((r) => r.id == c.id)) return ToolEffects.cutOffSafe(c.name);
    return ToolEffects.notStarted;
  }
}

/// Settling a killed run in its chat before it goes on.
class ResumeSettle {
  ResumeSettle._();

  /// Tool calls of the killed run that have no tool reply yet: the ones the app died on. The model API needs an answer
  /// for every call before the next step.
  ///
  /// The run is found from where it started, never from the newest user message: a message the user typed while the
  /// task ran (a steer) sits after the run's tool calls and must not hide a cut-off send or payment. [fromId] is the
  /// user message that started the run (kept in the journal header); calls the journal saw start or wait ([journalIds])
  /// count wherever they are in the chat. Without either, the newest user message is the fallback.
  static List<ToolCall> unanswered(List<ChatMessage> list, {String? fromId, Iterable<String> journalIds = const []}) {
    var from = -1;
    if (fromId != null && fromId.isNotEmpty) {
      from = list.indexWhere((m) => m.id == fromId);
      if (from >= 0) from++;
    }
    if (from < 0) {
      from = 0;
      for (var i = list.length - 1; i >= 0; i--) {
        if (list[i].role == 'user') {
          from = i + 1;
          break;
        }
      }
    }
    final known = journalIds.toSet();
    final calls = <ToolCall>[];
    final seen = <String>{};
    final answered = <String>{
      for (final m in list)
        if (m.role == 'tool' && m.toolCallId != null) m.toolCallId!,
    };
    for (var i = 0; i < list.length; i++) {
      final m = list[i];
      if (m.role != 'assistant') continue;
      for (final c in m.toolCalls ?? const <ToolCall>[]) {
        if ((i >= from || known.contains(c.id)) && seen.add(c.id)) calls.add(c);
      }
    }
    return [for (final c in calls) if (!answered.contains(c.id)) c];
  }

  /// The note the resumed run starts with.
  static String note(int settled) => '# Resumed after the app closed\n'
      'Telesia was closed by the phone while you were working on this task${settled > 0 ? ', and $settled tool call(s) were cut off (their results say what is known)' : ''}. '
      'Carry on from where you were: do not start over, do not repeat anything that already happened, and never repeat a '
      'send, payment, post or delete whose result says it is unknown; check first. Then finish the task as asked.';
}
