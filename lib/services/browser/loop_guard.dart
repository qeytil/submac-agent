import 'dart:async';

/// One finished browser action, as the loop guard remembers it.
class StepTrace {
  StepTrace({required this.action, required this.page, required this.url, required this.changed, required this.failed});

  /// Tool name + normalised arguments.
  final String action;

  /// The page fingerprint after the step.
  final String page;
  final String url;

  /// The step changed something on the page (verified by before/after state and screenshot).
  final bool changed;
  final bool failed;
}

/// What the guard tells the loop to do.
enum GuardVerdict { ok, nudge, replan, stop }

/// Loop and stall detection for the browser agent (browser-use v2).
///
/// Signals: the same action on the same page again and again; N actions in a row that changed nothing (a stall);
/// failures in a row; bouncing between two pages. The answer escalates: first a nudge (take another route), then a
/// forced re-plan, then a clean stop with a clear message. After each warning the window starts over, so one old
/// repetition is never counted twice (the old guard kept re-firing on the same four steps until it gave up).
class LoopGuard {
  LoopGuard({this.window = 6, this.stallAfter = 4, this.failAfter = 3, this.repeatAfter = 3});

  final int window;
  final int stallAfter;
  final int failAfter;
  final int repeatAfter;

  final List<StepTrace> _recent = [];
  int warnings = 0;
  String reason = '';

  void reset() => _recent.clear();

  static String sig(String tool, String args) => '$tool ${args.replaceAll(RegExp(r'\s+'), '')}';

  String _lastPage = '';

  GuardVerdict record(StepTrace t) {
    _recent.add(t);
    if (_recent.length > window * 2) _recent.removeAt(0);
    final r = _check();
    final moved = t.page != _lastPage;
    _lastPage = t.page;
    if (r == null) {
      // Real progress (the step worked AND the page is a different one now) clears the slate.
      if (t.changed && !t.failed && moved) warnings = 0;
      return GuardVerdict.ok;
    }
    reason = r;
    warnings++;
    _recent.clear();
    if (warnings >= 3) return GuardVerdict.stop;
    return warnings == 2 ? GuardVerdict.replan : GuardVerdict.nudge;
  }

  String? _check() {
    final n = _recent.length;
    // Same action on the same page, repeatedly.
    final counts = <String, int>{};
    for (final s in _recent.skip(n > window ? n - window : 0)) {
      final k = '${s.action}@${s.page}';
      counts[k] = (counts[k] ?? 0) + 1;
    }
    if (counts.values.any((c) => c >= repeatAfter)) return 'the same action was repeated on the same page';
    // Stall: nothing changed for several actions.
    if (n >= stallAfter && _recent.sublist(n - stallAfter).every((s) => !s.changed)) {
      return 'the last $stallAfter actions changed nothing on the page';
    }
    // Failures in a row.
    if (n >= failAfter && _recent.sublist(n - failAfter).every((s) => s.failed)) return 'the last $failAfter actions failed';
    // Bouncing A -> B -> A -> B between two pages.
    if (n >= 4) {
      final u = _recent.sublist(n - 4).map((s) => s.url).toList();
      if (u[0] == u[2] && u[1] == u[3] && u[0] != u[1]) return 'it is going back and forth between two pages';
    }
    return null;
  }

  String message(GuardVerdict v) {
    switch (v) {
      case GuardVerdict.nudge:
        return 'LOOP CHECK: $reason. Stop repeating it. Look at the screenshot and the element list again and take a '
            'different route (close an overlay, scroll the element in, use another element, a search box, a direct URL, '
            'browser_back). Write in memory what failed so you never try it again.';
      case GuardVerdict.replan:
        return 'LOOP CHECK (second time): $reason. Your plan is not working. Call plan with a NEW checklist that takes a '
            'different approach (another page, another site, the site\'s search, a direct link), then continue.';
      case GuardVerdict.stop:
        return 'Stopped: I kept getting stuck ($reason) and changing approach did not help.';
      case GuardVerdict.ok:
        return '';
    }
  }
}

/// The browser task's budget: steps and wall-clock time. Every limit is hard.
class StepBudget {
  StepBudget({this.maxSteps = 120, this.maxTime = const Duration(minutes: 25), DateTime? start}) : started = start ?? DateTime.now();

  final int maxSteps;
  final Duration maxTime;
  DateTime started;
  int steps = 0;

  void restart({DateTime? now}) {
    started = now ?? DateTime.now();
    steps = 0;
  }

  bool spent({DateTime? now}) => steps >= maxSteps || (now ?? DateTime.now()).difference(started) >= maxTime;

  /// 75 % used: time to consolidate (browser-use's budget rule).
  bool nearlySpent({DateTime? now}) =>
      steps >= (maxSteps * 0.75).floor() || (now ?? DateTime.now()).difference(started) >= maxTime * 0.75;

  String left({DateTime? now}) {
    final m = maxTime.inMinutes - (now ?? DateTime.now()).difference(started).inMinutes;
    return '${maxSteps - steps} steps and about ${m < 0 ? 0 : m} min left';
  }
}

/// Bounded waits: nothing in the browser agent awaits without a limit, and every wait ends at once on Stop.
class Bounded {
  /// [f] with a time limit; on timeout returns [fallback]. A thrown error also returns [fallback] when [swallow].
  static Future<T> run<T>(Future<T> f, Duration limit, T fallback, {bool swallow = true}) async {
    try {
      return await f.timeout(limit, onTimeout: () => fallback);
    } catch (_) {
      if (swallow) return fallback;
      rethrow;
    }
  }

  /// Waits for [f], but gives up when [cancel] completes or after [limit]. Returns null when it gave up.
  static Future<T?> orCancel<T>(Future<T> f, Future<void> cancel, {Duration? limit}) {
    final c = Completer<T?>();
    Timer? t;
    void finish(T? v) {
      if (c.isCompleted) return;
      t?.cancel();
      c.complete(v);
    }

    f.then(finish, onError: (_) => finish(null));
    cancel.then((_) => finish(null), onError: (_) => finish(null));
    if (limit != null) t = Timer(limit, () => finish(null));
    return c.future;
  }

  /// A delay that ends early when [cancelled] says so (checked every 100 ms).
  static Future<void> sleep(Duration d, bool Function() cancelled) async {
    final end = DateTime.now().add(d);
    while (DateTime.now().isBefore(end)) {
      if (cancelled()) return;
      final left = end.difference(DateTime.now());
      await Future<void>.delayed(left < const Duration(milliseconds: 100) ? left : const Duration(milliseconds: 100));
    }
  }
}
