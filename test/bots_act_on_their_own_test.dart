// Owner 2026-11-08: a bot and a team member are people, not an approval workflow. No gate, no approval card: a risky
// call runs (their brief tells them to ask the owner in words first). Telesia's own chat keeps its card.
import 'dart:io';

import 'package:agent/app_state.dart';
import 'package:agent/services/bots.dart';
import 'package:agent/services/team_key.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a bot\'s risky call is never gated by a card', () async {
    final b = Bot(id: 'na1', name: 'Nova', role: 'Researcher', persona: '')..convId = 'conv-na1';
    Bots.I.bots.add(b);
    addTearDown(() => Bots.I.bots.removeWhere((x) => x.id == 'na1'));
    final s = AppState();
    // Ways a bot used to be carded: a delete, a file change, a tap in another app.
    for (final n in ['delete_file', 'edit_file', 'phone_tap']) {
      final g = await s.toolGate(n, {'path': 'a.txt', 'text': 'x', 'id': 1}, b.convId);
      expect(g.ask, isNull, reason: '$n must not wait on a card');
      expect(g.blocked, isNull, reason: n);
    }
  });

  test('a team member\'s call under its team key is never gated by a card', () async {
    final b = Bot(id: 'na2', name: 'Amal', role: 'Analyst', persona: '')..convId = 'conv-na2';
    Bots.I.bots.add(b);
    addTearDown(() => Bots.I.bots.removeWhere((x) => x.id == 'na2'));
    final s = AppState();
    final key = TeamKey.of('o1', 'na2', job: TeamKey.job());
    final g = await s.toolGate('delete_file', {'path': 'a.txt'}, key);
    expect(g.ask, isNull);
    expect(g.blocked, isNull);
  });

  test('a new bot is born free: no off hours by default', () {
    final b = Bot(id: 'fr1', name: 'Free', role: 'x', persona: '');
    expect(b.quietFrom, b.quietTo, reason: 'quietFrom == quietTo means "none"');
    for (var h = 0; h < 24; h++) {
      expect(b.quietNow(DateTime(2026, 11, 8, h, 30)), isFalse, reason: 'hour $h');
    }
  });

  test('a new bot is born free: a light self-wake and no daily limit', () {
    final b = Bot(id: 'fr2', name: 'Free', role: 'x', persona: '');
    expect(b.proactivity, 'free');
    expect(b.heartbeatHours, 6, reason: 'it wakes on its own, lightly');
    expect(b.messageCap, greaterThanOrEqualTo(99), reason: 'no practical daily cap');
    expect(b.callCap, greaterThanOrEqualTo(99));
    b.messagesToday = 90;
    expect(b.messagesLeft, greaterThan(0), reason: '90 messages in a day is still free');
  });

  test('a bot proposes a mission; the owner\'s yes starts it once', () async {
    SharedPreferences.setMockInitialValues({});
    await Bots.I.init();
    final b = Bot(id: 'mp1', name: 'Nova', role: 'Analyst', persona: '');
    Bots.I.bots.add(b);
    addTearDown(() => Bots.I.bots.removeWhere((x) => x.id == 'mp1'));
    Bots.I.propose(b, 'Grow the shop', ['find suppliers', 'compare prices']);
    expect(b.proposeGoal, 'Grow the shop');
    expect(Bots.I.approvedProposal(b, 'not now'), isNull, reason: 'a no leaves it waiting');
    expect(b.proposeGoal, 'Grow the shop');
    // Off a fresh proposal the answer must clearly agree.
    final yes = Bots.I.approvedProposal(b, 'yes, go ahead');
    expect(yes?.goal, 'Grow the shop');
    expect(yes?.steps, ['find suppliers', 'compare prices']);
    expect(b.proposeGoal, isEmpty, reason: 'it starts once');
    expect(Bots.I.approvedProposal(b, 'yes'), isNull, reason: 'nothing waits now');
  });

  test('the Telesia allowance never stops or bills a bot on its own key', () {
    final ctl = File('lib/state/bots_controller.dart').readAsStringSync();
    expect(ctl, contains("b.overBudget && kind != 'chat' && BotModelRoute.of(b).byok == null"));
    expect(ctl, contains("b.overBudget && j.kind != 'reply' && BotModelRoute.of(b).byok == null"));
    expect(ctl, contains('if (!route.isByok) {'), reason: 'the one-answer calls count Telesia-lane work only');
    final runner = File('lib/state/agent_runner.dart').readAsStringSync();
    expect(runner, contains('if (!OcLane.isByok(laneModel)) bot.addTokens(turn.tokens);'));
    expect(runner, contains('if (own == null) b.addTokens(r.tokens);'));
    final router = File('lib/state/tool_router.dart').readAsStringSync();
    expect(router, isNot(contains('bot.addTokens(r.tokens)')), reason: 'a BYOK browser step is not Telesia-billed');
  });
}
