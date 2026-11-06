// Bots on opencode (owner, 2026-11-03): a bot's turn gets its own brief (who it is, what it knows, its tools) after
// opencode's prompt, and its own tools are called through submac_run_tool.
import 'package:agent/services/bots.dart';
import 'package:agent/services/submac_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a bot\'s opencode brief: its name, its memory, its desk, its tools and its folder', () {
    final b = Bot(id: 'boc1', name: 'Hodan', role: 'sales lead', persona: 'Direct and warm.', mission: 'Grow the shop')
      ..memory.add('The shop opens at 9')
      ..desk.add(DeskTask('t1', 'Call three suppliers'));
    Bots.I.bots.add(b);
    addTearDown(() => Bots.I.bots.removeWhere((x) => x.id == 'boc1'));
    final t = Bots.I.opencodeBriefOf(b);
    expect(t, contains('You are Hodan'));
    expect(t, contains('Grow the shop'));
    expect(t, contains('The shop opens at 9'));
    expect(t, contains('Call three suppliers'));
    expect(t, contains('submac_run_tool'));
    for (final n in ['bot_remember', 'bot_desk', 'bot_followup', 'bot_routine', 'bot_watch', 'bot_ask']) {
      expect(t, contains('- $n:'), reason: n);
    }
    expect(t, isNot(contains('- bot_make:')), reason: 'only the Chief makes bots');
    expect(t, contains('bots/boc1/'));
    expect(t, contains('Never say you are opencode'));
    expect(t, isNot(contains('Your name is Telesia')));
  });

  test('bot tools run through the gateway by name', () async {
    String? ran;
    final g = SubMacGateway(tools: () => Bots.definitions, run: (n, a) async {
      ran = n;
      return 'ok';
    });
    expect(await g.call(SubMacGateway.runName, {'name': 'bot_remember', 'arguments': {'fact': 'x'}}), 'ok');
    expect(ran, 'bot_remember');
  });
}
