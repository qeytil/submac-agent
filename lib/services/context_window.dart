/// How much SubMac can read at once (its context window), in tokens. Backend only: used to fold the older part
/// of a long chat into a summary before it stops fitting.
///
/// One model (`submac`), so there is no per-model table any more. The server says how big the window is on every
/// reply (`x-submac-window`, the smallest healthy route's window, PLAN 1.6); until it has, the app assumes the
/// 128k every route must have (PLAN 1.1 model checks).
class ContextWindow {
  /// Every route behind `submac` has at least this much (PLAN 1.1).
  static const int fallback = 128000;

  /// Never trust a reading outside this range (a broken header must not make every request compact or overflow).
  static const int min = 16000, max = 1000000;

  static int _tokens = fallback;

  /// The current window in tokens.
  static int get tokens => _tokens;

  /// Reads `x-submac-window` from a server reply. Returns true when the window changed.
  static bool note(String? header) {
    final n = int.tryParse((header ?? '').trim());
    if (n == null || n <= 0) return false;
    final v = n < min ? min : (n > max ? max : n);
    if (v == _tokens) return false;
    _tokens = v;
    return true;
  }

  /// Back to the default (tests, sign-out).
  static void reset() => _tokens = fallback;

  /// The share of the window a request may fill before the chat is compacted (leaves room for the reply).
  static int compactAt() {
    final w = _tokens;
    final reply = w ~/ 10 > 8000 ? 8000 : w ~/ 10;
    final at = (w * 0.75).floor();
    return at > w - reply ? w - reply : at;
  }
}
