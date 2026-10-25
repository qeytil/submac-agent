import 'package:flutter_test/flutter_test.dart';

import 'package:agent/services/truth.dart';

Evidence ok(String tool) => Evidence(tool: tool, ok: true, summary: 'ok');
Evidence bad(String tool) => Evidence(tool: tool, ok: false, summary: 'Error: failed');

void main() {
  group('Truth.unproven', () {
    test('a claim backed by a successful tool is not flagged', () {
      expect(Truth.unproven('Sent it to Amina.', [ok('whatsapp_send')]), isNull);
      expect(Truth.unproven('I saved the file.', [ok('write_file')]), isNull);
      expect(Truth.unproven('Booked it for 9am.', [ok('calendar_create')]), isNull);
    });

    test('a claim with no tool at all is flagged', () {
      final r = Truth.unproven('Done - I sent the message to Amina.', const []);
      expect(r, isNotNull);
      expect(r!.toLowerCase(), contains('sent'));
    });

    test('a claim backed only by a failed tool is flagged', () {
      expect(Truth.unproven('I sent the email.', [bad('email_send')]), isNotNull);
    });

    test('a claim backed by an unrelated tool is flagged', () {
      expect(Truth.unproven('I deleted the photos.', [ok('read_file')]), isNotNull);
    });

    test('plain explanation is never flagged', () {
      expect(
          Truth.unproven('To send a message, open WhatsApp and tap the send button.', const []),
          isNull);
      expect(Truth.unproven('Here is how gravity works.', const []), isNull);
    });

    test('a negated claim is not flagged', () {
      expect(Truth.unproven("I couldn't send the message because the app was offline.", const []),
          isNull);
      expect(Truth.unproven('I have not sent it yet.', const []), isNull);
      expect(Truth.unproven('The file was not saved.', const []), isNull);
    });

    test('claims inside code blocks are ignored', () {
      expect(Truth.unproven('```\nmessage sent\n```', const []), isNull);
    });

    test('only the unproven claim is reported', () {
      final r = Truth.unproven('I saved the file and sent the email.', [ok('write_file')]);
      expect(r, isNotNull);
      final text = r!;
      expect(text.toLowerCase(), contains('sent'));
      expect(text.toLowerCase(), isNot(contains('saved')));
    });

    test('the same reason is never repeated', () {
      final r = Truth.unproven('I sent it. Sent it already.', const []);
      expect(r, isNotNull);
      expect('sent'.allMatches(r!.toLowerCase()).length, 1);
    });

    test('empty reply is not flagged', () {
      expect(Truth.unproven('   ', const []), isNull);
    });
  });

  group('PromptContract', () {
    test('picks up count, language and a do-not rule', () {
      final c = PromptContract.extract('Write 3 bullets in Somali. Do not use emojis.');
      expect(c, contains('exactly 3 bullets'));
      expect(c, contains('reply in Somali'));
      expect(c.any((x) => x.startsWith('do not')), isTrue);
    });

    test('picks up an app and a format', () {
      final c = PromptContract.extract('Use WhatsApp to send it as a table');
      expect(c, contains('use WhatsApp'));
      expect(c, contains('format as table'));
    });

    test('picks up a word limit', () {
      final c = PromptContract.extract('Explain it under 100 words');
      expect(c, contains('keep it under 100 words'));
    });

    test('is empty for plain chat', () {
      expect(PromptContract.extract('what is the capital of France'), isEmpty);
      expect(PromptContract.extract('   '), isEmpty);
    });

    test('block is empty without requirements', () {
      expect(PromptContract.block(const []), isEmpty);
    });

    test('block lists every requirement', () {
      final b = PromptContract.block(const ['use WhatsApp', 'exactly 3 bullets']);
      expect(b, contains('# The user'));
      expect(b, contains('- use WhatsApp'));
      expect(b, contains('- exactly 3 bullets'));
    });
  });
}
