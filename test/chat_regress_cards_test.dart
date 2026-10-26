// PR-7 fix/cards-render: regression tests for the chat cards and rendering bugs (CB-5, 6, 7, 8, 9, 11a, 11b, 12, 27, 28,
// 43). The CB-5..CB-12 groups are the round-1 bug-hunt probes (test/zz_chat_bughunt_test.dart, branch chat-bughunt),
// moved here with their assertions unchanged; the CB-5 probe now passes the card's own message id (owner), which is how
// the fix tells the cards apart. The rest are new tests named in the fix plan.
import 'dart:async';
import 'dart:convert';

import 'package:agent/agent/reply_schema.dart';
import 'package:agent/app_state.dart';
import 'package:agent/models.dart';
import 'package:agent/services/calm.dart';
import 'package:agent/services/choices.dart';
import 'package:agent/services/error_copy.dart';
import 'package:agent/services/llm_client.dart';
import 'package:agent/services/reply_text.dart';
import 'package:agent/theme.dart';
import 'package:agent/widgets/chat_extras.dart' show StreamingMarkdown;
import 'package:agent/widgets/chat/message_actions.dart';
import 'package:agent/widgets/hark_cards.dart' show looseJson, repairJson;
import 'package:agent/widgets/message_view.dart';
import 'package:agent/widgets/output_cards.dart';
import 'package:agent/widgets/reply_blocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Widget _host(Widget child, {TextDirection dir = TextDirection.ltr, bool still = true}) => ChangeNotifierProvider<AppState>.value(
      value: AppState(),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        home: MediaQuery(
          data: MediaQueryData(size: const Size(400, 860), disableAnimations: still),
          child: Directionality(textDirection: dir, child: Scaffold(body: SingleChildScrollView(child: child))),
        ),
      ),
    );

/// A voice that records what it was asked to say (CB-28).
class _FakeSpeaker implements Speaker {
  final said = <(String, String?)>[];
  final installed = <String>{'en', 'ar'};
  String? lang;
  int stops = 0;
  Completer<void>? hold;

  @override
  Future<bool> setLanguage(String l) async {
    if (!installed.contains(l)) return false;
    lang = l;
    return true;
  }

  bool speaking = false;

  @override
  Future<void> speak(String text) async {
    said.add((text, lang));
    final h = hold;
    if (h == null) return;
    speaking = true;
    await h.future;
    speaking = false;
  }

  /// Like the phone's voice: stopping ends the piece being read.
  @override
  Future<void> stop() async {
    stops++;
    final h = hold;
    if (!speaking || h == null) return;
    hold = null;
    if (!h.isCompleted) h.complete();
  }
}

void main() {
  // ================================================================== moved probes (round 1)

  group('CB-5 a newer identical choices card revives an answered one', () {
    test('the first card stays answered after the same options are offered again', () {
      const card = '```choices\n["Yes, book it", "Not now"]\n```';
      final msgs = [
        ChatMessage(id: 'a1', role: 'assistant', content: 'Book the 9 am flight?\n$card'),
        ChatMessage(id: 'u1', role: 'user', content: 'Yes, book it'),
        ChatMessage(id: 'a2', role: 'assistant', content: 'Booked. Also book the hotel?\n$card'),
      ];
      // statusIn could not tell which card it is drawing: both got the newest card's status. PR-7: the card passes the id
      // of the message it sits in (owner), as ReplyView now does through buildOutputCard.
      final (live, picked) = ChoicesCard.statusIn(msgs, const ['Yes, book it', 'Not now'], busy: false, owner: 'a1');
      // The first card must stay answered ("Yes, book it" ticked, not tappable). It comes back live and unticked,
      // and a tap on it sends "Yes, book it" again to the new question.
      expect((live, picked), (false, 'Yes, book it'), reason: 'old card is live again and lost its tick');
    }, skip: false);
  });

  group('CB-6 a code fence with an unusual language word swallows the rest of the reply', () {
    test('```c# … ``` followed by a table card still gives the table card', () {
      const reply = 'Here is the code:\n```c#\nConsole.WriteLine("hi");\n```\n\nPrices:\n```table\n{"columns":["Item","Price"],"rows":[["Tea","\$1"]]}\n```';
      final blocks = parseReply(reply);
      expect(blocks.where((b) => b.lang == 'table'), isNotEmpty,
          reason: 'the closing ``` of the c# block is read as an OPENING fence, so the table card becomes code text');
    });
  });

  group('CB-7 a card whose JSON is broken disappears without a trace', () {
    testWidgets('a finished reply with a malformed table still shows its content', (t) async {
      final m = ChatMessage(id: 'x', role: 'assistant', content: 'Your budget:\n```table\n{"columns":["Item","Cost"],"rows":[["Rent","\$300"],["Food","\$120"]\n```');
      await t.pumpWidget(_host(ReplyView(message: m)));
      await t.pump(const Duration(milliseconds: 500));
      expect(find.textContaining('Rent'), findsWidgets, reason: 'reply_blocks.dart draws SizedBox.shrink for a broken card');
    });
  });

  group('CB-8 Copy drops whole cards', () {
    testWidgets('Copy keeps the items of a ```list / ```links card', (t) async {
      String? copied;
      t.view.physicalSize = const Size(800, 3000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (c) async {
        if (c.method == 'Clipboard.setData') {
          copied = (c.arguments as Map)['text'] as String?;
        }
        return null;
      });
      final m = ChatMessage(
          id: 'c1',
          role: 'assistant',
          content: 'Your packing list:\n```list\n{"title":"Packing","items":["Passport","Charger","Sunscreen"]}\n```\n'
              'Useful links:\n```links\n[{"title":"Visa portal","url":"https://evisa.go.ke"}]\n```');
      await t.pumpWidget(_host(AssistantMessageView(message: m, toolResults: const {}, showActions: true, isLast: true), still: false));
      await t.pump(const Duration(milliseconds: 600));
      await t.tap(find.textContaining('Your packing list'));
      await t.pump(const Duration(milliseconds: 600));
      await t.ensureVisible(find.descendant(of: find.byType(MessageActionRow), matching: find.byTooltip('Copy')).first);
      await t.pump(const Duration(milliseconds: 300));
      await t.tap(find.descendant(of: find.byType(MessageActionRow), matching: find.byTooltip('Copy')).first);
      await t.pump(const Duration(milliseconds: 600));
      expect(copied, isNotNull);
      expect(copied, contains('Passport'), reason: 'message_view.dart _plain() replaces list/links/plan/sections/math… cards with ""');
      expect(copied, contains('evisa.go.ke'));
    });
  });

  group('CB-9 one text direction for a whole reply', () {
    test('a Somali reply that opens with an Arabic greeting is still left-to-right', () {
      expect(textDirOf('السلام عليكم! Waan ku faraxsanahay inaan ku caawiyo. Maxaan kuu qabtaa maanta?'), TextDirection.ltr);
    });
    test('an Arabic reply that opens with a brand name is still right-to-left', () {
      expect(textDirOf('iPhone 16 هو أحدث هاتف من شركة آبل، ويأتي بكاميرا محسنة وبطارية أطول.'), TextDirection.rtl);
    });
  });

  group('CB-11a a thousands comma splits a choice', () {
    test('an answer with a thousands comma stays one answer', () {
      expect(Choices.parse('Under \$1,000'), ['Under \$1,000']);
    });
  });

  group('CB-11b a | inside code cuts table cells', () {
    test('a pipe inside inline code does not cut the table row (no cell is lost)', () {
      const md = '| Command | Meaning |\n|---|---|\n| `a \\| b` | pipe |';
      final out = ReplySchema.repair(md);
      final j = jsonDecode(RegExp(r'```table\n(.*)\n```').firstMatch(out)!.group(1)!) as Map;
      expect((j['rows'] as List).first, contains('pipe'), reason: 'the row is split on every | and the last cell is dropped');
    });
  });

  group('CB-12 reduced motion: a reply that changes size throws in layout', () {
    testWidgets('a streaming reply growing under "Remove animations" lays out without errors', (t) async {
      final m = ChatMessage(id: 's', role: 'assistant', content: 'Short', streaming: true);
      await t.pumpWidget(_host(ReplyView(key: const ValueKey('r'), message: m)));
      await t.pump(const Duration(milliseconds: 200));
      m.content = 'Short answer, now much longer.\n\n${'More words arrive here. ' * 40}';
      m.streaming = false;
      await t.pumpWidget(_host(ReplyView(key: const ValueKey('r'), message: m)));
      await t.pump(const Duration(milliseconds: 200));
      // reply_blocks.dart wraps each block in AnimatedSize(duration: SubMotion.of(...)) = Duration.zero when animations
      // are off; a zero-length AnimatedSize re-dirties itself during layout (the repo's own rule: use SubSize).
      expect(t.takeException(), isNull);
    });
  });

  // ================================================================== new tests (fix plan, PR-7)

  group('CB-5 each choices card keeps its own status', () {
    final card = '```choices\n["Yes, book it", "Not now"]\n```';
    final msgs = [
      ChatMessage(id: 'a1', role: 'assistant', content: 'Book the 9 am flight?\n$card'),
      ChatMessage(id: 'u1', role: 'user', content: 'Yes, book it'),
      ChatMessage(id: 'a2', role: 'assistant', content: 'Booked. Also book the hotel?\n$card'),
    ];
    test('the newest card with the same options is live while nothing runs', () {
      expect(ChoicesCard.statusIn(msgs, const ['Yes, book it', 'Not now'], busy: false, owner: 'a2'), (true, null));
      expect(ChoicesCard.statusIn(msgs, const ['Yes, book it', 'Not now'], busy: true, owner: 'a2'), (false, null));
    });
    test('a card whose message is not in the open chat can be answered while idle', () {
      expect(ChoicesCard.statusIn(msgs, const ['Yes, book it', 'Not now'], busy: false, owner: 'elsewhere'), (true, null));
    });
    testWidgets('ReplyView hands its message id to the choices card', (t) async {
      final m = ChatMessage(id: 'a9', role: 'assistant', content: 'Pick one:\n```choices\n["Fri", "Sat", "Sun"]\n```');
      await t.pumpWidget(_host(ReplyView(message: m)));
      await t.pump(const Duration(milliseconds: 300));
      final c = t.widget<ChoicesCard>(find.byType(ChoicesCard));
      expect(c.owner, 'a9');
    });
  });

  group('CB-6 fence hardening', () {
    test('a fence with an info string after the language still opens and closes cleanly', () {
      const reply = '```python title="x.py"\nprint(1)\n```\n\n```list\n{"items":["A","B"]}\n```';
      final blocks = parseReply(reply);
      expect(blocks.map((b) => b.lang), [null, 'list']);
      expect(blocks.first.text, contains('print(1)'));
    });
  });

  group('CB-7 tolerant card JSON', () {
    test('trailing commas and missing closers are repaired', () {
      expect(looseJson('{"items":["A","B",],}'), {'items': ['A', 'B']});
      expect(looseJson('{"columns":["Item","Cost"],"rows":[["Rent","300"],["Food","120"]'), {
        'columns': ['Item', 'Cost'],
        'rows': [
          ['Rent', '300'],
          ['Food', '120']
        ]
      });
      expect(looseJson('{"title":"Plan","steps":["Book","Pa'), {'title': 'Plan', 'steps': ['Book', 'Pa']});
      expect(looseJson('{"title":"Plan","steps":'), {'title': 'Plan'});
      expect(repairJson('no json here'), isNull);
    });
    test('a body that cannot be repaired still gives its words as plain lines', () {
      expect(brokenCardText('{"columns":["Item","Cost"] "rows":[["Rent","\$300"]]]]'), contains('Rent'));
      expect(brokenCardText('{"title": "Trip"\n"items": ["Passport" "Charger"]'), 'Trip\nPassport | Charger');
    });
    testWidgets('an unreadable card shows its words, not nothing and not raw JSON', (t) async {
      final m = ChatMessage(id: 'y', role: 'assistant', content: 'Here:\n```list\n{"title": "Trip" "items": [["Passport" "Charger"]]}}}\n```');
      await t.pumpWidget(_host(ReplyView(message: m)));
      await t.pump(const Duration(milliseconds: 500));
      expect(find.textContaining('Passport'), findsWidgets);
      expect(find.textContaining('"items"'), findsNothing);
    });
  });

  group('CB-8 every card has a text form for Copy, Share and Read aloud', () {
    test('list, plan and sections one item per line; links title and url; math TeX; file and page the name', () {
      expect(cardPlainText('plan', '{"title":"Move","steps":["Pack","Ship"]}'), 'Move\nPack\nShip');
      expect(cardPlainText('list', '["Passport","Charger"]'), 'Passport\nCharger');
      expect(cardPlainText('sections', '{"sections":[{"title":"Visa","body":"Apply online"},{"title":"Money","items":["Cash","Card"]}]}'),
          'Visa\nApply online\nMoney\nCash\nCard');
      expect(cardPlainText('links', '[{"title":"Visa portal","url":"https://evisa.go.ke"}]'), 'Visa portal — https://evisa.go.ke');
      expect(cardPlainText('math', r'E = mc^2'), r'E = mc^2');
      expect(cardPlainText('file', 'workspace/out/report.pdf'), 'report.pdf');
      expect(cardPlainText('page', 'site/index.html'), 'index.html');
      expect(cardPlainText('page', '<html><head><title>My page</title></head></html>'), 'My page');
      expect(cardPlainText('choices', '["Yes","No"]'), '');
    });
    test('the copied reply keeps prose, code and the card words', () {
      const reply = 'Steps:\n```plan\n{"title":"Move","steps":["Pack","Ship"]}\n```\nCode:\n```dart\nprint(1);\n```\n```choices\n["Yes","No"]\n```';
      final p = replyPlain(reply);
      expect(p, contains('Pack\nShip'));
      expect(p, contains('```dart\nprint(1);\n```'));
      expect(p, isNot(contains('"Yes"')));
    });
  });

  group('CB-9 direction per paragraph', () {
    test('the majority of strong letters decides; ties go to the first letter', () {
      expect(majorityDir('Hello مرحبا'), TextDirection.ltr);
      expect(majorityDir('مرحبا Hello'), TextDirection.rtl);
      expect(majorityDir('123 !'), TextDirection.ltr);
    });
    testWidgets('a reply mixing a Somali and an Arabic paragraph sets each paragraph its own way', (t) async {
      const text = 'Waan ku faraxsanahay inaan ku caawiyo maanta.\n\nهذه فقرة باللغة العربية كاملة.';
      await t.pumpWidget(_host(const StreamingMarkdown(text)));
      await t.pump(const Duration(milliseconds: 100));
      final dirs = t
          .widgetList<Directionality>(find.descendant(of: find.byType(StreamingMarkdown), matching: find.byType(Directionality)))
          .map((d) => d.textDirection)
          .toList();
      expect(dirs, containsAllInOrder([TextDirection.ltr, TextDirection.rtl]));
    });
  });

  group('CB-11b extra cells', () {
    test('an escaped pipe stays in its cell and extra cells join the last one', () {
      expect(ReplySchema.tableCells(r' a \| b | c '), ['a | b', 'c']);
      expect(ReplySchema.tableCells(' `x|y` | z '), ['`x|y`', 'z']);
      final out = ReplySchema.repair('| A | B |\n|---|---|\n| 1 | 2 | 3 |');
      final j = jsonDecode(RegExp(r'```table\n(.*)\n```').firstMatch(out)!.group(1)!) as Map;
      expect((j['rows'] as List).first, ['1', '2 | 3']);
    });
    test('a thousands comma inside a list of answers stays whole; real separators still split', () {
      expect(Choices.parse('Under \$1,000, \$1,000-2,000, or more'), ['Under \$1,000', '\$1,000-2,000', 'more']);
      expect(Choices.parse('Red, Blue or Green'), ['Red', 'Blue', 'Green']);
    });
  });

  group('CB-27 the error card speaks the app language', () {
    test('a failed run stores its code and status; Details show the raw text without tag or class name', () {
      final s = ErrorCopy.store(LlmException('The model is busy right now', status: 503, code: 'busy'));
      expect(ErrorCopy.codeOf(s), ('busy', 503));
      expect(ErrorCopy.detail(s), 'The model is busy right now');
      expect(ErrorCopy.store(Exception('GenkitException: Tool x not found (Status: NOT_FOUND)')), isNot(contains('Exception')));
      expect(ErrorCopy.detail('GenkitException: boom'), 'boom');
    });
    const cases = {
      ('busy', 503): 'busy',
      ('server', 500): 'busy',
      ('limit_daily', 429): 'limit',
      ('limit_total', 429): 'limit',
      ('no_plan', 429): 'limit',
      ('blocked', 403): 'blocked',
      ('auth', 401): 'auth',
      ('paused', 0): 'paused',
      ('too_long', 413): 'too_long',
      ('', 401): 'auth',
      ('', 429): 'busy',
      ('', 502): 'busy',
      ('', 413): 'too_long',
    };
    for (final lang in ['en', 'so', 'ar']) {
      test('each code maps to its own words in $lang', () {
        cases.forEach((k, kind) {
          final stored = ErrorCopy.store(LlmException('raw server sentence', status: k.$2, code: k.$1));
          final e = ErrorCopy.explain(stored, lang: lang);
          expect(e.kind, kind, reason: '$k');
          expect((e.title, e.body), ErrorCopy.wordsFor(kind, lang), reason: '$k $lang');
          expect(e.title, isNot(contains('raw server')));
          expect(e.body, isNot(contains('raw server')));
          expect(e.raw, 'raw server sentence');
        });
      });
    }
    test('every kind has Somali and Arabic words, different from the English', () {
      for (final k in ErrorCopy.kinds) {
        for (final l in ['so', 'ar']) {
          final w = ErrorCopy.wordsFor(k, l);
          expect(w, isNotNull, reason: '$k $l');
          expect(w!.$1, isNot(ErrorCopy.wordsFor(k, 'en')!.$1), reason: '$k $l');
        }
      }
      expect(ErrorCopy.button('Details', lang: 'so'), 'Faahfaahin');
      expect(ErrorCopy.button('Try again', lang: 'ar'), 'حاول مرة أخرى');
    });
    test('an old error with no code still finds its kind from the text', () {
      expect(ErrorCopy.explain('SocketException: Failed host lookup', lang: 'ar').kind, 'offline');
      expect(Calm.explain('timed out').kind, 'timeout');
    });
  });

  group('CB-28 read aloud reads everything, in the right language', () {
    late _FakeSpeaker voice;
    setUp(() {
      voice = _FakeSpeaker();
      ReadAloud.speaker = voice;
    });
    test('a long reply is read in pieces of at most 3,900 characters, one after another, nothing cut', () async {
      final para = '${'This is a sentence about the trip. ' * 60}\n\n';
      final text = para * 4; // about 8,400 characters
      await ReadAloud.toggle('m1', text);
      expect(voice.said.length, greaterThan(1));
      expect(voice.said.every((s) => s.$1.length <= 3900), isTrue);
      expect(voice.said.map((s) => s.$1).join(' ').replaceAll(RegExp(r'\s+'), ' ').trim(), text.replaceAll(RegExp(r'\s+'), ' ').trim());
      expect(ReadAloud.reading.value, isNull);
    });
    test('each paragraph is read in its own language; a missing voice keeps the current one', () async {
      await ReadAloud.toggle('m2', 'Hello, here is your answer in English.\n\nهذه هي الإجابة باللغة العربية الكاملة.');
      expect(voice.said.map((s) => s.$2), ['en', 'ar']);
      voice.said.clear();
      await ReadAloud.toggle('m3', 'Waan ku faraxsanahay inaan ku caawiyo maanta, waa run.');
      expect(voice.said.single.$2, 'ar', reason: 'no Somali voice installed: the current voice reads it');
      expect(speechLang('Waan ku faraxsanahay inaan ku caawiyo maanta, waa run.'), 'so');
    });
    test('Stop ends the reading before the next piece', () async {
      voice.hold = Completer<void>();
      final text = '${'One more sentence to read. ' * 200}\n\n${'Another paragraph here. ' * 200}';
      final run = ReadAloud.toggle('m4', text);
      await Future<void>.delayed(Duration.zero);
      expect(ReadAloud.isReading('m4'), isTrue);
      await ReadAloud.toggle('m4', text); // tap again = stop
      await run;
      expect(voice.said.length, 1);
      expect(ReadAloud.reading.value, isNull);
    });
  });

  group('CB-43 glyphs the font does not have', () {
    test('U+2010/2011 become "-" and U+202F a space', () {
      expect(cleanGlyphs('e\u2011mail at 10\u202Fam, well\u2010known'), 'e-mail at 10 am, well-known');
      expect(cleanGlyphs('plain'), 'plain');
      expect(replyPlain('Check\u2011in at 3\u202Fpm'), 'Check-in at 3 pm');
    });
    testWidgets('a reply with them renders without the missing glyphs', (t) async {
      final m = ChatMessage(id: 'g', role: 'assistant', content: 'Check\u2011in at 3\u202Fpm');
      await t.pumpWidget(_host(ReplyView(message: m)));
      await t.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('Check-in at 3 pm', findRichText: true), findsWidgets);
    });
  });
}
