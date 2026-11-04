// Teams never start on their own; given a task the lead posts the plan and the team starts (Grok group chats), asking the
// owner only when something is missing; the work is a visible conversation (2026-10-24).
import 'package:agent/services/bot_manner.dart';
import 'package:agent/services/bots.dart';
import 'package:agent/services/offices.dart';
import 'package:agent/services/team_run.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final lead = Bot(id: 'trl', name: 'Hodan', role: 'Manager', persona: 'Calm.');
  final nova = Bot(id: 'trn', name: 'Nova', role: 'Researcher', persona: 'Curious.');
  final amal = Bot(id: 'tra', name: 'Amal', role: 'Analyst', persona: 'Careful.');
  final calls = <String>[];
  var withQuestions = false;

  Future<String> fakeAsk(Bot b, String system, String user, {int maxTokens = 0}) async {
    // The team's "who speaks" decision (2026-10-24): small talk gets nobody; a job for the team goes to the lead.
    if (system.contains('# Who speaks')) {
      calls.add('floor');
      return user.toLowerCase().startsWith('hi') ? '{"speaker":"none","team_task":false}' : '{"speaker":"Hodan","team_task":true}';
    }
    if (system.contains('# Plan for the owner')) {
      calls.add('plan');
      final q = withQuestions ? '"Which city?"' : '';
      return '{"reply":"You want the three cheapest coffee suppliers in Hargeisa.","questions":[$q],'
          '"parts":[{"bot":"Nova","ask":"Find suppliers and prices"},{"bot":"Amal","ask":"Compare the prices"}]}';
    }
    if (system.contains('# Your part')) {
      calls.add('part:${b.name}');
      final saw = system.contains('Nova:') ? ' I used Nova\'s list.' : '';
      return 'Hodan, my part is done.$saw\n---\nFull result from ${b.name}.';
    }
    if (system.contains('# Combine')) {
      calls.add('combine');
      return 'Here are the three cheapest suppliers.';
    }
    calls.add('other');
    return '';
  }

  Office team() => Office(id: 'otr${DateTime.now().microsecondsSinceEpoch}', name: 'Coffee', members: ['trl', 'trn', 'tra'], chiefId: 'trl');

  setUp(() {
    Bots.I.bots.addAll([lead, nova, amal]);
    TeamRun.I
      ..reset()
      ..ask = fakeAsk
      ..promptOf = (b) => 'You are ${b.name}.';
    calls.clear();
    withQuestions = false;
    Offices.I.queue.clear();
  });
  tearDown(() {
    Bots.I.bots.removeWhere((b) => b.id.startsWith('tr'));
    Offices.I.offices.clear();
    Offices.I.queue.clear();
    TeamRun.I.reset();
  });

  test('creating and opening a team starts no work, even with a goal', () async {
    final o = await Offices.I.create(name: 'Coffee', goal: 'Sell more coffee', members: ['trl', 'trn', 'tra'], chiefId: 'trl');
    expect(Offices.I.queue, isEmpty, reason: 'no Chief kickoff job on create');
    expect(TeamRun.I.running, isEmpty);
    expect(TeamRun.I.awaitingGo(o), isFalse);
    expect(calls, isEmpty, reason: 'no model call');
    expect(o.posts.where((p) => p.from != 'system'), isEmpty, reason: 'only a system line saying the team waits for a task');
    expect(o.posts.last.text, contains('waits for you'));
  });

  test('small talk is a chat, not a job (and the lead does not answer it by default)', () async {
    final o = team();
    TeamRun.I.send(o, 'hi team');
    await TeamRun.I.work;
    expect(TeamRun.I.awaitingGo(o), isFalse);
    expect(TeamRun.I.running, isEmpty);
    expect(calls, ['floor']);
    expect(o.posts.where((p) => p.from == 'trl'), isEmpty);
  });

  test('a clear task: the lead posts the plan and the team starts right away (Grok)', () async {
    final o = team();
    TeamRun.I.send(o, 'Find the three cheapest coffee suppliers in Hargeisa');
    await TeamRun.I.work;
    expect(calls, ['floor', 'plan', 'part:Nova', 'part:Amal', 'combine']);
    expect(TeamRun.I.awaitingGo(o), isFalse);
    final plan = o.posts.firstWhere((p) => p.from == 'trl');
    expect(plan.text, contains('You want the three cheapest coffee suppliers'));
    expect(plan.text, contains('- Nova: Find suppliers and prices'));
    expect(plan.text, contains('- Amal: Compare the prices'));
    expect(plan.text, contains(BotManner.startingNow()));
    expect(plan.text, isNot(contains(BotManner.askGo())));
  });

  test('when the lead must ask, nobody works until the owner answers or says Go', () async {
    withQuestions = true;
    final o = team();
    TeamRun.I.send(o, 'Find the three cheapest coffee suppliers');
    await TeamRun.I.work;
    expect(calls, ['floor', 'plan']);
    expect(TeamRun.I.awaitingGo(o), isTrue);
    expect(o.posts.last.text, contains('Which city?'));
    expect(o.posts.last.text, contains(BotManner.askGo()));
    expect(o.posts.where((p) => p.from == 'trn' || p.from == 'tra'), isEmpty);
  });

  test('after Go: hand-offs, the members work side by side and each reports, then one answer', () async {
    // No cap and no queue (owner 2026-11-04): parts the lead did not hand off one by one all start at once.
    withQuestions = true;
    final o = team();
    TeamRun.I.send(o, 'Find the three cheapest coffee suppliers in Hargeisa');
    await TeamRun.I.work;
    expect(TeamRun.I.approve(o), isTrue);
    await TeamRun.I.work;
    expect(calls.take(2), ['floor', 'plan']);
    expect(calls.skip(2).take(2).toSet(), {'part:Nova', 'part:Amal'});
    expect(calls.last, 'combine');
    final said = [for (final p in o.posts) '${p.from}: ${p.text}'];
    final iNova = said.indexWhere((s) => s.startsWith('trl: Nova, could you please take this part'));
    final iNovaDone = said.indexWhere((s) => s.startsWith('trn: Hodan, my part is done'));
    final iAmal = said.indexWhere((s) => s.startsWith('trl: Amal, could you please take this part'));
    final iAmalDone = said.indexWhere((s) => s.startsWith('tra: Hodan, my part is done'));
    expect([iNova, iNovaDone, iAmal, iAmalDone].every((i) => i >= 0), isTrue, reason: said.join('\n'));
    expect(iNova < iNovaDone && iAmal < iAmalDone, isTrue);
    expect(iAmal < iNovaDone, isTrue, reason: 'Amal started before Nova finished: side by side, not in turn');
    final answer = o.posts.last;
    expect(answer.kind, 'answer');
    expect(answer.text, 'Here are the three cheapest suppliers.');
    expect(answer.parts.map((x) => x.from).toSet(), {'trn', 'tra'});
    expect(o.posts.firstWhere((p) => p.from == 'trn').parts.single.text, 'Full result from Nova.');
    expect(TeamRun.I.running, isEmpty);
  });

  test('a reply that is not Go changes the plan; Cancel sets it aside', () async {
    withQuestions = true;
    final o = team();
    TeamRun.I.send(o, 'Find coffee suppliers');
    await TeamRun.I.work;
    TeamRun.I.send(o, 'Only in Hargeisa please');
    await TeamRun.I.work;
    expect(calls, ['floor', 'plan', 'plan']);
    expect(TeamRun.I.awaitingGo(o), isTrue);
    TeamRun.I.cancelPlan(o);
    expect(TeamRun.I.awaitingGo(o), isFalse);
    expect(o.posts.last.text, BotManner.planCancelled());
    expect(calls.where((c) => c.startsWith('part')), isEmpty);
  });

  test('Go and Stop words, English and Somali', () {
    for (final t in ['Go', 'go ahead', 'Yes please', 'Start', 'approve', 'Haa', 'bilow']) {
      expect(TeamRun.isGo(t), isTrue, reason: t);
    }
    for (final t in ['Go to the market and buy rice', 'what is the plan?']) {
      expect(TeamRun.isGo(t), isFalse, reason: t);
    }
    for (final t in ['stop', 'Cancel', 'jooji']) {
      expect(TeamRun.isStop(t), isTrue, reason: t);
    }
  });

  test('a member reply without the --- line still gives a short note and the whole result', () {
    final r = TeamRun.splitReport('I checked five suppliers.\n\nAbdi Coffee: 4 USD/kg\nSahal: 5 USD/kg');
    expect(r.note, 'I checked five suppliers.');
    expect(r.result, contains('Sahal: 5 USD/kg'));
  });
}
