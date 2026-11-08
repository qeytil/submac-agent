// One person's event inbox (owner 2026-11-08): events about the world wait in that person's own queue and become ONE
// wake with one digest, deduped, so a burst is one turn and never reaches another person. Pure logic.
//
// Run: flutter test test/bot_inbox_test.dart
// ignore_for_file: depend_on_referenced_packages
import 'package:agent/services/bot_inbox.dart';
import 'package:agent/services/bots.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  BotEvent ev(String key,
          {String title = 'a notification from Gmail', String detail = '"x"', String instruction = '', DateTime? at}) =>
      BotEvent(key: key, source: 'notification', title: title, detail: detail, instruction: instruction, at: at);

  group('inbox', () {
    test('dedupes the same event and keeps the new ones', () {
      final box = BotInbox('b1');
      expect(box.add(ev('k1')), isTrue);
      expect(box.add(ev('k1')), isFalse);
      expect(box.add(ev('k2')), isTrue);
      expect(box.length, 2);
    });

    test('take empties it, and the bound drops the oldest', () {
      final box = BotInbox('b1');
      for (var i = 0; i < BotInbox.max + 5; i++) {
        box.add(ev('k$i'));
      }
      expect(box.length, BotInbox.max);
      expect(box.events.last.key, 'k${BotInbox.max + 4}');
      final taken = box.take();
      expect(taken, hasLength(BotInbox.max));
      expect(box.isEmpty, isTrue);
    });

    test('the digest names what arrived and what the person asked for, once', () {
      final box = BotInbox('b1');
      box.add(ev('k1',
          title: 'a new WhatsApp message from Ali',
          detail: '"invoice?"',
          instruction: 'Draft a reply',
          at: DateTime(2026, 11, 8, 10, 4)));
      box.add(ev('k2',
          title: 'a notification from Gmail',
          detail: '"Invoice from Acme"',
          instruction: 'Draft a reply',
          at: DateTime(2026, 11, 8, 10, 5)));
      final d = BotInbox.digest(box.take());
      expect(d, contains('10:04 a new WhatsApp message from Ali: "invoice?"'));
      expect(d, contains('10:05 a notification from Gmail: "Invoice from Acme"'));
      expect('What you asked'.allMatches(d).length, 1, reason: 'the same instruction is listed once');
      expect(d, contains('Draft a reply'));
    });
  });

  group('notification routing', () {
    test('a watched notification goes to the person\'s inbox, not an immediate wake', () async {
      final b = Bot(id: 'in1', name: 'Nova', role: '', persona: '')
        ..active = true
        ..watches.add(BotWatch('w1', 'Gmail', 'invoice', 'Draft a reply'));
      Bots.I.bots.add(b);
      final got = <BotEvent>[];
      Bots.I.onEvent = (bot, e) async => got.add(e);
      try {
        await Bots.I.notificationEvent({'bot': 'in1', 'id': 'w1', 'app': 'Gmail', 'title': 'Invoice from Acme', 'text': 'Due today'});
        expect(got, hasLength(1));
        expect(got.single.source, 'notification');
        expect(got.single.title, 'a notification from Gmail');
        expect(got.single.instruction, 'Draft a reply');
        expect(got.single.detail, contains('Invoice from Acme'));
      } finally {
        Bots.I.onEvent = null;
        Bots.I.bots.removeWhere((x) => x.id == 'in1');
      }
    });
  });
}