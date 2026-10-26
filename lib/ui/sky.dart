import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../theme.dart';
import 'tokens.dart' show LuxMotion;

/// The live sky behind every screen (owner, 2026-10-26: "make an actual live sky with orange sunset and sunrise and
/// golden hour"). It is drawn, not pictures: a three-stop gradient from the zenith to the horizon, a soft sun (or moon)
/// glow that crosses the sky with the time, a few slow drifting glows of light, and faint stars at night.
///
/// Its colours come from [skyKeys], a day of keyframes on the phone's own clock, eased between neighbours so the sky
/// never jumps (it changes a little every minute):
/// night (deep indigo, stars) → blue hour (05:00–06:00) → pink then orange sunrise (06:00–07:00) → golden morning
/// (07:00–08:00) → clear blue day → golden afternoon (17:30–18:30) → orange and red sunset (18:30–19:30) → dusk →
/// night. The app's Auto look turns light at 07:00 and dark at 19:00, inside sunrise's and sunset's warm light, so
/// the switch happens when the sky itself is half lit.
@immutable
class SkyLook {
  const SkyLook({
    required this.top,
    required this.mid,
    required this.horizon,
    required this.glow,
    required this.glowStrength,
    required this.stars,
    required this.light,
  });

  /// The zenith, the middle of the sky and the horizon (top to bottom of the screen).
  final Color top, mid, horizon;

  /// The sun's (or moon's) glow colour and how strong it is (0..1).
  final Color glow;
  final double glowStrength;

  /// How much the stars show (0..1).
  final double stars;

  /// How lit the sky is (0 night .. 1 full day). Drives the veils that keep text readable.
  final double light;

  List<Color> get stops => [top, mid, horizon];

  static SkyLook lerp(SkyLook a, SkyLook b, double t) => SkyLook(
        top: Color.lerp(a.top, b.top, t)!,
        mid: Color.lerp(a.mid, b.mid, t)!,
        horizon: Color.lerp(a.horizon, b.horizon, t)!,
        glow: Color.lerp(a.glow, b.glow, t)!,
        glowStrength: lerpDouble(a.glowStrength, b.glowStrength, t)!,
        stars: lerpDouble(a.stars, b.stars, t)!,
        light: lerpDouble(a.light, b.light, t)!,
      );

  @override
  bool operator ==(Object o) =>
      o is SkyLook &&
      o.top == top &&
      o.mid == mid &&
      o.horizon == horizon &&
      o.glow == glow &&
      o.glowStrength == glowStrength &&
      o.stars == stars &&
      o.light == light;

  @override
  int get hashCode => Object.hash(top, mid, horizon, glow, glowStrength, stars, light);
}

/// The sky's phases, named for tests and for reading.
enum SkyPhase { night, blueHour, sunrise, goldenMorning, day, goldenEvening, sunset, dusk }

const _night = SkyLook(
  top: Color(0xFF060A1C),
  mid: Color(0xFF0C1433),
  horizon: Color(0xFF18214A),
  glow: Color(0xFF9FB4FF),
  glowStrength: 0.18,
  stars: 1,
  light: 0,
);
const _blueHour = SkyLook(
  top: Color(0xFF0E1842),
  mid: Color(0xFF233568),
  horizon: Color(0xFF475A8F),
  glow: Color(0xFFB7C4F0),
  glowStrength: 0.22,
  stars: 0.45,
  light: 0.15,
);
const _sunrisePink = SkyLook(
  top: Color(0xFF2A3C76),
  mid: Color(0xFFA66F92),
  horizon: Color(0xFFF2996E),
  glow: Color(0xFFFFB07A),
  glowStrength: 0.55,
  stars: 0.08,
  light: 0.38,
);
const _sunriseOrange = SkyLook(
  top: Color(0xFF4C74B4),
  mid: Color(0xFFEDA27C),
  horizon: Color(0xFFFFB866),
  glow: Color(0xFFFFC07A),
  glowStrength: 0.7,
  stars: 0,
  light: 0.6,
);
const _goldenMorning = SkyLook(
  top: Color(0xFF6CA0D8),
  mid: Color(0xFFBCD3EA),
  horizon: Color(0xFFFFDCA0),
  glow: Color(0xFFFFE2A8),
  glowStrength: 0.6,
  stars: 0,
  light: 0.85,
);
const _day = SkyLook(
  top: Color(0xFF4A8BD6),
  mid: Color(0xFF8CBBEA),
  horizon: Color(0xFFD4E7F7),
  glow: Color(0xFFFFFFFF),
  glowStrength: 0.45,
  stars: 0,
  light: 1,
);
const _goldenEvening = SkyLook(
  top: Color(0xFF5A8ECE),
  mid: Color(0xFFB9CBDE),
  horizon: Color(0xFFFFD592),
  glow: Color(0xFFFFD38A),
  glowStrength: 0.62,
  stars: 0,
  light: 0.85,
);
const _sunsetOrange = SkyLook(
  top: Color(0xFF3D5C9C),
  mid: Color(0xFFE2875C),
  horizon: Color(0xFFFF9447),
  glow: Color(0xFFFF8A45),
  glowStrength: 0.75,
  stars: 0,
  light: 0.55,
);
const _sunsetRed = SkyLook(
  top: Color(0xFF2A336E),
  mid: Color(0xFFB9536A),
  horizon: Color(0xFFEC6A46),
  glow: Color(0xFFFF6A3D),
  glowStrength: 0.6,
  stars: 0.05,
  light: 0.35,
);
const _dusk = SkyLook(
  top: Color(0xFF151A45),
  mid: Color(0xFF3F3466),
  horizon: Color(0xFF7E4868),
  glow: Color(0xFFC88AA8),
  glowStrength: 0.3,
  stars: 0.35,
  light: 0.14,
);

/// One day of keyframes: (minute of the day, look, phase it opens). Between two keyframes the look eases (smoothstep),
/// so colours never jump and never kink at a keyframe.
const List<(int, SkyLook, SkyPhase)> skyKeys = [
  (0, _night, SkyPhase.night),
  (4 * 60 + 45, _night, SkyPhase.night),
  (5 * 60 + 30, _blueHour, SkyPhase.blueHour),
  (6 * 60 + 15, _sunrisePink, SkyPhase.sunrise),
  (6 * 60 + 45, _sunriseOrange, SkyPhase.sunrise),
  (7 * 60 + 30, _goldenMorning, SkyPhase.goldenMorning),
  (8 * 60 + 30, _day, SkyPhase.day),
  (16 * 60 + 45, _day, SkyPhase.day),
  (18 * 60, _goldenEvening, SkyPhase.goldenEvening),
  (18 * 60 + 45, _sunsetOrange, SkyPhase.sunset),
  (19 * 60 + 10, _sunsetRed, SkyPhase.sunset),
  (19 * 60 + 45, _dusk, SkyPhase.dusk),
  (20 * 60 + 30, _night, SkyPhase.night),
  (24 * 60, _night, SkyPhase.night),
];

/// Minutes since local midnight, with seconds as a fraction.
double minuteOfDay(DateTime t) => t.hour * 60 + t.minute + t.second / 60 + t.millisecond / 60000;

double _ease(double x) => x * x * (3 - 2 * x);

/// The sky at local time [t].
SkyLook skyAt(DateTime t) => skyAtMinute(minuteOfDay(t));

SkyLook skyAtMinute(double m) {
  m = m % (24 * 60);
  for (var i = 0; i < skyKeys.length - 1; i++) {
    final (a, la, _) = skyKeys[i];
    final (b, lb, _) = skyKeys[i + 1];
    if (m >= a && m < b) return SkyLook.lerp(la, lb, _ease((m - a) / (b - a)));
  }
  return _night;
}

/// The named phase at local time [t] (the keyframe range it is in, by when each phase is at its fullest).
SkyPhase skyPhaseAt(DateTime t) {
  final h = minuteOfDay(t) / 60;
  if (h < 5) return SkyPhase.night;
  if (h < 6) return SkyPhase.blueHour;
  if (h < 7) return SkyPhase.sunrise;
  if (h < 8) return SkyPhase.goldenMorning;
  if (h < 17.5) return SkyPhase.day;
  if (h < 18.5) return SkyPhase.goldenEvening;
  if (h < 19.5) return SkyPhase.sunset;
  if (h < 20.5) return SkyPhase.dusk;
  return SkyPhase.night;
}

/// How dark the sky is at [t] (0 full day, 1 night): 1 minus [SkyLook.light].
double skyNightness(DateTime t) => 1 - skyAt(t).light;

/// Where the sun's glow sits at [t] as fractions of the screen (x 0..1 left to right, y 0..1 top to bottom), or null
/// while it is below the horizon. It rises low on the left around 06:15, is highest at midday and sets on the right
/// around 19:30.
Offset? sunPosition(DateTime t) {
  final h = minuteOfDay(t) / 60;
  const rise = 6.0, set = 19.75;
  if (h < rise || h > set) return null;
  final f = (h - rise) / (set - rise);
  return Offset(0.08 + 0.84 * f, 0.95 - 0.75 * math.sin(math.pi * f));
}

/// Where the moon's glow sits at night (the same arc, lower), or null by day.
Offset? moonPosition(DateTime t) {
  var h = minuteOfDay(t) / 60;
  if (h < 12) h += 24;
  const rise = 19.25, set = 30.5;
  if (h < rise || h > set) return null;
  final f = (h - rise) / (set - rise);
  return Offset(0.12 + 0.76 * f, 0.9 - 0.6 * math.sin(math.pi * f));
}

// ---------------------------------------------------------------- contrast

double _lum(Color c) {
  double ch(double v) => v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
}

/// WCAG contrast ratio of two opaque colours.
double contrastRatio(Color a, Color b) {
  final la = _lum(a), lb = _lum(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// The brightest (or darkest) things text may sit on in [look]: every gradient stop, each lit by the sun glow and by a
/// drifting light at their strongest.
List<Color> skySurfaces(SkyLook look) => [
      for (final c in look.stops) ...[
        c,
        Color.lerp(c, look.glow, look.glowStrength * 0.55)!,
        Color.lerp(c, Colors.white, _cloudAlpha(look))!,
      ],
    ];

double _cloudAlpha(SkyLook l) => 0.05 + 0.09 * l.light;

/// The least veil of [veil] colour over every surface of [look] that gives [text] [ratio]:1 contrast.
double veilFor(SkyLook look, Color text, Color veil, {double ratio = 4.6}) {
  var need = 0.0;
  for (final s in skySurfaces(look)) {
    if (contrastRatio(text, s) >= ratio) continue;
    var lo = 0.0, hi = 1.0;
    for (var i = 0; i < 16; i++) {
      final m = (lo + hi) / 2;
      if (contrastRatio(text, Color.lerp(s, veil, m)!) >= ratio) {
        hi = m;
      } else {
        lo = m;
      }
    }
    need = math.max(need, hi);
  }
  return need;
}

/// How much daylight paper lies over the sky in the light look at most (deep night), so its ink text stays readable.
const double lightNightVeil = 0.62;

/// How much night ink lies over the sky in the dark look at most (full day), so its white text stays readable.
const double darkDayVeil = 0.58;

/// The veil the light look lays over [look]: paper, enough for ink text and never less than the old night veil scaled
/// by how dark the sky is.
double lightVeilFor(SkyLook look) =>
    math.min(0.95, math.max(lightNightVeil * (1 - look.light), veilFor(look, Palette.light.text, Palette.light.bg)));

/// The veil the dark look lays over [look]: night ink, enough for white text, never less than the old day veil
/// scaled by how lit the sky is.
double darkVeilFor(SkyLook look) =>
    math.min(0.95, math.max(darkDayVeil * look.light, veilFor(look, Palette.dark.text, Palette.dark.bg)));

// ---------------------------------------------------------------- painter

class _Star {
  const _Star(this.x, this.y, this.r, this.speed, this.offset);
  final double x, y, r;
  final int speed;
  final double offset;
}

final List<_Star> _stars = () {
  final rnd = math.Random(20261026);
  return [
    for (var i = 0; i < 70; i++)
      _Star(rnd.nextDouble(), math.pow(rnd.nextDouble(), 1.4) * 0.78, 0.45 + rnd.nextDouble() * 0.85, 2 + rnd.nextInt(6), rnd.nextDouble() * 2 * math.pi),
  ];
}();

/// Paints the sky. It repaints only when [repaint] ticks (the drift step, every few seconds) or its look changes,
/// never every frame. [phase] is the slow drift's loop position (0..1).
class SkyPainter extends CustomPainter {
  SkyPainter({
    required this.from,
    required this.to,
    required this.fade,
    required this.phase,
    required this.sun,
    required this.moon,
    required this.still,
  }) : super(repaint: Listenable.merge([phase, fade]));

  final SkyLook from, to;
  final Animation<double> fade;
  final ValueListenable<double> phase;
  final Offset? sun, moon;
  final bool still;

  /// How many times any sky has painted. For tests (the sky repaints a few times a minute, not every frame).
  static int paints = 0;

  @override
  void paint(Canvas canvas, Size size) {
    paints++;
    if (size.isEmpty) return;
    final look = fade.value >= 1 ? to : SkyLook.lerp(from, to, LuxMotion.skyEase.transform(fade.value));
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: look.stops,
          stops: const [0, 0.55, 1],
        ).createShader(rect),
    );
    final p = still ? 0.0 : phase.value;
    final a = p * 2 * math.pi;
    final big = math.max(size.width, size.height);

    // Stars: faint dots, gently twinkling (each on its own whole number of loops, so the drift loop is seamless).
    if (look.stars > 0.01) {
      final paint = Paint();
      for (var i = 0; i < _stars.length; i++) {
        final s = _stars[i];
        final tw = still ? 0.8 : 0.55 + 0.45 * math.sin(a * s.speed + s.offset);
        paint.color = Colors.white.withValues(alpha: (0.75 * look.stars * tw).clamp(0.0, 1.0));
        canvas.drawCircle(Offset(s.x * size.width, s.y * size.height), s.r, paint);
      }
    }

    // Drifting light: three wide, very soft glows sliding slowly across (one loop of the drift crosses the screen).
    final cloud = Color.lerp(look.mid, Colors.white, 0.35 + 0.4 * look.light)!;
    final ca = _cloudAlpha(look);
    for (var i = 0; i < 3; i++) {
      final x = ((0.15 + 0.37 * i + p * (i.isEven ? 1 : -1)) % 1.4) - 0.2;
      final y = 0.18 + 0.27 * i + 0.02 * math.sin(a + i);
      _glow(canvas, Offset(x * size.width, y * size.height), big * (0.42 + 0.06 * i), cloud.withValues(alpha: ca), squash: 0.45);
    }

    // The sun's warm glow (or the moon's pale one), where it is in the sky right now.
    if (sun != null) {
      final c = Offset(sun!.dx * size.width, sun!.dy * size.height);
      _glow(canvas, c, big * 0.75, look.glow.withValues(alpha: 0.55 * look.glowStrength));
      _glow(canvas, c, big * 0.16, look.glow.withValues(alpha: 0.6 * look.glowStrength));
    }
    if (moon != null && look.stars > 0.01) {
      final c = Offset(moon!.dx * size.width, moon!.dy * size.height);
      _glow(canvas, c, big * 0.5, const Color(0xFFB8C6FF).withValues(alpha: 0.16 * look.stars));
      _glow(canvas, c, big * 0.035, const Color(0xFFF2F4FF).withValues(alpha: 0.5 * look.stars));
    }
  }

  void _glow(Canvas canvas, Offset c, double r, Color color, {double squash = 1}) {
    if (color.a <= 0.003) return;
    canvas.save();
    canvas.translate(c.dx, c.dy);
    if (squash != 1) canvas.scale(1, squash);
    final rect = Rect.fromCircle(center: Offset.zero, radius: r);
    canvas.drawCircle(
      Offset.zero,
      r,
      Paint()..shader = RadialGradient(colors: [color, color.withValues(alpha: 0)]).createShader(rect),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(SkyPainter old) =>
      old.from != from || old.to != to || old.sun != sun || old.moon != moon || old.still != still || old.phase != phase || old.fade != fade;
}
