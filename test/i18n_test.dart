import 'package:agent/ui/i18n.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the app has English only', () {
    expect(Strings.table.keys, ['en']);
  });

  test('holes survive the English wording', () {
    final hole = RegExp(r'\{[a-z]+\}');
    Strings.table['en']!.forEach((en, t) {
      expect(hole.allMatches(t).map((m) => m[0]).toSet(), hole.allMatches(en).map((m) => m[0]).toSet(), reason: en);
    });
  });

  test('English falls back to the key and fills holes; the bots are digital people', () {
    expect(tr('Settings'), 'Settings');
    expect(tr('Hi {name}. What can I do?', {'name': 'Amina'}), 'Hi Amina. What can I do?');
    expect(tr('Not in the table'), 'Not in the table');
    expect(tr('Bots'), 'Digital people');
    expect(tr('New bot'), 'New digital person');
  });
}