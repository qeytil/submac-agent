
// R2 item 2: "Try again" resumes from the failed point instead of sending the whole message again.
//
// Runner tests drive the real loop (send -> _runAgent -> Genkit core -> LlmClient) against a fake ai-chat: a task
// calls a tool, the next model call fails for good, and the user taps Try again (regenerate). Run:
// flutter test test/retry_resume_test.dart
// ignore_for_file: invalid_use_of_visible_for_testing_member, depend_on_referenced_packages
import 'dart:io';

import 'package:agent/models.dart';
import 'package:agent/services/llm_client.dart';
import 'package:agent/services/retry_plan.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;











void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('retry'));
  tearDown(() async {
    LlmClient.testClient = http.Client();
    LlmClient.testHeaders = null;
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });


  group('plan', () {
    ChatMessage calls(String id, List<ToolCall> c) => ChatMessage(id: id, role: 'assistant', content: '')..toolCalls = c;
    test('no work in the turn: only answers go, nothing to resume', () {
      final err = ChatMessage(id: 'a', role: 'assistant', content: '')..error = 'busy';
      final p = RetryPlan.of([err]);
      expect(p.resume, isFalse);
      expect(p.remove, [err]);
    });

    test('finished steps stay; the failed bubble after them goes', () {
      final t = [
        calls('a1', [ToolCall(id: 'c1', name: 'web_search', arguments: '{}')]),
        ChatMessage(id: 't1', role: 'tool', content: 'results', toolCallId: 'c1', name: 'web_search'),
        ChatMessage(id: 'a2', role: 'assistant', content: 'Here is wh')..error = 'dropped',
      ];
      final p = RetryPlan.of(t);
      expect(p.resume, isTrue);
      expect(p.remove.map((m) => m.id), ['a2']);
      expect(p.settle, isEmpty);
    });

    test('a call with no result is settled, a send as unknown (never repeated blindly)', () {
      final send = ToolCall(id: 'c2', name: 'email_send', arguments: '{}');
      final read = ToolCall(id: 'c3', name: 'web_search', arguments: '{}');
      final p = RetryPlan.of([calls('a1', [send, read])]);
      expect(p.resume, isTrue);
      expect(p.settle[send], startsWith('Unknown:'));
      expect(p.settle[read], startsWith('Not finished:'));
      expect(RetryPlan.note(settled: 2), contains('do not start over'));
    });
  });
}
