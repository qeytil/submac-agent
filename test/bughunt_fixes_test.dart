// Regression tests for the deep bug hunt on build-61 (v1.13.102+172). Each test was a probe that passed BY SHOWING the
// bug; it now asserts the fixed behaviour. Report: C1, H1-H5, M1-M4, L1-L3.
import 'dart:async';
import 'dart:io';

import 'package:agent/agent/core.dart';
import 'package:agent/agent/run_journal.dart';
import 'package:agent/app_state.dart';
import 'package:agent/models.dart';
import 'package:agent/services/ai_keys.dart';
import 'package:agent/services/bots.dart';
import 'package:agent/services/connector_catalog.dart';
import 'package:agent/services/connector_tools.dart';
import 'package:agent/services/full_access.dart';
import 'package:agent/services/llm_client.dart';
import 'package:agent/services/offices.dart';
import 'package:agent/services/team_run.dart';
import 'package:agent/services/tool_output_clean.dart';
import 'package:agent/services/tools.dart';
import 'package:agent/services/trust.dart';
import 'package:agent/ui/i18n.dart';
import 'package:flutter_test/flutter_test.dart';

final tools = [
  for (final n in ['web_search'])
    {
      'type': 'function',
      'function': {
        'name': n,
        'description': n,
        'parameters': {'type': 'object', 'properties': {}},
      },
    }
];

class Hooks extends CoreHooks {
  final chat = <Map<String, dynamic>>[
    {'role': 'user', 'content': 'hi'},
  ];
  int errors = 0;
  int counted = 0;
  final outputs = <String>[];
  String Function(String)? clean;
  String toolText = 'ok';
  @override
  bool get cancelled => false;
  @override
  Future<Turn> buildTurn(int step, String? notes) async => Turn(step: step, payload: [...chat], tools: tools);
  @override
  Future<String> runTool(ToolCall call, Map<String, dynamic> args, {Object? approved}) async => toolText;
  @override
  String cleanOutput(String out) => clean == null ? out : clean!(out);
  @override
  void usage(Reply r) => counted += r.tokens;
  @override
  Future<void> toolDone(ToolCall call, Map<String, dynamic> args, String output) async => outputs.add(output);
  @override
  Future<ErrorAction> onError(Object error) async {
    errors++;
    return ErrorAction.retry; // every error here is a transient drop / steer the app retries
  }
}

class _DeadNet extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? c) => super.createHttpClient(c)..findProxy = (_) => 'PROXY 127.0.0.1:1';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    AiKeys.store = MemoryAiStore();
    ConnectorCatalog.connected.clear();
  });
  tearDown(() => ConnectorCatalog.connected.clear());

  // ------------------------------------------------------------------ C1
  group('C1 connector calls stay on the app\'s own host', () {
    test('an absolute URL to another host is refused: no request, no token sent, never a read', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var hits = 0;
      server.listen((req) {
        hits++;
        req.response
          ..statusCode = 200
          ..write('{}')
          ..close();
      });
      ConnectorCatalog.connected['notion'] = {'token': 'SECRET-NOTION-TOKEN'};
      for (final url in ['http://127.0.0.1:${server.port}/steal', 'https://127.0.0.1:${server.port}/steal', 'http://api.notion.com/v1/x']) {
        final args = {'path': url};
        expect(ConnectorCatalog.isRead('app_notion', args), isFalse, reason: url);
        final out = await ConnectorCatalog.execute('app_notion', args);
        expect(out, startsWith('Error: Notion calls must stay on'), reason: url);
        expect(out, isNot(contains('SECRET')));
      }
      // api_call with a connector: same rule.
      final viaApi = {'method': 'GET', 'url': 'http://127.0.0.1:${server.port}/steal', 'connector': 'notion'};
      expect(ConnectorCatalog.isRead('api_call', viaApi), isFalse);
      expect(await ConnectorCatalog.execute('api_call', viaApi), startsWith('Error: Notion calls must stay on'));
      await server.close(force: true);
      expect(hits, 0);
    });

    test('a full https URL on the app\'s own host still counts as a read for GET', () {
      ConnectorCatalog.connected['github'] = {'token': 'ghp_x'};
      expect(ConnectorCatalog.isRead('app_github', {'method': 'GET', 'path': 'https://api.github.com/repos/o/r'}), isTrue);
      expect(ConnectorCatalog.hostOf('github'), 'api.github.com');
    });

    test('a public api_call without a connector keeps working for GET reads', () {
      expect(ConnectorCatalog.isRead('api_call', {'method': 'GET', 'url': 'https://api.example.com/x'}), isTrue);
      expect(ConnectorCatalog.isRead('api_call', {'method': 'POST', 'url': 'https://api.example.com/x'}), isFalse);
    });
  });

  // ------------------------------------------------------------------ H1
  group('H1 write calls are never classed as reads', () {
    test('the query string never makes a write a read', () {
      expect(ConnectorCatalog.isRead('app_telegram', {'method': 'POST', 'path': '/sendMessage?x=getMe', 'body': {'chat_id': 1, 'text': 'hi'}}), isFalse);
      expect(ConnectorCatalog.isRead('app_github', {'method': 'POST', 'path': '/repos/o/r/issues?ref=/search', 'body': {'title': 'x'}}), isFalse);
    });

    test('Telegram send*/delete* never read, even as GET; its get* methods do', () {
      expect(ConnectorCatalog.isRead('app_telegram', {'method': 'GET', 'path': '/sendMessage', 'query': {'chat_id': 1, 'text': 'hi'}}), isFalse);
      expect(ConnectorCatalog.isRead('app_telegram', {'method': 'GET', 'path': '/deleteMessage'}), isFalse);
      expect(ConnectorCatalog.isRead('app_telegram', {'method': 'GET', 'path': '/getMe'}), isTrue);
      expect(ConnectorCatalog.isRead('app_telegram', {'method': 'POST', 'path': '/getUpdates'}), isTrue);
      expect(ConnectorCatalog.isRead('api_call', {'method': 'GET', 'url': '/sendMessage', 'connector': 'telegram'}), isFalse);
    });

    test('Slack writes over GET ask; its list/history reads do not', () {
      expect(ConnectorCatalog.isRead('app_slack', {'method': 'GET', 'path': '/chat.postMessage?channel=C1&text=hi'}), isFalse);
      expect(ConnectorCatalog.isRead('app_slack', {'method': 'GET', 'path': '/conversations.history?channel=C1'}), isTrue);
    });

    test('anchored search/query routes stay reads; look-alikes do not', () {
      expect(ConnectorCatalog.isRead('app_notion', {'method': 'POST', 'path': '/search'}), isTrue);
      expect(ConnectorCatalog.isRead('app_notion', {'method': 'POST', 'path': '/databases/abc/query'}), isTrue);
      expect(ConnectorCatalog.isRead('app_notion', {'method': 'POST', 'path': '/pages/search-notes'}), isFalse);
      expect(ConnectorCatalog.isRead('app_linear', {'method': 'POST', 'path': '/graphql', 'body': {'query': 'mutation { x }'}}), isFalse);
      expect(ConnectorCatalog.isRead('app_linear', {'method': 'POST', 'path': '/graphql', 'body': {'query': '{ viewer { id } }'}}), isTrue);
      expect(ConnectorTools.isWrite({'method': 'POST', 'path': '/search?x=1'}), isFalse);
      expect(ConnectorTools.isWrite({'method': 'POST', 'path': '/searchAndDelete'}), isTrue);
    });
  });

  // ------------------------------------------------------------------ H2
  group('H2 secrets never reach the chat, backup or model', () {
    test('a network error on a token-in-URL connector (Telegram) does not carry the bot token', () async {
      ConnectorCatalog.connected['telegram'] = {'token': '123456:SECRET-TG'};
      HttpOverrides.global = _DeadNet();
      final out = await ConnectorCatalog.execute('app_telegram', {'path': '/getMe'});
      HttpOverrides.global = null;
      expect(out, startsWith('Error'));
      expect(out, isNot(contains('SECRET-TG')));
      expect(out, isNot(contains('123456:SECRET')));
    });

    test('every tool output is cleaned before it is journaled, saved or sent (core hook)', () async {
      final h = Hooks()
        ..toolText = 'config: api_key = sk-proj-ABCDEFGHIJKLMNOPQRSTUVWX123'
        ..clean = ToolOutputClean.clean;
      var call = 0;
      final r = await AgentCore(
        hooks: h,
        transport: (t) async => ++call == 1
            ? LlmResult('', [ToolCall(id: 'a', name: 'web_search', arguments: '{}')], 'tool_calls', 2, 1, 1)
            : LlmResult('done', [], 'stop', 2, 1, 1),
        tools: tools,
      ).run();
      expect(r.end, RunEnd.done);
      expect(h.outputs.single, isNot(contains('sk-proj-ABCDEFGHIJKLMNOPQRSTUVWX123')));
      expect(h.outputs.single, contains(AiKeys.refPrefix));
    });

    test('ToolOutputClean hides saved connector secrets wherever they appear', () {
      ConnectorCatalog.connected['stripe'] = {'key': 'rk_live_SUPERSECRET'};
      expect(ToolOutputClean.clean('failed for https://x/?k=rk_live_SUPERSECRET'), isNot(contains('SUPERSECRET')));
      expect(ToolOutputClean.clean('plain text'), 'plain text');
    });
  });

  // ------------------------------------------------------------------ H3
  group('H3 risky app settings always ask', () {
    test('approval_mode, standing instructions and the microphone need approval; theme does not', () async {
      for (final k in ['approval_mode', 'about_you', 'how_to_respond', 'wake_word', 'wake_screen_off', 'actions_enabled', 'memory']) {
        expect(await AgentTools.riskFor('app_settings', {'action': 'set', 'key': k, 'value': 'x'}), isNotNull, reason: k);
      }
      // Any action other than list/get/open_permission sets the value (SystemTools._settings), so it asks too.
      expect(await AgentTools.riskFor('app_settings', {'action': 'update', 'key': 'approval_mode', 'value': 'full'}), isNotNull);
      expect(await AgentTools.riskFor('app_settings', {'action': 'set', 'key': 'theme', 'value': 'dark'}), isNull);
      expect(await AgentTools.riskFor('app_settings', {'action': 'list'}), isNull);
      expect(await AgentTools.riskFor('app_settings', {'action': 'get', 'key': 'approval_mode'}), isNull);
    });

    test('even Full access and a Trusted level ask for a settings change, and it never offers Allow always', () {
      expect(FullAccess.shouldAsk(level: BotTrust.levelTrusted, kind: FullAccess.alwaysAskKind, tool: 'app_settings', fullAccess: true), isTrue);
      expect(FullAccess.shouldAsk(level: BotTrust.levelTrusted, kind: 'change', tool: 'app_settings', fullAccess: true), isFalse,
          reason: 'only the router-set kind "settings" forces the ask');
      final a = Approval(id: 'x', botId: 'b', title: 't', kind: FullAccess.alwaysAskKind);
      expect(a.alwaysAsks, isTrue);
      expect(Approval(id: 'y', botId: 'b', title: 't', kind: 'change').alwaysAsks, isFalse);
    });
  });

  // ------------------------------------------------------------------ H4 + M3
  group('H4 resume settles every cut-off call of the run', () {
    final list = [
      ChatMessage(id: 'u1', role: 'user', content: 'pay the electricity bill'),
      ChatMessage(id: 'a1', role: 'assistant', toolCalls: [ToolCall(id: 'pay1', name: 'browser_click', arguments: '{"id":7}')]),
      // The user typed while the payment click was running (steerTask / send add a user message mid-run).
      ChatMessage(id: 'u2', role: 'user', content: 'use my visa card'),
    ];
    test('from the run start kept in the journal header', () {
      expect(ResumeSettle.unanswered(list, fromId: 'u1').map((c) => c.id), ['pay1']);
    });
    test('from the journal\'s own unfinished calls', () {
      expect(ResumeSettle.unanswered(list, journalIds: ['pay1']).map((c) => c.id), ['pay1']);
    });
    test('answered calls and earlier runs stay as they are', () {
      final l2 = [
        ChatMessage(id: 'u0', role: 'user', content: 'old'),
        ChatMessage(id: 'a0', role: 'assistant', toolCalls: [ToolCall(id: 'old1', name: 'web_search', arguments: '{}')]),
        ...list,
        ChatMessage(id: 't1', role: 'tool', content: 'ok', toolCallId: 'pay1'),
      ];
      expect(ResumeSettle.unanswered(l2, fromId: 'u1'), isEmpty);
    });

    test('the journal header keeps where the run started and whether it is background work (M3)', () async {
      final dir = await Directory.systemTemp.createTemp('rj');
      final j = await RunJournal.open(runId: 'r1', convId: 'c1', dir: dir, meta: {'title': 't', 'from': 'u1', 'background': 'office', 'office': 'o1'});
      await j!.toolStart(ToolCall(id: 'pay1', name: 'browser_click', arguments: '{}'));
      j.beat();
      final p = (await PendingRun.read(File('${dir.path}/r1.jsonl')))!;
      expect(p.meta['from'], 'u1');
      expect(p.meta['background'], 'office');
      expect(p.meta['office'], 'o1');
      expect(p.unfinished.map((c) => c.id), ['pay1']);
      await j.close('test');
      await dir.delete(recursive: true);
    });
  });

  // ------------------------------------------------------------------ H5
  group('H5 error retries count streaks, not the whole run', () {
    test('nine drops, each followed by a good step, no longer kill a long task', () async {
      var call = 0;
      Future<LlmResult> transport(Turn t) async {
        call++;
        if (call.isOdd && call < 30) throw LlmException('The connection dropped. Please try again.');
        if (call >= 40) return LlmResult('All done.', [], 'stop', 2, 1, 1);
        return LlmResult('', [ToolCall(id: 'c$call', name: 'web_search', arguments: '{}')], 'tool_calls', 2, 1, 1);
      }

      final h = Hooks();
      final r = await AgentCore(hooks: h, transport: transport, tools: tools).run();
      expect(r.end, RunEnd.done);
      expect(h.errors, greaterThanOrEqualTo(9));
    });

    test('errors in a row with no progress are still capped', () async {
      final h = Hooks();
      final r = await AgentCore(hooks: h, transport: (t) async => throw LlmException('The connection dropped.'), tools: tools).run();
      expect(r.end, RunEnd.failed);
      expect(h.errors, AgentCore.maxFailuresInRow + 1);
    });

    test('steers never count as failures, and a run never ends with the word "steered"', () async {
      var call = 0;
      final h = Hooks();
      final r = await AgentCore(
        hooks: h,
        transport: (t) async {
          call++;
          if (call <= 20) throw LlmException('steered');
          return LlmResult('Answer', [], 'stop', 2, 1, 1);
        },
        tools: tools,
      ).run();
      expect(r.end, RunEnd.done);
      expect(AgentCore.isSteer(LlmException('steered')), isTrue);
      expect(AgentCore.steerStopText, isNot(contains('steered')));
    });
  });

  // ------------------------------------------------------------------ M1
  test('M1 usage is counted for every reply, also replies without tool calls', () async {
    final h = Hooks();
    var seenAfter = 0;
    final r = await AgentCore(
      hooks: h,
      transport: (t) async => LlmResult('A long final answer…', [], 'stop', 9000, 1000, 8000),
      tools: tools,
      after: [(rep, st) async => seenAfter += rep.tokens],
    ).run();
    expect(r.end, RunEnd.done);
    expect(h.counted, 9000);
    expect(seenAfter, 0, reason: 'after-guards still only decide about tool calls');
  });

  // ------------------------------------------------------------------ M2
  test('M2 a checkpoint fires even when a finish gate makes the step counter jump past it', () async {
    var call = 0, gateHits = 0;
    final checked = <int>[];
    final clock = CheckpointClock();
    final h = Hooks();
    final core = AgentCore(
      hooks: h,
      transport: (t) async {
        call++;
        if (call == 1) return LlmResult('', [ToolCall(id: 'a', name: 'web_search', arguments: '{}')], 'tool_calls', 2, 1, 1);
        if (call == 2 || call == 3) return LlmResult('I am done', [], 'stop', 2, 1, 1); // sent back twice
        if (call == 4) return LlmResult('', [ToolCall(id: 'b', name: 'web_search', arguments: '{}')], 'tool_calls', 2, 1, 1);
        return LlmResult('final', [], 'stop', 2, 1, 1);
      },
      tools: tools,
      gates: [(rep) async => gateHits++ < 2 ? (note: 'not yet', hold: false) : null],
      before: [
        (st) {
          checked.add(st.step);
          return clock.due(st.step, 3) ? 'checkpoint' : null; // as agent_runner's checkpoint guard
        }
      ],
    );
    final r = await core.run();
    expect(checked, [0, 1, 4]);
    expect(r.end, RunEnd.halted);
    expect(core.state.haltReason, 'checkpoint');
    expect(clock.last, 4);
    expect(clock.due(6, 3), isFalse);
    expect(clock.due(7, 3), isTrue);
  });

  // ------------------------------------------------------------------ L1
  test('L1 the team step cap has a real halt reason (never an empty banner)', () {
    expect(AppState.officeCapReason.trim(), isNotEmpty);
    expect(Strings.table['so']![AppState.officeCapReason], isNotNull);
    expect(Strings.table['ar']![AppState.officeCapReason], isNotNull);
  });

  // ------------------------------------------------------------------ L2
  group('L2 team stop cancels the call in flight', () {
    final lead = Bot(id: 'bhl', name: 'Hodan', role: 'Manager', persona: 'Calm.');
    final nova = Bot(id: 'bhn', name: 'Nova', role: 'Researcher', persona: 'Curious.');
    setUp(() {
      Bots.I.bots.addAll([lead, nova]);
      TeamRun.I.reset();
    });
    tearDown(() {
      Bots.I.bots.removeWhere((b) => b.id.startsWith('bh'));
      Offices.I.offices.clear();
      Offices.I.queue.clear();
      TeamRun.I.reset();
    });

    test('"stop" while a member is mid-call ends the work at once', () async {
      final hang = Completer<String>();
      var inPart = false;
      TeamRun.I
        ..promptOf = ((b) => 'You are ${b.name}.')
        ..ask = (b, system, user, {int maxTokens = 0}) async {
          if (system.contains('# Who speaks')) return '{"speaker":"Hodan","team_task":true}';
          if (system.contains('# Plan for the owner')) {
            return '{"reply":"Ok.","questions":[],"parts":[{"bot":"Nova","ask":"Find suppliers"}]}';
          }
          if (system.contains('# Your part')) {
            inPart = true;
            return hang.future; // the model call never comes back on its own
          }
          return 'Combined.';
        };
      final o = Office(id: 'obh${DateTime.now().microsecondsSinceEpoch}', name: 'Coffee', members: ['bhl', 'bhn'], chiefId: 'bhl');
      TeamRun.I.send(o, 'Find the three cheapest coffee suppliers in Hargeisa');
      final work = TeamRun.I.work!;
      for (var i = 0; i < 100 && !inPart; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(inPart, isTrue);
      expect(TeamRun.I.coresFor(o.id), greaterThan(0));
      TeamRun.I.send(o, 'stop');
      await work.timeout(const Duration(seconds: 5));
      expect(TeamRun.I.coresFor(o.id), 0);
      expect(TeamRun.I.running, isEmpty);
    });
  });

  // ------------------------------------------------------------------ M4
  test('M4 the six keys that had no translation have Somali and Arabic', () {
    for (final k in ['Copy', 'Copied', 'Reply', 'Select text', 'Skills', 'Pay {usd}']) {
      expect(Strings.table['so']![k], isNotNull, reason: k);
      expect(Strings.table['ar']![k], isNotNull, reason: k);
    }
  });

  test('M4 banners with {holes} translate as one sentence', () {
    AppLang.I.choice = 'so';
    expect(tr('Paused after {n} steps, the most for one task. Send "continue" to keep going.', {'n': '12'}), contains('12 tallaabo'));
    AppLang.I.choice = 'ar';
    expect(tr('Task finished in "{chat}".', {'chat': 'X'}), 'انتهت المهمة في "X".');
    AppLang.I.choice = 'phone';
  });

  test('M4 guard: no Text(\'…\') literal in screens/widgets that already has Somali and Arabic stays unwrapped', () {
    final so = Strings.table['so']!, ar = Strings.table['ar']!;
    final lit = RegExp(r"""(?<![A-Za-z_.])Text\(\s*(['"])((?:\\.|(?!\1).)*)\1""");
    final bad = <String>[];
    for (final dir in ['lib/screens', 'lib/widgets']) {
      for (final f in Directory(dir).listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
        if (f.path.contains('/billing/')) continue; // billing words come from BillingCopy
        final src = f.readAsStringSync();
        for (final m in lit.allMatches(src)) {
          final k = m.group(2)!;
          if (k.contains(r'$')) continue;
          if (so.containsKey(k) && ar.containsKey(k)) bad.add('${f.path}:${src.substring(0, m.start).split('\n').length} "$k"');
        }
      }
    }
    expect(bad, isEmpty, reason: 'wrap these in tr(): ${bad.join(', ')}');
  });
}
