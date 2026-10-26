// Usage accounting regressions (PR-9 fix/usage-accounting): CB-20, CB-40 (app part), CB-45 (app part).
// CB-20: a bot's daily budget and Bot Activity counted raw tokens (prompt + completion), owner chats included: 5.9x
// what the server bills (9.7x on cached wakes). Now: billing units (uncached×0.3 + cached×0.1 + out×1, rounded up per
// call, weights from /status), and only the bot's own work (a wake, team work) counts.
// CB-45: every run in a bot's chat went out as `source: bot`, so the owner's own chats were billed to the bots' share.
// Now a wake sends `bot` and what the owner types sends `bot-chat` (ai-chat v43 bills it to the chat bucket); a server
// that answers 400 for an unknown source gets `agent`.
// CB-40: a browser step whose screen did not change sent the same picture again; model pictures were 720 px wide but
// up to 1600 px tall at JPEG 62; the allowance notice opened a modal sheet over the composer.
// The "runner" tests drive the real task loop (send / startBackgroundTask -> _runAgent -> Genkit core -> LlmClient)
// against a fake ai-chat through LlmClient.testClient.
//
// Run: flutter test test/chat_regress_usage_test.dart
// ignore_for_file: invalid_use_of_visible_for_testing_member, depend_on_referenced_packages
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent/agent/core.dart';
import 'package:agent/app_state.dart';
import 'package:agent/models.dart';
import 'package:agent/screens/billing/billing_notice_sheet.dart';
import 'package:agent/services/billing/billing_models.dart';
import 'package:agent/services/billing/billing_service.dart';
import 'package:agent/services/bots.dart';
import 'package:agent/services/browser/shots.dart';
import 'package:agent/services/browser_agent.dart';
import 'package:agent/services/browser_jobs.dart';
import 'package:agent/services/cloud.dart';
import 'package:agent/services/llm_client.dart';
import 'package:agent/services/usage_accounting.dart';
import 'package:agent/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'billing/fake_billing_api.dart';

// ------------------------------------------------------------------ helpers

/// The three live calls of chatbugs4/live4_cb20.json (a bot chat, 2026-10-25): the provider's usage blocks, and how
/// much the server took off the balance for the first two (50,100,000 -> 50,096,337 -> 50,095,082).
const _live = [
  {'prompt_tokens': 12105, 'completion_tokens': 41, 'total_tokens': 12146, 'prompt_tokens_details': {'cached_tokens': 48}},
  {'prompt_tokens': 12105, 'completion_tokens': 36, 'total_tokens': 12141, 'prompt_tokens_details': {'cached_tokens': 12064}},
  {'prompt_tokens': 12105, 'completion_tokens': 37, 'total_tokens': 12142, 'prompt_tokens_details': {'cached_tokens': 12064}},
];

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

String _chunk(Map<String, dynamic> delta, {String? finish, Map<String, dynamic>? usage}) => 'data: ${jsonEncode({
      'choices': [
        {'index': 0, 'delta': delta, 'finish_reason': finish}
      ],
      if (usage != null) 'usage': usage,
    })}\n\n';

String _sse(String text, Map<String, dynamic> usage) =>
    ': ping\n\n${_chunk({'content': text})}${_chunk({}, finish: 'stop', usage: usage)}data: [DONE]\n\n';

/// A fake ai-chat: every streamed call answers [text] with the next usage block of [_live] (the last one repeats) and
/// records the `x-submac-source` it was sent with. [refuse]: sources answered with a 400 "unknown source".
class _FakeCloud {
  _FakeCloud({this.text = 'Done.', this.refuse = const {}});
  final String text;
  final Set<String> refuse;
  final sources = <String>[];
  final refused = <String>[];

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
        final src = req.headers['x-submac-source'] ?? '';
        if (refuse.contains(src)) {
          refused.add(src);
          final err = jsonEncode({'error': {'code': 'bad_source', 'message': 'unknown source: $src'}});
          return http.StreamedResponse(Stream.value(utf8.encode(err)), 400, headers: {'content-type': 'application/json'});
        }
        sources.add(src);
        final u = _live[(sources.length - 1).clamp(0, _live.length - 1)];
        return http.StreamedResponse(Stream.value(utf8.encode(_sse(text, u))), 200, headers: {'content-type': 'text/event-stream'});
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
  LlmClient.testHeaders = (source) async => {'Content-Type': 'application/json', 'x-submac-source': source};
  LlmClient.testClient = cloud.client();
  final s = AppState();
  s.repo.testUserId = 'u-usage-${tmp.path.hashCode}';
  await s.local.init();
  return s;
}

/// A bot with its own chat, open on screen (the owner is looking at it).
Future<Bot> _botChat(AppState s, String id) async {
  final c = await s.repo.createConversation(title: 'Nova');
  final b = Bot(id: id, name: 'Nova', role: 'Researcher', persona: '')
    ..active = true
    ..convId = c.id;
  Bots.I.bots.add(b);
  s.conversations = [c];
  s.currentId = c.id;
  s.messages = [];
  s.listsForTest[c.id] = s.messages;
  return b;
}

class _UsageHooks extends CoreHooks {
  final seen = <Reply>[];
  @override
  bool get cancelled => false;
  @override
  Future<Turn> buildTurn(int step, String? notes) async => Turn(step: step, payload: const [
        {'role': 'user', 'content': 'hi'}
      ]);
  @override
  Future<String> runTool(ToolCall call, Map<String, dynamic> args, {Object? approved}) async => 'ok';
  @override
  void usage(Reply r) => seen.add(r);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('cbusage');
    UsageUnits.resetWeights();
    UsageSource.botChatRefused = false;
  });
  tearDown(() async {
    LlmClient.testClient = http.Client();
    LlmClient.testHeaders = null;
    UsageUnits.resetWeights();
    UsageSource.botChatRefused = false;
    Bots.I.bots.removeWhere((b) => b.id.startsWith('u9'));
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  // ================================================================== CB-20
  group('CB-20 the bot budget counts what the server bills', () {
    test('the 3-call live fixture is about 6,174 units (not 36,429 raw tokens)', () {
      final units = [for (final u in _live) UsageUnits.of(u['prompt_tokens'] as int, u['completion_tokens'] as int, cached: UsageUnits.cachedOf(u))];
      // Per call, rounded up the way the server rounds: the first two match the live balance drops exactly.
      expect(units, [3663, 1255, 1256]);
      expect(units.reduce((a, b) => a + b), 6174);
      final raw = _live.fold<int>(0, (a, u) => a + (u['total_tokens'] as int));
      expect(raw, 36429);
      expect(raw / 6174, closeTo(5.9, 0.05), reason: 'the over-count the app had');
    });

    test('weights come from /status when it sends them; the server defaults otherwise', () {
      UsageUnits.noteStatus({'weights': {'input': 0.5, 'cached': 0.2, 'output': 2}});
      expect(UsageUnits.of(1000, 100, cached: 400), (600 * 0.5 + 400 * 0.2 + 100 * 2).ceil());
      UsageUnits.noteStatus({'billing': {'input_weight': 0.25}});
      expect(UsageUnits.wIn, 0.25);
      expect(UsageUnits.wCached, UsageUnits.defaultCached);
      UsageUnits.noteStatus({'ratio': 0.1, 'state': 'ok'});
      expect([UsageUnits.wIn, UsageUnits.wCached, UsageUnits.wOut], [0.3, 0.1, 1.0]);
      // A call with no counts at all falls back to its estimate.
      expect(UsageUnits.of(0, 0, fallback: 77), 77);
      // Cached never exceeds the prompt.
      expect(UsageUnits.of(100, 0, cached: 500), 10);
    });

    test('the client reads the cached part of the prompt from the stream', () async {
      LlmClient.testHeaders = (_) async => {'Content-Type': 'application/json'};
      LlmClient.testClient = MockClient.streaming((req, body) async {
        await body.drain<void>();
        return http.StreamedResponse(Stream.value(utf8.encode(_sse('ok', _live[0]))), 200, headers: {'content-type': 'text/event-stream'});
      });
      final r = await LlmClient().streamChat(provider: Cloud.provider, model: Cloud.submac, messages: const [
        {'role': 'user', 'content': 'hi'}
      ], onDelta: (_) {});
      expect([r.tokensIn, r.tokensOut, r.tokensCached], [12105, 41, 48]);
      expect(UsageUnits.ofResult(r), 3663);
    });

    test('the cached count reaches the usage hook through the Genkit core', () async {
      final h = _UsageHooks();
      final core = AgentCore(hooks: h, tools: const [], transport: (t) async => LlmResult('Done.', const [], 'stop', 12141, 12105, 36, 12064));
      await core.run();
      expect(h.seen, isNotEmpty);
      final r = h.seen.first;
      expect([r.tokensIn, r.tokensOut, r.tokensCached], [12105, 36, 12064]);
      expect(UsageUnits.of(r.tokensIn, r.tokensOut, cached: r.tokensCached), 1255);
    });

    test('runner: what the owner types to a bot never counts against its budget', () async {
      final cloud = _FakeCloud(text: 'Here is the plan.');
      final s = await _app(cloud, tmp);
      final b = await _botChat(s, 'u9a');
      unawaited(s.send('Make me a sales plan', const []));
      await _until(() => s.runs.isNotEmpty, ms: 2000);
      await _until(() => s.runs.isEmpty, ms: 8000);
      expect(cloud.sources, isNotEmpty);
      expect(b.tokensTodayNow, 0, reason: 'an owner chat was counted as the bot\'s own work');
    });

    test('runner: a bot\'s own wake counts billing units, not raw tokens', () async {
      final cloud = _FakeCloud(text: 'Checked the inbox, nothing new.');
      final s = await _app(cloud, tmp);
      final b = await _botChat(s, 'u9b');
      s.currentId = null; // the owner is somewhere else
      s.botWakeConvsForTest[b.convId] = 'work';
      final err = await s.startBackgroundTask('$botWakeMark[Woken: check-in]\nThis is your regular check-in.', reuseConvId: b.convId);
      expect(err, isNull);
      await _until(() => s.runs.isNotEmpty, ms: 2000);
      await _until(() => s.runs.isEmpty, ms: 8000);
      final calls = cloud.sources.length;
      expect(calls, greaterThan(0));
      final want = [3663, 1255, 1256, for (var i = 3; i < calls; i++) 1256].take(calls).reduce((a, c) => a + c);
      final raw = [12146, 12141, 12142, for (var i = 3; i < calls; i++) 12142].take(calls).reduce((a, c) => a + c);
      expect(b.tokensTodayNow, want, reason: 'raw would be $raw');
    });
  });

  // ================================================================== CB-45
  group('CB-45 owner chats with a bot are not bot work', () {
    test('source table: wake = bot, owner = bot-chat, office = office, own chat = agent', () {
      expect(UsageSource.pick(officeJob: false, botConv: true, botWork: true), 'bot');
      expect(UsageSource.pick(officeJob: false, botConv: true, botWork: false), 'bot-chat');
      expect(UsageSource.pick(officeJob: true, botConv: true, botWork: true), 'office');
      expect(UsageSource.pick(officeJob: false, botConv: false, botWork: false), 'agent');
      expect(UsageSource.pick(officeJob: false, botConv: false, botWork: false, sideRun: true), 'side');
      UsageSource.botChatRefused = true;
      expect(UsageSource.pick(officeJob: false, botConv: true, botWork: false), 'agent');
      expect(UsageSource.pick(officeJob: false, botConv: true, botWork: true), 'bot');
      expect(UsageSource.isBotWork('bot-chat'), isFalse);
      expect(UsageSource.isBotWork('bot'), isTrue);
      expect(UsageSource.isBotWork('office'), isTrue);
    });

    test('the app picks the source from the chat: wake kinds, the owner\'s first-job chat, plain chats', () async {
      final s = await _app(_FakeCloud(), tmp);
      final b = await _botChat(s, 'u9c');
      expect(s.usageSourceForTest(b.convId), 'bot-chat');
      s.botWakeConvsForTest[b.convId] = 'work';
      expect(s.usageSourceForTest(b.convId), 'bot');
      s.botWakeConvsForTest[b.convId] = 'chat'; // first job, the owner is watching
      expect(s.usageSourceForTest(b.convId), 'bot-chat');
      s.botWakeConvsForTest.remove(b.convId);
      expect(s.usageSourceForTest('my-own-chat'), 'agent');
    });

    test('runner: the owner typing in a bot chat sends bot-chat', () async {
      final cloud = _FakeCloud(text: 'Sure.');
      final s = await _app(cloud, tmp);
      await _botChat(s, 'u9d');
      unawaited(s.send('What did you find today?', const []));
      await _until(() => s.runs.isNotEmpty, ms: 2000);
      await _until(() => s.runs.isEmpty, ms: 8000);
      expect(cloud.sources, isNotEmpty);
      expect(cloud.sources.toSet(), {'bot-chat'});
    });

    test('runner: a server that does not know bot-chat (400) gets agent, and the reply still arrives', () async {
      final cloud = _FakeCloud(text: 'Sure, here it is.', refuse: {'bot-chat'});
      final s = await _app(cloud, tmp);
      await _botChat(s, 'u9e');
      unawaited(s.send('Summarise the week', const []));
      await _until(() => s.runs.isNotEmpty, ms: 2000);
      await _until(() => s.runs.isEmpty, ms: 8000);
      expect(cloud.refused, ['bot-chat'], reason: 'asked once, then remembered');
      expect(cloud.sources.toSet(), {'agent'});
      expect(s.messages.where((m) => m.role == 'assistant').last.content, 'Sure, here it is.');
      expect(s.messages.any((m) => m.error != null), isFalse);
    });

    test('runner: a bot\'s own wake still sends bot', () async {
      final cloud = _FakeCloud(text: 'Nothing new.');
      final s = await _app(cloud, tmp);
      final b = await _botChat(s, 'u9f');
      s.currentId = null;
      s.botWakeConvsForTest[b.convId] = 'work';
      await s.startBackgroundTask('$botWakeMark[Woken: check-in]\nThis is your regular check-in.', reuseConvId: b.convId);
      await _until(() => s.runs.isNotEmpty, ms: 2000);
      await _until(() => s.runs.isEmpty, ms: 8000);
      expect(cloud.sources, isNotEmpty);
      expect(cloud.sources.toSet(), {'bot'});
    });
  });

  // ================================================================== CB-40
  group('CB-40 browser pictures and the allowance notice', () {
    Uint8List jpg(int w, int h, {int shade = 230, bool typed = false}) {
      final im = img.Image(width: w, height: h);
      img.fill(im, color: img.ColorRgb8(shade, shade, shade));
      if (typed) img.fillRect(im, x1: w ~/ 4, y1: h ~/ 3, x2: w ~/ 4 + 60, y2: h ~/ 3 + 24, color: img.ColorRgb8(20, 20, 20));
      return Uint8List.fromList(img.encodeJpg(im));
    }

    setUp(ShotGate.reset);

    test('a tall phone screenshot is at most 1024 px on its long edge, JPEG 55', () {
      final s = Shots.processSync(jpg(1080, 2400), const [])!;
      expect(s.width, lessThanOrEqualTo(Shots.modelWidth));
      expect(s.height, lessThanOrEqualTo(1024));
      expect(s.width > s.height ? s.width : s.height, lessThanOrEqualTo(1024));
      expect(Shots.modelQuality, 55);
      final back = img.decodeJpg(s.marked)!;
      expect(back.height, lessThanOrEqualTo(1024));
    });

    test('an unchanged page sends no new picture; a changed one does', () {
      final a = Shots.processSync(jpg(720, 1280), const [])!;
      final same = Shots.processSync(jpg(720, 1280), const [])!;
      final typed = Shots.processSync(jpg(720, 1280, typed: true), const [])!;
      expect(ShotGate.fresh('1|job', a.fine), isTrue, reason: 'the first look always goes');
      expect(ShotGate.fresh('1|job', same.fine), isFalse, reason: 'the same screen again');
      expect(ShotGate.fresh('1|job', typed.fine), isTrue, reason: 'a few typed letters are a change');
      expect(ShotGate.fresh('2|job', typed.fine), isTrue, reason: 'another tab or task has its own first look');
    });

    test('payload: after a step whose screen did not change, no picture goes to the model (not even the older one)', () {
      BrowserJobs.I.canSee = () => true;
      final j = BrowserJob('u9t', 'x', '', 'chatU', 20);
      BrowserAgent.I.shotsByCall['shotU1'] = Uint8List.fromList([1, 2, 3]);
      j.steps.add(BrowserJobs.stepForTest(
          ToolCall(id: 'shotU1', name: 'browser_click', arguments: '{"id":1}'), 'Effect: the page changed.',
          shot: 'shotU1'));
      final first = BrowserJobs.I.payloadFor(j);
      expect(first.where((m) => m['content'] is List).length, 1, reason: 'the fresh picture goes');
      // The next action changed nothing on screen: observe() keeps no picture for it and marks it.
      ShotGate.noteSame('shotU2');
      j.steps.add(BrowserJobs.stepForTest(
          ToolCall(id: 'shotU2', name: 'browser_scroll', arguments: '{}'), 'Effect: nothing changed. ${ShotGate.sameText}',
          shot: 'shotU2'));
      final next = BrowserJobs.I.payloadFor(j);
      expect(next.where((m) => m['content'] is List), isEmpty, reason: 'the same picture was sent again');
      BrowserAgent.I.shotsByCall.remove('shotU1');
    });

    testWidgets('with the allowance notice shown, the composer stays reachable', (t) async {
      SharedPreferences.setMockInitialValues({});
      final b = Billing(api: FakeBillingApi());
      final n = BillingNotice.tryParse(429, {
        'error': {'code': 'limit_daily', 'message': 'You have used today\'s replies.'},
        'billing': {'resets_at': DateTime.now().toUtc().add(const Duration(hours: 5)).toIso8601String()},
      })!;
      b.noteNotice(n);
      final focus = FocusNode();
      addTearDown(focus.dispose);
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: Column(children: [
            Expanded(child: ListView(children: [BillingNoticeCard(notice: n, isLast: true, billing: b)])),
            BillingNoticeBanner(billing: b),
            TextField(key: const ValueKey('composer'), focusNode: focus),
          ]),
        ),
      ));
      await t.pumpAndSettle();
      expect(find.byType(BillingNoticeSheet), findsNothing, reason: 'a modal sheet covers the composer');
      await t.tap(find.byKey(const ValueKey('composer')));
      await t.pump();
      expect(focus.hasFocus, isTrue, reason: 'the composer could not be reached');
      await t.enterText(find.byKey(const ValueKey('composer')), 'ok');
      expect(find.text('ok'), findsOneWidget);
      // The notice is a banner above it, and it can be dismissed.
      expect(find.byKey(const ValueKey('billing-notice-banner')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('billing-banner-close')));
      await t.pump();
      expect(find.byKey(const ValueKey('billing-notice-banner')), findsNothing);
    });
  });
}
