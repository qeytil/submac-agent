import 'package:agent/services/bots.dart';
import 'package:agent/services/offices.dart';
import 'package:flutter_test/flutter_test.dart';

/// 2026-10-21: teams burned the owner's allowance by working on their own and by bots waking each other without end.
void main() {
  Office team({String mode = 'manual'}) => Office(id: 'ob1', name: 'Shop', goal: 'Sell more', members: ['a', 'b'], chiefId: 'a', mode: mode);

  test('a new team works only when the owner asks, with a small daily limit', () {
    final o = Office(id: 'x', name: 'New');
    expect(o.mode, 'manual');
    expect(o.manual, isTrue);
    expect(o.dailyLimit, 15);
    // "Works on its own" is gone (2026-10-24): an old saved team in that mode reads as "Only when I ask".
    expect(Office.fromJson({'id': 'y', 'name': 'Old', 'mode': 'away'}).mode, 'manual');
  });

  test('a teammate\'s message is a mention, never the owner, and cannot start new work', () {
    final t = Offices.I.jobText(team(), _bot, OfficeJob(officeId: 'ob1', botId: 'b', kind: 'mention', instruction: 'Hodan wrote to you: "@Nova check prices"'));
    expect(t, contains('teammate, not the owner'));
    expect(t, contains('do not @mention anyone back'));
    expect(t, isNot(contains('The owner wrote')));
    expect(OfficeJob(officeId: 'o', botId: 'b', kind: 'mention').rank, lessThan(OfficeJob(officeId: 'o', botId: 'b', kind: 'task').rank));
  });

  test('the lead adds no new tasks on its own in a team that works on request', () {
    final manual = Offices.I.jobText(team(), _bot, OfficeJob(officeId: 'ob1', botId: 'a', kind: 'chief'));
    expect(manual, contains('Add no new tasks'));
    final away = Offices.I.jobText(team(mode: 'away'), _bot, OfficeJob(officeId: 'ob1', botId: 'a', kind: 'chief'));
    expect(away, contains('add the next 1 to 5 useful tasks'));
    expect(Offices.I.teamLivePromptOf(team(), _bot), contains('on request: do only what the owner asked'));
  });

  test('retries are remembered so busy models do not cause endless tries', () {
    final j = OfficeJob(officeId: 'o', botId: 'b', kind: 'task', taskId: 't1', tries: 2);
    expect(OfficeJob.fromJson(j.toJson()).tries, 2);
    expect(OfficeJob.fromJson(OfficeJob(officeId: 'o', botId: 'b', kind: 'task').toJson()).tries, 0);
  });
}

final _bot = Bot(id: 'b', name: 'Nova', role: 'Researcher', persona: 'Curious.');
