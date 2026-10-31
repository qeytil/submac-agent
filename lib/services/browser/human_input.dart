import 'dart:math';

/// Hands that look like a person's (P6).
///
/// Everything here is pure and seeded, so a test can pin it: the plans never drop, reorder or invent text;
/// a stroke always starts and ends exactly where the finger was told to; and a long drag goes a little past
/// the target and comes back — the small imperfections a hand has and a script does not.
///
/// The point a tap lands on is NOT decided here: the page script already picks a point that is verified to
/// hit the element and not something on top of it, and moving it would risk tapping an overlay instead.
/// What varies is the rhythm and the shape of the movement.
class HumanInput {
  HumanInput._();

  /// A deterministic generator: the same seed gives the same hands (tests pin it, the app uses the clock).
  static Random rng(int seed) => Random(seed == 0 ? DateTime.now().microsecondsSinceEpoch : seed);

  /// Is [u] the first half of a two-unit character (an emoji, a rare script)?
  static bool _highSurrogate(int u) => u >= 0xD800 && u <= 0xDBFF;

  /// Typing the way a keyboard app delivers it: bursts of 1-3 keys with a pause between them, a longer pause
  /// after a space or a comma, longer still after a full stop, and now and then a thought in the middle of a
  /// sentence. The chunks always join back to [text], character for character.
  ///
  /// Long text is not typed key by key — a 200-character address would take half a minute — so above 60
  /// characters the chunks get bigger and the pauses short.
  static List<({String chunk, int delayMs})> typing(String text, {int seed = 0}) {
    if (text.isEmpty) return const <({String chunk, int delayMs})>[];
    final r = rng(seed);
    final fast = text.length > 60;
    final out = <({String chunk, int delayMs})>[];
    var i = 0;
    while (i < text.length) {
      var n = 1 + r.nextInt(fast ? 8 : 3);
      if (i + n > text.length) n = text.length - i;
      // Never cut a character in half: an emoji is two code units and half of one types a broken glyph.
      if (i + n < text.length && _highSurrogate(text.codeUnitAt(i + n - 1))) n++;
      final chunk = text.substring(i, i + n);
      i += n;
      // The delay is the time before this chunk: reaching for the field, then the gaps between keys.
      var d = fast ? 10 + r.nextInt(18) : 32 + r.nextInt(74);
      final last = chunk[chunk.length - 1];
      if (last == ' ') {
        d += 28 + r.nextInt(70);
      } else if (last == ',' || last == ';' || last == ':' || last == '-') {
        d += 55 + r.nextInt(90);
      } else if (last == '.' || last == '!' || last == '?') {
        d += 100 + r.nextInt(150);
      }
      // One in twelve: a person stops to think mid-sentence.
      if (!fast && r.nextInt(12) == 0) d += 140 + r.nextInt(240);
      out.add((chunk: chunk, delayMs: d));
    }
    return out;
  }

  /// The whole typing time of [text] in milliseconds (what a caller should budget before giving up).
  static int typingMs(String text, {int seed = 0}) =>
      typing(text, seed: seed).fold<int>(0, (sum, p) => sum + p.delayMs);

  /// The path of a finger from one point to another (fractions of the visible page).
  ///
  /// - the line bows to one side (a thumb does not travel in a straight line),
  /// - micro-jitter on every point, fading to nothing at both ends so the finger still lands where it should,
  /// - on a long drag, a small overshoot that comes back — the classic human correction.
  static List<({double x, double y})> stroke(double x1, double y1, double x2, double y2, {int seed = 0, int points = 14}) {
    final r = rng(seed);
    final n = points < 4 ? 4 : points;
    final dx = x2 - x1, dy = y2 - y1;
    final dist = sqrt(dx * dx + dy * dy);
    final nx = dist == 0 ? 0.0 : -dy / dist;
    final ny = dist == 0 ? 0.0 : dx / dist;
    // Sideways bow: 2-6% of the distance, either side.
    final bow = dist * (0.02 + r.nextDouble() * 0.04) * (r.nextBool() ? 1 : -1);
    // A real drag (a quarter of the screen or more) overshoots by 2-4% and comes back.
    final over = dist >= 0.25 ? dist * (0.02 + r.nextDouble() * 0.02) : 0.0;
    const jitter = 0.0035; // ~1.4 px on a 400 px wide phone
    final pts = <({double x, double y})>[];
    for (var k = 0; k <= n; k++) {
      final f = k / n;
      // Ease in and out, like a finger starting and stopping.
      final e = f * f * (3 - 2 * f);
      var px = x1 + dx * e, py = y1 + dy * e;
      // The bow is widest in the middle and zero at both ends.
      final b = bow * sin(pi * f);
      px += nx * b;
      py += ny * b;
      // Overshoot: past the target in the last third, back exactly on it at the end.
      if (over > 0 && f > 0.7) {
        final o = over * sin(pi * (f - 0.7) / 0.3);
        px += (dx / (dist == 0 ? 1 : dist)) * o;
        py += (dy / (dist == 0 ? 1 : dist)) * o;
      }
      // Jitter, gone at both ends so the start and the end are exact.
      final fade = sin(pi * f);
      px += jitter * (r.nextDouble() * 2 - 1) * fade;
      py += jitter * (r.nextDouble() * 2 - 1) * fade;
      pts.add((x: px.clamp(0.0, 1.0).toDouble(), y: py.clamp(0.0, 1.0).toDouble()));
    }
    // Exact ends: the first touch must hit the element, the last must land on the target.
    pts[0] = (x: x1, y: y1);
    pts[n] = (x: x2, y: y2);
    return pts;
  }

  /// How long a finger rests on the screen for a tap: 42-79 ms, never the same twice.
  static int tapHoldMs({int seed = 0}) => 42 + rng(seed).nextInt(38);

  /// The distance between two points, in fractions of the page.
  static double distance(double x1, double y1, double x2, double y2) => sqrt((x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1));

  /// How long a long-press rests: 620-780 ms (below the usual 800 ms threshold that starts a context menu).
  static int longPressMs({int seed = 0}) => 620 + rng(seed).nextInt(160);

  /// A swipe's duration for a given distance: short flicks are quick, long drags take longer, and neither is
  /// the same twice. 180-420 ms.
  static int swipeMs(double distance, {int seed = 0}) {
    final r = rng(seed);
    final base = 150 + (distance.clamp(0.0, 1.0) * 420).round();
    return (base + r.nextInt(70)).clamp(180, 620).toInt();
  }
}
