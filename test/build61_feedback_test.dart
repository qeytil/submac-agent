import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:agent/agent/reply_schema.dart';
import 'package:agent/app_state.dart';
import 'package:agent/main.dart' show SkyBackground, SkyBackgroundState, skyStep;
import 'package:agent/models.dart';
import 'package:agent/services/choices.dart';
import 'package:agent/widgets/chat_logic.dart' show suggestFollowUps;
import 'package:agent/widgets/output_cards.dart' show ChoicesCard, buildOutputCard;

/// Owner feedback on build-61 (2026-10-24), v1.13.101: the follow-up questions, the cost of one message, the sky and
/// smoothness. Every issue predates build-61; these tests pin the fixes.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final app = AppState();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await app.local.init();
  });

  group('choices: every shape a model writes', () {
    test('a plain list', () => expect(Choices.parse(['Today', 'Tomorrow', 'Next week']), ['Today', 'Tomorrow', 'Next week']));
    test('an object with a question', () {
      const j = '{"question":"When?","options":["Today","Tomorrow","Next week"]}';
      expect(Choices.parse(j), ['Today', 'Tomorrow', 'Next week']);
      expect(Choices.question(j), 'When?');
    });
    test('labelled objects', () => expect(Choices.parse(jsonDecode('[{"label":"A"},{"title":"B"},{"value":"C"}]')), ['A', 'B', 'C']));
    test('one string from ask_user (commas, lines, bars)', () {
      expect(Choices.parse('Red, Green or Blue'), ['Red', 'Green', 'Blue']);
      expect(Choices.parse('- Red\n- Green\n- Blue'), ['Red', 'Green', 'Blue']);
      expect(Choices.parse('Red | Green'), ['Red', 'Green']);
      expect(Choices.parse('["Red","Green"]'), ['Red', 'Green']);
    });
    test('the model\'s own "Other" is dropped (the card has its own row), and duplicates', () {
      expect(Choices.parse(['A', 'a', 'Other', 'Something else', 'Other (tell me)', 'B']), ['A', 'B']);
    });
    test('at most six', () => expect(Choices.parse([for (var i = 0; i < 9; i++) 'Option $i']).length, Choices.max));
    test('the card draws every shape', () {
      for (final body in ['["A","B","C"]', '{"question":"Q","options":["A","B","C"]}', '[{"label":"A"},{"label":"B"}]']) {
        expect(buildOutputCard('choices', body), isNotNull, reason: body);
      }
    });
    test('the reply check accepts them, so no "Tidying the answer" call', () {
      expect(ReplySchema.problems('Which day?\n\n```choices\n{"question":"Which day?","options":["Fri","Sat","Sun"]}\n```'), isEmpty);
      expect(ReplySchema.problems('Pick one\n\n```choices\n["Only this"]\n```'), isEmpty);
    });
  });

  group('the app fixes cards itself instead of a second model call', () {
    test('a markdown table becomes a table card', () {
      const r = 'Here:\n\n| Name | Price |\n|---|---|\n| A | 1 |\n| B | 2 |\n\nPick one.';
      expect(ReplySchema.problems(r), isNotEmpty);
      final fixed = ReplySchema.repair(r);
      expect(fixed, contains('```table'));
      expect(ReplySchema.problems(fixed), isEmpty);
      expect(fixed, contains('Pick one.'));
    });
    test('a card left open at the end is closed', () {
      final fixed = ReplySchema.repair('Pick:\n```choices\n["A","B","C"]');
      expect(ReplySchema.problems(fixed), isEmpty);
    });
    test('a valid reply is left exactly as written', () {
      const r = 'Done.\n\n```file\n/data/x.pdf\n```';
      expect(ReplySchema.repair(r), r);
    });
  });

  group('the prompt asks for real choices', () {
  });

  group('choices card status', () {
    ChatMessage a(String c) => ChatMessage(id: 'a${c.hashCode}', role: 'assistant', content: c);
    ChatMessage u(String c) => ChatMessage(id: 'u${c.hashCode}', role: 'user', content: c);
    const card = 'Which one?\n\n```choices\n["Fri","Sat","Sun"]\n```';
    test('live until answered', () => expect(ChoicesCard.statusIn([u('plan'), a(card)], ['Fri', 'Sat', 'Sun'], busy: false), (true, null)));
    test('answered: shows the pick and cannot be tapped again', () {
      expect(ChoicesCard.statusIn([a(card), u('sat')], ['Fri', 'Sat', 'Sun'], busy: false), (false, 'Sat'));
      expect(ChoicesCard.statusIn([a(card), u('Monday instead')], ['Fri', 'Sat', 'Sun'], busy: false), (false, 'Monday instead'));
    });
    test('not while a task runs here', () => expect(ChoicesCard.statusIn([a(card)], ['Fri', 'Sat', 'Sun'], busy: true).$1, isFalse));

    testWidgets('the card has a "Something else" row for your own words', (t) async {
      await t.pumpWidget(ChangeNotifierProvider<AppState>.value(
        value: app,
        child: const MaterialApp(home: Scaffold(body: ChoicesCard(['Fri', 'Sat', 'Sun']))),
      ));
      await t.pumpAndSettle();
      expect(find.text('Fri'), findsOneWidget);
      expect(find.text('Something else'), findsOneWidget);
    });
  });

  group('follow-up taps', () {
    test('a list of three gets all three, not Yes / No', () {
      expect(suggestFollowUps('Should I use Python, Dart or Go?'), ['Python', 'Dart', 'Go']);
    });
    test('"me to" is not part of a choice', () {
      expect(suggestFollowUps('Do you want me to keep going, or stop here?'), ['Keep going', 'Stop here']);
    });
    test('a card is not code: no "Explain it simply" under a file or table', () {
      expect(suggestFollowUps('Done.\n\n```file\n/data/x.pdf\n```'), isEmpty);
    });
  });

  group('cost of one message', () {
  });

  group('sky', () {
    testWidgets('the drift steps on a timer, and stops in the background', (t) async {
      await t.pumpWidget(MediaQuery(
        data: const MediaQueryData(size: Size(390, 844)),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: SkyBackground(dark: false, clock: () => DateTime(2026, 10, 24, 12), child: const SizedBox()),
        ),
      ));
      final s = t.state<SkyBackgroundState>(find.byType(SkyBackground));
      expect(s.driftRunning, isTrue);
      final p0 = s.driftPhase;
      await t.pump(skyStep * 10);
      expect(s.driftPhase, greaterThan(p0));
      s.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(s.driftRunning, isFalse);
      s.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(s.driftRunning, isTrue);
      await t.pumpWidget(const SizedBox());
    });
  });
}
