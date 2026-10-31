// R2 item 1: the live status line tells the agent's real state ("the indicator line of the progress is lying").
//
// The runner group drives the real task loop (send -> _runAgent -> Genkit core -> LlmClient) against a fake ai-chat
// that can hold its first byte, stream a tool call in two parts, or answer 503 once, and reads AgentRun.status at the
// moment it matters. The line group checks the words the screen shows (en/so/ar) and how the line reads a long wait.
//
// Run: flutter test test/run_status_test.dart
// ignore_for_file: invalid_use_of_visible_for_testing_member, depend_on_referenced_packages
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent/app_state.dart';
import 'package:agent/services/llm_client.dart';
import 'package:agent/ui/i18n.dart';
import 'package:agent/widgets/composer.dart';
import 'package:agent/widgets/chat/activity.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Docs extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Docs(this.dir);
  final String dir;
  @override
  Future<String?> getApplicationDocumentsPath() async => dir;
  @override
  Future<String?> getTemporaryPath() async => dir;
  @override
  Future<String?> getApplicationSupportPath() async => dir;
}

String _chunk(Map<String, dynamic> delta, {String? finish}) =>
    'data: ${jsonEncode({'choices': [{'index': 0, 'delta': delta, 'finish_reason': finish}]})}\n\n';

/// One scripted model call: wait [first] before anything, then send [events] with [gap] between them.
class _Call {
  _Call(this.events, {this.first = Duration.zero, this.gap = const Duration(milliseconds: 5), this.status = 200, this.finish = 'stop'});
  final List<Map<String, dynamic>> events;
  final Duration first, gap;
  final int status;
  final String finish;
  static _Call text(String t, {Duration first = Duration.zero}) => _Call([
        {'content': t}
      ], first: first);
}

class _Cloud {
  _Cloud(this.script);
  final List<_Call> script;
  var calls = 0;
  http.Client client() => MockClient.streaming((req, bodyStream) async {
        final body = jsonDecode(await bodyStream.bytesToString()) as Map<String, dynamic>;
        if (body['stream'] != true) {
          final plain = jsonEncode({
            'choices': [
              {'index': 0, 'message': {'role': 'assistant', 'content': 'Title'}, 'finish_reason': 'stop'}
            ]
          });
          return http.StreamedResponse(Stream.value(utf8.encode(plain)), 200, headers: {'content-type': 'application/json'});
        }
        final c = script[calls.clamp(0, script.length - 1)];
        calls++;
        if (c.status != 200) {
          return http.StreamedResponse(Stream.value(utf8.encode(jsonEncode({'error': {'code': 'busy', 'message': 'busy'}}))), c.status,
              headers: {'content-type': 'application/json', 'retry-after': '1'});
        }
        final ctrl = StreamController<List<int>>();
        () async {
          await Future<void>.delayed(c.first);
          for (final e in c.events) {
            await Future<void>.delayed(c.gap);
            if (ctrl.isClosed) return;
            ctrl.add(utf8.encode(_chunk(e)));
          }
          await Future<void>.delayed(c.gap);
          if (ctrl.isClosed) return;
          ctrl.add(utf8.encode(_chunk({}, finish: c.finish)));
          ctrl.add(utf8.encode('data: [DONE]\n\n'));
          await ctrl.close();
        }();
        return http.StreamedResponse(ctrl.stream, 200, headers: {'content-type': 'text/event-stream'});
      });
}

Future<void> _until(bool Function() ok, {int ms = 4000}) async {
  for (var i = 0; i < ms ~/ 5 && !ok(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<AppState> _app(_Cloud cloud, Directory tmp) async {
  SharedPreferences.setMockInitialValues({});
  PathProviderPlatform.instance = _Docs(tmp.path);
  LlmClient.testHeaders = (_) async => {'Content-Type': 'application/json'};
  LlmClient.testClient = cloud.client();
  final s = AppState();
  s.repo.testUserId = 'u-status-${tmp.path.hashCode}';
  await s.local.init();
  return s;
}

/// A tool call streamed in two parts: the name first, the arguments [gap] later.
_Call _toolCall(String name, String args, {Duration gap = const Duration(milliseconds: 5)}) => _Call([
      {
        'tool_calls': [
          {'index': 0, 'id': 'call_1', 'type': 'function', 'function': {'name': name, 'arguments': ''}}
        ]
      },
      {
        'tool_calls': [
          {'index': 0, 'function': {'arguments': args}}
        ]
      },
    ], gap: gap, finish: 'tool_calls');

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

  group('runner: the line follows real events', () {
    test('before the first byte it says it waits for a response (not a canned "Thinking")', () async {
      final cloud = _Cloud([_Call.text('Hello there.', first: const Duration(milliseconds: 600))]);
      final s = await _app(cloud, tmp);
      unawaited(s.send('Hi', const []));
      await _until(() => cloud.calls >= 1 && s.runs.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(s.runs.first.status, 'Waiting for a response');
      await _until(() => s.runs.isEmpty);
    });

    test('while the model writes a tool call, the line does not claim the tool is running', () async {
      final cloud = _Cloud([
        _toolCall('calculate', '{"expression":"2+2"}', gap: const Duration(milliseconds: 500)),
        _Call.text('It is 4.'),
      ]);
      final s = await _app(cloud, tmp);
      unawaited(s.send('What is 2+2? Use the calculator.', const []));
      await _until(() => cloud.calls >= 1 && s.runs.isNotEmpty);
      // The name has arrived, the arguments have not: the step is being prepared.
      await Future<void>.delayed(const Duration(milliseconds: 750));
      expect(s.runs.first.status, 'Preparing the next step');
      await _until(() => s.runs.isEmpty);
    });

    test('after a tool returns, the next request says "Thinking", not the finished tool nor a repeated "Waiting for a response"', () async {
      final cloud = _Cloud([
        _toolCall('calculate', '{"expression":"2+2"}'),
        _Call.text('It is 4.', first: const Duration(milliseconds: 700)),
      ]);
      final s = await _app(cloud, tmp);
      unawaited(s.send('What is 2+2? Use the calculator.', const []));
      await _until(() => cloud.calls >= 2);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(s.runs, isNotEmpty);
      expect(s.runs.first.status, 'Thinking');
      await _until(() => s.runs.isEmpty);
    });

    test('Stop: the line says it is stopping at once, not the last step', () async {
      final cloud = _Cloud([_Call.text('late', first: const Duration(milliseconds: 1500))]);
      final s = await _app(cloud, tmp);
      unawaited(s.send('Hi', const []));
      await _until(() => cloud.calls >= 1 && s.runs.isNotEmpty);
      final run = s.runs.first;
      s.stop();
      expect(run.status, 'Stopping');
      await _until(() => s.runs.isEmpty);
    });

    test('a failed call that is retried says so, with the attempt number', () async {
      final cloud = _Cloud([
        _Call([], status: 503),
        _Call.text('Back again.'),
      ]);
      final s = await _app(cloud, tmp);
      unawaited(s.send('Hi', const []));
      await _until(() => cloud.calls >= 1 && s.runs.isNotEmpty);
      final seen = <String>{};
      for (var i = 0; i < 300 && s.runs.isNotEmpty; i++) {
        seen.add(s.runs.first.statusEnglish);
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(seen.any((x) => x.startsWith('Connection problem. Retrying in') && x.endsWith('(1 of 1)')), isTrue, reason: 'seen: $seen');
      await _until(() => s.runs.isEmpty, ms: 5000);
    });
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
