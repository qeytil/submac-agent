import 'package:flutter_test/flutter_test.dart';
import 'package:agent/app_state.dart';
import 'package:agent/models.dart';
import 'package:agent/services/agent_loop.dart';
import 'package:agent/services/constraints.dart';
import 'package:agent/services/quick_lane.dart';
import 'package:agent/services/tool_scope.dart';

void main() {
  group('"no" answering SubMac continues the task', () {
    test('lane', () {
      for (final t in ['no', 'nope', 'nah', 'maya', 'no thanks', 'haa', 'the second one']) {
        expect(QuickLane.laneFor(t, answeringQuestion: true), QuickLane.full, reason: t);
      }
      expect(QuickLane.laneFor('no'), QuickLane.quick);
      expect(QuickLane.laneFor('thanks', answeringQuestion: true), QuickLane.quick);
    });

    test('knows when our last reply asked something', () {
      final asked = [
        ChatMessage(id: '1', role: 'user', content: 'book a table'),
        ChatMessage(id: '2', role: 'assistant', content: 'Should I pick the window seat?'),
        ChatMessage(id: '3', role: 'user', content: 'no'),
      ];
      expect(AppState.answersOurQuestionForTest(asked), isTrue);
      final told = [
        ChatMessage(id: '1', role: 'user', content: 'book a table'),
        ChatMessage(id: '2', role: 'assistant', content: 'Booked for 8 pm.'),
        ChatMessage(id: '3', role: 'user', content: 'no'),
      ];
      expect(AppState.answersOurQuestionForTest(told), isFalse);
    });
  });

  // One model since PLAN 1.1: there is no fast route to skip; constraints still ride along as the Must line.
  group('constraints', () {
    test('Must line and self-check', () {
      final c = ConstraintReader.read('Write 5 tips in Somali, no emoji, only the list');
      expect(c.mustLine(), allOf(contains('5 tips'), contains('Somali'), contains('no emoji'), contains('only the list')));
      expect(c.selfCheck(), contains('Must'));
      expect(ConstraintReader.read('hello there').mustLine(), isEmpty);
      expect(ConstraintReader.read('Ha ha').any, isFalse);
      expect(Recite.finalCheck(selfCheck: c.selfCheck()), contains('Self-check'));
    });
  });

  group('mid-task corrections amend the task', () {
    test('original + change, both verbatim', () {
      final b = TaskBrief('Find a hotel in Hargeisa under \$80 with breakfast')..amend('use Booking.com instead');
      final r = b.recital();
      expect(r, contains('"Find a hotel in Hargeisa under \$80 with breakfast"'));
      expect(r, contains('"use Booking.com instead"'));
      expect(r, contains('amends the request'));
      expect(TaskBrief.steer('"use Booking.com"', acked: false), contains('keep their original request'));
      expect(TaskBrief.steer('"x"', acked: true), isNot(contains('overrides')));
    });

    test('long requests are clipped, not dropped', () {
      final long = 'a' * 4000;
      expect(TaskBrief(long).recital().length, lessThan(1800));
      expect(TaskBrief('').recital(), isEmpty);
    });
  });

  test('Somali tool triggers', () {
    expect(ToolScope.hinted('warqad ii qor'), contains(ToolScope.files));
    expect(ToolScope.hinted('faylka ii fur'), contains(ToolScope.files));
    expect(ToolScope.hinted('sawir ii samee'), contains(ToolScope.media));
    expect(ToolScope.hinted('hotel raadi'), contains(ToolScope.browser));
    expect(ToolScope.hinted('fariinta u dir'), contains(ToolScope.phone));
    expect(ToolScope.hinted('xisaabi kharashka'), contains(ToolScope.cards));
    expect(ToolScope.hinted('bog ii samee'), containsAll([ToolScope.browser, ToolScope.files]));
  });

  test('system prompt: amend wording, one short question, user words beat skills', () {
    final s = AppState().systemPromptForTest();
    expect(s, isNot(contains('The latest user message is the task')));
    expect(s, contains('amends the request'));
    expect(s, contains('Never ask about anything they already said'));
    expect(s, contains('Ask at most one short question'));
    expect(s, isNot(contains('up to 3 short questions')));
  });
}
