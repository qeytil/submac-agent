import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../theme.dart';

/// What a bot is doing right now. The face shows it, so nothing else in the UI has to.
enum BotMood { idle, listening, thinking, speaking }

/// The bot's face: the same calm monochrome disc as always, now alive — it breathes, it blinks,
/// and it reacts to [mood].
///
/// Phase 1 is pure Flutter: no asset, no art pipeline, one [Ticker] per face. Phase 2 swaps the
/// painted face for a Rive file per archetype; this API does not change.
///
/// [seed] is the bot id: the blink is randomised per seed, so a list of faces never blinks in
/// unison. [dim] is the quiet palette (a bot that is not working). [streamedChars] drives the
/// speaking bars' amplitude — 0 when nothing is streaming.
class BotFace extends StatefulWidget {
  const BotFace({
    super.key,
    this.mood = BotMood.idle,
    this.seed = '',
    this.size = 44,
    this.dim = false,
    this.streamedChars = 0,
  });

  final BotMood mood;
  final String seed;
  final double size;
  final bool dim;
  final int streamedChars;

  @override
  State<BotFace> createState() => _BotFaceState();
}

class _BotFaceState extends State<BotFace> with TickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onTick);
  double _t = 0;
  bool _still = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // A user who switched animations off gets a still face, never a busy one.
    final still = MediaQuery.of(context).disableAnimations;
    if (still != _still) {
      _still = still;
      _t = 0;
      if (still) {
        _ticker.stop();
      } else if (!_ticker.isActive) {
        _ticker.start();
      }
    }
  }

  void _onTick(Duration elapsed) {
    if (mounted) setState(() => _t = elapsed.inMilliseconds / 1000.0);
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: CustomPaint(
        painter: _FacePainter(
          mood: widget.mood,
          seed: widget.seed,
          t: _t,
          dim: widget.dim,
          streamedChars: widget.streamedChars,
          disc: widget.dim ? p.bubble : p.text,
          border: p.border,
          line: widget.dim ? p.muted : p.bg,
          ring: p.ok,
        ),
      ),
    );
  }
}

/// Every motion is a pure function of elapsed seconds, so one clock drives all four moods.
class _FacePainter extends CustomPainter {
  _FacePainter({
    required this.mood,
    required this.seed,
    required this.t,
    required this.dim,
    required this.streamedChars,
    required this.disc,
    required this.border,
    required this.line,
    required this.ring,
  });

  final BotMood mood;
  final String seed;
  final double t;
  final bool dim;
  final int streamedChars;
  final Color disc;
  final Color border;
  final Color line;
  final Color ring;

  /// The blink: a 90 ms dip every 4-7 s, timed by the seed so a list never blinks in unison.
  /// 1 = open, 0 = shut.
  double get _lid {
    final h = (seed.hashCode & 0x3fffffff) / 0x3fffffff;
    final period = 4.0 + h * 3.0;
    final phase = (t + h * period) % period;
    if (phase > 0.09) return 1;
    final k = phase / 0.045; // 0..2 across the 90 ms
    return 1 - (1 - (k - 1).abs());
  }

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2;
    final pad = size.width * 0.04 + 0.8; // breathing room, so the breath never clips
    final dr = r - pad;
    final c = Offset(r, r);

    canvas.save();
    // Breathing: 1.00 -> 1.02, 3.2 s, ease-in-out (a sine is its own ease).
    canvas.translate(c.dx, c.dy);
    canvas.scale(1 + 0.02 * math.sin(2 * math.pi * t / 3.2));
    canvas.translate(-c.dx, -c.dy);

    // The disc itself — the one the app has always drawn.
    canvas.drawCircle(c, dr, Paint()
      ..color = disc
      ..style = PaintingStyle.fill);
    // No outline (UI rules): the disc's own tone is enough.

    switch (mood) {
      case BotMood.idle:
        _eyes(canvas, c, size);
      case BotMood.listening:
        _ring(canvas, c, dr);
        _eyes(canvas, c, size);
      case BotMood.thinking:
        _orbit(canvas, c, size);
      case BotMood.speaking:
        _eyes(canvas, c, size);
        _bars(canvas, c, size);
    }
    canvas.restore();
  }

  void _eyes(Canvas canvas, Offset c, Size size) {
    final w = math.min(8.0, math.max(1.6, size.width * 0.09));
    final h = math.min(16.0, math.max(3.0, size.width * 0.16)) * _lid;
    if (h < 0.6) return; // mid-blink: the lid is shut
    final dx = size.width * 0.17;
    final paint = Paint()..color = line;
    for (final s in const [-1, 1]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: c + Offset(s * dx, -size.width * 0.04), width: w, height: h),
          Radius.circular(w / 2),
        ),
        paint,
      );
    }
  }

  /// Listening used to draw a ring leaving the disc; it is gone (no rings).
  void _ring(Canvas canvas, Offset c, double dr) {
    // UI rules (2026-10-23): no rings around a face. Listening shows in the eyes and the breathing alone.
  }

  /// Three dots on a slow orbit, each a fifth of a beat behind the one before it.
  void _orbit(Canvas canvas, Offset c, Size size) {
    final rad = size.width * 0.27;
    final dot = math.min(3.0, math.max(1.6, size.width * 0.035));
    for (var i = 0; i < 3; i++) {
      final a = 2 * math.pi * ((t - i * 0.2) / 1.4);
      canvas.drawCircle(
        c + Offset(math.cos(a) * rad, math.sin(a) * rad),
        dot,
        Paint()..color = line.withValues(alpha: i == 0 ? 1.0 : 0.55),
      );
    }
  }

  /// Five bars that dance with the stream: 120 ms step, amplitude from the streamed characters.
  void _bars(Canvas canvas, Offset c, Size size) {
    final w = math.min(3.2, math.max(1.8, size.width * 0.03));
    final maxH = size.width * 0.20;
    final amp = 0.4 + (streamedChars % 5) / 5;
    final paint = Paint()..color = line;
    for (var k = 0; k < 5; k++) {
      final h = maxH * amp * (0.30 + 0.70 * math.sin(2 * math.pi * (t / 0.12) + k * 0.9).abs());
      final x = c.dx + (k - 2) * w * 1.7;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(x, c.dy + size.width * 0.16), width: w, height: math.max(1.0, h)),
          Radius.circular(w / 2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_FacePainter old) =>
      old.t != t ||
      old.mood != mood ||
      old.dim != dim ||
      old.seed != seed ||
      old.streamedChars != streamedChars ||
      old.disc != disc ||
      old.border != border ||
      old.line != line ||
      old.ring != ring;
}
