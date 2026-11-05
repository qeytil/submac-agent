/// The route key of one piece of team work (bots team audit, owner 2026-11-04): a team member's or lead's part of a
/// team job, or one office job (an owner's question in the team chat, a board task, a review).
///
/// `team:<officeId>:<botId>`, or `team:<officeId>~<job>:<botId>` when several pieces of work of the same bot in the
/// same team run side by side (each has its own key, so ending one never ends the other's routing).
///
/// Team work runs under this key, never under the bot's private chat id: its tool calls, approval cards, browser jobs,
/// screen lease and asks belong to the team work, so nothing of it lands in the bot's 1:1 chat with the owner (it used
/// to: an office job ran as a wake inside the bot's private chat, so every team reply, step and result showed twice).
class TeamKey {
  TeamKey._();

  static const prefix = 'team:';

  static String of(String officeId, String botId, {String? job}) =>
      '$prefix$officeId${job == null || job.isEmpty ? '' : '~$job'}:$botId';

  static bool isKey(String? s) => s != null && s.startsWith(prefix) && s.indexOf(':', prefix.length) > prefix.length;

  /// The bot whose work this is ('' when [key] is no team key).
  static String botOf(String? key) => isKey(key) ? key!.substring(key.lastIndexOf(':') + 1) : '';

  /// The team (office) this work is for ('' when [key] is no team key).
  static String officeOf(String? key) {
    if (!isKey(key)) return '';
    final mid = key!.substring(prefix.length, key.lastIndexOf(':'));
    final t = mid.indexOf('~');
    return t < 0 ? mid : mid.substring(0, t);
  }

  static int _seq = 0;

  /// A fresh job tag, unique for this app run.
  static String job() => '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${(_seq++).toRadixString(36)}';
}
