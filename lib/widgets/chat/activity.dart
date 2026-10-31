import 'package:flutter/material.dart';

import '../../theme.dart';
import '../../ui/i18n.dart';
import '../../ui/tokens.dart';

/// What SubMac is doing. The words say it; the kind only sets how calmly the word breathes.
enum ActivityKind { thinking, working, roaming }

/// The agent's activity indicator (owner rule, 2026-10-31): one honest word for what the agent is
/// doing right now, set inside a quiet pill — the same "word with a whisper of tone" language as the
/// app's chips. No dots, icons or glyphs before it. The word settles in when it changes ([InkText])
/// and breathes gently while SubMac works ([Breath], opacity only). With reduced motion it simply
/// sits there, fully lit.
class StatusWord extends StatelessWidget {
  const StatusWord(this.text, {super.key, this.kind = ActivityKind.thinking, this.style, this.color});
  final String text;
  final ActivityKind kind;
  final TextStyle? style;
  final Color? color;

  /// How low the breath goes for each kind: thinking breathes deepest, working a little less.
  static double lowFor(ActivityKind k) => switch (k) {
        ActivityKind.thinking => 0.40,
        ActivityKind.working => 0.55,
        ActivityKind.roaming => 0.50,
      };

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final st = (style ?? AppText.metaStyle).copyWith(color: color ?? style?.color ?? p.muted, fontWeight: FontWeight.w500);
    // The status word in the app language ("Tidying the answer", "Picking up where it left off"…); the "· 2 more"
    // tail keeps its number.
    final at = text.indexOf('  ·  ');
    final shown = at < 0 ? tr(text) : '${tr(text.substring(0, at))}${text.substring(at)}';
    return Semantics(
      liveRegion: true,
      label: shown,
      excludeSemantics: true,
      child: Breath(
        low: lowFor(kind),
        child: Container(
          padding: const EdgeInsetsDirectional.fromSTEB(12, 5, 12, 5),
          decoration: ShapeDecoration(
            // The chip rule: a word with a whisper of tone, never an outline.
            color: p.text.withValues(alpha: 0.05),
            shape: const StadiumBorder(),
          ),
          child: InkText(shown, style: st),
        ),
      ),
    );
  }
}
