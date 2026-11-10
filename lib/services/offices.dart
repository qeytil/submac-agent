import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'bots.dart';
import 'bot_manner.dart';
import 'full_access.dart';
import 'house_rules.dart';
import 'no_reply.dart';
import 'system_bridge.dart';
import 'team_floor.dart';
import 'team_run.dart';
import 'tools.dart';
import 'trust.dart';

/// Offices, shown as Teams since 1.13.28 (plan 5: "a team with a lead"): a team of bots the user puts together, led
/// by one bot they pick as lead (called Chief in the bots' own tools). Its documents live in the team's folder in
/// Files (Teams/<name>), so the owner and the team share one place.
///
/// The Chief plans the work toward the office goal, splits it into tasks, assigns them to teammates,
/// checks progress, unblocks or reassigns, and reports to the owner. Teammates do the work with all their
/// tools in their own chats and post results back to the office. Everything runs on the phone, also
/// with the app in the background, inside the limits the owner sets (work hours, a daily work limit,
/// what needs their approval).

class OfficeTask {
  OfficeTask({
    required this.id,
    required this.title,
    this.detail = '',
    this.owner = '',
    this.reviewer = '',
    this.status = 'todo',
    this.priority = 'normal',
    this.due,
    List<String>? deps,
    this.result = '',
    this.createdBy = 'you',
    DateTime? createdAt,
  })  : deps = deps ?? [],
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = createdAt ?? DateTime.now();

  final String id;
  String title;
  String detail;
  /// Bot id, or '' while nobody owns it.
  String owner;
  /// Bot id that checks the work before it counts as done ('' = no review).
  String reviewer;
  /// proposed | todo | doing | review | blocked | done | cancelled
  String status;
  /// high | normal | low
  String priority;
  DateTime? due;
  final List<String> deps;
  String result;
  String createdBy;
  final DateTime createdAt;
  DateTime updatedAt;
  int attempts = 0;
  DateTime? startedAt;
  /// The Chief's check-ins when the task's owner goes quiet: 0 none, 1 nudged, 2 the user was told. Reset when it acts.
  int nudges = 0;
  DateTime? nudgedAt;

  bool get open => status != 'done' && status != 'cancelled';

  Map<String, dynamic> toJson() => {
        'id': id, 't': title, 'd': detail, 'o': owner, 'r': reviewer, 's': status, 'p': priority,
        'due': due?.toIso8601String(), 'deps': deps, 'res': result, 'by': createdBy,
        'c': createdAt.toIso8601String(), 'u': updatedAt.toIso8601String(), 'a': attempts,
        'st': startedAt?.toIso8601String(),
        if (nudges > 0) 'nz': nudges,
        if (nudgedAt != null) 'na': nudgedAt!.toIso8601String(),
      };

  static OfficeTask fromJson(Map<String, dynamic> j) => OfficeTask(
        id: '${j['id']}',
        title: '${j['t'] ?? ''}',
        detail: '${j['d'] ?? ''}',
        owner: '${j['o'] ?? ''}',
        reviewer: '${j['r'] ?? ''}',
        status: '${j['s'] ?? 'todo'}',
        priority: '${j['p'] ?? 'normal'}',
        due: DateTime.tryParse('${j['due']}'),
        deps: [for (final e in (j['deps'] as List? ?? const [])) '$e'],
        result: '${j['res'] ?? ''}',
        createdBy: '${j['by'] ?? 'you'}',
        createdAt: DateTime.tryParse('${j['c']}'),
      )
        ..updatedAt = DateTime.tryParse('${j['u']}') ?? DateTime.now()
        ..attempts = (j['a'] as num?)?.toInt() ?? 0
        ..startedAt = DateTime.tryParse('${j['st']}')
        ..nudges = (j['nz'] as num?)?.toInt() ?? 0
        ..nudgedAt = DateTime.tryParse('${j['na']}');
}

/// A document in the team's folder: a report a bot shared, or text or a file the owner added.
class OfficeDoc {
  OfficeDoc({required this.id, required this.title, this.body = '', this.file = '', this.fileName = '', required this.author, DateTime? created, DateTime? updated})
      : created = created ?? DateTime.now(),
        updated = updated ?? created ?? DateTime.now();
  final String id;
  String title;
  /// The text (for a file: the text read from it, when it has any).
  String body;
  /// Path of an attached file on the phone ('' for a text doc), and its original name.
  String file;
  String fileName;
  /// The bot's name, or "You".
  String author;
  final DateTime created;
  DateTime updated;
  /// Its file name in the team's folder ('' = not written there yet).
  String saved = '';

  Map<String, dynamic> toJson() => {
        'id': id, 't': title, 'b': body, 'f': file, 'fn': fileName, 'a': author,
        'c': created.toIso8601String(), 'u': updated.toIso8601String(), if (saved.isNotEmpty) 'sv': saved,
      };
  static OfficeDoc fromJson(Map<String, dynamic> j) => OfficeDoc(
      id: '${j['id']}',
      title: '${j['t'] ?? 'Untitled'}',
      body: '${j['b'] ?? ''}',
      file: '${j['f'] ?? ''}',
      fileName: '${j['fn'] ?? ''}',
      author: '${j['a'] ?? 'You'}',
      created: DateTime.tryParse('${j['c']}'),
      updated: DateTime.tryParse('${j['u']}'))
    ..saved = '${j['sv'] ?? ''}';
}

class OfficePost {
  OfficePost({required this.id, required this.from, required this.text, DateTime? at, this.kind = 'chat', this.taskId = '', this.replyTo = ''})
      : at = at ?? DateTime.now();

  /// The post this one answers (a swipe or hold on a message, then Reply), or ''. Shown as a quote; tap jumps to it.
  final String replyTo;
  final String id;
  /// 'you', 'system', or a bot id.
  final String from;
  String text;
  final DateTime at;
  /// chat | update | report | ask | system | answer (a team run's combined answer, with [parts])
  final String kind;
  final String taskId;

  /// A team run's answer: each member's own part (bot id and text), opened on tap.
  final List<({String from, String text})> parts = [];

  Map<String, dynamic> toJson() => {
        'id': id, 'f': from, 't': text, 'at': at.toIso8601String(), 'k': kind, 'tk': taskId,
        if (replyTo.isNotEmpty) 're': replyTo,
        if (parts.isNotEmpty) 'pt': [for (final x in parts) {'f': x.from, 't': x.text}],
      };
  static OfficePost fromJson(Map<String, dynamic> j) => OfficePost(
      id: '${j['id']}',
      from: '${j['f'] ?? 'system'}',
      text: '${j['t'] ?? ''}',
      at: DateTime.tryParse('${j['at']}'),
      kind: '${j['k'] ?? 'chat'}',
      taskId: '${j['tk'] ?? ''}',
      replyTo: '${j['re'] ?? ''}')
    ..parts.addAll([
      for (final e in (j['pt'] as List? ?? const []))
        if (e is Map) (from: '${e['f'] ?? ''}', text: '${e['t'] ?? ''}'),
    ]);
}

/// One piece of office work waiting for a bot. Saved, so work survives the app being closed or the phone restarting.
class OfficeJob {
  OfficeJob(
      {required this.officeId,
      required this.botId,
      required this.kind,
      this.taskId = '',
      this.instruction = '',
      DateTime? at,
      this.after,
      this.tries = 0,
      this.thread = '',
      this.depth = 0,
      this.cause = '',
      this.post = ''})
      : at = at ?? DateTime.now();

  /// How deep in a chain of bot-to-bot turns this job is (TeamReact, owner 2026-11-06): 0 = started by the owner or
  /// the app; a turn a bot's post started is one deeper than the turn that wrote that post.
  final int depth;

  /// Who started it: a bot id (its post), 'you', or ''.
  final String cause;

  /// The team post that started it (react | assign | mention), which the answer links to; ''.
  final String post;

  /// The owner post several bots were asked to answer (owner 2026-11-05: bots answering the same thing at once sent
  /// duplicates). Jobs of one thread run one after another, so each bot sees what the ones before it said and can
  /// stay quiet when it is covered. '' = a job of its own.
  final String thread;
  /// Times this job already failed because the phone was offline or the models were busy.
  final int tries;
  /// Not before this time (a retry after the phone was offline or the provider was busy).
  DateTime? after;
  bool get ready => after == null || !after!.isAfter(DateTime.now());
  final String officeId;
  final String botId;
  /// reply (the owner wrote) | mention (a teammate wrote) | assign (a lead or teammate handed it work in the chat) |
  /// react (a watch fired: "when Nova posts, do this") | task (do a task) | review | chief (plan and check) | digest | unblock
  final String kind;
  final String taskId;
  final String instruction;
  final DateTime at;

  int get rank => switch (kind) { 'reply' => 0, 'mention' || 'assign' || 'react' || 'unblock' || 'mission' => 1, 'review' => 2, 'task' => 3, 'digest' => 4, _ => 5 };

  Map<String, dynamic> toJson() =>
      {'o': officeId, 'b': botId, 'k': kind, 't': taskId, 'i': instruction, 'at': at.toIso8601String(), 'af': after?.toIso8601String(), if (tries > 0) 'tr': tries, if (thread.isNotEmpty) 'th': thread,
        if (depth > 0) 'd': depth, if (cause.isNotEmpty) 'c': cause, if (post.isNotEmpty) 'p': post};
  static OfficeJob fromJson(Map<String, dynamic> j) => OfficeJob(
      officeId: '${j['o']}',
      botId: '${j['b']}',
      kind: '${j['k']}',
      taskId: '${j['t'] ?? ''}',
      instruction: '${j['i'] ?? ''}',
      at: DateTime.tryParse('${j['at']}'),
      after: DateTime.tryParse('${j['af']}'),
      tries: (j['tr'] as num?)?.toInt() ?? 0,
      thread: '${j['th'] ?? ''}',
      depth: (j['d'] as num?)?.toInt() ?? 0,
      cause: '${j['c'] ?? ''}',
      post: '${j['p'] ?? ''}');

  /// The same job again later (a retry), keeping its chain.
  OfficeJob retry({DateTime? after, int? tries}) => OfficeJob(
      officeId: officeId, botId: botId, kind: kind, taskId: taskId, instruction: instruction, at: at, after: after, tries: tries ?? this.tries,
      thread: thread, depth: depth, cause: cause, post: post);
}

/// A number the office works toward ("Orders a week", target 50). The team updates it; the history draws the trend.
class OfficeKpi {
  OfficeKpi(this.name, {this.value = 0, this.target, this.unit = '', DateTime? updated}) : updated = updated ?? DateTime.now();
  String name;
  double value;
  double? target;
  String unit;
  DateTime updated;
  /// Daily values, oldest first (date as yyyy-mm-dd), at most 60.
  final List<MapEntry<String, double>> history = [];

  void set(double v) {
    value = v;
    updated = DateTime.now();
    final day = updated.toIso8601String().substring(0, 10);
    history.removeWhere((e) => e.key == day);
    history.add(MapEntry(day, v));
    while (history.length > 60) {
      history.removeAt(0);
    }
  }

  /// The value a week ago, if known.
  double? get weekAgo {
    final cut = DateTime.now().subtract(const Duration(days: 7)).toIso8601String().substring(0, 10);
    final older = history.where((e) => e.key.compareTo(cut) <= 0).toList();
    return older.isEmpty ? (history.length > 1 ? history.first.value : null) : older.last.value;
  }

  static String fmt(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

  String get line => '$name: ${fmt(value)}${unit.isEmpty ? '' : ' $unit'}${target == null ? '' : ' (target ${fmt(target!)})'}';

  Map<String, dynamic> toJson() => {
        'n': name, 'v': value, 't': target, 'u': unit, 'up': updated.toIso8601String(),
        'h': [for (final e in history) [e.key, e.value]],
      };
  static OfficeKpi fromJson(Map<String, dynamic> j) {
    final k = OfficeKpi('${j['n']}',
        value: (j['v'] as num?)?.toDouble() ?? 0, target: (j['t'] as num?)?.toDouble(), unit: '${j['u'] ?? ''}', updated: DateTime.tryParse('${j['up']}'));
    for (final e in (j['h'] as List? ?? const [])) {
      final l = e as List;
      if (l.length == 2) k.history.add(MapEntry('${l[0]}', (l[1] as num).toDouble()));
    }
    return k;
  }
}

/// The numbers on an office's overview.
class OfficeStats {
  OfficeStats(Office o) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final weekStart = today.subtract(const Duration(days: 6));
    for (final t in o.tasks) {
      switch (t.status) {
        case 'doing':
          doing++;
        case 'review':
          review++;
        case 'blocked':
          blocked++;
        case 'proposed':
          proposed++;
        case 'todo':
          todo++;
      }
      if (t.status != 'done' || t.updatedAt.isBefore(weekStart)) continue;
      doneWeek++;
      if (!t.updatedAt.isBefore(today)) doneToday++;
      final d = DateTime(t.updatedAt.year, t.updatedAt.month, t.updatedAt.day).difference(weekStart).inDays;
      if (d >= 0 && d < 7) byDay[d]++;
      byBot[t.owner] = (byBot[t.owner] ?? 0) + 1;
      hours += t.updatedAt.difference(t.startedAt ?? t.createdAt).inMinutes / 60;
      timed++;
    }
  }
  int doing = 0, review = 0, blocked = 0, proposed = 0, todo = 0, doneWeek = 0, doneToday = 0, timed = 0;
  double hours = 0;
  /// Tasks done on each of the last 7 days, oldest first.
  final List<int> byDay = List.filled(7, 0);
  final Map<String, int> byBot = {};
  int get open => doing + review + blocked + proposed + todo;
  /// Average hours from start to done this week.
  double? get avgHours => timed == 0 ? null : hours / timed;
}

class Office {
  Office({
    required this.id,
    required this.name,
    this.goal = '',
    this.icon = 'work',
    List<String>? members,
    this.chiefId = '',
    this.mode = 'manual',
    this.checkMinutes = 60,
    this.workFrom = 8,
    this.workTo = 22,
    this.digestTime = '19:00',
    this.digestCall = false,
    this.trust = 'ask',
    this.dailyLimit = 15,
    this.rules = '',
  }) : members = members ?? [];

  final String id;
  String name;
  String goal;
  String icon;
  final List<String> members;
  String chiefId;
  /// manual = works only on what the owner asks (default) | away = works on its own | supervised = the owner approves
  /// the Chief's new tasks | paused
  String mode;
  int checkMinutes;
  /// Work hours (local). Equal values = around the clock.
  int workFrom;
  int workTo;
  /// 'HH:MM', or '' for no daily report.
  String digestTime;
  bool digestCall;
  /// ask = risky actions wait for the owner's OK | trusted = they run
  String trust;
  /// Kept for older saved teams and the account copy only: no longer enforced (owner 2026-11-04, no per-day cap on
  /// bot work; the bots' share and each bot's token budget still hold).
  int dailyLimit;
  /// The owner's standing rules: when to escalate, spend limits, tone, what never to do.
  String rules;
  /// The team's folder in Files, relative to Telesia's files (e.g. "Teams/Hodan Coffee"); '' until migrated.
  String folder = '';
  /// 1 = an office from before Teams; 2 = a team (docs copied into its folder).
  int v = 1;

  final List<OfficeTask> tasks = [];
  final List<OfficePost> posts = [];
  final List<String> brief = [];
  final List<String> decisions = [];
  final List<OfficeKpi> kpis = [];
  /// The office's shared shelf of documents, newest last.
  final List<OfficeDoc> docs = [];
  String dayKey = '';
  int runsToday = 0;
  DateTime? lastTick;
  DateTime? lastOwnerPost;

  /// The owner handed the team to the lead ("lead, take over", "I'm away") until they say they are back
  /// (TeamLeadMode, owner 2026-11-05). While false, the lead leads only when the owner has been away a while.
  bool delegated = false;

  /// Standing "when X posts, do Y" instructions (TeamReact, owner 2026-11-06).
  final List<TeamWatch> watches = [];
  int unread = 0;
  /// Work waits until then (the model ran out of credit). Replies to the owner still go out.
  DateTime? holdUntil;

  bool get paused => mode == 'paused';
  /// Only when the owner asks: no timed rounds, no daily report, no restarting work by itself.
  bool get manual => mode == 'manual';
  bool get onHold => holdUntil != null && holdUntil!.isAfter(DateTime.now());

  bool workingNow([DateTime? at]) {
    if (workFrom == workTo) return true;
    final h = (at ?? DateTime.now()).hour;
    return workFrom < workTo ? (h >= workFrom && h < workTo) : (h >= workFrom || h < workTo);
  }

  void rollDay() {
    final n = DateTime.now();
    final k = '${n.year}-${n.month}-${n.day}';
    if (k != dayKey) {
      dayKey = k;
      runsToday = 0;
    }
  }

  int get runsLeft {
    rollDay();
    return (dailyLimit - runsToday).clamp(0, 9999).toInt();
  }

  OfficeTask? task(String id) => tasks.where((t) => t.id == id).firstOrNull;

  Map<String, dynamic> toJson() => {
        'id': id, 'name': name, 'goal': goal, 'icon': icon, 'm': members, 'chief': chiefId, 'mode': mode,
        'every': checkMinutes, 'wf': workFrom, 'wt': workTo, 'dg': digestTime, 'dgc': digestCall, 'trust': trust,
        'lim': dailyLimit, 'rules': rules, 'tasks': tasks.map((e) => e.toJson()).toList(),
        'posts': posts.map((e) => e.toJson()).toList(), 'brief': brief, 'dec': decisions, 'day': dayKey,
        'rt': runsToday, 'lt': lastTick?.toIso8601String(), 'lo': lastOwnerPost?.toIso8601String(), if (delegated) 'dl': true,
        if (watches.isNotEmpty) 'wa': watches.map((w) => w.toJson()).toList(), 'un': unread, 'kpi': kpis.map((k) => k.toJson()).toList(), 'docs': docs.map((d) => d.toJson()).toList(),
        'hold': holdUntil?.toIso8601String(), 'fd': folder, 'v': v,
      };

  static Office fromJson(Map<String, dynamic> j) {
    List<Map<String, dynamic>> l(String k) => [for (final e in (j[k] as List? ?? const [])) Map<String, dynamic>.from(e as Map)];
    final o = Office(
      id: '${j['id']}',
      name: '${j['name'] ?? 'Office'}',
      goal: '${j['goal'] ?? ''}',
      icon: '${j['icon'] ?? 'work'}',
      members: [for (final e in (j['m'] as List? ?? const [])) '$e'],
      chiefId: '${j['chief'] ?? ''}',
      mode: '${j['mode'] ?? 'manual'}' == 'away' ? 'manual' : '${j['mode'] ?? 'manual'}',
      checkMinutes: (j['every'] as num?)?.toInt() ?? 60,
      workFrom: (j['wf'] as num?)?.toInt() ?? 8,
      workTo: (j['wt'] as num?)?.toInt() ?? 22,
      // 'dg' once also carried the hand-over flag (a true overwrote the report time): only a time is a time.
      digestTime: j['dg'] is String ? j['dg'] as String : '19:00',
      digestCall: j['dgc'] == true,
      trust: '${j['trust'] ?? 'ask'}',
      dailyLimit: (j['lim'] as num?)?.toInt() ?? 40,
      rules: '${j['rules'] ?? ''}',
    )
      ..dayKey = '${j['day'] ?? ''}'
      ..runsToday = (j['rt'] as num?)?.toInt() ?? 0
      ..lastTick = DateTime.tryParse('${j['lt']}')
      ..lastOwnerPost = DateTime.tryParse('${j['lo']}')
      ..delegated = j['dl'] == true || j['dg'] == true
      ..unread = (j['un'] as num?)?.toInt() ?? 0
      ..holdUntil = DateTime.tryParse('${j['hold']}')
      ..folder = '${j['fd'] ?? ''}'
      ..v = (j['v'] as num?)?.toInt() ?? 1;
    o.tasks.addAll(l('tasks').map(OfficeTask.fromJson));
    o.posts.addAll(l('posts').map(OfficePost.fromJson));
    o.docs.addAll(l('docs').map(OfficeDoc.fromJson));
    o.watches.addAll(l('wa').map(TeamWatch.fromJson).where((w) => !w.expired() && w.watcher.isNotEmpty));
    o.brief.addAll([for (final e in (j['brief'] as List? ?? const [])) '$e']);
    o.decisions.addAll([for (final e in (j['dec'] as List? ?? const [])) '$e']);
    for (final e in (j['kpi'] as List? ?? const [])) {
      o.kpis.add(OfficeKpi.fromJson(Map<String, dynamic>.from(e as Map)));
    }
    return o;
  }
}

/// Where a team's documents live in Files, and the file name each document gets there. Pure (unit tested).
class TeamFolder {
  static const root = 'Teams';

  /// A name that is safe as a folder or file name on every phone: letters, digits, spaces, dashes and dots.
  static String safe(String name, {String fallback = 'Team'}) {
    var t = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    t = t.replaceAll(RegExp(r'^\.+'), '').trim();
    if (t.length > 60) t = t.substring(0, 60).trim();
    return t.isEmpty ? fallback : t;
  }

  /// "Teams/Hodan Coffee", or "Teams/Hodan Coffee 2" when that folder belongs to another team.
  static String folderFor(String name, Iterable<String> taken) {
    final base = '$root/${safe(name)}';
    final low = {for (final t in taken) t.toLowerCase()};
    if (!low.contains(base.toLowerCase())) return base;
    var n = 2;
    while (low.contains('$base $n'.toLowerCase())) {
      n++;
    }
    return '$base $n';
  }

  /// The file name for a document: its title (".md" for text), or the attached file's own name; numbered when taken.
  static String fileFor(OfficeDoc d, Set<String> used) {
    String name;
    if (d.fileName.isNotEmpty) {
      name = safe(d.fileName, fallback: 'File');
    } else {
      final t = safe(d.title, fallback: 'Note');
      name = t.toLowerCase().endsWith('.md') ? t : '$t.md';
    }
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name, ext = dot > 0 ? name.substring(dot) : '';
    var out = name;
    var n = 2;
    while (used.contains(out.toLowerCase())) {
      out = '$stem ($n)$ext';
      n++;
    }
    used.add(out.toLowerCase());
    return out;
  }

  /// Text files dropped into the folder that the team can read.
  static bool readable(String fileName) =>
      RegExp(r'\.(txt|md|csv|tsv|json|html?|xml|ya?ml|log)$', caseSensitive: false).hasMatch(fileName);
}

/// Something a bot wants to do that needs the owner's OK. Answered in the app (one card: Approve · Edit · Not now) or
/// right from the notification.
class Approval {
  Approval(
      {required this.id,
      required this.botId,
      required this.title,
      this.body = '',
      this.officeId = '',
      this.group = '',
      this.detail = '',
      this.editText,
      this.convId = '',
      this.kind = '',
      DateTime? at})
      : at = at ?? DateTime.now();

  static int _seq = 0;

  /// A new ask's id. It used to be 'a<milliseconds>', so two bots asking in the same millisecond (a team's members
  /// working side by side) got the same id: the second ask replaced the first one's waiter (that bot waited the full
  /// three hours whatever the owner tapped), one tap answered the wrong ask, and the list had two cards with one key.
  static String newId() => 'a${DateTime.now().microsecondsSinceEpoch}-${_seq++}';

  final String id;
  final String botId;
  final String officeId;
  final String title;
  final String body;
  final DateTime at;
  /// Similar asks share a card (plan 5.2): email | whatsapp | send | money | delete | change ('' = change).
  final String group;
  /// Plain lines of what exactly will happen (shown under "Show details").
  final String detail;
  /// The text the owner may change before approving (a message about to be sent), or null.
  final String? editText;
  /// The chat whose run asked ('' = unknown). When that run is stopped, its asks go with it.
  final String convId;
  /// money | send | delete | change ('' = unknown): a money ask is never approved by Full access.
  final String kind;
  bool get isMoney => kind == 'money' || group == 'money';
  /// Asks every time, even with Full access on: money, and changes to how Telesia itself works (kind 'settings').
  bool get alwaysAsks => isMoney || kind == 'settings';
  /// What the owner changed it to ('' = approved as it was). [wantsChange] = they asked for a change first.
  String edited = '';
  bool wantsChange = false;
  /// pending | approved | denied | expired
  String status = 'pending';

  bool get editable => editText != null;

  Map<String, dynamic> toJson() => {
        'id': id, 'b': botId, 'o': officeId, 't': title, 'body': body, 'at': at.toIso8601String(), 's': status,
        if (group.isNotEmpty) 'g': group,
        if (detail.isNotEmpty) 'd': detail,
        if (editText != null) 'e': editText,
        if (convId.isNotEmpty) 'c': convId,
        if (kind.isNotEmpty) 'k': kind,
        if (edited.isNotEmpty) 'ed': edited,
        if (wantsChange) 'wc': true,
      };
  static Approval fromJson(Map<String, dynamic> j) => Approval(
      id: '${j['id']}',
      botId: '${j['b']}',
      officeId: '${j['o'] ?? ''}',
      title: '${j['t'] ?? ''}',
      body: '${j['body'] ?? ''}',
      group: '${j['g'] ?? ''}',
      detail: '${j['d'] ?? ''}',
      editText: j['e'] == null ? null : '${j['e']}',
      convId: '${j['c'] ?? ''}',
      kind: '${j['k'] ?? ''}',
      at: DateTime.tryParse('${j['at']}'))
    ..status = '${j['s'] ?? 'pending'}'
    ..edited = '${j['ed'] ?? ''}'
    ..wantsChange = j['wc'] == true;
}

/// A ready-made office the owner can start in one tap.
class OfficeTemplate {
  const OfficeTemplate(this.id, this.name, this.icon, this.goal, this.pitch, this.chief, this.members, this.rules);
  final String id;
  final String name;
  final String icon;
  final String goal;
  final String pitch;
  /// A built-in bot id, or a description for a new bot (the Chief).
  final String chief;
  /// Built-in bot ids or descriptions of new bots.
  final List<String> members;
  final String rules;

  static const all = <OfficeTemplate>[
    OfficeTemplate('shop', 'Online shop', 'payments', 'Grow my online shop: more visitors, more sales, happy customers.',
        'Marketing, research and customer care for a small online business.',
        'An operations manager named Hodan who runs a small online shop day to day: plans the week, keeps everyone on track, watches sales and customer messages, and reports to the owner in plain words.',
        ['seo', 'researcher', 'A customer care lead named Sagal who drafts friendly replies to customer questions and complaints, tracks open issues and suggests fixes.'],
        'Ask me before sending anything to customers, publishing, or spending money. Message me at once about angry customers or payment problems.'),
    OfficeTemplate('agency', 'Agency', 'campaign', 'Deliver great work for my clients on time and win new ones.',
        'Client projects, proposals, content and research.',
        'A project manager named Bashir who runs a small agency\'s client work: breaks briefs into tasks, sets deadlines, chases progress and writes the client updates for the owner to approve.',
        ['researcher', 'seo', 'A copywriter named Idil who writes clear, persuasive copy: proposals, ads, posts, emails and landing pages.'],
        'Ask me before anything goes to a client. Flag any deadline at risk the same day.'),
    OfficeTemplate('content', 'Content studio', 'edit', 'Publish useful content every week and grow my audience.',
        'Ideas, research, writing and SEO for a blog, channel or page.',
        'An editor-in-chief named Layla who plans a weekly content calendar, assigns research and writing, edits for quality and keeps the schedule.',
        ['researcher', 'seo', 'A writer named Idil who turns research into clear, engaging articles, scripts and posts in the owner\'s voice.'],
        'Ask me before publishing. Send me the weekly plan every Monday.'),
    OfficeTemplate('dev', 'Dev team', 'code', 'Ship my app: plan features, write and review code, keep docs and issues in order.',
        'For builders: specs, code, reviews, research and release notes.',
        'A tech lead named Kaafi who turns goals into small, testable tasks, reviews code for bugs and security, and keeps the roadmap and release notes current.',
        ['researcher', 'A senior software engineer named Deeq who writes clean, tested code, uses the shell and GitHub tools, and explains changes briefly.', 'A QA engineer named Nimco who writes test plans, finds edge cases and checks every change before it counts as done.'],
        'Never push to main or deploy without my OK. Message me when something is blocked for more than a day.'),
    OfficeTemplate('legal', 'Legal desk', 'gavel', 'Keep my business compliant and my contracts safe.',
        'Contract reviews, compliance checks and plain-language summaries.',
        'legal',
        ['researcher', 'A compliance officer named Faisal who tracks deadlines, licences, tax dates and regulations that apply to the owner\'s business.'],
        'Never sign or send anything. Message me about any deadline within 7 days.'),
    OfficeTemplate('study', 'Study group', 'school', 'Help me learn faster and pass my exams.',
        'A teacher, a researcher and a quiz master who keep you on track.',
        'teacher',
        ['researcher', 'A quiz master named Hibo who makes short quizzes and flashcards from what the owner studies and tracks weak topics.'],
        'Call me for a 10-minute lesson when I ask. Keep messages short.'),
  ];
}

class Offices extends ChangeNotifier {
  Offices._();
  static final Offices I = Offices._();

  final List<Office> offices = [];
  final List<OfficeJob> queue = [];
  final List<Approval> approvals = [];
  SharedPreferences? _p;

  /// Set by AppState: runs the queue.
  void Function()? pump;
  /// Set by AppState: a short notification from a bot in an office (with an inline reply).
  Future<void> Function(Office o, Bot b, String text)? notify;

  /// A post that needs the owner ("[needs you]", the lead's question): the team's notification pops up (high
  /// priority, docs/notifications.md). Unset: [notify].
  Future<void> Function(Office o, Bot b, String text)? notifyNeeds;
  /// Set by AppState: true while this bot is working right now (so it is not "quiet").
  bool Function(String botId)? isWorking;
  /// Set by AppState (CB-34): true while a member runs an office job for this office right now.
  bool Function(String officeId)? jobsRunning;
  /// Set by AppState (CB-34): stops the office jobs running for this office right now (their replies are not posted).
  void Function(String officeId)? stopRunning;

  /// When the owner last stopped each office's work, so a reply that lands after the stop is not posted.
  final Map<String, DateTime> _stoppedAt = {};

  /// CB-34: whether office [officeId] has member jobs waiting in the queue or running now (replies started by
  /// [askBot] among them).
  bool jobsFor(String officeId) => queue.any((j) => j.officeId == officeId) || (jobsRunning?.call(officeId) ?? false);

  /// CB-34: drops every queued job of office [officeId] and stops the ones running.
  void stopJobs(String officeId) {
    _stoppedAt[officeId] = DateTime.now();
    final had = queue.length;
    queue.removeWhere((j) => j.officeId == officeId);
    stopRunning?.call(officeId);
    if (queue.length != had) saveSoon();
  }

  /// Whether the owner stopped office [officeId]'s work after [start] (a job that started then posts nothing).
  bool stoppedSince(String officeId, DateTime start) {
    final t = _stoppedAt[officeId];
    return t != null && !t.isBefore(start);
  }

  Office? byId(String id) => offices.where((o) => o.id == id).firstOrNull;
  Iterable<Approval> get pending => approvals.where((a) => a.status == 'pending');
  bool get any => offices.isNotEmpty;

  /// Teams, their job queue and approvals as kept per account at sign-out (R2 item 3). Teams are not in the account.
  Map<String, dynamic> snapshot() => {
        'offices': [for (final o in offices) o.toJson()],
        'queue': [for (final j in queue) j.toJson()],
      };

  /// Brings back a [snapshot] (a team already here with the same id is replaced), then arms the teams again.
  Future<void> adopt(Map<String, dynamic> snap) async {
    _p ??= await SharedPreferences.getInstance();
    for (final e in (snap['offices'] as List? ?? const [])) {
      final o = Office.fromJson(Map<String, dynamic>.from(e as Map));
      offices.removeWhere((x) => x.id == o.id);
      offices.add(o);
    }
    for (final e in (snap['queue'] as List? ?? const [])) {
      queue.add(OfficeJob.fromJson(Map<String, dynamic>.from(e as Map)));
    }
    await save();
    await armAll();
  }

  Future<void> init() async {
    _p = await SharedPreferences.getInstance();
    offices.clear();
    queue.clear();
    approvals.clear();
    try {
      for (final e in jsonDecode(_p!.getString('offices_v1') ?? '[]') as List) {
        offices.add(Office.fromJson(Map<String, dynamic>.from(e as Map)));
      }
      for (final e in jsonDecode(_p!.getString('office_queue_v1') ?? '[]') as List) {
        queue.add(OfficeJob.fromJson(Map<String, dynamic>.from(e as Map)));
      }
      for (final e in jsonDecode(_p!.getString('approvals_v1') ?? '[]') as List) {
        approvals.add(Approval.fromJson(Map<String, dynamic>.from(e as Map)));
      }
    } catch (_) {}
    // An approval nobody answered before the app closed can't be waited on any more.
    for (final a in approvals.where((a) => a.status == 'pending')) {
      a.status = 'expired';
    }
    // 2026-10-21 (owner): teams burned the allowance by working on their own, starting as soon as the app opened.
    // Every existing team moves to "Only when I ask" once; the owner can switch a team back to "Works on its own".
    if (_p!.getBool('offices_manual_v1') != true) {
      for (final o in offices.where((o) => o.mode == 'away')) {
        o.mode = 'manual';
        if (o.dailyLimit == 40) o.dailyLimit = 15;
        post(o, 'system', 'This team now works only when you ask, to save your daily allowance. Change it under Settings > Mode.', kind: 'system');
      }
      await _p!.setBool('offices_manual_v1', true);
    }
    // 2026-10-24 (owner): no team works on its own any more. "Works on its own" is gone; such a team now waits for
    // the owner like any other, and timed rounds or reports still waiting in the queue are dropped.
    for (final o in offices.where((o) => o.mode == 'away')) {
      o.mode = 'manual';
    }
    queue.removeWhere((j) => j.kind == 'chief' && j.instruction.isEmpty || j.kind == 'digest');
    for (final o in offices) {
      if (o.manual) {
        // Nothing restarts by itself when the app opens: unfinished work waits for the owner (Start on the task).
        queue.removeWhere((j) => j.officeId == o.id && j.kind != 'reply');
        var stopped = 0;
        for (final t in o.tasks.where((t) => t.status == 'doing')) {
          t.status = 'todo';
          stopped++;
        }
        if (stopped > 0) {
          post(o, 'system', '$stopped unfinished ${stopped == 1 ? 'task was' : 'tasks were'} stopped when the app closed. Tap Start on a task to continue it.',
              kind: 'system');
        }
        continue;
      }
      // Work that was running when the app closed goes back to the queue.
      for (final t in o.tasks.where((t) => t.status == 'doing')) {
        if (!queue.any((j) => j.taskId == t.id)) queue.add(OfficeJob(officeId: o.id, botId: t.owner, kind: 'task', taskId: t.id));
      }
    }
    await save();
    await armAll();
    unawaited(migrateToTeams().catchError((Object e) => debugPrint('teams: $e')));
  }

  // ---------------------------------------------------------------- teams (plan 5: offices merged into Team)

  /// Offices become teams, in place: each gets a folder in Files and its Docs are copied there, once. Nothing is
  /// deleted: tasks, chat, brief, members, lead and settings stay exactly as they were.
  Future<void> migrateToTeams() async {
    var changed = false;
    for (final o in offices) {
      if (o.folder.isEmpty) {
        o.folder = TeamFolder.folderFor(o.name, [for (final x in offices) if (x != o) x.folder]);
        changed = true;
      }
      if (o.v < 2) {
        try {
          for (final d in o.docs) {
            await _toFolder(o, d);
          }
          o.v = 2;
          changed = true;
        } catch (e) {
          debugPrint('team folder ${o.name}: $e');
        }
      }
    }
    if (changed) await save();
  }

  /// The team's folder on the phone (made when missing).
  Future<Directory> folderOf(Office o) async {
    if (o.folder.isEmpty) o.folder = TeamFolder.folderFor(o.name, [for (final x in offices) if (x != o) x.folder]);
    final d = Directory('${await AgentTools.workspaceDir()}/${o.folder}');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// Writes one document into the team's folder (a text doc as .md, an attached file as a copy).
  Future<void> _toFolder(Office o, OfficeDoc d) async {
    // An attached file that is no longer on the phone stays in the list (its text is still readable), not in the folder.
    if (d.fileName.isNotEmpty && (d.file.isEmpty || !File(d.file).existsSync())) return;
    final dir = await folderOf(o);
    var name = d.saved;
    if (name.isEmpty) {
      final used = <String>{
        for (final x in o.docs) if (x.saved.isNotEmpty) x.saved.toLowerCase(),
        for (final e in dir.listSync()) e.path.split('/').last.toLowerCase(),
      };
      name = TeamFolder.fileFor(d, used);
    }
    final out = File('${dir.path}/$name');
    if (d.file.isNotEmpty && File(d.file).existsSync()) {
      if (File(d.file).absolute.path != out.absolute.path) await File(d.file).copy(out.path);
    } else {
      await out.writeAsString(d.fileName.isNotEmpty ? d.body : '# ${d.title}\n\n${d.author == 'You' ? '' : '_By ${d.author}_\n\n'}${d.body}\n');
    }
    // Only a doc that really is in the folder is tied to it (a doc whose write failed is never dropped by a sync).
    d.saved = name;
  }

  /// Picks up what the owner put in (or removed from) the team's folder in Files, so the team sees the same files.
  Future<void> syncFromFolder(Office o) async {
    final dir = await folderOf(o);
    final files = {
      for (final e in dir.listSync())
        if (e is File && !e.path.split('/').last.startsWith('.')) e.path.split('/').last.toLowerCase(): e,
    };
    var changed = false;
    final before = o.docs.length;
    o.docs.removeWhere((d) => d.saved.isNotEmpty && !files.containsKey(d.saved.toLowerCase()));
    if (o.docs.length != before) changed = true;
    final known = {for (final d in o.docs) if (d.saved.isNotEmpty) d.saved.toLowerCase()};
    for (final e in files.entries) {
      if (known.contains(e.key)) continue;
      final name = e.value.path.split('/').last;
      var text = '';
      try {
        if (TeamFolder.readable(name) && await e.value.length() < 400000) text = await e.value.readAsString();
      } catch (_) {}
      final d = OfficeDoc(
          id: 'd${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${o.docs.length}',
          title: name,
          body: text,
          file: e.value.path,
          fileName: name,
          author: 'You')
        ..saved = name;
      o.docs.add(d);
      changed = true;
    }
    if (changed) saveSoon();
  }

  Timer? _saveTimer;
  Future<void> save() async {
    _saveTimer?.cancel();
    // Keep the last 60, dropping answered ones first: an ask still waiting must never be cut from the list.
    while (approvals.length > 60) {
      final i = approvals.indexWhere((a) => a.status != 'pending');
      if (i < 0) break;
      approvals.removeAt(i);
    }
    await _p?.setString('offices_v1', jsonEncode(offices.map((e) => e.toJson()).toList()));
    await _p?.setString('office_queue_v1', jsonEncode(queue.map((e) => e.toJson()).toList()));
    await _p?.setString('approvals_v1', jsonEncode(approvals.map((e) => e.toJson()).toList()));
    notifyListeners();
  }

  /// Many small changes in a row (a busy office) are written once.
  void saveSoon() {
    notifyListeners();
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), () => unawaited(save()));
  }

  // ---------------------------------------------------------------- alarms

  static String alarmId(Office o, String what) => 'office|${o.id}|$what';

  Future<void> armAll() async {
    for (final o in offices) {
      await arm(o);
    }
  }

  /// Teams never wake on a timer (owner 2026-10-24: "no hardcoded automation… nobody talks for no reason"): no timed
  /// lead rounds, no automatic daily report. Any alarm left from an older version is cleared.
  Future<void> arm(Office o) async {
    await SystemBridge.I.cancelAlarm(alarmId(o, 'tick'));
    await SystemBridge.I.cancelAlarm(alarmId(o, 'digest'));
  }

  Future<void> disarm(Office o) async {
    await SystemBridge.I.cancelAlarm(alarmId(o, 'tick'));
    await SystemBridge.I.cancelAlarm(alarmId(o, 'digest'));
  }

  /// An office alarm fired. Only a retry of work the owner or the lead already gave runs; an old timed round or daily
  /// report alarm just clears itself.
  Future<bool> fire(String alarm) async {
    if (_p == null) await init();
    final p = alarm.split('|');
    if (p.length < 3) return false;
    final o = byId(p[1]);
    if (o == null) return false;
    if (p[2] == 'retry') {
      pump?.call();
      return queue.any((j) => j.officeId == o.id);
    }
    await disarm(o);
    return false;
  }

  // ---------------------------------------------------------------- the Chief's rounds

  /// How long a teammate with an open task may stay quiet: twice the office's check time, 30 to 60 minutes.
  static Duration quietLimit(Office o) => Duration(minutes: (o.checkMinutes * 2).clamp(30, 60).toInt());

  /// The last sign of life from [b] on [t]: the task changing, a post, or anything in the bot's journal.
  DateTime lastActivity(Office o, OfficeTask t, Bot b) {
    var last = t.updatedAt;
    if (t.startedAt != null && t.startedAt!.isAfter(last)) last = t.startedAt!;
    for (final p in o.posts.reversed) {
      if (p.from == b.id) {
        if (p.at.isAfter(last)) last = p.at;
        break;
      }
    }
    if (b.journal.isNotEmpty && b.journal.last.at.isAfter(last)) last = b.journal.last.at;
    return last;
  }

  /// Was: the lead's timed check-in ("@Nova checking in on …") and a note to the owner when a teammate went quiet.
  /// Removed (owner 2026-10-24): canned chatter on a timer. Work that stalls shows on the task list and the status
  /// rings; the owner asks the lead when they want a check. Kept as a no-op for older callers.
  void supervise(Office o) {}

  // ---------------------------------------------------------------- docs (the team folder)

  /// Adds a doc. A doc with the same title from the same author is updated instead of duplicated.
  OfficeDoc addDoc(Office o, {required String title, String body = '', String file = '', String fileName = '', required String author}) {
    final t = title.trim().isEmpty ? (fileName.isEmpty ? 'Untitled' : fileName) : title.trim();
    final b = body.length > 200000 ? '${body.substring(0, 200000)}\n…[trimmed]' : body;
    final same = o.docs.where((d) => d.title.toLowerCase() == t.toLowerCase() && d.author == author && d.file.isEmpty && file.isEmpty).firstOrNull;
    if (same != null) {
      same
        ..body = b
        ..updated = DateTime.now();
      saveSoon();
      unawaited(_toFolder(o, same).catchError((Object e) => debugPrint('team folder: $e')));
      return same;
    }
    final d = OfficeDoc(id: 'd${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}', title: t, body: b, file: file, fileName: fileName, author: author);
    o.docs.add(d);
    while (o.docs.length > 200) {
      o.docs.removeAt(0);
    }
    saveSoon();
    // Plan 5: the team's documents are files in its folder (Files > Teams), where the owner sees them too.
    unawaited(_toFolder(o, d).then((_) => saveSoon()).catchError((Object e) => debugPrint('team folder: $e')));
    return d;
  }

  void removeDoc(Office o, OfficeDoc d) {
    o.docs.remove(d);
    saveSoon();
  }

  OfficeDoc? doc(Office o, String id) {
    final k = id.trim().toLowerCase();
    return o.docs.where((d) => d.id.toLowerCase() == k).firstOrNull ?? o.docs.where((d) => d.title.toLowerCase() == k).firstOrNull;
  }

  static String _when(DateTime t) => t.toIso8601String().substring(0, 16).replaceFirst('T', ' ');

  // ---------------------------------------------------------------- the office itself

  Future<Office> create({required String name, String goal = '', String icon = 'work', required List<String> members, required String chiefId, String rules = ''}) async {
    final o = Office(id: 'o${DateTime.now().millisecondsSinceEpoch}', name: name.trim().isEmpty ? 'Team' : name.trim(), goal: goal.trim(), icon: icon, rules: rules.trim())
      ..members.addAll(members.toSet())
      ..chiefId = chiefId;
    if (chiefId.isNotEmpty && !o.members.contains(chiefId)) o.members.insert(0, chiefId);
    offices.add(o);
    post(o, 'system', 'Team opened. ${_botName(chiefId)} is Chief.', kind: 'system');
    await save();
    await arm(o);
    // A new team never starts work by itself (owner, 2026-10-24): it waits for a task in its chat. Even a team set to
    // work on its own makes its first plan only at its first check, never at the moment it is created.
    // CB-36 (owner, 2026-10-24): teams start right away after the lead's plan; they wait only when the lead must ask.
    post(o, 'system', introText(_botName(chiefId)), kind: 'system');
    return o;
  }

  /// The new team's first line (CB-36): the lead posts a plan and the team starts; it asks only when something is unclear.
  static String introText(String lead) =>
      'The team waits for you: write a task in the chat. $lead posts a plan and the team starts right away. $lead asks you first only if something is unclear.';

  /// A shareable copy of the office: its setup and its team (each bot without its chats or private notes).
  Map<String, dynamic> export(Office o) {
    final team = [for (final id in o.members) Bots.I.byId(id)].whereType<Bot>().toList();
    return {
      'telesia': 'office',
      'v': 1,
      'name': o.name, 'goal': o.goal, 'icon': o.icon, 'rules': o.rules, 'mode': o.mode == 'paused' ? 'manual' : o.mode,
      'check_minutes': o.checkMinutes, 'work_from': o.workFrom, 'work_to': o.workTo, 'digest_time': o.digestTime,
      'digest_call': o.digestCall, 'trust': o.trust, 'daily_limit': o.dailyLimit,
      'brief': o.brief, 'decisions': o.decisions,
      'kpis': [for (final k in o.kpis) {'name': k.name, 'target': k.target, 'unit': k.unit}],
      'chief': team.indexWhere((b) => b.id == o.chiefId),
      'bots': [for (final b in team) b.export()],
    };
  }

  /// An office from a shared copy. Team members you already have (same name and role) are reused, the rest join new.
  Future<Office?> importOffice(Map<String, dynamic> j) async {
    if ('${j['telesia']}' != 'office') return null;
    final ids = <String>[];
    for (final e in (j['bots'] as List? ?? const [])) {
      final m = Map<String, dynamic>.from(e as Map);
      final same = Bots.I.bots
          .where((b) => b.name.toLowerCase() == '${m['name']}'.toLowerCase() && b.role.toLowerCase() == '${m['role']}'.toLowerCase())
          .firstOrNull;
      final b = same ?? await Bots.I.importBot(m);
      if (b != null) ids.add(b.id);
    }
    if (ids.isEmpty) return null;
    final ci = (j['chief'] as num?)?.toInt() ?? 0;
    final o = await create(
        name: '${j['name'] ?? 'Office'}',
        goal: '${j['goal'] ?? ''}',
        icon: '${j['icon'] ?? 'work'}',
        members: ids,
        chiefId: ids[ci >= 0 && ci < ids.length ? ci : 0],
        rules: '${j['rules'] ?? ''}');
    o
      // A copy from someone else waits for the new owner: nothing runs until they ask.
      ..mode = 'manual'
      ..checkMinutes = (j['check_minutes'] as num?)?.toInt().clamp(15, 1440).toInt() ?? o.checkMinutes
      ..workFrom = (j['work_from'] as num?)?.toInt().clamp(0, 23).toInt() ?? o.workFrom
      ..workTo = (j['work_to'] as num?)?.toInt().clamp(0, 24).toInt() ?? o.workTo
      ..digestTime = '${j['digest_time'] ?? o.digestTime}'
      ..digestCall = j['digest_call'] == true
      // A copy from someone else never starts trusted: its risky steps ask the new owner first.
      ..trust = 'ask'
      ..dailyLimit = (j['daily_limit'] as num?)?.toInt().clamp(1, 500).toInt() ?? o.dailyLimit;
    o.brief.addAll([for (final e in (j['brief'] as List? ?? const [])) '$e']);
    o.decisions.addAll([for (final e in (j['decisions'] as List? ?? const [])) '$e']);
    for (final e in (j['kpis'] as List? ?? const [])) {
      final m = Map<String, dynamic>.from(e as Map);
      if ('${m['name'] ?? ''}'.trim().isNotEmpty) o.kpis.add(OfficeKpi('${m['name']}'.trim(), target: (m['target'] as num?)?.toDouble(), unit: '${m['unit'] ?? ''}'));
    }
    await save();
    await arm(o);
    return o;
  }

  /// Closes a team. CB-60: its work stops first (the team run, its member jobs, a waiting plan) and its asks go, so
  /// nothing keeps spending or posting into a team that is gone.
  Future<void> remove(Office o) async {
    TeamRun.I.halt(o);
    TeamRun.I.forget(o.id);
    await expireForOffice(o.id);
    await disarm(o);
    offices.remove(o);
    queue.removeWhere((j) => j.officeId == o.id);
    await save();
  }

  Future<void> setMode(Office o, String mode) async {
    // "Works on its own" was removed (2026-10-24): it reads as "Only when I ask".
    if (mode == 'away') mode = 'manual';
    o.mode = mode;
    if (mode != 'paused') o.holdUntil = null;
    post(o, 'system', switch (mode) {
      'paused' => 'Team paused.',
      'manual' => 'The team works only when you ask.',
      'supervised' => 'Supervised: new tasks from the Chief wait for your OK.',
      _ => 'The team works only when you ask.'
    }, kind: 'system');
    if (mode == 'paused') queue.removeWhere((j) => j.officeId == o.id && j.kind != 'reply');
    if (mode == 'manual') queue.removeWhere((j) => j.officeId == o.id && (j.kind == 'chief' || j.kind == 'digest'));
    await save();
    await arm(o);
    if (mode != 'paused') pump?.call();
  }

  Future<void> setChief(Office o, String botId) async {
    o.chiefId = botId;
    if (!o.members.contains(botId)) o.members.insert(0, botId);
    post(o, 'system', '${_botName(botId)} is now Chief.', kind: 'system');
    await save();
    await arm(o);
  }

  Future<void> addMember(Office o, String botId) async {
    if (o.members.contains(botId)) return;
    o.members.add(botId);
    post(o, 'system', '${_botName(botId)} joined the team.', kind: 'system');
    await save();
  }

  Future<void> removeMember(Office o, String botId) async {
    o.members.remove(botId);
    if (o.chiefId == botId) o.chiefId = o.members.isEmpty ? '' : o.members.first;
    for (final t in o.tasks.where((t) => t.owner == botId && t.open)) {
      t.owner = '';
      t.status = 'todo';
    }
    queue.removeWhere((j) => j.officeId == o.id && j.botId == botId);
    post(o, 'system', '${_botName(botId)} left the team.', kind: 'system');
    await save();
    await arm(o);
  }

  /// Posts [text] in team [o] as [from] ('you', 'system' or a bot id).
  ///
  /// A bot's chat post (owner 2026-11-05, team awareness): "[needs you]" in it makes it a "Needs you" post (kind 'ask')
  /// and tells the owner; one that repeats a recent post (the same bot again, another bot saying the same, a bot
  /// echoing the owner's message) is dropped and the earlier post is returned instead ([dropped] counts them).
  /// [dedupe] false: a structured post that may look like a teammate's on purpose (each member's hand-back note in a
  /// team job, which carries its own part).
  ///
  /// Every bot post can start teammates' turns (TeamReact, owner 2026-11-06): a watch on its author, work it hands
  /// out, a teammate it asks. [depth] and [cause] are the chain of the turn that wrote it (looked up with [jobOf]
  /// when not given); [assigns] false for a structured team job's own posts (its plan runs its members itself);
  /// [react] false starts nothing at all.
  OfficePost post(Office o, String from, String text,
      {String kind = 'chat', String taskId = '', String replyTo = '', bool dedupe = true, int? depth, String? cause, bool assigns = true, bool react = true}) {
    var body = text.trim();
    var k = kind;
    final bot = from != 'you' && from != 'system';
    var needs = false;
    if (bot && (k == 'chat' || k == 'report' || k == 'answer')) {
      final n = NeedsYou.parse(body);
      if (n.needs) {
        body = n.text;
        needs = true;
        if (k == 'chat') k = 'ask';
      }
      if (dedupe && (k == 'chat' || k == 'ask' || k == 'report')) {
        final dup = TeamDedupe.duplicateOf(o, from, body);
        if (dup != null) {
          dropped++;
          debugPrint('team post dropped as a duplicate of ${dup.id}');
          return dup;
        }
      }
    }
    final p = OfficePost(id: _postId(), from: from, text: body, kind: k, taskId: taskId, replyTo: replyTo);
    o.posts.add(p);
    if (needs) {
      final b = Bots.I.byId(from);
      final line = body.split('\n').firstWhere((l) => l.trim().isNotEmpty, orElse: () => body);
      if (b != null) unawaited((notifyNeeds ?? notify)?.call(o, b, line).catchError((Object _) {}));
    }
    while (o.posts.length > 400) {
      o.posts.removeAt(0);
    }
    if (from != 'you' && kind != 'system') o.unread++;
    if (bot && react) {
      final job = jobOf?.call(from, o.id);
      _react(o, p, depth: depth ?? job?.depth ?? 0, cause: cause ?? job?.cause ?? '', causeKind: job?.kind ?? '', assigns: assigns);
    }
    saveSoon();
    return p;
  }

  /// The team's mission block for [b]'s prompt ('' = none; set by the app, Missions).
  String Function(Office o, Bot b)? missionOf;

  /// The office job bot [botId] is doing in team [officeId] right now: its kind and chain (set by the app).
  ({String kind, int depth, String cause})? Function(String botId, String officeId)? jobOf;

  /// Posts that already started a turn for a bot ("post|bot"), so one post wakes each bot once.
  final Set<String> _reacted = {};

  /// Bot-started turns per team, for the burst guard.
  final Map<String, List<DateTime>> _burst = {};
  final Map<String, DateTime> _burstNoted = {};

  /// Bot-started turns the loop guards held back since the app started (diagnostics and tests).
  final List<String> held = [];

  /// Starts the turns post [p] sets off (TeamReact), within the loop guards.
  void _react(Office o, OfficePost p, {required int depth, required String cause, String causeKind = '', bool assigns = true}) {
    final r = TeamReact.of(o, p, depth: depth, cause: cause, causeKind: causeKind, assigns: assigns);
    held.addAll(r.skipped);
    if (r.fired.isNotEmpty) o.watches.removeWhere((w) => r.fired.contains(w.id) || w.expired());
    o.watches.addAll(r.added);
    if (r.triggers.isEmpty) return;
    final now = DateTime.now();
    final recent = (_burst[o.id] ??= [])..removeWhere((t) => now.difference(t) > TeamReact.burstWindow);
    for (final t in r.triggers) {
      if (!_reacted.add('${p.id}|${t.botId}')) continue;
      if (recent.length >= TeamReact.burst) {
        held.add('burst:${t.botId}');
        final noted = _burstNoted[o.id];
        if (noted == null || now.difference(noted) > TeamReact.burstWindow) {
          _burstNoted[o.id] = now;
          post(o, 'system', 'The bots have been passing work back and forth a lot, so automatic replies pause for a few minutes. '
              'Write to them to carry on.', kind: 'system');
        }
        continue;
      }
      recent.add(now);
      enqueue(OfficeJob(officeId: o.id, botId: t.botId, kind: t.kind, instruction: t.instruction, depth: depth + 1, cause: p.from, post: p.id));
    }
    while (_reacted.length > 2000) {
      _reacted.remove(_reacted.first);
    }
  }

  /// The owner's message [text] in team [o] asks a bot to act when a teammate posts ("Amal, analyze Nova's research
  /// once it posts"): the watches are saved and a short system line says so. [addressed]: who the message is to.
  List<TeamWatch> addOwnerWatches(Office o, String text, {List<Bot> addressed = const []}) {
    final ws = TeamReact.fromOwner(o, text, addressed: addressed);
    if (ws.isEmpty) return ws;
    for (final w in ws) {
      o.watches.removeWhere((x) => x.watcher == w.watcher && x.from == w.from && x.by == 'you');
      o.watches.add(w);
    }
    while (o.watches.length > 60) {
      o.watches.removeAt(0);
    }
    final lines = <String>[];
    for (final w in ws) {
      lines.add('${_botName(w.watcher)} will pick this up as soon as ${_botName(w.from)} posts.');
    }
    post(o, 'system', lines.join('\n'), kind: 'system');
    saveSoon();
    return ws;
  }

  /// Bot posts dropped as near-duplicates since the app started (diagnostics and tests).
  int dropped = 0;

  static int _postSeq = 0;
  static String _postId() => 'p${DateTime.now().microsecondsSinceEpoch}${(_postSeq++ % 1000).toString().padLeft(3, '0')}';

  /// The members [text] @mentions, in the order written ("@Nova", or a role without spaces such as "@researcher").
  /// "@team", "@everyone" and "@all" mean every member. An @word that is no member ("@silent", an e-mail address) is
  /// not a mention.
  List<Bot> mentioned(Office o, String text) {
    if (mentionsEveryone(text)) return [for (final id in o.members) Bots.I.byId(id)].whereType<Bot>().toList();
    final out = <Bot>[];
    for (final m in RegExp(r'(^|[^\w@.])@([\w\u0600-\u06FF-]+)').allMatches(text)) {
      final b = _member(o, m.group(2)!);
      if (b != null && !out.contains(b)) out.add(b);
    }
    return out;
  }

  static bool mentionsEveryone(String text) => RegExp(r'(^|\s)@(all|everyone|team)\b', caseSensitive: false).hasMatch(text);

  /// The owner wrote in the team chat. Only the bots in [to] are asked to answer: nobody else wakes, and the lead is
  /// never added by default (owner 2026-10-24: "the team lead answers every time"). Routing is TeamRun's job.
  OfficePost ownerPost(Office o, String text, {List<String> to = const [], String replyTo = ''}) {
    final p = post(o, 'you', text.trim(), replyTo: replyTo);
    o.lastOwnerPost = DateTime.now();
    // Several bots asked about one message answer one after another (a thread), so nobody repeats a teammate.
    for (final id in to) {
      askBot(o, id, text.trim(), replyTo: replyTo, thread: to.length > 1 ? p.id : '');
    }
    return p;
  }

  /// Asks one member to answer the owner's [text] (a full turn with its tools). [replyTo] is the post it answers.
  void askBot(Office o, String botId, String text, {String replyTo = '', String thread = ''}) {
    if (!o.members.contains(botId)) return;
    final quoted = replyTo.isEmpty ? null : o.posts.where((x) => x.id == replyTo).firstOrNull;
    final ctx = quoted == null
        ? ''
        : '\n(The owner is replying to ${quoted.from == 'you' ? 'their own message' : quoted.from == botId ? 'your message' : '${_botName(quoted.from)}\'s message'}: '
            '"${quoted.text.length > 600 ? '${quoted.text.substring(0, 600)}…' : quoted.text}")';
    enqueue(OfficeJob(officeId: o.id, botId: botId, kind: 'reply', instruction: '${text.trim()}$ctx', thread: thread));
  }

  Bot? _member(Office o, String name) {
    final n = name.toLowerCase();
    for (final id in o.members) {
      final b = Bots.I.byId(id);
      if (b != null && (b.name.toLowerCase() == n || b.role.toLowerCase().replaceAll(' ', '') == n)) return b;
    }
    return null;
  }

  String _botName(String id) => Bots.I.byId(id)?.name ?? 'A bot';

  /// The job a bot is doing right now (set by the app), so tools can tell a mention from other work.
  String? Function(String botId)? currentJob;

  void enqueue(OfficeJob j) {
    // One waiting job per bot and task is enough.
    // A reply job is one per message: the same bot asked the same words twice (a double send, a notification reply
    // and the app at once) waits once (owner 2026-11-05: duplicate messages).
    final dup = queue.any((q) =>
        q.officeId == j.officeId &&
        q.botId == j.botId &&
        q.kind == j.kind &&
        q.taskId == j.taskId &&
        // One message, one turn: a bot asked about two different posts answers both (a second teammate's hand-off
        // used to be dropped as a "duplicate" of the first).
        ((j.kind != 'reply' && j.kind != 'mention' && j.kind != 'assign' && j.kind != 'react') || q.instruction == j.instruction));
    if (!dup) queue.add(j);
    queue.sort((a, b) => a.rank != b.rank ? a.rank.compareTo(b.rank) : a.at.compareTo(b.at));
    saveSoon();
    pump?.call();
  }

  /// A task changed: start whatever it unlocked, and ask for a review when one is needed.
  void taskChanged(Office o, OfficeTask t, {String by = ''}) {
    t.updatedAt = DateTime.now();
    // Blocked, in review or closed: a work job still waiting for it must not pull it back to "doing".
    if (t.status != 'todo' && t.status != 'doing') queue.removeWhere((q) => q.taskId == t.id && q.kind == 'task');
    if (t.status == 'done' && t.reviewer.isNotEmpty && t.reviewer != by && !t.result.startsWith('[reviewed]')) {
      t.status = 'review';
      enqueue(OfficeJob(officeId: o.id, botId: t.reviewer, kind: 'review', taskId: t.id));
    }
    if (t.status == 'blocked' && o.chiefId.isNotEmpty && by != o.chiefId) {
      enqueue(OfficeJob(officeId: o.id, botId: o.chiefId, kind: 'unblock', taskId: t.id));
    }
    if (t.status == 'done') {
      for (final next in o.tasks.where((x) => x.status == 'todo' && x.deps.contains(t.id))) {
        startIfReady(o, next);
      }
    }
    if (t.status == 'todo') startIfReady(o, t);
    saveSoon();
  }

  bool depsDone(Office o, OfficeTask t) => t.deps.every((d) => o.task(d)?.status == 'done' || o.task(d) == null);

  void startIfReady(Office o, OfficeTask t) {
    if (o.paused || t.owner.isEmpty || t.status != 'todo' || !depsDone(o, t)) return;
    enqueue(OfficeJob(officeId: o.id, botId: t.owner, kind: 'task', taskId: t.id));
  }

  /// Supervised offices: the owner approves the Chief's proposed tasks.
  void approveProposed(Office o, [String? taskId]) {
    for (final t in o.tasks.where((t) => t.status == 'proposed' && (taskId == null || t.id == taskId))) {
      t.status = 'todo';
      taskChanged(o, t, by: 'you');
    }
    saveSoon();
  }

  // ---------------------------------------------------------------- approvals

  final Map<String, Completer<bool>> _waiting = {};
  bool _watchingFullAccess = false;

  /// Asks the owner and waits (up to [wait]). False when they say no or never answer.
  Future<bool> ask(Approval a, {Duration wait = const Duration(hours: 3)}) async {
    _watchFullAccess();
    // Full access went on while this ask was being made: it goes ahead like any other (money still asks).
    if (FullAccess.I.on && !a.alwaysAsks) {
      a.status = 'approved';
      return true;
    }
    approvals.add(a);
    final c = Completer<bool>();
    _waiting[a.id] = c;
    await save();
    try {
      return await c.future.timeout(wait);
    } on TimeoutException {
      if (a.status == 'pending') a.status = 'expired';
      await save();
      return false;
    } finally {
      _waiting.remove(a.id);
    }
  }

  /// The owner answered. [edited] = the text they changed before approving; [change] = "Edit" on an ask with no text
  /// to change: the bot is told to ask what to change.
  Future<void> answer(String id, bool ok, {String edited = '', bool change = false}) async {
    final a = approvals.where((x) => x.id == id).firstOrNull;
    if (a == null || a.status != 'pending') return;
    a.status = ok ? 'approved' : 'denied';
    if (ok && edited.trim().isNotEmpty && edited.trim() != (a.editText ?? '').trim()) a.edited = edited.trim();
    if (!ok && change) a.wantsChange = true;
    _complete(id, ok);
    await save();
  }

  void _complete(String id, bool ok) {
    final c = _waiting[id];
    if (c != null && !c.isCompleted) c.complete(ok);
  }

  /// Answers every ask in a group at once ("Approve all" / "Not now" on a batched card).
  Future<void> answerAll(Iterable<Approval> list, bool ok) async {
    for (final a in list.toList()) {
      await answer(a.id, ok);
    }
  }

  /// The run in [convId] was stopped: its asks can't be acted on any more, so their cards go now (they used to stay
  /// for three hours, and approving one did nothing) and the stopped run stops waiting.
  Future<void> expireFor(String convId) async {
    if (convId.isEmpty) return;
    var changed = false;
    for (final a in approvals.where((a) => a.status == 'pending' && a.convId == convId).toList()) {
      a.status = 'expired';
      _complete(a.id, false);
      changed = true;
    }
    if (changed) await save();
  }

  /// CB-60: every ask still waiting for office [officeId] goes (the team is closed or stopped).
  Future<void> expireForOffice(String officeId) async {
    if (officeId.isEmpty) return;
    var changed = false;
    for (final a in approvals.where((a) => a.status == 'pending' && a.officeId == officeId).toList()) {
      a.status = 'expired';
      _complete(a.id, false);
      changed = true;
    }
    if (changed) await save();
  }

  /// Signing out (or a reset) removes every ask: whoever still waits on one hears "no" instead of waiting for hours.
  void clearApprovals() {
    for (final id in _waiting.keys.toList()) {
      _complete(id, false);
    }
    approvals.clear();
  }

  /// Full access just went on ("Allow always" on a card, or Settings): every ask already waiting goes ahead at once,
  /// the way it would have if it were asked now. Payments still wait for their own tap.
  Future<void> releaseForFullAccess() async {
    var changed = false;
    for (final a in approvals.where((a) => a.status == 'pending' && !a.alwaysAsks).toList()) {
      a.status = 'approved';
      _complete(a.id, true);
      changed = true;
    }
    if (changed) await save();
  }

  void _watchFullAccess() {
    if (_watchingFullAccess) return;
    _watchingFullAccess = true;
    FullAccess.I.addListener(() {
      if (FullAccess.I.on) unawaited(releaseForFullAccess());
    });
  }

  // ---------------------------------------------------------------- what a bot sees in the office

  String promptFor(Office o, Bot b, OfficeJob job) => '${teamStablePromptOf(o, b)}\n\n${teamLivePromptOf(o, b)}'.trim();

  /// The part of a teammate's wake text that only changes when the owner changes the team (who is on it, the lead,
  /// the goal, the rules): sent first, so it stays the same from job to job.
  String teamStablePromptOf(Office o, Bot b) {
    final lead = Bots.I.byId(o.chiefId);
    final isLead = b.id == o.chiefId;
    final sb = StringBuffer()
      ..writeln('# Your team: ${o.name}')
      ..writeln('Goal: ${o.goal.isEmpty ? '(not set yet: ask the owner in one short post)' : o.goal}')
      ..writeln('You are ${b.name}, ${b.role.isEmpty ? 'colleague' : b.role}, ${isLead ? 'the lead' : 'a member'}; teammates are other people.')
      ..writeln(isLead
          ? 'You are the lead (Chief in your tools). When leading: plan toward the goal, give each task to the teammate whose role '
              'fits (office_board add with owner), check progress, unblock, report to the owner.'
          : 'Your lead is ${lead?.name ?? 'not set'}. Own your tasks: do them fully, then office_board update to done with the result '
              '(links, numbers, file names), or to blocked with the exact reason.');
    if (isLead) sb.writeln(TeamLeadMode.leadInstruction(o));
    sb.writeln(isLead ? BotManner.leadLine : BotManner.memberLine(lead?.name ?? 'your lead'));
    sb.writeln('\n# Teammates');
    for (final id in o.members) {
      final m = Bots.I.byId(id);
      if (m == null) continue;
      sb.writeln('- ${m.name}${id == o.chiefId ? ' (lead)' : ''}: ${m.role.isEmpty ? 'colleague' : m.role}${id == b.id ? ' (you)' : ''}');
    }
    if (o.rules.trim().isNotEmpty) {
      sb
        ..writeln('\n# The owner\'s rules (always follow them)')
        ..writeln(o.rules.trim());
    }
    sb
      ..writeln('\n# How the team works')
      ..writeln('- One shared task list (office_board). Check it before you start; never redo work that is on it.')
      ..writeln('- Team chat: your final reply is posted for you; office_post only for an extra message mid-work, never the same reply. '
          '@Name wakes that teammate. Notes and decisions: office_brief. Numbers: office_kpi (real values only).')
      ..writeln('- Team folder: Files > ${o.folder.isEmpty ? 'Teams/${o.name}' : o.folder}, shared with the owner. Anything long (research, '
          'plan, draft, list) goes there in full with docs_share; in chat and task results write 2 to 4 lines and say it is in the team '
          'folder. Before you research, check docs_list and docs_read: a teammate may have it.')
      ..writeln('- You act on your own; there is no approval card. '
          '${(o.trust == 'trusted' || b.level == BotTrust.levelTrusted) ? 'Ask the owner in one short line ("can I ...?") before money or deleting.' : 'Ask the owner in one short line ("can I ...?") before money, sending, deleting or a big change.'} '
          'Routine work asks nothing.')
      ..writeln(isLead
          ? '- Reach the owner with office_ask_owner only when their rules say so or you truly need them.'
          : '- Stuck: ask your lead in the team chat. Only a decision or an action that is the owner\'s alone goes to them, '
              'marked [needs you].')
      ..writeln('- Never say something is done or sent unless a tool result shows it.')
      ..writeln('- Speak when you are spoken to or have something the team needs. Like a person in a work chat, you can stay '
          'quiet; nobody needs to confirm, echo or narrate.')
      ..writeln(HouseRules.teamLine);
    return sb.toString().trim();
  }

  /// What changes while the team works (time, task list, chat, docs): sent after the stable part.
  String teamLivePromptOf(Office o, Bot b) {
    final now = DateTime.now();
    final sb = StringBuffer()
      ..writeln('# Right now')
      ..writeln('${_when(now)} · ${switch (o.mode) { 'supervised' => 'supervised (new tasks from the lead wait for the owner\'s OK)', 'paused' => 'paused', 'manual' => 'on request: do only what the owner asked, add no extra tasks, and stop when it is done', _ => 'away mode (the team works on its own)' }}');
    final busy = [
      for (final id in o.members)
        if (o.tasks.where((t) => t.owner == id && t.status == 'doing').map((t) => t.title).firstOrNull case final d?) '${_botName(id)}: "$d"'
    ];
    if (busy.isNotEmpty) sb.writeln('Working on: ${busy.join('; ')}');
    // The team's mission (owner 2026-11-07): the lead sees the plan and log; members see the goal, so their part fits.
    final mission = missionOf?.call(o, b) ?? '';
    if (mission.isNotEmpty) sb.writeln('\n$mission');
    if (o.brief.isNotEmpty || o.decisions.isNotEmpty) {
      sb.writeln('\n# Brief and decisions');
      for (final x in o.brief.reversed.take(25).toList().reversed) {
        sb.writeln('- $x');
      }
      for (final x in o.decisions.reversed.take(15).toList().reversed) {
        sb.writeln('- Decided: $x');
      }
    }
    if (o.kpis.isNotEmpty) {
      sb.writeln('\n# Numbers');
      for (final k in o.kpis) {
        sb.writeln('- ${k.line}');
      }
    }
    sb.writeln('\n# Task list');
    final open = o.tasks.where((t) => t.open).toList();
    if (open.isEmpty) {
      sb.writeln('Empty.');
    } else {
      for (final t in open.take(40)) {
        sb.writeln('- [${t.id}] ${t.status}${t.priority == 'high' ? ' HIGH' : ''} · ${t.owner.isEmpty ? 'unassigned' : _botName(t.owner)}'
            '${t.reviewer.isEmpty ? '' : ' (review: ${_botName(t.reviewer)})'}'
            '${t.due == null ? '' : ' · due ${_when(t.due!)}'}'
            '${t.deps.isEmpty ? '' : ' · after ${t.deps.join(', ')}'}: ${t.title}'
            '${t.result.isEmpty ? '' : ' — ${t.result.length > 160 ? '${t.result.substring(0, 160)}…' : t.result}'}');
      }
    }
    final done = o.tasks.where((t) => t.status == 'done').toList();
    if (done.isNotEmpty) {
      sb.writeln('Recently done: ${done.reversed.take(6).map((t) => '[${t.id}] ${t.title}').join('; ')}');
    }
    // Every message labelled with who wrote it (owner, lead, member and role, system, "you"), to whom, what it replies
    // to and when, then the situation (owner 2026-11-05: bots confused who they are and spoke without reading the room).
    if (o.posts.isNotEmpty) {
      sb.writeln('\n# Team chat (latest; oldest first)');
      sb.writeln(TeamTranscript.lines(o, selfId: b.id, max: 18).join('\n'));
    }
    sb.writeln('\n# The situation');
    for (final s in TeamTranscript.situation(o, selfId: b.id, working: [
      for (final id in o.members)
        if (id != b.id && (isWorking?.call(id) ?? false)) _botName(id)
    ])) {
      sb.writeln('- $s');
    }
    if (o.docs.isNotEmpty) {
      sb.writeln('\n# Team folder (docs_read)');
      for (final d in o.docs.reversed.take(10)) {
        sb.writeln('- ${d.id}: "${d.title}" by ${d.author}, ${_when(d.updated)}');
      }
    }
    return sb.toString().trim();
  }

  /// What a job asks the bot to do now.
  String jobText(Office o, Bot b, OfficeJob job) {
    final t = job.taskId.isEmpty ? null : o.task(job.taskId);
    const end = '\n\nYour final reply goes in the team chat as you: results first, under 500 characters (long work: docs_share).';
    const mayPass = '\n${NoReply.rule}';
    const check = '\nBefore you answer, read the team chat and the situation above: who wrote what, who it was for, and whether a teammate '
        'already answered. ${NeedsYou.rule}';
    switch (job.kind) {
      case 'reply':
        // The owner addressed this bot (an @mention, a reply to its message, or the team picked it to answer): it answers,
        // the way a colleague answers when spoken to. Nobody else was asked, unless it is a thread (several were asked
        // about one message): then it answers after the ones before it and may stay quiet when they covered it.
        if (job.thread.isNotEmpty) {
          final before = threadAnswers(o, job.thread, except: b.id);
          return 'The owner wrote to several of you in the team chat: "${job.instruction}"\n'
              'Answer only for your own role (${b.role.isEmpty ? 'your part' : b.role}). '
              '${before.isEmpty ? 'You answer first.' : 'Already answered by ${before.join(', ')} (see the chat): add only what is new from your role; '
                  'if they covered it, reply with exactly ${NoReply.token}.'} Never repeat a teammate or the owner\'s words.$check$end';
        }
        final waits = [
          for (final w in o.watches)
            if (w.watcher == b.id && w.by == 'you' && !w.expired() && job.instruction.startsWith(w.instruction)) _botName(w.from)
        ];
        final later = waits.isEmpty
            ? ''
            : 'Part of this is for later: you will be woken by yourself as soon as ${waits.join(' or ')} posts, and do it then (no need to '
                'wait, check or ask). Do now only what can be done now; if ${waits.join(' or ')}\'s post is already in the chat, do it now. '
                'Otherwise say in one short line that you will, nothing more.\n';
        return 'The owner wrote to you in the team chat: "${job.instruction}"\n$later'
            'They are talking to you, so answer them yourself, in your own role. If they asked for work, do it with your tools. '
            'Do not answer for teammates, do not repeat the owner\'s words, and do not hand the work around unless they asked you to '
            'coordinate it.$check$end';
      case 'mention':
        return '${job.instruction}\n'
            'This is a teammate, not the owner. Answer in one short post only if it needs you, and do a small thing it asks now. '
            'Do not start new work beyond it and do not @mention anyone back just to acknowledge.$end$mayPass';
      case 'assign':
        // A lead (or a teammate) handed this bot work in the chat: it starts now, by itself (owner 2026-11-06: assigned
        // bots used to wait until the owner told each one "start working").
        return '${job.instruction}\n'
            'This is your assignment from a teammate, not the owner, and it starts now: nobody will tell you to begin. Do the real '
            'work with your tools, then report back in the team chat: the result first (links, numbers, file names; long work goes in '
            'the team folder with docs_share), addressed to whoever handed it to you. Do only your own part; do not hand it on or '
            'restate it. If the message was not really asking you for anything, reply with exactly ${NoReply.token}.$check$end';
      case 'mission':
        // The team's mission woke its lead (owner 2026-11-07): the lead decides and hands out the work by itself.
        return '${job.instruction}\n'
            'You lead this mission for the team. Hand parts to teammates with lines that start with their name ("Nova: …") in your posts '
            'or office_post: that starts their turn now and they report back (you are woken by their reports). Do lead work yourself only '
            'when nobody else fits. Keep the mission plan (mission_plan with "who") and log (mission_update) current, then '
            'mission_schedule_next or mission_done.$end';
      case 'react':
        // A watch fired: the teammate this bot was waiting for just posted (owner 2026-11-06).
        return '${job.instruction}\n'
            'Take your turn now, by yourself: do what was asked with what they posted (open the files or docs they mention), then post '
            'your result in the team chat. If their post does not have what you were waiting for yet, reply with exactly '
            '${NoReply.token} (you stay on the lookout only if you call office_watch again).$check$end';
      case 'task':
        final resume = (t?.attempts ?? 0) > 1 ? 'You started this before and were interrupted: continue from your chat above, do not start over.\n' : '';
        return '${job.instruction.isEmpty ? '' : '${job.instruction}\n'}${resume}Your task: [${t?.id}] ${t?.title}\n${t?.detail ?? ''}\n'
            'Set it to doing, do the real work with your tools, then set it to done with the result, or blocked with the reason.$end';
      case 'review':
        return 'Review [${t?.id}] "${t?.title}" by ${_botName(t?.owner ?? '')}.\nResult: ${t?.result}\n'
            'Open the files or links. Good: office_board update to done with a result starting "[reviewed] " plus one line of feedback. '
            'Not good: back to todo with what to fix in "note".$end';
      case 'unblock':
        return '[${t?.id}] "${t?.title}" is blocked: ${t?.result}\nUnblock it: answer it, reassign it or split it. '
            'Only if the owner alone can help, use office_ask_owner.$end';
      case 'digest':
        if (job.instruction == 'weekly') {
          final st = OfficeStats(o);
          return 'Write the weekly review. First update every number you can measure with office_kpi'
              '${o.kpis.isEmpty ? ' (no numbers yet: add 1 to 3 that show progress toward the goal)' : ''}. '
              'Then at most 8 short lines: wins with links, each number against its target and last week, what slipped and why, '
              'and next week\'s 3 priorities (also put them on the task list). Finished this week: ${st.doneWeek}; blocked: ${st.blocked}.$end';
        }
        return 'Write today\'s report: done (with links), in progress, blocked, and any decision only the owner can make. '
            'At most 6 short lines. Then plan tomorrow on the task list if needed.$end';
      default:
        return '${job.instruction.isEmpty ? 'Regular check.' : job.instruction}\n'
            '${o.manual ? 'Assign unowned tasks and chase anything stuck. Add no new tasks: this team works only on what the owner asked. ' : 'Assign unowned tasks, chase anything in doing for over 2 hours, and if nothing is open add the next 1 to 5 useful tasks '
                'toward the goal (real work, never busywork). '}'
            '${o.mode == 'supervised' ? 'New tasks wait for the owner\'s OK. ' : ''}'
            'Reach the owner only as their rules say.$end$mayPass';
    }
  }

  /// The bots that already answered thread [thread] (the owner post several bots were asked about), by name.
  List<String> threadAnswers(Office o, String thread, {String except = ''}) {
    final i = o.posts.indexWhere((p) => p.id == thread);
    if (i < 0) return const [];
    final out = <String>[];
    for (final p in o.posts.sublist(i + 1)) {
      if (p.from == 'you' || p.from == 'system' || p.from == except || p.kind == 'system') continue;
      final n = _botName(p.from);
      if (!out.contains(n)) out.add(n);
    }
    return out;
  }

  // ---------------------------------------------------------------- office tools

  static const names = {'office_board', 'office_post', 'office_watch', 'office_brief', 'office_ask_owner', 'office_kpi', 'docs_share', 'docs_list', 'docs_read'};

  static Map<String, dynamic> _fn(String name, String desc, Map<String, dynamic> props, List<String> req) => {
        'type': 'function',
        'function': {
          'name': name,
          'description': desc,
          'parameters': {'type': 'object', 'properties': props, 'required': req},
        },
      };

  static final List<Map<String, dynamic>> definitions = [
    _fn('office_board', 'The office task board. add a task (with owner = teammate name), update a task\'s status or result, assign it, or list the board.', {
      'action': {'type': 'string', 'enum': ['add', 'update', 'assign', 'list']},
      'id': {'type': 'string'},
      'title': {'type': 'string'},
      'detail': {'type': 'string', 'description': 'What exactly to deliver, and how to know it is done.'},
      'owner': {'type': 'string', 'description': 'Teammate name.'},
      'reviewer': {'type': 'string', 'description': 'Teammate who checks the work before it counts as done (optional).'},
      'status': {'type': 'string', 'enum': ['todo', 'doing', 'review', 'blocked', 'done', 'cancelled']},
      'priority': {'type': 'string', 'enum': ['high', 'normal', 'low']},
      'due': {'type': 'string', 'description': 'Local date and time, e.g. 2026-10-18T17:00.'},
      'after': {'type': 'string', 'description': 'Task ids this one waits for, comma separated.'},
      'result': {'type': 'string', 'description': 'What was delivered (links, numbers, file paths), or why it is blocked.'},
      'note': {'type': 'string'},
    }, ['action']),
    _fn('office_post', 'Post a message in the office chat. Mention a teammate as @Name (or start a line with "Name:") to start their turn.', {
      'text': {'type': 'string'},
    }, ['text']),
    _fn('office_watch', 'When teammate "from" next posts in the team chat, you are woken to do "do". Use instead of waiting.', {
      'from': {'type': 'string'},
      'do': {'type': 'string'},
    }, ['from', 'do']),
    _fn('office_brief', 'Shared office memory everyone sees: add a brief note (facts, links, preferences) or record a decision; or forget a line.', {
      'action': {'type': 'string', 'enum': ['note', 'decision', 'forget']},
      'text': {'type': 'string'},
    }, ['action', 'text']),
    _fn('office_kpi', 'The office\'s numbers (KPIs) on its overview: set a value you measured (real numbers only, never guesses), '
        'add a new number with a target (Chief), or remove one (Chief).', {
      'action': {'type': 'string', 'enum': ['set', 'add', 'remove']},
      'name': {'type': 'string', 'description': 'e.g. Orders this week, Followers, Pages ranking top 10'},
      'value': {'type': 'number'},
      'target': {'type': 'number'},
      'unit': {'type': 'string', 'description': 'e.g. orders, \$, %'},
    }, ['action', 'name']),
    _fn('office_ask_owner', 'Lead (Chief) only: reach the owner now (a message on their phone they can answer from the notification).', {
      'text': {'type': 'string', 'description': 'One short, specific message or question.'},
    }, ['text']),
    _fn('docs_share', 'Put a full document in the team folder (reports, research, drafts, lists). Same title again = update it.', {
      'title': {'type': 'string'},
      'content': {'type': 'string', 'description': 'The full text, in markdown.'},
    }, ['title', 'content']),
    _fn('docs_list', 'List the docs in the team folder (title, author, time), optionally only those matching words.', {
      'query': {'type': 'string'},
    }, []),
    _fn('docs_read', 'Read one doc in the team folder by its id or exact title. Long docs come in parts: pass offset to read on.', {
      'id': {'type': 'string'},
      'offset': {'type': 'integer'},
    }, ['id']),
  ];

  /// [job]: the office job this call is part of (reply | task | mention ...), when the caller knows it.
  Future<String> execute(String name, Map<String, dynamic> a, Office o, Bot b, {String? job}) async {
    String s(String k) => '${a[k] ?? ''}'.trim();
    final isChief = b.id == o.chiefId;
    switch (name) {
      case 'office_board':
        switch (s('action')) {
          case 'add':
            if (s('title').isEmpty) return 'Error: give the task a title.';
            if (o.tasks.where((t) => t.open).any((t) => t.title.toLowerCase() == s('title').toLowerCase())) {
              return 'Already on the board.';
            }
            var owner = s('owner').isEmpty ? '' : (_member(o, s('owner'))?.id ?? '');
            if (s('owner').isNotEmpty && owner.isEmpty) return 'Error: no teammate called "${s('owner')}". Team: ${o.members.map(_botName).join(', ')}.';
            if (!isChief && owner.isNotEmpty && owner != b.id) owner = ''; // only the Chief assigns others; the Chief picks it up
            final t = OfficeTask(
              id: 'k${(DateTime.now().millisecondsSinceEpoch % 100000).toString().padLeft(5, '0')}',
              title: s('title'),
              detail: s('detail'),
              owner: owner,
              reviewer: s('reviewer').isEmpty ? '' : (_member(o, s('reviewer'))?.id ?? ''),
              priority: s('priority').isEmpty ? 'normal' : s('priority'),
              due: DateTime.tryParse(s('due').replaceAll(' ', 'T')),
              deps: [for (final d in s('after').split(',')) if (d.trim().isNotEmpty) d.trim()],
              createdBy: b.id,
              status: (isChief && o.mode == 'supervised') ? 'proposed' : 'todo',
            );
            o.tasks.add(t);
            _trim(o);
            post(o, b.id, '${t.status == 'proposed' ? 'Proposed' : 'New task'}: ${t.title}${t.owner.isEmpty ? '' : ' → ${_botName(t.owner)}'}', kind: 'update', taskId: t.id);
            if (t.status == 'todo') startIfReady(o, t);
            if (!isChief && o.chiefId.isNotEmpty && t.owner.isEmpty) {
              enqueue(OfficeJob(officeId: o.id, botId: o.chiefId, kind: 'chief', instruction: '${b.name} added a task that needs an owner: [${t.id}] ${t.title}.'));
            }
            await save();
            return 'Added [${t.id}] (${t.status})${t.owner.isEmpty ? ', unassigned' : ' for ${_botName(t.owner)}'}.';
          case 'assign':
            final t = o.task(s('id'));
            if (t == null) return 'Error: no task ${s('id')}.';
            if (!isChief) return 'Error: only the Chief assigns tasks. Post to the Chief instead.';
            final who = _member(o, s('owner'));
            if (who == null) return 'Error: no teammate called "${s('owner')}".';
            t.owner = who.id;
            if (t.status == 'blocked') t.status = 'todo';
            post(o, b.id, '[${t.id}] ${t.title} → ${who.name}', kind: 'update', taskId: t.id);
            taskChanged(o, t, by: b.id);
            await save();
            return 'Assigned to ${who.name}.';
          case 'update':
            final t = o.task(s('id')) ??
                o.tasks.where((x) => s('title').isNotEmpty && x.title.toLowerCase().contains(s('title').toLowerCase())).firstOrNull;
            if (t == null) return 'Error: no task ${s('id')}.';
            if (!isChief && t.owner != b.id && t.reviewer != b.id) return 'Error: [${t.id}] belongs to ${_botName(t.owner)}.';
            final before = t.status;
            if (s('status').isNotEmpty) t.status = s('status');
            if (s('result').isNotEmpty) t.result = s('result');
            if (s('note').isNotEmpty) t.detail = '${t.detail}\nNote: ${s('note')}'.trim();
            if (s('priority').isNotEmpty) t.priority = s('priority');
            if (s('due').isNotEmpty) t.due = DateTime.tryParse(s('due').replaceAll(' ', 'T')) ?? t.due;
            if (t.status == 'doing' && before != 'doing') t.startedAt = DateTime.now();
            if (t.status != before && (t.status == 'done' || t.status == 'blocked')) {
              post(o, b.id, '${t.status == 'done' ? 'Done' : 'Blocked'}: ${t.title}${t.result.isEmpty ? '' : '\n${t.result.length > 300 ? '${t.result.substring(0, 300)}…' : t.result}'}',
                  kind: 'update', taskId: t.id);
            }
            taskChanged(o, t, by: b.id);
            await save();
            return 'Updated [${t.id}] to ${t.status}.';
          default:
            final open = o.tasks.where((t) => t.open);
            return open.isEmpty
                ? 'The board is empty.'
                : open.map((t) => '[${t.id}] ${t.status} · ${t.owner.isEmpty ? 'unassigned' : _botName(t.owner)}: ${t.title}').join('\n');
        }
      case 'office_post':
        if (s('text').isEmpty) return 'Error: nothing to post.';
        // Teammates it names or @mentions, and anyone waiting for this bot's post, take their turn by themselves
        // (TeamReact, owner 2026-11-06), within the loop guards (chain depth, no ping-pong, burst).
        final p = post(o, b.id, s('text'));
        final woke = queue.where((j) => j.officeId == o.id && j.post == p.id).length;
        return woke > 0 ? 'Posted. $woke teammate${woke == 1 ? '' : 's'} will see it and take their turn.' : 'Posted.';
      case 'office_watch':
        final who = s('from').isEmpty || RegExp(r'^(anyone|any|everyone|\*)$', caseSensitive: false).hasMatch(s('from')) ? null : _member(o, s('from'));
        if (s('from').isNotEmpty && who == null && !RegExp(r'^(anyone|any|everyone|\*)$', caseSensitive: false).hasMatch(s('from'))) {
          return 'Error: no teammate called "${s('from')}". Team: ${o.members.map(_botName).join(', ')}.';
        }
        if (who?.id == b.id) return 'Error: you cannot wait for your own post.';
        if (s('do').isEmpty) return 'Error: say what you will do then.';
        o.watches.removeWhere((w) => w.watcher == b.id && w.from == (who?.id ?? TeamWatch.anyone) && w.by == b.id);
        o.watches.add(TeamWatch(id: TeamWatch.newId(), watcher: b.id, from: who?.id ?? TeamWatch.anyone, instruction: s('do'), by: b.id));
        await save();
        return 'Saved. You will be woken by yourself as soon as ${who?.name ?? 'a teammate'} posts in the team chat; no need to check or wait.';
      case 'office_brief':
        switch (s('action')) {
          case 'decision':
            o.decisions.add(s('text'));
            while (o.decisions.length > 60) {
              o.decisions.removeAt(0);
            }
          case 'forget':
            o.brief.removeWhere((x) => x.toLowerCase().contains(s('text').toLowerCase()));
            o.decisions.removeWhere((x) => x.toLowerCase().contains(s('text').toLowerCase()));
          default:
            o.brief.removeWhere((x) => x.toLowerCase() == s('text').toLowerCase());
            o.brief.add(s('text'));
            while (o.brief.length > 80) {
              o.brief.removeAt(0);
            }
        }
        await save();
        return 'Saved to the team brief.';
      case 'office_kpi':
        final name = s('name');
        if (name.isEmpty) return 'Error: name the number.';
        final k = o.kpis.where((x) => x.name.toLowerCase() == name.toLowerCase()).firstOrNull;
        final value = (a['value'] as num?)?.toDouble();
        final target = (a['target'] as num?)?.toDouble();
        switch (s('action')) {
          case 'remove':
            if (!isChief) return 'Error: only the Chief removes numbers.';
            if (k == null) return 'No number called "$name".';
            o.kpis.remove(k);
          case 'add':
            if (k != null) return 'Already tracked: ${k.line}. Use set to update it.';
            if (!isChief) return 'Error: only the Chief adds new numbers. Suggest it to the Chief.';
            if (o.kpis.length >= 6) return 'Error: at most 6 numbers. Remove one first.';
            final nk = OfficeKpi(name, target: target, unit: s('unit'));
            if (value != null) nk.set(value);
            o.kpis.add(nk);
          default:
            if (k == null) return 'No number called "$name". The Chief can add it.';
            if (value == null) return 'Error: give the value you measured.';
            k.set(value);
            if (target != null && isChief) k.target = target;
            if (s('unit').isNotEmpty) k.unit = s('unit');
        }
        await save();
        return 'Numbers: ${o.kpis.map((x) => x.line).join('; ')}';
      case 'office_ask_owner':
        if (!isChief) return 'Error: only the Chief reaches the owner. Post to the Chief in the office chat.';
        if (s('text').isEmpty) return 'Error: say what you need.';
        post(o, b.id, s('text'), kind: 'ask');
        await (notifyNeeds ?? notify)?.call(o, b, s('text'));
        return 'The owner got your message on their phone. Carry on with other work; their answer comes as a new office message.';
      case 'docs_share':
        if (s('content').isEmpty) return 'Error: give the doc its full text in content.';
        final d = addDoc(o, title: s('title'), body: '${a['content']}', author: b.name);
        return 'Saved to the team folder as "${d.title}" (id ${d.id}). In the chat, post only a short summary and say it is in the team folder.';
      case 'docs_list':
        await syncFromFolder(o).catchError((Object _) {});
        final words = s('query').toLowerCase().split(RegExp(r'\s+')).where((w) => w.length > 1).toList();
        final hits = o.docs.reversed.where((d) {
          if (words.isEmpty) return true;
          final hay = '${d.title} ${d.author} ${d.body.length > 2000 ? d.body.substring(0, 2000) : d.body}'.toLowerCase();
          return words.any(hay.contains);
        }).take(30).toList();
        if (hits.isEmpty) return o.docs.isEmpty ? 'The team folder is empty.' : 'No doc matches. ${o.docs.length} docs in total.';
        return hits
            .map((d) => '- ${d.id}: "${d.title}" by ${d.author}, ${_when(d.updated)}'
                '${d.fileName.isEmpty ? '' : ' (file ${d.fileName})'} · ${d.body.length} chars')
            .join('\n');
      case 'docs_read':
        await syncFromFolder(o).catchError((Object _) {});
        final d = doc(o, s('id'));
        if (d == null) return 'Error: no doc "${s('id')}". Call docs_list for the ids.';
        final off = ((a['offset'] as num?)?.toInt() ?? 0).clamp(0, d.body.length).toInt();
        const size = 8000;
        final end = (off + size).clamp(0, d.body.length).toInt();
        final head = '"${d.title}" by ${d.author}, ${_when(d.updated)}'
            '${d.file.isEmpty ? '' : '\nFile: ${d.file}'}\n';
        if (d.body.isEmpty) return '$head(No text inside. ${d.file.isEmpty ? '' : 'Open the file with your file tools.'})';
        return '$head${d.body.substring(off, end)}${end < d.body.length ? '\n…[${d.body.length - end} more characters: docs_read with offset $end]' : ''}';
    }
    return 'Error: unknown tool $name.';
  }

  void _trim(Office o) {
    while (o.tasks.length > 300) {
      final i = o.tasks.indexWhere((t) => !t.open);
      if (i < 0) break;
      o.tasks.removeAt(i);
    }
  }
}
