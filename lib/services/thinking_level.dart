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

  /// The opencode model variant for [level] (its variants carry the same names as the effort).
  static String? variantFor(ThinkingLevel level) => effort(level);
}
