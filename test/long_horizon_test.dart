import 'package:agent/app_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  String? cp({bool cancelled = false, bool low = false, bool bg = false, int done = 0, int at = 0, int writes = 0}) =>
      AppState.checkpointReason(cancelled: cancelled, lowAllowance: low, background: bg, doneNow: done, doneAtCheckpoint: at,
          writesSinceCheckpoint: writes, steps: 50);

  test('a long task goes on past the checkpoint while it makes progress', () {
    expect(cp(done: 3, at: 1), isNull);
    expect(cp(writes: 4), isNull);
  });

  test('it pauses with no progress, low allowance, background or a stop', () {
    expect(cp(), contains('did not move'));
    expect(cp(low: true, writes: 9), contains('allowance'));
    expect(cp(bg: true, writes: 9), contains('Paused'));
    expect(cp(cancelled: true), 'Stopped.');
  });

  test('unfinished work is spotted', () {
    for (final s in ['// TODO: add login', 'Lorem ipsum dolor', 'function pay() { /* not implemented */ }', '// ... rest of the code', 'apiKey = "YOUR_API_KEY"']) {
      expect(AppState.unfinished.hasMatch(s), isTrue, reason: s);
    }
    for (final s in ['final total = price * qty;', '<h1>Hodan Shop</h1>', 'todos.add(item)']) {
      expect(AppState.unfinished.hasMatch(s), isFalse, reason: s);
    }
  });

  test('the ceiling leaves room for a full build', () {
    expect(AppState.longTaskCeiling, greaterThanOrEqualTo(500));
  });
}
