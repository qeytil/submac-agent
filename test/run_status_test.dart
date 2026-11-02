// R2 item 1: the live status line tells the agent's real state ("the indicator line of the progress is lying").
//
// The runner group drives the real task loop (send -> _runAgent -> Genkit core -> LlmClient) against a fake ai-chat
// that can hold its first byte, stream a tool call in two parts, or answer 503 once, and reads AgentRun.status at the
// moment it matters. The line group checks the words the screen shows (en/so/ar) and how the line reads a long wait.
//
// Run: flutter test test/run_status_test.dart
// ignore_for_file: invalid_use_of_visible_for_testing_member, depend_on_referenced_packages
import 'dart:io';

import 'package:agent/app_state.dart';
import 'package:agent/services/llm_client.dart';
import 'package:agent/ui/i18n.dart';
import 'package:agent/widgets/composer.dart';
import 'package:agent/widgets/chat/activity.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;








void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('runstatus'));
  tearDown(() async {
    LlmClient.testClient = http.Client();
    LlmClient.testHeaders = null;
    AppLang.I.choice = 'phone';
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });


  group('line: words on screen', () {
    test('every phase and step label has Somali and Arabic words', () {
      final missing = <String>[];
      for (final lang in ['so', 'ar']) {
        AppLang.I.choice = lang;
        for (final k in [...RunStatus.phaseKeys, ...RunStatus.toolKeys]) {
          if (tr(k) == k) missing.add('$lang: $k');
        }
      }
      AppLang.I.choice = 'phone';
      expect(missing, isEmpty);
    });

    test('the line is in the app language, holes filled', () {
      final run = AgentRun(convId: 'c', side: false, title: 't');
      run.show(RunPhase.retrying, RunStatus.retryIn, {'n': '3', 'i': '1', 'm': '1'});
      AppLang.I.choice = 'ar';
      expect(WorkingLine.lineFor(run), 'مشكلة في الاتصال. إعادة المحاولة خلال 3 ث (1 من 1)');
      AppLang.I.choice = 'en';
      expect(WorkingLine.lineFor(run, more: 2), 'Connection problem. Retrying in 3s (1 of 1)  ·  2 more');
    });

    test('a long silence is said honestly; a tool line never changes by itself', () {
      final run = AgentRun(convId: 'c', side: false, title: 't');
      AppLang.I.choice = 'en';
      run.show(RunPhase.waiting, RunStatus.waiting);
      final t0 = run.statusAt;
      expect(WorkingLine.lineFor(run, now: t0.add(const Duration(seconds: 3))), 'Waiting for a response');
      expect(WorkingLine.lineFor(run, now: t0.add(const Duration(seconds: 9))), 'Still waiting for a response');
      expect(WorkingLine.lineFor(run, now: t0.add(const Duration(seconds: 30))), 'The response is taking longer than usual');
      run.show(RunPhase.tool, 'Reading a file');
      expect(WorkingLine.lineFor(run, now: run.statusAt.add(const Duration(seconds: 60))), 'Reading a file');
      expect(WorkingLine.lineFor(null), 'Sending your message');
    });

    test('writing on screen overrides a waiting line, never a tool or Stop', () {
      final run = AgentRun(convId: 'c', side: false, title: 't');
      AppLang.I.choice = 'en';
      run.show(RunPhase.waiting, RunStatus.waiting);
      expect(WorkingLine.lineFor(run, writing: true), 'Writing the reply');
      run.show(RunPhase.tool, 'Reading a file');
      expect(WorkingLine.lineFor(run, writing: true), 'Reading a file');
      run.stop();
      expect(WorkingLine.lineFor(run, writing: true), 'Stopping');
      expect(WorkingLine.kindOf(run), ActivityKind.working);
    });
  });
}
