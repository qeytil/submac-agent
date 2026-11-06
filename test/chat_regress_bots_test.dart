// Bots and routines regressions (PR-5 fix/bots-routines): CB-16, CB-21, CB-29, CB-35, CB-46.
// The CB-16 and CB-35 groups start from the round-2/round-4 probes (test/zz_chat_bughunt2_test.dart,
// test/zz_bughunt4_bots_test.dart on chat-bughunt-4-bots), with their assertions unchanged.
//
// Run: flutter test test/chat_regress_bots_test.dart
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member, depend_on_referenced_packages
import 'dart:convert';
import 'dart:io';

import 'package:agent/app_state.dart';
import 'package:agent/models.dart';
import 'package:agent/screens/bots_workspace.dart';
import 'package:agent/services/bot_status.dart';
import 'package:agent/services/bots.dart';
import 'package:agent/theme.dart';
import 'package:agent/widgets/composer.dart';
import 'package:agent/widgets/message_view.dart' show AttachmentChip;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:provider/provider.dart';
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

Bot _bot(String id, String name, String role) => Bot(id: id, name: name, role: role, persona: '')
  ..active = true
  ..convId = 'conv-$id';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ---------------------------------------------------------------- CB-16 Bots workspace keeps showing the old bot
  group('CB-16 the Bots workspace follows a chat opened from outside (notification tap)', () {
    Widget app(AppState s) => ChangeNotifierProvider<AppState>.value(
          value: s,
          child: MaterialApp(
            theme: buildTheme(Brightness.light),
            builder: (context, child) => MediaQuery(
              data: const MediaQueryData(size: Size(400, 860), padding: EdgeInsets.only(top: 24), disableAnimations: true),
              child: child!,
            ),
            home: const BotsWorkspace(),
          ),
        );

    setUp(() {
      SharedPreferences.setMockInitialValues({'office_bg_asked': true});
      BotStatus.I.reset();
      RailPins.I.reset();
      Composer.drafts.clear();
      Composer.attachmentDrafts.clear();
      BotsWorkspace.debugOpenBot = (s, b) async {
        s.currentId = b.convId;
        s.messages = [ChatMessage(id: 'm-${b.id}', role: 'assistant', content: 'Hello from ${b.name}')];
        s.loadingMessages = false;
        s.notifyListeners();
      };
      final chief = _bot('chief', 'Chief', 'Chief of staff');
      Bots.I.bots.addAll([chief, _bot('nova', 'Nova', 'Researcher')]);
      Bots.I.chiefId = chief.id;
    });
    tearDown(() {
      BotsWorkspace.debugOpenBot = null;
      Bots.I.bots.clear();
      Bots.I.chiefId = '';
      BotStatus.I.reset();
    });

    testWidgets('a bot notification for Nova tapped while the Chief is on screen: what you type goes where you look', (t) async {
      t.view.physicalSize = const Size(400, 860);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final s = AppState();
      await t.pumpWidget(app(s));
      await t.pumpAndSettle();
      final ws = t.state<BotsWorkspaceState>(find.byType(BotsWorkspace));
      expect(ws.active, 'b:chief');
      // _onNotificationTap('conv/<nova conv>') -> openConversation(novaConv): the open chat changes under the workspace.
      s.currentId = 'conv-nova';
      s.messages = [ChatMessage(id: 'n1', role: 'assistant', content: 'Nova found 3 suppliers')];
      s.notifyListeners();
      await t.pumpAndSettle();
      final shownChief = find.textContaining('Hello from Chief').evaluate().isNotEmpty;
      // The composer sends to state.currentId (Nova). The screen must then be Nova's chat, not the Chief's.
      expect(ws.active == 'b:nova' || !shownChief, isTrue,
          reason: 'the workspace still shows the Chief (active=${ws.active}, Chief\'s messages on screen=$shownChief) while the '
              'composer now sends to ${s.currentId}: the user writes to Nova believing they talk to the Chief');
      expect(ws.active, 'b:nova');
      expect(BotStatus.I.viewing, 'b:nova', reason: 'Nova\'s ring must count as read, the Chief\'s no longer');
    });

    testWidgets('a chat that is not a bot\'s, opened from outside, closes the workspace instead of hiding under it', (t) async {
      t.view.physicalSize = const Size(400, 860);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final s = AppState();
      // The workspace pushed over the main chat, the way the app opens it.
      await t.pumpWidget(ChangeNotifierProvider<AppState>.value(
        value: s,
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          builder: (context, child) => MediaQuery(
            data: const MediaQueryData(size: Size(400, 860), padding: EdgeInsets.only(top: 24), disableAnimations: true),
            child: child!,
          ),
          home: Builder(builder: (context) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (find.byType(BotsWorkspace).evaluate().isEmpty) {
                Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const BotsWorkspace()));
              }
            });
            return const Scaffold(body: Text('main chat'));
          }),
        ),
      ));
      await t.pumpAndSettle();
      final ws = t.state<BotsWorkspaceState>(find.byType(BotsWorkspace));
      expect(ws.active, 'b:chief');
      s.currentId = 'conv-plain';
      s.messages = [ChatMessage(id: 'p1', role: 'assistant', content: 'Your flight is booked')];
      s.notifyListeners();
      await t.pumpAndSettle();
      expect(find.byType(BotsWorkspace), findsNothing,
          reason: 'the Chief\'s chat is still on screen while the composer sends to ${s.currentId}');
    });

    testWidgets('the workspace counts itself open, so a bot notification opens that bot in place', (t) async {
      t.view.physicalSize = const Size(400, 860);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final s = AppState();
      expect(BotStatus.I.workspaces, 0);
      await t.pumpWidget(app(s));
      await t.pumpAndSettle();
      expect(BotStatus.I.workspaces, 1);
      await t.pumpWidget(const SizedBox());
      await t.pumpAndSettle();
      expect(BotStatus.I.workspaces, 0);
    });
  });

  // ---------------------------------------------------------------- CB-35 / CB-21 routine alarms
  group('CB-35 / CB-21 routines run once per slot, and a missed one catches up', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      Bots.clock = DateTime.now;
      await Bots.I.init();
      Bots.I.bots.removeWhere((b) => b.id.startsWith('cb4'));
    });
    tearDown(() {
      Bots.clock = DateTime.now;
      Bots.I.onWake = null;
      Bots.I.bots.removeWhere((b) => b.id.startsWith('cb4'));
    });

    Bot bot({String time = '09:00'}) {
      final b = Bot(id: 'cb4ledger', name: 'Ledger', role: 'Bookkeeper', persona: '')
        ..active = true
        ..convId = 'conv-cb4';
      b.routines.add(BotRoutine(id: 'rq', time: time, days: 'daily', kind: 'message', instruction: 'Send me one bookkeeping tip.'));
      Bots.I.bots.add(b);
      return b;
    }

    // The round-4 probe, unchanged (it runs at the real time of day, so the slot is whatever slot "now" falls in).
    test('CB-35: the same routine alarm delivered twice wakes the bot once', () async {
      final b = bot();
      var wakes = 0;
      Bots.I.onWake = (bot, reason, instruction, kind) async {
        wakes++;
        await Future<void>.delayed(const Duration(milliseconds: 30));
      };
      final r = await Future.wait([Bots.I.fire(Bots.alarmId(b, 'rq')), Bots.I.fire(Bots.alarmId(b, 'rq'))]);
      final late = await Bots.I.fire(Bots.alarmId(b, 'rq'));
      expect(wakes, 1, reason: 'fire() results=$r then a late redelivery=$late: the routine woke the bot $wakes times for one 09:00 slot');
    });

    test('CB-35: a redelivery after a restart (slot kept on the phone) does not run the routine again', () async {
      final b = bot();
      Bots.clock = () => DateTime(2026, 10, 25, 9, 0, 3);
      var wakes = 0;
      Bots.I.onWake = (bot, reason, instruction, kind) async => wakes++;
      expect(await Bots.I.fire(Bots.alarmId(b, 'rq')), isTrue);
      final saved = jsonOf(b);
      await Bots.I.init(); // the app was killed and started again by the redelivered alarm
      Bots.I.bots.removeWhere((x) => x.id == b.id);
      final again = Bot.fromJson(saved);
      Bots.I.bots.add(again);
      Bots.clock = () => DateTime(2026, 10, 25, 9, 4);
      expect(await Bots.I.fire(Bots.alarmId(again, 'rq')), isFalse);
      expect(wakes, 1);
      expect(again.followups, isEmpty, reason: 'a duplicate must not become a 15-minute follow-up either');
      expect(Bots.I.lastRunAt(again, again.routines.first), DateTime(2026, 10, 25, 9, 0, 3));
    });

    test('CB-35: the next day\'s slot, and another routine at the same minute, still run', () async {
      final b = bot();
      b.routines.add(BotRoutine(id: 'r2', time: '09:00', days: 'daily', kind: 'work', instruction: 'Check the invoices.'));
      final woke = <String>[];
      Bots.I.onWake = (bot, reason, instruction, kind) async => woke.add(instruction);
      Bots.clock = () => DateTime(2026, 10, 25, 9, 0);
      await Bots.I.fire(Bots.alarmId(b, 'rq'));
      await Bots.I.fire(Bots.alarmId(b, 'r2'));
      Bots.clock = () => DateTime(2026, 10, 26, 9, 0, 1);
      await Bots.I.fire(Bots.alarmId(b, 'rq'));
      expect(woke, ['Send me one bookkeeping tip.', 'Check the invoices.', 'Send me one bookkeeping tip.']);
    });

    test('CB-35: an alarm a moment early still counts as its own slot', () async {
      final b = bot();
      var wakes = 0;
      Bots.I.onWake = (bot, reason, instruction, kind) async => wakes++;
      Bots.clock = () => DateTime(2026, 10, 25, 8, 59, 58);
      await Bots.I.fire(Bots.alarmId(b, 'rq'));
      Bots.clock = () => DateTime(2026, 10, 25, 9, 0, 40);
      await Bots.I.fire(Bots.alarmId(b, 'rq'));
      expect(wakes, 1);
    });

    test('CB-21: an 08:30 routine missed while Telesia was stopped is caught up at 08:40, then armed for tomorrow', () async {
      final b = bot(time: '08:30');
      final id = Bots.alarmId(b, 'rq');
      // Yesterday evening: the routine is armed as usual.
      Bots.clock = () => DateTime(2026, 10, 24, 20, 0);
      await Bots.I.arm(b);
      expect(Bots.I.routineAlarmAt(id), DateTime(2026, 10, 25, 8, 30));
      // The phone was off at 08:30 (or the app was force-stopped). It starts at 08:40.
      Bots.clock = () => DateTime(2026, 10, 25, 8, 40);
      await Bots.I.arm(b);
      final at = Bots.I.routineAlarmAt(id)!;
      expect(at.difference(DateTime(2026, 10, 25, 8, 40)).inMinutes, lessThan(60),
          reason: 'armed for $at: the missed 08:30 run is skipped until tomorrow, with no note');
      // The catch-up fires: the bot is told it is a late run, and the next alarm is tomorrow's.
      final reasons = <String>[];
      Bots.I.onWake = (bot, reason, instruction, kind) async => reasons.add(reason);
      Bots.clock = () => DateTime(2026, 10, 25, 8, 41);
      expect(await Bots.I.fire(id), isTrue);
      expect(reasons.single, contains('caught up'));
      expect(Bots.I.routineAlarmAt(id), DateTime(2026, 10, 26, 8, 30));
      // Starting again later that morning does not run it a second time.
      Bots.clock = () => DateTime(2026, 10, 25, 9, 10);
      await Bots.I.arm(b);
      expect(Bots.I.routineAlarmAt(id), DateTime(2026, 10, 26, 8, 30));
    });

    test('CB-21: no catch-up when the slot is more than 3 hours gone', () async {
      final b = bot(time: '08:30');
      Bots.clock = () => DateTime(2026, 10, 24, 20, 0);
      await Bots.I.arm(b);
      Bots.clock = () => DateTime(2026, 10, 25, 11, 45);
      await Bots.I.arm(b);
      expect(Bots.I.routineAlarmAt(Bots.alarmId(b, 'rq')), DateTime(2026, 10, 26, 8, 30));
    });

    test('CB-21: a routine made (or moved) after its time today does not run at once', () async {
      final b = bot(time: '08:30');
      Bots.clock = () => DateTime(2026, 10, 25, 8, 40);
      await Bots.I.arm(b);
      expect(Bots.I.routineAlarmAt(Bots.alarmId(b, 'rq')), DateTime(2026, 10, 26, 8, 30));
      // Moved from 10:00 to 08:30 at 08:50: still tomorrow.
      final c = Bot(id: 'cb4moved', name: 'Moved', role: '', persona: '')
        ..active = true
        ..convId = 'conv-cb4m';
      c.routines.add(BotRoutine(id: 'rm', time: '10:00', instruction: 'x'));
      Bots.I.bots.add(c);
      Bots.clock = () => DateTime(2026, 10, 24, 20, 0);
      await Bots.I.arm(c);
      c.routines.first.time = '08:30';
      Bots.clock = () => DateTime(2026, 10, 25, 8, 50);
      await Bots.I.arm(c);
      expect(Bots.I.routineAlarmAt(Bots.alarmId(c, 'rm')), DateTime(2026, 10, 26, 8, 30));
    });

    test('CB-21: when it last ran is kept across a restart', () async {
      final b = bot(time: '08:30');
      Bots.I.onWake = (bot, reason, instruction, kind) async {};
      Bots.clock = () => DateTime(2026, 10, 25, 8, 30);
      await Bots.I.fire(Bots.alarmId(b, 'rq'));
      final saved = jsonOf(b);
      await Bots.I.init();
      final again = Bot.fromJson(saved);
      Bots.I.bots.add(again);
      expect(Bots.I.lastRunAt(again, again.routines.first), DateTime(2026, 10, 25, 8, 30));
    });

    test('BotRoutine.catchUp and prev', () {
      final r = BotRoutine(id: 'r', time: '08:30', days: 'weekdays', instruction: 'x');
      expect(r.prev(DateTime(2026, 10, 26, 8, 30)), DateTime(2026, 10, 26, 8, 30)); // Monday, on the minute
      expect(r.prev(DateTime(2026, 10, 25, 12, 0)), DateTime(2026, 10, 23, 8, 30)); // Sunday -> Friday
      final since = DateTime(2026, 10, 1);
      expect(r.catchUp(DateTime(2026, 10, 26, 8, 40), since: since), DateTime(2026, 10, 26, 8, 41));
      expect(r.catchUp(DateTime(2026, 10, 26, 8, 40), since: since, lastSlot: DateTime(2026, 10, 26, 8, 30)), isNull);
      expect(r.catchUp(DateTime(2026, 10, 26, 8, 40)), isNull, reason: 'nothing known about the routine: no surprise run');
    });
  });

  // ---------------------------------------------------------------- CB-46 an alarm that cold-starts the app
  group('CB-46 a wake that comes before Telesia is ready is kept and run once', () {
    late Directory tmp;
    late AppState s;
    late Bot b;
    final started = <String>[];

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      tmp = await Directory.systemTemp.createTemp('cb46');
      PathProviderPlatform.instance = _Docs(tmp.path);
      await Bots.I.init();
      b = Bot(id: 'cb46', name: 'Ledger', role: 'Bookkeeper', persona: '')
        ..active = true
        ..convId = 'conv-cb46';
      b.routines.add(BotRoutine(id: 'rq', time: '09:00', days: 'daily', kind: 'message', instruction: 'Send me one bookkeeping tip.'));
      Bots.I.bots.add(b);
      Bots.readyWait = const Duration(milliseconds: 40);
      Bots.clock = () => DateTime(2026, 10, 25, 9, 0);
      s = AppState();
      s.listsForTest[b.convId] = <ChatMessage>[];
      started.clear();
      AppState.debugRunAgent = (app, run) async => started.add(run.convId);
      Bots.I.onWake = s.botWakeForTest;
    });
    tearDown(() async {
      AppState.debugRunAgent = null;
      Bots.readyWait = const Duration(seconds: 10);
      Bots.clock = DateTime.now;
      Bots.I.onWake = null;
      Bots.I.bots.remove(b);
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('fire before provider restore runs the wake once provider arrives', () async {
      // Cold start by the alarm: no account restored yet (repo.userId is not there).
      expect(await Bots.I.fire(Bots.alarmId(b, 'rq')), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(started, isEmpty);
      expect(Bots.I.heldForTest.map((w) => w.key), ['cb46|rq|2026-10-25T09:00'], reason: 'the wake was dropped without a trace');
      expect(b.journal.last.text, contains('before Telesia was ready'));
      // A redelivered alarm neither runs it nor holds it twice.
      expect(await Bots.I.fire(Bots.alarmId(b, 'rq')), isFalse);
      expect(Bots.I.heldForTest, hasLength(1));
      // Signed in: the held wake runs, once.
      s.repo.testUserId = 'u46';
      await s.runHeldWakesForTest();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(started, ['conv-cb46']);
      expect(s.listsForTest[b.convId]!.where((m) => m.role == 'user' && m.content.startsWith(botWakeMark)), hasLength(1));
      expect(s.listsForTest[b.convId]!.first.content, contains('Send me one bookkeeping tip.'));
      await s.runHeldWakesForTest();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(started, hasLength(1), reason: 'a held wake runs once');
      expect(Bots.I.heldForTest, isEmpty);
    });

    test('a wake that finds Telesia ready runs straight away and holds nothing', () async {
      s.repo.testUserId = 'u46';
      expect(await Bots.I.fire(Bots.alarmId(b, 'rq')), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(started, ['conv-cb46']);
      expect(Bots.I.heldForTest, isEmpty);
    });
  });

  // ---------------------------------------------------------------- CB-29 drafts and attachments leak between chats
  group('CB-29 text and picked files stay with the chat they were meant for', () {
    late Directory tmp;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      Composer.drafts.clear();
      Composer.attachmentDrafts.clear();
      tmp = await Directory.systemTemp.createTemp('cb29');
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    Widget host(AppState s) => ChangeNotifierProvider<AppState>.value(
          value: s,
          child: MaterialApp(
            theme: buildTheme(Brightness.light),
            home: const Scaffold(body: Column(children: [Spacer(), Composer(perChatDrafts: true)])),
          ),
        );

    testWidgets('text and a picked file in chat A do not appear in chat B, and come back in A', (t) async {
      final s = AppState()..currentId = 'conv-a';
      await t.pumpWidget(host(s));
      await t.pump();
      final f = File('${tmp.path}/invoice_a.pdf');
      await t.runAsync(() => f.writeAsBytes([37, 80, 68, 70]));
      // Shared into chat A (the same path the "+" picker fills): one file and some text.
      await t.runAsync(() async {
        s.shareInbox.value = {'text': 'For chat A only', 'files': [f.path]};
        for (var i = 0; i < 20 && find.byType(AttachmentChip).evaluate().isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await t.pump();
        }
      });
      await t.pump();
      expect(find.byType(AttachmentChip), findsOneWidget);
      expect(find.text('For chat A only'), findsOneWidget);
      // Another chat opens (the drawer, a notification): it must start empty.
      s.currentId = 'conv-b';
      s.notifyListeners();
      await t.pump();
      await t.pump();
      expect(find.byType(AttachmentChip), findsNothing, reason: 'the file picked in chat A would be sent to chat B');
      expect(find.text('For chat A only'), findsNothing);
      // Back to A: both come back.
      s.currentId = 'conv-a';
      s.notifyListeners();
      await t.pump();
      await t.pump();
      expect(find.byType(AttachmentChip), findsOneWidget);
      expect(find.text('For chat A only'), findsOneWidget);
    });

    testWidgets('the main chat keeps drafts per chat too', (t) async {
      // home_screen builds the main chat's composer with perChatDrafts on (it was off, so text and files followed you).
      final src = File('lib/screens/home_screen.dart').readAsStringSync();
      expect(src.contains('Composer(perChatDrafts: true)'), isTrue);
    });
  });
}

Map<String, dynamic> jsonOf(Bot b) => Map<String, dynamic>.from(jsonDecode(jsonEncode(b.toJson())) as Map);
