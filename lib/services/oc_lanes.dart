import 'byok.dart';
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

  /// The SubMac model a bot's turn runs on: its own setting (`auto` or `providerId|model`) when that names one of
  /// SubMac's chat models, else `submac`. A BYOK setting (`byok-…|model`) is resolved first by [pick]; here any other
  /// provider id falls back to `submac`.
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
  ///
  /// BYOK (owner 2026-11-03, docs/byok.md): the owner's chats use the model chosen in Settings → Models
  /// ([userModel], default the saved choice), a bot uses its own setting; when either names a usable model of the
  /// user's own providers, the turn goes to that provider and model directly (`byok-…`), whatever the lane: lanes only
  /// decide SubMac billing, and a BYOK call is never billed by SubMac. Anything unusable falls back to SubMac.
  static Map<String, String> pick({required bool background, bool officeWork = false, String? botModel, String? userModel}) {
    final setting = botModel == null ? (userModel ?? ByokStore.I.chatModel) : botSetting(botModel, userModel: userModel);
    final own = byokFor(setting);
    if (own != null) return own;
    return {
      'providerID': background ? (officeWork ? office : bot) : fg,
      'modelID': botModel == null ? Cloud.submac : modelFor(setting),
    };
  }

  /// A bot's model setting left at its default: `auto` or empty ("Default (same as SubMac)" in its profile).
  static bool isDefault(String? setting) {
    final s = (setting ?? '').trim();
    return s.isEmpty || s == 'auto';
  }

  /// The model setting a bot's turn really runs on (owner 2026-11-05: each bot picks its model in its own profile).
  ///  - Default (`auto`): the same model as SubMac, i.e. the owner's chat model ([userModel], default the one chosen
  ///    in Settings → Models), whether that is SubMac or one of the owner's own providers.
  ///  - An own-provider model (`byok-…|model`) that is no longer usable here (provider removed or off, model off,
  ///    no key, or a setting synced from another phone with other providers): falls back to that default.
  ///  - `submac` / `submac|alias`: SubMac's own model, whatever the owner's chats use.
  static String botSetting(String? botModel, {String? userModel, ByokStore? store}) {
    final st = store ?? ByokStore.I;
    final fallback = userModel ?? st.chatModel;
    if (isDefault(botModel)) return fallback;
    final s = botModel!.trim();
    if (ByokRef.parse(s) != null && st.resolve(s) == null) return fallback;
    return s;
  }

  /// Whether a bot's chosen model is set but cannot be used here now (it runs on the default instead).
  static bool botModelUnavailable(String? botModel, {ByokStore? store}) {
    if (isDefault(botModel)) return false;
    return ByokRef.parse(botModel) != null && (store ?? ByokStore.I).resolve(botModel) == null;
  }

  /// The prompt `model` of a BYOK setting, or null when it does not name a usable model of the user's providers.
  static Map<String, String>? byokFor(String? setting, {ByokStore? store}) {
    final pick = (store ?? ByokStore.I).resolve(setting);
    return pick == null ? null : {'providerID': pick.provider.id, 'modelID': pick.model.id};
  }

  /// A turn on one of the user's own providers (not billed by SubMac, not stopped by the bots' share).
  static bool isByok(Map<String, String>? model) => model != null && (model['providerID'] ?? '').startsWith(ByokProvider.prefix);

  static bool isBackground(Map<String, String>? model) => model != null && bgSources.containsKey(model['providerID']);

  /// ai-chat's refusal of background work when the bots' share is used up (429 background_paused). opencode retries
  /// a 429 on its own, so it arrives as a retry status (or an error) carrying the server's message.
  static final _paused = RegExp(r'background_paused|background tasks are paused|paused until (tomorrow|midnight)', caseSensitive: false);
  static bool isPausedText(String? s) => s != null && _paused.hasMatch(s);

  /// ai-chat's refusal once the account's whole daily allowance is used up (foreground and background alike).
  static final _allowance = RegExp(r'allowance|done a lot today|refreshes tomorrow|resting until tomorrow', caseSensitive: false);
  static bool isAllowanceText(String? s) => s != null && _allowance.hasMatch(s);
}

/// Why a background opencode turn must stop now (owner 2026-11-03), checked as its events arrive. Pure, so tested
/// without the engine.
///  - `paused`: ai-chat refused it for the bots' share (opencode would retry the 429 until the turn timed out).
///  - `budget`: the bot's own daily token budget ran out mid-turn ([budgetLeft] tokens were left when it started).
class OcBgGuard {
  OcBgGuard({required this.background, this.budgetLeft, this.byok = false});
  final bool background;
  final int? budgetLeft;

  /// The turn runs on the user's own provider (BYOK, owner 2026-11-03): SubMac's bots' share does not apply to it.
  final bool byok;

  static const paused = 'paused', budget = 'budget';

  /// The account's whole daily allowance is used up: the owner's own chat stops too (it used to retry all evening).
  static const credit = 'credit';

  /// The provider keeps refusing (one call was retried 82 times with nothing to stop it).
  static const stuck = 'stuck';

  /// How long one turn may stay in opencode's own retry state before it is stopped.
  static const maxRetrySpan = Duration(minutes: 3);

  /// Tests: the clock.
  static DateTime Function() clock = DateTime.now;

  DateTime? _retrySince;

  /// Tokens a bot may still use today ([budgetK] thousand a day, 0 = no budget): null when it has no budget.
  static int? leftOf(int budgetK, int usedToday) {
    if (budgetK <= 0) return null;
    final left = budgetK * 1000 - usedToday;
    return left < 0 ? 0 : left;
  }

  String? check(OpenCodeTurn t) {
    // opencode retries a refused call on its own until the turn's 30 minutes run out (bug audit 2026-11-07):
    //  - the day's allowance is used up: the owner's chat said "retrying" all evening; stop now and say so.
    //  - the provider keeps failing: one call was retried 82 times; stop after [maxRetrySpan] in retry.
    if (!byok && !background && (OcLane.isAllowanceText(t.retry) || OcLane.isAllowanceText(t.error))) return credit;
    if (t.retry != null && t.retry!.isNotEmpty) {
      _retrySince ??= clock();
      if (clock().difference(_retrySince!) > maxRetrySpan) return stuck;
    } else {
      _retrySince = null;
    }
    if (!background) return null;
    if (!byok && (OcLane.isPausedText(t.retry) || OcLane.isPausedText(t.error))) return paused;
    final left = budgetLeft;
    if (left != null && t.tokens > 0 && t.tokens >= left) return budget;
    return null;
  }
}
