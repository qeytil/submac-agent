// Notifications that say who it is from and what came of the work (owner 2026-11-05: "never 'Running your scheduled
// task'; show a short summary of the result"). Plain functions, so the wording, the channel and the reply routing
// are tested without a phone. Android draws them (android_native/Notifier.kt); the flow is in docs/notifications.md.
import '../widgets/sub_avatar.dart';
import 'bg_runs.dart';
import 'no_reply.dart';

/// Who a notification is from. Each has its own Android channel, so the owner can tune them apart.
enum NotifFrom {
  /// The owner's own Telesia (its main chat, its scheduled tasks): title "Telesia", Telesia red accent.
  agent,

  /// One of the owner's bots, in its private chat: titled with the bot's name, its avatar colour as the icon.
  bot,

  /// A team chat: titled with the team's name, each line "<Bot name>: message", one conversation per team.
  team,

  /// Work running with Telesia closed (the foreground line "Nova · Hourly news"): silent, low priority.
  work,
}

/// The Android channel ids. A channel keeps the sound it was made with, so the new chime needed new ids; the old
/// ones are deleted on start (Notifier.ensureChannels).
class NotifChannels {
  NotifChannels._();

  static const agent = 'telesia_agent_v2';
  static const bots = 'telesia_bots_v2';
  static const teams = 'telesia_teams_v2';
  static const work = 'telesia_work_v2';

  /// Channels from before the chime: removed so the phone's settings list only the ones in use.
  static const retired = ['telesia_tasks', 'telesia_tasks_v2', 'telesia_bot_msgs'];

  static String of(NotifFrom from) => switch (from) {
        NotifFrom.agent => agent,
        NotifFrom.bot => bots,
        NotifFrom.team => teams,
        NotifFrom.work => work,
      };
}

/// The words on a notification.
class NotifText {
  NotifText._();

  /// The longest summary a result notification carries.
  static const maxSummary = 240;

  /// The title for [from]: "Telesia" for the agent, the bot's name, the team's name.
  static String title(NotifFrom from, {String bot = '', String team = ''}) {
    final b = bot.trim(), t = team.trim();
    return switch (from) {
      NotifFrom.agent => 'Telesia',
      NotifFrom.bot => b.isEmpty ? 'Telesia' : b,
      NotifFrom.team => t.isEmpty ? (b.isEmpty ? 'Team' : b) : t,
      NotifFrom.work => b.isEmpty ? 'Telesia' : b,
    };
  }

  /// The line while work runs with Telesia closed: "Nova · Hourly news" (never "Running your scheduled task").
  static String running(String sender, String task) => BgRun.line(sender, BgRun.title(task, fallback: ''));

  /// One line of a team conversation: "Nova: the draft is ready".
  static String teamLine(String bot, String text) {
    final s = summary(text, max: 200, lines: 2);
    final n = bot.trim();
    return n.isEmpty ? s : '$n: $s';
  }

  static final _fence = RegExp(r'```[\s\S]*?(```|$)');
  static final _field = RegExp(r'"(title|headline|summary|text|caption)"\s*:\s*"((?:[^"\\]|\\.){3,})"');
  static final _tag = RegExp(r'^\s*@(silent|note|message|call)\b.*$', caseSensitive: false, multiLine: true);

  /// A short summary of a reply for a notification: its first meaningful sentences, with markdown, code, cards,
  /// links, tags and greetings taken off, at most [lines] lines and [max] characters. [fallback] when nothing is left
  /// (a reply that was only a card or code).
  static String summary(String reply, {int max = maxSummary, int lines = 3, String fallback = ''}) {
    var t = reply.replaceAll('\r', '');
    final fences = _fence.allMatches(t).map((m) => m.group(0)!).toList();
    t = t.replaceAll(_fence, '\n');
    t = t.replaceAll(_tag, '');
    t = NoReply.clean(t);
    // The team's "[needs you]" mark (team_floor.dart NeedsYou) is for the chat, not the notification.
    t = t.replaceAll(RegExp(r'\[\s*needs[\s_-]*you\s*\]|@owner\b', caseSensitive: false), '');
    // Images go, links keep their words, bare urls go.
    t = t.replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), '');
    t = t.replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]*\)'), (m) => m.group(1)!);
    t = t.replaceAll(RegExp(r'<[^>\n]{1,80}>'), '');
    t = t.replaceAll(RegExp(r'https?://\S+'), '');
    t = t.replaceAll(RegExp(r'`([^`]*)`'), r'$1');
    final out = <String>[];
    var used = 0;
    for (var line in t.split('\n')) {
      line = line
          .replaceFirst(RegExp(r'^\s{0,3}(#{1,6}\s+|>\s*|[-*+•]\s+|\d{1,2}[.)]\s+)'), '')
          .replaceAll(RegExp(r'\*\*|__|~~|\*|(?<!\w)_(?!\w)'), '')
          .replaceAll(RegExp(r'^\|.*\|$'), '')
          .replaceAll(RegExp(r'^\s*[-=:|]{3,}\s*$'), '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (line.isEmpty || _filler(line)) continue;
      out.add(line);
      used += line.length;
      if (out.length >= lines || used >= max) break;
    }
    var s = out.join('\n').trim();
    if (s.isEmpty) {
      // A card-only reply: its title or summary field, if it has one.
      for (final f in fences) {
        final m = _field.firstMatch(f);
        if (m != null) {
          s = m.group(2)!.replaceAll(r'\"', '"').trim();
          break;
        }
      }
    }
    if (s.isEmpty) return fallback;
    if (s.length > max) {
      var cut = s.substring(0, max - 1);
      // End on a sentence when there is one in the second half, else on a word.
      final end = cut.lastIndexOf(RegExp(r'[.!?](\s|$)'));
      if (end > max ~/ 2) {
        cut = cut.substring(0, end + 1);
        return cut.trim();
      }
      final sp = cut.lastIndexOf(RegExp(r'\s'));
      if (sp > max ~/ 2) cut = cut.substring(0, sp);
      s = '${cut.trimRight()}…';
    }
    return s;
  }

  /// Lines that say nothing on their own in a notification: a greeting, "Here is…:", "Done!".
  static bool _filler(String line) {
    final l = line.toLowerCase().replaceAll(RegExp(r'[^a-z ]'), '').trim();
    if (l.isEmpty) return true;
    if (RegExp(r'^(hi|hello|hey|salaam|good (morning|afternoon|evening))( there| [a-z]+)?$').hasMatch(l)) return true;
    if (line.trim().endsWith(':') && RegExp(r'^(here (is|are)|heres|this is|these are|below)').hasMatch(l)) return true;
    return false;
  }

  /// The result notification's text for [reply], or '' when it should stay silent (no reply, a watcher's NO_CHANGE).
  static String result(String reply, {String task = ''}) {
    final r = reply.trim();
    if (r.isEmpty || NoReply.isSilent(r) || (r.contains('NO_CHANGE') && r.length < 40)) return '';
    final t = BgRun.title(task, fallback: '');
    return summary(r, fallback: t.isEmpty ? 'Done.' : 'Done: $t');
  }
}

/// Where a reply typed in a notification goes. The payload is the one the notification opens: 'office/<id>' (a team
/// chat), 'conv/<id>' (a bot's private chat or Telesia's own chat), 'botchat/<bot id>'.
class NotifRoute {
  const NotifRoute(this.from, this.id);

  final NotifFrom from;

  /// The team id, the chat id, or the bot id (for 'botchat/').
  final String id;

  static NotifRoute? parse(String to, {bool Function(String convId)? isBotConv}) {
    final p = to.trim();
    String rest(String pre) => p.substring(pre.length).trim();
    if (p.startsWith('office/') && rest('office/').isNotEmpty) return NotifRoute(NotifFrom.team, rest('office/'));
    if (p.startsWith('botchat/') && rest('botchat/').isNotEmpty) return NotifRoute(NotifFrom.bot, rest('botchat/'));
    if (p.startsWith('conv/') && rest('conv/').isNotEmpty) {
      final c = rest('conv/');
      return NotifRoute((isBotConv?.call(c) ?? false) ? NotifFrom.bot : NotifFrom.agent, c);
    }
    return null;
  }

  /// The payload for this route (what a tap opens and what Reply answers).
  String get payload => switch (from) {
        NotifFrom.team => 'office/$id',
        _ => 'conv/$id',
      };
}

/// A bot's notification icon: its first letter on its avatar colour (Notifier draws it). The agent has none (its
/// own Telesia mark and red accent).
class NotifFace {
  const NotifFace(this.initial, this.color);

  final String initial;

  /// ARGB.
  final int color;

  static NotifFace of(String name, int color) {
    final n = name.trim();
    final first = n.isEmpty ? '?' : String.fromCharCodes(n.runes.take(1)).toUpperCase();
    return NotifFace(first, color);
  }

  /// A bot's face: its avatar colour (the owner's pick, else its own seeded one), its first letter.
  static NotifFace ofBot(String id, String name, String? look) {
    final spec = AvatarSpec.parse(look) ?? AvatarSpec.seeded(id);
    return of(name, AvatarSpec.colorOf(spec.color).toARGB32());
  }

  /// Telesia red, for the agent's accent.
  static const agentAccent = 0xFFC2361B;

  /// The calm ink every bot notification used before; kept for teams.
  static const ink = 0xFF17150F;
}
