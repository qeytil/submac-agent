import 'dart:convert';

import 'package:agent/services/agent_loop.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LoopGuard', () {
    test('same call with the same result three times is a repeat', () {
      final g = LoopGuard();
      for (var i = 0; i < 3; i++) {
        g.record('fetch_url', '{"url":"https://a.so"}', 'Page text');
      }
      expect(g.check().kind, LoopKind.repeat);
      expect(g.check().escalate, isTrue);
    });

    test('argument order and spacing do not hide a repeat', () {
      final g = LoopGuard();
      g.record('web_search', '{"q":"hotels","n":3}', 'r');
      g.record('web_search', '{ "n": 3, "q": "hotels" }', 'r');
      g.record('web_search', '{"n":3,"q":"hotels"}', 'r');
      expect(g.check().kind, LoopKind.repeat);
    });

    test('different calls are fine', () {
      final g = LoopGuard();
      g.record('web_search', '{"q":"a"}', 'r1');
      g.record('fetch_url', '{"url":"x"}', 'r2');
      g.record('web_search', '{"q":"b"}', 'r3');
      expect(g.check().stuck, isFalse);
    });

    test('scrolling may repeat for a while', () {
      final g = LoopGuard();
      for (var i = 0; i < 6; i++) {
        g.record('phone_scroll', '{"dir":"down"}', 'same screen');
      }
      expect(g.check().stuck, isFalse);
      for (var i = 0; i < 3; i++) {
        g.record('phone_scroll', '{"dir":"down"}', 'same screen');
      }
      expect(g.check().kind, LoopKind.repeat);
    });

    test('the same failing call three times is repeatedError with alternatives', () {
      final g = LoopGuard();
      for (var i = 0; i < 3; i++) {
        g.record('fetch_url', '{"url":"x"}', 'Error in fetch_url: 403 Forbidden');
      }
      final s = g.check();
      expect(s.kind, LoopKind.repeatedError);
      expect(s.guidance, contains('web_search'));
    });

    test('one tool failing with different inputs is failingTool (no escalation by itself)', () {
      final g = LoopGuard();
      g.record('web_search', '{"q":"a"}', 'Error: search is down');
      g.record('web_search', '{"q":"b"}', 'Error: search is down');
      g.record('web_search', '{"q":"c"}', 'Error: search is down');
      final s = g.check();
      expect(s.kind, LoopKind.failingTool);
      expect(s.escalate, isFalse);
    });

    test('A B A B A B is ping-pong', () {
      final g = LoopGuard();
      for (var i = 0; i < 3; i++) {
        g.record('browser_click', '{"n":3}', 'page ${i * 2}');
        g.record('browser_back', '{}', 'list ${i * 2 + 1}');
      }
      expect(g.check().kind, LoopKind.pingPong);
    });

    test('reset clears the history', () {
      final g = LoopGuard();
      for (var i = 0; i < 3; i++) {
        g.record('fetch_url', '{"url":"x"}', 'same');
      }
      g.reset();
      expect(g.check().stuck, isFalse);
    });
  });

  group('ParallelPlan', () {
    test('neighbouring reads share a batch, changes are barriers', () {
      final b = ParallelPlan.batches(['web_search', 'web_search', 'fetch_url', 'write_file', 'read_file', 'list_dir', 'say']);
      expect(b, [
        [0, 1, 2],
        [3],
        [4, 5],
        [6],
      ]);
    });

    test('broken calls run alone', () {
      final b = ParallelPlan.batches(['web_search', 'web_search', 'web_search'], broken: {1});
      expect(b, [
        [0],
        [1],
        [2],
      ]);
    });

    test('batches are capped', () {
      final b = ParallelPlan.batches(List.filled(8, 'web_search'), max: 6);
      expect(b.map((e) => e.length).toList(), [6, 2]);
    });

    test('screen and message tools are never parallel', () {
      for (final n in ['browser_click', 'phone_tap', 'whatsapp', 'email_send', 'write_file', 'todo', 'ask_user', 'more_tools']) {
        expect(ParallelPlan.isSafe(n), isFalse, reason: n);
      }
    });

    test('runBatch keeps the order of results', () async {
      final out = await ParallelPlan.runBatch([0, 1, 2], (i) async {
        await Future<void>.delayed(Duration(milliseconds: 30 - i * 10));
        return 'r$i';
      });
      expect(out, ['r0', 'r1', 'r2']);
    });
  });

  group('ResultClip', () {
    test('small results are untouched', () {
      expect(ResultClip.fresh('hello'), 'hello');
      expect(ResultClip.old('short'), 'short');
    });

    test('a huge fresh result keeps head and tail', () {
      final big = List.generate(4000, (i) => 'line $i of the page').join('\n');
      final c = ResultClip.fresh(big);
      expect(c.length, lessThan(ResultClip.freshMax + 300));
      expect(c, startsWith('line 0 of the page'));
      expect(c, contains('line 3999 of the page'));
      expect(c, contains('characters cut from the middle'));
    });

    test('old results keep start and end and are deterministic', () {
      final v = '${'a' * 1000}\nTOTAL: 42';
      final o = ResultClip.old(v);
      expect(o.length, lessThan(560));
      expect(o, contains('TOTAL: 42'));
      expect(ResultClip.old(v), o);
    });
  });

  group('ToolRecovery', () {
    test('errors are recognised', () {
      expect(ToolRecovery.isError('Error in fetch_url: boom'), isTrue);
      expect(ToolRecovery.isError('Error: web_search took too long and was stopped.'), isTrue);
      expect(ToolRecovery.isError('Here are 5 results'), isFalse);
    });

    test('only read-only network hiccups get a retry', () {
      expect(ToolRecovery.retryOnce('fetch_url', 'Error: fetch_url took too long and was stopped.'), isTrue);
      expect(ToolRecovery.retryOnce('web_search', 'Error in web_search: SocketException: connection reset'), isTrue);
      expect(ToolRecovery.retryOnce('fetch_url', 'Error in fetch_url: 404 not found'), isFalse);
      expect(ToolRecovery.retryOnce('email_send', 'Error: took too long'), isFalse);
    });
  });

  group('TurnRouter', () {
    test('needsPlan spots multi-part requests', () {
      expect(TurnRouter.needsPlan('Build me a website for my shop in Hargeisa'), isTrue);
      expect(TurnRouter.needsPlan('Please:\n1. find hotels\n2. compare prices\n3. book the best'), isTrue);
      expect(TurnRouter.needsPlan('what is the weather'), isFalse);
    });
  });

  group('TailNote and recitation', () {
    test('note goes before the last user message (their words last), or follows tool results', () {
      final a = TailNote.attach([
        {'role': 'system', 'content': 'S'},
        {'role': 'user', 'content': 'hi'},
      ], 'NOTE');
      expect(a.length, 2);
      expect(a.last['content'], contains('NOTE'));
      expect(a.last['content'], startsWith(TailNote.open));
      expect(a.last['content'], endsWith('hi'));
      final b = TailNote.attach([
        {'role': 'system', 'content': 'S'},
        {'role': 'user', 'content': 'hi'},
        {'role': 'assistant', 'content': null, 'tool_calls': []},
        {'role': 'tool', 'tool_call_id': '1', 'content': 'r'},
      ], 'NOTE');
      expect(b.length, 5);
      expect(b.last['role'], 'user');
      final c = TailNote.attach([
        {'role': 'system', 'content': 'S'},
        {'role': 'user', 'content': 'hi'},
        {'role': 'assistant', 'content': null, 'tool_calls': []},
        {'role': 'tool', 'tool_call_id': '1', 'content': 'r'},
      ], 'NOTE', request: TaskBrief('find 3 hotels').recital());
      expect(TailNote.lastText(c), endsWith('"find 3 hotels"'));
      expect(TailNote.lastText(c).indexOf('NOTE'), lessThan(TailNote.lastText(c).indexOf('find 3 hotels')));
      expect(TailNote.attach([{'role': 'user', 'content': 'x'}], ''), [{'role': 'user', 'content': 'x'}]);
    });

    test('image messages get the note as an extra text part', () {
      final a = TailNote.attach([
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'look'},
          ],
        },
      ], 'N');
      expect((a.last['content'] as List).length, 2);
      expect(TailNote.lastText(a), 'look');
    });

    test('checklist marks the next step and turns into the final check', () {
      final c = Recite.checklist(['plan', 'build', 'check'], {0});
      expect(c, contains('1/3 done'));
      expect(c, contains('2. [ ] build  <- now'));
      expect(Recite.checklist(['a'], {0}), contains('Before your final reply'));
      expect(Recite.checklist([], {}), '');
    });

    test('step budget warns two steps before the limit', () {
      expect(StepBudget.note(23, 25), isNotNull);
      expect(StepBudget.note(10, 25), isNull);
      expect(StepBudget.note(0, 1), isNull);
    });
  });

  test('canonical args', () {
    expect(LoopGuard.canonicalArgs('{"b":{"y":1,"x":2},"a":[1]}'), jsonEncode({'a': [1], 'b': {'x': 2, 'y': 1}}));
    expect(LoopGuard.canonicalArgs(''), '{}');
    expect(LoopGuard.canonicalArgs('not json  here'), 'not json here');
  });
}
