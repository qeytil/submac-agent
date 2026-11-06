// Bug hunt 2026-11-06: a turn whose engine events stopped coming recovers instead of showing "Working" forever;
// streamed words no longer rebuild the app on every event; the end-of-turn file walk runs off the UI thread.
import 'dart:io';

import 'package:agent/services/opencode.dart';
import 'package:agent/services/turn_visuals.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('OcWatch', () {
    final t0 = DateTime(2026, 11, 6, 12);
    bool due(int nowS, {int seenS = 0, int checkedS = 0, bool dropped = false}) => OcWatch.due(
        now: t0.add(Duration(seconds: nowS)),
        sent: t0,
        seen: t0.add(Duration(seconds: seenS)),
        checked: t0.add(Duration(seconds: checkedS)),
        dropped: dropped);

    test('never in the first seconds after the prompt', () {
      expect(due(3, dropped: true), isFalse);
      expect(due(7, seenS: -60, dropped: true), isFalse);
    });
    test('a dropped stream is checked once settled', () {
      expect(due(12, seenS: 11, dropped: true), isTrue);
    });
    test('a quiet turn is checked after 30 s, a lively one is not', () {
      expect(due(31), isTrue);
      expect(due(31, seenS: 25), isFalse);
    });
    test('at most every 10 s', () {
      expect(due(40, checkedS: 35, dropped: true), isFalse);
      expect(due(46, checkedS: 35, dropped: true), isTrue);
    });
  });

  group('session status', () {
    test('a session missing from /session/status is idle', () {
      expect(OpenCodeTurn.statusIn(<String, dynamic>{}, 's1'), 'idle');
      expect(OpenCodeTurn.statusIn({'s2': {'type': 'busy'}}, 's1'), 'idle');
    });
    test('busy and retry are read', () {
      expect(OpenCodeTurn.statusIn({'s1': {'type': 'busy'}}, 's1'), 'busy');
      expect(OpenCodeTurn.statusIn({'s1': {'type': 'retry', 'attempt': 2}}, 's1'), 'retry');
    });
    test('an unreadable answer is unknown', () {
      expect(OpenCodeTurn.statusIn('oops', 's1'), isNull);
      expect(OpenCodeTurn.statusIn(null, 's1'), isNull);
    });
  });

  group('applySnapshot', () {
    final since = DateTime.fromMillisecondsSinceEpoch(1000000);
    Map<String, dynamic> msg(String id, String role, int created, List<Map<String, dynamic>> parts, {String session = 's1'}) => {
          'info': {'id': id, 'sessionID': session, 'role': role, 'time': {'created': created}},
          'parts': parts,
        };

    test('the answer written while the stream was down shows', () {
      final turn = OpenCodeTurn('s1');
      final changed = turn.applySnapshot([
        msg('u1', 'user', 1000500, [
          {'id': 'p0', 'sessionID': 's1', 'messageID': 'u1', 'type': 'text', 'text': 'hi'}
        ]),
        msg('a1', 'assistant', 1000600, [
          {'id': 'p1', 'sessionID': 's1', 'messageID': 'a1', 'type': 'reasoning', 'text': 'thinking'},
          {'id': 'p2', 'sessionID': 's1', 'messageID': 'a1', 'type': 'tool', 'tool': 'bash', 'callID': 'c1',
            'state': {'status': 'completed', 'input': {'command': 'ls'}, 'output': 'a b'}},
          {'id': 'p3', 'sessionID': 's1', 'messageID': 'a1', 'type': 'text', 'text': 'Done: two files.'},
        ]),
      ], since: since);
      expect(changed, isTrue);
      expect(turn.answer, 'Done: two files.');
      expect(turn.parts.values.where((p) => p.kind == 'tool').single.output, 'a b');
      expect(turn.parts.containsKey('p0'), isFalse, reason: 'the user message is not a reply');
      expect(turn.reasoning, isFalse);
      expect(turn.parts['p1']!.finished, isTrue);
    });

    test('older replies and other sessions stay out', () {
      final turn = OpenCodeTurn('s1');
      turn.applySnapshot([
        msg('a0', 'assistant', 900000, [
          {'id': 'old', 'sessionID': 's1', 'messageID': 'a0', 'type': 'text', 'text': 'last turn'}
        ]),
        msg('x1', 'assistant', 1000700, [
          {'id': 'other', 'sessionID': 's2', 'messageID': 'x1', 'type': 'text', 'text': 'another chat'}
        ], session: 's2'),
      ], since: since);
      expect(turn.parts, isEmpty);
    });

    test('a provider error in the stored reply ends the turn with it', () {
      final turn = OpenCodeTurn('s1');
      turn.applySnapshot([
        {
          'info': {
            'id': 'a1', 'sessionID': 's1', 'role': 'assistant', 'time': {'created': 1000800},
            'error': {'name': 'APIError', 'data': {'message': 'quota exceeded'}}
          },
          'parts': const [],
        }
      ], since: since);
      expect(turn.error, 'quota exceeded');
    });

    test('garbage is ignored', () {
      final turn = OpenCodeTurn('s1');
      expect(turn.applySnapshot({'not': 'a list'}, since: since), isFalse);
      expect(turn.applySnapshot([1, 'x', null], since: since), isFalse);
    });
  });

  test('madeSinceAsync finds the same files as madeSince', () async {
    final root = await Directory.systemTemp.createTemp('bh1106');
    final since = DateTime.now().subtract(const Duration(seconds: 5));
    await File('${root.path}/out/plot.png').create(recursive: true);
    await File('${root.path}/bots/b1/chart.png').create(recursive: true);
    final a = await TurnVisuals.madeSinceAsync(root, since, skip: const {'bots'});
    expect(a, TurnVisuals.madeSince(root, since, skip: const {'bots'}));
    expect(a, ['${root.path}/out/plot.png']);
    await root.delete(recursive: true);
  });

  test('the chat batches streamed words instead of rebuilding on each event', () {
    final src = File('lib/state/agent_runner.dart').readAsStringSync();
    final sync = src.substring(src.indexOf('void sync() {'), src.indexOf('// The allowance lane and model of this turn'));
    expect(sync.contains('_throttledNotify();'), isTrue);
    expect(RegExp(r'^\s*_notify\(\);', multiLine: true).hasMatch(sync), isFalse);
  });
}
