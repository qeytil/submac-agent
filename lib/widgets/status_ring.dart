import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/bot_status.dart';
import '../theme.dart';
import '../ui/tokens.dart';

/// A thin ring around a head (owner, 2026-10-24): always there, its colour says the state. Green while working,
/// yellow while waiting for the owner's OK, blue when finished with unread results, grey when idle. No dots.
///
/// Only the working ring moves: a brighter arc travels slowly around it. The arc turns with a transform (no repaint
/// of the face, no layout), in its own RepaintBoundary, and only while working; under reduced motion the ring stands
/// still. Colour changes cross-fade on SubMac's settle curve.
class StatusRing extends StatefulWidget {
  const StatusRing({super.key, required this.state, required this.size, required this.child});

  final RingState state;

  /// The face's size; the ring sits just outside it.
  final double size;
  final Widget child;

  /// The ring's stroke and the gap between the ring and the face. Tiny (owner 2026-10-24: "smaller and tiny so the
  /// screen isn't noisy"): a hairline that still reads as green / yellow / blue / grey.
  static const double stroke = 1.25;
  static const double gap = 1.25;

  /// Idle is the quiet state: its ring is only a faint trace, so a rail of idle heads stays calm.
  static const double idleOpacity = 0.45;

  /// The whole box: the face plus the ring around it.
  static double outer(double size) => size + (stroke + gap) * 2;

  static Color colorFor(Palette p, RingState s) => switch (s) {
        RingState.working => p.statusWorking,
        RingState.waiting => p.statusWaiting,
        RingState.done => p.statusDone,
        RingState.idle => p.statusIdle,
      };

  @override
  State<StatusRing> createState() => _StatusRingState();
}

class _StatusRingState extends State<StatusRing> with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(vsync: this, duration: SubMotion.breath);

  bool get _moving => widget.state == RingState.working && !SubMotion.still(context);

  void _sync() {
    if (_moving) {
      if (!_spin.isAnimating) _spin.repeat();
    } else if (_spin.isAnimating || _spin.value != 0) {
      _spin.stop();
      _spin.value = 0;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(StatusRing old) {
    super.didUpdateWidget(old);
    if (old.state != widget.state) _sync();
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final box = StatusRing.outer(widget.size);
    final target = StatusRing.colorFor(p, widget.state);
    final working = widget.state == RingState.working;
    return SizedBox.square(
      dimension: box,
      child: Stack(alignment: Alignment.center, children: [
        Positioned.fill(
          child: RepaintBoundary(
            child: TweenAnimationBuilder<Color?>(
              tween: ColorTween(end: target),
              duration: SubMotion.of(context, LuxMotion.base),
              curve: LuxMotion.ease,
              builder: (context, c, _) {
                final color = c ?? target;
                final ring = CustomPaint(painter: _RingPainter(color: color, arc: working, idle: widget.state == RingState.idle));
                return working ? RotationTransition(turns: _spin, child: ring) : ring;
              },
            ),
          ),
        ),
        SizedBox.square(dimension: widget.size, child: Center(child: widget.child)),
      ]),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.color, required this.arc, this.idle = false});
  final Color color;
  final bool idle;

  /// Working: a soft full ring with a brighter arc on it (the arc is what turns).
  final bool arc;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Rect.fromLTWH(StatusRing.stroke / 2, StatusRing.stroke / 2, size.width - StatusRing.stroke, size.height - StatusRing.stroke);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = StatusRing.stroke
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;
    if (!arc) {
      canvas.drawOval(r, paint..color = idle ? color.withValues(alpha: color.a * StatusRing.idleOpacity) : color);
      return;
    }
    canvas.drawOval(r, paint..color = color.withValues(alpha: 0.38));
    canvas.drawArc(r, -math.pi / 2, math.pi * 0.6, false, paint..color = color);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.color != color || old.arc != arc || old.idle != idle;
}
