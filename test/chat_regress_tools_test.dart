// Agent tool regressions (PR-4 fix/agent-tools): CB-3, CB-38, CB-39.
// CB-3: a tool name the run does not have (gpt-oss `web_search<|channel|>commentary`, `functions.x`, a made-up name, a
// name written as text) is mapped in the model adapter: cleaned to the real tool, or answered by the `unknown_tool`
// stub, so Genkit never fails the run with NOT_FOUND. A model that keeps calling unknown tools stops on its own (the
// emulator run 40207082061 re-sent the same request every 2 s until it was killed after 150 s).
// CB-38: Wikipedia-only search results are labelled; weak searches and read-only browser tasks have a per-task budget.
// CB-39: a file card with a few words, for a request that never asked for a file, goes back once to be answered inline.
// The "runner" tests drive the real task loop (send -> _runAgent -> Genkit core -> LlmClient) against a fake ai-chat
// through LlmClient.testClient.
//
// Run: flutter test test/chat_regress_tools_test.dart
// ignore_for_file: invalid_use_of_visible_for_testing_member, depend_on_referenced_packages
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent/agent/core.dart';
import 'package:agent/app_state.dart';
import 'package:agent/models.dart';
import 'package:agent/services/answer_inline.dart';
import 'package:agent/services/doc_maker.dart';
import 'package:agent/services/llm_client.dart';
import 'package:agent/services/search_budget.dart';
import 'package:agent/services/web_tools.dart';
import 'package:agent/ui/i18n.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ------------------------------------------------------------------ helpers

class _Hooks extends CoreHooks {
  final ran = <String>[];
  final results = <String, String>{};
  @override
  bool get cancelled => false;
  @override
  Future<Turn> buildTurn(int step, String? notes) async => Turn(step: step, payload: const [
        {'role': 'user', 'content': 'hi'}
      ]);
  @override
  Future<String> runTool(ToolCall call, Map<String, dynamic> args, {Object? approved}) async {
    ran.add(call.name);
    return '${call.name} ok';
  }

  @override
  Future<void> toolDone(ToolCall call, Map<String, dynamic> args, String output) async => results[call.name] = output;
}

Map<String, dynamic> _def(String name) => {
      'type': 'function',
      'function': {'name': name, 'description': name, 'parameters': {'type': 'object', 'properties': {}}},
    };

AgentCore _core(_Hooks h, Future<LlmResult> Function(int call) answer, {List<String> tools = const ['web_search', 'fetch_url']}) {
  var n = 0;
  return AgentCore(hooks: h, tools: [for (final t in tools) _def(t)], transport: (t) async => answer(++n));
}

LlmResult _call(String name, [Map<String, dynamic> args = const {}]) =>
    LlmResult('', [ToolCall(id: 'c${name.hashCode}', name: name, arguments: jsonEncode(args))], 'tool_calls');

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

/// One answer of the fake ai-chat: text, or tool calls (name, arguments).
class _Say {
  _Say.text(this.text) : calls = const [];
  _Say.calls(this.calls) : text = '';
  _Say.both(this.text, this.calls);
  final String text;
  final List<(String, Map<String, dynamic>)> calls;
}

/// A fake ai-chat: streamed agent calls take the scripted answers in order (the last one repeats); other calls (title,
/// summaries) get a short plain answer.
class _FakeCloud {
  _FakeCloud(this.script);
  final List<_Say> script;
  final agentRaw = <String>[];

  http.Client client() => MockClient.streaming((req, bodyStream) async {
        final raw = await bodyStream.bytesToString();
        final body = jsonDecode(raw) as Map<String, dynamic>;
        if (body['stream'] != true) {
          final plain = jsonEncode({
            'choices': [
              {'index': 0, 'message': {'role': 'assistant', 'content': 'Chat'}, 'finish_reason': 'stop'}
            ]
          });
          return http.StreamedResponse(Stream.value(utf8.encode(plain)), 200, headers: {'content-type': 'application/json'});
        }
        agentRaw.add(raw);
        final a = script[(agentRaw.length - 1).clamp(0, script.length - 1)];
        final n = agentRaw.length;
        final out = StringBuffer(': ping\n\n');
        if (a.calls.isEmpty) {
          out.write(_chunk({'content': a.text}));
          out.write(_chunk({}, finish: 'stop'));
        } else {
          if (a.text.isNotEmpty) out.write(_chunk({'content': a.text}));
          for (var i = 0; i < a.calls.length; i++) {
            out.write(_chunk({
              'tool_calls': [
                {
                  'index': i,
                  'id': 'call_${n}_$i',
                  'type': 'function',
                  'function': {'name': a.calls[i].$1, 'arguments': jsonEncode(a.calls[i].$2)}
                }
              ]
            }));
          }
          out.write(_chunk({}, finish: 'tool_calls'));
        }
        out.write('data: [DONE]\n\n');
        return http.StreamedResponse(Stream.value(utf8.encode(out.toString())), 200, headers: {'content-type': 'text/event-stream'});
      });
}

Future<void> _until(bool Function() ok, {int ms = 4000}) async {
  for (var i = 0; i < ms ~/ 10 && !ok(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<AppState> _app(_FakeCloud cloud, Directory tmp) async {
  SharedPreferences.setMockInitialValues({});
  PathProviderPlatform.instance = _Docs(tmp.path);
  LlmClient.testHeaders = (_) async => {'Content-Type': 'application/json'};
  LlmClient.testClient = cloud.client();
  final s = AppState();
  s.repo.testUserId = 'u-tools-${tmp.path.hashCode}';
  await s.local.init();
  return s;
}

/// DuckDuckGo (both pages) fails; Wikipedia answers. [wikiHits] false: Wikipedia finds nothing either.
http.Client _ddgDown({bool wikiHits = true}) => MockClient((req) async {
      if (req.url.host.contains('duckduckgo')) return http.Response('<html><body>blocked</body></html>', 200);
      if (req.url.host.contains('wikipedia')) {
        return http.Response(
            jsonEncode({
              'query': {
                'search': wikiHits
                    ? [
                        {'title': 'Samsung Galaxy S25', 'snippet': 'The <b>Galaxy S25</b> is a smartphone'}
                      ]
                    : []
              }
            }),
            200,
            headers: {'content-type': 'application/json'});
      }
      return http.Response('not here', 404);
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('cbtools'));
  tearDown(() async {
    LlmClient.testClient = http.Client();
    LlmClient.testHeaders = null;
    WebTools.braveKey = '';
    WebTools.tavilyKey = '';
    AppLang.I.choice = 'phone';
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  // ================================================================== CB-3
  group('CB-3 a tool name the app does not have', () {
    test('probe: gpt-oss `name<|channel|>commentary` runs the real tool; the task goes on', () async {
      final h = _Hooks();
      var calls = 0;
      final r = await _core(h, (n) async {
        calls = n;
        // The round-1 probe name, zero-width space included.
        if (n == 1) return _call('web_search<\u200B|channel|>commentary', {'query': 'x'});
        return LlmResult('Here is what I found.', const [], 'stop');
      }).run();
      // Old code: RunEnd.failed with "GenkitException: Tool web_search<|channel|>commentary not found (NOT_FOUND)".
      expect(r.end, RunEnd.done, reason: '${r.error}');
      expect(calls, 2);
      expect(h.ran, ['web_search']);
    });

    test('`functions.` and `default_api.` prefixes are stripped', () async {
      final h = _Hooks();
      final r = await _core(h, (n) async {
        if (n == 1) return _call('functions.web_search', {'query': 'x'});
        if (n == 2) return _call('default_api.fetch_url', {'url': 'https://example.com'});
        return LlmResult('Done.', const [], 'stop');
      }).run();
      expect(r.end, RunEnd.done, reason: '${r.error}');
      expect(h.ran, ['web_search', 'fetch_url']);
    });

    test('a made-up name gets an error result the model can read; nothing runs, the task goes on', () async {
      final h = _Hooks();
      final r = await _core(h, (n) async {
        if (n == 1) return _call('browser.search', {'q': 'x'});
        return LlmResult('Answered without it.', const [], 'stop');
      }).run();
      expect(r.end, RunEnd.done, reason: '${r.error}');
      expect(r.reply?.text, 'Answered without it.');
      expect(h.ran, isEmpty, reason: 'the app never runs an unknown tool');
      expect(h.results[ToolNames.unknown], 'Error: there is no tool named "browser.search". Use one of the tools you were given.');
    });

    test('a tool call written as text with an unknown name does not end the task', () async {
      final h = _Hooks();
      final r = await _core(h, (n) async {
        if (n == 1) return LlmResult('<tool_call>{"name": "python", "arguments": {"code": "1+1"}}</tool_call>', const [], 'stop');
        return LlmResult('2', const [], 'stop');
      }).run();
      expect(r.end, RunEnd.done, reason: '${r.error}');
      expect(h.results[ToolNames.unknown], contains('"python"'));
    });

    test('a known call next to an unknown one: the known one runs', () async {
      final h = _Hooks();
      final r = await _core(h, (n) async {
        if (n == 1) {
          return LlmResult('', [
            ToolCall(id: 'a', name: 'nope_tool', arguments: '{}'),
            ToolCall(id: 'b', name: 'web_search', arguments: '{"query":"x"}'),
          ], 'tool_calls');
        }
        return LlmResult('ok', const [], 'stop');
      }).run();
      expect(r.end, RunEnd.done, reason: '${r.error}');
      expect(h.ran, ['web_search']);
    });

    test('a model that only ever calls an unknown tool stops on its own after 3 replies', () async {
      final h = _Hooks();
      var calls = 0;
      final r = await _core(h, (n) async {
        calls = n;
        return _call('look_up<|channel|>commentary', {'query': 'x'});
      }).run().timeout(const Duration(seconds: 10));
      expect(r.end, RunEnd.halted);
      expect(calls, ToolNames.maxUnknownTurns);
      expect(r.error, isNull);
    });

    test('backstop: Genkit NOT_FOUND is never a dropped line (not retried)', () {
      expect(ToolNames.isMissingTool(AgentCore.causeOf(Exception('x'))), isFalse);
      expect(ToolNames.clean('web_search<\u200B|channel|>commentary'), 'web_search');
      expect(ToolNames.clean('functions.default_api.read_file'), 'read_file');
      expect(ToolNames.resolve(ToolCall(id: 'x', name: 'zzz', arguments: '{}'), {'a'}).name, ToolNames.unknown);
    });

    test('runner: an unknown tool every time ends the run on its own (no re-send loop), with a plain message', () async {
      // Emulator run 40207082061: the app re-sent the same request every 2 s until the harness stopped it at 150 s.
      final cloud = _FakeCloud([
        _Say.calls([('search_web<|channel|>commentary', {'query': 'weather'})]),
        _Say.calls([('browser.search', {'q': 'weather'})]),
        _Say.calls([('python', {'code': '1'})]),
      ]);
      final s = await _app(cloud, tmp);
      final t0 = DateTime.now();
      unawaited(s.send('What is the weather in Mogadishu?', const []));
      await _until(() => s.runs.isNotEmpty, ms: 2000);
      await _until(() => s.runs.isEmpty, ms: 12000);
      final took = DateTime.now().difference(t0);
      final stillRunning = s.runs.isNotEmpty;
      for (final r in [...s.runs]) {
        s.stopRun(r);
      }
      expect(stillRunning, isFalse, reason: 'the run never ended on its own (${cloud.agentRaw.length} model calls in $took)');
      expect(cloud.agentRaw.length, ToolNames.maxUnknownTurns, reason: 'one model call per reply, never the same request again');
      expect(took.inSeconds, lessThan(10));
      final errs = [for (final m in s.messages) if (m.error != null) m.error!];
      expect(errs.where((e) => e.contains('GenkitException') || e.contains('NOT_FOUND')), isEmpty, reason: '$errs');
      expect(s.banner, ToolNames.stopText);
      // The model was told, in the request after each unknown call, that the tool does not exist.
      expect(cloud.agentRaw[1], contains('there is no tool named'));
    });

    test('CB-42: the unknown-tool stop leaves a short visible reply in the chat, not just a banner', () async {
      // Emulator run 40222543795 (CB-42): more_tools, skill_use, then guessed names until the stop; the chat stayed empty.
      final cloud = _FakeCloud([
        _Say.calls([('email_send_draft', {'to': 'ali@example.com'})]),
        _Say.calls([('functions.compose_mail', {'to': 'ali@example.com'})]),
        _Say.calls([('gmail.create_draft', {'to': 'ali@example.com'})]),
      ]);
      final s = await _app(cloud, tmp);
      unawaited(s.send('Write an email to ali@example.com saying I will be 10 minutes late', const []));
      await _until(() => s.runs.isNotEmpty, ms: 2000);
      await _until(() => s.runs.isEmpty, ms: 12000);
      expect(s.runs, isEmpty);
      expect(cloud.agentRaw.length, ToolNames.maxUnknownTurns);
      final visible = [for (final m in s.messages) if (m.role == 'assistant' && m.error == null && m.content.trim().isNotEmpty) m.content];
      expect(visible, [ToolNames.stopReply], reason: 'CB-42: the user must get one short reply, never nothing');
      expect(ToolNames.stopReply.length, lessThan(160));
      expect(s.banner, ToolNames.stopText, reason: 'the banner stays as it was');
    });

    test('CB-42: no extra reply when the run already said something before the stop', () async {
      // Words next to the unknown calls are the visible reply; nothing is added after the stop.
      final cloud = _FakeCloud([
        _Say.both('Let me check that for you.', [('lookup_thing', {'q': 'weather'})]),
        _Say.calls([('lookup_thing', {'q': 'weather'})]),
      ]);
      final s = await _app(cloud, tmp);
      unawaited(s.send('What is the weather in Mogadishu?', const []));
      await _until(() => s.runs.isNotEmpty, ms: 2000);
      await _until(() => s.runs.isEmpty, ms: 12000);
      expect(s.runs, isEmpty);
      expect(cloud.agentRaw.length, ToolNames.maxUnknownTurns);
      final visible = [for (final m in s.messages) if (m.role == 'assistant' && m.error == null && m.content.trim().isNotEmpty) m.content];
      expect(visible.join(' '), contains('Let me check that for you.'));
      expect(visible, isNot(contains(ToolNames.stopReply)));
    });

    test('runner: an unknown tool once, then an answer: the user gets the answer', () async {
      final cloud = _FakeCloud([
        _Say.calls([('functions.nope', {})]),
        _Say.text('It is sunny in Mogadishu today.'),
      ]);
      final s = await _app(cloud, tmp);
      unawaited(s.send('Weather in Mogadishu?', const []));
      await _until(() => s.runs.isNotEmpty, ms: 2000);
      await _until(() => s.runs.isEmpty, ms: 8000);
      expect(s.runs, isEmpty);
      expect(cloud.agentRaw.length, 2);
      expect(s.messages.where((m) => m.role == 'assistant').last.content, 'It is sunny in Mogadishu today.');
      expect(s.messages.any((m) => m.error != null), isFalse);
    });
  });

  // ================================================================== CB-38
  group('CB-38 web search without a key', () {
    test('Wikipedia-only results are labelled "web search unavailable"', () async {
      final out = await http.runWithClient(() => WebTools.webSearch('galaxy s25 price', 5), () => _ddgDown());
      final j = jsonDecode(out) as Map;
      // Old code: {"engine":"Wikipedia","results":[...],"note":"Show the sources..."} with no warning.
      expect(j['engine'], 'Wikipedia');
      expect(j['warning'], WebTools.wikiOnlyWarning);
      expect('${j['warning']}', startsWith('Web search unavailable; these are encyclopedia results only'));
      expect(SearchBudget.isWeak(out), isTrue);
    });

    test('a search that works is not weak and not labelled', () {
      final ok = jsonEncode({
        'query': 'q',
        'engine': 'DuckDuckGo',
        'results': [
          {'title': 't', 'url': 'https://a.com', 'snippet': 's'}
        ]
      });
      expect(SearchBudget.isWeak(ok), isFalse);
      expect(SearchBudget.isWeak('Error: web search found nothing. Try different words.'), isTrue);
    });

    test('after 2 weak searches the model is told to use fetch_url or answer', () {
      final b = SearchBudget();
      const wiki = '{"query":"q","engine":"Wikipedia","results":[]}';
      expect(b.after('web_search', wiki), wiki, reason: 'the first weak search passes as it is');
      expect(b.after('web_search', wiki), endsWith(SearchBudget.stopSearchingNote));
      expect(b.after('web_search', 'Error: web search found nothing'), contains('fetch_url'));
      final good = jsonEncode({
        'engine': 'DuckDuckGo',
        'results': [
          {'title': 't'}
        ]
      });
      expect(b.after('web_search', good), good, reason: 'a search that worked never carries the note');
      expect(b.after('fetch_url', 'Error: x'), 'Error: x');
    });

    test('read-only browser_tasks run three times per task (core loop v3); tasks that act are not capped', () {
      final b = SearchBudget();
      expect(b.before('browser_task', {'goal': 'Find the price of the Galaxy S25 on samsung.com'}), isNull);
      expect(b.before('browser_task', {'goal': 'Look up the S25 price on another shop'}), isNull);
      expect(b.before('browser_task', {'goal': 'Look up the S25 price on a third shop'}), isNull);
      expect(b.before('browser_task', {'goal': 'Look up the S25 price on a fourth shop'}), SearchBudget.browserCapText);
      expect(b.before('browser_task', {'goal': 'Sign in to my bank and download the statement'}), isNull);
      expect(b.before('browser_task', {'goal': 'Book a table for two at 8pm'}), isNull);
      expect(b.before('web_search', {'query': 'x'}), isNull);
    });

    test('runner: from the second weak search in a task, results carry the stop note to the model', () async {
      final cloud = _FakeCloud([
        _Say.calls([('web_search', {'query': 'galaxy s25 price'})]),
        _Say.calls([('web_search', {'query': 'galaxy s25 price usd'})]),
        _Say.calls([('web_search', {'query': 'galaxy s25 cost'})]),
        _Say.text('I could not check live prices; the S25 launched at about 800 USD.'),
      ]);
      await http.runWithClient(() async {
        final s = await _app(cloud, tmp);
        unawaited(s.send('How much is the Galaxy S25?', const []));
        await _until(() => s.runs.isNotEmpty, ms: 2000);
        await _until(() => s.runs.isEmpty, ms: 15000);
        for (final r in [...s.runs]) {
          s.stopRun(r);
        }
        final tools = [for (final m in s.messages) if (m.role == 'tool' && m.name == 'web_search') m.content];
        expect(tools.length, 3, reason: '${s.messages.map((m) => '${m.role}:${m.name}').toList()}');
        expect(tools[0], contains(WebTools.wikiOnlyWarning));
        expect(tools[0], isNot(contains('Do not search again')));
        expect(tools[1], contains('Do not search again'));
        expect(tools[2], contains('Do not search again'));
      }, () => _ddgDown());
    });
  });

  // ================================================================== CB-39
  group('CB-39 long answers come back only as files', () {
    const card = '```file\n/data/user/0/app/files/workspace/Muqdisho.docx\n```';

    test('gate: a file card and a few words, for a request that asked for no file, goes back once', () {
      const ask = 'Write 500 words in Somali about Mogadishu, not in a file.';
      expect(InlineAnswer.needsInline(reply: 'Halkan waa qoraalka.\n$card', userText: ask, rounds: 0), isTrue);
      expect(InlineAnswer.needsInline(reply: 'Halkan waa qoraalka.\n$card', userText: ask, rounds: 1), isFalse, reason: 'one fix round');
      final long = List.filled(60, 'erey').join(' ');
      expect(InlineAnswer.needsInline(reply: '$long\n$card', userText: ask, rounds: 0), isFalse, reason: 'the answer is in the chat');
      expect(InlineAnswer.needsInline(reply: 'Short answer.', userText: ask, rounds: 0), isFalse, reason: 'no file card');
    });

    test('gate: a request for a file is left alone (English, Somali, Arabic)', () {
      for (final ask in [
        'Make me a CV as a PDF',
        'Put this in a Word document',
        'Export the list to Excel',
        'Ii samee fayl ah',
        'اكتب لي ملف عن مقديشو',
        'Save it as notes.txt',
      ]) {
        expect(InlineAnswer.needsInline(reply: 'Here it is.\n$card', userText: ask, rounds: 0), isFalse, reason: ask);
      }
      expect(InlineAnswer.askedForFile('اكتب 400 كلمة بالعربية عن البحر'), isFalse);
      expect(InlineAnswer.askedForFile('Write it here, not in a file'), isFalse);
      expect(InlineAnswer.askedForFile("Don't make a PDF, just answer"), isFalse);
    });

    test('make_document says: only when the user asks for a file', () {
      final d = DocMaker.definitions.firstWhere((e) => e['function']['name'] == 'make_document');
      final desc = '${d['function']['description']}';
      // Old code: "Use for CVs, cover letters, invoices, ... reports, proposals, letters ..." with no such limit.
      expect(desc, contains('Only when the user asks for a file'));
      expect(desc, contains('write the answer in the chat'));
    });

    test('runner: a file-only reply gets one round to answer in the chat', () async {
      final essay = List.filled(70, 'Muqdisho waa caasimadda Soomaaliya.').join(' ');
      final cloud = _FakeCloud([
        _Say.text('Halkan waa qoraalka.\n$card'),
        _Say.text(essay),
      ]);
      final s = await _app(cloud, tmp);
      unawaited(s.send('Write 500 words in Somali about Mogadishu.', const []));
      await _until(() => s.runs.isNotEmpty, ms: 2000);
      await _until(() => s.runs.isEmpty, ms: 8000);
      // Old code: 1 model call; the chat ends with the file card and four words.
      expect(cloud.agentRaw.length, 2);
      expect(cloud.agentRaw[1], contains('Answer in the chat'));
      final last = s.messages.lastWhere((m) => m.role == 'assistant' && m.content.trim().isNotEmpty);
      expect(last.content, essay);
    });
  });
}
