// Owner 2026-11-08: a bot and a team member are people, not an approval workflow. No gate, no approval card: a risky
// call runs (their brief tells them to ask the owner in words first). SubMac's own chat keeps its card.
import 'package:agent/app_state.dart';
import 'package:agent/services/bots.dart';
import 'package:agent/services/team_key.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
