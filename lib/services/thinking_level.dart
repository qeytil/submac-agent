/// How hard the model should think before it answers (owner 2026-11-10): the quiet Thinking pill under the
/// composer, in the app's own words.
///
/// Auto leaves the choice to the model. Light and Deep ask for the low/high reasoning effort: opencode applies
/// that as one of its own model variants, and Telesia's own model takes it as the `x-telesia-effort` hint
/// (PLAN 1.5). Pure, so it is tested without the engine or the UI.
enum ThinkingLevel { auto, light, deep }

class Thinking {
  Thinking._();

  /// The levels, in the order the sheet shows them.
  static const all = [ThinkingLevel.auto, ThinkingLevel.light, ThinkingLevel.deep];

  /// The one word the pill shows for [level].
  static String word(ThinkingLevel level) => switch (level) {
        ThinkingLevel.auto => 'Auto',
        ThinkingLevel.light => 'Light',
        ThinkingLevel.deep => 'Deep',
      };

  /// What the server and the engine call [level] (null for Auto: no hint, the model decides).
  static String? effort(ThinkingLevel level) => switch (level) {
        ThinkingLevel.auto => null,
        ThinkingLevel.light => 'low',
        ThinkingLevel.deep => 'high',
      };

  /// The opencode model variant for [level] when the caller already knows the model's variants (tests, callers
  /// that hold the list).
  static String? variantFor(ThinkingLevel level) => effort(level);

  /// The effort names opencode uses, weakest first: a family may have fewer of them, or more.
  static const order = ['none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max'];

  static int _rank(String effort) {
    final i = order.indexOf(effort);
    return i < 0 ? order.length : i;
  }

  /// The reasoning variants one model really has, out of the engine's own `/provider` answer (pure). Empty when
  /// the model has none — it does not think, so there is nothing for the pill to change.
  static List<String> variantsIn(Object? body, String providerID, String modelID) {
    if (body is! Map) return const [];
    final all = body['all'] ?? body['providers'];
    if (all is! List) return const [];
    for (final p in all) {
      if (p is! Map || '${p['id']}' != providerID) continue;
      final models = p['models'];
      if (models is! Map) return const [];
      final m = models[modelID];
      if (m is! Map) return const [];
      final variants = m['variants'];
      if (variants is! Map) return const [];
      final names = [for (final k in variants.keys) '$k'];
      names.sort((a, b) => _rank(a).compareTo(_rank(b)));
      return names;
    }
    return const [];
  }

  /// The variant [level] should use out of [variants]: Light the weakest they have, Deep the strongest. Null when
  /// there is nothing to send (Auto, or a model that does not think).
  static String? pick(List<String> variants, ThinkingLevel level) => switch (level) {
        ThinkingLevel.auto => null,
        ThinkingLevel.light => variants.isEmpty ? null : variants.first,
        ThinkingLevel.deep => variants.isEmpty ? null : variants.last,
      };
}
