import 'bots.dart';
import 'offices.dart';

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
      ? 'Lead mode: LEADING (${o.delegated ? 'the owner handed over' : 'the owner is away'}). Split the work into concrete subtasks per role, '
          'assign each by name with what to hand back, follow up, report once. Never forward the owner\'s words: make specific asks.'
      : 'Lead mode: PEER (the owner is here and leads): act as a member in your role; do not assign, restate or relay the '
          'owner\'s messages. You lead only when they are away or ask.';
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
