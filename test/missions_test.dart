// Mission mode (owner 2026-11-07, docs/bot-autonomy.md): a bot or team works toward a goal on its own across many
// background runs. These cover the Dart core: state on disk (resumable), self-scheduling on its own alarm, the
// guardrails (runs/day, tokens/day, stop switch, on/off), [needs you] escalation, team hand-offs, and the tools.
//
// Run: flutter test test/missions_test.dart
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:convert';
import 'dart:io';

import 'package:agent/services/bot_powers.dart';
import 'package:agent/services/bots.dart';
import 'package:agent/services/missions.dart';
import 'package:agent/services/system_bridge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late List<(String, Map<String, dynamic>?)> calls;
  late DateTime now;
  late List<(String, String)> woke;
  late List<(String, bool)> notes;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('missions');
    Missions.dirOverride = tmp.path;
    Missions.I.resetForTest();
    now = DateTime(2026, 11, 7, 10, 0);
    Missions.clock = () => now;
    calls = [];
    SystemBridge.debugCalls = (m, a) => calls.add((m, a));
    woke = [];
    notes = [];
    Missions.I.wakeBot = (m, ins) async {
      woke.add((m.ownerId, ins));
      return true;
    };
    Missions.I.wakeTeam = (m, ins) async {
      woke.add(('team:${m.ownerId}', ins));
      return true;
    };
    Missions.I.notify = (m, text, {bool needs = false}) async => notes.add((text, needs));
    Missions.I.nameOf = (m) => 'Nova';
  });

  tearDown(() async {
    SystemBridge.debugCalls = null;
    Missions.clock = DateTime.now;
    Missions.dirOverride = null;
    Missions.I.resetForTest();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  List<Map<String, dynamic>?> alarms(String method) => [for (final c in calls) if (c.$1 == method) c.$2];

  test('start: saved on disk with a readable MISSION.md, first wake armed on its own alarm, BootReceiver flag set', () async {
    final m = await Missions.I.start('bot', 'b1', 'Find 20 suppliers and get quotes');
    final dir = Directory('${tmp.path}/missions/${m.id}');
    expect(File('${dir.path}/mission.json').existsSync(), isTrue);
    final md = File('${dir.path}/MISSION.md').readAsStringSync();
    expect(md, contains('Find 20 suppliers and get quotes'));
    final set = alarms('scheduleAlarm').where((a) => a?['id'] == 'mission|${m.id}').toList();
    expect(set, isNotEmpty);
    expect(set.last?['at'], now.add(const Duration(minutes: 1)).millisecondsSinceEpoch);
    expect(set.last?['label'], startsWith('Nova · Find 20 suppliers'));
    final p = await SharedPreferences.getInstance();
    expect(p.getString(Missions.prefOn), m.id);
  });

  test('resumable: a fresh load reads plan, log and counters back from disk', () async {
    final m = await Missions.I.start('bot', 'b1', 'Grow the newsletter to 500 readers');
    await Missions.I.execute('mission_plan', {'steps': ['Audit the list', 'Write 3 posts', 'Pitch 5 partners']}, m: m, who: 'Nova');
    await Missions.I.execute('mission_update', {'step': 's1', 'status': 'done', 'progress': 'Audited: 212 readers.'}, m: m, who: 'Nova');
    Missions.I.resetForTest();
    await Missions.I.init();
    final back = Missions.I.liveOf('bot', 'b1')!;
    expect(back.goal, 'Grow the newsletter to 500 readers');
    expect(back.plan.map((s) => s.status), ['done', 'todo', 'todo']);
    expect(back.log.map((e) => e.kind), containsAll(['start', 'plan', 'step', 'progress']));
    expect(back.summary, 'Audited: 212 readers.');
  });

  test('a wake runs within the budget, counts the run, and arms a fallback wake so the mission never silently stops', () async {
    final m = await Missions.I.start('bot', 'b1', 'Goal');
    calls.clear();
    expect(await Missions.I.fire('mission|${m.id}'), isTrue);
    expect(woke.single.$1, 'b1');
    expect(woke.single.$2, contains('[Mission run:'));
    expect(woke.single.$2, contains('mission_schedule_next'));
    expect(woke.single.$2, contains('needs_you'));
    expect(m.runsToday, 1);
    expect(m.running, isTrue);
    expect(alarms('scheduleAlarm').last?['at'], now.add(Missions.fallbackGap).millisecondsSinceEpoch);
    // The run ends without scheduling: the fallback stays; with news, one summary notification.
    await Missions.I.runEnded(m, reply: 'Found 6 suppliers so far, quotes asked from 3.');
    expect(m.running, isFalse);
    expect(m.nextAt, now.add(Missions.fallbackGap));
    // An alarm while a run goes on starts no second run: it looks again in 15 minutes.
    await Missions.I.wake(m);
    expect(await Missions.I.wake(m), isFalse);
    expect(woke, hasLength(2));
    expect(m.nextAt, now.add(const Duration(minutes: 15)));
    expect(notes.single.$1, 'Found 6 suppliers so far, quotes asked from 3.');
  });

  test('mission_schedule_next sets its own next wake, clamped to 5 min .. 7 days', () async {
    final m = await Missions.I.start('bot', 'b1', 'Goal');
    var r = await Missions.I.execute('mission_schedule_next', {'in_minutes': 90, 'why': 'check replies'}, m: m);
    expect(r, contains('check replies'));
    expect(m.nextAt, now.add(const Duration(minutes: 90)));
    expect(alarms('scheduleAlarm').last?['at'], now.add(const Duration(minutes: 90)).millisecondsSinceEpoch);
    r = await Missions.I.execute('mission_schedule_next', {'in_minutes': 1}, m: m);
    expect(m.nextAt, now.add(Missions.minGap));
    expect(r, contains('soonest'));
    await Missions.I.execute('mission_schedule_next', {'when': '2027-01-01T09:00'}, m: m);
    expect(m.nextAt, now.add(Missions.maxGap));
    expect(await Missions.I.execute('mission_schedule_next', {}, m: m), startsWith('Error'));
  });

  test('guardrails: runs per day, tokens per day (also mid-run via leftFor), then paused until tomorrow with one note', () async {
    final m = await Missions.I.start('bot', 'b1', 'Goal', runsPerDay: 2, tokensPerDay: 50000);
    expect(await Missions.I.wake(m), isTrue);
    await Missions.I.runEnded(m);
    expect(await Missions.I.wake(m), isTrue);
    Missions.I.addTokens('bot', 'b1', 30000);
    expect(Missions.I.leftFor('bot', 'b1'), 20000);
    expect(Missions.minLeft(100000, Missions.I.leftFor('bot', 'b1')), 20000);
    expect(Missions.minLeft(null, 5), 5);
    expect(Missions.minLeft(7, null), 7);
    await Missions.I.runEnded(m);
    expect(Missions.I.leftFor('bot', 'b1'), isNull, reason: 'no run going on: the bot\'s own budget only');
    expect(await Missions.I.wake(m), isFalse, reason: '2 runs used');
    expect(woke, hasLength(2));
    expect(m.log.last.kind, 'budget');
    expect(notes.last.$1, contains('Paused until tomorrow'));
    expect(m.nextAt, DateTime(2026, 11, 8, 8));
    // Next day the counters roll over and it runs again.
    now = DateTime(2026, 11, 8, 8, 0);
    expect(await Missions.I.wake(m), isTrue);
    expect(m.runsToday, 1);
    // Tokens: over the daily token budget stops it too.
    m.runsPerDay = 10;
    Missions.I.addTokens('bot', 'b1', 60000);
    await Missions.I.runEnded(m);
    expect(m.blockedReason(now), contains('token budget'));
  });

  test('tokens count only while a mission run goes on (a chat with the owner never eats the mission budget)', () async {
    final m = await Missions.I.start('bot', 'b1', 'Goal');
    Missions.I.addTokens('bot', 'b1', 5000);
    expect(m.tokensToday, 0);
    await Missions.I.wake(m);
    Missions.I.addTokens('bot', 'b1', 5000);
    expect(m.tokensToday, 5000);
    // A run killed with the app does not stay "running" for ever.
    now = now.add(Missions.runWindow + const Duration(minutes: 1));
    Missions.I.addTokens('bot', 'b1', 5000);
    expect(m.tokensToday, 5000);
  });

  test('stop switch and on/off: off cancels its alarm and no wake runs; on again wakes within a minute; stop ends it for good', () async {
    final m = await Missions.I.start('bot', 'b1', 'Goal');
    var stopped = 0;
    Missions.I.onStop = (_) => stopped++;
    await Missions.I.setOn(m, false);
    expect(alarms('cancelAlarm').last?['id'], 'mission|${m.id}');
    expect(await Missions.I.wake(m), isFalse);
    expect(woke, isEmpty);
    expect((await SharedPreferences.getInstance()).getString(Missions.prefOn), isNull);
    await Missions.I.setOn(m, true);
    expect(m.nextAt, now.add(const Duration(minutes: 1)));
    await Missions.I.stop(m);
    expect(m.status, 'stopped');
    expect(stopped, 1);
    expect(await Missions.I.wake(m), isFalse);
    expect(await Missions.I.execute('mission_update', {'progress': 'x'}, m: m), contains('stopped'));
  });

  test('needs you: asks the owner once (a needs notification), the mission carries on; the answer wakes it soon', () async {
    final m = await Missions.I.start('bot', 'b1', 'Goal');
    final r = await Missions.I.execute('mission_update', {'needs_you': 'Pay \$49 for the supplier directory?'}, m: m, who: 'Nova');
    expect(r, contains('Do not do that step'));
    expect(m.status, 'waiting');
    expect(notes.single, ('[needs you] Pay \$49 for the supplier directory?', true));
    expect(m.blockedReason(now), isNull, reason: 'it keeps working on other steps');
    expect(Missions.I.brief(m), contains('Waiting on the owner: Pay \$49'));
    now = now.add(const Duration(minutes: 30));
    await Missions.I.answer(m, true, words: 'yes, use the work card');
    expect(m.needs, isEmpty);
    expect(m.status, 'active');
    expect(m.log.last.text, contains('Approved: Pay \$49'));
    expect(m.log.last.text, contains('use the work card'));
    expect(m.nextAt, now.add(const Duration(minutes: 1)));
  });

  test('mission_done closes it, cancels its alarm and tells the owner', () async {
    final m = await Missions.I.start('bot', 'b1', 'Goal');
    final r = await Missions.I.execute('mission_done', {'summary': '20 suppliers, 9 quotes in the sheet.', 'success': true}, m: m);
    expect(r, contains('Mission closed'));
    expect(m.status, 'done');
    expect(alarms('cancelAlarm').last?['id'], 'mission|${m.id}');
    expect(notes.last.$1, 'Mission done: 20 suppliers, 9 quotes in the sheet.');
    expect((await SharedPreferences.getInstance()).getString(Missions.prefOn), isNull);
  });

  test('starting needs the owner: a background run cannot give itself a mission', () async {
    final r = await Missions.I.execute('mission_plan', {'goal': 'Take over the world'}, m: null);
    expect(r, contains('while nobody is watching'));
    expect(Missions.I.missions, isEmpty);
    final ok = await Missions.I.execute('mission_plan', {'goal': 'Weekly competitor report', 'steps': ['List competitors', 'Check prices']},
        m: null, start: (g) => Missions.I.start('bot', 'b1', g, by: 'Nova'));
    expect(ok, contains('Plan saved'));
    expect(Missions.I.liveOf('bot', 'b1')!.plan, hasLength(2));
  });

  test('a new mission replaces the live one (one mission per bot), keeping the old log on disk', () async {
    final a = await Missions.I.start('bot', 'b1', 'First');
    final b = await Missions.I.start('bot', 'b1', 'Second');
    expect(a.status, 'stopped');
    expect(Missions.I.liveOf('bot', 'b1'), same(b));
    expect(File('${tmp.path}/missions/${a.id}/mission.json').existsSync(), isTrue);
  });

  test('team missions: the lead is woken, and a plan step with assign hands it to a teammate in the team chat', () async {
    final m = await Missions.I.start('team', 'o1', 'Launch the shop');
    expect(await Missions.I.wake(m), isTrue);
    expect(woke.single.$1, 'team:o1');
    expect(woke.single.$2, contains('teammate\'s name'));
    await Missions.I.execute('mission_plan', {'steps': ['Product photos', 'Write listings']}, m: m, who: 'Lead');
    final handed = <(String, String)>[];
    final r = await Missions.I.execute('mission_plan', {'step': 's1', 'who': 'Amal', 'assign': true}, m: m, who: 'Lead',
        assign: (who, text) async {
      handed.add((who, text));
      return null;
    });
    expect(r, contains('Handed to Amal'));
    expect(handed, [('Amal', 'Product photos')]);
    expect(m.plan.first.status, 'doing');
    expect(m.log.last.kind, 'delegate');
    // A bot mission has no team to hand to.
    final solo = await Missions.I.start('bot', 'b2', 'Solo');
    await Missions.I.execute('mission_plan', {'steps': ['A']}, m: solo);
    expect(await Missions.I.execute('mission_plan', {'step': '1', 'who': 'Amal', 'assign': true}, m: solo), contains('Not handed over'));
  });

  test('armAll after a restart: missions that are on get their alarm again; a missed time wakes in a minute', () async {
    final m = await Missions.I.start('bot', 'b1', 'Goal');
    await Missions.I.execute('mission_schedule_next', {'in_minutes': 30}, m: m);
    final off = await Missions.I.start('bot', 'b2', 'Off one');
    await Missions.I.setOn(off, false);
    Missions.I.resetForTest();
    Missions.I.nameOf = (m) => 'Nova';
    calls.clear();
    now = now.add(const Duration(hours: 3)); // the phone was off past its time
    await Missions.I.armAll();
    final set = alarms('scheduleAlarm');
    expect([for (final a in set) a?['id']], ['mission|${m.id}']);
    expect(set.single?['at'], now.add(const Duration(minutes: 1)).millisecondsSinceEpoch);
  });

  test('a run cut short by no connection does not count, and retries soon', () async {
    final m = await Missions.I.start('bot', 'b1', 'Goal');
    await Missions.I.wake(m);
    await Missions.I.runFailed(m, 'offline');
    expect(m.runsToday, 0);
    expect(m.running, isFalse);
    expect(m.nextAt, now.add(const Duration(minutes: 10)));
    await Missions.I.wake(m);
    await Missions.I.runFailed(m, 'credit');
    expect(m.nextAt, DateTime(2026, 11, 8, 8));
  });

  test('a wake that could not start is not counted and retries in 20 minutes', () async {
    final m = await Missions.I.start('bot', 'b1', 'Goal');
    Missions.I.wakeBot = (m, ins) async => false;
    expect(await Missions.I.wake(m), isFalse);
    expect(m.runsToday, 0);
    expect(m.running, isFalse);
    expect(m.nextAt, now.add(const Duration(minutes: 20)));
  });

  test('progress notifications are summaries, at most one per 30 minutes', () async {
    final m = await Missions.I.start('bot', 'b1', 'Goal');
    await Missions.I.wake(m);
    await Missions.I.runEnded(m, reply: 'Step one done.\n@note');
    await Missions.I.wake(m);
    await Missions.I.runEnded(m, reply: 'Step two done.');
    expect(notes.map((n) => n.$1), ['Step one done.']);
    now = now.add(const Duration(minutes: 31));
    await Missions.I.wake(m);
    await Missions.I.runEnded(m, reply: '[no reply]');
    expect(notes.map((n) => n.$1), ['Step one done.', 'Step two done.'], reason: 'the latest summary, not a "[no reply]"');
  });

  test('the tools are a bot\'s own: in every bot\'s list, never switched off with a power, mission brief in the prompt', () async {
    final b = Bot(id: 'b1', name: 'Nova', role: 'Researcher', persona: '');
    final names = [for (final d in Bots.I.definitionsFor(b)) '${(d['function'] as Map)['name']}'];
    expect(names, containsAll(Missions.names));
    for (final n in Missions.names) {
      expect(BotPowers.allowed({'web', 'browser', 'phone', 'files', 'apps'}, n), isTrue, reason: n);
    }
    expect(Bots.I.agentBriefOf(b), contains('# Missions'));
    final m = await Missions.I.start('bot', 'b1', 'Write the weekly report every Friday');
    Bots.I.missionOf = (x) => Missions.I.brief(m);
    addTearDown(() => Bots.I.missionOf = null);
    expect(Bots.I.agentBriefOf(b), contains('# Your mission'));
    expect(Bots.I.agentBriefOf(b), contains('Write the weekly report every Friday'));
  });

  test('mission.json is valid JSON with the owner, goal and budget', () async {
    final m = await Missions.I.start('team', 'o9', 'Goal X', runsPerDay: 5, tokensPerDay: 123000);
    final j = jsonDecode(File('${tmp.path}/missions/${m.id}/mission.json').readAsStringSync()) as Map;
    expect(j['kind'], 'team');
    expect(j['owner'], 'o9');
    expect(j['rpd'], 5);
    expect(j['tpd'], 123000);
  });
}
