// Bug hunt, round 3: the agent core, own tools (tool_make), tool arguments, the code runner's web bridge.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent/agent/core.dart';
import 'package:agent/models.dart';
import 'package:agent/services/cloud.dart';
import 'package:agent/services/forged_tools.dart';
import 'package:agent/services/llm_client.dart';
import 'package:agent/services/text_tool_calls.dart';
import 'package:agent/services/tools.dart';
import 'package:agent/services/web_tools.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

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

Map<String, dynamic> def(String n) => {
      'type': 'function',
      'function': {
        'name': n,
        'description': n,
        'parameters': {'type': 'object', 'properties': {}},
      },
    };

LlmResult say(String s) => LlmResult(s, [], 'stop', 15, 10, 5);
LlmResult calls(List<ToolCall> c) => LlmResult('', c, 'tool_calls', 15, 10, 5);
ToolCall tc(String id, String name, Map<String, dynamic> args) => ToolCall(id: id, name: name, arguments: jsonEncode(args));

/// A small app whose tool list can grow during the run, as SubMac's does (tool_make, an app connected mid-task).
class GrowingApp extends CoreHooks {
  GrowingApp(this.offered);
  final List<Map<String, dynamic>> offered;
  final chat = <Map<String, dynamic>>[
    {'role': 'system', 'content': 'sys'},
    {'role': 'user', 'content': 'hi'},
  ];
  final ran = <String>[];
  final ranArgs = <Map<String, dynamic>>[];
  final committedNames = <String>[];
  final doneIds = <String>[];
  Set<String> needsOk = {};
  bool approve = true;

  @override
  bool get cancelled => false;

  @override
  Future<Turn> buildTurn(int step, String? notes) async => Turn(step: step, payload: [...chat], tools: [...offered]);

  @override
  Future<void> commit(Reply r) async {
    committedNames.addAll(r.calls.map((c) => c.name));
    chat.add({'role': 'assistant', 'content': r.text, if (r.hasCalls) 'tool_calls': [for (final c in r.calls) c.toJson()]});
  }

  @override
  Future<String> runTool(ToolCall call, Map<String, dynamic> args, {Object? approved}) async {
    ran.add(call.name);
    ranArgs.add(args);
    return '${call.name} ok';
  }

  @override
  Future<void> toolDone(ToolCall call, Map<String, dynamic> args, String output) async {
    doneIds.add('${call.id}:${call.name}');
    chat.add({'role': 'tool', 'tool_call_id': call.id, 'content': output});
  }

  @override
  Future<Map<String, dynamic>?> approvalFor(ToolCall call, Map<String, dynamic> args) async =>
      needsOk.contains(call.name) ? {'title': 'Run ${call.name}?'} : null;

  @override
  Future<ToolApproval> answer(ToolCall call, Map<String, dynamic> args, Map<String, dynamic> data) async =>
      approve ? ToolApproval.yes(args: args) : const ToolApproval.no('No.');
}

void main() {
  group('R3-1 a tool offered after the run started (tool_make, an app connected mid-task) can be called', () {
    test('the call runs the real tool, and the chat keeps its real name', () async {
      final start = [def('web_search'), def('tool_make')];
      final app = GrowingApp([...start]);
      var i = 0;
      final answers = <LlmResult Function()>[
        () {
          // tool_make saved my_rates: from the next step it is in the list the model sees.
          app.offered.add(def('my_rates'));
          return calls([tc('a', 'tool_make', {'action': 'save'})]);
        },
        () => calls([tc('b', 'my_rates', {'city': 'Paris'})]),
        () => say('Done.'),
      ];
      final core = AgentCore(hooks: app, transport: (_) async => answers[i++](), tools: start);
      final r = await core.run();
      expect(r.end, RunEnd.done);
      expect(app.ran, ['tool_make', 'my_rates']);
      expect(app.ranArgs.last, {'city': 'Paris'});
      expect(app.committedNames, ['tool_make', 'my_rates']);
      expect(app.doneIds, ['a:tool_make', 'b:my_rates']);
      expect(core.state.haltReason, isNull);
    });

    test('a late tool still asks for approval, and runs with the approved arguments', () async {
      final start = [def('web_search')];
      final app = GrowingApp([...start, def('my_shell')])..needsOk = {'my_shell'};
      var i = 0;
      final answers = <LlmResult Function()>[
        () => calls([tc('s', 'my_shell', {'n': 1})]),
        () => say('Done.'),
      ];
      final core = AgentCore(hooks: app, transport: (_) async => answers[i++](), tools: start);
      final r = await core.run();
      expect(r.end, RunEnd.done);
      expect(app.ran, ['my_shell']);
      expect(app.ranArgs.single, {'n': 1});
    });

    test('a name that is offered nowhere is still an unknown tool', () async {
      final start = [def('web_search')];
      final app = GrowingApp([...start]);
      var i = 0;
      final answers = <LlmResult Function()>[
        () => calls([tc('x', 'my_nothing', {})]),
        () => say('Done.'),
      ];
      final core = AgentCore(hooks: app, transport: (_) async => answers[i++](), tools: start);
      await core.run();
      expect(app.ran, isEmpty);
      expect(app.chat.any((m) => m['role'] == 'tool' && '${m['content']}'.contains('no tool named "my_nothing"')), isTrue);
    });
  });

  group('R3-2 tool_make: a shell test run always asks like run_shell', () {
    test('"Shell", " shell " and any action but list/remove are read as _make reads them', () {
      const code = 'rm -rf ./x';
      expect(ForgedTools.makeShellCode({'action': 'save', 'language': 'shell', 'code': code}), code);
      expect(ForgedTools.makeShellCode({'language': 'Shell', 'code': code}), code);
      expect(ForgedTools.makeShellCode({'action': 'Save', 'language': ' SHELL ', 'code': code}), code);
      expect(ForgedTools.makeShellCode({'action': 'update', 'language': 'shell', 'code': code}), code);
      expect(ForgedTools.makeShellCode({'action': 'list', 'language': 'shell', 'code': code}), isNull);
      expect(ForgedTools.makeShellCode({'action': ' Remove', 'language': 'shell', 'code': code}), isNull);
      expect(ForgedTools.makeShellCode({'action': 'save', 'language': 'python', 'code': code}), isNull);
    });
  });

  group('R3-3 tool_make: an own tool can be saved again (fixed), a built-in name cannot be taken', () {
    test('its own name is not a clash; another tool\'s is', () {
      ForgedTools.toolsForTest = [ForgedTool(name: 'rates', description: 'd', language: 'python', code: 'print(1)')];
      // The tool list the router passes in holds the agent's own my_rates too.
      final taken = {'web_search', 'tool_make', 'my_rates'};
      expect(ForgedTools.nameClash('rates', taken), isNull);
      expect(ForgedTools.nameClash('web_search', taken), isNotNull);
      expect(ForgedTools.nameClash('weather', taken), isNull);
      ForgedTools.toolsForTest = [];
    });

    test('a test run that timed out or failed is not saved as working', () {
      expect(ForgedTools.testFailed('exit_code: -1\nstderr:\n\n[timed out after 120s]'), isTrue);
      expect(ForgedTools.testFailed('result: failed\nstdout:\nhalf'), isTrue);
      expect(ForgedTools.testFailed('exit_code: 2\n'), isTrue);
      expect(ForgedTools.testFailed('exit_code: 0\nstdout:\nok'), isFalse);
      expect(ForgedTools.testFailed('stdout:\n42'), isFalse);
    });
  });

  group('R3-4 an own tool\'s definition is always a schema the provider accepts', () {
    test('shorthand parameters become schema objects; required keeps only real parameters', () {
      final t = ForgedTool.fromJson({
        'name': 'rates',
        'description': 'd',
        'language': 'python',
        'code': 'print(1)',
        'params': {'city': 'string', 'days': {'type': 'integer'}, 'tags': 'array', 'odd': 7},
        'required': ['city', 'country'],
      });
      final p = ((t.definition()['function'] as Map)['parameters'] as Map);
      expect(p['properties'], {
        'city': {'type': 'string'},
        'days': {'type': 'integer'},
        'tags': {'type': 'array', 'items': {'type': 'string'}},
        'odd': {'type': 'string'},
      });
      expect(p['required'], ['city']);
    });

    test('"required" as a string never breaks loading or saving', () {
      final t = ForgedTool.fromJson({'name': 'rates', 'code': 'x', 'required': 'city'});
      expect(t.required, isEmpty);
    });
  });

  group('R3-5 numbers sent as strings no longer fail the call', () {
    late Directory tmp;
    setUpAll(() {
      tmp = Directory.systemTemp.createTempSync('bh3');
      PathProviderPlatform.instance = _Docs(tmp.path);
    });

    test('read_file with start_line "2" reads lines, not a type error', () async {
      final f = File('${tmp.path}/notes.txt')..writeAsStringSync('one\ntwo\nthree\nfour');
      final out = await AgentTools.execute('read_file', {'path': f.path, 'start_line': '2', 'end_line': '3'});
      expect(out, contains('two'));
      expect(out, contains('three'));
      expect(out, isNot(contains('subtype')));
    });

    test('R3-11 read_file on a huge file says so instead of loading it whole', () async {
      final f = File('${tmp.path}/big.bin');
      final raf = f.openSync(mode: FileMode.write)..truncateSync(AgentTools.maxReadBytes + 1);
      raf.closeSync();
      final out = await AgentTools.execute('read_file', {'path': f.path});
      expect(out, startsWith('Error: '));
      expect(out, contains('too big to read whole'));
    });

    test('run_shell with timeout_seconds "30" runs', () async {
      final out = await AgentTools.execute('run_shell', {'command': 'echo hi', 'timeout_seconds': '30'});
      expect(out, startsWith('exit_code: 0'));
    });

    test('web_research with queries as one string is read, not a type error', () async {
      final out = await WebTools.execute('web_research', {'question': ' ', 'queries': 'other words'});
      expect(out, 'Error: empty question');
    });

    test('intArg reads numbers and numeric strings, and nothing else', () {
      expect(AgentTools.intArg(5), 5);
      expect(AgentTools.intArg(5.7), 5);
      expect(AgentTools.intArg(' 120 '), 120);
      expect(AgentTools.intArg('8000.0'), 8000);
      expect(AgentTools.intArg('ten'), isNull);
      expect(AgentTools.intArg(null), isNull);
      expect(AgentTools.intArg(const ['1']), isNull);
    });
  });

  group('R3-6 submac.get in code: a body that never ends no longer hangs or fills the memory', () {
    test('an endless body stops at the size cap', () async {
      Stream<List<int>> endless() async* {
        while (true) {
          yield List<int>.filled(1000, 65);
          await Future<void>.delayed(Duration.zero);
        }
      }

      final b = await AgentTools.readCapped(endless(), maxBytes: 5500);
      expect(b.length, 5500);
    });

    test('a body that goes silent ends after the idle limit with what came', () async {
      final c = StreamController<List<int>>();
      c.add([1, 2, 3]);
      final b = await AgentTools.readCapped(c.stream, idle: const Duration(milliseconds: 200));
      expect(b, [1, 2, 3]);
      await c.close();
    });

    test('fetch_url on a link that never ends stops at its cap and still answers', () async {
      var sent = 0;
      final client = MockClient.streaming((req, body) async {
        Stream<List<int>> endless() async* {
          while (true) {
            sent += 65536;
            yield List<int>.filled(65536, 97);
            await Future<void>.delayed(Duration.zero);
          }
        }

        return http.StreamedResponse(endless(), 200, headers: {'content-type': 'text/plain'});
      });
      final out = await http.runWithClient(() => AgentTools.fetchUrl('https://example.com/live', 0), () => client);
      expect(out, startsWith('HTTP 200'));
      expect(sent, lessThan(AgentTools.maxFetchBytes + 200000));
    });

    test('a normal body is read whole', () async {
      final b = await AgentTools.readCapped(Stream.fromIterable([
        [1, 2],
        [3]
      ]));
      expect(b, [1, 2, 3]);
    });
  });

  group('R3-7 tool calls with an empty or repeated id never get each other\'s results', () {
    test('two reads with empty ids, run together: each result answers its own call', () async {
      final tools = [def('web_search')];
      final app = _EchoApp([...tools]);
      var i = 0;
      final answers = <LlmResult Function()>[
        () => calls([tc('', 'web_search', {'q': 'cats'}), tc('', 'web_search', {'q': 'dogs'})]),
        () => calls([tc('call_0', 'web_search', {'q': 'birds'})]),
        () => calls([tc('call_0', 'web_search', {'q': 'fish'})]),
        () => say('Done.'),
      ];
      final core = AgentCore(hooks: app, transport: (_) async => answers[i++](), tools: tools);
      expect((await core.run()).end, RunEnd.done);
      final asked = <String, String>{};
      for (final m in app.chat.where((m) => m['role'] == 'assistant' && m['tool_calls'] != null)) {
        for (final c in m['tool_calls'] as List) {
          asked['${c['id']}'] = '${jsonDecode('${(c['function'] as Map)['arguments']}')['q']}';
        }
      }
      final results = {for (final m in app.chat.where((m) => m['role'] == 'tool')) '${m['tool_call_id']}': '${m['content']}'};
      expect(asked.length, 4, reason: 'every call has its own id');
      expect(asked.keys.every((k) => k.isNotEmpty), isTrue);
      for (final e in asked.entries) {
        expect(results[e.key], 'searched ${e.value}');
      }
    });
  });

  group('R3-8 a streamed tool call with an empty id, a number id or object arguments is read, not a dropped line', () {
    test('ids are unique and arguments are text', () async {
      LlmClient.testHeaders = (source) async => {'Content-Type': 'application/json'};
      String ev(Map<String, dynamic> delta, [String? finish]) => 'data: ${jsonEncode({
            'choices': [
              {'index': 0, 'delta': delta, if (finish != null) 'finish_reason': finish}
            ]
          })}\n\n';
      final body = [
        ev({
          'tool_calls': [
            {'index': 0, 'id': '', 'function': {'name': 'web_search', 'arguments': '{"q":"a"}'}},
            {'index': 1, 'id': 7, 'function': {'name': 'read_file', 'arguments': {'path': 'x.txt'}}},
          ]
        }),
        ev({}, 'tool_calls'),
        'data: [DONE]\n\n',
      ].join();
      LlmClient.testClient = MockClient.streaming((req, b) async =>
          http.StreamedResponse(Stream.value(utf8.encode(body)), 200, headers: {'content-type': 'text/event-stream'}));
      try {
        final r = await LlmClient().streamChat(provider: Cloud.provider, model: Cloud.submac, messages: const [
          {'role': 'user', 'content': 'hi'}
        ], onDelta: (_) {});
        expect(r.toolCalls.length, 2);
        expect(r.toolCalls[0].id, isNotEmpty);
        expect(r.toolCalls[1].id, '7');
        expect(jsonDecode(r.toolCalls[1].arguments), {'path': 'x.txt'});
      } finally {
        LlmClient.testClient = http.Client();
        LlmClient.testHeaders = null;
      }
    });
  });

  group('R3-9 a tool call written as text keeps phone numbers and codes as they were written', () {
    test('a leading zero or a long id stays text; plain numbers stay numbers', () {
      final r = TextToolCalls.parse('<function=whatsapp><parameter=to>0612345678</parameter><parameter=code>007</parameter>'
          '<parameter=order>12345678901234567890</parameter><parameter=n>3</parameter><parameter=p>0.5</parameter>'
          '<parameter=t>-12.25</parameter></function>');
      final a = jsonDecode(r.calls.single.arguments) as Map;
      expect(a['to'], '0612345678');
      expect(a['code'], '007');
      expect(a['order'], '12345678901234567890');
      expect(a['n'], 3);
      expect(a['p'], 0.5);
      expect(a['t'], -12.25);
    });
  });

  group('R3-10 one odd character code on a results page no longer drops the whole search engine', () {
    test('Bing results with an out-of-range &#...; still parse', () {
      const page = '<li class="b_algo"><h2><a href="https://example.com/a">Caf&#233; &#99999999; menu</a></h2><p>Open &#1114112; now</p></li>';
      final r = WebTools.parseBing(page, 5);
      expect(r.single['url'], 'https://example.com/a');
      expect(r.single['title'], 'Café &#99999999; menu');
      expect(r.single['snippet'], 'Open &#1114112; now');
    });
  });
}

/// Answers every search with what it searched for, and runs reads together like the app does.
class _EchoApp extends GrowingApp {
  _EchoApp(super.offered);
  @override
  List<List<int>> parallel(List<ToolCall> calls) => calls.length > 1 ? [List<int>.generate(calls.length, (i) => i)] : const [];
  @override
  Future<String> runTool(ToolCall call, Map<String, dynamic> args, {Object? approved}) async {
    await Future<void>.delayed(Duration(milliseconds: args['q'] == 'cats' ? 30 : 1));
    return 'searched ${args['q']}';
  }
}
