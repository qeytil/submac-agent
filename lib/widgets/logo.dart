import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../theme.dart';

/// Telesia logo (owner 2026-11-11): a calm blue "T" and a white dot on a light-blue rounded tile.
/// Drawn from the vector master in assets/brand, so it stays sharp at every size.
/// [tile] false draws only the T and the dot, for places that already sit on their own surface.
class AppLogo extends StatelessWidget {
  final double size;
  final bool tile;
  const AppLogo({super.key, this.size = 32, this.tile = true});

  static const tileAsset = 'assets/brand/telesia_mark.svg';
  static const plainAsset = 'assets/brand/telesia_mark_plain.svg';

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Telesia',
      image: true,
      child: SvgPicture.asset(
        tile ? tileAsset : plainAsset,
        width: size,
        height: size,
        excludeFromSemantics: true,
      ),
    );
  }
}

/// Was the breathing dot. Now: a fine working ring when [animate] is true, nothing otherwise.
/// (No hidden ticker: the ring is the only motion, and it stands still with Remove animations.)
class RedDot extends StatelessWidget {
  final double size;
  final bool animate;
  const RedDot({super.key, this.size = 12, this.animate = false});

  @override
  Widget build(BuildContext context) {
    // No dots in the interface (they read as filler). Working shows a fine, quiet ring; still shows nothing.
    if (!animate) return const SizedBox.shrink();
    final s = size < 12 ? 12.0 : size;
    return SizedBox(
      width: s,
      height: s,
      // With Remove animations the ring stands still (and never keeps a test's pumpAndSettle waiting).
      child: CircularProgressIndicator(
        strokeWidth: 1.4,
        color: Palette.of(context).muted,
        value: (MediaQuery.maybeDisableAnimationsOf(context) ?? false) ? 0.7 : null,
      ),
    );
  }
}

/// The calm T of the mark (owner 2026-11-11): one rounded bar over one rounded stem, the same geometry as
/// assets/brand/telesia_mark.svg and the notification icon, so the mark is one shape everywhere.
class _CalmT extends CustomPainter {
  _CalmT({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final paint = Paint()..color = color;
    // The proportions of the vector master, in a 1024 box: bar 296..728 x 312..445, stem 462..595 x 312..744.
    final bar = RRect.fromRectAndRadius(
        Rect.fromLTWH(s * 0.289, s * 0.305, s * 0.422, s * 0.130), Radius.circular(s * 0.065));
    final stem = RRect.fromRectAndRadius(
        Rect.fromLTWH(s * 0.451, s * 0.305, s * 0.130, s * 0.422), Radius.circular(s * 0.065));
    canvas.drawRRect(bar, paint);
    canvas.drawRRect(stem, paint);
  }

  @override
  bool shouldRepaint(_CalmT old) => old.color != color;
}

/// What the agent is doing, shown through the brand mark.
enum MarkMode { idle, thinking, working, roaming }

/// The Telesia mark (the calm "T") as a living indicator. No dots (owner rule): motion is carried by the letter
/// and one fine line.
/// - idle: the T breathes slowly;
/// - thinking: the T glows softly while a fine ring opens out around it;
/// - working: a short fine arc turns around the T;
/// - roaming (browsing or using the phone): a longer arc sweeps around the T, a little faster.
class AgentMark extends StatefulWidget {
  const AgentMark({super.key, this.size = 28, this.mode = MarkMode.thinking});
  final double size;
  final MarkMode mode;

  @override
  State<AgentMark> createState() => _AgentMarkState();
}

class _AgentMarkState extends State<AgentMark> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: _period(widget.mode));

  static Duration _period(MarkMode m) => switch (m) {
        MarkMode.idle => const Duration(milliseconds: 3200),
        MarkMode.thinking => const Duration(milliseconds: 1600),
        MarkMode.working => const Duration(milliseconds: 1100),
        MarkMode.roaming => const Duration(milliseconds: 1800),
      };

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (still) {
      _c.stop();
      _c.value = 0.5;
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void didUpdateWidget(AgentMark old) {
    super.didUpdateWidget(old);
    if (old.mode != widget.mode) {
      _c.duration = _period(widget.mode);
      if (_c.isAnimating) _c.repeat();
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
    final s = widget.size;
    return SizedBox(
      width: s,
      height: s,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final t = _c.value;
          final wave = 0.5 - 0.5 * math.cos(2 * math.pi * t); // 0 to 1 and back
          final glow = switch (widget.mode) {
            MarkMode.idle => 0.78 + 0.22 * wave,
            MarkMode.thinking => 0.7 + 0.3 * wave,
            MarkMode.working => 1.0,
            MarkMode.roaming => 0.85 + 0.15 * wave,
          };
          return Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(child: CustomPaint(painter: _MarkLine(mode: widget.mode, t: t, color: p.text))),
              Positioned.fill(
                child: Opacity(
                  opacity: glow.clamp(0.0, 1.0),
                  child: CustomPaint(painter: _CalmT(color: p.text)),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// The one fine line around the mark: a ring that opens out (thinking) or an arc that turns (working, roaming).
class _MarkLine extends CustomPainter {
  _MarkLine({required this.mode, required this.t, required this.color});
  final MarkMode mode;
  final double t;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = (size.shortestSide / 28).clamp(1.0, 2.4).toDouble();
    switch (mode) {
      case MarkMode.idle:
        return;
      case MarkMode.thinking:
        paint.color = color.withValues(alpha: 0.45 * (1 - t));
        canvas.drawCircle(c, r * (0.75 + 0.35 * t), paint);
      case MarkMode.working:
        paint.color = color.withValues(alpha: 0.7);
        canvas.drawArc(Rect.fromCircle(center: c, radius: r * 0.98), 2 * math.pi * t - math.pi / 2, math.pi * 0.45, false, paint);
      case MarkMode.roaming:
        paint.color = color.withValues(alpha: 0.55);
        canvas.drawArc(Rect.fromCircle(center: c, radius: r * 0.98), 2 * math.pi * t - math.pi / 2, math.pi * 0.9, false, paint);
    }
  }

  @override
  bool shouldRepaint(_MarkLine old) => old.t != t || old.mode != mode || old.color != color;
}
