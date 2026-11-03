import 'cloud.dart';
import 'opencode.dart';

/// Which allowance lane an opencode turn's model calls bill to (owner 2026-11-03).
///
/// The cause: opencode on the phone had one provider (`submac`), so every model call it made, a bot's wake and a team
/// member's part included, reached ai-chat without `x-submac-lane: background`. Bot work was billed as the owner's own
/// chat and was never paused when the bots' share ran out; bots also always ran on the `submac` alias.
///
/// The fix: opencode gets one provider per lane, each pointing at its own path on the app's local proxy. The proxy
/// (LocalProxy.kt) turns the path into the lane: `/__submac/lane/<source>/...` goes out with `x-submac-lane: background`
/// and `x-submac-source: <source>`; any other `/__submac/...` call goes out with the lane header removed, so a
/// foreground call can never carry it. Every prompt names its provider and model explicitly (opencode's per-message
/// `model`), so the lane is chosen per turn and per session and cannot leak between turns running side by side: it
/// travels in each request's own path, not in shared state. (opencode would otherwise reuse a session's last model, so
/// a bot chat the owner types in after a background wake would stay on the background lane.) Subagents opencode starts
/// in child sessions inherit the parent message's provider, so they bill to the same lane.
class OcLane {
  OcLane._();

  /// The owner's own chats (and the owner typing in a bot's chat): the user's lane.
  static const fg = 'submac';

  /// A bot's own background work (wakes, routines, follow-ups): the bots' share, billed as `bot`.
  static const bot = 'submac-bg';

  /// Office and team work nobody is watching (team members' and leads' parts): the bots' share, billed as `office`.
  static const office = 'submac-office';

  /// The source each background provider sends (ai-chat BOT_SOURCES: both bill to the bots' share).
  static const bgSources = {bot: 'bot', office: 'office'};

  /// The proxy path prefix that marks the background lane (after LocalProxy.PREFIX).
  static const lanePath = '/lane/';

  /// SubMac's chat model names opencode may be asked for. ai-chat treats every `submac*` chat name as the one model
  /// (older apps sent these aliases), so each is safe to send. The image model is not a chat model.
  static const models = ['submac', 'submac-smart', 'submac-fast', 'submac-think', 'submac-lite', 'submac-vision', 'submac-somali'];

  /// The providers written into opencode's config (OpenCode.kt builds the JSON): id, shown name, proxy path and the
  /// `x-submac-source` header. Every provider offers the same [models].
  static List<Map<String, String>> providers() => [
        {'id': fg, 'name': 'SubMac', 'path': '', 'source': 'opencode'},
        for (final e in bgSources.entries) {'id': e.key, 'name': 'SubMac (${e.value})', 'path': '$lanePath${e.value}', 'source': e.value},
      ];

  /// The model a bot's turn runs on: its own setting (`auto` or `providerId|model`) when that names one of SubMac's
  /// chat models, else `submac`. SubMac Cloud is the only provider, so another provider id falls back too.
  static String modelFor(String? setting) {
    final s = (setting ?? '').trim();
    if (s.isEmpty || s == 'auto') return Cloud.submac;
    final i = s.indexOf('|');
    final provider = i >= 0 ? s.substring(0, i).trim() : '';
    final model = (i >= 0 ? s.substring(i + 1) : s).trim().toLowerCase();
    if (provider.isNotEmpty && provider != Cloud.providerId) return Cloud.submac;
    return models.contains(model) ? model : Cloud.submac;
  }

  /// The prompt's `model` for one turn. [background]: nobody is watching (a bot's wake, office or team work).
  /// [officeWork]: that background work is office/team work. [botModel]: the bot's model setting, null for the owner.
  static Map<String, String> pick({required bool background, bool officeWork = false, String? botModel}) => {
        'providerID': background ? (officeWork ? office : bot) : fg,
        'modelID': botModel == null ? Cloud.submac : modelFor(botModel),
      };

  static bool isBackground(Map<String, String>? model) => model != null && bgSources.containsKey(model['providerID']);

  /// ai-chat's refusal of background work when the bots' share is used up (429 background_paused). opencode retries
  /// a 429 on its own, so it arrives as a retry status (or an error) carrying the server's message.
  static final _paused = RegExp(r'background_paused|background tasks are paused|paused until (tomorrow|midnight)', caseSensitive: false);
  static bool isPausedText(String? s) => s != null && _paused.hasMatch(s);
}

/// Why a background opencode turn must stop now (owner 2026-11-03), checked as its events arrive. Pure, so tested
/// without the engine.
///  - `paused`: ai-chat refused it for the bots' share (opencode would retry the 429 until the turn timed out).
///  - `budget`: the bot's own daily token budget ran out mid-turn ([budgetLeft] tokens were left when it started).
class OcBgGuard {
  OcBgGuard({required this.background, this.budgetLeft});
  final bool background;
  final int? budgetLeft;

  static const paused = 'paused', budget = 'budget';

  /// Tokens a bot may still use today ([budgetK] thousand a day, 0 = no budget): null when it has no budget.
  static int? leftOf(int budgetK, int usedToday) {
    if (budgetK <= 0) return null;
    final left = budgetK * 1000 - usedToday;
    return left < 0 ? 0 : left;
  }

  String? check(OpenCodeTurn t) {
    if (!background) return null;
    if (OcLane.isPausedText(t.retry) || OcLane.isPausedText(t.error)) return paused;
    final left = budgetLeft;
    if (left != null && t.tokens > 0 && t.tokens >= left) return budget;
    return null;
  }
}
