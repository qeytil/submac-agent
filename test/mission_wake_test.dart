// Mission mode in the app (owner 2026-11-07, docs/bot-autonomy.md): a mission alarm with SubMac closed wakes the bot
// in the background lane with the mission's instruction; a team mission wakes its lead with a 'mission' office job;
// the tools start a mission only when the owner is present; the stop switch reaches a running wake. Engine mocked.
//
// Run: flutter test test/mission_wake_test.dart
// ignore_for_file: invalid_use_of_visible_for_testing_member, depend_on_referenced_packages
import 'dart:io';

import 'package:agent/app_state.dart';
import 'package:agent/models.dart';
import 'package:agent/services/bots.dart';
import 'package:agent/services/missions.dart';
import 'package:agent/services/offices.dart';
import 'package:agent/services/system_bridge.dart';
import 'package:agent/services/team_key.dart';
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

Future<void> _settle([int ms = 30]) => Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late AppState s;
  late Bot b;
  late List<String> started;
  late List<(String, Map<String, dynamic>?)> calls;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('mwake');
    PathProviderPlatform.instance = _Docs(tmp.path);
    Missions.dirOverride = tmp.path;
    Missions.I.resetForTest();
    await Bots.I.init();
    await Offices.I.init();
    b = Bot(id: 'mw1', name: 'Nova', role: 'Researcher', persona: '')
      ..active = true
      ..convId = 'conv-mw1';
    Bots.I.bots.add(b);
    Bots.readyWait = const Duration(milliseconds: 40);
    s = AppState()..appVisible = false;
    s.listsForTest[b.convId] = <ChatMessage>[];
    s.repo.testUserId = 'u1';
    s.wireMissionsForTest();
    s.openAlarmGateForTest();
    started = [];
    calls = [];
    SystemBridge.debugCalls = (m, a) => calls.add((m, a));
    AppState.debugRunAgent = (app, run) async {
      started.add(run.convId);
      await _settle(60); // the run is "going on" for a moment
    };
  });

  tearDown(() async {
    AppState.debugRunAgent = null;
    AppState.debugTeamTurn = null;
    SystemBridge.debugCalls = null;
    Bots.readyWait = const Duration(seconds: 10);
    Bots.I.bots.removeWhere((x) => x.id.startsWith('mw'));
    Bots.I.missionOf = null;
    Offices.I.missionOf = null;
    Offices.I.queue.clear();
    TeamRun.I.reset();
    Missions.I.resetForTest();
    // A finished office run asks for one more pump 300 ms later (bots_controller, `_officeRun`'s last line). Let it
    // fire here, with the queue empty, so it can never fire inside the next test and take that test's job out of the
    // queue before its assertion (this made the team hand-off test fail only in the full suite, where timing differs).
    await Future<void>.delayed(const Duration(milliseconds: 400));
    Missions.dirOverride = null;
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('a mission alarm with SubMac closed wakes the bot unattended, with the mission instruction and a "<Bot> · Mission" line', () async {
    final m = await Missions.I.start('bot', b.id, 'Find 20 wholesale suppliers');
    await Missions.I.execute('mission_plan', {'steps': ['List candidates', 'Ask for quotes']}, m: m);
    await s.onAlarmForTest(Missions.alarmId(m));
    await _settle();
    expect(started, [b.convId]);
    expect(s.botWakeConvsForTest[b.convId], 'mission');
    expect(s.unattendedRun(b.convId), isTrue);
    final task = s.listsForTest[b.convId]!.lastWhere((x) => x.role == 'user').content;
    expect(task, contains('[Mission run:'));
    expect(task, contains('Find 20 wholesale suppliers'));
    expect(task, contains('s1 [todo] List candidates'));
    expect(task, isNot(contains('@message')), reason: 'a mission run reports a summary, not outreach tags');
    final keep = calls.where((c) => c.$1 == 'keepAlive' && c.$2?['on'] == true).map((c) => '${c.$2?['text']}').toList();
    expect(keep.any((t) => t.startsWith('Nova · Mission: Find 20 wholesale')), isTrue, reason: '$keep');
    expect(m.runsToday, 1);
    expect(m.running, isTrue);
    // Its run ends: the reply stays as a quiet note, the mission takes the summary.
    s.listsForTest[b.convId]!.add(ChatMessage(id: 'a1', role: 'assistant', content: 'Listed 8 candidates; quotes asked from 3.'));
    await s.missionBotOutcomeForTest(b, 'Listed 8 candidates; quotes asked from 3.');
    expect(m.running, isFalse);
    expect(m.summary, 'Listed 8 candidates; quotes asked from 3.');
    expect(b.journal.last.text, startsWith('Mission: Listed 8'));
  });

  test('a bot that is busy is not woken twice: the mission retries by itself and the run is not counted', () async {
    final m = await Missions.I.start('bot', b.id, 'Goal');
    s.botWakeConvsForTest[b.convId] = 'work'; // another wake holds its chat
    expect(await Missions.I.wake(m), isFalse);
    expect(started, isEmpty);
    expect(m.runsToday, 0);
    expect(b.followups, isEmpty, reason: 'no stale follow-up copy of the mission is queued');
  });

  test('an offline cut does not count and retries soon', () async {
    final m = await Missions.I.start('bot', b.id, 'Goal');
    await Missions.I.wake(m);
    await s.missionBotOutcomeForTest(b, '', failure: 'offline');
    expect(m.runsToday, 0);
    expect(m.log.last.kind, 'skip');
  });

  test('tools: the owner in the bot\'s chat starts a mission; a background wake cannot; the stop switch ends the run', () async {
    final r = await s.missionToolForTest('mission_plan', {'goal': 'Weekly price report', 'steps': ['Pick 10 products']}, b.convId);
    expect(r, contains('Plan saved'));
    final m = Missions.I.liveOf('bot', b.id)!;
    expect(m.goal, 'Weekly price report');
    expect(m.nextAt, isNotNull, reason: 'it wakes itself after this chat');
    await Missions.I.stop(m);
    s.botWakeConvsForTest[b.convId] = 'work';
    final r2 = await s.missionToolForTest('mission_plan', {'goal': 'Something new'}, b.convId);
    expect(r2, contains('only the owner starts a mission'));
    s.botWakeConvsForTest.remove(b.convId);
  });

  test('a team mission wakes its lead with a mission job; the lead\'s turn knows the mission; its end updates the mission', () async {
    final lead = Bot(id: 'mwlead', name: 'Hodan', role: 'Manager', persona: '')..active = true;
    final amal = Bot(id: 'mwamal', name: 'Amal', role: 'Designer', persona: '')..active = true;
    Bots.I.bots.addAll([lead, amal]);
    final o = Office(id: 'omw1', name: 'Shop', members: ['mwlead', 'mwamal'], chiefId: 'mwlead');
    Offices.I.offices.add(o);
    addTearDown(() => Offices.I.offices.remove(o));
    final tasks = <String>[];
    final systems = <String>[];
    AppState.debugTeamTurn = (bot, key, system, task, {required model, bool background = true, String? officeJob}) async {
      tasks.add(task);
      systems.add(system);
      return 'Plan made; photos handed to Amal.';
    };
    final m = await Missions.I.start('team', o.id, 'Launch the online shop by Friday');
    expect(await Missions.I.wake(m), isTrue);
    await _settle(200);
    expect(tasks, isNotEmpty);
    expect(tasks.first, contains('You lead this mission'));
    expect(tasks.first, contains('Launch the online shop by Friday'));
    expect(systems.first, contains('# Your mission'));
    await _settle(100);
    expect(m.running, isFalse);
    expect(m.summary, 'Plan made; photos handed to Amal.');
    // A member sees the goal only; the lead sees the plan.
    expect(Offices.I.missionOf!(o, amal), '# The team\'s mission\nLaunch the online shop by Friday');
  });

  test('a team mission step handed to a teammate posts "Name: …" in the team chat, which starts their turn', () async {
    final lead = Bot(id: 'mwlead2', name: 'Hodan', role: 'Manager', persona: '')..active = true;
    final amal = Bot(id: 'mwamal2', name: 'Amal', role: 'Designer', persona: '')..active = true;
    Bots.I.bots.addAll([lead, amal]);
    final o = Office(id: 'omw2', name: 'Shop', members: ['mwlead2', 'mwamal2'], chiefId: 'mwlead2');
    Offices.I.offices.add(o);
    addTearDown(() => Offices.I.offices.remove(o));
    final m = await Missions.I.start('team', o.id, 'Launch');
    await Missions.I.execute('mission_plan', {'steps': ['Product photos']}, m: m);
    final key = TeamKey.of(o.id, lead.id);
    s.officeCtxForTest[key] = o.id;
    final r = await s.missionToolForTest('mission_plan', {'step': 's1', 'who': 'Amal', 'assign': true}, key);
    s.officeCtxForTest.remove(key);
    expect(r, contains('Handed to Amal'), reason: r);
    expect(o.posts.last.text, 'Amal: Product photos');
    final next = Offices.I.queue.where((j) => j.officeId == o.id && j.botId == 'mwamal2').toList();
    expect(next.single.kind, 'assign');
  });
}

