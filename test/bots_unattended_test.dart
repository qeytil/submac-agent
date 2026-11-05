// Bots working with SubMac closed (owner bug 2026-11-05): a bot's scheduled task must run on its own, every hour,
// with the app closed. These cover the Dart side of that path (docs/bots-background.md): alarms that arrive before
// SubMac is ready, the foreground line, held wakes retried without the screen, permissions and approvals in a run
// nobody watches, and the owner's own Telegram. The engine is mocked (AppState.debugRunAgent).
//
// Run: flutter test test/bots_unattended_test.dart
// ignore_for_file: invalid_use_of_visible_for_testing_member, invalid_use_of_protected_member, depend_on_referenced_packages
import 'dart:io';

import 'package:agent/app_state.dart';
import 'package:agent/models.dart';
import 'package:agent/services/bg_runs.dart';
import 'package:agent/services/bot_powers.dart';
import 'package:agent/services/bots.dart';
import 'package:agent/services/offices.dart';
import 'package:agent/services/opencode.dart';
import 'package:agent/services/system_bridge.dart';
import 'package:agent/services/system_tools.dart';
import 'package:agent/services/tools.dart';
import 'package:agent/services/trust.dart';
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

Future<void> _settle([int ms = 20]) => Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AlarmGate: an alarm that comes before SubMac is ready waits instead of being dropped', () {
    test('alarms wait, then run in the order they came once SubMac is ready', () async {
      final g = AlarmGate();
      final ran = <String>[];
      final a = g.run(() async => ran.add('a'));
      final b = g.run(() async => ran.add('b'));
      await _settle();
      expect(ran, isEmpty, reason: 'ran before the bots and scheduled tasks were loaded');
      g.open();
      await Future.wait([a, b]);
      expect(ran, ['a', 'b']);
      await g.run(() async => ran.add('c'));
      expect(ran, ['a', 'b', 'c'], reason: 'once open, an alarm runs at once');
    });

    test('a start-up that never finishes does not swallow the alarm', () async {
      final g = AlarmGate(maxWait: const Duration(milliseconds: 30));
      var ran = false;
      await g.run(() async => ran = true);
      expect(ran, isTrue);
    });
  });

  group('BgRun rules', () {
    test('unattended: a bot wake or a scheduled run that is not on screen', () {
      expect(BgRun.unattended(wakeKind: 'message', scheduled: false, onScreen: false), isTrue);
      expect(BgRun.unattended(wakeKind: 'work', scheduled: false, onScreen: false), isTrue);
      expect(BgRun.unattended(scheduled: true, onScreen: false), isTrue);
      expect(BgRun.unattended(wakeKind: 'chat', scheduled: false, onScreen: false), isFalse, reason: 'the owner is chatting');
      expect(BgRun.unattended(scheduled: false, onScreen: false), isFalse, reason: "the owner's own chat");
      expect(BgRun.unattended(wakeKind: 'message', scheduled: true, onScreen: true), isFalse, reason: 'the owner is looking');
    });

    test('the foreground line is "<Bot name> · <task title>"', () {
      expect(BgRun.line('Nova', BgRun.title('Send me local and international news every hour in Telegram')),
          'Nova · Send me local and international news every hour…');
      expect(BgRun.line('Nova', BgRun.title('')), 'Nova · Check-in');
      expect(BgRun.line('Nova', BgRun.title('(retry) Daily brief\nmore lines')), 'Nova · Daily brief');
      expect(BgRun.line('', 'X'), 'SubMac · X');
    });

    test('permissions with nobody watching: what the owner already allowed goes, the rest is refused at once', () {
      expect(BgRun.permission(perm: 'bash', fullAccess: false, botLevel: BotTrust.levelNew), 'reject');
      expect(BgRun.permission(perm: 'bash', fullAccess: false, botLevel: BotTrust.levelTrusted), 'once');
      expect(BgRun.permission(perm: 'bash', fullAccess: true, botLevel: BotTrust.levelNew), 'once');
      expect(BgRun.permission(perm: 'external_directory', fullAccess: false, botLevel: BotTrust.levelTrusted), 'reject');
      expect(BgRun.permission(perm: 'doom_loop', fullAccess: true, botLevel: BotTrust.levelTrusted), 'reject');
      expect(BgRun.needs('Run this command? curl https://example.com'), startsWith('Needs your OK: Run this command?'));
    });
  });

  group('opencode asks in a run nobody watches never wait on a card', () {
    late List<String> permits;
    late List<String> asked;
    late List<String> refused;
    late List<List<List<String>>?> answers;
    OpenCodeAsks asks(String? Function(String conv, String perm) unattended) => OpenCodeAsks(
          ask: (conv, title, prompt, options) async {
            asked.add(title);
            return OpenCodeAsks.allow;
          },
          permit: (id, reply) async => permits.add(reply),
          answer: (id, a) async => answers.add(a),
          convOf: (s) => 'conv-$s',
          unattended: unattended,
          refused: (conv, title, detail) => refused.add('$conv|$title|$detail'),
        );
    setUp(() {
      permits = [];
      asked = [];
      refused = [];
      answers = [];
    });
    Map<String, dynamic> perm(String id, String p) => {
          'type': 'permission.asked',
          'properties': {'id': id, 'sessionID': 's1', 'permission': p, 'patterns': ['curl x'], 'metadata': {'command': 'curl x'}},
        };

    test('refused at once, and the owner is told what was needed', () async {
      final a = asks((conv, p) => 'reject');
      expect(await a.handle(perm('p1', 'bash')), isTrue);
      expect(permits, ['reject']);
      expect(asked, isEmpty, reason: 'a card nobody can see held the run until the app opened');
      expect(refused.single, 'conv-s1|Run this command?|curl x');
    });

    test('allowed at once when the owner already allowed it', () async {
      final a = asks((conv, p) => 'once');
      await a.handle(perm('p2', 'bash'));
      expect(permits, ['once']);
      expect(refused, isEmpty);
      expect(asked, isEmpty);
    });

    test("a question is skipped; the owner's own chat still asks", () async {
      final a = asks((conv, p) => conv == 'conv-s1' ? 'reject' : null);
      await a.handle({
        'type': 'question.asked',
        'properties': {'id': 'q1', 'sessionID': 's1', 'questions': [
          {'question': 'Which city?', 'options': [{'label': 'Mogadishu'}]},
        ]},
      });
      expect(answers, [null]);
      expect(asked, isEmpty);
      final watched = asks((conv, p) => null);
      await watched.handle(perm('p3', 'bash'));
      expect(asked, ['Run this command?']);
      expect(permits, ['once']);
    });
  });

  group('a bot scheduled task with the app closed (mock engine)', () {
    late Directory tmp;
    late AppState s;
    late Bot b;
    late List<String> started;
    late List<bool> unattendedSeen;
    late List<(String, Map<String, dynamic>?)> calls;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      tmp = await Directory.systemTemp.createTemp('bgbots');
      PathProviderPlatform.instance = _Docs(tmp.path);
      await Bots.I.init();
      b = Bot(id: 'bg1', name: 'Nova', role: 'Researcher', persona: '')
        ..active = true
        ..convId = 'conv-bg1';
      b.routines.add(BotRoutine(id: 'news', time: '09:00', days: 'daily', kind: 'message', instruction: 'Send me the news on Telegram.'));
      Bots.I.bots.add(b);
      Bots.readyWait = const Duration(milliseconds: 40);
      Bots.clock = () => DateTime(2026, 11, 5, 9, 0);
      s = AppState()..appVisible = false;
      s.listsForTest[b.convId] = <ChatMessage>[];
      started = [];
      unattendedSeen = [];
      calls = [];
      SystemBridge.debugCalls = (m, a) => calls.add((m, a));
      AppState.debugRunAgent = (app, run) async {
        started.add(run.convId);
        unattendedSeen.add(app.unattendedRun(run.convId));
      };
      Bots.I.onWake = s.botWakeForTest;
    });
    tearDown(() async {
      AppState.debugRunAgent = null;
      SystemBridge.debugCalls = null;
      Bots.readyWait = const Duration(seconds: 10);
      Bots.clock = DateTime.now;
      Bots.I.onWake = null;
      Bots.I.bots.remove(b);
      BgRun.heldRetries = const [Duration(seconds: 15), Duration(seconds: 45), Duration(minutes: 2)];
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('an alarm before SubMac is ready runs once it is, unattended, with "<Bot> · <task>" on the notification', () async {
      s.repo.testUserId = 'u1';
      final fired = s.onAlarmForTest(Bots.alarmId(b, 'news'));
      await _settle();
      expect(started, isEmpty, reason: 'start-up has not finished');
      s.openAlarmGateForTest();
      await fired;
      await _settle();
      expect(started, ['conv-bg1']);
      expect(unattendedSeen, [true], reason: 'the run must know nobody is watching');
      final keep = calls.where((c) => c.$1 == 'keepAlive' && c.$2?['on'] == true).map((c) => c.$2?['text']).toList();
      expect(keep, contains('Nova · Send me the news on Telegram.'));
    });

    test('a wake held because the account was not restored yet runs on a retry, without the home screen', () async {
      BgRun.heldRetries = const [Duration(milliseconds: 10), Duration(milliseconds: 10)];
      s.openAlarmGateForTest();
      await s.onAlarmForTest(Bots.alarmId(b, 'news'));
      await _settle(60);
      expect(started, isEmpty);
      expect(Bots.I.hasHeldWakes, isTrue);
      final retry = s.retryHeldWakesForTest();
      s.repo.testUserId = 'u1'; // the session is restored meanwhile
      await retry;
      await _settle();
      expect(started, ['conv-bg1']);
      expect(Bots.I.hasHeldWakes, isFalse);
    });

    test('an approval in a run nobody watches waits minutes, not hours, then says what is needed', () async {
      BgRun.approvalWait = const Duration(milliseconds: 30);
      addTearDown(() => BgRun.approvalWait = const Duration(minutes: 3));
      await Offices.I.init();
      s.botWakeConvsForTest[b.convId] = 'message';
      final req = ActionRequest(title: 'Send this message?', body: '', detail: 'hello')..kind = 'send';
      final g = ToolGate(ask: req, kind: 'send', worker: b);
      final ok = await s.presentApproval(g, 'api_call', const {}, b.convId).timeout(const Duration(seconds: 2));
      expect(ok, isFalse);
      await _settle();
      final notes = calls.where((c) => c.$1 == 'notify').map((c) => '${c.$2?['body']}').toList();
      expect(notes.any((n) => n.contains('Needs your OK: Send this message?')), isTrue, reason: '$notes');
      expect(b.journal.last.text, contains('Needs your OK'));
    });
  });

  group('a scheduled task fired before the Scheduler loaded', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({
        'scheduled':
            '[{"id":"s1","task":"Send me local and international news","next":"2026-11-05T09:00:00.000","repeat":"hourly","uid":"u1","bot":"nb"}]',
      });
    });

    test('runs once the Scheduler has loaded (it used to be dropped), the next hour is armed with its line', () async {
      final calls = <(String, Map<String, dynamic>?)>[];
      SystemBridge.debugCalls = (m, a) => calls.add((m, a));
      addTearDown(() => SystemBridge.debugCalls = null);
      final nb = Bot(id: 'nb', name: 'Nova', role: 'News', persona: '')..active = true;
      Bots.I.bots.add(nb);
      addTearDown(() => Bots.I.bots.remove(nb));
      final s = AppState();
      final ran = <String>[];
      Scheduler.I.runTask = (t) async => ran.add(t.id);
      addTearDown(() => Scheduler.I.runTask = null);
      final fired = s.onAlarmForTest('s1');
      await Scheduler.I.init(uid: 'u1');
      s.openAlarmGateForTest();
      await fired;
      expect(ran, ['s1']);
      final labels = calls.where((c) => c.$1 == 'scheduleAlarm' && c.$2?['id'] == 's1').map((c) => c.$2?['label']).toSet();
      expect(labels, contains('Nova · Send me local and international news'));
      await Scheduler.I.useAccount('');
    });
  });

  group("bot_telegram: the owner's own Telegram", () {
    late Bot b;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await Bots.I.init();
      b = Bot(id: 'tg1', name: 'Nova', role: 'News', persona: '')
        ..active = true
        ..convId = 'conv-tg1';
      Bots.I.bots.add(b);
    });
    tearDown(() {
      Bots.telegramSend = null;
      Bots.I.bots.remove(b);
    });

    test('sends to the paired chat with no approval and is never switched off with a power', () async {
      final sent = <String>[];
      Bots.telegramSend = (text, files) async {
        sent.add(text);
        return null;
      };
      expect(await Bots.I.execute('bot_telegram', {'text': 'Top news: ...'}, b.convId), 'Sent to the owner on Telegram.');
      expect(sent, ['Top news: ...']);
      expect(Bots.names, contains('bot_telegram'));
      expect(BotPowers.allowed({'apps', 'web', 'phone', 'files', 'browser'}, 'bot_telegram'), isTrue);
    });

    test('not connected: says how to connect it', () async {
      final r = await Bots.I.execute('bot_telegram', {'text': 'hi'}, b.convId);
      expect(r, contains('Settings > Telegram'));
    });
  });
}
