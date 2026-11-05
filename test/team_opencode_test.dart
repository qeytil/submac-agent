// Teams on opencode (owner, 2026-11-03): the lead works in its own opencode turn and hands parts off with team_assign;
// each member's part is its own opencode turn with its own brief; every member works at once (no cap, owner 2026-11-04);
// a lead's routine
// starts a team job with team_task.

import 'package:agent/services/bots.dart';
import 'package:agent/services/offices.dart';
import 'package:agent/services/team_key.dart';
import 'package:agent/services/team_run.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final lead = Bot(id: 'tol', name: 'Hodan', role: 'Manager', persona: 'Calm.');
  final nova = Bot(id: 'ton', name: 'Nova', role: 'Researcher', persona: 'Curious.');
  final amal = Bot(id: 'toa', name: 'Amal', role: 'Analyst', persona: 'Careful.');
  final omar = Bot(id: 'too', name: 'Omar', role: 'Writer', persona: 'Clear.');
  final turns = <({String bot, String key, String system, String task})>[];
  var live = 0, peak = 0;

  Future<String> fakeAsk(Bot b, String system, String user, {int maxTokens = 0}) async {
    if (system.contains('# Who speaks')) return '{"speaker":"Hodan","team_task":true}';
    if (system.contains('# Plan for the owner')) {
      return '{"reply":"Suppliers.","questions":[],"parts":[{"bot":"Nova","ask":"Find suppliers"},'
          '{"bot":"Amal","ask":"Compare prices"},{"bot":"Omar","ask":"Write the summary"}]}';
    }
    if (system.contains('# Combine')) return 'Combined by the old path.';
    return '';
  }

  Future<String> fakeTurn(Bot b, String key, String system, String task,
      {bool Function()? stopped, Future<String> Function(String member, String ask)? assign}) async {
    turns.add((bot: b.name, key: key, system: system, task: task));
    if (assign != null) {
      final r = await Future.wait([assign('Nova', 'Find suppliers'), assign('amal', 'Compare prices'), assign('Omar', 'Write it')]);
      expect(await assign('Nobody', 'x'), contains('no member named'));
      return 'Final answer from the lead. ${r.length} parts.';
    }
    live++;
    peak = live > peak ? live : peak;
    await Future<void>.delayed(const Duration(milliseconds: 60));
    live--;
    return '${lead.name}, done.\n---\nResult from ${b.name}.';
  }

  // These tests drive the lead's team job; since team awareness (owner 2026-11-05) the lead plans an owner's job only
  // when the owner handed the team over (or gave the lead the job by name), so the team starts handed over.
  Office team() => Office(id: 'oto${DateTime.now().microsecondsSinceEpoch}', name: 'Coffee', members: ['tol', 'ton', 'toa', 'too'], chiefId: 'tol')..delegated = true;

  setUp(() {
    Bots.I.bots.addAll([lead, nova, amal, omar]);
    TeamRun.I
      ..reset()
      ..ask = fakeAsk
      ..ocTurn = fakeTurn
      ..promptOf = (b) => 'You are ${b.name}.';
    turns.clear();
    live = 0;
    peak = 0;
    Offices.I.queue.clear();
  });
  tearDown(() {
    Bots.I.bots.removeWhere((b) => b.id.startsWith('to'));
    Offices.I.offices.clear();
    Offices.I.queue.clear();
    TeamRun.I
      ..ocTurn = null
      ..reset();
  });

  test('the lead hands off with team_assign; members run in their own turns, all at once; the lead answers', () async {
    final o = team();
    TeamRun.I.send(o, 'Find the three cheapest coffee suppliers in Hargeisa');
    await TeamRun.I.work;
    expect(turns.first.bot, 'Hodan');
    expect(TeamKey.officeOf(turns.first.key), o.id);
    expect(TeamKey.botOf(turns.first.key), 'tol');
    expect(turns.first.system, contains(TeamRun.assignName));
    expect(turns.first.system, contains('teams/${o.id}/'));
    expect(turns.first.system, contains('submac_run_tool'), reason: 'the lead gets its opencode brief');
    final members = turns.skip(1).toList();
    expect(members.map((t) => t.bot).toSet(), {'Nova', 'Amal', 'Omar'});
    for (final t in members) {
      expect(TeamKey.officeOf(t.key), o.id);
      expect(TeamKey.botOf(t.key), {'Nova': 'ton', 'Amal': 'toa', 'Omar': 'too'}[t.bot]);
      expect(t.system, contains('You are ${t.bot}'), reason: 'each member has its own brief');
      expect(t.system, isNot(contains('You are Hodan.')));
      expect(t.system, contains('# Team folder'));
    }
    expect(peak, 3, reason: 'independent parts all run side by side: no cap on members working at once');
    expect(turns.map((t) => t.key).toSet().length, turns.length, reason: 'each piece of work has its own route key');
    final answer = o.posts.last;
    expect(answer.kind, 'answer');
    expect(answer.text, 'Final answer from the lead. 3 parts.');
    expect(answer.parts.map((p) => p.from).toSet(), {'ton', 'toa', 'too'});
    expect(TeamRun.I.running, isEmpty);
  });

  test('stop: no member starts after the owner stops the team', () async {
    final o = team();
    TeamRun.I.ocTurn = (b, key, system, task, {stopped, assign}) async {
      turns.add((bot: b.name, key: key, system: system, task: task));
      if (assign != null) {
        TeamRun.I.halt(o);
        expect(stopped?.call(), isTrue, reason: 'the running turn sees the stop and aborts');
        return await assign('Nova', 'Find suppliers');
      }
      return 'x\n---\ny';
    };
    TeamRun.I.send(o, 'Find the three cheapest coffee suppliers in Hargeisa');
    await TeamRun.I.work;
    expect(turns.map((t) => t.bot), ['Hodan'], reason: 'stopped before any member ran');
    expect(o.posts.where((p) => p.kind == 'answer'), isEmpty);
  });

  test('team_task from a lead\'s routine starts a job; a busy team says so', () async {
    final o = team();
    expect(TeamRun.I.startJob(o, 'Weekly supplier report'), startsWith('Started'));
    expect(TeamRun.I.startJob(o, 'Another job'), contains('busy'));
    await TeamRun.I.work;
    expect(o.posts.last.kind, 'answer');
    expect(TeamRun.I.startJob(o, 'Next week'), startsWith('Started'));
    await TeamRun.I.work;
  });

  test('a lead over its daily budget does not start routine team work', () {
    final rich = Bot(id: 'tob', name: 'Bilan', role: 'Lead', persona: '');
    Bots.I.bots.add(rich);
    rich.tokenBudgetK = 1;
    rich.addTokens(2000);
    expect(rich.overBudget, isTrue);
    final o2 = Office(id: 'otob', name: 'B', members: ['tob', 'ton'], chiefId: 'tob');
    expect(TeamRun.I.startJob(o2, 'x'), contains('budget'));
  });
}

