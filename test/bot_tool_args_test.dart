// A model's bad arguments must never break a turn (bug audit 2026-11-07): bot_make and team_make take lists
// ("skills", "members") and a model sometimes sends one as text; bot_followup takes minutes and a model sometimes
// writes "30 minutes". Each call answers plainly now instead of throwing out of the tool.
import 'package:agent/services/bots.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Bot chief;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Bots.I.init();
    chief = Bot(id: 'ch1', name: 'Hodan', role: 'Chief', persona: '')
      ..active = true
      ..convId = 'conv-ch1';
    Bots.I.bots.add(chief);
    Bots.I.chiefId = chief.id;
  });
  tearDown(() {
    Bots.I.bots.clear();
    Bots.I.chiefId = '';
  });

  test('bot_make: skills sent as one text line make the draft, not an error', () async {
    final r = await Bots.I.execute('bot_make', {
      'action': 'draft',
      'name': 'Amal',
      'role': 'Designer',
      'instructions': 'Makes posters',
      'skills': 'posters, captions',
    }, chief.convId);
    expect(r, contains('Draft ready'), reason: r);
    expect(r, contains('posters, captions'));
  });

  test('team_make: members sent as one text line make the draft', () async {
    final r = await Bots.I.execute('team_make', {
      'action': 'draft',
      'name': 'Shop',
      'members': 'Amal, Hodin',
      'goal': 'Launch the shop',
    }, chief.convId);
    expect(r, contains('Draft ready'), reason: r);
    expect(r, contains('Amal'));
  });

  test('bot_followup: "30 minutes" is read as thirty minutes', () async {
    final r = await Bots.I.execute('bot_followup', {
      'in_minutes': '30 minutes',
      'instruction': 'Check the news',
    }, chief.convId);
    expect(r, contains('will be woken'), reason: r);
  });

  test('wrong types always come back as a line, never thrown out of the tool', () async {
    final calls = <(String, Map<String, dynamic>)>[
      ('bot_make', {'action': 'draft', 'name': 5, 'role': ['a'], 'instructions': true, 'skills': 7}),
      ('team_make', {'action': 'draft', 'name': 5, 'members': 7}),
      ('bot_followup', {'in_minutes': 'soon', 'instruction': 5}),
    ];
    for (final (name, args) in calls) {
      final r = await Bots.I.execute(name, args, chief.convId);
      expect(r, isNotEmpty, reason: name);
    }
  });
}
