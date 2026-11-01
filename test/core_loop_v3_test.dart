import 'package:agent/app_state.dart';
import 'package:agent/services/agent_loop.dart';
import 'package:agent/services/quick_lane.dart';
import 'package:agent/services/search_budget.dart';
import 'package:agent/services/tools.dart';
import 'package:flutter_test/flutter_test.dart';

/// Core loop v3 (2026-11-01): the harness stops deciding for the model. These are the contracts that make a novel,
/// heavy task get the whole workbench, room to work, and no "wrap up now" pressure (docs/core-loop-v3.md).
void main() {
  group('no task is guessed small', () {
    // Plain imperatives with uncommon verbs used to land in the light lane: ~18 tools, no write_file, no code_run.
    const novel = [
      "Organise last month's receipts into categories and total each one",
      'Turn these lecture notes into a study guide with flashcards',
      'Reconcile my two bank statements and flag duplicates',
      'Benchmark three sorting algorithms on a million integers',
      'Convert all the HEIC photos in my Downloads to JPG and shrink them',
      'Migrate my recipes from the old JSON format to markdown files',
    ];
    for (final t in novel) {
      test('full lane: $t', () => expect(QuickLane.laneFor(t), QuickLane.full));
    }
    test('small talk is still instant', () {
      expect(QuickLane.laneFor('hi'), QuickLane.quick);
      expect(QuickLane.laneFor('thanks!'), QuickLane.quick);
    });
    test('nothing is ever light any more', () {
      for (final t in ['ok cool', 'tell me about Mogadishu', 'my cat is sick', 'Lagos weather']) {
        expect(QuickLane.laneFor(t), isNot(QuickLane.light), reason: t);
      }
    });
  });

  group('long work is judged by progress, not by files written', () {
    String? reason({int fresh = 0, int writes = 0, int done = 0}) => AppState.checkpointReason(
        cancelled: false, lowAllowance: false, background: false, doneNow: done, doneAtCheckpoint: 0,
        writesSinceCheckpoint: writes, steps: 50, freshSinceCheckpoint: fresh);
    test('a research run that keeps finding new things goes on', () => expect(reason(fresh: 6), isNull));
    test('a run that found nothing new pauses', () => expect(reason(fresh: 2), isNotNull));
    test('writes and ticks still count', () {
      expect(reason(writes: 2), isNull);
      expect(reason(done: 1), isNull);
    });
  });

  group('the loop guard flags loops, not patience', () {
    test('polling something that keeps changing is not a loop', () {
      final g = LoopGuard();
      for (var i = 0; i < 10; i++) {
        g.record('code_build', '{"action":"wait"}', 'build running: step $i of 12');
      }
      expect(g.check().stuck, isFalse);
    });
    test('the same call with the same result is still a loop', () {
      final g = LoopGuard();
      for (var i = 0; i < 3; i++) {
        g.record('fetch_url', '{"url":"https://a.so"}', 'Page text');
      }
      expect(g.check().stuck, isTrue);
    });
  });

  test('research may use three read-only browser jobs, as the prompt says', () {
    final b = SearchBudget();
    for (var i = 0; i < 3; i++) {
      expect(b.before('browser_task', {'goal': 'compare prices of laptops on site $i'}), isNull);
    }
    expect(b.before('browser_task', {'goal': 'compare prices on a fourth site'}), isNotNull);
  });

  group('read_file by line', () {
    final text = List.generate(1000, (i) => 'line ${i + 1}').join('\n');
    test('numbered lines from where you ask', () {
      final out = AgentTools.numberedLines(text, 10, 12);
      expect(out, contains('   10  line 10'));
      expect(out, contains('   12  line 12'));
      expect(out, isNot(contains('line 13\n')));
      expect(out, contains('read on with start_line 13'));
    });
    test('at most 400 lines at once, and it says where to read on', () {
      final out = AgentTools.numberedLines(text, 1, null);
      expect(out, contains('  400  line 400'));
      expect(out, contains('start_line 401'));
    });
    test('past the end says how long the file is', () => expect(AgentTools.numberedLines(text, 2000, null), contains('1000 lines')));
  });

  test('the request is recited as a reminder, never as a new task', () {
    final r = TaskBrief('Build me a budget sheet').recital();
    expect(r, contains('not a new message'));
    expect(r, contains('Build me a budget sheet'));
  });
}
