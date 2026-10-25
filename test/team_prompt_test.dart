import 'package:flutter_test/flutter_test.dart';
import 'package:agent/services/bots.dart';
import 'package:agent/services/offices.dart';

void main() {
  final lead = Bot(id: 'tl1', name: 'Hodan', role: 'Manager', persona: 'Calm.');
  final mate = Bot(id: 'tm1', name: 'Nova', role: 'Researcher', persona: 'Curious.');
  setUpAll(() => Bots.I.bots.addAll([lead, mate]));
  tearDownAll(() => Bots.I.bots.removeWhere((b) => b.id == 'tl1' || b.id == 'tm1'));

  Office team() => Office(id: 'tp1', name: 'Hodan Coffee', goal: 'Sell more coffee', members: ['tl1', 'tm1'], chiefId: 'tl1',
      rules: 'Ask me before paying')
    ..folder = 'Teams/Hodan Coffee';

  group('team prompts', () {
    test('stable part names the team, lead, folder, approval card and trust', () {
      final s = Offices.I.teamStablePromptOf(team(), mate);
      expect(s, contains('# Your team: Hodan Coffee'));
      expect(s, contains('Your lead is Hodan'));
      expect(s, contains('Files > Teams/Hodan Coffee'));
      expect(s, contains('Approve · Edit · Not now'));
      expect(s, contains('New or Trusted'));
      expect(s, contains('Ask me before paying'));
      final l = Offices.I.teamStablePromptOf(team(), lead);
      expect(l, contains('You are the lead'));
      expect(l, contains('office_ask_owner'));
    });

    test('stable part does not change while the team works', () {
      final o = team();
      final before = Offices.I.teamStablePromptOf(o, mate);
      o.tasks.add(OfficeTask(id: 't1', title: 'Price check', owner: 'tm1', status: 'doing'));
      o.posts.add(OfficePost(id: 'p1', from: 'you', text: 'Go'));
      o.brief.add('Beans from Yirgacheffe');
      o.runsToday = 5;
      expect(Offices.I.teamStablePromptOf(o, mate), before);
      final live = Offices.I.teamLivePromptOf(o, mate);
      expect(live, contains('Price check'));
      expect(live, contains('Owner: Go'));
      expect(live, contains('Beans from Yirgacheffe'));
    });

    test('stable text comes first and every tool name is still mentioned', () {
      final o = team();
      final p = Offices.I.promptFor(o, lead, OfficeJob(officeId: o.id, botId: 'tl1', kind: 'check'));
      expect(p.startsWith(Offices.I.teamStablePromptOf(o, lead)), isTrue);
      for (final n in ['office_board', 'office_post', 'office_brief', 'office_kpi', 'office_ask_owner', 'docs_share', 'docs_list', 'docs_read']) {
        expect(p, contains(n), reason: n);
      }
      expect(Offices.names, containsAll(['office_board', 'office_post', 'office_brief', 'office_ask_owner', 'office_kpi', 'docs_share', 'docs_list', 'docs_read']));
    });

    test('shorter than before', () {
      final o = team();
      expect(Offices.I.teamStablePromptOf(o, lead).length, lessThan(2200));
    });
  });
}
