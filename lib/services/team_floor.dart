import 'bots.dart';
import 'offices.dart';
import 'no_reply.dart';
import 'quick_lane.dart';

/// Team awareness (owner feedback 2026-11-05): "bots send duplicate messages; they confuse who they are and their
/// roles; weak situational awareness; the lead always repeats the owner's words to the others." What a bot needs to
/// read the room before it speaks, in one place, as plain logic the tests can hold:
///
///  - [TeamTranscript]: the team chat as each bot sees it, every message labelled with who wrote it (owner, lead, a
///    member and their role, system), what it replies to and when, plus the bot's own identity, the roster and a short
///    "situation" (who is being asked, whether the owner asked something, who already answered, what waits on the
///    owner, whether the owner is here).
///  - [TeamFloor]: who (if anyone) should answer a new owner message, by cheap rules first (addressed, a role named,
///    continuing a bot's question); only when the rules have nothing does the team ask the small model.
///  - [TeamDedupe]: near-duplicate posts (the same bot twice, two bots saying the same, a bot echoing the owner) are
///    dropped before they reach the chat.
///  - [TeamLeadMode]: the lead leads (plans, assigns concrete subtasks with hand-offs) only when the owner is away or
///    hands over; while the owner is here the lead is one member among the others.
///  - [NeedsYou]: a bot that needs the owner marks its post "[needs you]" (shown as "Needs you"), instead of chatting.
enum TeamSpeakerKind { owner, lead, member, system }

class TeamLeadMode {
  TeamLeadMode._();

  static const peer = 'peer';
  static const leading = 'leading';

  /// The owner counts as here while they wrote in the team within this time.
  static const awayAfter = Duration(minutes: 20);

  /// Whether the owner is here: they wrote in the team within [awayAfter]. A team the owner never wrote in has nobody
  /// to be "away" from yet, so the owner counts as here (the lead leads only a job given to it).
  static bool ownerPresent(Office o, {DateTime? now}) {
    final last = o.lastOwnerPost;
    if (last == null) return true;
    return (now ?? DateTime.now()).difference(last) < awayAfter;
  }

  /// peer: the owner is here and has not handed over, so the lead is a team member like the others. leading: the owner
  /// handed over ("lead, take over", "I'm away") or has been away for [awayAfter].
  static String of(Office o, {DateTime? now}) {
    if (o.delegated) return leading;
    return ownerPresent(o, now: now) ? peer : leading;
  }

  static bool leads(Office o, {DateTime? now}) => of(o, now: now) == leading;

  static final _delegate = RegExp(
      r"(\b(lead|chief|boss)\b[^.?!]{0,40}\b(take over|take charge|in charge|run (it|this|the team|things)|lead (it|this|the team)|assign|organi[sz]e|coordinate)\b)"
      r"|(^\s*(please\s+)?take over\b)"
      r"|(\b(i['’]?m|i am)\s+(now\s+)?(away|offline|afk|gone|unavailable|stepping away|heading out|out for|out until|out now|off now|off for)\b)"
      r"|(\byou(['’]?re| are) in charge\b)"
      r"|(\bwhile i['’]?m (away|out|gone|offline)\b)",
      caseSensitive: false);

  static final _reclaim = RegExp(
      r"(\b(i['’]?m|i am) back\b)|(\bback now\b)|(\b(i['’]?m|i am) here now\b)|(\bi['’]?ll take it from here\b)|(\bi will take it from here\b)"
      r"|(\b(i['’]?ll|i will) lead( again)?\b)|(\bi['’]?m taking over\b)",
      caseSensitive: false);

  /// 'delegate' (the owner hands the team to the lead), 'reclaim' (the owner is back) or null.
  static String? commandOf(String text) {
    final t = text.trim();
    if (_reclaim.hasMatch(t)) return 'reclaim';
    if (_delegate.hasMatch(t)) return 'delegate';
    return null;
  }

  /// [text] without the hand-over words, to see whether a task came with them ("I'm away. Finish the report.").
  static String rest(String text) => text
      .replaceAll(_reclaim, ' ')
      .replaceAll(_delegate, ' ')
      .replaceAll(RegExp(r'^[\s,.;:!-]+|[\s,.;:!-]+$'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  /// The small indicator under the team chat: '' while the owner leads.
  static String indicator(Office o, {DateTime? now}) {
    if (!leads(o, now: now)) return '';
    final lead = Bots.I.byId(o.chiefId)?.name ?? 'The lead';
    return o.delegated ? '$lead is leading the team' : '$lead is leading while you are away';
  }

  /// The lead's standing instruction for the mode it is in (team prompts read it).
  static String leadInstruction(Office o, {DateTime? now}) => leads(o, now: now)
      ? 'Lead mode: LEADING (${o.delegated ? 'the owner handed over' : 'the owner is away'}). Split the work per role; assign each part '
          'on its own line ("Nova: <part>") or @Nova, which starts their turn. Follow up on reports, report once; never forward the owner\'s words.'
      : 'Lead mode: PEER (the owner is here and leads): act as a member, never relay the owner\'s messages, and assign '
          '("Nova: <part>" starts their turn) only when the owner asks.';
}

/// "[needs you]": a bot needs the owner to decide, answer or act. Stripped from the text; the post is shown as
/// "Needs you" (kind 'ask') and the owner is notified.
class NeedsYou {
  NeedsYou._();

  static const token = '[needs you]';

  static const rule = 'When you need the owner to decide, answer or do something, start your message with [needs you] and ask one '
      'clear question. Do not ask the owner anything without it, and never use it for status or thanks.';

  static final _mark = RegExp(r'\[\s*needs[\s_-]*you\s*\]|@owner\b', caseSensitive: false);

  static ({String text, bool needs}) parse(String text) {
    if (!_mark.hasMatch(text)) return (text: text, needs: false);
    final t = text.replaceAll(_mark, ' ').replaceAll(RegExp(r'[ \t]+'), ' ').replaceAll(RegExp(r'^\s+|\s+$'), '');
    return (text: t, needs: t.isNotEmpty);
  }
}

/// Near-duplicate detection for team posts.
class TeamDedupe {
  TeamDedupe._();

  /// How far back a duplicate is looked for.
  static const window = Duration(minutes: 15);

  static final _strip = RegExp(r'[^\p{L}\p{N}\s]', unicode: true);

  static List<String> words(String s) =>
      s.toLowerCase().replaceAll(_strip, ' ').split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();

  static String norm(String s) => words(s).join(' ');

  /// 0..1: how much two texts say the same (word sets; the shorter text inside the longer one counts as the same).
  static double similarity(String a, String b) {
    final na = norm(a), nb = norm(b);
    if (na.isEmpty || nb.isEmpty) return 0;
    if (na == nb) return 1;
    final sa = words(a).where((w) => w.length > 2).toSet();
    final sb = words(b).where((w) => w.length > 2).toSet();
    if (sa.isEmpty || sb.isEmpty) return 0;
    final inter = sa.intersection(sb).length;
    final jac = inter / sa.union(sb).length;
    final small = sa.length <= sb.length ? sa.length : sb.length;
    final big = sa.length <= sb.length ? sb.length : sa.length;
    // Containment counts only when the two are close in size (a short "Done." inside a long report is no duplicate).
    final contain = small >= 4 && small / big >= 0.6 ? inter / small : 0.0;
    return jac > contain ? jac : contain;
  }

  static bool near(String a, String b, {double at = 0.82}) {
    final na = norm(a), nb = norm(b);
    if (na.isEmpty || nb.isEmpty) return false;
    // Short lines ("Thanks", "On it") are only duplicates when they are the same words.
    if (words(a).length < 4 || words(b).length < 4) return na == nb;
    return similarity(a, b) >= at;
  }

  /// A bot repeating the owner's message: most of the owner's words, and little of its own.
  static bool parrots(String owner, String text) {
    final ow = words(owner).where((w) => w.length > 2).toSet();
    final tw = words(text).where((w) => w.length > 2).toList();
    if (ow.length < 4 || tw.isEmpty) return false;
    final covered = ow.where(tw.contains).length / ow.length;
    final own = tw.where((w) => !ow.contains(w)).toSet().length;
    return covered >= 0.85 && own <= (ow.length / 2).ceil() + 4;
  }

  /// An earlier post that [text] by bot [from] would repeat, or null. Same bot saying it again, another bot saying
  /// the same thing, or a bot echoing the owner's latest message. Only chat-like posts count (task updates, approvals
  /// and system lines have their own rules).
  static OfficePost? duplicateOf(Office o, String from, String text, {DateTime? now}) {
    if (from == 'you' || from == 'system') return null;
    final t = (now ?? DateTime.now()).subtract(window);
    for (final p in o.posts.reversed) {
      if (p.at.isBefore(t)) break;
      if (p.kind == 'system' || p.kind == 'update') continue;
      if (p.from == 'you') {
        if (parrots(p.text, text)) return p;
        continue;
      }
      if (p.from == 'system') continue;
      // The same bot again: any near repeat. Another bot: only real content said twice (two short "Done." notes from
      // two members are two people reporting, not a duplicate).
      if (p.from == from ? near(p.text, text) : (words(p.text).length >= 4 && words(text).length >= 4 && near(p.text, text))) return p;
    }
    return null;
  }
}

/// The team chat as one bot sees it before it speaks.
class TeamTranscript {
  TeamTranscript._();

  static TeamSpeakerKind kindOf(Office o, String from) {
    if (from == 'you') return TeamSpeakerKind.owner;
    if (from == 'system') return TeamSpeakerKind.system;
    return from == o.chiefId ? TeamSpeakerKind.lead : TeamSpeakerKind.member;
  }

  static String _role(Bot? b) => (b?.role ?? '').trim().isEmpty ? 'colleague' : b!.role.trim();

  /// "Owner", "System", "Hodan (lead, Manager)", "Nova (member, Researcher; you)".
  static String label(Office o, String from, {String? selfId}) {
    switch (kindOf(o, from)) {
      case TeamSpeakerKind.owner:
        return 'Owner';
      case TeamSpeakerKind.system:
        return 'System';
      case TeamSpeakerKind.lead:
      case TeamSpeakerKind.member:
        final b = Bots.I.byId(from);
        final k = from == o.chiefId ? 'lead' : 'member';
        return '${b?.name ?? 'A former member'} ($k, ${_role(b)}${from == selfId ? '; you' : ''})';
    }
  }

  static String _hm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  static String _short(String s, int n) {
    final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length > n ? '${t.substring(0, n)}…' : t;
  }

  static String _kindTag(OfficePost p) => switch (p.kind) {
        'ask' => ' [NEEDS OWNER]',
        'answer' => ' [team answer]',
        'report' => ' [report]',
        'update' => ' [task update]',
        _ => '',
      };

  /// Who a post is addressed to: @mentions, the author it replies to, or a name that opens it. Empty: the room.
  static List<String> addressedIds(Office o, OfficePost p) {
    final out = <String>[for (final b in Offices.I.mentioned(o, p.text)) b.id];
    if (p.replyTo.isNotEmpty) {
      final q = o.posts.where((x) => x.id == p.replyTo).firstOrNull;
      if (q != null && q.from != p.from && !out.contains(q.from) && q.from != 'system') out.add(q.from);
    }
    if (out.isEmpty) {
      final m = RegExp(r'^(?:(?:hey|hi|ok|okay|so|and|walaal)\s+)?([\w\u0600-\u06FF-]+)\s*[,:،]', caseSensitive: false).firstMatch(p.text.trim());
      if (m != null) {
        final n = m.group(1)!.toLowerCase();
        for (final id in o.members) {
          if (Bots.I.byId(id)?.name.toLowerCase() == n) out.add(id);
        }
        if (n == 'owner' || n == 'boss') out.add('you');
      }
    }
    return out;
  }

  static bool isQuestion(String t) {
    final s = t.trim().toLowerCase();
    return s.contains('?') ||
        s.contains('؟') ||
        RegExp(r'^(who|what|when|where|why|how|which|can|could|would|will|should|is|are|do|does|did|any|ma|maxaa|sidee|goorma|xagee)\b').hasMatch(s);
  }

  /// The labelled chat lines (oldest first), [max] at most, system lines included (they say what the app did).
  static List<String> lines(Office o, {String? selfId, int max = 24, int clip = 400}) {
    final recent = o.posts.length > max ? o.posts.sublist(o.posts.length - max) : o.posts;
    final ref = <String, int>{};
    final out = <String>[];
    var i = 0;
    for (final p in recent) {
      i++;
      ref[p.id] = i;
      final to = addressedIds(o, p).where((id) => id != p.from).toList();
      final toTxt = to.isEmpty ? '' : ' → ${to.map((id) => id == 'you' ? 'Owner' : (Bots.I.byId(id)?.name ?? '?')).join(', ')}';
      var re = '';
      if (p.replyTo.isNotEmpty) {
        final n = ref[p.replyTo];
        if (n != null) {
          re = ' (reply to #$n)';
        } else {
          final q = o.posts.where((x) => x.id == p.replyTo).firstOrNull;
          if (q != null) re = ' (reply to an earlier message by ${label(o, q.from, selfId: selfId)}: "${_short(q.text, 120)}")';
        }
      }
      out.add('#$i ${_hm(p.at)} ${label(o, p.from, selfId: selfId)}$toTxt$re${_kindTag(p)}: ${_short(p.text, clip)}');
    }
    return out;
  }

  /// The roster with roles, the lead marked, the bot itself marked.
  static String roster(Office o, {String? selfId}) {
    final sb = StringBuffer('- Owner: the person the whole team works for. Their word decides.\n');
    for (final id in o.members) {
      final b = Bots.I.byId(id);
      if (b == null) continue;
      sb.writeln('- ${b.name}: ${id == o.chiefId ? 'team lead' : 'member'}, ${_role(b)}${b.mission.isEmpty ? '' : ' (${_short(b.mission, 120)})'}'
          '${id == selfId ? '  <- this is you' : ''}');
    }
    return sb.toString().trim();
  }

  /// The situation right now, from the chat: what the newest message is and who it is for, whether the owner asked
  /// something and who already answered it, what waits on the owner, whether the owner is here, and who is working.
  static List<String> situation(Office o, {String? selfId, DateTime? now, Iterable<String> working = const []}) {
    final at = now ?? DateTime.now();
    final out = <String>[];
    final talk = o.posts.where((p) => p.kind != 'system').toList();
    if (talk.isEmpty) {
      out.add('The chat is empty.');
    } else {
      final last = talk.last;
      final to = addressedIds(o, last).where((id) => id != last.from).toList();
      final toTxt = to.isEmpty
          ? 'the whole team (nobody named)'
          : to.map((id) => id == selfId ? 'you' : (id == 'you' ? 'the owner' : (Bots.I.byId(id)?.name ?? '?'))).join(', ');
      out.add('Newest message: ${label(o, last.from, selfId: selfId)}, ${_ago(at, last.at)}, to $toTxt.');
      final oi = talk.lastIndexWhere((p) => p.from == 'you');
      if (oi >= 0) {
        final owner = talk[oi];
        final after = talk.sublist(oi + 1).where((p) => p.from != 'you').toList();
        final ownerTo = addressedIds(o, owner);
        final asked = isQuestion(owner.text) ? 'asked' : 'wrote';
        final whom = ownerTo.isEmpty
            ? 'the team'
            : ownerTo.map((id) => id == selfId ? 'you' : (Bots.I.byId(id)?.name ?? '?')).join(', ');
        out.add('The owner last $asked ($whom, ${_ago(at, owner.at)}): "${_short(owner.text, 160)}".');
        if (after.isEmpty) {
          out.add('Nobody has answered the owner\'s last message yet.');
        } else {
          final names = <String>[];
          for (final p in after) {
            final n = p.from == selfId ? 'you' : (Bots.I.byId(p.from)?.name ?? '?');
            if (!names.contains(n)) names.add(n);
          }
          out.add('Already answered after it by: ${names.join(', ')}. Do not repeat what they said.');
        }
        final open = after.where((p) => p.kind == 'ask').toList();
        if (open.isNotEmpty) {
          out.add('Waiting on the owner: ${open.map((p) => '${Bots.I.byId(p.from)?.name ?? 'A bot'}: "${_short(p.text, 100)}"').join('; ')}.');
        }
      } else {
        final open = talk.where((p) => p.kind == 'ask').toList();
        if (open.isNotEmpty) out.add('Waiting on the owner: ${open.length} question${open.length == 1 ? '' : 's'} marked NEEDS OWNER.');
      }
    }
    final present = TeamLeadMode.ownerPresent(o, now: at);
    out.add(present
        ? 'The owner is here (wrote in the last ${TeamLeadMode.awayAfter.inMinutes} min): keep it short and answer what they ask.'
        : 'The owner is away: only post what they will need when they are back; use [needs you] for decisions only they can make.');
    final lead = Bots.I.byId(o.chiefId);
    if (lead != null) {
      out.add(TeamLeadMode.leads(o, now: at)
          ? '${lead.id == selfId ? 'You are' : '${lead.name} is'} leading the team right now${o.delegated ? ' (the owner handed over)' : ' (the owner is away)'}.'
          : 'The owner leads; ${lead.id == selfId ? 'you, the lead, act' : '${lead.name}, the lead, acts'} as a regular member for now.');
    }
    final busy = [for (final n in working) if (n.isNotEmpty) n];
    if (busy.isNotEmpty) out.add('Working on a reply right now: ${busy.join(', ')}. Do not answer the same thing.');
    return out;
  }

  static String _ago(DateTime now, DateTime t) {
    final d = now.difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours} h ago';
    return '${d.inDays} d ago';
  }

  /// Who the bot is in this team, in two lines.
  static String identity(Office o, Bot self) {
    final lead = Bots.I.byId(o.chiefId);
    final isLead = self.id == o.chiefId;
    return 'You are ${self.name}, ${_role(self)}, ${isLead ? 'the lead of' : 'a member of'} the team "${o.name}"'
        '${isLead || lead == null ? '' : ' (lead: ${lead.name}, ${_role(lead)})'}. Messages labelled "you" are yours. '
        'Everyone else is a different person: never speak for them or take their role.';
  }

  /// The full block for a bot's team turn: identity, roster, the labelled chat and the situation.
  static String build(Office o, Bot self, {DateTime? now, int max = 24, Iterable<String> working = const []}) {
    final sb = StringBuffer()
      ..writeln('# Who you are here')
      ..writeln(identity(o, self))
      ..writeln('\n# Roster')
      ..writeln(roster(o, selfId: self.id))
      ..writeln('\n# Team chat (oldest first; #n, time, who, → to whom, reply links)');
    final l = lines(o, selfId: self.id, max: max);
    sb.writeln(l.isEmpty ? '(empty)' : l.join('\n'));
    sb.writeln('\n# The situation');
    for (final s in situation(o, selfId: self.id, now: now, working: working.where((n) => n != self.name))) {
      sb.writeln('- $s');
    }
    sb
      ..writeln('\n# Before you speak')
      ..writeln('Check: who wrote the newest message and to whom; whether you are the one asked (by name, by role, or by a reply to you); '
          'whether a teammate already answered or is answering; whether the owner needs to act. Speak only if you add something. '
          '${NeedsYou.rule}');
    return sb.toString().trim();
  }

  /// The chat block for an observer (the "who speaks" decision): roster and labelled lines, no self.
  static String observer(Office o, {DateTime? now, int max = 16}) {
    final l = lines(o, max: max, clip: 300);
    return '# Roster\n${roster(o)}\n\n# Team chat (oldest first)\n${l.isEmpty ? '(empty)' : l.join('\n')}\n\n# The situation\n'
        '${situation(o, now: now).map((s) => '- $s').join('\n')}';
  }
}

/// Who answers a new owner message.
class FloorPick {
  const FloorPick(this.speakers, this.why, {this.needModel = false});
  final List<Bot> speakers;

  /// addressed | role | continues | model
  final String why;
  final bool needModel;
}

class TeamFloor {
  TeamFloor._();

  /// A bot's question the owner is probably answering stays "open" this long.
  static const followUp = Duration(minutes: 15);

  static final _leadWord = RegExp(r'\b(team lead|the lead|our lead|lead,|chief)\b', caseSensitive: false);

  /// The cheap rules, before any model call. [addressed]: who the owner named (@mention, reply, name first).
  static FloorPick rules(Office o, String text, {List<Bot> addressed = const [], DateTime? now}) {
    if (addressed.isNotEmpty) return FloorPick(addressed, 'addressed');
    final members = [for (final id in o.members) Bots.I.byId(id)].whereType<Bot>().toList();
    // A role named ("the researcher, …", "can our analyst check…"): that member, when exactly one fits.
    final byRole = <Bot>[];
    final low = text.toLowerCase();
    for (final b in members) {
      final r = b.role.trim().toLowerCase();
      if (r.length < 4) continue;
      if (RegExp('\\b${RegExp.escape(r)}s?\\b').hasMatch(low)) byRole.add(b);
    }
    if (byRole.length == 1) return FloorPick(byRole, 'role');
    if (byRole.isEmpty && _leadWord.hasMatch(text)) {
      final lead = Bots.I.byId(o.chiefId);
      if (lead != null) return FloorPick([lead], 'role');
    }
    // Continuing: the last thing said before this message was one bot's question to the owner, a moment ago.
    final at = now ?? DateTime.now();
    final talk = o.posts.where((p) => p.kind != 'system' && p.kind != 'update').toList();
    // The owner's own new post may already be in the chat (posted before routing): look before it.
    var i = talk.length - 1;
    if (i >= 0 && talk[i].from == 'you' && talk[i].text.trim() == text.trim()) i--;
    if (i >= 0) {
      final p = talk[i];
      final b = Bots.I.byId(p.from);
      if (b != null && o.members.contains(b.id) && at.difference(p.at) < followUp && (p.kind == 'ask' || TeamTranscript.isQuestion(p.text))) {
        return FloorPick([b], 'continues');
      }
    }
    return const FloorPick([], 'model', needModel: true);
  }
}

/// Turn-taking of office jobs.
class TeamTurns {
  TeamTurns._();

  /// A job of a thread waits while another job of the same thread runs.
  static bool waitsForThread(OfficeJob j, Iterable<String> runningThreads) => j.thread.isNotEmpty && runningThreads.contains(j.thread);
}

/// A standing "when X posts, do Y" in a team (owner 2026-11-06: "bot B, analyze bot A's research once it posts" left
/// B silent, because a bot only ever took a turn when the owner wrote). Saved with the team; fired by [TeamReact] the
/// moment the watched teammate posts, without anyone writing again.
class TeamWatch {
  TeamWatch({
    required this.id,
    required this.watcher,
    required this.from,
    required this.instruction,
    this.by = 'you',
    DateTime? at,
    DateTime? until,
    this.once = true,
    this.task = '',
  })  : at = at ?? DateTime.now(),
        until = until ?? (at ?? DateTime.now()).add(life);

  /// How long a watch waits before it lapses.
  static const life = Duration(hours: 24);

  final String id;

  /// The bot that takes the turn.
  final String watcher;

  /// The bot whose post fires it, or [anyone].
  final String from;

  /// What to do then (the owner's words, or the lead's hand-off).
  final String instruction;

  /// Who set it: 'you' (the owner) or a bot id (a lead waiting for a report, or a bot's own office_watch).
  final String by;
  final DateTime at;
  final DateTime until;
  final bool once;

  /// The assignment it follows up (a lead waiting for a report), shown in the "still waiting on" line.
  final String task;

  static const anyone = '*';

  bool expired([DateTime? now]) => !(now ?? DateTime.now()).isBefore(until);

  static int _seq = 0;
  static String newId() => 'w${DateTime.now().microsecondsSinceEpoch}${(_seq++ % 1000).toString().padLeft(3, '0')}';

  Map<String, dynamic> toJson() => {
        'id': id, 'w': watcher, 'f': from, 'i': instruction, 'by': by, 'at': at.toIso8601String(), 'u': until.toIso8601String(),
        if (!once) 'r': true, if (task.isNotEmpty) 'tk': task,
      };

  static TeamWatch fromJson(Map<String, dynamic> j) => TeamWatch(
        id: '${j['id'] ?? newId()}',
        watcher: '${j['w'] ?? ''}',
        from: '${j['f'] ?? anyone}',
        instruction: '${j['i'] ?? ''}',
        by: '${j['by'] ?? 'you'}',
        at: DateTime.tryParse('${j['at']}'),
        until: DateTime.tryParse('${j['u']}'),
        once: j['r'] != true,
        task: '${j['tk'] ?? ''}',
      );
}

/// One turn a team post starts for a bot.
class TeamTrigger {
  const TeamTrigger(this.botId, this.kind, this.instruction, {this.watchIds = const []});
  final String botId;

  /// react (a watch fired) | assign (a lead or teammate handed it work) | mention (a teammate wrote to it)
  final String kind;
  final String instruction;
  final List<String> watchIds;
}

/// What one team post sets off: the turns it starts, the watches it used up and the ones it adds.
class TeamReaction {
  TeamReaction(this.triggers, this.fired, this.added, {this.skipped = const []});
  final List<TeamTrigger> triggers;

  /// Watches that fired once and are done.
  final List<String> fired;

  /// New watches (a lead waiting for the report of the work it just assigned).
  final List<TeamWatch> added;

  /// Why a trigger did not happen (loop guards), for diagnostics and tests.
  final List<String> skipped;

  static final none = TeamReaction(const [], const [], const []);
}

/// Event-driven team turns (owner 2026-11-06, "bots and teams, highest priority"):
///  1. Any team post can start a teammate's turn, not only the owner's messages: a watch on its author fires
///     ([TeamWatch]), a lead's assignment ("Nova: find three prices", "@Nova …") starts the assignee at once and the
///     lead hears back when it reports, a teammate's question wakes the one asked.
///  2. Loop guards: each turn carries the depth of the chain that started it (the owner's message is 0); bot-to-bot
///     turns stop at [maxDepth] (watches the owner set at [watchDepth]); a post starts at most one turn per bot; a
///     plain reply (mention) never wakes the teammate that woke it (no ping-pong); a team has at most [burst]
///     bot-started turns in [burstWindow]; small talk ("thanks Nova") starts nothing; a bot may always answer
///     [no reply].
class TeamReact {
  TeamReact._();

  /// Deepest chain of bot-to-bot turns (owner's message → bot → bot → bot → bot).
  static const maxDepth = 4;

  /// Watches the owner set reach a little further (they were asked for by name).
  static const watchDepth = 8;

  /// At most this many bot-started turns per team in [burstWindow] (a runaway chain stops here).
  static const burst = 20;
  static const burstWindow = Duration(minutes: 10);

  static final _when = RegExp(
      r"\b(once|when|whenever|after|as soon as|wait(ing)? (for|until|till)|until|till|then)\b|\b(marka|kadib|ka dib|markay|markuu)\b|(عندما|بعد ما|بعدما|حين)",
      caseSensitive: false);
  static final _event = RegExp(
      r"\b(posts?|posted|finish(es|ed)?|done|shares?|shared|reports?|reported|sends?|sent|publish(es|ed)?|comes? (in|back)|ready|deliver(s|ed)?|"
      r"repl(y|ies|ied)|answers?|answered|completes?|completed|results?|research|findings|report|draft|soo diro|dhammeeyo|keeno)\b|(ينشر|ينتهي|يرسل)",
      caseSensitive: false);

  static String _nameRe(String name) => '(?<![\\w\\u0600-\\u06FF])${RegExp.escape(name)}(?:[\'’]s)?(?![\\w\\u0600-\\u06FF])';

  static List<Bot> _members(Office o) => [for (final id in o.members) Bots.I.byId(id)].whereType<Bot>().toList();

  /// Watches in an owner message: "Amal, analyze Nova's research once it posts", "when Nova is done, Amal checks it",
  /// "@Amal wait for Nova's report, then write the summary". [addressed]: who the owner wrote to (the watchers when
  /// the sentence itself names only the source). Sentence by sentence; a sentence needs a "when" word, an event word
  /// and a teammate whose post it waits for.
  static List<TeamWatch> fromOwner(Office o, String text, {List<Bot> addressed = const [], DateTime? now}) {
    final at = now ?? DateTime.now();
    final members = _members(o);
    final out = <TeamWatch>[];
    for (final s in text.split(RegExp(r'(?<=[.!?؟])\s+|\n+|;\s*'))) {
      final w = _when.firstMatch(s);
      if (w == null || !_event.hasMatch(s)) continue;
      final named = <({Bot bot, int at, bool possessive})>[];
      for (final b in members) {
        final m = RegExp(_nameRe(b.name), caseSensitive: false).firstMatch(s);
        if (m != null) named.add((bot: b, at: m.start, possessive: RegExp('[\'’]s\$').hasMatch(m.group(0)!)));
      }
      if (named.isEmpty) continue;
      named.sort((a, b) => a.at.compareTo(b.at));
      // The source: the teammate whose post is waited for. "Nova's result", "when Nova posts", "after Nova".
      Bot? source;
      for (final n in named) {
        final after = s.substring(n.at + n.bot.name.length).toLowerCase();
        final before = s.substring(0, n.at).toLowerCase();
        final followsWhen = RegExp(r'(once|when|whenever|after|as soon as|for|until|till|marka|kadib)\s+(@)?$').hasMatch(before.trimRight().isEmpty ? before : '${before.trimRight()} ');
        final eventSoon = RegExp(r"^(?:['’]s)?\s*(?:\w+\s+){0,3}?(posts?|posted|finish|finishes|finished|is done|is ready|shares?|reports?|sends?|publishes|delivers?|replies|answers?|completes?)\b").hasMatch(after);
        if (n.possessive || followsWhen || eventSoon) {
          source = n.bot;
          break;
        }
      }
      if (source == null) continue;
      var watchers = [for (final n in named) if (n.bot.id != source.id) n.bot];
      if (watchers.isEmpty) watchers = [for (final b in addressed) if (b.id != source.id) b];
      for (final b in watchers) {
        if (out.any((x) => x.watcher == b.id && x.from == source!.id)) continue;
        out.add(TeamWatch(id: TeamWatch.newId(), watcher: b.id, from: source.id, instruction: text.trim(), at: at));
      }
    }
    return out;
  }

  /// The work [text] by [authorId] hands to teammates: lines that open on a teammate's name ("Nova: …", "- Nova, …",
  /// "1. @Nova …"), and @mentions (the sentence around each, or the whole post when short; "@team" = everyone).
  static List<({Bot bot, String ask})> assignmentsIn(Office o, String text, String authorId) {
    final out = <({Bot bot, String ask})>[];
    final members = _members(o);
    Bot? byName(String n) {
      final l = n.toLowerCase();
      return members.where((b) => b.name.toLowerCase() == l || b.role.toLowerCase().replaceAll(' ', '') == l).firstOrNull;
    }

    final line = RegExp(r'^\s*(?:[-*•▪◦]\s*|\d{1,2}[.)]\s*)?(?:\*\*)?@?([\w\u0600-\u06FF-]+)(?:\*\*)?\s*(?:[:,،–—]|\s-)\s*(.+)$');
    for (final l in text.split('\n')) {
      final m = line.firstMatch(l);
      if (m == null) continue;
      final b = byName(m.group(1)!);
      final ask = m.group(2)!.trim();
      if (b == null || b.id == authorId || ask.isEmpty || out.any((x) => x.bot.id == b.id)) continue;
      out.add((bot: b, ask: ask));
    }
    final mentioned = Offices.I.mentioned(o, text);
    if (mentioned.isNotEmpty) {
      final sentences = text.split(RegExp(r'(?<=[.!?؟])\s+|\n+'));
      for (final b in mentioned) {
        if (b.id == authorId || out.any((x) => x.bot.id == b.id)) continue;
        final s = sentences.where((x) => RegExp('@${RegExp.escape(b.name)}\\b', caseSensitive: false).hasMatch(x)).firstOrNull;
        out.add((bot: b, ask: (text.length <= 400 || s == null ? text : s).trim()));
      }
    }
    return out;
  }

  /// A post that may fire a watch: real content (chat, report, answer, a question to the owner) or a "Done:" update.
  static bool firesWatch(OfficePost p) =>
      p.kind == 'chat' || p.kind == 'report' || p.kind == 'answer' || p.kind == 'ask' || (p.kind == 'update' && p.text.startsWith('Done'));

  static String _short(String s, int n) {
    final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length > n ? '${t.substring(0, n)}…' : t;
  }

  static final _report = RegExp(
      r"^(?:[\s,.:;-]*)(done|found|finished|sent|made|wrote|built|delivered|shared|reported|posted|completed|has|have|had|is|was|were|did|got|"
      r"already|thanks|thank you|great|good|nice|well done|good job|agreed|confirmed|ready|here (is|are)|her(e|e's)|dhammeeyay|waa la dhammeeyay)\b",
      caseSensitive: false);

  /// A line about work done (a report or a credit), not work asked for: "found three prices", "built the table".
  static bool reportLike(String ask) {
    final t = ask.trim();
    if (_report.hasMatch(t)) return true;
    final first = RegExp(r'^[A-Za-z]+').firstMatch(t)?.group(0)?.toLowerCase() ?? '';
    return first.length > 4 && first.endsWith('ed') && !const {'need', 'feed', 'speed', 'proceed', 'embed'}.contains(first);
  }

  /// "Thanks @Amal!", "Nova: great": small talk once the names are taken out.
  static bool _smallTalk(Office o, String text) {
    var t = text.replaceAll(RegExp(r'@[\w\u0600-\u06FF-]+'), ' ');
    for (final b in _members(o)) {
      t = t.replaceAll(RegExp(_nameRe(b.name), caseSensitive: false), ' ');
    }
    t = t.replaceAll(RegExp(r'^[\s,.:;!-]+'), '').replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.isEmpty || QuickLane.isSmallTalk(t);
  }

  /// What post [p] sets off. [depth]: the chain depth of the turn that wrote it (0 = no bot turn, or the owner's
  /// message); [cause]: who started that turn (a bot id, 'you' or ''); [causeKind]: that turn's kind; [assigns]:
  /// false for a structured team job's own posts (its plan and hand-offs already run their members).
  static TeamReaction of(Office o, OfficePost p, {int depth = 0, String cause = '', String causeKind = '', bool assigns = true, DateTime? now}) {
    if (p.from == 'you' || p.from == 'system' || p.kind == 'system') return TeamReaction.none;
    final author = Bots.I.byId(p.from);
    if (author == null || !o.members.contains(author.id)) return TeamReaction.none;
    final at = now ?? DateTime.now();
    final triggers = <TeamTrigger>[];
    final fired = <String>[];
    final added = <TeamWatch>[];
    final skipped = <String>[];
    final next = depth + 1;
    final isLead = author.id == o.chiefId;

    // 1. Watches on this author.
    if (firesWatch(p)) {
      final byBot = <String, List<TeamWatch>>{};
      for (final w in o.watches) {
        if (w.expired(at) || w.watcher == author.id || !o.members.contains(w.watcher)) continue;
        if (w.from != author.id && w.from != TeamWatch.anyone) continue;
        (byBot[w.watcher] ??= []).add(w);
      }
      for (final e in byBot.entries) {
        final owners = e.value.where((w) => w.by == 'you').isNotEmpty;
        if (next > (owners ? watchDepth : maxDepth)) {
          skipped.add('depth:${e.key}');
          continue;
        }
        final asks = [for (final w in e.value) w.by == 'you' ? 'The owner asked: "${_short(w.instruction, 600)}"' : _short(w.instruction, 600)];
        // A lead waiting on several reports: say who is still to come, so it sums up once, at the end.
        final still = [
          for (final w in o.watches)
            if (!e.value.contains(w) && w.watcher == e.key && w.by == e.key && !w.expired(at) && w.from != author.id) Bots.I.byId(w.from)?.name ?? '?'
        ];
        triggers.add(TeamTrigger(
            e.key,
            'react',
            '${author.name} just posted in the team chat:\n"${_short(p.text, 1500)}"\n\n'
                'You were waiting for this. ${asks.join('\n')}${still.isEmpty ? '' : '\nStill waiting on: ${still.join(', ')}.'}',
            watchIds: [for (final w in e.value) w.id]));
        fired.addAll([for (final w in e.value) if (w.once) w.id]);
      }
    }

    // 2. Work handed to teammates, and teammates asked something.
    if (assigns && (p.kind == 'chat' || p.kind == 'answer' || p.kind == 'report' || p.kind == 'ask')) {
      for (final a in assignmentsIn(o, p.text, author.id)) {
        if (triggers.any((t) => t.botId == a.bot.id)) continue;
        if (_smallTalk(o, a.ask) || _smallTalk(o, p.text)) {
          skipped.add('smalltalk:${a.bot.id}');
          continue;
        }
        final question0 = TeamTranscript.isQuestion(a.ask);
        // A line that reports or credits ("Nova: found three prices", "Amal: done, table attached") hands nothing out.
        if (!question0 && reportLike(a.ask)) {
          skipped.add('report:${a.bot.id}');
          continue;
        }
        // The same work already on the board for them, just added by this author: the task job runs it (no twice).
        if (o.tasks.any((t) => t.owner == a.bot.id && t.createdBy == author.id && (t.status == 'todo' || t.status == 'doing' || t.status == 'proposed') &&
            at.difference(t.createdAt) < const Duration(minutes: 10))) {
          skipped.add('board:${a.bot.id}');
          continue;
        }
        if (next > maxDepth) {
          skipped.add('depth:${a.bot.id}');
          continue;
        }
        final question = TeamTranscript.isQuestion(a.ask) && !QuickLane.hasAction(a.ask);
        final kind = question ? 'mention' : ((isLead || QuickLane.hasAction(a.ask) || QuickLane.isRequest(a.ask)) ? 'assign' : 'mention');
        // A plain answer never wakes the teammate whose message started this turn (two bots thanking each other forever).
        if (kind == 'mention' && a.bot.id == cause && (causeKind == 'mention' || causeKind == 'react' || causeKind == 'assign')) {
          skipped.add('pingpong:${a.bot.id}');
          continue;
        }
        if (kind == 'assign') {
          triggers.add(TeamTrigger(
              a.bot.id,
              'assign',
              '${author.name}${isLead ? ' (the team lead)' : ''} handed you this in the team chat: "${_short(a.ask, 1200)}"'
                  '${a.ask.trim() == p.text.trim() ? '' : '\n(Their whole message: "${_short(p.text, 800)}")'}'));
          // The one who handed it out hears back when it is done, without anyone asking (owner 2026-11-06).
          if (!o.watches.any((w) => w.watcher == author.id && w.from == a.bot.id && !w.expired(at)) && !added.any((w) => w.from == a.bot.id)) {
            added.add(TeamWatch(
                id: TeamWatch.newId(),
                watcher: author.id,
                from: a.bot.id,
                by: author.id,
                task: _short(a.ask, 200),
                at: at,
                instruction: 'You handed ${a.bot.name} this: "${_short(a.ask, 300)}". Check their report: hand out the next step if one '
                    'follows, or, when every part you are waiting on is in, post one short summary for the owner. Nothing to do yet: '
                    '${NoReply.token}.'));
          }
        } else {
          triggers.add(TeamTrigger(a.bot.id, 'mention', '${author.name} wrote to you in the team chat: "${_short(p.text, 1200)}"'));
        }
      }
    }
    return TeamReaction(triggers, fired, added, skipped: skipped);
  }
}

