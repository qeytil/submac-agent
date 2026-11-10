/// How long a model's reply may be, and what happens when a reply still runs out of room (owner 2026-11-06: "something
/// limits the maximum output tokens for the main agent and the bots — replies get cut short").
///
/// What cut replies short before this (docs/max-output.md has the full list):
///  - opencode asks for `min(limit.output, OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX or 32,000)` output tokens. Telesia's
///    own models had no `limit`, so every Telesia turn asked for 32,000, and no model could go past 32,000 at all.
///  - The user's own providers (BYOK) without a listed output limit (OpenAI's list has none, most OpenAI-compatible
///    servers neither) were written with 8,192.
///  - opencode ends a turn quietly when the model stops for length (`finish: "length"`): the reply simply stopped
///    mid-sentence. ai-chat also ends a reply it cut itself with `finish_reason: "length"`.
///  - Plain one-answer calls (a team's combined answer, a bot asked by another bot) had 1,200 to 2,000 tokens and
///    ignored a length stop.
///
/// Now each model asks for its real maximum (the provider's own figure when it gave one, else the model family's
/// known maximum, else [fallback]); Telesia's models ask for [telesia] and the server clamps that to what the route it
/// picks can really do (its alias maximum, the model's window, the reply cap). A reply that still stops for length is
/// continued ([ReplyContinuation]) instead of left cut.
class OutputLimits {
  OutputLimits._();

  /// What an opencode turn on Telesia's own models asks for. ai-chat takes `min(asked, alias max_output_tokens)` and
  /// clamps it further per route, so asking for more than a route can do is safe; asking for less was the cap.
  static const telesia = 65536;

  /// An unknown model of the user's own provider: big enough for a long answer or a whole file, small enough that
  /// most servers accept it. (opencode's own default is 32,000, which some small servers refuse.)
  static const fallback = 16384;

  /// A free-text answer from a plain one-answer call (no tools): a team's combined answer, a bot's expert view.
  static const answer = 16384;

  /// A small structured answer that must not be cut (a plan or a bot's description as JSON).
  static const structured = 4096;

  /// The most any model is asked for (opencode's ceiling, OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX).
  static const ceiling = 131072;

  /// Known output maximums by model family (checked in order; the first match wins). Only families whose published
  /// maximum is clear; anything else uses the provider's figure or [fallback].
  static final List<(RegExp, int)> families = [
    (RegExp(r'claude-3-haiku|claude-3-opus|claude-3-sonnet'), 4096),
    (RegExp(r'claude-3[-.]5'), 8192),
    (RegExp(r'claude-opus-4([-.][01])?(-\d{8})?$|claude-4-opus'), 32000),
    (RegExp(r'claude-3[-.]7|claude-(sonnet|haiku|opus)-4|claude-4|claude-(sonnet|opus|haiku)-[5-9]'), 64000),
    (RegExp(r'gpt-5[\w.-]*chat'), 16384),
    (RegExp(r'gpt-5|gpt-6'), 128000),
    (RegExp(r'\bo1-mini'), 65536),
    (RegExp(r'\bo1-preview'), 32768),
    (RegExp(r'\bo[134](-mini|-pro)?\b'), 100000),
    (RegExp(r'gpt-4\.1'), 32768),
    (RegExp(r'gpt-4o'), 16384),
    (RegExp(r'gpt-oss'), 32768),
    (RegExp(r'gemini-(1\.|2\.0)'), 8192),
    (RegExp(r'gemini'), 65536),
    (RegExp(r'deepseek-(reasoner|r1)'), 64000),
    (RegExp(r'deepseek-(chat|v3)'), 8192),
  ];

  /// The output limit to give a model: [known] (the provider's own figure) when it is a real number, else the
  /// family's maximum, else [fallback]. Never above [ceiling].
  static int forModel(String id, {int? known}) {
    if (known != null && known > 0) return known > ceiling ? ceiling : known;
    final n = id.toLowerCase();
    for (final (re, max) in families) {
      if (re.hasMatch(n)) return max;
    }
    return fallback;
  }

  /// opencode's ceiling for this engine (OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX): the largest limit any configured
  /// model has, so no model's own limit is cut by opencode's default of 32,000. Every model gets an explicit limit,
  /// so the ceiling never reaches a model without one.
  static int engineMax(Iterable<int> limits) {
    var m = telesia;
    for (final l in limits) {
      if (l > m) m = l;
    }
    return m > ceiling ? ceiling : m;
  }
}

/// A reply that stopped because it ran out of room (`finish_reason: "length"`, Anthropic's `max_tokens`, opencode's
/// `finish: "length"`) is continued: the model gets its own words back and is asked to go on from the exact point it
/// stopped, a few times at most. The pieces are joined as one answer.
class ReplyContinuation {
  ReplyContinuation._();

  /// How many times one reply is continued before it is left as it is (and the chat says it was cut).
  static const maxContinues = 3;

  /// Whether a finish reason means "out of room".
  static bool isCut(String? finish) => finish == 'length' || finish == 'max_tokens' || finish == 'max-tokens';

  /// What the model is told when its reply was cut.
  static const prompt = 'Your previous reply was cut off because it reached the output length limit. Continue exactly '
      'where it stopped: do not repeat anything already written, do not apologise or summarise, just go on from the '
      'last word. If you were in the middle of a tool call or writing a file, start that step again in smaller parts.';

  /// The note shown when a reply is still cut after [maxContinues] continuations.
  static const cutNote = 'This reply hit the model\'s length limit and may be incomplete. Say "continue" to get the rest.';

  /// The messages for the next piece of a plain (OpenAI-style) call: the original [messages], what the model wrote
  /// so far as its own turn, then the request to go on.
  static List<Map<String, dynamic>> messages(List<Map<String, dynamic>> messages, String soFar) => [
        ...messages,
        {'role': 'assistant', 'content': soFar},
        {'role': 'user', 'content': prompt},
      ];

  /// [soFar] and the next [piece] as one text. The piece is taken as written (the model continues mid-word or
  /// mid-sentence); only a piece that starts by repeating the tail of [soFar] has that overlap removed.
  static String join(String soFar, String piece) {
    if (soFar.isEmpty) return piece;
    if (piece.isEmpty) return soFar;
    final max = soFar.length < piece.length ? soFar.length : piece.length;
    for (var n = max > 400 ? 400 : max; n >= 24; n--) {
      if (soFar.endsWith(piece.substring(0, n))) return soFar + piece.substring(n);
    }
    return soFar + piece;
  }
}
