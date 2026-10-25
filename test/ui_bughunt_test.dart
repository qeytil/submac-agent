import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:agent/app_state.dart';
import 'package:agent/models.dart';
import 'package:agent/screens/home_screen.dart';
import 'package:agent/theme.dart';
import 'package:agent/widgets/chat/typing_text.dart';
import 'package:agent/widgets/chat_extras.dart';
import 'package:agent/widgets/logo.dart';

// Bug hunt (v1.13.84): the chat stays on the newest message, the greeting types itself, the question rows,
// and no dots. No pumpAndSettle on anything that loops.

Widget _app(Widget child, {AppState? state, bool still = false}) => ChangeNotifierProvider<AppState>.value(
      value: state ?? AppState(),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        home: MediaQuery(
          data: MediaQueryData(size: const Size(400, 860), disableAnimations: still),
          child: Scaffold(body: child),
        ),
      ),
    );

String _typed(WidgetTester t) => (t.widget(find.byKey(const ValueKey('typing-text'))) as Text).data ?? '';

void main() {
  group('chat list', () {
    testWidgets('a new message appears at the bottom, in view, not stranded at the top', (t) async {
      t.view.physicalSize = const Size(400, 860);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final s = AppState();
      s.messages = [
        ChatMessage(id: 'u1', role: 'user', content: 'First question'),
        ChatMessage(id: 'a1', role: 'assistant', content: 'A short first answer.'),
      ];
      await t.pumpWidget(_app(const ChatList(), state: s, still: true));
      await t.pump(const Duration(milliseconds: 400));
      // The second message, sent from this screen.
      s.messages = [...s.messages, ChatMessage(id: 'u2', role: 'user', content: 'And a second one')..animateIn = true];
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      s.notifyListeners();
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      final bubble = find.byKey(const ValueKey('user-bubble-u2'));
      expect(bubble, findsOneWidget);
      // It sits at the foot of the chat (the list rests on the newest message), not at the top of the screen.
      expect(t.getBottomLeft(bubble).dy, greaterThan(860 * 0.7));
      // The reply then grows under it, still at the bottom.
      s.messages = [...s.messages, ChatMessage(id: 'a2', role: 'assistant', content: 'The second answer.')];
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      s.notifyListeners();
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(t.getBottomLeft(bubble).dy, lessThan(860));
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });
  });

  group('greeting', () {
    testWidgets('the letters fade in once, in order, then the line stays (no loop, no erase)', (t) async {
      const full = 'What can I do?';
      await t.pumpWidget(_app(const Center(child: TypingText(full))));
      // The whole line is laid out from the first frame, so nothing moves while it appears.
      final size0 = t.getSize(find.byKey(const ValueKey('typing-text')));
      double alphaOf(int i) {
        final rich = t.widget<Text>(find.byKey(const ValueKey('typing-text'))).textSpan;
        if (rich == null) return 1;
        return ((rich as TextSpan).children![i] as TextSpan).style!.color!.a;
      }
      expect(alphaOf(0), lessThan(0.05));
      await t.pump(TypingText.letterStep * 3);
      expect(alphaOf(0), greaterThan(alphaOf(5)), reason: 'earlier letters are ahead of later ones');
      expect(t.getSize(find.byKey(const ValueKey('typing-text'))), size0);
      await t.pumpAndSettle(); // settles: it never loops
      expect(_typed(t), full);
      await t.pump(const Duration(seconds: 6));
      expect(_typed(t), full, reason: 'no erase, no replay');
      expect(t.getSize(find.byKey(const ValueKey('typing-text'))), size0);
    });

    test('Arabic fades in word by word so the letters keep joining', () {
      expect(TypingText.units('مرحبا هودن'), ['مرحبا ', 'هودن']);
      expect(TypingText.units('Hi').length, 2);
    });

    testWidgets('stands still with reduced motion', (t) async {
      await t.pumpWidget(_app(const Center(child: TypingText('What can I do?')), still: true));
      expect(_typed(t), 'What can I do?');
      await t.pump(const Duration(seconds: 5));
      expect(_typed(t), 'What can I do?');
    });
  });

  group('questions', () {
    testWidgets('Something else opens a field for your own answer', (t) async {
      final picks = <String>[];
      final own = <String>[];
      await t.pumpWidget(_app(SingleChildScrollView(
        child: ChoiceRows(options: const ['Morning', 'Evening'], onPick: picks.add, onOther: own.add),
      )));
      await t.pump(const Duration(seconds: 1));
      expect(find.text('Something else'), findsOneWidget);
      await t.tap(find.text('Something else'));
      await t.pump(const Duration(milliseconds: 400));
      await t.enterText(find.byType(TextField), 'Around noon');
      await t.testTextInput.receiveAction(TextInputAction.send);
      await t.pump(const Duration(milliseconds: 400));
      expect(own, ['Around noon']);
      expect(picks, isEmpty);
      expect(find.byKey(const ValueKey('choice-check')), findsOneWidget);
      // Answered: the other rows cannot be tapped any more.
      await t.tap(find.text('Morning'));
      expect(picks, isEmpty);
      await t.pumpWidget(const SizedBox());
    });
  });

  group('no dots', () {
    testWidgets('a resting indicator shows nothing; a working one is a fine ring that stands still with reduced motion', (t) async {
      await t.pumpWidget(_app(const Center(child: RedDot(size: 8))));
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await t.pumpWidget(_app(const Center(child: RedDot(size: 8, animate: true)), still: true));
      final ring = t.widget<CircularProgressIndicator>(find.byType(CircularProgressIndicator));
      expect(ring.value, isNotNull);
      await t.pumpAndSettle();
    });

    test('the icon set carries no dots', () {
      for (final name in ['mic', 'crown', 'image', 'store', 'steps', 'more']) {
        final svg = File('assets/icons/$name.svg').readAsStringSync();
        expect(svg.contains('<circle'), isFalse, reason: name);
        expect(svg.toUpperCase().contains('C2361B'), isFalse, reason: name);
      }
    });
  });
}
