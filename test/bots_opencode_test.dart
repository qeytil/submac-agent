// A bot's own-engine brief (owner 2026-11-07): who it is, what it knows, its tools (called directly by name, never
// through opencode's telesia_run_tool) and its folder. opencode is the owner's chat only now.
import 'package:agent/services/bots.dart';
import 'package:agent/services/telesia_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a bot\'s brief: its name, its memory, its desk, its tools and its folder', () {
    final b = Bot(id: 'boc1', name: 'Hodan', role: 'sales lead', persona: 'Direct and warm.', mission: 'Grow the shop')
      ..memory.add('The shop opens at 9')
      ..desk.add(DeskTask('t1', 'Call three suppliers'));
    Bots.I.bots.add(b);
    addTearDown(() => Bots.I.bots.removeWhere((x) => x.id == 'boc1'));
    final t = Bots.I.agentBriefOf(b);
    expect(t, contains('You are Hodan'));
    expect(t, contains('Grow the shop'));
    expect(t, contains('The shop opens at 9'));
    expect(t, contains('Call three suppliers'));
    expect(t, contains('# Your tools'));
    expect(t, contains('Your tools are listed in this request'));
    expect(t, contains('Call one directly by its name'));
    expect(t, isNot(contains('telesia_run_tool')), reason: 'the bot engine calls every tool by name');
    expect(t, isNot(contains('find_tools')), reason: 'no find/run gateway');
    for (final n in ['bot_remember', 'bot_desk', 'bot_followup', 'bot_routine', 'bot_watch', 'bot_ask']) {
      expect(t, contains('- $n:'), reason: n);
    }
    expect(t, isNot(contains('- bot_make:')), reason: 'only the Chief makes bots');
    expect(t, contains('bots/boc1/'));
    expect(t, contains('Your name is Hodan'));
    expect(t, isNot(contains('Your name is Telesia')));
    // Owner 2026-11-08: no approval card; it asks the owner in words before anything big.
    expect(t, contains('there is no approval card'));
    expect(t, contains('can I ...?'));
    // In the team chat the owner is not watching: no question-tool line.
    expect(Bots.I.agentBriefOf(b, team: true), isNot(contains('call your question tool')));
  });

  test('bot tools run through the gateway by name', () async {
    String? ran;
    final g = TelesiaGateway(tools: () => Bots.definitions, run: (n, a) async {
      ran = n;
      return 'ok';
    });
    expect(await g.call(TelesiaGateway.runName, {'name': 'bot_remember', 'arguments': {'fact': 'x'}}), 'ok');
    expect(ran, 'bot_remember');
  });
}
