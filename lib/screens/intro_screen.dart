import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../services/intro_sound.dart';
import '../theme.dart';
import '../ui/i18n.dart';
import '../ui/intro_motion.dart';
import '../ui/motion.dart';

/// The first-launch intro (owner, 2026-10-26): on a clean white page the wordmark "SubMac" draws itself in behind a
/// thin brand-blue pen line, then resolves into the logo (it scales and fades in), and the white dot lands last.
/// A soft whoosh plays under the drawing and a warm two-note bloom as the logo lands, with light selection ticks as
/// the pen passes each letter and one soft impact when the dot touches down. About three seconds; a tap anywhere skips
/// it (sound and ticks stop at once). With Remove animations the finished logo simply fades in, with one light tick.
///
/// Pure Flutter: one AnimationController, every beat a fraction of it (IntroMotion).
class IntroScreen extends StatefulWidget {
  const IntroScreen({super.key, required this.onDone, this.sound});

  /// Called once, when the intro finishes or is skipped.
  final VoidCallback onDone;

  /// The sound to play; the device player by default. Tests pass a fake.
  final IntroSound? sound;

  @override
  State<IntroScreen> createState() => IntroScreenState();
}

class IntroScreenState extends State<IntroScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: IntroMotion.total);
  IntroSound? _sound;
  bool _started = false;
  bool _done = false;
  bool _still = false;
  int _nextTick = 0;
  bool _landed = false;
  late final List<double> _ticks = IntroMotion.ticks();

  /// True once the intro has finished or was skipped. For tests.
  bool get done => _done;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _still = SubMotion.still(context);
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed) _finish();
    });
    if (_still) {
      // Remove animations: the finished logo fades in quickly, one light tick, no sound.
      _c.duration = IntroMotion.still;
      unawaited(HapticFeedback.selectionClick());
    } else {
      _c.addListener(_beats);
      _sound = widget.sound ?? IntroSound.device();
      unawaited(_sound!.play().catchError((Object _) {})); // a sound that fails never stops the intro
    }
    _c.forward();
  }

  /// Haptics in step with the picture: a selection tick as the pen passes each letter, one soft impact as the dot lands.
  void _beats() {
    final t = _c.value;
    while (_nextTick < _ticks.length && t >= _ticks[_nextTick]) {
      _nextTick++;
      unawaited(HapticFeedback.selectionClick());
    }
    if (!_landed && t >= IntroMotion.dotLand) {
      _landed = true;
      unawaited(HapticFeedback.mediumImpact());
    }
  }

  /// Tap to skip: sound and ticks stop at once.
  void skip() {
    if (_done) return;
    _c.removeListener(_beats);
    _c.stop();
    unawaited(_sound?.stop().catchError((Object _) {}));
    _finish();
  }

  void _finish() {
    if (_done) return;
    _done = true;
    _c.removeListener(_beats);
    widget.onDone();
  }

  @override
  void dispose() {
    _c.removeListener(_beats);
    _c.dispose();
    // A finished intro lets the sound's short tail ring out; a skipped one has already stopped it.
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: tr('Skip intro'),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: skip,
        // Material gives the wordmark a proper text style (no debug underline) on the plain white page.
        child: Material(
          color: IntroMotion.paper,
          child: Center(
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: _c,
                builder: (context, _) => _still ? _stillFrame(_c.value) : _frame(_c.value),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _stillFrame(double t) => Opacity(
        opacity: IntroMotion.span(t, 0, 0.35),
        child: const IntroLogo(dot: 1),
      );

  Widget _frame(double t) {
    final draw = IntroMotion.span(t, IntroMotion.drawStart, IntroMotion.drawEnd);
    final wordOut = IntroMotion.easeInOut.transform(IntroMotion.span(t, IntroMotion.wordOutStart, IntroMotion.wordOutEnd));
    final logo = IntroMotion.easeOut.transform(IntroMotion.span(t, IntroMotion.logoStart, IntroMotion.logoEnd));
    final dot = IntroMotion.easeOut.transform(IntroMotion.span(t, IntroMotion.dotStart, IntroMotion.dotEnd));
    return Stack(
      alignment: Alignment.center,
      children: [
        if (wordOut < 1)
          Opacity(
            opacity: 1 - wordOut,
            child: Transform.scale(
              scale: 1 - 0.06 * wordOut,
              child: IntroWordmark(edge: IntroMotion.revealEdge(draw)),
            ),
          ),
        if (logo > 0)
          Opacity(
            opacity: logo,
            child: Transform.scale(scale: 0.82 + 0.18 * logo, child: IntroLogo(dot: dot)),
          ),
      ],
    );
  }
}

/// "SubMac" revealed left to right up to [edge] (0..1) through a soft mask, with a thin pen line riding the edge.
class IntroWordmark extends StatelessWidget {
  const IntroWordmark({super.key, required this.edge, this.pen = 1});
  final double edge;
  final double pen;

  @override
  Widget build(BuildContext context) {
    const soft = 0.08;
    // The mask runs a little past both ends so the first and last letters start and finish cleanly.
    final e = -soft + (1 + 2 * soft) * edge;
    return CustomPaint(
      foregroundPainter: _PenPainter(edge: e, opacity: edge <= 0 || edge >= 1 ? 0 : pen),
      child: ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (r) => LinearGradient(
          colors: const [IntroMotion.ink, IntroMotion.ink, IntroMotion.inkClear],
          stops: [0, (e - soft).clamp(0.0, 1.0), e.clamp(0.0, 1.0)],
        ).createShader(r),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Text(
            IntroMotion.word,
            textDirection: TextDirection.ltr,
            style: Brand.serif(size: IntroMotion.wordSize, color: IntroMotion.ink, height: 1.1),
          ),
        ),
      ),
    );
  }
}

class _PenPainter extends CustomPainter {
  _PenPainter({required this.edge, required this.opacity});
  final double edge;
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    if (opacity <= 0) return;
    final x = size.width * edge.clamp(0.0, 1.0);
    final paint = Paint()
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..color = IntroMotion.theme.withValues(alpha: opacity);
    canvas.drawLine(Offset(x, size.height * 0.16), Offset(x, size.height * 0.88), paint);
  }

  @override
  bool shouldRepaint(_PenPainter old) => old.edge != edge || old.opacity != opacity;
}

/// The new SubMac logo: the light-blue tile with its blue "S" (assets/intro/submac_tile.svg), and the white dot drawn
/// on top so it can land last. [dot] is the dot's arrival (0 = not there, 1 = landed).
class IntroLogo extends StatelessWidget {
  const IntroLogo({super.key, this.dot = 1, this.size = IntroMotion.tileSize});
  final double dot;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        foregroundPainter: _DotPainter(dot),
        child: SvgPicture.asset('assets/intro/submac_tile.svg', width: size, height: size),
      ),
    );
  }
}

class _DotPainter extends CustomPainter {
  _DotPainter(this.t);
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    if (t <= 0) return;
    final c = Offset(IntroMotion.dotCentre.dx * size.width, IntroMotion.dotCentre.dy * size.height);
    // Drops in from just above its place and grows to full size as it settles.
    final drop = (1 - t) * size.height * 0.08;
    final r = IntroMotion.dotRadius * size.width * math.min(1.0, 0.2 + 0.8 * t);
    canvas.drawCircle(c.translate(0, -drop), r, Paint()..color = IntroMotion.dot.withValues(alpha: t.clamp(0.0, 1.0)));
  }

  @override
  bool shouldRepaint(_DotPainter old) => old.t != t;
}
