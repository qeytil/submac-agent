import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:agent/services/bot_powers.dart';
import 'package:agent/services/bots.dart';
import 'package:agent/services/repo.dart';
import 'package:agent/services/whatsapp.dart';

void main() {
  group('phone numbers', () {
    test('international forms become digits', () {
      expect(WaText.phoneDigits('+252 61 512 3456'), '252615123456');
      expect(WaText.phoneDigits('00252-61-512-3456'), '252615123456');
      expect(WaText.phoneDigits('(+1) 415 555 0100'), '14155550100');
      expect(WaText.phoneDigits('252615123456'), '252615123456');
    });
    test('no country code is refused, never guessed', () {
      expect(WaText.phoneDigits('0615123456'), isNull);
      expect(WaText.phoneDigits('615123456'), isNull);
      expect(WaText.phoneDigits('+12'), isNull);
      expect(WaText.phoneDigits('Ahmed'), isNull);
      expect(WaText.phoneDigits(''), isNull);
    });
    test('number or name', () {
      expect(WaText.looksLikePhone('+252 61 512 3456'), isTrue);
      expect(WaText.looksLikePhone('Ahmed Shop'), isFalse);
      expect(WaText.looksLikePhone('Family 2024'), isFalse);
    });
    test('click-to-chat link encodes the text', () {
      expect(WaText.chatLink('252615123456'), 'https://wa.me/252615123456');
      expect(WaText.chatLink('252615123456', text: 'Salaan & mahadsanid?'),
          'https://wa.me/252615123456?text=Salaan%20%26%20mahadsanid%3F');
    });
  });

  test('which WhatsApp', () {
    expect(WaText.pkgFor('business', WaText.personal), WaText.business);
    expect(WaText.pkgFor('WhatsApp Business', WaText.personal), WaText.business);
    expect(WaText.pkgFor('personal', WaText.business), WaText.personal);
    expect(WaText.pkgFor('', WaText.business), WaText.business);
    expect(WaText.appName(WaText.business), 'WhatsApp Business');
  });

  test('flags spot money, orders, urgency and questions in several languages', () {
    expect(WaText.flags('How much is the blue dress?'), containsAll(['money', 'question']));
    expect(WaText.flags('Imisa qiimuhu yahay?'), contains('money'));
    expect(WaText.flags('كم السعر؟'), containsAll(['money', 'question']));
    expect(WaText.flags('I want to order 2, delivery to Hodan'), contains('order'));
    expect(WaText.flags('Fadlan degdeg i soo wac'), contains('urgent'));
    expect(WaText.flags('ok thanks'), isEmpty);
  });

  test('inbox text lists chats with flags and quick reply', () {
    final now = DateTime(2026, 10, 19, 18, 0);
    final at = DateTime(2026, 10, 19, 17, 42).millisecondsSinceEpoch;
    final t = WaText.inboxText([
      {
        'name': 'Hodan Shop', 'group': false, 'phone': '252615123456', 'unread': 2, 'last': at, 'quickReply': true, 'app': 'WhatsApp Business',
        'msgs': [
          {'f': 'Hodan Shop', 't': 'Salaan', 'at': at, 'me': false},
          {'f': 'Hodan Shop', 't': 'How much is delivery?', 'at': at, 'me': false},
        ],
      },
      {
        'name': 'Family', 'group': true, 'unread': 0, 'last': at - 86400000, 'quickReply': false, 'app': 'WhatsApp',
        'msgs': [
          {'f': 'Amina', 't': 'See you tomorrow', 'at': at - 86400000, 'me': false},
          {'f': 'You', 't': 'Yes', 'at': at - 86400000, 'me': true},
        ],
      },
    ], now: now);
    expect(t, contains('2 chats, 1 with new messages'));
    expect(t, contains('• Hodan Shop (direct, +252615123456, Business, 2 new, 17:42, quick reply ready) [money, order, question]'));
    expect(t, contains('17:42 Hodan Shop: How much is delivery?'));
    expect(t, contains('Family (group, read, yesterday 17:42)'));
    expect(t, contains('Amina: See you tomorrow'));
    expect(t, contains('You: Yes'));
    expect(WaText.inboxText(const [], unreadOnly: true), contains('No unread'));
  });

  test('chat read from the screen', () {
    final t = WaText.chatText({
      'chat': 'Ali', 'status': 'online',
      'messages': [
        {'text': 'Are you coming?', 'time': '17:40', 'from': 'Ali', 'me': false},
        {'text': 'Yes, 10 minutes', 'time': '17:41', 'from': 'You', 'me': true, 'status': 'Read'},
      ],
    });
    expect(t, 'Chat: Ali (online)\n17:40 Ali: Are you coming?\n17:41 You: Yes, 10 minutes (Read)');
  });

  group('limiter', () {
    test('paces messages and caps the hour', () {
      final l = WaLimiter(gap: const Duration(seconds: 6), perHour: 3);
      final t0 = DateTime(2026, 10, 19, 12);
      expect(l.waitBefore(t0), Duration.zero);
      l.mark(t0);
      expect(l.waitBefore(t0.add(const Duration(seconds: 2))), const Duration(seconds: 4));
      expect(l.waitBefore(t0.add(const Duration(seconds: 7))), Duration.zero);
      l.mark(t0.add(const Duration(seconds: 7)));
      l.mark(t0.add(const Duration(seconds: 14)));
      expect(l.hourFull(t0.add(const Duration(seconds: 20))), isTrue);
      expect(l.leftThisHour(t0.add(const Duration(seconds: 20))), 0);
      expect(l.hourFull(t0.add(const Duration(minutes: 61))), isFalse);
    });
    test('bulk cap is 20', () => expect(WaLimiter.maxRecipients, 20));
  });

  group('approval cards', () {
    test('reading needs no card', () {
      expect(WhatsAppTools.approvalFor({'action': 'inbox'}), isNull);
      expect(WhatsAppTools.approvalFor({'action': 'read', 'to': 'Ali'}), isNull);
      expect(WhatsAppTools.approvalFor({'action': 'status'}), isNull);
    });
    test('sends, files and calls ask, and messages can be edited', () {
      final r = WhatsAppTools.approvalFor({'action': 'send', 'to': '+252615123456', 'message': 'Hi'})!;
      expect(r.title, contains('+252615123456'));
      expect(r.confirmLabel, 'Send');
      expect(r.edit?.value, 'Hi');
      final c = WhatsAppTools.approvalFor({'action': 'call', 'to': 'Ali', 'video': true})!;
      expect(c.title, startsWith('Video call Ali'));
      final b = WhatsAppTools.approvalFor({'action': 'send_bulk', 'recipients': ['a', 'b', 'c'], 'message': 'Eid Mubarak'})!;
      expect(b.title, contains('3 people'));
      expect(WhatsAppTools.approvalFor({'action': 'reply', 'to': 'Ali', 'message': 'ok'}), isNotNull);
      expect(WhatsAppTools.approvalFor({'action': 'send_file', 'to': 'Ali', 'path': '/x/invoice.pdf'})!.title, contains('invoice.pdf'));
    });
  });

  test('WhatsApp is a phone plugin a bot can lose', () {
    expect(BotPowers.groupOf('whatsapp'), 'phone');
    expect(BotPowers.allowed({}, 'whatsapp'), isTrue);
    expect(BotPowers.allowed({'phone'}, 'whatsapp'), isFalse);
    expect(BotPowers.allowed({'whatsapp'}, 'whatsapp'), isFalse);
    expect(BotPowers.allowed({'whatsapp'}, 'web_search'), isTrue);
    expect(BotPowers.note({'whatsapp'}), contains('WhatsApp'));
  });

  test('a WhatsApp watch keeps its chat', () {
    final w = BotWatch('w1', 'WhatsApp', 'price', 'Draft a reply', chat: 'Hodan');
    final back = BotWatch.fromJson(w.toJson());
    expect(back.chat, 'Hodan');
    expect(BotWatch.fromJson({'id': 'w2', 'app': 'Gmail', 'kw': '', 'do': 'x'}).chat, '');
  });

  test('the backup never keeps WhatsApp content', () {
    final tool = Repo.forBackup({'id': '1', 'role': 'tool', 'name': 'whatsapp', 'content': 'Hodan: How much is delivery?'}, 'c');
    expect(tool['content'], isNot(contains('Hodan')));
    final call = Repo.forBackup({
      'id': '2', 'role': 'assistant', 'content': '',
      'tool_calls': [
        {'id': 't', 'type': 'function', 'function': {'name': 'whatsapp', 'arguments': jsonEncode({'action': 'send', 'to': '+252615123456', 'message': 'secret'})}},
      ],
    }, 'c');
    final args = ((call['tool_calls'] as List).first as Map)['function']['arguments'] as String;
    expect(args, isNot(contains('secret')));
    expect(args, isNot(contains('252615123456')));
    expect(jsonDecode(args)['action'], 'send');
    // Other tools are untouched.
    final other = Repo.forBackup({'id': '3', 'role': 'tool', 'name': 'web_search', 'content': 'result'}, 'c');
    expect(other['content'], 'result');
  });

  test('the WhatsApp tool stays lean', () {
    expect(jsonEncode(WhatsAppTools.definition).length ~/ 4, lessThan(600));
    expect(WhatsAppTools.hint.hasMatch('reply to Ali on WhatsApp'), isTrue);
    expect(WhatsAppTools.hint.hasMatch('واتساب'), isTrue);
    expect(WhatsAppTools.hint.hasMatch('send an email'), isFalse);
  });
}
