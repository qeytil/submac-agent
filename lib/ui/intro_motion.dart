import 'package:flutter/animation.dart';

/// The first-launch intro's timeling, curves and brand values (owner, 2026-10-26: "Animation drawing Telesia then our
/// logo with professional clean intro style", with a "smooth satisfying sound with haptic").
///
/// One controller runs for [total]; every beat is a fraction of it, so the picture, the haptic ticks and the sound
/// stay in step. Kept apart from SubMotion (lib/ui/motion.dart) because only the intro uses these values.
class IntroMotion {
  const IntroMotion._();

  /// The whole intro: the wordmark draws in, resolves into the logo, the dot lands, a short hold.
  static const Duration total = Duration(milliseconds: 3000);

  /// With Remove animations: the finished logo fades in and the intro ends.
  static const Duration still = Duration(milliseconds: 900);

  /// Intro to sign-in, and sign-in to chat: a fade with a slight scale.
  static const Duration handoff = Duration(milliseconds: 600);

  /// Ease in and out (the brief asks for ease-in-out curves throughout).
  static const Curve easeInOut = Cubic(0.42, 0.0, 0.58, 1.0);

  /// Ease out, for things coming to rest (the logo, the dot).
  static const Curve easeOut = Cubic(0.16, 1.0, 0.3, 1.0);

  // Beats, as fractions of [total] (ms in brackets).
  /// The wordmarx draws in (0 to 1500).
  static const double drawStart = 0.0, drawEnd = 0.5;

  /// The wordmark gives way (1500 to 1800).
  static const double wordOutStart = 0.5, wordOutEnd = 0.6;

  /// The logo scales and fades in as the word leaves (1800 to 2200), eliminating overlap with wordmark.
  static const double logoStart = 0.600, logoEnd = 0.733;

  /// The white dot lands last (2200 to 2450); the soft impact (and the sound's second note) as it touches down (2295).
  static const double dotStart = 0.733, dotEnd = 0.817, dotLand = 0.765;

  /// Selection ticks across the letter reveal: one as the reveal passes each letter of "Telesia" (6 at most).
  static const String word = 'Telesia';
  /// How far the reveal edge has travelled (0..1 across the word) at draw progress [d] (0..1).
  static double revealEdge(double d) => easeInOut.transform(d.clamp(0.0, 1.0));

  /// Draw progress needed for the reveal edge to reach [edge] (inverse of [revealEdge]), for the haptic ticks.
  static double drawFor(double edge) {
    var lo = 0.0, hi = 1.0;
    for (var i = 0; i < 30; i++) {
      final mid = (lo + hi) / 2;
      if (revealEdge(mid) < edge) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return (lo + hi) / 2;
  }

  /// The controller values at which a tick fires: as the reveal edge passes the middle of each letter.
  static List<double> ticks() => [
        for (var i = 0; i < word.length; i++) drawStart + (drawEnd - drawStart) * drawFor((i + 0.5) / word.length),
      ];

  /// Progress (0..1) of a beat running from [a] to [b] at controller value [t].
  static double span(double t, double a, double b) => ((t - a) / (b - a)).clamp(0.0, 1.0);

  // Brand (the new logo, telesia.site).
  static const Color paper = Color(0xFFFFFFFF);
  static const Color ink = Color(0xFF0A5BD3);
  static const Color inkClear = Color(0x000A5BD3);
  static const Color theme = Color(0xFF86C0F3);
  static const Color dot = Color(0xFFFFFFFF);

  /// The wordmark's size and the logo tile's size (logical pixels).
  static const double wordSize = 60;
  static const double tileSize = 112;

  /// The dot inside the 1024 logo: centre (752, 310), radius 62.
  static const Offset dotCentre = Offset(752 / 1024, 310 / 1024);
  static const double dotRadius = 62 / 1024;
}