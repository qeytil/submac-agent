import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme.dart';
import '../../ui/i18n.dart';
import '../../ui/tokens.dart';

/// What Telesia is doing. A compact activity row, distinct from message content.
enum ActivityKind { thinking, working, roaming }

/// The agent's activity indicator: a small, calm status mark and a short live label.
///
/// With [live] the mark breathes — one soft cosine breath per [SubMotion.breath], opacity only,
/// inside a RepaintBoundary so only the dot repaints: the word and the layout never move, and a
/// 120 Hz screen simply draws the same curve more often. It rests at [lowFor] under reduced
/// motion, and [live] is off except on the chat's live task line, so a loading word ("Opening")
/// never loops and never keeps a test's pumpAndSettle waiting.
class StatusWord extends StatefulWidget {
  const StatusWord(this.text,
      {super.key, this.kind = ActivityKind.thinking, this.style, this.color, this.live = false});
  final String text;

  /// Kept for callers that group thinking, work and device activity.
  final ActivityKind kind;
  final TextStyle? style;
  final Color? color;

  /// The mark breathes while a task line is up (Claude-style living progress).
  final bool live;

  /// Marker opacity stays restrained and consistent across activity kinds.
  static double lowFor(ActivityKind k) => switch (k) {
        ActivityKind.thinking => 0.55,
        ActivityKind.working => 0.78,
        ActivityKind.roaming => 0.68,
      };

  @override
  State<StatusWord> createState() => _StatusWordState();
}

class _StatusWordState extends State<StatusWord> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: SubMotion.breath);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(covariant StatusWord old) {
    super.didUpdateWidget(old);
    if (old.live != widget.live || old.kind != widget.kind) _sync();
  }

  void _sync() {
    if (!widget.live || SubMotion.still(context)) {
      _c.stop();
      _c.value = 0;
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final st = (widget.style ?? AppText.metaStyle)
        .copyWith(color: widget.color ?? widget.style?.color ?? p.muted, fontWeight: FontWeight.w500);
    // The status word in the app language ("Tidying the answer", "Picking up where it left off"...); the "· 2 more"
    // tail keeps its number.
    final at = widget.text.indexOf('  ·  ');
    final shown = at < 0 ? tr(widget.text) : '${tr(widget.text.substring(0, at))}${widget.text.substring(at)}';
    final low = StatusWord.lowFor(widget.kind);
    return Semantics(
      liveRegion: true,
      label: shown,
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          RepaintBoundary(
            child: AnimatedBuilder(
              animation: _c,
              builder: (context, _) {
                // Rest (no live mark, or Remove animations): the marker's quiet resting opacity.
                final rest = !widget.live || SubMotion.still(context);
                final w = rest ? 0.0 : 0.5 + 0.5 * math.cos(2 * math.pi * _c.value);
                return Container(
                  width: Lux.pulse,
                  height: Lux.pulse,
                  decoration:
                      BoxDecoration(color: p.muted.withValues(alpha: low + (0.95 - low) * w), shape: BoxShape.circle),
                );
              },
            ),
          ),
          // 8 (pulse) + 4 = the line's 12 px text inset: the live status and the finished
          // "Worked for ..." words start at one edge, so nothing moves when a task ends.
          const SizedBox(width: Space.x1),
          Flexible(child: InkText(shown, style: st)),
        ],
      ),
    );
  }
}
