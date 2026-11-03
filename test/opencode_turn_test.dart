import 'package:agent/services/opencode.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> ev(String type, Map<String, dynamic> props) => {'type': type, 'properties': props};

void main() {
  test('a turn folds text, tool steps and the end of the reply; the user\'s own message is skipped', () {
    final t = OpenCodeTurn('s1');
    t.apply(ev('message.updated', {'info': {'id': 'u1', 'sessionID': 's1', 'role': 'user'}}));
    t.apply(ev('message.part.updated', {'part': {'id': 'p0', 'sessionID': 's1', 'messageID': 'u1', 'type': 'text', 'text': 'hi'}}));
    expect(t.parts, isEmpty);
    t.apply(ev('message.updated', {'info': {'id': 'a1', 'sessionID': 's1', 'role': 'assistant'}}));
    t.apply(ev('message.part.updated', {'part': {'id': 'p1', 'sessionID': 's1', 'messageID': 'a1', 'type': 'text', 'text': ''}}));
    t.apply(ev('message.part.delta', {'sessionID': 's1', 'messageID': 'a1', 'partID': 'p1', 'field': 'text', 'delta': 'Hel'}));
    t.apply(ev('message.part.delta', {'sessionID': 's1', 'messageID': 'a1', 'partID': 'p1', 'field': 'text', 'delta': 'lo'}));
    expect(t.parts['p1']!.text, 'Hello');
    t.apply(ev('message.part.updated', {
      'part': {
        'id': 'p2', 'sessionID': 's1', 'messageID': 'a1', 'type': 'tool', 'tool': 'bash', 'callID': 'c1',
        'state': {'status': 'running', 'input': {'command': 'ls'}, 'title': 'List files'},
      }
    }));
    expect(t.parts['p2']!.finished, isFalse);
    t.apply(ev('message.part.updated', {
      'part': {
        'id': 'p2', 'sessionID': 's1', 'messageID': 'a1', 'type': 'tool', 'tool': 'bash', 'callID': 'c1',
        'state': {'status': 'completed', 'input': {'command': 'ls'}, 'output': 'a.txt', 'title': 'List files'},
      }
    }));
    expect(t.parts['p2']!.output, 'a.txt');
    expect(t.parts['p2']!.finished, isTrue);
    // Another chat's events change nothing.
    expect(t.apply(ev('session.idle', {'sessionID': 's2'})), isFalse);
    expect(t.done, isFalse);
    t.apply(ev('session.status', {'sessionID': 's1', 'status': {'type': 'idle'}}));
    expect(t.done, isTrue);
    expect(t.parts.keys, ['p1', 'p2']);
  });

  test('thinking streams as its own part and closes when the answer starts', () {
    final t = OpenCodeTurn('s1');
    t.apply(ev('message.updated', {'info': {'id': 'a1', 'sessionID': 's1', 'role': 'assistant'}}));
    t.apply(ev('message.part.updated', {'part': {'id': 'r1', 'sessionID': 's1', 'messageID': 'a1', 'type': 'reasoning', 'text': ''}}));
    t.apply(ev('message.part.delta', {'sessionID': 's1', 'messageID': 'a1', 'partID': 'r1', 'field': 'text', 'delta': 'Let me '}));
    t.apply(ev('message.part.delta', {'sessionID': 's1', 'messageID': 'a1', 'partID': 'r1', 'field': 'text', 'delta': 'think.'}));
    expect(t.parts['r1']!.kind, 'reasoning');
    expect(t.parts['r1']!.text, 'Let me think.');
    expect(t.reasoning, isTrue);
    expect(t.parts['r1']!.finished, isFalse);
    t.apply(ev('message.part.delta', {'sessionID': 's1', 'messageID': 'a1', 'partID': 't1', 'field': 'text', 'delta': 'x'}));
    expect(t.parts['t1']!.kind, 'reasoning'); // a delta for an unseen part while thinking is thinking
    t.apply(ev('message.part.updated', {'part': {'id': 'p1', 'sessionID': 's1', 'messageID': 'a1', 'type': 'text', 'text': 'Answer'}}));
    expect(t.reasoning, isFalse);
    expect(t.parts['r1']!.finished, isTrue);
    expect(t.parts['p1']!.text, 'Answer');
  });

  test('an error ends the turn with its message; a stop is not an error', () {
    final t = OpenCodeTurn('s1');
    t.apply(ev('session.error', {'sessionID': 's1', 'error': {'name': 'MessageAbortedError', 'data': {}}}));
    expect(t.error, isNull);
    t.apply(ev('session.error', {
      'sessionID': 's1',
      'error': {'name': 'UnknownError', 'data': {'message': 'getaddrinfo EAI_AGAIN'}}
    }));
    expect(t.error, 'getaddrinfo EAI_AGAIN');
  });

  test('a retry shows its message', () {
    final t = OpenCodeTurn('s1');
    t.apply(ev('session.status', {'sessionID': 's1', 'status': {'type': 'retry', 'attempt': 1, 'message': 'Rate limited'}}));
    expect(t.retry, 'Rate limited');
  });
}
