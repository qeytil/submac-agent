import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'system_bridge.dart';
import 'tools.dart' show AgentTools;

/// Mission mode (owner 2026-11-07): a bot or a team, once the owner switches autonomy on and gives it a goal, works
/// toward it on its own across many runs, also with SubMac closed. It plans, keeps a task list and a progress log on
/// disk, wakes itself (its own exact alarm, the same AlarmManager → TaskService → AlarmGate path bot routines and
/// scheduled tasks use), hands work to teammates, and reaches the owner only for approvals, money and irreversible
/// steps ("[needs you]"). Guardrails: runs per day, tokens per day, a stop switch, and a log the owner sees.
///
/// One mission per bot and one per team. State lives in `<workspace>/missions/<id>/mission.json` (resumable after a
/// restart or a crash) with a readable `MISSION.md` next to it that the bot can open with its own file tools.

/// One line of a mission's plan.
class MissionStep {
  MissionStep(this.id, this.text, {this.status = 'todo', this.who = '', this.note = ''});
  final String id;
  String text;

  /// todo | doing | done | blocked
  String status;

  /// Who does it ('' = the mission's owner itself; a teammate's name in a team).
  String who;
  String note;
  DateTime updated = DateTime.now();

  bool get open => status != 'done';

  Map<String, dynamic> toJson() => {'id': id, 't': text, 's': status, if (who.isNotEmpty) 'w': who, if (note.isNotEmpty) 'n': note, 'u': updated.toIso8601String()};
  static MissionStep fromJson(Map<String, dynamic> j) => MissionStep('${j['id']}', '${j['t'] ?? ''}',
      status: '${j['s'] ?? 'todo'}', who: '${j['w'] ?? ''}', note: '${j['n'] ?? ''}')
    ..updated = DateTime.tryParse('${j['u']}') ?? DateTime.now();
}

/// One entry of the activity log the owner sees.
class MissionEntry {
  MissionEntry(this.kind, this.text, {DateTime? at, this.who = ''}) : at = at ?? DateTime.now();

  /// start | plan | progress | step | delegate | schedule | wake | skip | needs_you | answer | done | stop | budget | owner
  final String kind;
  final String text;
  final String who;
  final DateTime at;

  Map<String, dynamic> toJson() => {'k': kind, 't': text, if (who.isNotEmpty) 'w': who, 'at': at.toIso8601String()};
  static MissionEntry fromJson(Map<String, dynamic> j) =>
      MissionEntry('${j['k'] ?? 'progress'}', '${j['t'] ?? ''}', who: '${j['w'] ?? ''}', at: DateTime.tryParse('${j['at']}'));
}

class Mission {
  Mission({
    required this.id,
    required this.kind,
    required this.ownerId,
    required this.goal,
    this.runsPerDay = defaultRuns,
    this.tokensPerDay = defaultTokens,
    DateTime? created,
  }) : created = created ?? DateTime.now();

  static const defaultRuns = 12;
  static const defaultTokens = 400000;

  final String id;

  /// bot | team
  final String kind;

  /// The bot's id or the team's (office) id.
  final String ownerId;
  String goal;

  /// The owner's switch: off = it never wakes on its own (the plan and log stay).
  bool on = true;

  /// active | waiting (a [needs you] is open) | done | stopped
  String status = 'active';

  int runsPerDay;
  int tokensPerDay;

  String dayKey = '';
  int runsToday = 0;
  int tokensToday = 0;
  int runsTotal = 0;
  int tokensTotal = 0;

  /// Its next own wake, and why.
  DateTime? nextAt;
  String nextWhy = '';

  /// A run is going on now (set at the wake, cleared at its end); tokens used meanwhile count toward the mission.
  DateTime? runningSince;

  /// What it asked the owner ("[needs you]"), until answered.
  String needs = '';

  /// The latest progress summary (the notification text).
  String summary = '';
  DateTime? lastNotified;

  final DateTime created;
  DateTime updated = DateTime.now();
  final List<MissionStep> plan = [];
  final List<MissionEntry> log = [];

  bool get finished => status == 'done' || status == 'stopped';
  bool get running => runningSince != null && Missions.clock().difference(runningSince!) < Missions.runWindow;

  static String dayOf(DateTime d) => '${d.year}-${d.month}-${d.day}';

  void rollDay([DateTime? now]) {
    final k = dayOf(now ?? DateTime.now());
    if (k != dayKey) {
      dayKey = k;
      runsToday = 0;
      tokensToday = 0;
    }
  }

  /// Why it may not run now, or null when it may.
  String? blockedReason([DateTime? now]) {
    rollDay(now);
    if (!on) return 'autonomy is off';
    if (status == 'done') return 'the mission is done';
    if (status == 'stopped') return 'the mission was stopped';
    if (runsToday >= runsPerDay) return 'today\'s $runsPerDay runs are used';
    if (tokensPerDay > 0 && tokensToday >= tokensPerDay) return 'today\'s token budget (${Missions.k(tokensPerDay)}) is used';
    return null;
  }

  void add(String kind, String text, {String who = ''}) {
    log.add(MissionEntry(kind, text.length > 600 ? '${text.substring(0, 599)}…' : text, who: who));
    while (log.length > Missions.maxLog) {
      log.removeAt(0);
    }
    updated = DateTime.now();
  }

  Map<String, dynamic> toJson() => {
        'id': id, 'kind': kind, 'owner': ownerId, 'goal': goal, 'on': on, 'status': status,
        'rpd': runsPerDay, 'tpd': tokensPerDay, 'day': dayKey, 'rt': runsToday, 'tt': tokensToday,
        'rT': runsTotal, 'tT': tokensTotal, 'next': nextAt?.toIso8601String(), 'nw': nextWhy,
        'run': runningSince?.toIso8601String(), 'needs': needs, 'sum': summary, 'ln': lastNotified?.toIso8601String(),
        'created': created.toIso8601String(), 'updated': updated.toIso8601String(),
        'plan': plan.map((s) => s.toJson()).toList(), 'log': log.map((e) => e.toJson()).toList(),
      };

  static Mission fromJson(Map<String, dynamic> j) {
    final m = Mission(
      id: '${j['id']}',
      kind: '${j['kind'] ?? 'bot'}',
      ownerId: '${j['owner'] ?? ''}',
      goal: '${j['goal'] ?? ''}',
      runsPerDay: (j['rpd'] as num?)?.toInt() ?? defaultRuns,
      tokensPerDay: (j['tpd'] as num?)?.toInt() ?? defaultTokens,
      created: DateTime.tryParse('${j['created']}'),
    )
      ..on = j['on'] != false
      ..status = '${j['status'] ?? 'active'}'
      ..dayKey = '${j['day'] ?? ''}'
      ..runsToday = (j['rt'] as num?)?.toInt() ?? 0
      ..tokensToday = (j['tt'] as num?)?.toInt() ?? 0
      ..runsTotal = (j['rT'] as num?)?.toInt() ?? 0
      ..tokensTotal = (j['tT'] as num?)?.toInt() ?? 0
      ..nextAt = DateTime.tryParse('${j['next']}')
      ..nextWhy = '${j['nw'] ?? ''}'
      ..runningSince = DateTime.tryParse('${j['run']}')
      ..needs = '${j['needs'] ?? ''}'
      ..summary = '${j['sum'] ?? ''}'
      ..lastNotified = DateTime.tryParse('${j['ln']}')
      ..updated = DateTime.tryParse('${j['updated']}') ?? DateTime.now();
    for (final e in (j['plan'] as List? ?? const [])) {
      if (e is Map) m.plan.add(MissionStep.fromJson(Map<String, dynamic>.from(e)));
    }
    for (final e in (j['log'] as List? ?? const [])) {
      if (e is Map) m.log.add(MissionEntry.fromJson(Map<String, dynamic>.from(e)));
    }
    return m;
  }

  /// The readable copy next to the state (the bot reads it with its own file tools; the owner sees it in Files).
  String markdown() {
    final sb = StringBuffer()
      ..writeln('# Mission')
      ..writeln()
      ..writeln(goal)
      ..writeln()
      ..writeln('Status: $status${on ? '' : ' (autonomy off)'} · runs today $runsToday/$runsPerDay · tokens today ${Missions.k(tokensToday)}/${Missions.k(tokensPerDay)}');
    if (nextAt != null) sb.writeln('Next wake: ${Missions.when(nextAt!)}${nextWhy.isEmpty ? '' : ' ($nextWhy)'}');
    if (needs.isNotEmpty) sb.writeln('Waiting on the owner: $needs');
    sb
      ..writeln()
      ..writeln('## Plan');
    if (plan.isEmpty) sb.writeln('(no plan yet)');
    for (final s in plan) {
      sb.writeln('- [${s.status == 'done' ? 'x' : ' '}] ${s.id} (${s.status}${s.who.isEmpty ? '' : ', ${s.who}'}) ${s.text}${s.note.isEmpty ? '' : ' — ${s.note}'}');
    }
    sb
      ..writeln()
      ..writeln('## Log (newest last)');
    for (final e in log.length > 60 ? log.sublist(log.length - 60) : log) {
      sb.writeln('- ${Missions.when(e.at)} ${e.kind}${e.who.isEmpty ? '' : ' (${e.who})'}: ${e.text}');
    }
    return sb.toString();
  }
}

/// The missions on this phone, their files, alarms, guardrails and tools.
class Missions extends ChangeNotifier {
  Missions._();
  static final Missions I = Missions._();

  /// Tests: where the mission folders go (default: SubMac's workspace).
  static String? dirOverride;

  /// Tests: the clock.
  static DateTime Function() clock = DateTime.now;

  static const maxLog = 400;

  /// The shortest and longest gap a mission may set to its next own wake.
  static const minGap = Duration(minutes: 5);
  static const maxGap = Duration(days: 7);

  /// When a run ends with no next wake set (or the app died mid-run), it comes back after this (a long mission never
  /// silently stops). Set before each run starts, replaced by mission_schedule_next.
  static const fallbackGap = Duration(hours: 2);

  /// How long a run's tokens count toward the mission after its wake (a run killed with the app never stays "running").
  static const runWindow = Duration(minutes: 90);

  /// At most one progress notification per mission in this time (summary only).
  static const notifyGap = Duration(minutes: 30);

  /// SharedPreferences key BootReceiver.kt reads to re-arm after a restart (ids of missions switched on).
  static const prefOn = 'missions_on_v1';

  static const names = {'mission_plan', 'mission_update', 'mission_schedule_next', 'mission_done'};

  final List<Mission> missions = [];
  static int _seq = 0;
  bool _loaded = false;
  Future<void>? _loading;

  // ---- hooks the app sets ----

  /// Wake bot [botId] for mission [m] with [instruction]. Returns false when it could not start.
  Future<bool> Function(Mission m, String instruction)? wakeBot;

  /// Start the team's lead on mission [m] with [instruction]. Returns false when it could not start.
  Future<bool> Function(Mission m, String instruction)? wakeTeam;

  /// Show the owner a notification for [m] (a summary line). [needs]: an approval or decision is waiting.
  Future<void> Function(Mission m, String text, {bool needs})? notify;

  /// The display name of a mission's owner (bot or team), for lines and notifications.
  String Function(Mission m)? nameOf;

  /// Lets the app go of the foreground service when nothing runs (a skipped wake).
  Future<void> Function()? idle;

  static String k(int n) => n >= 1000000 ? '${(n / 1000000).toStringAsFixed(1)}M' : n >= 1000 ? '${(n / 1000).round()}k' : '$n';
  static String when(DateTime d) => d.toIso8601String().substring(0, 16).replaceFirst('T', ' ');

  static String alarmId(Mission m) => 'mission|${m.id}';

  Future<String> _root() async => '${dirOverride ?? await AgentTools.workspaceDir()}/missions';

  /// The mission's own folder, relative to the workspace (what the bot sees).
  static String folderOf(Mission m) => 'missions/${m.id}';

  Future<void> init() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final root = Directory(await _root());
      if (await root.exists()) {
        await for (final d in root.list()) {
          if (d is! Directory) continue;
          final f = File('${d.path}/mission.json');
          if (!await f.exists()) continue;
          try {
            final m = Mission.fromJson(Map<String, dynamic>.from(jsonDecode(await f.readAsString()) as Map));
            if (m.ownerId.isEmpty || missions.any((x) => x.id == m.id)) continue;
            missions.add(m);
          } catch (e) {
            debugPrint('mission ${d.path}: $e');
          }
        }
      }
    } catch (e) {
      debugPrint('missions: $e');
    }
    _loaded = true;
    notifyListeners();
  }

  /// Tests: forget everything loaded.
  @visibleForTesting
  void resetForTest() {
    missions.clear();
    _loaded = false;
    _loading = null;
    wakeBot = null;
    wakeTeam = null;
    notify = null;
    nameOf = null;
    idle = null;
  }

  bool get loaded => _loaded;

  Mission? byId(String id) => missions.where((m) => m.id == id).firstOrNull;

  /// The live (not finished) mission of a bot or team; else its latest one.
  Mission? of(String kind, String ownerId) {
    final mine = missions.where((m) => m.kind == kind && m.ownerId == ownerId).toList();
    return mine.where((m) => !m.finished).lastOrNull ?? mine.lastOrNull;
  }

  Mission? liveOf(String kind, String ownerId) => missions.where((m) => m.kind == kind && m.ownerId == ownerId && !m.finished).lastOrNull;

  Future<void> save(Mission m) async {
    m.updated = clock();
    try {
      final dir = Directory('${await _root()}/${m.id}');
      await dir.create(recursive: true);
      final tmp = File('${dir.path}/mission.json.tmp');
      await tmp.writeAsString(jsonEncode(m.toJson()), flush: true);
      await tmp.rename('${dir.path}/mission.json');
      await File('${dir.path}/MISSION.md').writeAsString(m.markdown());
    } catch (e) {
      debugPrint('mission save: $e');
    }
    await _savePref();
    notifyListeners();
  }

  Future<void> _savePref() async {
    try {
      final p = await SharedPreferences.getInstance();
      final on = [for (final m in missions) if (m.on && !m.finished) m.id];
      if (on.isEmpty) {
        await p.remove(prefOn);
      } else {
        await p.setString(prefOn, on.join(','));
      }
    } catch (_) {}
  }

  // ---- the owner's controls ----

  /// Starts (or replaces) the mission of a bot or team. The owner's act: from the UI, or the owner's own words in
  /// chat. The first wake comes in [firstIn] (default 1 minute) so the plan starts without waiting.
  Future<Mission> start(String kind, String ownerId, String goal,
      {int? runsPerDay, int? tokensPerDay, String by = 'owner', Duration firstIn = const Duration(minutes: 1),
      List<String> steps = const []}) async {
    await init();
    final old = liveOf(kind, ownerId);
    if (old != null) {
      old.status = 'stopped';
      old.add('stop', 'Replaced by a new mission.', who: by);
      await disarm(old);
      await save(old);
    }
    final now = clock();
    final m = Mission(
      id: 'm${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${(_seq++).toRadixString(36)}',
      kind: kind,
      ownerId: ownerId,
      goal: goal.trim(),
      runsPerDay: (runsPerDay ?? Mission.defaultRuns).clamp(1, 96).toInt(),
      tokensPerDay: (tokensPerDay ?? Mission.defaultTokens).clamp(10000, 20000000).toInt(),
      created: now,
    );
    m.add('start', 'Mission started: ${m.goal}', who: by);
    final seed = [for (final t in steps.take(30)) t.trim()].where((t) => t.isNotEmpty).toList();
    if (seed.isNotEmpty) {
      var i = 0;
      m.plan.addAll([for (final t in seed) MissionStep('s${++i}', t)]);
    }
    missions.add(m);
    await setNext(m, now.add(firstIn), 'first plan', by: 'app');
    await save(m);
    return m;
  }

  /// The owner's on/off switch. On again: the next wake comes in a minute (or at its planned time when sooner).
  Future<void> setOn(Mission m, bool on) async {
    if (m.on == on) return;
    m.on = on;
    m.add('owner', on ? 'Autonomy switched on.' : 'Autonomy switched off: no more wakes on its own.', who: 'owner');
    if (on) {
      if (m.status == 'stopped') m.status = 'active';
      final soon = clock().add(const Duration(minutes: 1));
      await setNext(m, m.nextAt != null && m.nextAt!.isAfter(clock()) && m.nextAt!.isBefore(soon) ? m.nextAt! : soon, 'switched on', by: 'app');
    } else {
      await disarm(m);
    }
    await save(m);
  }

  /// The stop switch: ends the mission for good (the log stays). A run going on now is stopped by the app.
  Future<void> stop(Mission m, {String by = 'owner'}) async {
    m.status = 'stopped';
    m.on = false;
    m.runningSince = null;
    m.add('stop', 'Stopped${by == 'owner' ? ' by the owner' : ''}.', who: by);
    await disarm(m);
    await save(m);
    onStop?.call(m);
  }

  /// The app stops a run of [m] that is going on now (set by the app).
  void Function(Mission m)? onStop;

  Future<void> setBudget(Mission m, {int? runsPerDay, int? tokensPerDay}) async {
    if (runsPerDay != null) m.runsPerDay = runsPerDay.clamp(1, 96).toInt();
    if (tokensPerDay != null) m.tokensPerDay = tokensPerDay.clamp(10000, 20000000).toInt();
    m.add('owner', 'Budget: ${m.runsPerDay} runs and ${k(m.tokensPerDay)} tokens a day.', who: 'owner');
    await save(m);
  }

  Future<void> setGoal(Mission m, String goal) async {
    if (goal.trim().isEmpty || goal.trim() == m.goal) return;
    m.goal = goal.trim();
    m.add('owner', 'New goal: ${m.goal}', who: 'owner');
    await save(m);
  }

  /// The owner answered a [needs you]: approved (or not), with optional words. The mission wakes soon to act on it.
  Future<void> answer(Mission m, bool approved, {String words = ''}) async {
    if (m.needs.isEmpty && words.trim().isEmpty) return;
    final asked = m.needs;
    m.needs = '';
    if (m.status == 'waiting') m.status = 'active';
    m.add('answer', '${approved ? 'Approved' : 'Declined'}${asked.isEmpty ? '' : ': $asked'}${words.trim().isEmpty ? '' : ' — "${words.trim()}"'}', who: 'owner');
    if (m.on && !m.finished) await setNext(m, clock().add(const Duration(minutes: 1)), 'the owner answered', by: 'app');
    await save(m);
  }

  // ---- alarms ----

  Future<void> setNext(Mission m, DateTime at, String why, {String by = ''}) async {
    m.nextAt = at;
    m.nextWhy = why;
    if (m.on && !m.finished) {
      await SystemBridge.I.scheduleAlarm(alarmId(m), at, label: '${nameOf?.call(m) ?? 'Mission'} · ${_short(m.goal, 40)}');
    }
  }

  Future<void> disarm(Mission m) async {
    m.nextAt = null;
    m.nextWhy = '';
    await SystemBridge.I.cancelAlarm(alarmId(m));
  }

  /// After a start-up (or a restart): every mission that is on gets its alarm again; one whose time passed while the
  /// phone was off wakes in a minute.
  Future<void> armAll() async {
    await init();
    final now = clock();
    for (final m in missions) {
      if (!m.on || m.finished) continue;
      final at = m.nextAt == null || m.nextAt!.isBefore(now) ? now.add(const Duration(minutes: 1)) : m.nextAt!;
      await setNext(m, at, m.nextWhy.isEmpty ? 'resume' : m.nextWhy);
    }
    await _savePref();
  }

  /// A mission alarm fired. Returns true when a run started.
  Future<bool> fire(String alarm) async {
    await init();
    final p = alarm.split('|');
    if (p.length < 2) return false;
    final m = byId(p[1]);
    if (m == null) return false;
    return wake(m, reason: m.nextWhy.isEmpty ? 'scheduled' : m.nextWhy);
  }

  /// Runs mission [m] now, within its guardrails.
  Future<bool> wake(Mission m, {String reason = 'scheduled'}) async {
    final now = clock();
    m.nextAt = null;
    final why = m.blockedReason(now);
    if (why != null) {
      if (m.on && !m.finished) {
        // Out of today's runs or tokens: it waits for tomorrow (one line, then the next day's first wake).
        if (!m.log.any((e) => e.kind == 'budget' && now.difference(e.at) < const Duration(hours: 12))) {
          m.add('budget', 'Paused until tomorrow: $why.');
          await _notify(m, 'Paused until tomorrow: $why.', force: true);
        }
        final t = DateTime(now.year, now.month, now.day + 1, 8);
        await setNext(m, t, 'new day');
      }
      await save(m);
      return false;
    }
    if (m.running) {
      // The last run is still going: come back later instead of starting a second one.
      await setNext(m, now.add(const Duration(minutes: 15)), 'still working', by: 'app');
      await save(m);
      return false;
    }
    final f = m.kind == 'team' ? wakeTeam : wakeBot;
    if (f == null) return false;
    m.runsToday++;
    m.runsTotal++;
    m.runningSince = now;
    m.add('wake', 'Run ${m.runsToday}/${m.runsPerDay} today ($reason).');
    // Never lost: if the run dies with the app, or ends without saying when to come back, it wakes again.
    await setNext(m, now.add(fallbackGap), 'continue (no next wake was set)', by: 'app');
    await save(m);
    bool ok;
    try {
      ok = await f(m, wakeInstruction(m, reason: reason));
    } catch (e) {
      ok = false;
      m.add('skip', 'Could not start: $e');
    }
    if (!ok) {
      m.runningSince = null;
      m.runsToday = (m.runsToday - 1).clamp(0, 1 << 30).toInt();
      await setNext(m, now.add(const Duration(minutes: 20)), 'retry', by: 'app');
      await save(m);
    }
    return ok;
  }

  /// A run of [m] could not finish for a reason that is not its fault (offline, busy models, out of allowance): it does
  /// not count as a run, and comes back by itself (soon, or tomorrow when the allowance is used).
  Future<void> runFailed(Mission m, String failure) async {
    m.runningSince = null;
    m.rollDay(clock());
    m.runsToday = (m.runsToday - 1).clamp(0, 1 << 30).toInt();
    final now = clock();
    final at = failure == 'credit' ? DateTime(now.year, now.month, now.day + 1, 8) : now.add(Duration(minutes: failure == 'offline' ? 10 : 5));
    m.add('skip', 'Run cut short (${failure == 'credit' ? 'today\'s allowance is used' : failure == 'offline' ? 'no connection' : 'the models were busy'}); again at ${when(at)}.');
    if (m.on && !m.finished) await setNext(m, at, 'retry', by: 'app');
    await save(m);
  }

  /// A run of [m] ended (the app calls it with the reply). Notifies a summary when there is news.
  Future<void> runEnded(Mission m, {String reply = ''}) async {
    m.runningSince = null;
    if (!m.finished && m.on && (m.nextAt == null || m.nextAt!.isBefore(clock()))) {
      await setNext(m, clock().add(fallbackGap), 'continue (no next wake was set)', by: 'app');
    }
    final clean = reply.trim();
    if (clean.isNotEmpty && !RegExp(r'^\[no reply\]$', caseSensitive: false).hasMatch(clean)) {
      final line = clean.split('\n').where((l) => l.trim().isNotEmpty && !l.trim().startsWith('@')).take(3).join(' ');
      if (line.isNotEmpty) m.summary = _short(line, 280);
    }
    if (m.summary.isNotEmpty && !m.finished) await _notify(m, m.summary);
    await save(m);
  }

  /// Tokens a bot or a team used: counted toward the live mission while one of its runs goes on (team: any member's
  /// turn in the team while the mission's lead run is live, which over-counts rather than under-counts).
  void addTokens(String kind, String ownerId, int n) {
    if (n <= 0) return;
    final m = liveOf(kind, ownerId);
    if (m == null || !m.running) return;
    m.rollDay(clock());
    m.tokensToday += n;
    m.tokensTotal += n;
    unawaited(save(m));
  }

  /// Tokens the live mission of a bot or team may still use today while one of its runs goes on; null otherwise
  /// (the turn's guard then stops at the bot's own budget only).
  int? leftFor(String kind, String ownerId) {
    final m = liveOf(kind, ownerId);
    if (m == null || !m.running || m.tokensPerDay <= 0) return null;
    m.rollDay(clock());
    final left = m.tokensPerDay - m.tokensToday;
    return left < 0 ? 0 : left;
  }

  /// The smaller of two "tokens left" limits (null = no limit).
  static int? minLeft(int? a, int? b) => a == null ? b : (b == null ? a : (a < b ? a : b));

  /// Is the run of [m] over budget now (the app stops it at its next step)?
  bool overBudget(Mission m) => m.tokensPerDay > 0 && m.tokensToday >= m.tokensPerDay;

  Future<void> _notify(Mission m, String text, {bool needs = false, bool force = false}) async {
    final now = clock();
    if (!needs && !force && m.lastNotified != null && now.difference(m.lastNotified!) < notifyGap) return;
    m.lastNotified = now;
    try {
      await notify?.call(m, _short(text, 300), needs: needs);
    } catch (_) {}
  }

  static String _short(String s, int n) {
    final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length > n ? '${t.substring(0, n - 1)}…' : t;
  }

  // ---- what the model sees ----

  /// The instruction of a mission wake: the goal, the plan, the last log lines, and how to keep going.
  String wakeInstruction(Mission m, {String reason = 'scheduled'}) {
    final team = m.kind == 'team';
    return '[Mission run: $reason]\n${brief(m)}\n\n'
        'You are working on your mission on your own: the owner is not watching and nobody will tell you to start. Decide the next '
        'steps yourself and do the real work now with your tools${team ? ', and hand parts to teammates: a line that starts with a teammate\'s '
            'name ("Nova: …") in the team chat starts their turn; they report back and you are woken' : ''}.\n'
        '- Keep the plan current with mission_plan (steps with status) and log progress with mission_update (short, concrete: what was done, '
        'links, numbers).\n'
        '- Before you stop, call mission_schedule_next with when to come back and why (e.g. in_minutes 60 "check replies"), or mission_done '
        'when the goal is met (or cannot be met: success false with why).\n'
        '- Approvals, spending money, sending things in the owner\'s name to new people, deleting or anything that cannot be undone: do NOT do '
        'it. Call mission_update with needs_you (one clear question) and carry on with other steps; the owner\'s answer comes back to you.\n'
        '- Stay within the budget below; do not create routines for the mission (it wakes itself).\n'
        'Your final reply is a 1-2 line progress summary for the owner (no greeting).';
  }

  /// The mission block of a bot's or team's prompt.
  String brief(Mission m) {
    m.rollDay(clock());
    final sb = StringBuffer()
      ..writeln('# Your mission${m.on ? '' : ' (autonomy is OFF: work on it only when the owner asks)'}')
      ..writeln(m.goal)
      ..writeln('Status: ${m.status}. Budget today: run ${m.runsToday}/${m.runsPerDay}, tokens ${k(m.tokensToday)}/${k(m.tokensPerDay)}. '
          'Files: ${folderOf(m)}/MISSION.md (plan and log), keep mission notes in ${folderOf(m)}/.');
    if (m.needs.isNotEmpty) sb.writeln('Waiting on the owner: ${m.needs} (do not do that step until they answer).');
    if (m.plan.isEmpty) {
      sb.writeln('Plan: none yet. Make one first with mission_plan (3-12 concrete steps).');
    } else {
      sb.writeln('Plan:');
      for (final s in m.plan) {
        sb.writeln('- ${s.id} [${s.status}]${s.who.isEmpty ? '' : ' (${s.who})'} ${s.text}${s.note.isEmpty ? '' : ' — ${_short(s.note, 160)}'}');
      }
    }
    final recent = m.log.length > 12 ? m.log.sublist(m.log.length - 12) : m.log;
    if (recent.isNotEmpty) {
      sb.writeln('Recent log:');
      for (final e in recent) {
        sb.writeln('- ${when(e.at).substring(5)} ${e.kind}${e.who.isEmpty ? '' : ' (${e.who})'}: ${_short(e.text, 200)}');
      }
    }
    return sb.toString().trim();
  }

  // ---- tools ----

  static Map<String, dynamic> _fn(String name, String desc, Map<String, dynamic> props, List<String> req) => {
        'type': 'function',
        'function': {
          'name': name,
          'description': desc,
          'parameters': {'type': 'object', 'properties': props, 'required': req},
        },
      };

  static final List<Map<String, dynamic>> definitions = [
    _fn('mission_plan', 'Your mission plan: set all steps, or update one. "goal" starts a mission; while nobody is watching it is saved as a proposal the owner approves in words.', {
      'goal': {'type': 'string'},
      'steps': {'type': 'array', 'items': {'type': 'string'}},
      'step': {'type': 'string', 'description': 'Id or number.'},
      'status': {'type': 'string', 'enum': ['todo', 'doing', 'done', 'blocked']},
      'who': {'type': 'string', 'description': 'Team: teammate.'},
      'assign': {'type': 'boolean', 'description': 'Team: hand it to who now.'},
      'note': {'type': 'string'},
    }, []),
    _fn('mission_update', 'Log progress, update a step, or needs_you: ask the owner (approval, money, irreversible). Empty: status.', {
      'progress': {'type': 'string'},
      'step': {'type': 'string'},
      'status': {'type': 'string', 'enum': ['todo', 'doing', 'done', 'blocked']},
      'needs_you': {'type': 'string'},
    }, []),
    _fn('mission_schedule_next', 'When to wake you next for the mission (works with the app closed).', {
      'in_minutes': {'type': 'integer'},
      'when': {'type': 'string', 'description': 'Local, e.g. 2026-11-08T09:00.'},
      'why': {'type': 'string'},
    }, []),
    _fn('mission_done', 'End the mission (success false: why it cannot be met). The owner is told.', {
      'summary': {'type': 'string'},
      'success': {'type': 'boolean'},
    }, ['summary']),
  ];

  /// One mission tool call. [m]: the caller's mission (null = none yet). [start]: makes the mission when the call
  /// carries a goal and the owner is present (the app decides); null = starting is not allowed here.
  /// [assign]: a team mission's hand-off of [text] to teammate [who] (posts in the team chat); returns an error line
  /// or null. [who]: the caller's name for the log.
  Future<String> execute(String name, Map<String, dynamic> a,
      {Mission? m, Future<Mission> Function(String goal)? start, Future<String?> Function(String who, String text)? assign, String who = ''}) async {
    String s(String k) => '${a[k] ?? ''}'.trim();
    if (name == 'mission_plan' && s('goal').isNotEmpty && (m == null || m.finished || s('goal') != m.goal)) {
      if (start == null) {
        return 'You cannot start a mission while nobody is watching. Ask the owner to take it on: write them one short '
            'message; when they agree in this chat it can start. '
            '${m == null ? 'You have no mission.' : 'Keep working on: ${m.goal}'}';
      }
      m = await start(s('goal'));
    }
    if (m == null) return 'You have no mission. Propose one to the owner in a short message (or wait for them to ask); its job page has an Autonomy switch.';
    if (m.finished) return 'Your mission is ${m.status}. Nothing to do; the owner can start a new one.';
    final now = clock();
    switch (name) {
      case 'mission_plan':
        final steps = [for (final x in (a['steps'] is List ? a['steps'] as List : const [])) '$x'.trim()]..removeWhere((x) => x.isEmpty);
        if (steps.isNotEmpty) {
          final done = {for (final p in m.plan.where((p) => p.status == 'done')) _key(p.text): p};
          final old = {for (final p in m.plan) _key(p.text): p};
          final next = <MissionStep>[];
          var i = 0;
          for (final t in steps.take(30)) {
            i++;
            final keep = done[_key(t)] ?? old[_key(t)];
            next.add(MissionStep('s$i', t, status: keep?.status ?? 'todo', who: keep?.who ?? '', note: keep?.note ?? ''));
          }
          m.plan
            ..clear()
            ..addAll(next);
          m.add('plan', 'Plan: ${next.length} steps (${next.where((x) => x.status == 'done').length} done).', who: who);
          await save(m);
          return 'Plan saved: ${next.map((x) => '${x.id} ${x.text}').join('; ')}. Work on the first open step now.';
        }
        if (s('step').isEmpty) return 'Error: give "steps" (the whole plan) or "step" with what changes.\n${brief(m)}';
        return _stepUpdate(m, a, who: who, assign: assign);
      case 'mission_update':
        final parts = <String>[];
        if (s('step').isNotEmpty) parts.add(await _stepUpdate(m, a, who: who, assign: assign, save_: false));
        if (s('progress').isNotEmpty) {
          m.add('progress', s('progress'), who: who);
          m.summary = _short(s('progress'), 280);
          parts.add('Logged.');
        }
        if (s('needs_you').isNotEmpty) {
          m.needs = _short(s('needs_you'), 400);
          m.status = 'waiting';
          m.add('needs_you', m.needs, who: who);
          await _notify(m, '[needs you] ${m.needs}', needs: true);
          parts.add('The owner was asked. Do not do that step until they answer; carry on with other steps, and schedule your next wake.');
        }
        if (parts.isEmpty) return brief(m);
        await save(m);
        return parts.join(' ');
      case 'mission_schedule_next':
        DateTime? at;
        final mins = int.tryParse(s('in_minutes')) ?? double.tryParse(s('in_minutes'))?.round();
        if (mins != null) {
          at = now.add(Duration(minutes: mins));
        } else if (s('when').isNotEmpty) {
          at = DateTime.tryParse(s('when').replaceAll(' ', 'T'));
          if (at == null) return 'Error: "when" like 2026-11-08T09:00, or in_minutes.';
        } else {
          return 'Error: give in_minutes (5 to 10080) or "when".';
        }
        var note = '';
        if (at.isBefore(now.add(minGap))) {
          at = now.add(minGap);
          note = ' (the soonest is ${minGap.inMinutes} minutes)';
        }
        if (at.isAfter(now.add(maxGap))) {
          at = now.add(maxGap);
          note = ' (the latest is ${maxGap.inDays} days)';
        }
        final why = s('why').isEmpty ? 'continue' : _short(s('why'), 160);
        await setNext(m, at, why);
        m.add('schedule', 'Next run ${when(at)}: $why', who: who);
        await save(m);
        return 'You will be woken at ${when(at)}$note to: $why. ${m.on ? '' : 'Autonomy is off, so this waits until the owner switches it on.'}';
      case 'mission_done':
        final ok = a['success'] != false && '${a['success']}' != 'false';
        m.status = 'done';
        m.summary = _short(s('summary').isEmpty ? (ok ? 'Mission done.' : 'Mission ended.') : s('summary'), 280);
        m.add('done', '${ok ? 'Done' : 'Ended without reaching the goal'}: ${m.summary}', who: who);
        await disarm(m);
        await _notify(m, '${ok ? 'Mission done' : 'Mission ended'}: ${m.summary}', force: true);
        await save(m);
        return 'Mission closed. Tell the owner the result in your final reply.';
    }
    return 'Error: unknown tool $name.';
  }

  static String _key(String t) => t.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ').trim();

  MissionStep? _find(Mission m, String ref) {
    final r = ref.trim().toLowerCase();
    final n = int.tryParse(r.replaceFirst('s', ''));
    return m.plan.where((p) => p.id.toLowerCase() == r).firstOrNull ??
        (n != null && n >= 1 && n <= m.plan.length ? m.plan[n - 1] : null) ??
        m.plan.where((p) => r.length > 3 && p.text.toLowerCase().contains(r)).firstOrNull;
  }

  Future<String> _stepUpdate(Mission m, Map<String, dynamic> a,
      {String who = '', Future<String?> Function(String who, String text)? assign, bool save_ = true}) async {
    String s(String k) => '${a[k] ?? ''}'.trim();
    final st = _find(m, s('step'));
    if (st == null) return 'Error: no step "${s('step')}". Steps: ${m.plan.map((p) => p.id).join(', ')}.';
    final changes = <String>[];
    if (const {'todo', 'doing', 'done', 'blocked'}.contains(s('status')) && s('status') != st.status) {
      st.status = s('status');
      changes.add(st.status);
    }
    if (s('who').isNotEmpty) st.who = s('who');
    if (s('note').isNotEmpty) st.note = _short(s('note'), 400);
    st.updated = clock();
    var out = 'Step ${st.id} ${changes.isEmpty ? 'updated' : 'is ${changes.last}'}.';
    if (changes.isNotEmpty) m.add('step', '${st.id} ${st.status}: ${st.text}${st.note.isEmpty ? '' : ' — ${st.note}'}', who: who);
    if ((a['assign'] == true || '${a['assign']}' == 'true') && st.who.isNotEmpty) {
      if (assign == null) {
        out += ' Not handed over: only a team mission can assign steps (ask a colleague with bot_ask instead).';
      } else {
        final err = await assign(st.who, '${st.text}${st.note.isEmpty ? '' : ' (${st.note})'}');
        if (err != null) {
          out += ' Not handed over: $err';
        } else {
          if (st.status == 'todo') st.status = 'doing';
          m.add('delegate', '${st.id} → ${st.who}: ${st.text}', who: who);
          out += ' Handed to ${st.who} in the team chat; they start now and report back (you are woken).';
        }
      }
    }
    if (save_) await save(m);
    return out;
  }
}
