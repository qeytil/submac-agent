// CB-20 / CB-45: how the app counts and labels model usage, the same way the server bills it.

import 'llm_client.dart';

/// The weights the server bills with (`quotaOf` in ai-chat): uncached prompt × in, cached prompt × cached, output ×
/// out, rounded up per call. /status may send them; until it does the server's own defaults apply (0.3 / 0.1 / 1).
class UsageUnits {
  static const defaultIn = 0.3, defaultCached = 0.1, defaultOut = 1.0;
  static double wIn = defaultIn, wCached = defaultCached, wOut = defaultOut;

  /// Weights from a /status answer, when it has them (`weights: {input, cached, output}`, or the ai_settings names
  /// `input_weight` / `cached_weight` / `output_weight`, at the top or in `billing`). Anything missing keeps its default.
  static void noteStatus(Object? status) {
    if (status is! Map) return;
    Object? w = status['weights'];
    if (w is! Map && status['billing'] is Map) w = (status['billing'] as Map)['weights'];
    final src = w is Map ? w : (status['billing'] is Map ? status['billing'] as Map : status);
    double pick(List<String> keys, double d) {
      for (final k in keys) {
        final v = src[k];
        final n = v is num ? v.toDouble() : double.tryParse('${v ?? ''}');
        if (n != null && n.isFinite && n >= 0) return n;
      }
      return d;
    }

    wIn = pick(const ['input', 'in', 'input_weight'], defaultIn);
    wCached = pick(const ['cached', 'cache', 'cached_weight'], defaultCached);
    wOut = pick(const ['output', 'out', 'output_weight'], defaultOut);
  }

  static void resetWeights() {
    wIn = defaultIn;
    wCached = defaultCached;
    wOut = defaultOut;
  }

  /// The cached part of a provider's usage block (same fields the server reads).
  static int cachedOf(Object? usage) {
    if (usage is! Map) return 0;
    final details = usage['prompt_tokens_details'], inDetails = usage['input_tokens_details'];
    final candidates = [
      details is Map ? details['cached_tokens'] : null,
      inDetails is Map ? inDetails['cached_tokens'] : null,
      usage['cached_tokens'],
      usage['prompt_cache_hit_tokens'],
      usage['cachedContentTokenCount'],
      usage['cached_content_token_count'],
      usage['cache_read_input_tokens'],
    ];
    for (final c in candidates) {
      if (c is num && c.isFinite && c > 0) return c.floor();
    }
    return 0;
  }

  /// Billing units of one call. [fallback] (an estimate) is used only when the call has no prompt/output counts.
  static int of(int prompt, int output, {int cached = 0, int fallback = 0}) {
    final p = prompt < 0 ? 0 : prompt, c = output < 0 ? 0 : output;
    if (p == 0 && c == 0) return fallback < 0 ? 0 : fallback;
    final hit = cached < 0 ? 0 : (cached > p ? p : cached);
    return ((p - hit) * wIn + hit * wCached + c * wOut).ceil();
  }

  static int ofResult(LlmResult r) => of(r.tokensIn, r.tokensOut, cached: r.tokensCached, fallback: r.tokens);
}

/// The `x-submac-source` of a chat model call (CB-45). Only a bot's own work (a wake, an office job) is bot work;
/// what the owner types to a bot is `bot-chat`, billed to the owner's chat bucket (ai-chat v43, S-2).
class UsageSource {
  static const bot = 'bot', botChat = 'bot-chat', office = 'office', agent = 'agent', side = 'side';

  /// Set once a server refused `bot-chat` (an older ai-chat): owner chats with a bot then go as plain `agent`.
  static bool botChatRefused = false;

  static String pick({required bool officeJob, required bool botConv, required bool botWork, bool sideRun = false}) {
    if (officeJob) return office;
    if (botConv) return botWork ? bot : (botChatRefused ? agent : botChat);
    return sideRun ? side : agent;
  }

  /// Usage the server counts against the bots' share (billing.is_bot): the only usage a bot's daily budget counts.
  static bool isBotWork(String source) => source == bot || source == office || source == 'background' || source == 'bot-cloud';

  /// A 400 that says the source is unknown: retry this call as `agent` and remember it.
  static bool refusedBotChat(String source, LlmException e) {
    if (source != botChat || e.status != 400) return false;
    final s = '${e.code} ${e.message}'.toLowerCase();
    return s.contains('source');
  }
}
