// Stream, stop and steer regressions (PR-2 fix/stream-stop-steer): CB-1, CB-2, CB-10, CB-24, CB-30.
// The "probe" tests are the round-1/round-2 probes from test/zz_chat_bughunt_test.dart (CB-2, CB-10) and
// test/zz_chat_bughunt2_test.dart (CB-24), moved here with their assertions unchanged. The "runner" tests drive the real
// task loop (send -> _runAgent -> Genkit core -> LlmClient) against a fake ai-chat through LlmClient.testClient: a fake
// SSE stream that can stream slowly, stop with finish_reason=length, close without its end mark, or answer 413.
//
// Run: flutter test test/chat_regress_stream_test.dart
// ignore_for_file: invalid_use_of_visible_for_testing_member, depend_on_referenced_packages
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent/agent/core.dart';
import 'package:agent/agent/reply_schema.dart';
import 'package:agent/app_state.dart';
import 'package:agent/models.dart';
import 'package:agent/services/cloud.dart';
import 'package:agent/services/llm_client.dart';
import 'package:agent/services/paste_guard.dart';
import 'package:agent/ui/i18n.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ------------------------------------------------------------------ helpers

class _Hooks extends CoreHooks {
  final committed = <Reply>[];
  final stoppedWith = <Reply>[];
  String shownSoFar = '';
  bool stop = false;
  @override
  bool get cancelled => stop;
  @override
  Future<Turn> buildTurn(int step, String? notes) async => Turn(step: step, payload: const [
        {'role': 'user', 'content': 'hi'}
      ]);
  @override
  Future<void> commit(Reply r) async => committed.add(r);
  @override
  Future<String> runTool(ToolCall call, Map<String, dynamic> args, {Object? approved}) async => 'ok';
}

/// [_Hooks] that also reports what the screen showed, as the app's hooks do.
class _ShowingHooks extends _Hooks {
  @override
  String partialText() => shownSoFar;
  @override
  Future<void> onStopped(Reply r) async => stoppedWith.add(r);
}

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

const _done = 'data: [DONE]\n\n';

/// One scripted answer of the fake ai-chat.
class _Answer {
  _Answer(this.parts, {this.finish = 'stop', this.end = true, this.status = 200, this.body = '', this.gap = const Duration(milliseconds: 5)});

  /// Text pieces streamed one by one (a function gets the request's last user message).
  final List<Object> parts;
  final String? finish;

  /// false: the line closes after the parts with no finish_reason and no [DONE] (a cut stream).
  final bool end;
  final int status;
  final String body;
  final Duration gap;
}

/// A fake ai-chat for the whole task loop. Streamed agent calls take the scripted answers in order (the last one
/// repeats); other calls (title, summaries) get a short plain answer and are counted apart.
class _FakeCloud {
  _FakeCloud(this.script);
  final List<_Answer> script;
  final agentBodies = <Map<String, dynamic>>[];
  var other = 0;

  static String lastUser(Map<String, dynamic> body) {
    final msgs = (body['messages'] as List).cast<Map>();
    for (final m in msgs.reversed) {
      if (m['role'] != 'user') continue;
      final c = m['content'];
      final t = c is String ? c : (c is List ? c.whereType<Map>().map((p) => '${p['text'] ?? ''}').join() : '');
      // The app's own note for the step rides on the newest message; the user's words follow it.
      final at = t.lastIndexOf('</app-note>');
      return (at < 0 ? t : t.substring(at + '</app-note>'.length)).trim();
    }
    return '';
  }

  http.Client client() => MockClient.streaming((req, bodyStream) async {
        final raw = await bodyStream.bytesToString();
        final body = jsonDecode(raw) as Map<String, dynamic>;
        if (body['stream'] != true) {
          other++;
          final plain = jsonEncode({
            'choices': [
              {'index': 0, 'message': {'role': 'assistant', 'content': 'Somalia'}, 'finish_reason': 'stop'}
            ]
          });
          return http.StreamedResponse(Stream.value(utf8.encode(plain)), 200, headers: {'content-type': 'application/json'});
        }
        body['_bytes'] = raw.length;
        agentBodies.add(body);
        final a = script[(agentBodies.length - 1).clamp(0, script.length - 1)];
        if (a.status != 200) {
          return http.StreamedResponse(Stream.value(utf8.encode(a.body)), a.status, headers: {'content-type': 'application/json'});
        }
        final ctrl = StreamController<List<int>>();
        () async {
          ctrl.add(utf8.encode(': ping\n\n'));
          for (final p in a.parts) {
            await Future<void>.delayed(a.gap);
            final text = p is String Function(Map<String, dynamic>) ? p(body) : '$p';
            if (ctrl.isClosed) return;
            ctrl.add(utf8.encode(_chunk({'content': text})));
          }
          await Future<void>.delayed(a.gap);
          if (a.end) {
            ctrl.add(utf8.encode(_chunk({}, finish: a.finish)));
            ctrl.add(utf8.encode(_done));
          }
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

/// A signed-in (local) app with a fake cloud, ready to send in a new chat.
Future<AppState> _app(_FakeCloud cloud, Directory tmp) async {
  SharedPreferences.setMockInitialValues({});
  PathProviderPlatform.instance = _Docs(tmp.path);
  LlmClient.testHeaders = (_) async => {'Content-Type': 'application/json'};
  LlmClient.testClient = cloud.client();
  final s = AppState();
  s.repo.testUserId = 'u-stream-${tmp.path.hashCode}';
  await s.local.init();
  return s;
}

List<ChatMessage> _answers(AppState s) => [for (final m in s.messages) if (m.role == 'assistant' && m.content.trim().isNotEmpty) m];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('cbstream'));
  tearDown(() async {
    LlmClient.testClient = http.Client();
    LlmClient.testHeaders = null;
    AppLang.I.choice = 'phone';
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  // ================================================================== CB-1
  group('CB-1 a message sent while the final answer streams is answered', () {
    test('runner: a steer during the final stream gets a second answer that quotes it', () async {
      final cloud = _FakeCloud([
        _Answer(['Mogadishu ', 'is the ', 'capital ', 'of ', 'Somalia.'], gap: const Duration(milliseconds: 40)),
        _Answer([(Map<String, dynamic> b) => 'You asked: "${_FakeCloud.lastUser(b)}". About 2.6 million people.']),
      ]);
      final s = await _app(cloud, tmp);
      unawaited(s.send('What is the capital of Somalia?', const []));
      // The final answer is on screen and still streaming when the user writes again.
      await _until(() => s.messages.any((m) => m.role == 'assistant' && m.streaming && m.content.contains('is the')));
      expect(s.runs, isNotEmpty);
      await s.send('And how many people live there?', const []);
      await _until(() => s.runs.isEmpty && cloud.agentBodies.length >= 2, ms: 6000);
      await _until(() => s.runs.isEmpty, ms: 2000);
      final a = _answers(s);
      expect(a.map((m) => m.content).join('\n'), contains('Mogadishu is the capital of Somalia.'),
          reason: 'the first answer stays: ${a.map((m) => m.content).toList()}');
      expect(a.any((m) => m.content.contains('You asked: "And how many people live there?"')), isTrue,
          reason: 'the message sent during the final stream was never answered: ${a.map((m) => m.content).toList()}');
      expect(cloud.agentBodies.length, 2, reason: 'one extra model call answers the steer (no loop)');
      expect(s.messages.last.role, 'assistant', reason: 'the steer is answered after it, in order');
    });

    test('runner: the follow-on is capped (a steady stream of steers never loops)', () async {
      final cloud = _FakeCloud([
        _Answer(['Answer ', 'one ', 'two ', 'three.'], gap: const Duration(milliseconds: 30)),
      ]);
      final s = await _app(cloud, tmp);
      unawaited(s.send('Start', const []));
      // Every time a reply streams, another message arrives.
      var sent = 0;
      for (var i = 0; i < 1200 && sent < 30; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        final live = s.messages.any((m) => m.role == 'assistant' && m.streaming && m.content.isNotEmpty);
        // Two messages during every streamed answer.
        if (live && cloud.agentBodies.length * 2 > sent) {
          sent++;
          await s.send('more $sent', const []);
        }
      }
      await _until(() => s.runs.isEmpty, ms: 6000);
      expect(s.runs, isEmpty);
      // At most 3 extra answers inside a run, and at most 3 follow-on runs of 1 + 3 calls each.
      const most = 1 + AppStateAgentRunner.maxFollowOns + AppStateAgentRunner.maxFollowOns * (1 + AppStateAgentRunner.maxFollowOns);
      expect(sent, greaterThan(most), reason: 'the test must send more steers than the cap allows');
      expect(cloud.agentBodies.length, lessThanOrEqualTo(most), reason: 'steers chained ${cloud.agentBodies.length} model calls');
    });
  });

  // ================================================================== CB-2
  group('CB-2 Stop mid-answer erases the words already shown', () {
    test('probe: the turn committed after Stop keeps the text that had streamed', () async {
      final shown = StringBuffer(); // what the chat bubble showed (asst.content += delta in agent_stream.dart)
      final never = Completer<LlmResult>();
      final hooks = _Hooks();
      late AgentCore core;
      core = AgentCore(
        hooks: hooks,
        tools: const [],
        transport: (t) {
          shown.write('Here are the three cheapest flights to Nairobi: 1) ');
          return never.future; // still streaming
        },
      );
      final run = core.run();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      hooks.stop = true; // AgentRun.stop(): cancelled = true, then core.stop()
      core.stop();
      final res = await run;
      expect(res.end, RunEnd.cancelled);
      // _MainHooks.commit sets asst.content = r.text and removes the message when it is empty and the run is
      // cancelled (agent_runner.dart commit()). So whatever reaches commit is what the user keeps.
      final kept = hooks.committed.isEmpty ? shown.toString() : hooks.committed.last.text;
      expect(kept, isNotEmpty, reason: 'Stop replaced the streamed words with an empty reply, so the bubble is deleted');
    });

    test('core: a stopped call is not committed; the hooks get it with the words the screen showed', () async {
      final hooks = _ShowingHooks();
      final core = AgentCore(
        hooks: hooks,
        tools: const [],
        transport: (t) {
          hooks.shownSoFar = 'Here are the three cheapest flights to Nairobi: 1) ';
          return Completer<LlmResult>().future;
        },
      );
      final run = core.run();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      hooks.stop = true;
      core.stop();
      expect((await run).end, RunEnd.cancelled);
      expect(hooks.committed, isEmpty, reason: 'commit() with an empty text is what erased the bubble');
      expect(hooks.stoppedWith.single.text, 'Here are the three cheapest flights to Nairobi: 1) ');
    });

    test('runner: Stop keeps the streamed words, saved and marked stopped', () async {
      final cloud = _FakeCloud([
        _Answer(['Here are ', 'the three ', 'cheapest ', 'flights ', 'to Nairobi: ', '1) Daallo ', '2) Ethiopian ', '3) Kenya Airways'],
            gap: const Duration(milliseconds: 40)),
      ]);
      final s = await _app(cloud, tmp);
      unawaited(s.send('Find me cheap flights to Nairobi', const []));
      await _until(() => s.messages.any((m) => m.role == 'assistant' && m.content.contains('cheapest')));
      s.stop();
      await _until(() => s.runs.isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final a = _answers(s);
      expect(a, hasLength(1), reason: 'Stop deleted the words already on screen');
      expect(a.single.content, startsWith('Here are the three cheapest'));
      expect(a.single.stopped, isTrue);
      expect(a.single.streaming, isFalse);
      final saved = await s.repo.listMessages(s.currentId!);
      expect(saved.where((m) => m.id == a.single.id && m.content.startsWith('Here are the three cheapest')), isNotEmpty,
          reason: 'the kept words were not saved, so they vanish on the next open');
    });

    test('runner: Stop before any word leaves no empty bubble', () async {
      final cloud = _FakeCloud([
        _Answer(['late words'], gap: const Duration(milliseconds: 400)),
      ]);
      final s = await _app(cloud, tmp);
      unawaited(s.send('Hello', const []));
      await _until(() => cloud.agentBodies.isNotEmpty);
      s.stop();
      await _until(() => s.runs.isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(s.messages.where((m) => m.role == 'assistant'), isEmpty);
    });
  });

  // ================================================================== CB-10
  group('CB-10 a reply cut by the length limit continues in a second bubble with a broken table', () {
    test('probe: the continuation of a cut markdown table is neither repaired nor flagged', () {
      // First bubble (kept, cut off): "| Day | Plan |\n|---|---|\n| Mon | Beach |"; the continuation reply:
      const cont = '| Tue | Old town |\n| Wed | Museum |\n\nEnjoy the trip!';
      final fixed = ReplySchema.repair(cont);
      expect(fixed.contains('```table') || ReplySchema.problems(cont).isNotEmpty, isTrue,
          reason: 'rows without a header render as raw "| Tue | Old town |" text in a separate bubble');
    });

    test('runner: the continuation joins the cut reply in one message with one whole table', () async {
      final cloud = _FakeCloud([
        _Answer(['Your plan:\n\n', '| Day | Plan |\n', '|---|---|\n', '| Mon | Beach |\n'], finish: 'length'),
        _Answer(['| Tue | Old town |\n', '| Wed | Museum |\n', '\nEnjoy the trip!']),
      ]);
      final s = await _app(cloud, tmp);
      await s.send('Plan 3 days in Mogadishu as a table', const []);
      await _until(() => s.runs.isEmpty && cloud.agentBodies.length >= 2, ms: 5000);
      await _until(() => s.runs.isEmpty);
      final a = _answers(s);
      expect(a, hasLength(1), reason: 'the continuation is a second bubble: ${a.map((m) => m.content).toList()}');
      final text = a.single.content;
      expect(text, contains('```table'), reason: 'the joined table was not repaired into a table card: $text');
      final j = jsonDecode(RegExp(r'```table\n(.*)\n```').firstMatch(text)!.group(1)!) as Map;
      expect([for (final r in j['rows'] as List) (r as List).first], ['Mon', 'Tue', 'Wed']);
      expect(text, contains('Enjoy the trip!'));
      expect(text, isNot(contains('| Tue |')), reason: 'raw rows left in the reply');
      final saved = await s.repo.listMessages(s.currentId!);
      expect(saved.where((m) => m.role == 'assistant'), hasLength(1), reason: 'the half reply was saved as its own message');
    });

    test('problems(): headerless table rows are flagged, a real table or a single pipe line is not', () {
      expect(ReplySchema.problems('| a | b |\n| c | d |'), isNotEmpty);
      expect(ReplySchema.problems('Use the | key and the || operator.'), isEmpty);
      expect(ReplySchema.problems('| only | one row |'), isEmpty);
      expect(ReplySchema.problems('```\n| a | b |\n| c | d |\n```'), isEmpty, reason: 'inside a code block it is code');
    });
  });

  // ================================================================== CB-24
  group('CB-24 a reply stream that ends without finish_reason or [DONE] is taken as the whole answer', () {
    test('probe: half an answer followed by a closed connection is a drop, not a finished reply', () async {
      String chunk(Map<String, dynamic> d) => 'data: ${jsonEncode({'choices': [{'index': 0, 'delta': d, 'finish_reason': null}]})}\n\n';
      LlmClient.testHeaders = (_) async => {'Content-Type': 'application/json'};
      LlmClient.testClient = MockClient.streaming((req, body) async {
        final ctrl = StreamController<List<int>>();
        () async {
          ctrl.add(utf8.encode(': ping\n\n'));
          await Future<void>.delayed(Duration.zero);
          ctrl.add(utf8.encode(chunk({'content': 'Your 3-day plan:\n| Day | Plan |\n|---|---|\n| 1 | Arrive and '})));
          await Future<void>.delayed(Duration.zero);
          await ctrl.close(); // the line closes: no finish_reason, no [DONE] (proxy/gateway cut, radio switch)
        }();
        return http.StreamedResponse(ctrl.stream, 200, headers: {'content-type': 'text/event-stream'});
      });
      Object? err;
      LlmResult? r;
      try {
        r = await LlmClient().streamChat(provider: Cloud.provider, model: Cloud.submac, messages: const [
          {'role': 'user', 'content': 'plan my trip'}
        ], onDelta: (_) {});
      } catch (e) {
        err = e;
      }
      LlmClient.testHeaders = null;
      expect(err != null || (r?.cutOff ?? false), isTrue,
          reason: 'streamChat returned finish=${r?.finishReason} with "${r?.content}" as a complete reply: the runner saves it as the final '
              'answer (no drop retry, no cut-off continuation)');
    });

    test('the drop is retryable with code dropped; a finish_reason alone or [DONE] alone still ends a reply', () async {
      LlmClient.testHeaders = (_) async => {'Content-Type': 'application/json'};
      Future<Object> call(List<String> parts) async {
        LlmClient.testClient = MockClient.streaming((req, body) async =>
            http.StreamedResponse(Stream.fromIterable([for (final p in parts) utf8.encode(p)]), 200, headers: {'content-type': 'text/event-stream'}));
        try {
          return await LlmClient().streamChat(provider: Cloud.provider, model: Cloud.submac, messages: const [
            {'role': 'user', 'content': 'hi'}
          ], onDelta: (_) {});
        } catch (e) {
          return e;
        }
      }

      final cut = await call([_chunk({'content': 'Half'})]);
      expect(cut, isA<LlmException>());
      expect((cut as LlmException).code, 'dropped');
      expect(cut.isRetryable, isTrue);
      expect(cut.isFinal, isFalse);
      final fin = await call([_chunk({'content': 'Whole.'}), _chunk({}, finish: 'stop')]);
      expect((fin as LlmResult).content, 'Whole.');
      final done = await call([_chunk({'content': 'Whole.'}), _done]);
      expect((done as LlmResult).content, 'Whole.');
    });

    test('runner: a cut stream is sent again; the half answer stays on screen until the retry replaces it', () async {
      String? onScreenAtRetry;
      late AppState s;
      final cloud = _FakeCloud([
        _Answer(['Your 3-day plan: ', 'Day 1 arrive and '], end: false),
        _Answer([
          (Map<String, dynamic> b) {
            onScreenAtRetry ??= s.messages.lastWhere((m) => m.role == 'assistant', orElse: () => ChatMessage(id: '', role: 'assistant')).content;
            return 'Your 3-day plan: ';
          },
          'Day 1 the Lido beach. Day 2 the old town. Day 3 the market.',
        ]),
      ]);
      s = await _app(cloud, tmp);
      await s.send('Plan my 3 days in Mogadishu', const []);
      await _until(() => s.runs.isEmpty && cloud.agentBodies.length >= 2, ms: 5000);
      await _until(() => s.runs.isEmpty);
      expect(cloud.agentBodies.length, 2, reason: 'the cut stream was saved as the final answer instead of being sent again');
      expect(onScreenAtRetry, contains('Day 1 arrive and'), reason: 'the half answer disappeared before the retry had a word');
      final a = _answers(s);
      expect(a, hasLength(1));
      expect(a.single.content, 'Your 3-day plan: Day 1 the Lido beach. Day 2 the old town. Day 3 the market.');
    });
  });

  // ================================================================== CB-30
  group('CB-30 a too-long paste is uploaded 4 times and loses the summary', () {
    const tooLongBody = '{"error":{"code":"too_long","message":"This is too long to send in one go. Start a new chat or send less at once."}}';

    test('too_long is never re-sent as it is', () {
      final e = LlmException('x', status: 413, code: 'too_long');
      expect(e.isFinal, isTrue);
      expect(e.isRetryable, isFalse);
      expect(e.isTooLong, isTrue);
    });

    test('runner: a 413 for the user\'s own long paste is one upload and a reply in the app\'s language', () async {
      AppLang.I.choice = 'so';
      final cloud = _FakeCloud([_Answer(const [], status: 413, body: tooLongBody)]);
      final s = await _app(cloud, tmp);
      final paste = 'Warbixinta sanadlaha ah. ${'Qoraal dheer oo la soo koobayo. ' * 9000}'; // ~300k characters, under the 480k guard
      expect(PasteGuard.tooBig(paste), isFalse);
      await s.send(paste, const []);
      await _until(() => s.runs.isEmpty && cloud.agentBodies.isNotEmpty, ms: 5000);
      await _until(() => s.runs.isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(cloud.agentBodies.length, 1, reason: 'the same too-long request was uploaded ${cloud.agentBodies.length} times');
      final last = s.messages.last;
      expect(last.role, 'assistant');
      expect(last.error, isNull, reason: 'a "This chat got too long / start a new chat" error instead of the way forward');
      expect(last.content, PasteGuard.tooLongReply(PasteGuard.kbOf(paste), lang: 'so'));
      expect(last.content, contains('fayl'));
    });

    test('runner: a 600 KB paste is stopped before the network; "Attach as a file" sends it as a file', () async {
      final cloud = _FakeCloud([
        _Answer([(Map<String, dynamic> b) => 'Got the file. ${_FakeCloud.lastUser(b).contains('pasted-') ? 'It is attached.' : 'No file!'}']),
      ]);
      final s = await _app(cloud, tmp);
      final paste = 'Meeting notes. ${'The team agreed on the plan and the budget. ' * 14000}'; // ~600k characters
      expect(PasteGuard.tooBig(paste), isTrue);
      final sending = s.send(paste, const []);
      await _until(() => s.asks.isNotEmpty);
      expect(cloud.agentBodies, isEmpty, reason: 'the paste went to the network');
      final ask = s.asks.single;
      expect(ask.options, [PasteGuard.attachOption(), PasteGuard.partsOption()]);
      s.answerAsk(ask, {'answer': PasteGuard.attachOption()});
      await sending;
      await _until(() => s.runs.isEmpty && cloud.agentBodies.isNotEmpty, ms: 5000);
      await _until(() => s.runs.isEmpty);
      expect(cloud.agentBodies, hasLength(1));
      expect(cloud.agentBodies.single['_bytes'] as int, lessThan(200 * 1024), reason: 'the whole paste was still uploaded');
      final mine = s.messages.firstWhere((m) => m.role == 'user');
      expect(mine.attachments.single.name, startsWith('pasted-'));
      expect(mine.content.length, lessThan(300));
      expect(_answers(s).last.content, contains('It is attached.'));
    });

    test('runner: dismissing the question sends nothing and keeps the text as a file', () async {
      final cloud = _FakeCloud([_Answer(['x'])]);
      final s = await _app(cloud, tmp);
      final sending = s.send('x' * (PasteGuard.maxChars + 10), const []);
      await _until(() => s.asks.isNotEmpty);
      s.answerAsk(s.asks.single, null);
      await sending;
      expect(cloud.agentBodies, isEmpty);
      expect(s.banner, contains('pasted-'));
    });

    test('the Somali and Arabic words exist for every line', () {
      for (final l in ['en', 'so', 'ar']) {
        expect(PasteGuard.title(lang: l), isNotEmpty);
        expect(PasteGuard.prompt(600, lang: l), contains('600'));
        expect(PasteGuard.tooLongReply(600, lang: l), contains('600'));
        expect(PasteGuard.notSent('a.txt', lang: l), contains('a.txt'));
      }
      expect(PasteGuard.title(lang: 'so'), isNot(PasteGuard.title(lang: 'en')));
      expect(PasteGuard.title(lang: 'ar'), isNot(PasteGuard.title(lang: 'en')));
    });
  });
}
