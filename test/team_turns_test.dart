// Event-driven team turns (owner 2026-11-06, "bots and teams, highest priority"):
//  1. "Amal, analyze Nova's research once it posts": Amal takes its turn the moment Nova posts, nobody writes again.
//  2. The lead hands out work ("Nova: …", "@Nova …"): the assignee starts at once and the lead hears back.
//  3. Loop guards: chain depth, no ping-pong, one turn per post per bot, a burst cap, small talk starts nothing.
//  4. Collaboration fixes: a bot addressed while a team job runs answers itself, the hand-over flag no longer
//     overwrites the daily report time, two hand-offs to one bot are two turns.
import 'dart:io';

import 'package:agent/services/bots.dart';
import 'package:agent/services/no_reply.dart';
import 'package:agent/services/offices.dart';
import 'package:agent/services/team_floor.dart';
import 'package:agent/services/team_run.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final lead = Bot(id: 'ttl', name: 'Hodan', role: 'Manager', persona: 'Calm.');
  final nova = Bot(id: 'ttn', name: 'Nova', role: 'Researcher', persona: 'Curious.');
  final amal = Bot(id: 'tta', name: 'Amal', role: 'Analyst', persona: 'Careful.');
  final calls = <String>[];

  Future<String> fakeAsk(Bot b, String system, String user, {int maxTokens = 0}) async {
    calls.add(system.contains('# Who speaks') ? 'floor' : 'other');
    return '{"speaker":"none","team_task":false}';
  }

  var seq = 0;
  Office team() => Office(id: 'ott${seq++}${DateTime.now().microsecondsSinceEpoch}', name: 'Lab', members: ['ttl', 'ttn', 'tta'], chiefId: 'ttl');
  List<OfficeJob> jobs(Office o, [String? kind]) => [for (final j in Offices.I.queue) if (j.officeId == o.id && (kind == null || j.kind == kind)) j];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Bots.I.bots.addAll([lead, nova, amal]);
    TeamRun.I
      ..reset()
      ..ask = fakeAsk
      ..promptOf = (b) => 'You are ${b.name}.';
    Offices.I.queue.clear();
    Offices.I.jobOf = null;
    calls.clear();
  });
  tearDown(() {
    Bots.I.bots.removeWhere((b) => b.id.startsWith('tt'));
    Offices.I.queue.clear();
    Offices.I.jobOf = null;
    TeamRun.I.reset();
  });

  group('watches: "when X posts, do Y"', () {
    test('the owner\'s example: B takes its turn when A posts, without another owner message', () {
      final o = team();
      TeamRun.I.send(o, 'Amal, analyze Nova\'s research result once it posts in the team');
      expect(o.watches, hasLength(1));
      expect(o.watches.single.watcher, 'tta');
      expect(o.watches.single.from, 'ttn');
      // A short system line says so; Amal is asked now too (it was addressed) and told the rest comes later.
      expect(o.posts.any((p) => p.kind == 'system' && p.text.contains('Amal will pick this up as soon as Nova posts')), isTrue);
      final now = jobs(o, 'reply');
      expect(now.map((j) => j.botId), ['tta']);
      expect(Offices.I.jobText(o, amal, now.single), contains('you will be woken by yourself as soon as Nova posts'));
      Offices.I.queue.clear();

      // Nova posts its research (its own turn, started by the owner: depth 1).
      final p = Offices.I.post(o, 'ttn', 'Research done: three suppliers, cheapest is Acme at 4.20/kg. Full notes in the team folder.', depth: 1, cause: 'you');
      final r = jobs(o, 'react');
      expect(r, hasLength(1));
      expect(r.single.botId, 'tta');
      expect(r.single.depth, 2);
      expect(r.single.cause, 'ttn');
      expect(r.single.post, p.id);
      expect(r.single.instruction, contains('Acme at 4.20/kg'));
      expect(r.single.instruction, contains('The owner asked: "Amal, analyze Nova'));
      final text = Offices.I.jobText(o, amal, r.single);
      expect(text, contains('Take your turn now, by yourself'));
      expect(text, contains(NoReply.token));
      // Fired once: Nova's next post wakes nobody.
      expect(o.watches, isEmpty);
      Offices.I.queue.clear();
      Offices.I.post(o, 'ttn', 'Also found a fourth supplier in Hargeisa with good reviews.', depth: 1, cause: 'you');
      expect(jobs(o), isEmpty);
    });

    test('phrasings: "when Nova is done, Amal checks it", "@Amal wait for Nova\'s report, then summarise"', () {
      final o = team();
      final a = TeamReact.fromOwner(o, 'When Nova is done with the prices, Amal should check them.');
      expect(a.map((w) => '${w.watcher}<-${w.from}'), ['tta<-ttn']);
      final b = TeamReact.fromOwner(o, 'wait for Nova\'s report, then summarise it', addressed: [amal]);
      expect(b.map((w) => '${w.watcher}<-${w.from}'), ['tta<-ttn']);
      final c = TeamReact.fromOwner(o, 'Nova, research suppliers. Amal, compare them after Nova posts.');
      expect(c.map((w) => '${w.watcher}<-${w.from}'), ['tta<-ttn']);
      // No "when" or no event: no watch (a plain request is a plain request).
      expect(TeamReact.fromOwner(o, 'Amal, analyze Nova\'s research.'), isEmpty);
      expect(TeamReact.fromOwner(o, 'Nova, when you have time, say hi.'), isEmpty);
    });

    test('a watch-only message needs no answer now: no "who speaks" call, nobody asked', () async {
      final o = team();
      TeamRun.I.send(o, 'When Nova posts the prices, Amal should turn them into a table.');
      await TeamRun.I.work;
      expect(calls, isEmpty);
      expect(jobs(o), isEmpty);
      expect(o.watches.single.watcher, 'tta');
    });

    test('a bot can set its own watch with office_watch', () async {
      final o = team();
      final r = await Offices.I.execute('office_watch', {'from': 'Nova', 'do': 'Check the numbers Nova posts'}, o, amal);
      expect(r, contains('woken by yourself'));
      Offices.I.post(o, 'ttn', 'Prices: 4.20, 4.35 and 4.90 per kg.');
      expect(jobs(o, 'react').single.botId, 'tta');
      expect(await Offices.I.execute('office_watch', {'from': 'Amal', 'do': 'x'}, o, amal), contains('your own post'));
      expect(await Offices.I.execute('office_watch', {'from': 'Zed', 'do': 'x'}, o, amal), contains('no teammate'));
      expect(Offices.names, contains('office_watch'));
      expect(Offices.definitions.any((d) => (d['function'] as Map)['name'] == 'office_watch'), isTrue);
    });

    test('watches survive saving and lapse after a day', () {
      final o = team();
      o.watches.add(TeamWatch(id: 'w1', watcher: 'tta', from: 'ttn', instruction: 'Analyze it'));
      o.watches.add(TeamWatch(id: 'w2', watcher: 'tta', from: 'ttn', instruction: 'Old', at: DateTime.now().subtract(const Duration(days: 2))));
      final back = Office.fromJson(o.toJson());
      expect(back.watches.map((w) => w.id), ['w1']);
      expect(back.watches.single.instruction, 'Analyze it');
    });
  });

  group('the lead assigns: assignees start by themselves', () {
    test('"Name: task" lines start each assignee, and the lead hears back with who is still to come', () {
      final o = team();
      Offices.I.post(o, 'ttl', 'Plan for the launch:\nNova: find three supplier prices for green coffee\nAmal: build the cost comparison table', depth: 1, cause: 'you');
      final a = jobs(o, 'assign');
      expect(a.map((j) => j.botId).toSet(), {'ttn', 'tta'});
      final forNova = a.firstWhere((j) => j.botId == 'ttn');
      expect(forNova.instruction, contains('find three supplier prices'));
      expect(forNova.instruction, contains('the team lead'));
      expect(forNova.depth, 2);
      final text = Offices.I.jobText(o, nova, forNova);
      expect(text, contains('it starts now: nobody will tell you to begin'));
      expect(text, contains('report back in the team chat'));
      // The lead waits for both reports.
      expect(o.watches.where((w) => w.watcher == 'ttl').map((w) => w.from).toSet(), {'ttn', 'tta'});
      Offices.I.queue.clear();
      // Nova reports back: the lead takes a turn, told Amal is still to come.
      Offices.I.post(o, 'ttn', 'Prices found: Acme 4.20, Bean Co 4.35, Kaah 4.90 per kg.', depth: 2, cause: 'ttl');
      final r = jobs(o, 'react');
      expect(r.single.botId, 'ttl');
      expect(r.single.instruction, contains('Still waiting on: Amal'));
      expect(r.single.depth, 3);
    });

    test('@mentions from the lead are assignments; a teammate\'s question is a mention', () {
      final o = team();
      Offices.I.post(o, 'ttl', '@Nova please check the shipping costs to Mogadishu.');
      expect(jobs(o, 'assign').single.botId, 'ttn');
      Offices.I.queue.clear();
      Offices.I.post(o, 'ttn', '@Amal which currency do you want the table in?');
      expect(jobs(o, 'mention').single.botId, 'tta');
      expect(jobs(o, 'assign'), isEmpty);
      Offices.I.queue.clear();
      // A member asking a teammate for work is an assignment too.
      Offices.I.post(o, 'tta', 'Nova, please send me the raw price list.');
      expect(jobs(o, 'assign').single.botId, 'ttn');
    });

    test('an assignment must report back (it is never dropped as a silent answer)', () {
      // The office run posts an assignee's answer even with a stray silence tag, like a task.
      final ctl = _read('lib/state/bots_controller.dart');
      expect(ctl, contains("j.kind == 'task' || j.kind == 'assign'"));
    });

    test('a summary that credits teammates hands nothing out; work already on the board is not started twice', () {
      final o = team();
      Offices.I.post(o, 'ttl', 'Summary for you:\nNova: found three suppliers, Acme is cheapest\nAmal: built the comparison table');
      expect(jobs(o), isEmpty);
      expect(TeamReact.reportLike('done, the table is in the folder'), isTrue);
      expect(TeamReact.reportLike('compare the three offers'), isFalse);
      expect(TeamReact.reportLike('need the prices by noon'), isFalse);
      o.tasks.add(OfficeTask(id: 'k1', title: 'Find prices', owner: 'ttn', createdBy: 'ttl'));
      Offices.I.post(o, 'ttl', 'Nova: find the prices (on the board as k1)');
      expect(jobs(o), isEmpty);
      expect(Offices.I.held, contains('board:ttn'));
    });

    test('the lead\'s own plan in a team job never starts members twice (the job runs them)', () {
      final o = team();
      Offices.I.post(o, 'ttl', 'Who does what:\n- Nova: find prices\n- Amal: make the table', assigns: false);
      expect(jobs(o), isEmpty);
    });

    test('two hand-offs to one bot are two turns', () {
      final o = team();
      Offices.I.enqueue(OfficeJob(officeId: o.id, botId: 'ttn', kind: 'assign', instruction: 'Find prices'));
      Offices.I.enqueue(OfficeJob(officeId: o.id, botId: 'ttn', kind: 'assign', instruction: 'Find shipping'));
      Offices.I.enqueue(OfficeJob(officeId: o.id, botId: 'ttn', kind: 'assign', instruction: 'Find shipping'));
      expect(jobs(o, 'assign'), hasLength(2));
    });

    test('the lead\'s instructions say naming a teammate starts their turn', () {
      final o = team();
      expect(TeamLeadMode.leadInstruction(o..delegated = true), contains('which starts their turn'));
      expect(TeamLeadMode.leadInstruction(o..delegated = false), contains('only when the owner asks'));
    });
  });

  group('loop guards', () {
    test('chain depth: bot-to-bot turns stop at maxDepth; owner watches reach watchDepth', () {
      final o = team();
      Offices.I.post(o, 'ttl', 'Nova: check the prices again', depth: TeamReact.maxDepth);
      expect(jobs(o), isEmpty);
      expect(Offices.I.held, contains('depth:ttn'));
      o.watches.add(TeamWatch(id: 'wd', watcher: 'tta', from: 'ttn', instruction: 'Analyze it'));
      Offices.I.post(o, 'ttn', 'Here are the new prices: 4.10 and 4.30.', depth: TeamReact.maxDepth);
      expect(jobs(o, 'react').single.botId, 'tta', reason: 'the owner asked for this one by name');
      Offices.I.queue.clear();
      o.watches.add(TeamWatch(id: 'wd2', watcher: 'tta', from: 'ttn', instruction: 'Analyze it'));
      Offices.I.post(o, 'ttn', 'And a final update on the prices: 4.00.', depth: TeamReact.watchDepth);
      expect(jobs(o), isEmpty);
    });

    test('no ping-pong: a plain answer never wakes the teammate that woke it', () {
      final o = team();
      Offices.I.post(o, 'tta', '@Nova thanks, is the table format fine for you?', depth: 2, cause: 'ttn');
      expect(jobs(o, 'mention'), hasLength(1), reason: 'not posted from a turn Nova started (no job context)');
      Offices.I.queue.clear();
      Offices.I.jobOf = (id, officeId) => id == 'tta' ? (kind: 'mention', depth: 2, cause: 'ttn') : null;
      Offices.I.post(o, 'tta', '@Nova got it, I will use euros then?');
      expect(jobs(o), isEmpty);
      expect(Offices.I.held, contains('pingpong:ttn'));
    });

    test('office_post from a turn deep in a chain wakes nobody', () async {
      final o = team();
      Offices.I.jobOf = (id, officeId) => (kind: 'assign', depth: TeamReact.maxDepth, cause: 'ttl');
      final r = await Offices.I.execute('office_post', {'text': '@Amal please double-check my numbers'}, o, nova);
      expect(r, 'Posted.');
      expect(jobs(o), isEmpty);
    });

    test('one post starts at most one turn per bot', () {
      final o = team();
      o.watches.add(TeamWatch(id: 'w3', watcher: 'tta', from: 'ttn', instruction: 'Analyze it'));
      Offices.I.post(o, 'ttn', '@Amal the prices are in: 4.20 and 4.35. Please build the table.');
      expect(jobs(o).where((j) => j.botId == 'tta'), hasLength(1));
      expect(jobs(o).single.kind, 'react');
    });

    test('small talk starts nothing', () {
      final o = team();
      Offices.I.post(o, 'ttn', 'Thanks @Amal!');
      Offices.I.post(o, 'ttl', 'Nova: thanks');
      expect(jobs(o), isEmpty);
    });

    test('burst: at most TeamReact.burst bot-started turns per team in the window, then one system line', () {
      final o = team();
      for (var i = 0; i < TeamReact.burst + 3; i++) {
        Offices.I.post(o, 'ttl', '@Nova please check supplier number $i and its delivery terms.', dedupe: false);
      }
      expect(jobs(o, 'assign'), hasLength(TeamReact.burst));
      expect(o.posts.where((p) => p.kind == 'system' && p.text.contains('automatic replies pause')), hasLength(1));
    });

    test('the owner and system posts never start bot turns this way', () {
      final o = team();
      Offices.I.post(o, 'system', 'Nova: hello', kind: 'system');
      Offices.I.post(o, 'you', 'Nova: find prices', react: true);
      expect(jobs(o), isEmpty);
    });
  });

  group('collaboration fixes', () {
    test('a bot addressed while a team job runs, whose part is done, answers itself', () {
      final o = team();
      TeamRun.I.running.add(o.id);
      TeamRun.I.jobBotsForTest(o.id, {'ttl', 'tta'});
      TeamRun.I.send(o, 'Nova, add the delivery times too');
      expect(jobs(o, 'reply').map((j) => j.botId), ['ttn']);
      expect(o.posts.any((p) => p.kind == 'system'), isFalse);
      // One still working on its part gets it through the job, as before.
      TeamRun.I.send(o, 'Amal, use euros');
      expect(jobs(o, 'reply').map((j) => j.botId), ['ttn']);
      expect(o.posts.where((p) => p.kind == 'system'), hasLength(1));
    });

    test('handing the team over no longer overwrites the daily report time', () {
      final o = team()
        ..digestTime = '18:30'
        ..delegated = true;
      final back = Office.fromJson(o.toJson());
      expect(back.digestTime, '18:30');
      expect(back.delegated, isTrue);
      // A team saved by an older version (the flag on the report time's key) reads back sane.
      final old = Office.fromJson({...o.toJson()..remove('dl'), 'dg': true});
      expect(old.delegated, isTrue);
      expect(old.digestTime, '19:00');
    });

    test('a job keeps its chain through saving and retries', () {
      final j = OfficeJob(officeId: 'o', botId: 'b', kind: 'react', instruction: 'x', depth: 3, cause: 'ttn', post: 'p1', thread: 't');
      final back = OfficeJob.fromJson(j.toJson());
      expect([back.depth, back.cause, back.post], [3, 'ttn', 'p1']);
      final r = j.retry(after: DateTime.now(), tries: 2);
      expect([r.depth, r.cause, r.post, r.thread, r.tries], [3, 'ttn', 'p1', 't', 2]);
      expect(OfficeJob(officeId: 'o', botId: 'b', kind: 'assign').rank, OfficeJob(officeId: 'o', botId: 'b', kind: 'mention').rank);
    });
  });
}

String _read(String path) => File(path).readAsStringSync();
