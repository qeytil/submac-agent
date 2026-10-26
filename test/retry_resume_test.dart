
// R2 item 2: "Try again" resumes from the failed point instead of sending the whole message again.
//
// Runner tests drive the real loop (send -> _runAgent -> Genkit core -> LlmClient) against a fake ai-chat: a task
// calls a tool, the next model call fails for good, and the user taps Try again (regenerate). Run:
// flutter test test/retry_resume_test.dart
// ignore_for_file: invalid_use_of_visible_for_testing_member, depend_on_referenced_packages
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent/app_state.dart';
import 'package:agent/models.dart';
import 'package:agent/services/llm_client.dart';
import 'package:agent/services/retry_plan.dart';
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
  _Call(this.events, {this.first = Duration.zero, this.gap = const Duration(milliseconds: 5), this.status = 200, this.finish = 'stop', this.code = 'busy'});
  final String code;
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
  final bodies = <Map<String, dynamic>>[];
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
        bodies.add(body);
        final c = script[calls.clamp(0, script.length - 1)];
        calls++;
        if (c.status != 200) {
          return http.StreamedResponse(Stream.value(utf8.encode(jsonEncode({'error': {'code': c.code, 'message': c.code}}))), c.status,
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
  s.repo.testUserId = 'u-retry-${tmp.path.hashCode}';
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


List<Map> _msgs(Map<String, dynamic> body) => (body['messages'] as List).cast<Map>();
String _text(Map m) {
  final c = m['content'];
  return c is String ? c : (c is List ? c.whereType<Map>().map((p) => '${p['text'] ?? ''}').join() : '');
}

const _ask = 'What is 2+2? Use the calculator.';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('retry'));
  tearDown(() async {
    LlmClient.testClient = http.Client();
    LlmClient.testHeaders = null;
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('runner: Try again after a failed step', () {
    test('keeps the finished tool step, makes only the failed call again, never re-sends the request as new', () async {
      final cloud = _Cloud([
        _toolCall('calculate', '{"expression":"2+2"}'),
        _Call([], status: 403, code: 'blocked'),
        _Call.text('It is 4.'),
      ]);
      final s = await _app(cloud, tmp);
      await s.send(_ask, const []);
      await _until(() => s.runs.isEmpty && cloud.calls >= 2);
      expect(s.messages.last.error, isNotNull, reason: 'the second step failed: ${s.messages.map((m) => '${m.role}:${m.content}:${m.error}').toList()}');
      final toolsBefore = s.messages.where((m) => m.role == 'tool').length;
      expect(toolsBefore, 1);
      await s.regenerate();
      await _until(() => s.runs.isEmpty);
      expect(cloud.calls, 3, reason: 'Try again restarted the task (the tool call was asked for again)');
      final retry = cloud.bodies.last;
      expect(_msgs(retry).where((m) => m['role'] == 'tool' && '${m['tool_call_id']}' == 'call_1'), isNotEmpty,
          reason: 'the finished tool result was not in the retried request');
      // (The app's step note at the end quotes the request every step, as on any multi-step task: not a user turn.)
      expect(_msgs(retry).where((m) => m['role'] == 'user' && _text(m).trim() == _ask).length, 1,
          reason: 'the user message is in it once: ${_msgs(retry).map((m) => '${m['role']}: ${_text(m).length > 200 ? _text(m).substring(_text(m).length - 200) : _text(m)}').toList()}');
      expect(s.messages.where((m) => m.role == 'user').length, 1);
      expect(s.messages.where((m) => m.role == 'tool').length, 1, reason: 'the tool did not run again');
      expect(s.messages.where((m) => m.error != null), isEmpty, reason: 'the failed bubble is gone');
      expect(s.messages.last.content, 'It is 4.');
    });

    test('Try again on a finished answer makes only that answer again (no tool runs again)', () async {
      final cloud = _Cloud([
        _toolCall('calculate', '{"expression":"2+2"}'),
        _Call.text('Four.'),
        _Call.text('It is 4.'),
      ]);
      final s = await _app(cloud, tmp);
      await s.send(_ask, const []);
      await _until(() => s.runs.isEmpty && cloud.calls >= 2);
      expect(s.messages.last.content, 'Four.');
      await s.regenerate();
      await _until(() => s.runs.isEmpty);
      expect(cloud.calls, 3);
      expect(s.messages.where((m) => m.role == 'tool').length, 1);
      expect(s.messages.where((m) => m.role == 'assistant' && (m.toolCalls?.isEmpty ?? true) && m.content.isNotEmpty).map((m) => m.content).toList(),
          ['It is 4.']);
    });

    test('a step that failed before any work: the same message is answered again, once', () async {
      final cloud = _Cloud([
        _Call([], status: 403, code: 'blocked'),
        _Call.text('Hello!'),
      ]);
      final s = await _app(cloud, tmp);
      await s.send('Hi', const []);
      await _until(() => s.runs.isEmpty && cloud.calls >= 1);
      await s.regenerate();
      await _until(() => s.runs.isEmpty);
      expect(cloud.calls, 2);
      expect(s.messages.map((m) => '${m.role}:${m.content}').toList(), ['user:Hi', 'assistant:Hello!']);
    });
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
