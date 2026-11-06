import 'dart:async';

/// The app's time limits for a model call (PLAN 1.3, App row). The server always finishes first: it answers or sends
/// a clear `error` event within 25 s, so these only catch a dead line or a phone that lost its connection.
///
///  headers         10 s  for the response headers (the server sends 200 + `: ping` at once)
///  silence         30 s  with no byte at all (the server pings every 10 s, so this is a dropped line)
///  auto-retry       1    one quiet retry, only before any output was shown
///  continue         2    "continue" after a drop, at most twice per step
///  first word      45 s  with no word: stop and show "SubMac is busy. Tap to try again." (the message is kept)
class StreamPolicy {
  static Duration headers = const Duration(seconds: 10);
  static Duration silence = const Duration(seconds: 30);
  static Duration firstWord = const Duration(seconds: 45);
  static const autoRetries = 1;
  static const dropContinues = 2;

  /// Shown on the reply when nothing came back in time. The user's message stays; tapping retries.
  static const busyText = 'Telesia is busy. Tap to try again.';

  /// The longest the app waits before its one retry (the server's Retry-After is 15–30 s, but the 45 s first-word
  /// limit is the real bound: a retry that cannot start in time is pointless).
  static const maxRetryWait = Duration(seconds: 20);

  /// One quiet retry before any output, for a failure that may pass (busy, a dropped line, a server hiccup).
  static bool retryBeforeOutput({required int retriesDone, required bool gotOutput, required bool retryable}) =>
      !gotOutput && retryable && retriesDone < autoRetries;

  /// How long to wait before that retry: the server's Retry-After when it fits in what is left of the first-word
  /// budget, else a short pause. Null = no time left for a retry.
  static Duration? retryWait({Duration? retryAfter, required Duration elapsed}) {
    final left = firstWord - elapsed - const Duration(seconds: 3);
    if (left <= Duration.zero) return null;
    var w = retryAfter ?? const Duration(seconds: 2);
    if (w > maxRetryWait) w = maxRetryWait;
    if (w > left) return null;
    return w;
  }

  /// A reply that dropped mid-way is dropped and its step sent again, at most [dropContinues] times in a row.
  static bool canReissueAfterDrop(int dropsInRow) => dropsInRow < dropContinues;

  /// Contract A error codes and how the app treats them.
  static const finalCodes = {'limit_daily', 'limit_total', 'no_plan', 'blocked'};
  static const retryCodes = {'busy', 'server'};

  /// The HTTP-like status the app files a Contract A code under (so the old checks keep working).
  static int statusFor(String code) => switch (code) {
        'busy' => 503,
        'too_long' => 413,
        'limit_daily' || 'limit_total' || 'no_plan' => 429,
        'blocked' => 403,
        _ => 500,
      };

  /// Fixed, friendly words per code, used when the server sends none (never raw provider text).
  static String textFor(String code) => switch (code) {
        'busy' => 'Telesia is busy right now. Please try again in a moment.',
        'too_long' => 'This is too long to send in one go. Start a new chat or send less at once.',
        'limit_daily' => 'You\'ve used today\'s replies. They reset at midnight.',
        'limit_total' => 'You\'ve used all the replies in your plan.',
        'no_plan' => 'Get a plan to keep going.',
        'blocked' => 'Your account needs attention. Please contact support.',
        _ => 'Something went wrong on our side. Please try again.',
      };
}

/// Watches one step for its first word. [start] it when the step begins; [heard] when anything arrives (a word or a
/// tool call). If nothing came within [StreamPolicy.firstWord], [onLate] runs once (it stops the request).
class FirstWordWatch {
  FirstWordWatch(this.onLate, {Duration? limit}) : limit = limit ?? StreamPolicy.firstWord;
  final void Function() onLate;
  final Duration limit;
  Timer? _t;
  bool _heard = false;
  bool _fired = false;
  final Stopwatch _sw = Stopwatch();

  bool get fired => _fired;
  bool get gotWord => _heard;
  Duration get elapsed => _sw.elapsed;

  void start() {
    _sw.start();
    _t ??= Timer(limit, () {
      if (_heard) return;
      _fired = true;
      onLate();
    });
  }

  void heard() {
    _heard = true;
    _t?.cancel();
  }

  void stop() {
    _t?.cancel();
    _sw.stop();
  }
}
