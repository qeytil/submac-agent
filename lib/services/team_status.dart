import 'package:flutter/foundation.dart';

import '../ui/i18n.dart';
import 'bots.dart';
import 'team_key.dart';

/// What a bot in a team chat is doing right now (owner 2026-11-04): one small live line per bot, "Nova is working…"
/// while its turn thinks or runs tools and "Nova is typing…" while its reply streams; it goes when the turn ends and
/// the bot's message lands. A turn that fails leaves one small line "Nova · rate limit" instead of an error bubble or
/// raw error text; it stays until that bot starts its next piece of work in the team.
///
/// Only team work ([TeamKey] keys) is tracked, and only the team chat shows it: a bot's private chat never does.
enum TeamPhase { working, typing }

/// The kind of a row in the team chat's live area.
enum TeamLineKind { working, typing, waiting, issue }

/// One row under the newest team message: a bot and what it is doing, or what went wrong.
class TeamStatusLine {
  const TeamStatusLine({required this.bot, required this.kind, this.text = '', this.detail = '', this.since});
  final Bot bot;
  final TeamLineKind kind;

  /// waiting: the waiting state ("Read your message"); issue: the short error type ("rate limit").
  final String text;

  /// issue: the longer message behind it (shown on tap).
  final String detail;

  /// working / typing: when the work started.
  final DateTime? since;

  bool get isIssue => kind == TeamLineKind.issue;

  /// The line as shown, in the app's language.
  String get line => switch (kind) {
        TeamLineKind.working => tr('{name} is working…', {'name': bot.name}),
        TeamLineKind.typing => tr('{name} is typing…', {'name': bot.name}),
        TeamLineKind.waiting => '${bot.name} · ${tr(text)}',
        TeamLineKind.issue => '${bot.name} · ${tr(text)}',
      };
}

class TeamLive {
  TeamLive({required this.key, required this.officeId, required this.botId, DateTime? started}) : started = started ?? DateTime.now();
  final String key;
  final String officeId;
  final String botId;
  final DateTime started;
  TeamPhase phase = TeamPhase.working;
}

class TeamIssue {
  TeamIssue(this.type, this.detail) : at = DateTime.now();
  final String type;
  final String detail;
  final DateTime at;
}

class TeamStatus extends ChangeNotifier {
  TeamStatus._();
  static final I = TeamStatus._();

  // The short error types (one helper, [typeOf], maps any error to one of them).
  static const rateLimit = 'rate limit';
  static const outOfBudget = 'out of budget';
  static const allowanceUsed = 'allowance used';
  static const outOfCredit = 'out of credit';
  static const keyError = 'key error';
  static const providerError = 'provider error';
  static const timedOut = 'timed out';
  static const noConnection = 'no connection';
  static const toolFailed = 'tool failed';
  static const noReply = 'no reply';
  static const error = 'error';

  static const types = [
    rateLimit, outOfBudget, allowanceUsed, outOfCredit, keyError, providerError, timedOut, noConnection, toolFailed, noReply, error,
  ];

  /// Any error (an exception or its text) as one short type for the "<Bot> · <type>" line. Never the raw text.
  static String typeOf(Object? e) {
    final s = '${e ?? ''}'.toLowerCase();
    bool has(String p) => RegExp(p).hasMatch(s);
    if (s.trim().isEmpty) return error;
    // The bots' share of the daily allowance is used up (background_paused): the team rests until tomorrow.
    if (has(r'save your daily allowance|background_paused|allowance|bots.? share|refreshes tomorrow|resting until tomorrow|done a lot today')) {
      return allowanceUsed;
    }
    if (has(r"token budget|budget is used|over budget|out of budget|budget (ran|run) out")) return outOfBudget;
    if (has(r'\b429\b|rate.?limit|too many requests|slow down')) return rateLimit;
    if (has(r'insufficient.{0,12}(credit|balance|funds|quota)|out of credit|quota|billing|payment required|\b402\b|credit balance')) {
      return outOfCredit;
    }
    if (has(r'\b401\b|\b403\b|api.?key|unauthori[sz]ed|forbidden|authentication|invalid (key|token)|permission denied|incorrect key')) {
      return keyError;
    }
    if (has(r'ran out of time|timed? ?out|timeout|took too long|deadline exceeded')) return timedOut;
    if (has(r"offline|socketexception|failed host lookup|network|connection (refused|reset|closed|dropped|failed)|no internet|lost the connection|clientexception")) {
      return noConnection;
    }
    if (has(r'\btool\b.{0,40}(fail|error|crash)|(fail|error).{0,20}\btool\b')) return toolFailed;
    if (has(r"\b50[0-4]\b|overloaded|unavailable|busy|provider|model.{0,20}(not found|not available|unsupported)|internal server|bad gateway|couldn't reach its models")) {
      return providerError;
    }
    return error;
  }

  /// The phase of a turn from its newest part: its reply text streaming is typing; thinking, a step (tool) or
  /// nothing yet is working.
  static TeamPhase phaseOf({String? lastKind, bool lastFinished = true, bool reasoning = false}) {
    if (reasoning) return TeamPhase.working;
    if (lastKind == 'tool' && !lastFinished) return TeamPhase.working;
    return lastKind == 'text' ? TeamPhase.typing : TeamPhase.working;
  }

  final Map<String, TeamLive> _live = {};
  final Map<String, TeamIssue> _issues = {};

  static String _k(String officeId, String botId) => '$officeId|$botId';

  /// A turn of team work starts under [key]. A key that is no team key (a private chat) is ignored. The bot's old
  /// issue in that team goes: it is at work again.
  void begin(String key) {
    if (!TeamKey.isKey(key)) return;
    final office = TeamKey.officeOf(key), bot = TeamKey.botOf(key);
    if (office.isEmpty || bot.isEmpty) return;
    _issues.remove(_k(office, bot));
    _live[key] = TeamLive(key: key, officeId: office, botId: bot);
    notifyListeners();
  }

  /// The turn under [key] is now thinking / running tools ([TeamPhase.working]) or writing its reply.
  void phase(String key, TeamPhase p) {
    final l = _live[key];
    if (l == null || l.phase == p) return;
    l.phase = p;
    notifyListeners();
  }

  /// The turn under [key] ended (its message lands next, or nothing does).
  void end(String key) {
    if (_live.remove(key) != null) notifyListeners();
  }

  /// The turn under [key] failed with [e]: its bot gets the small issue line in that team.
  void fail(String key, Object e) {
    if (!TeamKey.isKey(key)) return;
    failBot(TeamKey.officeOf(key), TeamKey.botOf(key), e);
  }

  /// Bot [botId] hit [e] doing work for team [officeId].
  void failBot(String officeId, String botId, Object e) => flag(officeId, botId, typeOf(e), detail: '$e');

  /// Bot [botId] has issue [type] (one of [types]) in team [officeId].
  void flag(String officeId, String botId, String type, {String detail = ''}) {
    if (officeId.isEmpty || botId.isEmpty) return;
    _issues[_k(officeId, botId)] = TeamIssue(type, detail.trim());
    notifyListeners();
  }

  /// The owner set the issue aside (or the team is gone).
  void clear(String officeId, String botId) {
    if (_issues.remove(_k(officeId, botId)) != null) notifyListeners();
  }

  /// Turns running for team [officeId], one per bot (typing wins over working; the earliest start is kept).
  List<TeamLive> liveIn(String officeId) {
    final by = <String, TeamLive>{};
    for (final l in _live.values) {
      if (l.officeId != officeId) continue;
      final had = by[l.botId];
      if (had == null) {
        by[l.botId] = TeamLive(key: l.key, officeId: l.officeId, botId: l.botId, started: l.started)..phase = l.phase;
        continue;
      }
      by[l.botId] = TeamLive(
          key: had.key, officeId: had.officeId, botId: had.botId, started: l.started.isBefore(had.started) ? l.started : had.started)
        ..phase = (l.phase == TeamPhase.typing || had.phase == TeamPhase.typing) ? TeamPhase.typing : TeamPhase.working;
    }
    return by.values.toList()..sort((a, b) => a.started.compareTo(b.started));
  }

  /// Issues of team [officeId], by bot id.
  Map<String, TeamIssue> issuesIn(String officeId) => {
        for (final e in _issues.entries)
          if (e.key.startsWith('$officeId|')) e.key.substring(officeId.length + 1): e.value,
      };

  /// The team chat's live rows: bots at work now ([live]: the turns tracked here, plus [busy] office jobs that have
  /// not started their turn yet), then bots with a message waiting ([waiting]: bot -> "Read your message"), then
  /// issues of bots that are not at work. Bots that are not members any more ([bot] returns null) are left out.
  List<TeamStatusLine> linesFor(String officeId,
      {required Bot? Function(String id) bot,
      Map<String, DateTime> busy = const {},
      Map<String, String> waiting = const {}}) {
    final out = <TeamStatusLine>[];
    final seen = <String>{};
    for (final l in liveIn(officeId)) {
      final b = bot(l.botId);
      if (b == null) continue;
      seen.add(l.botId);
      final since = busy[l.botId];
      out.add(TeamStatusLine(
          bot: b,
          kind: l.phase == TeamPhase.typing ? TeamLineKind.typing : TeamLineKind.working,
          since: since != null && since.isBefore(l.started) ? since : l.started));
    }
    for (final e in busy.entries) {
      if (seen.contains(e.key)) continue;
      final b = bot(e.key);
      if (b == null) continue;
      seen.add(e.key);
      out.add(TeamStatusLine(bot: b, kind: TeamLineKind.working, since: e.value));
    }
    for (final e in waiting.entries) {
      if (seen.contains(e.key)) continue;
      final b = bot(e.key);
      if (b == null) continue;
      seen.add(e.key);
      out.add(TeamStatusLine(bot: b, kind: TeamLineKind.waiting, text: e.value));
    }
    final issues = issuesIn(officeId).entries.toList()..sort((a, b) => a.value.at.compareTo(b.value.at));
    for (final e in issues) {
      if (seen.contains(e.key)) continue;
      final b = bot(e.key);
      if (b == null) continue;
      seen.add(e.key);
      out.add(TeamStatusLine(bot: b, kind: TeamLineKind.issue, text: e.value.type, detail: e.value.detail));
    }
    return out;
  }

  /// Tests: forget everything.
  @visibleForTesting
  void reset() {
    _live.clear();
    _issues.clear();
  }
}
