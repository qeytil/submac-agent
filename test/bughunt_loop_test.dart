// Bug hunt 2026-10-23: the agent loop and bot work. Each test failed before its fix.
import 'package:agent/services/agent_loop.dart';
import 'package:agent/services/bots.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('#1 a task over its spending limit stops', () {
    test('one note, then a hard stop two steps later if it keeps calling tools', () {
      expect(SpendStop.decide(over: true, wantsTools: true, wrapUpAt: -1, step: 10), WrapUp.note);
      expect(SpendStop.decide(over: true, wantsTools: true, wrapUpAt: 10, step: 11), WrapUp.none);
      expect(SpendStop.decide(over: true, wantsTools: true, wrapUpAt: 10, step: 12), WrapUp.stop);
    });
    test('nothing to stop when under budget or already answering', () {
      expect(SpendStop.decide(over: false, wantsTools: true, wrapUpAt: -1, step: 3), WrapUp.none);
      expect(SpendStop.decide(over: true, wantsTools: false, wrapUpAt: 2, step: 9), WrapUp.none);
    });
  });

  group('#2 blank replies', () {
    test('two blanks in a row are nudged, the third ends the task', () {
      final g = BlankGuard();
      expect(g.retry(), isTrue);
      expect(g.retry(), isTrue);
      expect(g.retry(), isFalse);
    });
    test('a real reply in between resets the count (long tasks no longer die at their third blank)', () {
      final g = BlankGuard();
      for (var i = 0; i < 10; i++) {
        expect(g.retry(), isTrue);
        g.gotReply();
      }
    });
  });

  group('#4 a put-off check-in', () {
    test('is still a check-in, retried or not', () {
      expect(Bots.isHeartbeat(Bots.heartbeat), isTrue);
      expect(Bots.isHeartbeat('(retry) ${Bots.heartbeat}'), isTrue);
      expect(Bots.isHeartbeat('Send the weekly report'), isFalse);
      expect(Bots.isHeartbeat(''), isFalse);
    });
    test('a busy bot keeps one follow-up per job, not one per wake', () {
      final b = Bot(id: 'b1', name: 'Nova', role: 'Researcher', persona: '');
      expect(Bots.hasPendingFollowup(b, '', 'work'), isFalse);
      b.followups.add(BotFollowup('f1', DateTime.now().add(const Duration(minutes: 15)), Bots.heartbeat, 'work'));
      expect(Bots.hasPendingFollowup(b, '', 'work'), isTrue);
      expect(Bots.hasPendingFollowup(b, 'Send the weekly report', 'work'), isFalse);
      expect(Bots.hasPendingFollowup(b, '', 'message'), isFalse);
    });
  });
}
