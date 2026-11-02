import 'package:agent/services/submac_style.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SubMac layer on opencode', () {
    test('names the agent SubMac and keeps opencode out of its mouth', () {
      final t = SubMacStyle.layer();
      expect(t, contains('Your name is SubMac'));
      expect(t, contains('never mention opencode'));
      expect(t, contains('stays exactly as it is'));
    });

    test('teaches the chat cards for visuals', () {
      final t = SubMacStyle.layer();
      for (final card in ['```table', '```diagram', '```graph', '```visual', '```images', '```summary', '```choices', '```file']) {
        expect(t, contains(card), reason: card);
      }
      expect(t, contains('Never a markdown'));
    });

    test('knows the app, its connectors and the shell tools', () {
      final none = SubMacStyle.layer();
      expect(none, contains('Team > New bot'));
      expect(none, contains('None connected yet'));
      expect(none, contains('submac_connect_app'));
      expect(none, contains('git, curl, wget'));
      final some = SubMacStyle.layer(apps: ['Notion', 'GitHub']);
      expect(some, contains('Connected: Notion, GitHub'));
      expect(some, contains('submac_apps_list_tools'));
    });

    test('language, profile and memory ride along only when set', () {
      final plain = SubMacStyle.layer();
      expect(plain, contains('language of the user\'s most recent message'));
      expect(plain, isNot(contains('# The user')));
      final set = SubMacStyle.layer(language: 'Somali', aboutYou: 'Lives in Hargeisa', howToRespond: 'Short', memory: '# Memory\n- likes tea');
      expect(set, contains('Always reply in Somali'));
      expect(set, contains('# The user\nLives in Hargeisa'));
      expect(set, contains('# How the user wants replies (always follow)\nShort'));
      expect(set, contains('- likes tea'));
    });

    test('the image tool is offered only with an image model', () {
      expect(SubMacStyle.layer(), isNot(contains('submac_generate_image')));
      expect(SubMacStyle.layer(imageModel: true), contains('submac_generate_image'));
    });
  });
}
