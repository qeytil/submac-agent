import 'package:agent/services/submac_style.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SubMac on opencode', () {
    test('the prompt gets the name only', () {
      final t = SubMacStyle.identity;
      expect(t, contains('your name is SubMac'));
      expect(t, contains('Never say you are opencode'));
      expect(t.length, lessThan(300));
      for (final w in ['not a developer', 'terminal', '```', 'always follow']) {
        expect(t, isNot(contains(w)), reason: w);
      }
    });

    test('the cards are an opencode skill with valid front matter', () {
      final s = SubMacStyle.skills;
      expect(s.keys, containsAll(['submac-output', 'submac-app']));
      for (final e in s.entries) {
        expect(e.value, startsWith('---\nname: ${e.key}\ndescription: "'), reason: e.key);
        expect(RegExp(r'^[a-z0-9-]+$').hasMatch(e.key), isTrue);
      }
      for (final card in ['```table', '```diagram', '```graph', '```visual', '```images', '```summary', '```choices', '```file']) {
        expect(s['submac-output'], contains(card), reason: card);
      }
    });

    test('the app guide skill knows the app, connectors and the shell', () {
      final a = SubMacStyle.skills['submac-app']!;
      expect(a, contains('Team > New bot'));
      expect(a, contains('submac_connect_app'));
      expect(a, contains('git, curl, wget'));
      expect(a, contains('submac_make_document'));
    });

    test('the MCP tool returns the same card reference', () {
      expect(SubMacStyle.outputFormatsTool['function'], isA<Map>());
      expect(SubMacStyle.outputFormats, contains('```diagram'));
    });
  });
}
