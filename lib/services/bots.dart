import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart' show ChatMessage;
import 'bot_package.dart';
import 'bot_powers.dart';
import 'events.dart';
import 'bot_manner.dart';
import 'no_reply.dart';
import 'house_rules.dart';
import 'skill_library.dart';

import 'system_bridge.dart';
import 'full_access.dart';
import 'trust.dart';

/// Bots: colleagues who live in SubMac. Each has an identity, a role, its own memory, a desk of tasks, routines and
/// triggers that wake it, and a sense of when it is worth interrupting the user. It runs on the phone; its setup, memory,
/// desk and journal are kept in the owner's account too (BotSync), so jobs that need no phone can run in the cloud.

/// The hidden marker that starts a message SubMac wrote to wake a bot (never shown in the chat).
const botWakeMark = '\u2063wake\u2063';

class BotRoutine {
  BotRoutine({required this.id, required this.time, this.days = 'daily', this.kind = 'work', required this.instruction});
  final String id;
  /// 'HH:MM' in the phone's local time.
  String time;
  /// daily | weekdays | weekends | mon,wed,fri (three-letter names)
  String days;
  /// work (do it, then tell only if worth it) | message (always send the result) | call (ring the user)
  String kind;
  String instruction;

  Map<String, dynamic> toJson() => {'id': id, 'time': time, 'days': days, 'kind': kind, 'do': instruction};
  static BotRoutine fromJson(Map<String, dynamic> j) =>
      BotRoutine(id: '${j['id']}', time: '${j['time'] ?? '09:00'}', days: '${j['days'] ?? 'daily'}', kind: '${j['kind'] ?? 'work'}', instruction: '${j['do'] ?? ''}');

  static const _names = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];

  bool _onDay(DateTime d) {
    switch (days) {
      case 'daily':
        return true;
      case 'weekdays':
        return d.weekday <= 5;
      case 'weekends':
        return d.weekday >= 6;
    }
    final want = days.toLowerCase().split(RegExp(r'[ ,]+')).where((e) => e.isNotEmpty).map((e) => e.substring(0, e.length < 3 ? e.length : 3)).toSet();
    return want.contains(_names[d.weekday - 1]);
  }

  DateTime? next(DateTime from) {
    final p = time.split(':');
    final h = int.tryParse(p.first) ?? 9, m = p.length > 1 ? int.tryParse(p[1]) ?? 0 : 0;
    for (var i = 0; i < 9; i++) {
      final d = DateTime(from.year, from.month, from.day + i, h, m);
      if (d.isAfter(from) && _onDay(d)) return d;
    }
    return null;
  }

  /// The latest time this routine was due at or before [at], or null when no day in the last week matches.
  DateTime? prev(DateTime at) {
    final p = time.split(':');
    final h = int.tryParse(p.first) ?? 9, m = p.length > 1 ? int.tryParse(p[1]) ?? 0 : 0;
    for (var i = 0; i < 9; i++) {
      final d = DateTime(at.year, at.month, at.day - i, h, m);
      if (!d.isAfter(at) && _onDay(d)) return d;
    }
    return null;
  }

  /// How long after its time a missed run is still worth doing (CB-21). Later than this it waits for the next one.
  static const catchUpWindow = Duration(hours: 3);

  /// CB-21: a run missed while SubMac was stopped (phone off, app killed, alarm lost). When the latest slot passed
  /// less than [catchUpWindow] ago, this routine was already set to this time before that slot ([since]), and it has
  /// not run for that slot ([lastSlot]), it runs in about a minute. Otherwise null: [next] as usual. A routine made or
  /// moved after its time today never runs at once.
  DateTime? catchUp(DateTime now, {DateTime? lastSlot, DateTime? since}) {
    final s = prev(now);
    if (s == null || now.difference(s) >= catchUpWindow) return null;
    if (since == null || !since.isBefore(s)) return null;
    if (lastSlot != null && !lastSlot.isBefore(s)) return null;
    return now.add(const Duration(minutes: 1));
  }

  /// What a run record is valid for: a new time or days starts the routine's history again.
  String get schedule => '$time|$days';

  String describe() => '$time $days: ${kind == 'call' ? '(call) ' : kind == 'message' ? '(message) ' : ''}$instruction';
}

/// A wake that came before SubMac could run it (CB-46): kept until SubMac is ready, then run once.
class HeldWake {
  HeldWake(this.bot, this.key, this.reason, this.instruction, this.kind, this.at);
  final String bot;
  /// The alarm's once-per-slot key (CB-35), so the same wake is never held twice.
  final String key;
  final String reason;
  final String instruction;
  final String kind;
  final DateTime at;
  Map<String, dynamic> toJson() => {'bot': bot, 'key': key, 'why': reason, 'do': instruction, 'kind': kind, 'at': at.toUtc().toIso8601String()};
  static HeldWake fromJson(Map<String, dynamic> j) => HeldWake('${j['bot']}', '${j['key']}', '${j['why'] ?? ''}', '${j['do'] ?? ''}',
      '${j['kind'] ?? 'work'}', DateTime.tryParse('${j['at']}')?.toLocal() ?? DateTime.now());
}

class BotFollowup {
  BotFollowup(this.id, this.at, this.instruction, this.kind);
  final String id;
  final DateTime at;
  final String instruction;
  final String kind;
  // UTC with its Z: a time written without a zone means another moment once the phone changes zone (SYNC-8).
  Map<String, dynamic> toJson() => {'id': id, 'at': at.toUtc().toIso8601String(), 'do': instruction, 'kind': kind};
  static BotFollowup fromJson(Map<String, dynamic> j) =>
      BotFollowup('${j['id']}', DateTime.tryParse('${j['at']}')?.toLocal() ?? DateTime.now(), '${j['do'] ?? ''}', '${j['kind'] ?? 'work'}');
}

/// "When a notification from WhatsApp mentions 'invoice', do X."
class BotWatch {
  BotWatch(this.id, this.app, this.keyword, this.instruction, {this.chat = ''});
  final String id;
  final String app;
  final String keyword;
  final String instruction;
  /// WhatsApp watches: only this chat or contact (part of its name) wakes the bot ('' = any chat).
  final String chat;
  Map<String, dynamic> toJson() => {'id': id, 'app': app, 'kw': keyword, 'do': instruction, if (chat.isNotEmpty) 'c': chat};
  static BotWatch fromJson(Map<String, dynamic> j) =>
      BotWatch('${j['id']}', '${j['app'] ?? ''}', '${j['kw'] ?? ''}', '${j['do'] ?? ''}', chat: '${j['c'] ?? ''}');
}

class DeskTask {
  DeskTask(this.id, this.text, {this.status = 'todo', this.note = ''});
  final String id;
  String text;
  /// todo | doing | waiting (on the user) | done
  String status;
  String note;
  DateTime updated = DateTime.now();
  Map<String, dynamic> toJson() => {'id': id, 't': text, 's': status, 'n': note, 'u': updated.toIso8601String()};
  static DeskTask fromJson(Map<String, dynamic> j) => DeskTask('${j['id']}', '${j['t'] ?? ''}', status: '${j['s'] ?? 'todo'}', note: '${j['n'] ?? ''}')
    ..updated = DateTime.tryParse('${j['u']}') ?? DateTime.now();
}

class JournalEntry {
  JournalEntry(this.at, this.kind, this.text);
  final DateTime at;
  /// work | note | message | call | missed | learned
  final String kind;
  final String text;
  Map<String, dynamic> toJson() => {'at': at.toUtc().toIso8601String(), 'k': kind, 't': text};
  static JournalEntry fromJson(Map<String, dynamic> j) => JournalEntry(DateTime.tryParse('${j['at']}')?.toLocal() ?? DateTime.now(), '${j['k'] ?? 'note'}', '${j['t'] ?? ''}');
}

class Bot {
  Bot({
    required this.id,
    required this.name,
    required this.role,
    required this.persona,
    this.mission = '',
    this.icon = 'person',
    this.look,
    this.builtIn = false,
    this.model = 'auto',
    this.voice = '',
    this.proactivity = 'balanced',
    this.heartbeatHours = 0,
    this.quietFrom = 22,
    this.quietTo = 7,
    this.allowCalls = true,
    this.firstMeeting = '',
  });

  final String id;
  String name;
  String role;
  /// Who it is: character, expertise, how it talks.
  String persona;
  /// What it works toward for this user (filled in as it learns).
  String mission;
  String icon;
  /// The face it shows: 'av:<shape>.<colour>.<eyes>' = the owner's pick from SubMac's avatar set (sub_avatar.dart),
  /// null or '' = the bot's own seeded avatar, anything else = the older animated face (BotFace). Presentation-only: it never travels in a shared package and a cloud push never
  /// overwrites it (contract invariant 2), so it is absent from export() and from applySetup().
  String? look;
  final bool builtIn;
  /// 'auto' or 'providerId|model'.
  String model;
  /// Live voice name for calls ('' = the Live default).
  String voice;
  /// quiet | balanced | active
  String proactivity;
  /// Wakes on its own every N hours outside quiet hours (0 = only routines and triggers).
  int heartbeatHours;
  int quietFrom;
  int quietTo;
  bool allowCalls;
  /// What it asks in its first chat with the user.
  String firstMeeting;

  /// Hired: it lives, wakes and reaches out. Built-in bots start unhired.
  bool active = false;
  String convId = '';
  final List<String> memory = [];
  final List<DeskTask> desk = [];
  final List<BotRoutine> routines = [];
  final List<BotFollowup> followups = [];
  final List<BotWatch> watches = [];
  final List<JournalEntry> journal = [];

  // The interruption budget.
  String dayKey = '';
  int messagesToday = 0;
  int callsToday = 0;
  int ignoredStreak = 0;
  DateTime? lastOutreach;
  DateTime? lastUserReply;
  DateTime? lastWake;

  /// Powers the owner switched off (see BotPowers): web, browser, phone, files, apps.
  final Set<String> powersOff = {};

  /// What the owner wrote for it: how to do the job, rules, tone (part of its package, travels when shared).
  String instructions = '';

  /// Knowledge sandbox. On: answers only from its own knowledge, no web. Off: its knowledge first, then anywhere.
  bool sandbox = false;

  /// Its knowledge: notes and files' text. Saved apart from the rest (it can be big), see Bots.saveKnowledge.
  final List<BotKnowledge> knowledge = [];

  /// The apps and MCP servers it is set up to use (which app only; logins stay with the owner's own connection).
  final List<BotApp> apps = [];

  /// On: it may use only [apps]. Off (bots made before 1.11): every app the owner connected, as before.
  bool appsScoped = false;

  /// Short how-to lessons it learned from its own work (generic, no details about the owner).
  final List<BotLesson> lessons = [];

  /// Where it came from: '' (made here), 'store:<id>' (hired from the Bot Store), 'shared' (a copy someone shared).
  String origin = '';

  /// Its Bot Store listing when the owner published it ('' = not published).
  String storeId = '';

  /// "Works in the cloud" (plan 2.1): null = the default ([cloudFit]), true/false = the owner's choice.
  bool? cloudChoice;

  /// Plan 5.2 trust level: 'new' (asks before every change) or 'trusted' (routine work on its own; still asks before
  /// money, sending and deleting). '' = not set yet (bots made before 1.13.27; AppState sets it once).
  String trust = '';
  /// Approvals in a row the owner did not edit, and the count at which Trusted is offered next.
  int cleanOk = 0;
  int trustOfferAt = BotTrust.promoteAfter;
  /// The note it leaves in its chat: daily (each evening, when there is something to say) | weekly (Sundays) | off.
  String report = 'daily';
  /// The role it was hired for ('' = described or from the Store).
  String roleId = '';

  String get level => trust == BotTrust.levelTrusted ? BotTrust.levelTrusted : BotTrust.levelNew;
  bool get trustOffered => BotTrust.shouldOffer(level, cleanOk, trustOfferAt);

  static final _phoneWords = RegExp(
      r'\b(sms|texts?|text messages?|notifications?|whatsapp|screen|contacts?|phone|call|calls|calling|ring|gallery|camera|photos?|clipboard|battery)\b',
      caseSensitive: false);

  /// Does this job need the phone itself (a call, texts, notifications, the screen...)? Those never run in the cloud.
  bool needsPhone(String instruction, String kind) =>
      kind == 'call' || (!powersOff.contains('phone') && _phoneWords.hasMatch(instruction));

  /// None of its routines needs the phone, so by default it keeps working in the cloud.
  bool get cloudFit => routines.every((r) => !needsPhone(r.instruction, r.kind));

  /// It keeps working in the cloud (jobs that need the phone always stay on the phone).
  bool get cloudOn => cloudChoice ?? cloudFit;

  /// Takes the setup from the account (another phone changed it). Memory, desk, journal, knowledge and the day's
  /// counters stay as they are here.
  void applySetup(Map<String, dynamic> j) {
    final o = Bot.fromJson({...j, 'id': id});
    name = o.name;
    role = o.role;
    persona = o.persona;
    mission = o.mission;
    icon = o.icon;
    model = o.model;
    voice = o.voice;
    proactivity = o.proactivity;
    heartbeatHours = o.heartbeatHours;
    quietFrom = o.quietFrom;
    quietTo = o.quietTo;
    allowCalls = o.allowCalls;
    firstMeeting = o.firstMeeting;
    active = o.active;
    if (o.convId.isNotEmpty) convId = o.convId;
    instructions = o.instructions;
    sandbox = o.sandbox;
    appsScoped = o.appsScoped;
    origin = o.origin;
    storeId = o.storeId;
    tokenBudgetK = o.tokenBudgetK;
    cloudChoice = o.cloudChoice;
    if (o.trust.isNotEmpty) trust = o.trust;
    trustOfferAt = o.trustOfferAt;
    report = o.report;
    roleId = o.roleId;
    routines
      ..clear()
      ..addAll(o.routines);
    followups
      ..clear()
      ..addAll(o.followups);
    watches
      ..clear()
      ..addAll(o.watches);
    apps
      ..clear()
      ..addAll(o.apps);
    lessons
      ..clear()
      ..addAll(o.lessons);
    powersOff
      ..clear()
      ..addAll(o.powersOff);
  }

  /// The powers it may not use right now: the owner's switches, plus web and browser when the sandbox is on.
  Set<String> get effectiveOff => sandbox ? {...powersOff, 'web', 'browser'} : powersOff;
  /// Most tokens (in thousands) its own background work may use a day. 0 = no limit. Chats with the owner are never cut.
  int tokenBudgetK = 0;
  String tokenDay = '';
  int tokensToday = 0;

  void addTokens(int n) {
    final now = DateTime.now();
    final k = '${now.year}-${now.month}-${now.day}';
    if (k != tokenDay) {
      tokenDay = k;
      tokensToday = 0;
    }
    tokensToday += n;
  }

  int get tokensTodayNow {
    final now = DateTime.now();
    return tokenDay == '${now.year}-${now.month}-${now.day}' ? tokensToday : 0;
  }

  bool get overBudget => tokenBudgetK > 0 && tokensTodayNow >= tokenBudgetK * 1000;

  /// The bot package to share, publish or hire: who it is and how it works, its knowledge, skills, apps and
  /// lessons. Always passed through BotPackage.sanitize (an allow-list), so logins, keys, tokens and anything it
  /// knows about its owner (memory, journal, chats, desk) never leave the phone.
  Map<String, dynamic> export() => BotPackage.sanitize({
        'submac': BotPackage.format,
        'name': name, 'role': role, 'persona': persona, 'icon': icon, 'voice': voice, 'model': model,
        'instructions': instructions, 'first_meeting': firstMeeting, 'sandbox': sandbox,
        'proactivity': proactivity, 'heartbeat_hours': heartbeatHours, 'quiet_from': quietFrom, 'quiet_to': quietTo,
        'calls': allowCalls, 'token_budget_k': tokenBudgetK, 'powers_off': powersOff.toList(),
        'routines': [for (final r in routines) {'time': r.time, 'days': r.days, 'kind': r.kind, 'do': r.instruction}],
        'skills': SkillLibrary.I.of(id),
        'apps': [for (final a in apps) a.toJson()],
        'knowledge': [for (final k in knowledge) k.toJson()],
        'lessons': [for (final l in lessons) l.text],
      })!;

  /// One line for a Bot Store card.
  String get pitch {
    final s = persona.split(RegExp(r'(?<=[.!?])\s')).first;
    final t = s.replaceFirst(RegExp(r'^You are (an? )?', caseSensitive: false), '');
    return t.isEmpty ? t : t[0].toUpperCase() + t.substring(1);
  }

  Map<String, dynamic> toJson() => {
        'id': id, 'name': name, 'role': role, 'persona': persona, 'mission': mission, 'icon': icon, 'builtIn': builtIn,
        'model': model, 'voice': voice, 'pro': proactivity, 'hb': heartbeatHours, 'qf': quietFrom, 'qt': quietTo,
        'calls': allowCalls, 'first': firstMeeting, 'active': active, 'conv': convId, 'mem': memory,
        'desk': desk.map((e) => e.toJson()).toList(), 'rt': routines.map((e) => e.toJson()).toList(),
        'fu': followups.map((e) => e.toJson()).toList(), 'w': watches.map((e) => e.toJson()).toList(),
        'j': journal.map((e) => e.toJson()).toList(), 'day': dayKey, 'mt': messagesToday, 'ct': callsToday,
        'ig': ignoredStreak, 'lo': lastOutreach?.toIso8601String(), 'lu': lastUserReply?.toIso8601String(),
        'lw': lastWake?.toIso8601String(),
        'po': powersOff.toList(), 'tb': tokenBudgetK, 'td': tokenDay, 'tt': tokensToday,
        'ins': instructions, 'sb': sandbox, 'apps': apps.map((e) => e.toJson()).toList(), 'scoped': appsScoped,
        'les': lessons.map((e) => e.toJson()).toList(), 'origin': origin, 'store': storeId, 'cl': cloudChoice,
        if (look != null) 'lk': look,
        if (trust.isNotEmpty) 'tr': trust, 'ok': cleanOk, 'ta': trustOfferAt, 'rp': report, if (roleId.isNotEmpty) 'rl': roleId,
      };

  static Bot fromJson(Map<String, dynamic> j) {
    List<Map<String, dynamic>> l(String k) => [for (final e in (j[k] as List? ?? const [])) Map<String, dynamic>.from(e as Map)];
    final b = Bot(
      id: '${j['id']}',
      name: '${j['name'] ?? 'Bot'}',
      role: '${j['role'] ?? ''}',
      persona: '${j['persona'] ?? ''}',
      mission: '${j['mission'] ?? ''}',
      icon: '${j['icon'] ?? 'person'}',
      builtIn: j['builtIn'] == true,
      model: '${j['model'] ?? 'auto'}',
      voice: '${j['voice'] ?? ''}',
      proactivity: '${j['pro'] ?? 'balanced'}',
      heartbeatHours: (j['hb'] as num?)?.toInt() ?? 0,
      quietFrom: (j['qf'] as num?)?.toInt() ?? 22,
      quietTo: (j['qt'] as num?)?.toInt() ?? 7,
      allowCalls: j['calls'] != false,
      firstMeeting: '${j['first'] ?? ''}',
    )
      ..active = j['active'] == true
      ..convId = '${j['conv'] ?? ''}'
      ..dayKey = '${j['day'] ?? ''}'
      ..messagesToday = (j['mt'] as num?)?.toInt() ?? 0
      ..callsToday = (j['ct'] as num?)?.toInt() ?? 0
      ..ignoredStreak = (j['ig'] as num?)?.toInt() ?? 0
      ..lastOutreach = DateTime.tryParse('${j['lo']}')
      ..lastUserReply = DateTime.tryParse('${j['lu']}')
      ..lastWake = DateTime.tryParse('${j['lw']}')
      ..tokenBudgetK = (j['tb'] as num?)?.toInt() ?? 0
      ..tokenDay = '${j['td'] ?? ''}'
      ..tokensToday = (j['tt'] as num?)?.toInt() ?? 0
      ..instructions = '${j['ins'] ?? ''}'
      ..sandbox = j['sb'] == true
      ..appsScoped = j['scoped'] == true
      ..origin = '${j['origin'] ?? ''}'
      ..storeId = '${j['store'] ?? ''}'
      ..cloudChoice = j['cl'] is bool ? j['cl'] as bool : null
      ..trust = const {'new', 'trusted'}.contains(j['tr']) ? '${j['tr']}' : ''
      ..cleanOk = (j['ok'] as num?)?.toInt() ?? 0
      ..trustOfferAt = (j['ta'] as num?)?.toInt() ?? BotTrust.promoteAfter
      ..report = const {'daily', 'weekly', 'off'}.contains(j['rp']) ? '${j['rp']}' : 'daily'
      ..roleId = '${j['rl'] ?? ''}'
      ..look = j['lk'] is String ? '${j['lk']}' : null;
    b.apps.addAll(l('apps').map(BotApp.fromJson).whereType<BotApp>());
    b.lessons.addAll(l('les').map(BotLesson.fromJson).where((e) => e.text.trim().isNotEmpty));
    b.powersOff.addAll([for (final e in (j['po'] as List? ?? const [])) '$e']);
    b.memory.addAll([for (final e in (j['mem'] as List? ?? const [])) '$e']);
    b.desk.addAll(l('desk').map(DeskTask.fromJson));
    b.routines.addAll(l('rt').map(BotRoutine.fromJson));
    b.followups.addAll(l('fu').map(BotFollowup.fromJson));
    b.watches.addAll(l('w').map(BotWatch.fromJson));
    b.journal.addAll(l('j').map(JournalEntry.fromJson));
    return b;
  }

  bool quietNow([DateTime? at]) {
    final h = (at ?? DateTime.now()).hour;
    if (quietFrom == quietTo) return false;
    return quietFrom > quietTo ? (h >= quietFrom || h < quietTo) : (h >= quietFrom && h < quietTo);
  }

  void _rollDay() {
    final now = DateTime.now();
    final k = '${now.year}-${now.month}-${now.day}';
    if (k != dayKey) {
      dayKey = k;
      messagesToday = 0;
      callsToday = 0;
    }
  }

  int get messageCap {
    final base = switch (proactivity) { 'quiet' => 1, 'active' => 6, _ => 3 };
    return ignoredStreak >= 3 ? (base / 2).ceil() : base;
  }

  int get callCap {
    if (!allowCalls) return 0;
    final base = switch (proactivity) { 'quiet' => 0, 'active' => 2, _ => 1 };
    return ignoredStreak >= 3 ? 0 : base;
  }

  int get messagesLeft {
    _rollDay();
    return (messageCap - messagesToday).clamp(0, 99).toInt();
  }

  int get callsLeft {
    _rollDay();
    return (callCap - callsToday).clamp(0, 99).toInt();
  }

  void log(String kind, String text) {
    journal.add(JournalEntry(DateTime.now(), kind, text.length > 300 ? '${text.substring(0, 300)}…' : text));
    while (journal.length > 200) {
      journal.removeAt(0);
    }
  }

  /// Hours between heartbeats, slower when the user keeps ignoring it.
  int get effectiveHeartbeat => heartbeatHours <= 0 ? 0 : (ignoredStreak >= 3 ? heartbeatHours * 2 : heartbeatHours);

  /// Presence (plan 5.2): working (a run is going now) | free | off (not hired, paused or quiet hours).
  String presence(bool workingNow) {
    if (!active) return 'off';
    if (workingNow) return 'working';
    return quietNow() ? 'off' : 'free';
  }

  static const presenceLabels = {'working': 'Working', 'free': 'Free', 'off': 'Off'};

  String get status {
    if (!active) return 'Not added yet';
    final doing = desk.where((t) => t.status == 'doing').firstOrNull;
    if (doing != null) return doing.text;
    final waiting = desk.where((t) => t.status == 'waiting').length;
    if (waiting > 0) return 'Waiting on you ($waiting)';
    return quietNow() ? 'Off for the night' : 'Available';
  }
}

/// The interruption a wake ended with.
/// The rows of a bot wake that ended with nothing to show (CB-17).
class WakeTurn {
  WakeTurn._();

  /// The rows to remove: the wake's own mark and the rows the wake run wrote ([wrote], tracked by the runner).
  /// Rows the owner typed during the wake, and the quick side replies to them, always stay. When the wake's rows are
  /// unknown (null), everything after the mark goes only if nobody else wrote there; otherwise just the mark goes.
  static List<ChatMessage> rowsToDrop(List<ChatMessage> list, Set<String>? wrote) {
    final start = list.lastIndexWhere((m) => m.role == 'user' && m.content.startsWith(botWakeMark));
    if (start < 0) return const [];
    final after = list.sublist(start + 1);
    if (wrote == null) {
      final ownerSpoke = after.any((m) => m.role == 'user' && !m.content.startsWith(botWakeMark));
      return ownerSpoke ? [list[start]] : list.sublist(start);
    }
    return [list[start], ...after.where((m) => wrote.contains(m.id))];
  }
}

class BotOutcome {
  BotOutcome(this.kind, this.text);
  /// silent | note | message | call
  final String kind;
  final String text;

  /// The bot ends a background wake with a tag on its own last line: @note, @message or @call: reason; or it says
  /// nothing worth telling with [NoReply.token] (the old @silent still reads as silence). A silence tag stuck to real
  /// text keeps the text (kind "silent", so a wake stays quiet, but a job that must answer can still post it).
  static BotOutcome parse(String reply) {
    final lines = reply.trim().split('\n');
    final last = lines.isEmpty ? '' : lines.last.trim();
    final m = RegExp(r'^@(silent|note|message|call)\b:?\s*(.*)$', caseSensitive: false).firstMatch(last);
    final body = NoReply.clean((m == null ? lines : lines.sublist(0, lines.length - 1)).join('\n').trim());
    if (m == null) {
      final t = reply.trim();
      if (NoReply.isSilent(t)) return BotOutcome('silent', '');
      final kept = NoReply.clean(t);
      if (kept != t) return BotOutcome('silent', kept);
      return BotOutcome('note', t);
    }
    final kind = m.group(1)!.toLowerCase();
    final extra = (m.group(2) ?? '').trim();
    if (kind == 'call') return BotOutcome('call', extra.isNotEmpty ? extra : body);
    if (kind == 'silent') return BotOutcome('silent', body);
    return BotOutcome(kind, body.isNotEmpty ? body : extra);
  }

  /// The message to keep in the chat (without the tag line or a silence marker).
  static String visible(String reply) {
    final lines = reply.trim().split('\n');
    if (lines.isNotEmpty && RegExp(r'^@(silent|note|message|call)\b', caseSensitive: false).hasMatch(lines.last.trim())) {
      return NoReply.clean(lines.sublist(0, lines.length - 1).join('\n').trim());
    }
    return NoReply.clean(reply.trim());
  }
}

class Bots extends ChangeNotifier {
  Bots._();
  static final Bots I = Bots._();

  final List<Bot> bots = [];
  SharedPreferences? _p;

  // ---------------------------------------------------------------- the Chief (RESTYLE.md Dev 2)

  /// The bot that leads: every user starts with one, ready to talk to. It makes new bots in chat (bot_make) and leads
  /// teams by default. The owner can make any bot the Chief.
  String chiefId = '';
  Bot? get chief => byId(chiefId);
  bool isChief(Bot b) => b.id == chiefId;

  Future<void> setChief(Bot b) async {
    chiefId = b.id;
    await _p?.setString('bot_chief_v1', b.id);
    b.log('work', 'Now your Chief: I can make new bots for you and lead your teams.');
    await save();
  }

  /// Makes [id] the Chief without a journal line (the account or this phone's kept copy says it already is).
  Future<void> adoptChief(String id) async {
    chiefId = id;
    await _p?.setString('bot_chief_v1', id);
  }

  /// Every bot on this phone with its knowledge and which one is the Chief (kept per account at sign-out, R2 item 3).
  Map<String, dynamic> snapshot() => {
        'bots': [for (final b in bots) b.toJson()],
        'kn': {for (final b in bots) if (b.knowledge.isNotEmpty) b.id: [for (final k in b.knowledge) k.toJson()]},
        'chief': chiefId,
      };

  /// Brings back a [snapshot]: its bots (a bot already here with the same id is replaced), their knowledge, the
  /// Chief, and their alarms. Saved (which also queues them for the account).
  Future<void> adopt(Map<String, dynamic> snap) async {
    final kn = Map<String, dynamic>.from((snap['kn'] as Map?) ?? const {});
    for (final e in (snap['bots'] as List? ?? const [])) {
      final b = Bot.fromJson(Map<String, dynamic>.from(e as Map));
      if (b.id.isEmpty) continue;
      bots.removeWhere((x) => x.id == b.id);
      bots.add(b);
      b.knowledge
        ..clear()
        ..addAll([for (final k in (kn[b.id] as List? ?? const [])) BotKnowledge.fromJson(Map<String, dynamic>.from(k as Map))]);
      await saveKnowledge(b);
    }
    final c = '${snap['chief'] ?? ''}';
    if (c.isNotEmpty && byId(c) != null) await adoptChief(c);
    await save();
    await armAll();
  }

  /// The text a put-off check-in is saved with as a follow-up. It still runs as a plain check-in.
  static const heartbeat = 'Heartbeat check';

  static bool isHeartbeat(String instruction) {
    final t = instruction.trim();
    return t == heartbeat || t == '(retry) $heartbeat';
  }

  /// Why this bot may not ring the user right now, or null when it may. Every way a call starts (an outcome, the
  /// bot_call tool, a daily report) goes through this, so quiet hours, "calls off" and the daily cap always hold.
  static String? callBlock(Bot b, [DateTime? now]) {
    if (!b.allowCalls) return 'Calls are switched off for you. Send a message instead.';
    if (b.quietNow(now)) return 'It is the user\'s quiet hours: no calls. Keep a note instead.';
    if (b.callsLeft <= 0) return 'No calls left today. Send a message instead.';
    return null;
  }

  /// After an office run ends: does a task still marked "doing" go back in line by itself? Not when the run was
  /// stopped (the owner pressed Stop): that would restart the work they just stopped.
  static bool requeueAfterRun({required bool finished, required String kind, required String status}) =>
      finished && kind == 'task' && status == 'doing';

  /// May a wake take a bot's chat? Not while an office job holds it, another wake is marked on it, or a run is going.
  static bool wakeMayClaim({required bool officeBusy, required bool hasMarker, required bool running}) =>
      !officeBusy && !hasMarker && !running;

  /// A follow-up for the same job is already waiting: a busy bot must not stack one per wake.
  static bool hasPendingFollowup(Bot b, String instruction, String kind) {
    final want = instruction.trim().isEmpty ? heartbeat : instruction.trim();
    return b.followups.any((f) => f.kind == kind && (f.instruction.trim() == want || (isHeartbeat(want) && isHeartbeat(f.instruction))));
  }

  /// The owner picks how a bot looks (SubMac avatar set, lib/widgets/sub_avatar.dart): 'av:<shape>.<colour>.<eyes>',
  /// or null for the bot's own seeded avatar. Presentation only: never exported, never overwritten by a cloud push.
  Future<void> setLook(Bot b, String? look) async {
    b.look = look;
    notifyListeners();
    await save();
  }

  /// Gives a new user their Chief once. A Chief the owner removed is not brought back.
  void _seedChief() {
    chiefId = _p?.getString('bot_chief_v1') ?? '';
    if (chief != null) return;
    if (_p?.getBool('bot_chief_seeded_v1') == true) {
      chiefId = '';
      return;
    }
    final c = BotTemplates.chief;
    if (byId(c.id) == null) bots.insert(0, c);
    chiefId = c.id;
    _p?.setString('bot_chief_v1', c.id);
    _p?.setBool('bot_chief_seeded_v1', true);
  }

  /// Drafts the Chief showed in a chat, waiting for the owner's yes (convId → spec).
  final Map<String, Map<String, dynamic>> _drafts = {};

  /// Team drafts the Chief showed in a chat, waiting for the owner's yes (convId → spec).
  final Map<String, Map<String, dynamic>> _teamDrafts = {};

  /// Every chat was deleted: drafts shown there can no longer be approved.
  void forgetDrafts() {
    _drafts.clear();
    _teamDrafts.clear();
  }

  /// Wakes a bot (set by AppState): [reason] says why, [instruction] what to do, [kind] work | message | call.
  Future<void> Function(Bot bot, String reason, String instruction, String kind)? onWake;

  /// How many of this bot's asks wait for the owner (set by AppState, from the approvals).
  int Function(Bot b)? waitingFor;

  /// Posts the bot's daily or weekly note in its chat (set by AppState). [notify] = also a quiet notification.
  Future<void> Function(Bot bot, String text, {bool notify})? onReport;

  /// Is this bot working right now (set by AppState: a run in its chat or in a team)?
  bool Function(Bot b)? working;

  /// Presence for the avatar and the job page: working | free | off.
  String presenceOf(Bot b) => b.presence(working?.call(b) ?? false);

  /// The owner answered one of this bot's asks: counts toward the Trusted offer (plan 5.2).
  Future<void> recordAnswer(Bot b, {required bool approved, required bool edited}) async {
    b.cleanOk = BotTrust.afterAnswer(b.cleanOk, approved: approved, edited: edited);
    if (edited && b.trustOfferAt > BotTrust.promoteAfter) b.trustOfferAt = BotTrust.promoteAfter;
    await save();
  }

  /// Sets the trust level. Trusted keeps asking before money, sending and deleting.
  Future<void> setTrust(Bot b, String level) async {
    b.trust = level == BotTrust.levelTrusted ? BotTrust.levelTrusted : BotTrust.levelNew;
    if (b.trust == BotTrust.levelNew) {
      b.cleanOk = 0;
      b.trustOfferAt = BotTrust.promoteAfter;
    }
    b.log('note', b.trust == BotTrust.levelTrusted ? 'You made me Trusted.' : 'Back to New: I ask before every change.');
    await save();
  }

  /// "Not yet" on the Trusted offer: ask again after another ten clean approvals.
  Future<void> snoozeTrust(Bot b) async {
    b.trustOfferAt = BotTrust.snooze(b.cleanOk);
    await save();
  }

  Iterable<Bot> get hired => bots.where((b) => b.active);

  /// Loaded from the phone (init ran).
  bool get ready => _p != null;

  /// Called after every save (set by BotSync: sends the change to the account a few seconds later).
  void Function()? onChanged;

  /// Does the cloud run this job (set by BotSync)? Then the phone sets no alarm for it.
  bool Function(Bot b, String job)? cloudOwns;

  bool _cloud(Bot b, String job) => cloudOwns?.call(b, job) ?? false;
  Bot? byId(String id) => bots.where((b) => b.id == id).firstOrNull;
  Bot? byConv(String? convId) => convId == null || convId.isEmpty ? null : bots.where((b) => b.convId == convId).firstOrNull;
  bool isBotConv(String? convId) => byConv(convId) != null;
  Bot? byName(String name) {
    final n = name.trim().toLowerCase();
    return bots.where((b) => b.name.toLowerCase() == n || b.role.toLowerCase() == n).firstOrNull ??
        bots.where((b) => b.name.toLowerCase().contains(n) || b.role.toLowerCase().contains(n)).firstOrNull;
  }

  Future<void> init() async {
    _p = await SharedPreferences.getInstance();
    await BotTemplates.loadPacks();
    _loadRuns();
    bots.clear();
    try {
      for (final e in jsonDecode(_p!.getString('bots_v1') ?? '[]') as List) {
        bots.add(Bot.fromJson(Map<String, dynamic>.from(e as Map)));
      }
    } catch (_) {}
    // SubMac's own bots now live in the Bot Store. One the owner never started is taken off their list (it is still in
    // the Store); one they work with stays exactly as it was.
    bots.removeWhere((b) => b.builtIn && !b.active && b.convId.isEmpty);
    _seedChief();
    for (final b in bots) {
      _loadKnowledge(b);
    }
    // 2026-10-21 (owner): bots must not work on their own unless the owner set it up. The researcher's and SEO
    // strategist's built-in heartbeat and default routine are switched off once (only when still at the template values);
    // the owner can ask a bot for a routine any time.
    if (_p!.getBool('bots_quiet_v1') != true) {
      for (final b in bots.where((b) => b.builtIn || b.origin.startsWith('store:builtin:'))) {
        final id = b.origin.startsWith('store:builtin:') ? b.origin.substring('store:builtin:'.length) : b.id;
        final tplHb = switch (id) { 'researcher' => 8, 'seo' => 24, _ => -1 };
        if (tplHb < 0) continue;
        var changed = false;
        if (b.heartbeatHours == tplHb) {
          b.heartbeatHours = 0;
          changed = true;
        }
        final before = b.routines.length;
        b.routines.removeWhere((r) => (id == 'researcher' && r.id == 'brief' && r.time == '08:30') || (id == 'seo' && r.id == 'weekly' && r.time == '10:00'));
        if (changed || b.routines.length != before) b.log('work', 'Now works only when you ask. Ask me to set a routine if you want regular checks.');
      }
      await _p!.setBool('bots_quiet_v1', true);
    }
    await save();
    await armAll();
  }

  Future<void> save() async {
    await _p?.setString('bots_v1', jsonEncode(bots.map((e) => e.toJson()).toList()));
    await _p?.setString('bot_watches', jsonEncode([
      for (final b in hired)
        for (final w in b.watches) {'bot': b.id, 'id': w.id, 'app': w.app, 'kw': w.keyword, if (w.chat.isNotEmpty) 'chat': w.chat}
    ]));
    unawaited(SystemBridge.I.setNotifWatches(_p?.getString('bot_watches') ?? '[]'));
    notifyListeners();
    onChanged?.call();
  }

  // ---------------------------------------------------------------- knowledge

  static String _kKey(String id) => 'bot_kn_$id';

  void _loadKnowledge(Bot b) {
    b.knowledge.clear();
    try {
      for (final e in jsonDecode(_p?.getString(_kKey(b.id)) ?? '[]') as List) {
        final k = BotKnowledge.fromJson(Map<String, dynamic>.from(e as Map));
        if (k.text.trim().isNotEmpty) b.knowledge.add(k);
      }
    } catch (_) {}
  }

  /// Knowledge is saved on its own (it can be big), only when it changes.
  Future<void> saveKnowledge(Bot b) async {
    if (b.knowledge.isEmpty) {
      await _p?.remove(_kKey(b.id));
    } else {
      await _p?.setString(_kKey(b.id), jsonEncode(b.knowledge.map((e) => e.toJson()).toList()));
    }
    notifyListeners();
    onChanged?.call();
  }

  int knowledgeChars(Bot b) => b.knowledge.fold(0, (n, k) => n + k.text.length);

  /// Adds a note or a file's text. Returns null when added, or a plain sentence saying why not.
  Future<String?> addKnowledge(Bot b, String title, String text, {String kind = 'text', String file = ''}) async {
    var t = BotPackage.scrubSecrets(text).trim();
    if (t.isEmpty) return 'There is no text to add.';
    if (b.knowledge.length >= BotKnowledge.maxItems) return '${b.name} already has ${BotKnowledge.maxItems} pieces of knowledge. Remove one first.';
    final room = BotKnowledge.maxTotalChars - knowledgeChars(b);
    if (room < 200) return '${b.name}\'s knowledge is full. Remove something first.';
    var cut = false;
    final max = room < BotKnowledge.maxItemChars ? room : BotKnowledge.maxItemChars;
    if (t.length > max) {
      t = t.substring(0, max);
      cut = true;
    }
    b.knowledge.add(BotKnowledge(
        id: 'k${DateTime.now().microsecondsSinceEpoch}', title: title.trim().isEmpty ? 'Note' : title.trim(), text: t, kind: kind, file: file));
    await saveKnowledge(b);
    return cut ? 'Added, but it was long, so only the first part was kept.' : null;
  }

  // ---------------------------------------------------------------- lessons (how it gets better)

  static const maxLessons = 30;

  static Set<String> _lw(String s) =>
      s.toLowerCase().split(RegExp(r'[^a-z0-9\u00c0-\u024f\u0600-\u06ff]+')).where((w) => w.length > 2).toSet();

  /// Two lessons say the same thing when most of their words are shared.
  static bool similarLesson(String a, String b) {
    final x = _lw(a), y = _lw(b);
    if (x.isEmpty || y.isEmpty) return a.trim().toLowerCase() == b.trim().toLowerCase();
    final inter = x.intersection(y).length;
    return inter / x.union(y).length >= 0.6 || (inter >= 4 && inter / (x.length < y.length ? x.length : y.length) >= 0.85);
  }

  /// Saves a one-line, generic how-to lesson: scrubbed of personal details, merged with one it already has, capped at 30.
  /// Returns null when saved (or merged), or a plain reason it was not.
  Future<String?> addLesson(Bot b, String text, {String source = 'task'}) async {
    var t = BotPackage.scrubPersonal(text).replaceFirst(RegExp(r'^[\-*•\d.)\s]+'), '').trim();
    if (t.length < 8) return 'Too short to be a lesson.';
    if (BotPackage.personalLesson(t)) {
      return 'That is about the person, not about how to do the work. Save facts about them with bot_remember instead.';
    }
    if (t.length > 200) t = '${t.substring(0, 199)}…';
    final same = b.lessons.where((l) => similarLesson(l.text, t)).firstOrNull;
    if (same != null) {
      same.uses++;
      same.at = DateTime.now();
      if (source == 'owner') same.text = t;
      await save();
      return null;
    }
    b.lessons.add(BotLesson(t, source: source));
    while (b.lessons.length > maxLessons) {
      // The weakest goes: least confirmed, then oldest. Lessons the owner wrote go last.
      final pool = b.lessons.where((l) => l.source != 'owner').toList();
      final from = pool.isEmpty ? b.lessons : pool;
      from.sort((x, y) => x.uses != y.uses ? x.uses.compareTo(y.uses) : x.at.compareTo(y.at));
      b.lessons.remove(from.first);
    }
    b.log('learned', 'Lesson: $t');
    await save();
    return null;
  }

  /// The lessons that go into its prompt: the most confirmed and most recent, in a steady order (so the prompt
  /// stays the same from step to step).
  List<BotLesson> topLessons(Bot b, [int n = 12]) {
    final l = [...b.lessons]..sort((x, y) => x.uses != y.uses ? y.uses.compareTo(x.uses) : y.at.compareTo(x.at));
    final top = l.take(n).toList()..sort((x, y) => x.text.compareTo(y.text));
    return top;
  }

  // ---------------------------------------------------------------- alarms

  static String alarmId(Bot b, String what) => 'bot|${b.id}|$what';

  // ---------------------------------------------------------------- routine runs (CB-35, CB-21) and held wakes (CB-46)

  /// Tests: the clock routines are armed and fired by.
  @visibleForTesting
  static DateTime Function() clock = DateTime.now;

  /// How long a wake waits for SubMac to be ready (a cold start by an alarm) before it is held for later (CB-46).
  static Duration readyWait = const Duration(seconds: 10);

  static const _runsKey = 'bot_routine_runs_v1';
  static const _heldKey = 'bot_held_wakes_v1';

  /// Per routine ('<bot>|<routine>'): the slot it last ran for ('slot', local 'YYYY-MM-DDTHH:MM'), when it ran ('at'),
  /// and since when it has had its current time and days ('since', 'sch'). Kept on the phone only.
  final Map<String, Map<String, dynamic>> _runs = {};

  /// When each routine alarm was last set for (null = cancelled), as [arm] set it.
  final Map<String, DateTime?> _routineAlarms = {};

  @visibleForTesting
  DateTime? routineAlarmAt(String alarm) => _routineAlarms[alarm];

  /// The once-per-slot key of the wake each bot is being woken for right now (read by the wake as it starts).
  final Map<String, String> _wakeKeys = {};

  static String _minute(DateTime d) => d.toIso8601String().substring(0, 16);

  /// CB-35: the key of one run of a routine, 'routineId|scheduled-minute'.
  static String slotKey(BotRoutine r, DateTime slot) => '${r.id}|${_minute(slot)}';

  void _loadRuns() {
    _runs.clear();
    try {
      final m = jsonDecode(_p?.getString(_runsKey) ?? '{}') as Map;
      m.forEach((k, v) => _runs['$k'] = Map<String, dynamic>.from(v as Map));
    } catch (_) {}
  }

  Future<void> _saveRuns() async => _p?.setString(_runsKey, jsonEncode(_runs));

  /// When this routine last ran on this phone (null: never, or not since this was kept).
  DateTime? lastRunAt(Bot b, BotRoutine r) => DateTime.tryParse('${_runs['${b.id}|${r.id}']?['at']}')?.toLocal();

  DateTime? _lastSlot(Bot b, BotRoutine r) => DateTime.tryParse('${_runs['${b.id}|${r.id}']?['slot']}');

  /// Since when [r] has had its current time and days; starts now the first time it is seen or after it changed.
  DateTime? _since(Bot b, BotRoutine r, DateTime now) {
    final k = '${b.id}|${r.id}';
    final rec = _runs[k];
    if (rec != null && rec['sch'] == r.schedule) return DateTime.tryParse('${rec['since']}')?.toLocal();
    _runs[k] = {'since': now.toUtc().toIso8601String(), 'sch': r.schedule};
    return now;
  }

  /// CB-35: claims this routine's current slot before anything awaits. False when that slot already ran or is running
  /// (the same alarm delivered twice, at once or later): the second delivery does nothing at all.
  bool _claimSlot(Bot b, BotRoutine r, DateTime now) {
    // A little early is still this slot (an exact alarm can land a moment before its minute).
    final slot = r.prev(now.add(const Duration(minutes: 2)));
    if (slot == null) return false;
    final k = '${b.id}|${r.id}';
    final rec = _runs[k];
    if (rec != null && rec['slot'] == _minute(slot)) return false;
    _runs[k] = {...?rec, 'slot': _minute(slot), 'at': now.toUtc().toIso8601String()};
    if (rec == null || rec['sch'] != r.schedule) {
      _runs[k]!['sch'] = r.schedule;
      _runs[k]!['since'] = now.toUtc().toIso8601String();
    }
    _wakeKeys[b.id] = '${b.id}|${slotKey(r, slot)}';
    return true;
  }

  /// The once-per-slot key of the wake [b] is starting now, if an alarm started it.
  String? wakeKey(Bot b) => _wakeKeys[b.id];

  /// CB-46: keeps a wake SubMac could not run yet. False when the same wake is already held.
  Future<bool> holdWake(Bot b, String key, String reason, String instruction, String kind) async {
    final held = _held();
    if (held.any((w) => w.key == key)) return false;
    held.add(HeldWake(b.id, key, reason, instruction, kind, clock()));
    while (held.length > 20) {
      held.removeAt(0);
    }
    await _p?.setString(_heldKey, jsonEncode([for (final w in held) w.toJson()]));
    return true;
  }

  List<HeldWake> _held() {
    try {
      return [for (final e in jsonDecode(_p?.getString(_heldKey) ?? '[]') as List) HeldWake.fromJson(Map<String, dynamic>.from(e as Map))];
    } catch (_) {
      return [];
    }
  }

  /// The held wakes, taken (each runs once). Empty until the bots are loaded.
  Future<List<HeldWake>> takeHeldWakes() async {
    if (_p == null) return const [];
    final held = _held();
    if (held.isNotEmpty) await _p!.remove(_heldKey);
    return held;
  }

  @visibleForTesting
  List<HeldWake> get heldForTest => _held();

  Future<void> armAll() async {
    for (final b in bots) {
      await arm(b);
    }
  }

  /// Sets the next alarm for each routine, follow-up and the heartbeat.
  Future<void> arm(Bot b) async {
    final now = DateTime.now();
    final rNow = clock();
    var runsChanged = false;
    for (final r in b.routines) {
      final owned = b.active && !_cloud(b, r.id);
      DateTime? n;
      if (owned) {
        // CB-21: a run missed while SubMac was stopped is caught up in a minute (within a few hours of its time).
        final had = _runs['${b.id}|${r.id}']?['sch'] == r.schedule;
        final since = _since(b, r, rNow);
        if (!had) runsChanged = true;
        n = r.catchUp(rNow, lastSlot: _lastSlot(b, r), since: since) ?? r.next(rNow);
      }
      _routineAlarms[alarmId(b, r.id)] = n;
      if (n != null) {
        await SystemBridge.I.scheduleAlarm(alarmId(b, r.id), n);
      } else {
        await SystemBridge.I.cancelAlarm(alarmId(b, r.id));
      }
    }
    if (runsChanged) await _saveRuns();
    for (final f in List.of(b.followups)) {
      if (!b.active || _cloud(b, f.id)) {
        await SystemBridge.I.cancelAlarm(alarmId(b, f.id));
        continue;
      }
      await SystemBridge.I.scheduleAlarm(alarmId(b, f.id), f.at.isBefore(now) ? now.add(const Duration(seconds: 20)) : f.at);
    }
    final at = _heartbeatAt(b, now);
    if (b.active && at != null && !_cloud(b, 'hb')) {
      await SystemBridge.I.scheduleAlarm(alarmId(b, 'hb'), at);
    } else {
      await SystemBridge.I.cancelAlarm(alarmId(b, 'hb'));
    }
    final rep = BotReports.nextAt(b.report, now);
    if (b.active && rep != null) {
      await SystemBridge.I.scheduleAlarm(alarmId(b, 'rep'), rep);
    } else {
      await SystemBridge.I.cancelAlarm(alarmId(b, 'rep'));
    }
  }

  /// The note for tonight's (or this week's) report, or '' when there is nothing worth saying. [waiting] = asks of
  /// this bot that wait for the owner.
  String reportFor(Bot b, {required bool weekly, int waiting = 0, DateTime? now}) {
    final t = now ?? DateTime.now();
    final since = weekly ? t.subtract(const Duration(days: 7)) : DateTime(t.year, t.month, t.day);
    final done = <String>[
      for (final e in b.journal)
        if (!e.at.isBefore(since) && e.kind == 'work' && e.text.startsWith('Done: ')) e.text.substring(6),
    ];
    var sent = 0;
    for (final e in b.journal) {
      if (!e.at.isBefore(since) && (e.kind == 'message' || e.kind == 'note' || e.kind == 'call')) sent++;
    }
    final working = [for (final d in b.desk) if (d.status == 'doing' || d.status == 'todo') d.text];
    final needs = [for (final d in b.desk) if (d.status == 'waiting') d.text];
    final next = nextWork(b);
    return BotReports.compose(
      weekly: weekly,
      done: done,
      sent: sent,
      working: working,
      needs: needs,
      waiting: waiting,
      next: next == null ? '' : _when(next),
      week: weekly ? weekReport(b) : '',
    );
  }

  /// When the next heartbeat is due, or null when the bot has none.
  DateTime? _heartbeatAt(Bot b, DateTime now) {
    final hb = b.effectiveHeartbeat;
    if (hb <= 0) return null;
    var at = (b.lastWake ?? now).add(Duration(hours: hb));
    if (at.isBefore(now)) at = now.add(const Duration(minutes: 3));
    // Never in quiet hours: move to when they end.
    if (b.quietNow(at)) {
      var d = DateTime(at.year, at.month, at.day, b.quietTo, 5 + (b.id.hashCode % 20).abs());
      if (!d.isAfter(at)) d = d.add(const Duration(days: 1));
      at = d;
    }
    return at;
  }

  /// When the next heartbeat is due, or null.
  DateTime? nextHeartbeat(Bot b) => _heartbeatAt(b, DateTime.now());

  /// The next time this bot wakes on its own (routine, follow-up or heartbeat), or null.
  DateTime? nextWork(Bot b) {
    if (!b.active) return null;
    final now = DateTime.now();
    DateTime? best;
    void take(DateTime? d) {
      if (d != null && (best == null || d.isBefore(best!))) best = d;
    }
    for (final r in b.routines) {
      take(r.next(now));
    }
    for (final f in b.followups) {
      take(f.at.isBefore(now) ? now : f.at);
    }
    take(_heartbeatAt(b, now));
    return best;
  }

  /// The last time this bot did real work (not a skipped wake).
  DateTime? lastWorked(Bot b) {
    for (final e in b.journal.reversed) {
      if (const {'work', 'message', 'call', 'note', 'learned'}.contains(e.kind)) return e.at;
    }
    return b.lastWake;
  }

  static String _when(DateTime d) {
    final now = DateTime.now();
    final hm = '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    final day = DateTime(d.year, d.month, d.day).difference(DateTime(now.year, now.month, now.day)).inDays;
    if (day == 0) return hm;
    if (day == 1) return 'tomorrow $hm';
    if (day == -1) return 'yesterday $hm';
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return day.abs() < 7 ? '${names[d.weekday - 1]} $hm' : '${d.day}/${d.month} $hm';
  }

  /// Health line (plan 2.1), short words (UI rules): "Worked 08:02 · next 18:00". Empty when the bot is off.
  String health(Bot b) {
    if (!b.active) return '';
    final last = lastWorked(b);
    final next = nextWork(b);
    final parts = [
      if (last != null) 'Worked ${_when(last)}',
      next == null ? 'on request' : '${last == null ? 'Next' : 'next'} ${_when(next)}',
    ];
    return parts.join(' · ');
  }

  /// Weekly report card (plan 2.3): what the bot did in the last 7 days, counted from its journal. Empty when nothing.
  String weekReport(Bot b) {
    final since = DateTime.now().subtract(const Duration(days: 7));
    var work = 0, messages = 0, calls = 0, done = 0, learned = 0, missed = 0;
    for (final e in b.journal) {
      if (e.at.isBefore(since)) continue;
      switch (e.kind) {
        case 'work':
          if (e.text.startsWith('Done: ')) {
            done++;
          } else if (!e.text.startsWith('Checked in')) {
            work++;
          }
        case 'message':
        case 'note':
          messages++;
        case 'call':
          calls++;
        case 'learned':
          learned++;
        case 'missed':
          missed++;
      }
    }
    String n(int c, String one, String many) => '$c ${c == 1 ? one : many}';
    final parts = [
      if (done > 0) n(done, 'task done', 'tasks done'),
      if (work > 0) n(work, 'job', 'jobs'),
      if (messages > 0) n(messages, 'message', 'messages'),
      if (calls > 0) n(calls, 'call', 'calls'),
      if (learned > 0) n(learned, 'thing learned', 'things learned'),
    ];
    if (parts.isEmpty) return '';
    return '${b.name} this week: ${parts.join(', ')}${missed > 0 ? ' (${n(missed, 'missed call', 'missed calls')})' : ''}.';
  }

  Future<void> disarm(Bot b) async {
    await SystemBridge.I.cancelAlarm(alarmId(b, 'hb'));
    await SystemBridge.I.cancelAlarm(alarmId(b, 'rep'));
    for (final r in b.routines) {
      await SystemBridge.I.cancelAlarm(alarmId(b, r.id));
    }
    for (final f in b.followups) {
      await SystemBridge.I.cancelAlarm(alarmId(b, f.id));
    }
  }

  /// An alarm with a bot| id fired.
  Future<bool> fire(String alarm) async {
    if (_p == null) await init();
    final p = alarm.split('|');
    if (p.length < 3) return false;
    final b = byId(p[1]);
    if (b == null || !b.active) return false;
    final what = p[2];
    // An alarm set before the cloud took this job over (plan 2.1 part B): the cloud runs it, the phone stays quiet.
    if (_cloud(b, what)) {
      await arm(b);
      return false;
    }
    if (what == 'rep') {
      await arm(b);
      final now = DateTime.now();
      final weekly = b.report == 'weekly' || now.weekday == DateTime.sunday;
      final key = 'Report ${now.year}-${now.month}-${now.day}';
      if (b.journal.any((e) => e.kind == 'report' && e.text == key)) return false;
      final text = reportFor(b, weekly: weekly, waiting: waitingFor?.call(b) ?? 0);
      if (text.isEmpty) return false;
      b.log('report', key);
      await save();
      await onReport?.call(b, text, notify: weekly);
      return true;
    }
    if (what == 'hb') {
      b.lastWake = DateTime.now();
      await save();
      await arm(b);
      if (b.quietNow()) return false;
      await onWake?.call(b, 'heartbeat', '', 'work');
      return true;
    }
    final r = b.routines.where((e) => e.id == what).firstOrNull;
    if (r != null) {
      // CB-35: once per slot. Claimed before the first await, so two deliveries at once wake the bot once, and a late
      // redelivery (Android can repeat an exact alarm) neither runs the routine again nor queues a follow-up.
      final now = clock();
      if (!_claimSlot(b, r, now)) {
        await arm(b);
        return false;
      }
      final key = _wakeKeys[b.id]!;
      final slot = r.prev(now.add(const Duration(minutes: 2)))!;
      await _saveRuns();
      await arm(b);
      final late = now.difference(slot) > const Duration(minutes: 5);
      _wakeKeys[b.id] = key;
      try {
        await onWake?.call(b, late ? 'routine (${r.time} ${r.days}, caught up: SubMac was stopped at ${r.time})' : 'routine (${r.time} ${r.days})',
            r.instruction, r.kind);
      } finally {
        if (_wakeKeys[b.id] == key) _wakeKeys.remove(b.id);
      }
      return true;
    }
    final f = b.followups.where((e) => e.id == what).firstOrNull;
    if (f != null) {
      b.followups.remove(f);
      await save();
      final key = '${b.id}|${f.id}';
      _wakeKeys[b.id] = key;
      try {
        await onWake?.call(b, 'follow-up you set', f.instruction, f.kind);
      } finally {
        if (_wakeKeys[b.id] == key) _wakeKeys.remove(b.id);
      }
      return true;
    }
    return false;
  }

  /// A phone notification matched one of a bot's watches.
  Future<void> notificationEvent(Map<String, dynamic> e) async {
    final b = byId('${e['bot']}');
    if (b == null || !b.active) return;
    final w = b.watches.where((x) => x.id == '${e['id']}').firstOrNull;
    if (w == null) return;
    if ('${e['chat'] ?? ''}'.isNotEmpty) {
      // A WhatsApp message (plan: WhatsApp on the phone). The reply goes through the owner's approval card.
      await onWake?.call(b, 'a new ${e['app'] ?? 'WhatsApp'} message from ${e['chat']}',
          '${w.instruction}\nNew ${e['app'] ?? 'WhatsApp'} message in "${e['chat']}": "${e['text'] ?? ''}"\n'
              'If it needs an answer, draft a short reply in the chat\'s language and send it with whatsapp action "reply" '
              '(to: "${e['chat']}"); the owner approves it first. Use whatsapp action "inbox" with to "${e['chat']}" for the latest messages.',
          'work');
      return;
    }
    await onWake?.call(b, 'a notification from ${e['app'] ?? 'an app'}',
        '${w.instruction}\nThe notification: "${e['title'] ?? ''}: ${e['text'] ?? ''}"', 'work');
  }

  // ---------------------------------------------------------------- hiring and budget

  Future<void> hire(Bot b, String convId) async {
    b.active = true;
    b.convId = convId;
    b.lastWake = DateTime.now();
    b.log('work', 'Started working with you.');
    Events.I.hired(b.id, b.origin);
    await save();
    await arm(b);
  }

  Future<void> pause(Bot b) async {
    b.active = false;
    await disarm(b);
    b.log('work', 'Paused.');
    await save();
  }

  Future<void> resume(Bot b) async {
    b.active = true;
    await save();
    await arm(b);
  }

  Future<void> remove(Bot b) async {
    if (isChief(b)) {
      chiefId = '';
      await _p?.remove('bot_chief_v1');
    }
    await disarm(b);
    await SkillLibrary.I.forget(b.id);
    await _p?.remove(_kKey(b.id));
    bots.remove(b);
    await save();
  }

  Future<Bot> create(Map<String, dynamic> spec) async {
    final b = Bot(
      id: 'u${DateTime.now().millisecondsSinceEpoch}',
      name: '${spec['name'] ?? 'Assistant'}'.trim(),
      role: '${spec['role'] ?? ''}'.trim(),
      persona: '${spec['persona'] ?? ''}'.trim(),
      mission: '${spec['mission'] ?? ''}'.trim(),
      icon: '${spec['icon'] ?? 'person'}',
      look: '${spec['look'] ?? 'calm'}',
      proactivity: '${spec['proactivity'] ?? 'balanced'}',
      heartbeatHours: (spec['heartbeat_hours'] is num) ? (spec['heartbeat_hours'] as num).toInt().clamp(0, 48).toInt() : 0,
      firstMeeting: '${spec['first_meeting'] ?? ''}',
    )..trust = BotTrust.levelNew;
    for (final r in (spec['routines'] as List? ?? const [])) {
      final m = Map<String, dynamic>.from(r as Map);
      b.routines.add(BotRoutine(
          id: 'r${b.routines.length + 1}',
          time: '${m['time'] ?? '09:00'}',
          days: '${m['days'] ?? 'daily'}',
          kind: '${m['kind'] ?? 'work'}',
          instruction: '${m['do'] ?? m['instruction'] ?? ''}'));
    }
    bots.add(b);
    await save();
    return b;
  }

  /// Turns a model hint from a package (a model name, or 'auto') into one of the owner's own models (set by AppState).
  String Function(String hint)? resolveModel;

  /// Whether the owner has this app connected (set by AppState): its own login, key or sign-in.
  bool Function(BotApp app)? isAppConnected;

  bool appReady(BotApp a) => isAppConnected?.call(a) ?? false;

  /// The bot's apps that its owner still has to connect.
  List<BotApp> appsNeeded(Bot b) => [for (final a in b.apps) if (!appReady(a)) a];

  /// A bot from a package: a shared file, a code, the Bot Store or an office copy. The package is checked by the same
  /// strict gate as on the way out (BotPackage.sanitize). Returns null when the text is not a SubMac bot.
  Future<Bot?> importBot(Map<String, dynamic> raw, {String origin = 'shared'}) async {
    final j = BotPackage.sanitize(raw);
    if (j == null) return null;
    var name = '${j['name']}';
    if (bots.any((b) => b.name.toLowerCase() == name.toLowerCase())) {
      var n = 2;
      while (bots.any((b) => b.name.toLowerCase() == '$name $n'.toLowerCase())) {
        n++;
      }
      name = '$name $n';
    }
    final b = await create({...j, 'name': name});
    b
      ..voice = '${j['voice']}'
      ..quietFrom = j['quiet_from'] as int
      ..quietTo = j['quiet_to'] as int
      ..allowCalls = j['calls'] == true
      ..tokenBudgetK = j['token_budget_k'] as int
      ..instructions = '${j['instructions']}'
      ..sandbox = j['sandbox'] == true
      ..model = resolveModel?.call('${j['model']}') ?? 'auto'
      // A copy uses only the apps it came with (each connected with the new owner's own login).
      ..appsScoped = true
      ..origin = origin;
    b.powersOff.addAll([for (final e in j['powers_off'] as List) '$e']);
    for (final a in j['apps'] as List) {
      final app = BotApp.fromJson(Map<String, dynamic>.from(a as Map));
      if (app != null) b.apps.add(app);
    }
    for (final k in j['knowledge'] as List) {
      final m = Map<String, dynamic>.from(k as Map);
      b.knowledge.add(BotKnowledge(
          id: 'k${DateTime.now().microsecondsSinceEpoch}${b.knowledge.length}',
          title: '${m['title']}',
          text: '${m['text']}',
          kind: '${m['kind']}',
          file: '${m['file']}'));
    }
    for (final l in j['lessons'] as List) {
      b.lessons.add(BotLesson('$l', source: 'shared'));
    }
    for (final id in j['skills'] as List) {
      unawaited(SkillLibrary.I.install(b.id, '$id'));
    }
    b.log('note', origin.startsWith('store:') ? 'Added from the Bot Store' : 'Joined from a shared copy');
    await saveKnowledge(b);
    await save();
    return b;
  }

  /// The user wrote to the bot: they're engaged, so it can speak up as usual again.
  void userReplied(String convId) {
    final b = byConv(convId);
    if (b == null) return;
    b.lastUserReply = DateTime.now();
    b.ignoredStreak = 0;
    Events.I.ownerWrote(b.id);
    unawaited(save());
  }

  /// Can this bot reach out this way right now? Returns the kind it may actually use (a call can drop to a message,
  /// a message to a quiet note).
  String allow(Bot b, String kind) {
    // An earlier outreach left unanswered counts as ignored.
    if (b.lastOutreach != null && (b.lastUserReply == null || b.lastUserReply!.isBefore(b.lastOutreach!))) {
      if (DateTime.now().difference(b.lastOutreach!).inHours >= 6) {
        b.ignoredStreak++;
        b.lastOutreach = null; // counted once
      }
    }
    if (kind == 'call') {
      if (callBlock(b) != null) kind = 'message';
    }
    if (kind == 'message') {
      if (b.quietNow() || b.messagesLeft <= 0) kind = 'note';
    }
    return kind;
  }

  void spent(Bot b, String kind) {
    b._rollDay();
    if (kind == 'message') b.messagesToday++;
    if (kind == 'call') b.callsToday++;
    if (kind == 'message' || kind == 'call') b.lastOutreach = DateTime.now();
    unawaited(save());
  }

  // ---------------------------------------------------------------- the bot's prompt

  String promptFor(String? convId) {
    final b = byConv(convId);
    if (b == null) return '';
    return stablePromptOf(b);
  }

  /// What a bot's chat prompt carries after SubMac's part: knowledge, apps, memory, lessons, powers.
  String memoryPromptFor(String? convId) {
    final b = byConv(convId);
    return b == null ? '' : memoryPromptOf(b);
  }

  /// The parts of a bot's prompt that change while it works (desk, follow-ups, journal). Sent at the end
  /// of the prompt so the identity part before it stays the same from step to step.
  String livePromptFor(String? convId) {
    final b = byConv(convId);
    return b == null ? '' : livePromptOf(b);
  }

  /// Bot calls ring full screen instead of at the top of the screen (a setting).
  bool get fullScreenCalls => _p?.getBool('bot_full_calls') ?? false;
  Future<void> setFullScreenCalls(bool v) async {
    await _p?.setBool('bot_full_calls', v);
    notifyListeners();
  }

  /// A few lines for small talk: who the bot is and the gist of what it knows, so "hi" is instant and still in character.
  String quickPromptOf(Bot b) {
    final sb = StringBuffer()
      ..writeln('You are ${b.name}, the user\'s ${b.role}, a senior colleague who lives in SubMac on their phone. '
          'Never call yourself an AI model or SubMac.')
      ..writeln(b.persona)
      ..writeln(HouseRules.core)
      ..writeln(BotManner.block);
    if (b.mission.isNotEmpty) sb.writeln('Your mission: ${b.mission}');
    if (b.instructions.trim().isNotEmpty) {
      final t = b.instructions.trim();
      sb.writeln('Your instructions: ${t.length > 400 ? '${t.substring(0, 400)}…' : t}');
    }
    final mem = b.memory.reversed.take(8).toList().reversed;
    if (mem.isNotEmpty) sb.writeln('What you know about them: ${mem.join('; ')}');
    final open = b.desk.where((t) => t.status != 'done').take(3).map((t) => t.text).toList();
    if (open.isNotEmpty) sb.writeln('On your desk: ${open.join('; ')}');
    return sb.toString().trim();
  }

  /// Who the bot is and how it works. Only what the owner set up, so it stays byte-identical from step to step and
  /// from day to day (prompt cache). What it learns (memory, lessons) is in [memoryPromptOf], sent after SubMac's part.
  String stablePromptOf(Bot b) {
    final sb = StringBuffer()
      ..writeln('# Who you are')
      ..writeln('You are ${b.name}, the user\'s ${b.role.isEmpty ? 'colleague' : b.role}. You work for them inside SubMac like a trusted employee: '
          'you own your job, take initiative, remember what matters and keep every promise.')
      ..writeln(b.persona)
      ..writeln('Stay in character: you are ${b.name}, never "an AI" or SubMac. Write like a calm colleague in a work group: short, warm, '
          'specific; headings only in a report.')
      ..writeln()
      ..writeln(HouseRules.core)
      ..writeln()
      ..writeln(BotManner.block);
    if (b.mission.isNotEmpty) sb.writeln('\nYour job for this user: ${b.mission}');
    if (isChief(b)) {
      final others = bots.where((o) => o != b).map((o) => '${o.name} (${o.role})').join(', ');
      sb
        ..writeln('\n# You are the Chief')
        ..writeln('You lead the owner\'s bots. Colleagues: ${others.isEmpty ? 'none yet' : others}.')
        ..writeln('- When the owner wants a new bot ("make me a sales bot"), design it with bot_make action "draft", show the draft in a few '
            'quiet lines (name and role, its job, how it works, skills) and ask "Make it?". Call bot_make action "create" only after a clear yes.')
        ..writeln('- When the owner wants a team ("start a team for the shop launch"), design it with team_make action "draft" the same way: '
            'a name, a goal, who leads it, and its members — existing colleagues by name, new ones described in a few words (they get made). '
            'Call team_make action "create" only after a clear yes. The team waits for the owner\'s first task in its chat.')
        ..writeln('- A question a colleague knows best: ask them with bot_ask and give the owner one combined answer.');
    }
    if (b.instructions.trim().isNotEmpty) {
      sb
        ..writeln('\n# Your instructions (from the owner, always follow them)')
        ..writeln(b.instructions.trim());
    }
    sb
      ..writeln('\n# How you work')
      ..writeln('- Your Job page shows the owner what you do: "Working on" is your task list (bot_desk), "Responsibilities" are your regular '
          'jobs (bot_routine at a time, bot_watch when a phone notification arrives) and promised follow-ups (bot_followup).')
      ..writeln('- Multi-step work: put the real steps on bot_desk, work through them, keep each status current. Small questions need no list.')
      ..writeln('- A long build the owner asks for (an app, a website, software, a big report): settle their decisions first, then the todo '
          'checklist with every step, and keep going in the same task until all of it is built and checked. You have room for hundreds of '
          'steps: never stop half way to ask "shall I continue?", never leave stubs or placeholders. After a pause, "continue" picks up your plan.')
      ..writeln('- Learn a preference, goal, deadline or fact about their work: bot_remember at once. Promise to come back later: create the '
          'bot_followup in the same turn. A regular thing ("every morning", "call me Fridays"): bot_routine.')
      ..writeln('- Check your work before you deliver: exactly what was asked, facts and numbers right, sources linked. Long work goes in a document.')
      ..writeln('- Stuck (two failed tries, or missing information): ask a colleague with bot_ask, your team lead in a team, or the owner one clear question. '
          'After a mistake or a correction, save one general lesson with bot_lesson (never names or private facts).')
      ..writeln(FullAccess.I.on
          ? '- The owner turned on Full access: your actions run without an approval card, except payments and purchases. Just call the tool.'
          : '- Your trust level is ${b.level == BotTrust.levelTrusted ? 'Trusted: routine changes run; money, sending, posting and deleting still get the owner\'s approval card' : 'New: every action that changes something gets the owner\'s approval card first'}. '
          'Just call the tool; the card (Approve · Edit · Not now) appears by itself, so never ask twice in text.')
      ..writeln('- Never say something is done, sent or running unless a tool result shows it. Never invent facts.')
      ..writeln('\n# How you reply')
      ..writeln('- A simple question: a sentence or two. A task: start with one short line on what you will do (it shows while you work), '
          'do the work, then deliver a clean result: the outcome first, the details that matter (short list or table), at most one next step.')
      ..writeln('- Plain words in the owner\'s language (Somali, Arabic, English...). Never mention tools, steps, prompts or systems; '
          'no filler, no emoji. Ask only when you truly can\'t go on without the answer: one clear question.');
    return sb.toString().trim();
  }

  /// What the bot learned and works with: knowledge titles, apps, memory and lessons. Changes now and then, so it goes
  /// after the stable part of the prompt.
  String memoryPromptOf(Bot b) {
    final others = hired.where((o) => o != b).map((o) => '${o.name} (${o.role})').join(', ');
    final sb = StringBuffer();
    sb.write(_knowledgePrompt(b));
    sb.write(_appsPrompt(b));
    sb.writeln('\n# Colleagues you can ask (bot_ask)');
    sb.writeln(others.isEmpty ? 'None hired yet.' : others);
    sb.writeln('\n# What you know about the user and the work');
    if (b.memory.isEmpty) {
      sb.writeln('Nothing yet. Save what matters with bot_remember.');
    } else {
      for (final m in b.memory.reversed.take(60).toList().reversed) {
        sb.writeln('- $m');
      }
    }
    final lessons = topLessons(b);
    if (lessons.isNotEmpty) {
      sb.writeln('\n# Lessons you learned (follow them)');
      for (final l in lessons) {
        sb.writeln('- ${l.text}');
      }
    }
    final n = BotPowers.note(b.powersOff);
    if (n.isNotEmpty) sb.writeln('\n$n');
    return sb.toString().trim();
  }

  /// The bot's whole text-chat prompt (identity, what it knows, its desk), for one-off calls like bot_ask.
  String chatPromptOf(Bot b) => '${stablePromptOf(b)}\n\n${memoryPromptOf(b)}\n\n${livePromptOf(b)}'.trim();

  /// The identity text Live calls still use (kept as it was; calls are tuned separately).
  String _callStablePromptOf(Bot b) {
    final others = hired.where((o) => o != b).map((o) => '${o.name} (${o.role})').join(', ');
    final sb = StringBuffer()
      ..writeln('# Who you are')
      ..writeln('You are ${b.name}, the user\'s ${b.role}. You live inside SubMac on their phone and work for them like a dedicated, '
          'senior colleague: you take initiative, own your work, remember everything relevant, and follow through on every promise.')
      ..writeln(b.persona)
      ..writeln('Stay in character in every message. Never call yourself an AI model or SubMac; you are ${b.name}. '
          'You talk like a real person texting a colleague: short, warm, specific, no filler, no headings unless you deliver a report.');
    if (b.mission.isNotEmpty) sb.writeln('\nYour mission for this user: ${b.mission}');
    if (b.instructions.trim().isNotEmpty) {
      sb
        ..writeln('\n# Your instructions (from the person who set you up)')
        ..writeln(b.instructions.trim());
    }
    sb.write(_knowledgePrompt(b));
    sb.write(_appsPrompt(b));
    sb.writeln('\n# Your memory (what you know from working with this user)');
    if (b.memory.isEmpty) {
      sb.writeln('Nothing yet. Learn what matters and save it with bot_remember.');
    } else {
      for (final m in b.memory.reversed.take(60).toList().reversed) {
        sb.writeln('- $m');
      }
    }
    final lessons = topLessons(b);
    if (lessons.isNotEmpty) {
      sb.writeln('\n# Lessons you learned (your own know-how from past work; follow them)');
      for (final l in lessons) {
        sb.writeln('- ${l.text}');
      }
    }
    if (b.mission.isEmpty) {
      sb
        ..writeln('\n# Your goal')
        ..writeln('Be the best ${b.role.isEmpty ? 'colleague' : b.role} this person has ever had: useful, right, on time, and getting better every week.');
    }
    sb
      ..writeln('\n# How you think')
      ..writeln('- Multi-step work: first write a short plan (put each real step on your desk with bot_desk), then work through it, '
          'updating the desk as you go. Small questions need no plan.')
      ..writeln('- Before you post, send or deliver anything, check your own work: does it answer exactly what was asked, are facts '
          'and numbers right and sourced, does it follow your instructions and lessons? Fix it first, then send.')
      ..writeln('- When you are stuck (two failed tries, or missing information), do not guess: ask a colleague with bot_ask, or in an '
          'office ask the Chief, or ask the owner one clear question.')
      ..writeln('- After a mistake, a tool error you worked around, or a correction from the owner, save one short, general lesson with '
          'bot_lesson (how to do the work better next time). Never put names, contact details or private facts in a lesson.')
      ..writeln('\n# How you work')
      ..writeln('- Use all your tools: web_search and fetch_url for research, browser_task for real websites, documents for deliverables, '
          'and your own: bot_remember (save what you learn about the user and the work), bot_desk (your task board), '
          'bot_followup (promise to come back at a time, and you will be woken then), bot_routine (recurring routines, e.g. a daily '
          'brief or a call), bot_watch (react to phone notifications), bot_call (ring the user now for a voice call), '
          'and bot_ask (ask another colleague: ${others.isEmpty ? 'none hired yet' : others}).')
      ..writeln('- Whenever you learn a preference, goal, deadline or fact about their work, save it with bot_remember at once.')
      ..writeln('- When you say you will do something later, create the bot_followup in the same turn. Never promise without it.')
      ..writeln('- When the user asks for a regular thing ("every morning", "call me on Fridays"), create a bot_routine.')
      ..writeln('- Deliver real work: sources with links, numbers, clear recommendations, and a document when it is long.');
    return sb.toString().trim();
  }

  /// The knowledge part of the prompt: only the titles. The text itself is read with knowledge_search / knowledge_read,
  /// so a big knowledge base costs almost nothing per step.
  String _knowledgePrompt(Bot b) {
    if (b.knowledge.isEmpty && !b.sandbox) return '';
    final sb = StringBuffer('\n# Your knowledge\n');
    if (b.knowledge.isEmpty) {
      sb.writeln('You have no knowledge added yet.');
    } else {
      sb.writeln('You carry ${b.knowledge.length} piece(s) of knowledge. Search them with knowledge_search and read more with '
          'knowledge_read before you answer anything they may cover. Say which piece you used.');
      for (final k in b.knowledge.take(25)) {
        sb.writeln('- [${k.id}] ${k.title}${k.kind == 'file' && k.file.isNotEmpty ? ' (file ${k.file})' : ''}');
      }
      if (b.knowledge.length > 25) sb.writeln('- …and ${b.knowledge.length - 25} more (knowledge_search finds them).');
    }
    if (b.sandbox) {
      sb.writeln('Knowledge sandbox is ON: answer ONLY from your knowledge. You have no web search or browser. If the answer is '
          'not in your knowledge, say plainly that you do not have it in what you were given, and stop. Never guess or use '
          'outside facts.');
    } else {
      sb.writeln('Use your knowledge first. When it does not cover the question, you may look elsewhere (web, browser, apps) and '
          'say that the answer came from outside your knowledge.');
    }
    return sb.toString();
  }

  /// Which apps it is set up with, and which still need connecting, so it never promises what it cannot reach.
  String _appsPrompt(Bot b) {
    if (!b.appsScoped && b.apps.isEmpty) return '';
    final ready = [for (final a in b.apps) if (appReady(a)) a.name];
    final missing = [for (final a in b.apps) if (!appReady(a)) a.name];
    final sb = StringBuffer('\n# Your apps\n');
    if (b.apps.isEmpty) {
      sb.writeln('You are not set up with any connected apps. When a job needs one, say which app you would need.');
    } else {
      if (ready.isNotEmpty) sb.writeln('Ready to use: ${ready.join(', ')}.');
      if (missing.isNotEmpty) {
        sb.writeln('Not connected yet: ${missing.join(', ')}. When a job needs one of these, tell the owner plainly in one line, e.g. '
            '"I need ${missing.first} for this. Open my settings > Apps and tap Connect." Then do what you can without it.');
      }
    }
    if (b.appsScoped) sb.writeln('Use only these apps; other apps the owner has are not yours to use.');
    return sb.toString();
  }

  String promptOf(Bot b) => '${_callStablePromptOf(b)}\n\n${livePromptOf(b)}'.trim();

  String livePromptOf(Bot b) {
    final sb = StringBuffer();
    final open = b.desk.where((t) => t.status != 'done').toList();
    sb.writeln('\n# Your desk');
    if (open.isEmpty) {
      sb.writeln('No open tasks.');
    } else {
      for (final t in open.take(25)) {
        sb.writeln('- [${t.id}] (${t.status}) ${t.text}${t.note.isEmpty ? '' : ' — ${t.note}'}');
      }
    }
    if (b.routines.isNotEmpty) {
      sb.writeln('\n# Your routines');
      for (final r in b.routines) {
        sb.writeln('- ${r.id}: ${r.describe()}');
      }
    }
    if (b.followups.isNotEmpty) {
      sb.writeln('\n# Follow-ups you promised');
      for (final f in b.followups) {
        sb.writeln('- ${f.at.toIso8601String().substring(0, 16)}: ${f.instruction}');
      }
    }
    final recent = b.journal.reversed.take(8).toList().reversed;
    if (recent.isNotEmpty) {
      sb.writeln('\n# Lately');
      for (final j in recent) {
        sb.writeln('- ${j.at.toIso8601String().substring(5, 16).replaceFirst('T', ' ')} ${j.kind}: ${j.text}');
      }
    }
    return sb.toString().trim();
  }

  // ---------------------------------------------------------------- the bot's own tools

  static const names = {
    'bot_remember', 'bot_desk', 'bot_followup', 'bot_routine', 'bot_watch', 'bot_call', 'bot_ask', 'knowledge_search', 'knowledge_read',
    'bot_lesson', 'bot_make', 'team_make',
  };

  /// The tools only the Chief sees.
  static const _chiefOnly = {'bot_make', 'team_make'};

  /// The tools a bot sees: bot_make and team_make only for the Chief.
  List<Map<String, dynamic>> definitionsFor(Bot? b) => [
        for (final d in definitions)
          if (!_chiefOnly.contains((d['function'] as Map)['name']) || (b != null && isChief(b))) d,
      ];

  static Map<String, dynamic> _fn(String name, String desc, Map<String, dynamic> props, List<String> req) => {
        'type': 'function',
        'function': {
          'name': name,
          'description': desc,
          'parameters': {'type': 'object', 'properties': props, 'required': req},
        },
      };

  static final List<Map<String, dynamic>> definitions = [
    _fn('bot_remember', 'Save something to your long-term memory about this user or their work (or forget a line).', {
      'fact': {'type': 'string'},
      'forget': {'type': 'string', 'description': 'Words from a memory line to delete instead.'},
    }, []),
    _fn('bot_desk', 'Your task board: add a task, update its status (todo, doing, waiting, done), or list it.', {
      'action': {'type': 'string', 'enum': ['add', 'update', 'list']},
      'task': {'type': 'string'},
      'id': {'type': 'string'},
      'status': {'type': 'string', 'enum': ['todo', 'doing', 'waiting', 'done']},
      'note': {'type': 'string'},
    }, ['action']),
    _fn('bot_followup', 'Come back later on your own: at that time you are woken with this instruction.', {
      'when': {'type': 'string', 'description': 'Local date and time, e.g. 2026-10-18T09:00.'},
      'instruction': {'type': 'string'},
      'kind': {'type': 'string', 'enum': ['work', 'message', 'call'], 'description': 'call = ring the user then.'},
    }, ['when', 'instruction']),
    _fn('bot_routine', 'Add, change or remove a recurring routine (a daily brief, a weekly report, a lesson call).', {
      'action': {'type': 'string', 'enum': ['add', 'remove', 'list']},
      'id': {'type': 'string'},
      'time': {'type': 'string', 'description': 'HH:MM local time.'},
      'days': {'type': 'string', 'description': 'daily, weekdays, weekends, or names like mon,wed,fri.'},
      'kind': {'type': 'string', 'enum': ['work', 'message', 'call']},
      'instruction': {'type': 'string'},
    }, ['action']),
    _fn('bot_watch', 'React to phone notifications: when one from an app (and/or containing a keyword) arrives, you are woken.', {
      'action': {'type': 'string', 'enum': ['add', 'remove', 'list']},
      'id': {'type': 'string'},
      'app': {'type': 'string', 'description': 'App name, e.g. WhatsApp, Gmail.'},
      'keyword': {'type': 'string'},
      'instruction': {'type': 'string'},
    }, ['action']),
    _fn('bot_call', 'Ring the user now for a voice call with you (only when they asked, or it is truly worth a call).', {
      'reason': {'type': 'string', 'description': 'Shown on the ringing screen, e.g. "Your contract review is ready".'},
    }, ['reason']),
    _fn('bot_ask', 'Ask a colleague bot for their expert view and get their answer.', {
      'bot': {'type': 'string', 'description': 'Their name or role.'},
      'question': {'type': 'string'},
    }, ['bot', 'question']),
    _fn('bot_lesson', 'Your lessons: save a short, general how-to lesson you learned (one line, no personal details), remove one, or list them.', {
      'action': {'type': 'string', 'enum': ['add', 'remove', 'list']},
      'lesson': {'type': 'string', 'description': 'e.g. "Check the site\'s search page before saying a product is out of stock."'},
    }, ['action']),
    _fn('bot_make', 'Chief only. Make a new bot for the owner. First call with action "draft": it returns the draft to show the '
        'owner. Show it in a few quiet lines and ask for a yes. Only after they say yes, call action "create" (no other fields). '
        'To change the draft, call "draft" again.', {
      'action': {'type': 'string', 'enum': ['draft', 'create']},
      'name': {'type': 'string', 'description': 'A short human first name.'},
      'role': {'type': 'string', 'description': 'Job title, e.g. "Sales lead".'},
      'instructions': {'type': 'string', 'description': 'How the bot works: 3-6 short sentences in the owner\'s language.'},
      'mission': {'type': 'string', 'description': 'One sentence: its job for the owner.'},
      'skills': {'type': 'array', 'items': {'type': 'string'}, 'description': 'Up to 5 short skill names, e.g. "follow-up emails".'},
      'icon': {'type': 'string', 'enum': ['person', 'school', 'gavel', 'trending_up', 'travel_explore', 'fitness_center', 'payments', 'edit', 'code', 'work', 'favorite', 'campaign']},
    }, ['action']),
    _fn('team_make', 'Chief only. Make a team: a lead bot and its members working together in one chat. First call with action "draft": it returns '
        'the draft to show the owner. Show it in a few quiet lines and ask for a yes. Only after they say yes, call action "create" (no other '
        'fields). To change the draft, call "draft" again. Each member is an existing bot\'s name, or a plain description of a new bot to hire '
        '(it gets made). "chief" picks which member leads the team.', {
      'action': {'type': 'string', 'enum': ['draft', 'create']},
      'name': {'type': 'string', 'description': 'The team\'s name, e.g. "Shop launch".'},
      'goal': {'type': 'string', 'description': 'One sentence: what this team is for.'},
      'members': {'type': 'array', 'items': {'type': 'string'}, 'description': '2-8 members: an existing bot\'s name, or a description like "a designer who makes instagram posters".'},
      'chief': {'type': 'string', 'description': 'Which member leads (their name or the same description). Default: the first member.'},
      'rules': {'type': 'string', 'description': 'Optional working rules for the team, one line.'},
      'icon': {'type': 'string', 'enum': ['person', 'school', 'gavel', 'trending_up', 'travel_explore', 'fitness_center', 'payments', 'edit', 'code', 'work', 'favorite', 'campaign']},
    }, ['action', 'name', 'members']),
    _fn('knowledge_search', 'Search your own knowledge (notes and files you were given). Returns the best passages with their ids.', {
      'query': {'type': 'string', 'description': 'What you need, in a few words.'},
    }, ['query']),
    _fn('knowledge_read', 'Read one piece of your knowledge by id, from an offset (to read past a passage).', {
      'id': {'type': 'string'},
      'offset': {'type': 'integer', 'description': 'Character to start from (default 0).'},
    }, ['id']),
  ];

  /// Rings the user (set by AppState). Returns a result line.
  Future<String> Function(Bot b, String reason)? ring;
  /// One quick answer from another bot (set by AppState).
  Future<String> Function(Bot asker, Bot expert, String question)? consult;
  /// The Chief made a team from a draft (set by AppState): members resolved, hired, office opened.
  /// Returns an error line, or null when the team exists.
  Future<String?> Function(Bot chief, Map<String, dynamic> spec)? makeTeam;

  Future<String> execute(String name, Map<String, dynamic> a, String? convId) async {
    final b = byConv(convId);
    if (b == null) return 'Error: this tool only works inside a bot\'s own chat.';
    String s(String k) => '${a[k] ?? ''}'.trim();
    switch (name) {
      case 'bot_remember':
        if (s('forget').isNotEmpty) {
          final before = b.memory.length;
          b.memory.removeWhere((m) => m.toLowerCase().contains(s('forget').toLowerCase()));
          await save();
          return 'Forgot ${before - b.memory.length} line(s).';
        }
        if (s('fact').isEmpty) return 'Error: give the fact.';
        b.memory.removeWhere((m) => m.toLowerCase() == s('fact').toLowerCase());
        b.memory.add(s('fact'));
        while (b.memory.length > 150) {
          b.memory.removeAt(0);
        }
        b.log('learned', s('fact'));
        await save();
        return 'Remembered.';
      case 'bot_desk':
        switch (s('action')) {
          case 'add':
            if (s('task').isEmpty) return 'Error: give the task.';
            final t = DeskTask('t${DateTime.now().millisecondsSinceEpoch % 100000}', s('task'), status: a['status'] == null ? 'todo' : s('status'));
            b.desk.add(t);
            while (b.desk.length > 80) {
              final done = b.desk.indexWhere((x) => x.status == 'done');
              b.desk.removeAt(done >= 0 ? done : 0);
            }
            await save();
            return 'Added [${t.id}] ${t.text}.';
          case 'update':
            final t = b.desk.where((x) => x.id == s('id')).firstOrNull ??
                b.desk.where((x) => s('task').isNotEmpty && x.text.toLowerCase().contains(s('task').toLowerCase())).firstOrNull;
            if (t == null) return 'Error: no task ${s('id')}.';
            if (s('status').isNotEmpty) t.status = s('status');
            if (s('note').isNotEmpty) t.note = s('note');
            t.updated = DateTime.now();
            if (t.status == 'done') b.log('work', 'Done: ${t.text}');
            await save();
            return 'Updated [${t.id}] to ${t.status}.';
          default:
            final open = b.desk.where((t) => t.status != 'done');
            return open.isEmpty ? 'Desk is clear.' : open.map((t) => '[${t.id}] (${t.status}) ${t.text}').join('\n');
        }
      case 'bot_followup':
        final at = DateTime.tryParse(s('when').replaceAll(' ', 'T'));
        if (at == null) return 'Error: "when" must look like 2026-10-18T09:00.';
        if (s('instruction').isEmpty) return 'Error: say what to do then.';
        final f = BotFollowup('f${DateTime.now().millisecondsSinceEpoch % 1000000}', at, s('instruction'), s('kind').isEmpty ? 'work' : s('kind'));
        b.followups.add(f);
        while (b.followups.length > 30) {
          b.followups.removeAt(0);
        }
        await save();
        await arm(b);
        return 'You will be woken at ${at.toIso8601String().substring(0, 16)} to: ${f.instruction}.';
      case 'bot_routine':
        switch (s('action')) {
          case 'add':
            if (s('instruction').isEmpty || !RegExp(r'^\d{1,2}:\d{2}$').hasMatch(s('time'))) {
              return 'Error: give time as HH:MM and the instruction.';
            }
            final existing = b.routines.where((r) => r.id == s('id')).firstOrNull;
            final r = existing ?? BotRoutine(id: 'r${DateTime.now().millisecondsSinceEpoch % 100000}', time: s('time'), instruction: s('instruction'));
            r
              ..time = s('time')
              ..days = s('days').isEmpty ? 'daily' : s('days')
              ..kind = s('kind').isEmpty ? 'work' : s('kind')
              ..instruction = s('instruction');
            if (existing == null) b.routines.add(r);
            await save();
            await arm(b);
            return 'Routine ${r.id}: ${r.describe()}.';
          case 'remove':
            final r = b.routines.where((x) => x.id == s('id')).firstOrNull;
            if (r == null) return 'Error: no routine ${s('id')}.';
            b.routines.remove(r);
            await SystemBridge.I.cancelAlarm(alarmId(b, r.id));
            await save();
            return 'Removed.';
          default:
            return b.routines.isEmpty ? 'No routines.' : b.routines.map((r) => '${r.id}: ${r.describe()}').join('\n');
        }
      case 'bot_watch':
        switch (s('action')) {
          case 'add':
            if (s('app').isEmpty && s('keyword').isEmpty) return 'Error: give an app, a keyword, or both.';
            final w = BotWatch('w${DateTime.now().millisecondsSinceEpoch % 100000}', s('app'), s('keyword'), s('instruction'));
            b.watches.add(w);
            await save();
            return 'Watching ${w.app.isEmpty ? 'all apps' : w.app}${w.keyword.isEmpty ? '' : ' for "${w.keyword}"'} (${w.id}). '
                'This needs notification access, which the user turns on in SubMac permissions.';
          case 'remove':
            b.watches.removeWhere((w) => w.id == s('id'));
            await save();
            return 'Removed.';
          default:
            return b.watches.isEmpty ? 'No watches.' : b.watches.map((w) => '${w.id}: ${w.app} "${w.keyword}" → ${w.instruction}').join('\n');
        }
      case 'bot_lesson':
        switch (s('action')) {
          case 'add':
            final e = await addLesson(b, s('lesson'), source: 'self');
            return e ?? 'Lesson saved.';
          case 'remove':
            final before = b.lessons.length;
            b.lessons.removeWhere((l) => s('lesson').isNotEmpty && l.text.toLowerCase().contains(s('lesson').toLowerCase()));
            await save();
            return 'Removed ${before - b.lessons.length}.';
          default:
            return b.lessons.isEmpty ? 'No lessons yet.' : b.lessons.map((l) => '- ${l.text}').join('\n');
        }
      case 'knowledge_search':
        if (b.knowledge.isEmpty) return 'You have no knowledge added yet.${b.sandbox ? ' Say you do not have this in what you were given.' : ''}';
        final hits = BotPackage.search(b.knowledge, s('query'));
        if (hits.isEmpty) {
          return 'Nothing in your knowledge matches "${s('query')}". '
              '${b.sandbox ? 'Knowledge sandbox is on: tell the user you do not have this in what you were given.' : 'You may look elsewhere and say so.'}';
        }
        return [
          for (final h in hits) '[${h.$1.id} @${h.$2}] ${h.$1.title}\n${h.$3.replaceAll(RegExp(r'\s+'), ' ').trim()}',
        ].join('\n\n');
      case 'knowledge_read':
        final k = b.knowledge.where((x) => x.id == s('id')).firstOrNull ??
            b.knowledge.where((x) => x.title.toLowerCase() == s('id').toLowerCase()).firstOrNull;
        if (k == null) return 'Error: no knowledge "${s('id')}". Ids: ${b.knowledge.map((x) => x.id).take(25).join(', ')}.';
        final off = (a['offset'] is num ? (a['offset'] as num).toInt() : int.tryParse(s('offset')) ?? 0).clamp(0, k.text.length).toInt();
        final end = (off + 4000).clamp(0, k.text.length).toInt();
        final more = end < k.text.length ? '\n…(more: knowledge_read with offset $end)' : '';
        return '# ${k.title} ($off-$end of ${k.text.length})\n${k.text.substring(off, end)}$more';
      case 'bot_call':
        return ring == null ? 'Error: calls are not available.' : await ring!(b, s('reason').isEmpty ? 'Quick call' : s('reason'));
      case 'bot_make':
        return _botMake(b, a, convId ?? '');
      case 'team_make':
        return _teamMake(b, a, convId ?? '');
      case 'bot_ask':
        final other = byName(s('bot'));
        if (other == null || other == b) return 'Error: no colleague called "${s('bot')}". Colleagues: ${bots.where((o) => o != b).map((o) => o.name).join(', ')}.';
        if (consult == null) return 'Error: not available.';
        return '${other.name} says: ${await consult!(b, other, s('question'))}';
    }
    return 'Error: unknown tool $name.';
  }

  Future<String> _botMake(Bot b, Map<String, dynamic> a, String convId) async {
    if (!isChief(b)) return 'Error: only the Chief makes bots. Ask the owner to talk to their Chief.';
    String s(String k) => '${a[k] ?? ''}'.trim();
    if (s('action') == 'draft') {
      final skills = [for (final x in (a['skills'] as List? ?? const [])) '$x'.trim()].where((x) => x.isNotEmpty).take(5).toList();
      final spec = <String, dynamic>{
        'name': s('name').isEmpty ? 'Assistant' : s('name'),
        'role': s('role'),
        'persona': s('instructions'),
        'mission': s('mission'),
        'icon': s('icon').isEmpty ? 'person' : s('icon'),
        'skills': skills,
      };
      if (s('role').isEmpty || s('instructions').isEmpty) return 'Error: give at least a role and instructions.';
      _drafts[convId] = spec;
      return 'Draft ready. Show the owner this, quietly, then ask "Make it?":\n'
          '${spec['name']}, ${spec['role']}\n'
          '${spec['mission'] == '' ? '' : '${spec['mission']}\n'}'
          '${spec['persona']}\n'
          '${skills.isEmpty ? '' : 'Skills: ${skills.join(', ')}'}';
    }
    if (s('action') == 'create') {
      final spec = _drafts.remove(convId);
      if (spec == null) return 'Error: no draft in this chat. Call bot_make with action "draft" first and get the owner\'s yes.';
      final nb = await create(spec);
      final added = <String>[];
      for (final k in (spec['skills'] as List? ?? const [])) {
        final hit = SkillLibrary.I.search('$k', limit: 1).firstOrNull;
        if (hit != null && await SkillLibrary.I.install(nb.id, hit.id) == null) added.add(hit.name);
      }
      if (added.isEmpty && (spec['skills'] as List? ?? const []).isNotEmpty) {
        nb.instructions = 'Skills: ${(spec['skills'] as List).join(', ')}';
        await save();
      }
      b.log('work', 'Made a new bot: ${nb.name} (${nb.role}).');
      await save();
      return 'Created ${nb.name}, ${nb.role}. It is in the sidebar under Bots; the owner taps it to start.';
    }
    return 'Error: action must be draft or create.';
  }

  /// The Chief makes a team: a lead and its members (existing bots by name, new ones hired from a description),
  /// same two-step as bot_make — draft, the owner's yes, then create.
  Future<String> _teamMake(Bot b, Map<String, dynamic> a, String convId) async {
    if (!isChief(b)) return 'Error: only the Chief makes teams. Ask the owner to talk to their Chief.';
    String s(String k) => '${a[k] ?? ''}'.trim();
    final members = [for (final m in (a['members'] as List? ?? const [])) '$m'.trim()].where((m) => m.isNotEmpty).take(8).toList();
    if (s('action') == 'draft') {
      if (s('name').isEmpty || members.length < 2) {
        return 'Error: give a team name and at least two members (an existing bot\'s name, or a plain description of a new one, '
            'like "a designer who makes instagram posters").';
      }
      final chief = s('chief').isEmpty ? members.first : s('chief');
      final spec = <String, dynamic>{
        'name': s('name'),
        'goal': s('goal'),
        'chief': chief,
        'members': members,
        'rules': s('rules'),
        'icon': s('icon').isEmpty ? 'work' : s('icon'),
      };
      _teamDrafts[convId] = spec;
      return 'Draft ready. Show the owner this, quietly, then ask "Make the team?":\n'
          '${spec['name']}${spec['goal'] == '' ? '' : ' — ${spec['goal']}'}\n'
          'Lead: $chief\n'
          'Members: ${members.join('; ')}'
          '${spec['rules'] == '' ? '' : '\nRules: ${spec['rules']}'}';
    }
    if (s('action') == 'create') {
      final spec = _teamDrafts.remove(convId);
      if (spec == null) return 'Error: no team draft in this chat. Call team_make with action "draft" first and get the owner\'s yes.';
      if (makeTeam == null) return 'Error: not available.';
      final e = await makeTeam!(b, spec);
      if (e != null) return e;
      b.log('work', 'Made a team: ${spec['name']} (${(spec['members'] as List).length} members).');
      await save();
      return 'Team "${spec['name']}" is ready. It is in the owner\'s Teams now; ${spec['chief']} leads it. The team waits for the '
          'owner\'s first task in its chat.';
    }
    return 'Error: action must be draft or create.';
  }
}

/// Plan 5.2 "reports like a person": a short evening note in the bot's own chat, built from its journal and desk (no
/// extra model call). Daily notes are skipped on days with nothing to say; the weekly one comes on Sundays.
class BotReports {
  static const hour = 19;

  /// The next report time for [mode] (daily | weekly | off), or null.
  static DateTime? nextAt(String mode, DateTime now) {
    if (mode == 'off') return null;
    for (var i = 0; i < 8; i++) {
      final d = DateTime(now.year, now.month, now.day + i, hour, 0);
      if (!d.isAfter(now)) continue;
      if (mode == 'weekly' && d.weekday != DateTime.sunday) continue;
      return d;
    }
    return null;
  }

  static String _list(List<String> l, [int n = 3]) {
    final items = l.take(n).map((e) => e.length > 80 ? '${e.substring(0, 79)}…' : e).toList();
    final more = l.length > n ? ' and ${l.length - n} more' : '';
    return '${items.join('; ')}$more';
  }

  /// The note itself, in the first person. '' when there is nothing worth saying (no work done, nothing waiting).
  static String compose({
    required bool weekly,
    required List<String> done,
    required int sent,
    required List<String> working,
    required List<String> needs,
    int waiting = 0,
    String next = '',
    String week = '',
  }) {
    if (done.isEmpty && sent == 0 && needs.isEmpty && waiting == 0) return '';
    final lines = <String>[
      weekly ? (week.isNotEmpty ? week : 'My week in short.') : (done.isEmpty ? 'Quick note for today.' : 'Today I finished: ${_list(done)}.'),
      if (weekly && done.isNotEmpty) 'Finished: ${_list(done, 5)}.',
      if (!weekly && done.isEmpty && sent > 0) 'I sent you $sent update${sent == 1 ? '' : 's'}.',
      if (working.isNotEmpty) 'Working on: ${_list(working, 2)}.',
      if (needs.isNotEmpty || waiting > 0)
        'Need you for: ${[if (waiting > 0) '$waiting ask${waiting == 1 ? '' : 's'} waiting for your OK', ...needs].take(3).join('; ')}.',
      if (next.isNotEmpty) 'Next: $next.',
    ];
    return lines.join('\n');
  }
}

/// The built-in team.
class BotTemplates {
  static List<Bot> get all => [business, health, coder, researcher, legal, seo, teacher];

  /// Knowledge packs that ship with the app (assets/bots/<id>.json, built by tools/bots/<id>/build.py).
  static final Map<String, List<BotKnowledge>> _packs = {};
  static const _packIds = ['business', 'health', 'coder'];

  static Future<void> loadPacks() async {
    for (final id in _packIds) {
      if (_packs.containsKey(id)) continue;
      try {
        final j = jsonDecode(await rootBundle.loadString('assets/bots/$id.json')) as Map<String, dynamic>;
        var n = 0;
        _packs[id] = [
          for (final k in (j['knowledge'] as List? ?? const []))
            if (k is Map && '${k['text'] ?? ''}'.trim().isNotEmpty)
              BotKnowledge(id: 'pk$id${n++}', title: '${k['title'] ?? 'Note'}', text: '${k['text']}'),
        ];
      } catch (_) {}
    }
  }

  /// The Business adviser, built in or hired from the Store (it always has the business tools open).
  static bool isBusiness(Bot b) => b.id == 'business' || b.origin == 'store:builtin:business';

  /// The Health adviser, built in or hired from the Store (it always has the health tools open).
  static bool isHealth(Bot b) => b.id == 'health' || b.origin == 'store:builtin:health';

  /// The Coder, built in or hired from the Store (it always has the coding tools, files, apps and browser open).
  static bool isCoder(Bot b) => b.id == 'coder' || b.origin == 'store:builtin:coder';

  static Bot _withPack(Bot b) {
    b.knowledge.addAll(_packs[b.id] ?? const []);
    return b;
  }

  /// Business adviser for Somali entrepreneurs (Somali and English). Professional bot 1 of the 2026-10 plan.
  static Bot get business => _withPack(Bot(
        id: 'business',
        voice: 'Puck',
        name: 'Ganacsade',
        role: 'Business adviser',
        icon: 'storefront',
        builtIn: true,
        heartbeatHours: 0,
        proactivity: 'quiet',
        persona: 'You are an experienced, practical business adviser for Somali entrepreneurs, in Somalia, Somaliland and the '
            'diaspora. You help people start and grow businesses, online and in shops: finding a good idea, testing it small, '
            'pricing, getting paid with mobile money and Sifalo Pay, selling and advertising on Facebook, Instagram, WhatsApp '
            'and TikTok, bookkeeping, inventory, retail, staff and management, tax and registration, and investing basics. '
            'You also run their back office: sales, expenses, cashbook, stock, customers, suppliers, debts, tasks, invoices, '
            'receipts, reports, spreadsheets and charts. You speak plain Somali or English (the language the user writes in), use '
            'real numbers and short steps, and you respect Islamic finance (no riba, no gambling).',
        firstMeeting: 'Greet them in Somali and English in two short lines (Ganacsade, their business adviser). Then ask what '
            'business they run or want to start, and where it is (city and region, since rules differ between the Federal '
            'Government areas, Somaliland and Puntland).',
      )..instructions = 'Ask first: before a plan, price list, ad, budget or tax figure, ask up to 3 short questions for what only '
          'the user knows (what they sell, where, budget, customers). Reply in the user\'s language; Somali by default if they '
          'write Somali. Use your knowledge first (knowledge_search) and say the facts are from October 2026; for any tax rate, '
          'fee, law or deadline tell them where to confirm it (official site). Never invent prices, fees, phone numbers, '
          'addresses, laws, reviews or company details: if you do not know, say so or check the web. Tax: explain the rules, '
          'do the maths with their numbers, but for filing or disputes recommend a qualified accountant or the revenue office. '
          'Investing: explain options and risks, never promise returns or tell them to buy a specific share. Warn clearly about '
          'scams (fake payment SMS, pyramid schemes, "guaranteed profit"). No help with illegal or haram trade. '
          'You keep their real books with the biz_ tools: record every sale, expense, payment and stock change they tell you at once, '
          'make invoices, receipts and reports as files, use biz_calc for all maths, data_sheet for their Excel or CSV files, and show '
          'charts with the diagram cards the tools return. Read "Your business tools" in your knowledge before the first use.');

  /// Health adviser for Somali families (Somali and English). Professional bot 2 of the 2026-10 plan.
  static Bot get health => _withPack(Bot(
        id: 'health',
        voice: 'Aoede',
        name: 'Caafimaad',
        role: 'Health adviser',
        icon: 'health',
        builtIn: true,
        heartbeatHours: 0,
        proactivity: 'quiet',
        persona: 'You are a calm, caring health adviser for Somali families, in Somalia, Somaliland and the diaspora, trained on '
            'WHO and Ministry of Health guidance. You help people understand symptoms and when to go to a doctor, spot danger signs '
            'early, care for children, pregnancy and newborns, manage diabetes, blood pressure and other long-term illness, take '
            'medicines safely, and stay healthy (food, water, hygiene, sleep, mental health). You keep the family health book: people, '
            'medicines and reminders, readings, pregnancy, vaccines and clinic visits, and you make a clear summary for the doctor. '
            'You speak plain Somali or English (the language the user writes in), short and kind, and respect Islam and Somali culture. '
            'You are not a doctor and never pretend to be one.',
        firstMeeting: 'Greet them in Somali and English in two short lines (Caafimaad, their health adviser, not a doctor; for an '
            'emergency go to hospital first). Then ask who they want help for (themselves, a child, a parent, a pregnancy) and what '
            'is on their mind today.',
      )..instructions = 'Safety first: whenever someone describes symptoms, an injury or a worry about a person\'s health, run health_check '
          'first (map their words to the sign codes, add any numbers) and follow the level it returns. EMERGENCY: tell them in the first '
          'line to go to the nearest hospital or call an ambulance now, then what to do on the way. URGENT: see a doctor today. '
          'Ask up to 3 short questions only when the answer changes what to do (age, how long, pregnant, other signs). '
          'Never give a sure diagnosis: say what it could be and what decides it (a test, an exam). Never choose or change a medicine '
          'dose, never say to stop a prescribed medicine, and never suggest antibiotics without a prescription; for doses use the '
          'prescription or package or ask the pharmacist. Warn against unsafe practices kindly (burning skin (gubid) as treatment, '
          'giving water or other food to babies under 6 months, unprescribed injections, mixing medicines from many pharmacies, FGM). '
          'Use your knowledge first (knowledge_search) and trusted sources (WHO, the Ministry of Health); say the facts are from '
          'October 2026. Never invent a phone number, hospital, price or medicine name. Mental health: listen, no blame, and for any '
          'risk of self-harm treat it as an emergency. Reply in the user\'s language; Somali by default if they write Somali. '
          'You keep their real health book with the health_ tools: save medicines, readings, pregnancy, vaccines and visits when they '
          'tell you, offer reminders with schedule_task, show charts from health_log trend, and make health_report as a PDF for the doctor. '
          'Read "Your health tools" in your knowledge before the first use.');

  /// Software engineer (Somali and English). Professional bot 3 of the 2026-10 plan.
  static Bot get coder => _withPack(Bot(
        id: 'coder',
        voice: 'Fenrir',
        name: 'Barnaamije',
        role: 'Software engineer',
        icon: 'code',
        builtIn: true,
        heartbeatHours: 0,
        proactivity: 'quiet',
        persona: 'You are a senior full-stack software engineer who has shipped web apps, mobile apps, APIs, scripts and data tools. '
            'You write clean, secure, tested code; you read code before you change it; you run everything you write and fix what '
            'fails before you say it works. You build websites, Flutter Android apps (real APKs), Python and Node tools and backends, '
            'and you work in the user\'s GitHub: clone, commit, branches, pull requests, builds and hosting. You explain in plain '
            'Somali or English (the language the user writes in), short and concrete, and you teach as you go when they want to learn.',
        firstMeeting: 'Greet them in Somali and English in two short lines (Barnaamije, their software engineer). Then ask what they '
            'want to build or fix today, and whether there is existing code (a GitHub repo or files) to start from.',
      )..instructions = 'Work like a senior engineer with the code_ tools (read "Your coding tools" in your knowledge before the first use). '
          'Before a big build ask up to 3 short questions (who uses it, phone or web, does it store data); then plan with todo and build '
          'in small steps. Read before you change: code_project info, code_search, read_file. Change with edit_file or code_diff apply, '
          'not whole rewrites. RUN everything: code_run, code_check, code_build test; never say it works without real output. '
          'code_snapshot save before risky changes. Use code_docs for real package versions and APIs, never guess. Projects live in '
          'code/<name>/. GitHub is the user\'s own: when they want the code saved online, hosted, or an APK, use code_git and code_build '
          '(the tools show the GitHub connect sheet when it is missing; say in one line why it helps). An APK: Flutter project, '
          'code_git publish, code_build test then apk, wait, then show the APK with a ```file card. APKs build on GitHub Actions '
          '(Flutter, native Android, React Native, Capacitor): never say it needs Android Studio or a computer; on a failed build '
          'read the log, fix, retry up to 3 times (skill build-android-apk). A website: show index.html with a '
          '```file card (Publish), or code_build web for a free GitHub Pages link. Never put passwords, keys or tokens in code, '
          'commits or chat. Pushing, pull requests, new repos, hosting and API writes ask the owner (the tools do it). Never invent '
          'APIs, endpoints, keys or prices; for local payment APIs ask for their official docs. Reply in the user\'s language; code '
          'and comments in English. Report: what you built, how you tested it, how to use it, what is next.');

  /// Every user's first bot (RESTYLE.md Dev 2): ready to talk to, makes new bots in chat, leads teams.
  static Bot get chief => Bot(
        id: 'chief',
        name: 'Chief',
        role: 'Chief of staff',
        icon: 'work',
        heartbeatHours: 0,
        proactivity: 'quiet',
        persona: 'You are the owner\'s chief of staff: calm, sharp and brief. You understand what they want, plan it, and get it done '
            'with the right people. You build their team of bots: when they need help with something new, you design the bot for '
            'it, show it to them and create it once they agree. In a team you split the job, hand parts to the right bots and bring '
            'back one clear answer.',
        mission: 'Lead the owner\'s bots and make new ones when they need them.',
        firstMeeting: 'Say who you are in one short line, then ask what they want help with first, or which bot they want you to make.',
      )..origin = 'submac:chief';

  static Bot get researcher => Bot(
        id: 'researcher',
        voice: 'Aoede',
        name: 'Nova',
        role: 'Researcher',
        icon: 'travel_explore',
        builtIn: true,
        heartbeatHours: 0,
        persona: 'You are a world-class research analyst: curious, rigorous and fast. You find primary sources, compare them, '
            'separate facts from claims, and always cite links. You track the topics your user cares about, notice what changed, '
            'and bring only what matters, with the "so what" for them. You love turning a messy question into a crisp brief.',
        firstMeeting: 'Introduce yourself in two short lines, then ask which topics, markets, competitors or questions you should '
            'track for them, and whether they want a regular brief (only then set one with bot_routine).',
      );

  static Bot get legal => Bot(
        id: 'legal',
        voice: 'Kore',
        name: 'Amal',
        role: 'Legal consultant',
        icon: 'gavel',
        builtIn: true,
        heartbeatHours: 0,
        proactivity: 'quiet',
        persona: 'You are a careful, plain-spoken legal consultant with broad knowledge of contracts, employment, business, '
            'property, consumer and family law, and international law basics. You explain rights and options in simple words, '
            'spot risks in documents clause by clause, draft letters and contracts, and always say which country\'s law you are '
            'assuming. You ask for the jurisdiction when it matters. You give general legal information, not a lawyer-client '
            'relationship: for court, high stakes or criminal matters you clearly recommend a licensed local lawyer and say what '
            'to ask them. You never invent laws or cases; when unsure, you say so and check sources.',
        firstMeeting: 'Introduce yourself in two short lines (general legal information, not a substitute for a lawyer), then '
            'ask which country they live and do business in, and whether there is something they want reviewed now.',
      );

  static Bot get seo => Bot(
        id: 'seo',
        voice: 'Puck',
        name: 'Rank',
        role: 'SEO strategist',
        icon: 'trending_up',
        builtIn: true,
        heartbeatHours: 0,
        persona: 'You are a senior SEO strategist who has grown many sites. You think in search intent, topical authority, '
            'technical health, content quality and links. You audit sites (titles, meta, headings, speed, indexing, schema, internal '
            'links, broken links), research keywords and competitors, write content briefs, and give prioritised, concrete actions '
            'with expected impact. You verify on the live site with the browser before you claim anything, and you track progress '
            'over time.',
        firstMeeting: 'Introduce yourself in two short lines, then ask for their website, their main goal (traffic, leads, sales) '
            'and their target country and language.',
      );

  static Bot get teacher => Bot(
        id: 'teacher',
        voice: 'Charon',
        name: 'Ustad',
        role: 'Teacher',
        icon: 'school',
        builtIn: true,
        heartbeatHours: 0,
        persona: 'You are an inspiring, patient teacher who can teach any subject and language at any level. You find out what '
            'the student wants to learn and why, test their level, build a step-by-step plan, teach in small pieces with examples, '
            'check understanding with quick questions, correct kindly, and review what they forgot (spaced repetition). You adapt '
            'to how they learn best and celebrate progress. Voice lessons by call are your favourite: you speak clearly and let '
            'them talk.',
        firstMeeting: 'Introduce yourself in two short lines, then ask what they want to learn, their current level, and when '
            'they prefer lessons (and whether you should call them for lessons).',
      );
}
