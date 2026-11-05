// Owner bug (2026-11-04, APK 1.13.121): "in bots' private chat, the bots' questions are raw code". A bot's brief asks
// for a ```choices card (BotAsk.rule) and opencode turns reach the chat with no reply check, so a model's slips (a
// ```json fence, the fence opened mid-line, a one-line card, bare JSON, opencode's question-tool shape written as text)
// drew as code. Choices.fixReply turns each into a ```choices card, while streaming and after; real code stays code.
import 'package:agent/app_state.dart';
import 'package:agent/models.dart';
import 'package:agent/services/bots.dart';
import 'package:agent/services/choices.dart';
import 'package:agent/services/opencode.dart';
import 'package:agent/services/team_key.dart';
import 'package:agent/theme.dart';
import 'package:agent/widgets/chat_logic.dart';
import 'package:agent/widgets/markdown_view.dart';
import 'package:agent/widgets/output_cards.dart';
import 'package:agent/widgets/reply_blocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Widget _host(Widget child) => ChangeNotifierProvider<AppState>.value(
      value: AppState(),
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: MediaQuery(
          data: const MediaQueryData(size: Size(400, 860), disableAnimations: true),
          child: Scaffold(body: SingleChildScrollView(child: child)),
        ),
      ),
    );

List<ReplyBlock> _cards(String s) => parseReply(s).where((b) => b.lang != null).toList();

void main() {
  group('bot questions written as raw code become the choices card', () {
    const q = '{"question":"Which report first?","options":["Sales summary","Open orders","Stock plan"]}';
    final shapes = <String, String>{
      'a ```json fence': 'Happy to help.\n```json\n$q\n```',
      'a plain ``` fence': 'Happy to help.\n```\n$q\n```',
      'the fence opened mid-line': 'Which one should I start with? ```choices\n["Sales summary","Open orders"]\n```',
      'a one-line card after words': 'Which one? ```choices ["Sales summary","Open orders"]```',
      'a card whose JSON sits on the fence line': '```choices ["Sales summary","Open orders"]\n```',
      'a card indented under a list item': '1. Pick one:\n\n    ```choices\n    ["Sales summary","Open orders"]\n    ```',
      'bare JSON on one line': 'Happy to help.\n$q',
      'bare JSON over several lines': 'Happy to help.\n{\n  "question": "Which report first?",\n  "options": [\n    "Sales summary",\n    "Open orders"\n  ]\n}',
      "opencode's question-tool shape": '```json\n{"questions":[{"header":"Report","question":"Which report first?","options":'
          '[{"label":"Sales summary","description":"This week"},{"label":"Open orders"}]}]}\n```',
      'the question tool call written as text': '{"name":"question","arguments":{"questions":[{"question":"Which report first?",'
          '"options":[{"label":"Sales summary"},{"label":"Open orders"}]}]}}',
    };
    shapes.forEach((name, reply) {
      test(name, () {
        final cards = _cards(reply);
        expect(cards, hasLength(1), reason: parseReply(reply).map((b) => '${b.lang}: ${b.text}').join(' | '));
        expect(cards.single.lang, 'choices');
        expect(cards.single.complete, isTrue);
        final opts = Choices.parse(cards.single.text.trim());
        expect(opts.take(2), ['Sales summary', 'Open orders']);
        // No JSON and no fence is left in the words around the card.
        for (final b in parseReply(reply).where((b) => b.lang == null)) {
          expect(b.text, isNot(contains('"options"')));
          expect(b.text, isNot(contains('```')));
        }
      });
    });

    test('the words before a mid-line card stay as the question', () {
      final b = parseReply('Which one should I start with? ```choices\n["A","B"]\n```');
      expect(b.first.lang, isNull);
      expect(b.first.text, 'Which one should I start with?');
    });

    test('while it streams, an unclosed question block is the card\'s placeholder, never code', () {
      for (final partial in [
        'Sure.\n```json\n{"question":"Which report',
        'Sure.\n{"question":"Which report first?","options":["Sales',
        'Which one? ```choices\n["Sales summary","Op',
        'Sure.\n```\n{"questions":[{"question":"Which',
      ]) {
        final b = parseReply(partial);
        expect(b.last.lang, 'choices', reason: partial);
        expect(b.last.complete, isFalse, reason: partial);
        expect(b.where((x) => x.lang == null).map((x) => x.text).join(), isNot(contains('{')), reason: partial);
      }
    });

    test('real code and data stay as they are', () {
      for (final s in [
        '```json\n{"name":"Ada","age":3}\n```',
        '```json\n["a","b"]\n```',
        '```dart\nfinal x = {"question": 1};\n```',
        'See [the docs](https://x.y) and [more](https://z).',
        'Plain answer with no question.',
        '```\nls -la\n```',
      ]) {
        expect(Choices.fixReply(s), s, reason: s);
      }
    });

    test("opencode's several questions each get a card's worth of answers", () {
      final qs = Choices.questionsIn('{"questions":[{"question":"City?","options":[{"label":"Paris"},{"label":"Rome"}]},'
          '{"question":"When?","options":[{"label":"May"},{"label":"June"}],"multiple":false}]}');
      expect(qs.map((q) => [q.$1, ...q.$2]).toList(), [
        ['City?', 'Paris', 'Rome'],
        ['When?', 'May', 'June'],
      ]);
      expect(Choices.question('{"questions":[{"question":"City?","options":[]}]}'), 'City?');
    });

    test('the follow-up chips treat a fixed card as a card, not as code to explain', () {
      expect(suggestFollowUps('Happy to help.\n```json\n$q\n```'), isEmpty);
    });

    testWidgets('a bot reply with a ```json question draws a ChoicesCard and no code block', (t) async {
      final m = ChatMessage(id: 'b1', role: 'assistant', content: 'Happy to help.\n```json\n$q\n```');
      await t.pumpWidget(_host(ReplyView(message: m)));
      await t.pump(const Duration(milliseconds: 400));
      final c = t.widget<ChoicesCard>(find.byType(ChoicesCard));
      expect(c.choices, ['Sales summary', 'Open orders', 'Stock plan']);
      expect(c.question, 'Which report first?');
      expect(c.owner, 'b1');
      expect(find.byType(CodeBlock), findsNothing);
      expect(find.textContaining('"options"'), findsNothing);
    });

    testWidgets('a question card opened mid-line draws a ChoicesCard', (t) async {
      final m = ChatMessage(id: 'b2', role: 'assistant', content: 'Which one? ```choices\n["Fri", "Sat"]\n```');
      await t.pumpWidget(_host(ReplyView(message: m)));
      await t.pump(const Duration(milliseconds: 400));
      expect(t.widget<ChoicesCard>(find.byType(ChoicesCard)).choices, ['Fri', 'Sat']);
      expect(find.textContaining('```'), findsNothing);
    });

    testWidgets('the team chat (markdown) draws the same card', (t) async {
      await t.pumpWidget(_host(const MarkdownView('Nova asks: which first? ```choices ["Draft", "Review"]```')));
      await t.pump(const Duration(milliseconds: 400));
      expect(t.widget<ChoicesCard>(find.byType(ChoicesCard)).choices, ['Draft', 'Review']);
    });

    testWidgets("opencode's several questions draw one card each", (t) async {
      final card = buildOutputCard('choices',
          '{"questions":[{"question":"City?","options":[{"label":"Paris"}]},{"question":"When?","options":[{"label":"May"}]}]}');
      await t.pumpWidget(_host(card!));
      expect(find.byType(ChoicesCard), findsNWidgets(2));
    });
  });

  group("opencode's question tool in a bot's chat", () {
    test("a bot session's question shows in the bot's own chat; a team session's is skipped", () async {
      final shown = <String>[];
      final answered = <List<List<String>>?>[];
      final asks = OpenCodeAsks(
        ask: (conv, title, prompt, options) async {
          // As the app does: team work has no card to ask on (skipped), a chat gets the card.
          if (conv.isEmpty || TeamKey.isKey(conv)) return null;
          shown.add('$conv|$title|${options.join(',')}');
          return options.first;
        },
        permit: (id, r) async {},
        answer: (id, a) async => answered.add(a),
        convOf: (s) => {'ses_bot': 'bot-conv-1', 'ses_team': TeamKey.of('team1', 'nova')}[s],
      );
      Map<String, dynamic> ev(String id, String ses) => {
            'type': 'question.asked',
            'properties': {
              'id': id,
              'sessionID': ses,
              'questions': [
                {
                  'question': 'Which report first?',
                  'options': [
                    {'label': 'Sales summary'},
                    {'label': 'Open orders'}
                  ]
                }
              ],
            },
          };
      await asks.handle(ev('q1', 'ses_bot'));
      expect(shown, ['bot-conv-1|Which report first?|Sales summary,Open orders']);
      expect(answered.last, [
        ['Sales summary']
      ]);
      await asks.handle(ev('q2', 'ses_team'));
      expect(shown, hasLength(1));
      expect(answered.last, isNull);
    });

    test("the private brief points the bot at the question tool; the team brief does not", () {
      final b = Bot(id: 'qb1', name: 'Quill', role: 'Analyst', persona: '');
      expect(Bots.I.opencodeBriefOf(b), contains('call your question tool'));
      expect(Bots.I.opencodeBriefOf(b, team: true), isNot(contains('call your question tool')));
    });
  });
}
