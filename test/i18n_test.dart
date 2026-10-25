import 'package:agent/ui/i18n.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Somali and Arabic cover the same words', () {
    final so = Strings.table['so']!.keys.toSet();
    final ar = Strings.table['ar']!.keys.toSet();
    expect(so.difference(ar), isEmpty, reason: 'Arabic is missing these');
    expect(ar.difference(so), isEmpty, reason: 'Somali is missing these');
  });

  test('holes survive translation', () {
    final hole = RegExp(r'\{[a-z]+\}');
    for (final lang in Strings.table.values) {
      lang.forEach((en, t) {
        expect(hole.allMatches(t).map((m) => m[0]).toSet(), hole.allMatches(en).map((m) => m[0]).toSet(), reason: en);
      });
    }
  });

  test('English falls back to the key and fills holes', () {
    AppLang.I.choice = 'en';
    expect(tr('Settings'), 'Settings');
    expect(tr('Hi {name}. What can I do?', {'name': 'Amina'}), 'Hi Amina. What can I do?');
    AppLang.I.choice = 'so';
    expect(tr('Settings'), 'Dejinta');
    expect(tr('Not in the table'), 'Not in the table');
  });
}
