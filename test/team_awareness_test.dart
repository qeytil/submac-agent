// Team awareness (owner feedback 2026-11-05): no duplicate messages, every bot knows who it is and who said what,
// one bot answers unless several are needed (then one after another), the lead leads only when the owner is away or
// hands over and never parrots the owner, and a bot that needs the owner says so with a "needs you" post.
import 'package:agent/services/bot_manner.dart';
import 'package:agent/services/bots.dart';
import 'package:agent/services/offices.dart';
import 'package:agent/services/team_floor.dart';
import 'package:agent/services/team_run.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final lead = Bot(id: 'twl', name: 'Hodan', role: 'Manager', persona: 'Calm.');
  final nova = Bot(id: 'twn', name: 'Nova', role: 'Researcher', persona: 'Curious.');
  final amal = Bot(id: 'twa', name: 'Amal', role: 'Analyst', persona: 'Careful.');
  final calls = <String>[];
  var floor = '{"speaker":"none","team_task":false}';
  var planReply = '{"reply":"We will compare and write it up.","questions":[],"parts":[{"bot":"Nova","ask":"Find three laptop prices"},{"bot":"Amal","ask":"Make the comparison table"}]}';

  Future<String> fakeAsk(Bot b, String system, String user, {int maxTokens = 0}) async {
    if (system.contains('# Who speaks')) {
      calls.add('floor');
      return floor;
    }
    if (system.contains('# Plan for the owner')) {
      calls.add('plan');
      return planReply;
    }
    if (system.contains('# Your part')) {
      calls.add('part:${b.name}');
      return 'Done my part.\n---\nResult from ${b.name}.';
    }
    if (system.contains('# Combine')) {
      calls.add('combine');
      return 'Combined answer for the owner.';
    }
    calls.add('other');
    return '';
  }

  Office team() => Office(id: 'otw${DateTime.now().microsecondsSinceEpoch}', name: 'Coffee', members: ['twl', 'twn', 'twa'], chiefId: 'twl');
  List<OfficeJob> replies(Office o) => [for (final j in Offices.I.queue.where((j) => j.officeId == o.id && j.kind == 'reply')) j];
  List<String> asked(Office o) => [for (final j in replies(o)) j.botId];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Bots.I.bots.addAll([lead, nova, amal]);
    TeamRun.I
      ..reset()
      ..ask = fakeAsk
      ..promptOf = (b) => 'You are ${b.name}.';
    calls.clear();
    floor = '{"speaker":"none","team_task":false}';
    planReply = '{"reply":"We will compare and write it up.","questions":[],"parts":[{"bot":"Nova","ask":"Find three laptop prices"},{"bot":"Amal","ask":"Make the comparison table"}]}';
    Offices.I.queue.clear();
  });
  tearDown(() {
    Bots.I.bots.removeWhere((b) => b.id.startsWith('tw'));
    Offices.I.queue.clear();
    Offices.I.notify = null;
    Offices.I.notifyNeeds = null;
    TeamRun.I.reset();
  });

  group('transcript: every message labelled', () {
    test('speaker, role, kind, "you", addressee, reply link and time', () {
      final o = team();
      final q = Offices.I.post(o, 'you', '@Nova what did you find on prices?');
      Offices.I.post(o, 'twn', 'Three shops so far, the cheapest is 420.', replyTo: q.id);
      Offices.I.post(o, 'twl', 'Hodan here, noted.');
      Offices.I.post(o, 'system', 'Team opened.', kind: 'system');
      final lines = TeamTranscript.lines(o, selfId: 'twn');
      expect(lines[0], matches(RegExp(r'^#1 \d\d:\d\d Owner → Nova: @Nova what did you find')));
      expect(lines[1], contains('Nova (member, Researcher; you) → Owner (reply to #1): Three shops'));
      expect(lines[2], contains('Hodan (lead, Manager): Hodan here'));
      expect(lines[3], contains('System: Team opened.'));
    });

    test('the bot\'s own identity, the roster with roles and the lead', () {
      final o = team();
      final t = TeamTranscript.build(o, amal);
      expect(t, contains('You are Amal, Analyst, a member of the team "Coffee" (lead: Hodan, Manager)'));
      expect(t, contains('- Hodan: team lead, Manager'));
      expect(t, contains('- Amal: member, Analyst  <- this is you'));
      expect(t, contains('- Owner: the person the whole team works for'));
      expect(TeamTranscript.identity(o, lead), contains('the lead of the team'));
    });

    test('situation: who already answered, what waits on the owner, whether the owner is here', () {
      final o = team()..lastOwnerPost = DateTime.now();
      Offices.I.post(o, 'you', 'What should the price be?');
      var s = TeamTranscript.situation(o, selfId: 'twa').join('\n');
      expect(s, contains('The owner last asked (the team'));
      expect(s, contains('Nobody has answered'));
      expect(s, contains('The owner is here'));
      expect(s, contains('Hodan, the lead, acts as a regular member'));
      Offices.I.post(o, 'twn', '[needs you] Do you want retail or wholesale pricing?');
      s = TeamTranscript.situation(o, selfId: 'twa', working: ['Hodan']).join('\n');
      expect(s, contains('Already answered after it by: Nova'));
      expect(s, contains('Waiting on the owner: Nova: "Do you want retail'));
      expect(s, contains('Working on a reply right now: Hodan'));
      expect(TeamTranscript.lines(o).last, contains('[NEEDS OWNER]'));
    });

    test('the office prompt carries the labelled chat and the situation', () {
      final o = team();
      Offices.I.post(o, 'you', 'Morning team');
      final p = Offices.I.teamLivePromptOf(o, nova);
      expect(p, contains('Owner: Morning team'), reason: 'no addressee for the room: plain label');
      expect(p, contains('# The situation'));
      expect(Offices.I.teamStablePromptOf(o, nova), contains('You are Nova, Researcher'));
      expect(Offices.I.teamStablePromptOf(o, nova), contains('Nova: Researcher (you)'));
    });
  });

  group('turn selection', () {
    test('rules: addressed, a role named, the lead named, a bot\'s open question, else the model', () {
      final o = team();
      expect(TeamFloor.rules(o, 'x', addressed: [amal]).speakers, [amal]);
      expect(TeamFloor.rules(o, 'Could the analyst check the totals?').speakers, [amal]);
      expect(TeamFloor.rules(o, 'Can the team lead give me an update?').speakers, [lead]);
      expect(TeamFloor.rules(o, 'What do you all think?').needModel, isTrue);
      Offices.I.post(o, 'twn', 'Should I include second-hand shops?');
      expect(TeamFloor.rules(o, 'Yes, include them').speakers, [nova], reason: 'answers Nova\'s question');
    });

    test('an unaddressed question: one bot answers, not all', () async {
      final o = team();
      floor = '{"speaker":"Amal","team_task":false}';
      TeamRun.I.send(o, 'What do you think about the margins?');
      await TeamRun.I.work;
      expect(asked(o), ['twa']);
      expect(calls, ['floor']);
    });

    test('a role named needs no model call', () async {
      final o = team();
      TeamRun.I.send(o, 'Researcher, any news on suppliers?');
      await TeamRun.I.work;
      expect(asked(o), ['twn']);
      expect(calls, isEmpty);
    });

    test('a job for several roles while the owner is here: the members it needs, in one thread, no lead plan', () async {
      final o = team();
      floor = '{"speaker":"Nova","speakers":["Nova","Amal"],"team_task":true}';
      TeamRun.I.send(o, 'Compare three laptops and make a table');
      await TeamRun.I.work;
      expect(calls, ['floor'], reason: 'the lead does not plan while the owner leads');
      expect(asked(o), ['twn', 'twa']);
      final th = replies(o).map((j) => j.thread).toSet();
      expect(th.length, 1);
      expect(th.first, o.posts.firstWhere((p) => p.from == 'you').id);
    });

    test('"@team": everyone, one after another (one thread)', () {
      final o = team();
      TeamRun.I.send(o, '@team quick update please');
      expect(asked(o)..sort(), ['twa', 'twl', 'twn']);
      expect(replies(o).map((j) => j.thread).toSet().length, 1);
      expect(replies(o).first.thread, isNotEmpty);
    });

    test('a thread job waits while another job of the thread runs', () {
      final j = OfficeJob(officeId: 'o', botId: 'b', kind: 'reply', thread: 'p1');
      expect(TeamTurns.waitsForThread(j, ['p1']), isTrue);
      expect(TeamTurns.waitsForThread(j, ['p2']), isFalse);
      expect(TeamTurns.waitsForThread(OfficeJob(officeId: 'o', botId: 'b', kind: 'reply'), ['']), isFalse);
    });

    test('a thread job sees who answered before it and may pass', () {
      final o = team();
      final p = Offices.I.post(o, 'you', '@Nova @Amal thoughts on the price?');
      final j = OfficeJob(officeId: o.id, botId: 'twa', kind: 'reply', instruction: '@Nova @Amal thoughts on the price?', thread: p.id);
      expect(Offices.I.jobText(o, amal, j), contains('You answer first.'));
      Offices.I.post(o, 'twn', 'I would start at 4.50, in line with the two shops nearby.');
      final t = Offices.I.jobText(o, amal, j);
      expect(t, contains('Already answered by Nova'));
      expect(t, contains('[no reply]'));
      expect(Offices.I.threadAnswers(o, p.id, except: 'twa'), ['Nova']);
    });

    test('the same words sent twice wait once', () {
      final o = team();
      TeamRun.I.send(o, '@Nova check the supplier');
      TeamRun.I.send(o, '@Nova check the supplier');
      expect(asked(o), ['twn']);
    });

    test('the lead given a job alongside named teammates: their own replies go, the lead plans', () async {
      final o = team();
      floor = '{"speaker":"Hodan","team_task":true}';
      TeamRun.I.send(o, '@Hodan @Nova please organise the laptop comparison with the team');
      await TeamRun.I.work;
      expect(calls.first, 'floor');
      expect(calls, contains('plan'));
      expect(asked(o), isEmpty, reason: 'Nova gets a part from the plan, not a second reply of her own');
    });

    test('the "who speaks" prompt reads labelled messages and the lead mode', () {
      final o = team()..lastOwnerPost = DateTime.now();
      Offices.I.post(o, 'twn', 'Prices are in.');
      final s = TeamRun.floorSystem(o, lead, [nova, amal]);
      expect(s, contains('Nova (member, Researcher): Prices are in.'));
      expect(s, contains('the lead is a member like the others'));
      o.delegated = true;
      expect(TeamRun.floorSystem(o, lead, [nova, amal]), contains('The lead is leading right now'));
    });
  });

  group('dedupe', () {
    test('near duplicates, short lines, different texts', () {
      expect(TeamDedupe.near('The cheapest laptop is 420 at Shop A.', 'the cheapest laptop is 420 at shop A'), isTrue);
      expect(TeamDedupe.near('Thanks', 'Thanks!'), isTrue);
      expect(TeamDedupe.near('Done.', 'Done: the report is in the folder.'), isFalse);
      expect(TeamDedupe.near('I found three suppliers in Hargeisa with prices.', 'The table compares delivery times for each supplier.'), isFalse);
      expect(TeamDedupe.parrots('Compare three laptops under 500 and make a table', 'Nova, could you please take this part: compare three laptops under 500 and make a table'), isTrue);
      expect(TeamDedupe.parrots('Compare three laptops under 500 and make a table', 'Find current prices for the Dell, Lenovo and HP models at two shops'), isFalse);
    });

    test('a bot repeating itself or a teammate is dropped; the owner and system lines are not', () {
      final o = team();
      final a = Offices.I.post(o, 'twn', 'The cheapest laptop is 420 at Shop A, with free delivery.');
      final before = Offices.I.dropped;
      final b = Offices.I.post(o, 'twn', 'The cheapest laptop is 420 at Shop A, with free delivery!');
      expect(identical(a, b), isTrue);
      final c = Offices.I.post(o, 'twa', 'The cheapest laptop is 420 at Shop A with free delivery.');
      expect(identical(a, c), isTrue);
      expect(Offices.I.dropped, before + 2);
      Offices.I.post(o, 'you', 'ok');
      Offices.I.post(o, 'you', 'ok');
      Offices.I.post(o, 'system', 'Noted.', kind: 'system');
      Offices.I.post(o, 'system', 'Noted.', kind: 'system');
      expect(o.posts.length, 5);
    });

    test('a bot echoing the owner\'s message is dropped', () {
      final o = team();
      final p = Offices.I.post(o, 'you', 'Compare three laptops under 500 and make a table');
      final echo = Offices.I.post(o, 'twl', 'Team: compare three laptops under 500 and make a table.');
      expect(identical(echo, p), isTrue);
      expect(o.posts.length, 1);
    });
  });

  group('needs you', () {
    test('the marker makes a "Needs you" post, stripped, and tells the owner', () async {
      final o = team();
      final told = <String>[];
      Offices.I.notify = (o, b, t) async => told.add('${b.name}: $t');
      final p = Offices.I.post(o, 'twn', '[needs you] Which budget should I use?');
      expect(p.kind, 'ask');
      expect(p.text, 'Which budget should I use?');
      await Future<void>.delayed(Duration.zero);
      expect(told, ['Nova: Which budget should I use?']);
      expect(NeedsYou.parse('All done.').needs, isFalse);
    });
  });

  group('lead mode', () {
    test('commands', () {
      expect(TeamLeadMode.commandOf('Hodan, take over please'), isNull, reason: 'no lead word: the name routes it, not a command');
      expect(TeamLeadMode.commandOf('Lead, take over while I sleep'), 'delegate');
      expect(TeamLeadMode.commandOf("I'm away for the afternoon"), 'delegate');
      expect(TeamLeadMode.commandOf('Take over'), 'delegate');
      expect(TeamLeadMode.commandOf("I'm back"), 'reclaim');
      expect(TeamLeadMode.commandOf('What did we decide on prices?'), isNull);
      expect(TeamLeadMode.rest("I'm away. Compare three laptops and make a table."), 'Compare three laptops and make a table');
    });

    test('peer while the owner is here, leading when away or handed over', () {
      final o = team();
      final now = DateTime.now();
      expect(TeamLeadMode.of(o, now: now), TeamLeadMode.peer, reason: 'the owner never wrote: nobody to be away from');
      o.lastOwnerPost = now.subtract(const Duration(minutes: 5));
      expect(TeamLeadMode.of(o, now: now), TeamLeadMode.peer);
      o.lastOwnerPost = now.subtract(const Duration(minutes: 30));
      expect(TeamLeadMode.of(o, now: now), TeamLeadMode.leading);
      expect(TeamLeadMode.indicator(o, now: now), 'Hodan is leading while you are away');
      o
        ..lastOwnerPost = now
        ..delegated = true;
      expect(TeamLeadMode.of(o, now: now), TeamLeadMode.leading);
      expect(TeamLeadMode.indicator(o, now: now), 'Hodan is leading the team');
      expect(Offices.I.teamStablePromptOf(o, lead), contains('Lead mode: LEADING'));
      o.delegated = false;
      expect(TeamLeadMode.indicator(o, now: now), '');
      expect(Offices.I.teamStablePromptOf(o, lead), contains('Lead mode: PEER'));
    });

    test('"lead, take over" hands over, "I\'m back" takes it back, each with one line', () {
      final o = team();
      TeamRun.I.send(o, 'Lead, take over');
      expect(o.delegated, isTrue);
      expect(o.posts.last.text, BotManner.leadTakesOver('Hodan'));
      expect(asked(o), isEmpty);
      TeamRun.I.send(o, "I'm back");
      expect(o.delegated, isFalse);
      expect(o.posts.last.text, BotManner.ownerLeads('Hodan'));
      expect(o.posts.where((p) => p.from == 'you').length, 2);
    });

    test('handing over with a job: the lead plans concrete parts and never copies the owner', () async {
      final o = team();
      TeamRun.I.send(o, "I'm away. Compare three laptops under 500 and make a table.");
      await TeamRun.I.work;
      expect(o.delegated, isTrue);
      expect(calls, containsAll(['plan', 'part:Nova', 'part:Amal', 'combine']));
      expect(o.posts.where((p) => p.text.contains('could you please take this part')), isEmpty,
          reason: 'the plan shows each part once; no hand-off repeats it');
      expect(o.posts.where((p) => p.from == 'you').length, 1, reason: 'the owner\'s message is posted once');
    });

    test('a plan that copies the owner\'s words gets a part for each role instead', () async {
      final o = team()..delegated = true;
      planReply = '{"reply":"Compare three laptops under 500 and make a table","questions":[],"parts":[{"bot":"Nova","ask":"Compare three laptops under 500 and make a table"}]}';
      TeamRun.I.send(o, 'Compare three laptops under 500, then make a table');
      await TeamRun.I.work;
      final plan = o.posts.firstWhere((p) => p.from == 'twl');
      expect(plan.text, isNot(contains('Compare three laptops under 500 and make a table')));
      expect(plan.text, contains(TeamRun.roleAsk(nova).substring(0, 30)));
    });

    test('while the owner is here, a listed job is not planned by the lead', () async {
      final o = team()..lastOwnerPost = DateTime.now();
      floor = '{"speaker":"Nova","speakers":["Nova","Amal"],"team_task":true}';
      TeamRun.I.send(o, '1) compare three laptops\n2) make a table');
      await TeamRun.I.work;
      expect(calls, isNot(contains('plan')));
      expect(asked(o), ['twn', 'twa']);
    });
  });
}
