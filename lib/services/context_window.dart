/// How much Telesia can read at once (its context window), in tokens. Backend only: used to fold the older part
/// of a long chat into a summary before it stops fitting.
///
/// One model (`telesia`), so there is no per-model table any more. The server says how big the window is on every
/// reply (`x-telesia-window`, the smallest healthy route's window, PLAN 1.6); until it has, the app assumes the
/// 128k every route must have (PLAN 1.1 model checks).
///
/// CB-23: a request that carried pictures or tools is answered by fewer routes, so its header can name a bigger window
/// than plain text has (a photo turn reported 1M). Such a reading may lower the window but never raise it, and the
/// window is the smallest reading of the last [keep], so one odd reply cannot make every request overflow.
class ContextWindow {
  /// Every route behind `telesia` has at least this much (PLAN 1.1).
  static const int fallback = 128000;

  /// Never trust a reading outside this range (a broken header must not make every request compact or overflow).
  static const int min = 16000, max = 1000000;

  /// How long a smaller reading holds the window down (CB-23).
  static const Duration keep = Duration(minutes: 10);

  static int _tokens = fallback;
  static final List<(DateTime, int)> _seen = [];

  /// The current window in tokens.
  static int get tokens => _tokens;

  /// Reads `x-telesia-window` from a server reply. Returns true when the window changed.
  /// [filtered]: the request carried pictures or tools, so the server chose among fewer routes (CB-23).
  static bool note(String? header, {bool filtered = false, DateTime? now}) {
    final n = int.tryParse((header ?? '').trim());
    if (n == null || n <= 0) return false;
    final v = n < min ? min : (n > max ? max : n);
    if (filtered && v > _tokens) return false;
    final t = now ?? DateTime.now();
    _seen.add((t, v));
    // Drop readings older than [keep], but always keep the newest one.
    while (_seen.length > 1 && t.difference(_seen.first.$1) > keep) {
      _seen.removeAt(0);
    }
    var low = _seen.first.$2;
    for (final s in _seen) {
      if (s.$2 < low) low = s.$2;
    }
    if (low == _tokens) return false;
    _tokens = low;
    return true;
  }

  /// Back to the default (tests, sign-out).
  static void reset() {
    _tokens = fallback;
    _seen.clear();
  }

  /// True when an OpenAI-style message list carries a picture (`image_url` part).
  static bool hasImages(List<Map<String, dynamic>> messages) {
    for (final m in messages) {
      final c = m['content'];
      if (c is List && c.any((p) => p is Map && p['type'] == 'image_url')) return true;
    }
    return false;
  }

  /// The share of the window a request may fill before the chat is compacted (leaves room for the reply).
  static int compactAt() => compactAtFor(_tokens);

  /// The same rule for any window (pure: unit tested, and used by a caller that knows its own window).
  static int compactAtFor(int window) {
    final w = window <= 0 ? fallback : window;
    final reply = w ~/ 10 > 8000 ? 8000 : w ~/ 10;
    final at = (w * 0.75).floor();
    return at > w - reply ? w - reply : at;
  }
}
