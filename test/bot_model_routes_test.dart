// Every path a bot's model call takes uses the model in its profile (owner 2026-11-06: "bots do not use the model set
// in their profile"). opencode turns already named it per prompt; the plain one-answer calls (the team's "who speaks",
// the lead's plan and combined answer, instant team replies, bot_ask, the check-in gate) went to Telesia's model.
//
// ignore_for_file: invalid_use_of_visible_for_testing_member, depend_on_referenced_packages
import 'dart:convert';
import 'dart:io';

import 'package:agent/app_state.dart';
import 'package:agent/models.dart';
import 'package:agent/services/bot_llm.dart';
import 'package:agent/services/bots.dart';
import 'package:agent/services/byok.dart';
import 'package:agent/services/byok_fetch.dart';
import 'package:agent/services/cloud.dart';
import 'package:agent/services/oc_lanes.dart';
import 'package:agent/services/offices.dart';
import 'package:agent/services/team_floor.dart';
import 'package:agent/services/team_run.dart';
import 'package:flutter_test/flutter_test.dart';
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

const _pid = 'byok-9f8e7d6c';

ByokProvider _prov({ByokKind kind = ByokKind.openaiCompatible, String id = _pid, String base = 'https://llm.example.test/v1'}) => ByokProvider(
      id: id,
      kind: kind,
      preset: 'custom',
      baseUrl: base,
      enabled: true,
      keys: [ByokKey(id: 'k-$id', name: 'main', hint: 'wxyz')],
      activeKey: 'k-$id',
      models: [ByokModel(id: 'gpt-x'), ByokModel(id: 'gpt-x-mini'), ByokModel(id: 'claude-x')],
    );

void _store({String chat = ByokRef.telesia}) => ByokStore.I.resetForTests(ByokConfig(providers: [_prov()], chat: chat), {'k-$_pid': 'sk-secret-123456'});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final byokCalls = <String>[];
  final cloudCalls = <String>[];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    byokCalls.clear();
    cloudCalls.clear();
    BotLlm.byokCall = (pick, messages, {int? maxTokens}) async {
      byokCalls.add('${pick.provider.id}|${pick.model.id}');
      return 'from ${pick.model.id}';
    };
    BotLlm.cloudCall = (model, messages, {int? maxTokens, int continues = 0, String source = 'bot', bool background = false, ProviderConfig? provider}) async {
      cloudCalls.add('$model|$source|${background ? 'bg' : 'fg'}');
      return 'from telesia';
    };
  });
  tearDown(() => ByokStore.I.resetForTests());

  group('BotModelRoute: the one decision, the same as opencode\'s', () {
    test('own model, default (follows the owner\'s chat model), Telesia, unusable', () {
      _store(chat: '$_pid|claude-x');
      expect(BotModelRoute.ofSetting('$_pid|gpt-x').toString(), '$_pid|gpt-x');
      expect(BotModelRoute.ofSetting('auto').toString(), '$_pid|claude-x', reason: 'Default = the owner\'s chat model');
      expect(BotModelRoute.ofSetting('').toString(), '$_pid|claude-x');
      expect(BotModelRoute.ofSetting('telesia').toString(), 'telesia|${Cloud.telesia}');
      expect(BotModelRoute.ofSetting('byok-00000000|gpt-x').toString(), '$_pid|claude-x', reason: 'gone provider: the default');
      _store();
      expect(BotModelRoute.ofSetting('auto').isByok, isFalse);
      expect(BotModelRoute.ofSetting('$_pid|gpt-x').isByok, isTrue);
    });

    test('agrees with OcLane.pick on every lane', () {
      for (final chat in [ByokRef.telesia, '$_pid|claude-x']) {
        _store(chat: chat);
        for (final s in ['auto', 'telesia', '$_pid|gpt-x', 'byok-00000000|gpt-x', 'telesia|telesia-fast']) {
          for (final bg in [true, false]) {
            for (final office in [true, false]) {
              expect(BotModelRoute.ofSetting(s).asOcModel(background: bg, officeWork: office), OcLane.pick(background: bg, officeWork: office, botModel: s),
                  reason: '$chat $s bg=$bg office=$office');
            }
          }
        }
      }
    });
  });

  group('BotLlm: plain calls go to the bot\'s model', () {
    test('own model: that provider, never Telesia', () async {
      _store();
      final b = Bot(id: 'm1', name: 'Nova', role: 'Researcher', persona: '', model: '$_pid|gpt-x');
      expect(await BotLlm.complete(b, [{'role': 'user', 'content': 'hi'}]), 'from gpt-x');
      expect(byokCalls, ['$_pid|gpt-x']);
      expect(cloudCalls, isEmpty);
    });

    test('Telesia or default: Telesia, on the lane asked for', () async {
      _store();
      await BotLlm.complete(Bot(id: 'm2', name: 'A', role: '', persona: ''), [{'role': 'user', 'content': 'hi'}], source: 'office', background: true);
      expect(cloudCalls, ['${Cloud.telesia}|office|bg']);
      expect(byokCalls, isEmpty);
    });
  });

  group('ByokFetch: one plain chat call per protocol', () {
    final msgs = [
      {'role': 'system', 'content': 'You are Nova.'},
      {'role': 'user', 'content': 'Who answers?'},
    ];

    test('OpenAI style', () {
      final r = ByokFetch.chatRequest(_prov(), 'sk-1', 'gpt-x', msgs, maxTokens: 50);
      expect(r.url.toString(), 'https://llm.example.test/v1/chat/completions');
      final j = jsonDecode(r.body) as Map;
      expect(j['model'], 'gpt-x');
      expect(j['max_tokens'], 50);
      expect((j['messages'] as List).first, {'role': 'system', 'content': 'You are Nova.'});
      expect(r.headers['Authorization'], 'Bearer sk-1');
      expect(ByokFetch.chatText(ByokKind.openai, {'choices': [{'message': {'content': 'Nova.'}}]}), 'Nova.');
    });

    test('Anthropic style: system apart, max_tokens always set', () {
      final r = ByokFetch.chatRequest(_prov(kind: ByokKind.anthropic, base: 'https://api.anthropic.com/v1'), 'sk-ant', 'claude-x', msgs);
      expect(r.url.toString(), 'https://api.anthropic.com/v1/messages');
      final j = jsonDecode(r.body) as Map;
      expect(j['system'], 'You are Nova.');
      expect(j['max_tokens'], 1024);
      expect(j['messages'], [{'role': 'user', 'content': 'Who answers?'}]);
      expect(r.headers['x-api-key'], 'sk-ant');
      expect(ByokFetch.chatText(ByokKind.anthropic, {'content': [{'type': 'text', 'text': 'Nova'}, {'type': 'text', 'text': '.'}]}), 'Nova.');
    });

    test('the output cap fits the model (its listed limit; Anthropic never over 8192 unknown)', () {
      final p = _prov();
      expect(BotLlm.capFor(ByokPick(p, ByokModel(id: 'a', output: 4096)), 16384), 4096);
      expect(BotLlm.capFor(ByokPick(p, ByokModel(id: 'a')), 16384), 16384);
      expect(BotLlm.capFor(ByokPick(_prov(kind: ByokKind.anthropic), ByokModel(id: 'a')), 16384), 8192);
      expect(BotLlm.capFor(ByokPick(p, ByokModel(id: 'a')), null), isNull);
    });

    test('Gemini style', () {
      final r = ByokFetch.chatRequest(_prov(kind: ByokKind.gemini, base: 'https://generativelanguage.googleapis.com/v1beta'), 'g-1', 'gemini-x', msgs, maxTokens: 20);
      expect(r.url.toString(), 'https://generativelanguage.googleapis.com/v1beta/models/gemini-x:generateContent');
      final j = jsonDecode(r.body) as Map;
      expect(j['systemInstruction'], {'parts': [{'text': 'You are Nova.'}]});
      expect(j['contents'], [{'role': 'user', 'parts': [{'text': 'Who answers?'}]}]);
      expect(j['generationConfig'], {'maxOutputTokens': 20});
      expect(ByokFetch.chatText(ByokKind.gemini, {'candidates': [{'content': {'parts': [{'text': 'hm', 'thought': true}, {'text': 'Nova.'}]}}]}), 'Nova.');
    });

    test('Anthropic tool step: Messages shape with tools and tool_use/tool_result blocks', () {
      final p = _prov(kind: ByokKind.anthropic, base: 'https://api.anthropic.com/v1');
      final r = ByokFetch.toolChatRequest(p, 'sk-ant', 'claude-x', [
        {'role': 'system', 'content': 'You are Nova.'},
        {'role': 'user', 'content': 'open it'},
        {'role': 'assistant', 'tool_calls': [
          {'id': 'c1', 'type': 'function', 'function': {'name': 'browser_open', 'arguments': '{"url":"https://a"}'}}
        ]},
        {'role': 'tool', 'tool_call_id': 'c1', 'name': 'browser_open', 'content': 'opened'},
      ], [
        {'type': 'function', 'function': {'name': 'browser_open', 'description': 'Open', 'parameters': {'type': 'object', 'properties': {}}}},
      ], maxTokens: 100);
      expect(r.url.toString(), 'https://api.anthropic.com/v1/messages');
      expect(r.headers['x-api-key'], 'sk-ant');
      final j = jsonDecode(r.body) as Map;
      expect(j['system'], 'You are Nova.');
      expect(j['max_tokens'], 100);
      expect(j['tools'], [{'name': 'browser_open', 'description': 'Open', 'input_schema': {'type': 'object', 'properties': {}}}]);
      final m = j['messages'] as List;
      expect(m[0], {'role': 'user', 'content': [{'type': 'text', 'text': 'open it'}]});
      expect((m[1] as Map)['content'][0], {'type': 'tool_use', 'id': 'c1', 'name': 'browser_open', 'input': {'url': 'https://a'}});
      expect((m[2] as Map)['content'][0], {'type': 'tool_result', 'tool_use_id': 'c1', 'content': 'opened'});
      final a = ByokFetch.toolChatAnswer(ByokKind.anthropic, {
        'content': [{'type': 'text', 'text': 'Calling'}, {'type': 'tool_use', 'id': 'c2', 'name': 'browser_open', 'input': {'url': 'https://b'}}],
        'stop_reason': 'tool_use', 'usage': {'input_tokens': 30, 'output_tokens': 10},
      });
      expect(a.text, 'Calling');
      expect(a.calls.single, {'id': 'c2', 'name': 'browser_open', 'arguments': '{"url":"https://b"}'});
      expect(a.finish, 'tool_calls');
      expect(a.tokens, 40);
    });

    test('Gemini tool step goes through its OpenAI-compatible endpoint', () {
      final p = _prov(kind: ByokKind.gemini, base: 'https://generativelanguage.googleapis.com/v1beta');
      final r = ByokFetch.toolChatRequest(p, 'g-1', 'gemini-x', [
        {'role': 'user', 'content': 'hi'}
      ], [
        {'type': 'function', 'function': {'name': 'browser_open', 'parameters': {}}}
      ]);
      expect(r.url.toString(), 'https://generativelanguage.googleapis.com/v1beta/openai/chat/completions');
      expect(r.headers['Authorization'], 'Bearer g-1');
      expect((jsonDecode(r.body) as Map)['tools'], isNotNull);
    });
  });

  group('every app path', () {
    late Directory tmp;
    late AppState s;
    final bots = <Bot>[];
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('botmodel');
      PathProviderPlatform.instance = _Docs(tmp.path);
      s = AppState()..appVisible = false;
      _store();
      bots
        ..clear()
        ..addAll([
          Bot(id: 'bmlead', name: 'Hodan', role: 'Manager', persona: '', model: '$_pid|gpt-x'),
          Bot(id: 'bmnova', name: 'Nova', role: 'Researcher', persona: '', model: '$_pid|gpt-x-mini'),
          Bot(id: 'bmamal', name: 'Amal', role: 'Analyst', persona: '', model: 'telesia'),
        ]);
      Bots.I.bots.addAll(bots);
    });
    tearDown(() {
      Bots.I.bots.removeWhere((b) => b.id.startsWith('bm'));
      AppState.debugTeamTurn = null;
      Offices.I.queue.clear();
      TeamRun.I.reset();
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('a team\'s one-answer calls (who speaks, plan, combine) use the lead\'s model', () async {
      expect(await s.teamAskForTest(bots[0], '# Who speaks', 'hi'), 'from gpt-x');
      expect(byokCalls, ['$_pid|gpt-x']);
      expect(await s.teamAskForTest(bots[2], '# Who speaks', 'hi'), 'from telesia');
      expect(cloudCalls.single, startsWith('${Cloud.telesia}|office|bg'));
    });

    test('an instant reply in the team chat uses the bot\'s model', () async {
      final o = Office(id: 'obm1', name: 'Lab', members: ['bmlead', 'bmnova', 'bmamal'], chiefId: 'bmlead');
      expect(await s.officeQuickForTest(o, bots[1], 'hi'), 'from gpt-x-mini');
      expect(byokCalls, ['$_pid|gpt-x-mini']);
    });

    test('bot_ask answers on the expert\'s model', () async {
      expect(await s.botConsultForTest(bots[2], bots[1], 'What is the cheapest supplier?'), 'from gpt-x-mini');
      expect(byokCalls, ['$_pid|gpt-x-mini']);
      expect(cloudCalls, isEmpty);
    });

    test('the check-in gate uses the bot\'s model', () async {
      BotLlm.byokCall = (pick, messages, {int? maxTokens}) async {
        byokCalls.add('${pick.provider.id}|${pick.model.id}');
        return 'NO';
      };
      expect(await s.worthWakingForTest(bots[0]), isFalse);
      expect(byokCalls, ['$_pid|gpt-x']);
      expect(cloudCalls, isEmpty);
    });

    test('team turns (office jobs) run on the bot\'s model, and its post starts the teammate waiting for it', () async {
      final o = Office(id: 'obm2', name: 'Lab', members: ['bmlead', 'bmnova', 'bmamal'], chiefId: 'bmlead');
      Offices.I.offices.add(o);
      addTearDown(() => Offices.I.offices.remove(o));
      for (final b in bots) {
        b
          ..convId = 'conv-${b.id}'
          ..active = true;
        s.listsForTest[b.convId] = <ChatMessage>[];
      }
      final seen = <String, Map<String, String>>{};
      AppState.debugTeamTurn = (b, key, system, task, {required model, bool background = true, String? officeJob}) async {
        seen[b.id] = model;
        return b.id == 'bmnova' ? 'Research done: Acme 4.20, Bean Co 4.35 per kg.' : 'Analysis: Acme is the best value.';
      };
      o.watches.add(TeamWatch(id: 'wbm', watcher: 'bmamal', from: 'bmnova', instruction: 'Amal, analyze Nova\'s research once it posts'));
      await s.officeRunForTest(o, bots[1], OfficeJob(officeId: o.id, botId: 'bmnova', kind: 'reply', instruction: 'Nova, research suppliers'));
      expect(seen['bmnova'], {'providerID': _pid, 'modelID': 'gpt-x-mini'});
      expect(o.posts.last.text, contains('Acme 4.20'));
      // Nova's answer started Amal's turn by itself (no owner message in between).
      final next = Offices.I.queue.where((j) => j.officeId == o.id && j.botId == 'bmamal').toList();
      expect(next.single.kind, 'react');
      expect(next.single.depth, 1);
      Offices.I.queue.remove(next.single);
      await s.officeRunForTest(o, bots[2], next.single);
      expect(seen['bmamal'], {'providerID': OcLane.office, 'modelID': Cloud.telesia}, reason: 'Amal is on Telesia: background office lane');
      expect(o.posts.last.text, contains('Acme is the best value'));
      expect(o.posts.last.replyTo, next.single.post, reason: 'the answer links to the post it reacts to');
      Offices.I.queue.removeWhere((j) => j.officeId == o.id);
    });

    test('source: no plain bot call is pinned to Telesia\'s model any more', () {
      final ctl = File('lib/state/bots_controller.dart').readAsStringSync();
      for (final f in ['Future<String> _teamAsk(', 'Future<String> _botConsult(', 'Future<String> _officeQuick(', 'Future<bool> _worthWaking(']) {
        final i = ctl.indexOf(f);
        final body = ctl.substring(i, ctl.indexOf('\n  }\n', i));
        expect(body, contains('BotModelRoute.of('), reason: f);
        expect(body, isNot(contains('model: route.model')), reason: f);
        expect(body, isNot(contains('ref.model')), reason: f);
      }
      // Owner 2026-11-07: office work is governed by each bot's own allowance, not by the account-wide share gate.
      expect(ctl, isNot(contains('final bgPaused')));
      expect(ctl, isNot(contains('!ownModel')));
      expect(ctl, contains('b.overBudget'));
    });
  });
}
