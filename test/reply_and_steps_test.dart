import 'package:flutter_test/flutter_test.dart';

import 'package:agent/services/agent_loop.dart';
import 'package:agent/widgets/chat_logic.dart';
import 'package:agent/widgets/reply_blocks.dart';

/// A reply is split by one rule and its steps are judged by another: these tests keep them honest.
void main() {
  group('one failure rule', () {
    const bad = [
      'Error: no such file',
      'Failed to send the message',
      'HTTP 503 from the server',
      'The user said no',
      'exit_code: 1',
      'exit_code: -1',
    ];
    const good = ['Done. 3 files.', '12 items in the folder', 'exit_code: 0', ''];

    test('a failed step is failed everywhere', () {
      for (final out in bad) {
        expect(ToolRecovery.stepFailed(out), isTrue, reason: out);
        expect(TurnStep('x', '{}', out).failed, isTrue, reason: out);
      }
    });

    test('ordinary output is not a failure', () {
      for (final out in good) {
        expect(ToolRecovery.stepFailed(out), isFalse, reason: out);
        expect(TurnStep('x', '{}', out).failed, isFalse, reason: out);
      }
    });

    test('a step with no result yet is not a failure', () {
      expect(TurnStep('x', '{}', null).failed, isFalse);
    });
  });

  group('parseReply', () {
    test('plain text is one text block', () {
      final b = parseReply('Hello there.' + String.fromCharCode(10) + String.fromCharCode(10) + 'Second line.');
      expect(b.length, 1);
      expect(b.first.lang, isNull);
      expect(b.first.text, contains('Hello there.'));
    });

    test('a card is its own block, text on both sides stays text', () {
      final src = 'Here it is.' + String.fromCharCode(10) +
          '```table' + String.fromCharCode(10) +
          '{"columns":["a"],"rows":[[1]]}' + String.fromCharCode(10) +
          '```' + String.fromCharCode(10) + 'Anything else.';
      final b = parseReply(src);
      expect(b.length, 3);
      expect(b[0].lang, isNull);
      expect(b[1].lang, 'table');
      expect(b[1].complete, isTrue);
      expect(b[2].lang, isNull);
      expect(b[2].text, contains('Anything else.'));
    });

    test('an unclosed card is incomplete, so the view waits instead of drawing it', () {
      final src = 'Working on it.' + String.fromCharCode(10) + '```summary' + String.fromCharCode(10) + '# Plan' + String.fromCharCode(10) + 'half a plan';
      final b = parseReply(src);
      expect(b.length, 2);
      expect(b.last.lang, 'summary');
      expect(b.last.complete, isFalse);
    });

    test('an ordinary code fence stays inside the text', () {
      final src = 'Run this:' + String.fromCharCode(10) + '```sh' + String.fromCharCode(10) + 'ls -la' + String.fromCharCode(10) + '```';
      final b = parseReply(src);
      expect(b.length, 1);
      expect(b.first.lang, isNull);
      expect(b.first.text, contains('ls -la'));
    });

    test('a line with only --- starts a new bubble', () {
      final src = 'First bubble.' + String.fromCharCode(10) + '---' + String.fromCharCode(10) + 'Second bubble.';
      final b = parseReply(src);
      expect(b.length, 2);
      expect(b.every((x) => x.lang == null), isTrue);
    });

    test('a code fence inside a card body does not cut the card in half', () {
      final lines = ['```summary', '# Title', '```sh', 'ls', '```', 'more', '```'];
      final b = parseReply(lines.join(String.fromCharCode(10)));
      expect(b.length, 1);
      expect(b.first.lang, 'summary');
      expect(b.first.complete, isTrue);
      expect(b.first.text, contains('ls'));
      expect(b.first.text, contains('more'));
    });
  });
}
