import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:agent/app_state.dart';
import 'package:agent/models.dart';
import 'package:agent/screens/home_screen.dart';
import 'package:agent/theme.dart';
import 'package:agent/ui/motion.dart';

// Owner (Manuel, 2026-10-26): "The send and recieve messages should have smooth 1 sec animations".
// One MessageArrive (fade, slight rise and scale, ease-out, SubMotion.arrive = 1000 ms) for sent and received messages,
// once per message, only for messages new this session; never on history, never again on a rebuild; none with reduce
// motion. No pumpAndSettle on the chat (it has looping animations).

const _arriveKey = ValueKey('message-arrive-opacity');

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

/// The arrival opacity of message [id] (null: it has no arrival animation).
double? _opacity(WidgetTester t, String id) {
  final f = find.descendant(of: find.byKey(ValueKey(id)), matching: find.byKey(_arriveKey));
  if (f.evaluate().isEmpty) return null;
  return t.widget<Opacity>(f.first).opacity;
}

// ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
void _notify(AppState s) => s.notifyListeners();

Future<void> _size(WidgetTester t) async {
  t.view.physicalSize = const Size(400, 860);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
}

void main() {
  setUp(MessageArrive.resetSession);

  test('one constant: a message arrives over 1000 ms on an ease-out', () {
    expect(SubMotion.arrive, const Duration(milliseconds: 1000));
    expect(SubMotion.arriveEase.transform(0.5), greaterThan(0.5), reason: 'ease-out: past half way at half time');
  });

  group('MessageArrive', () {
    Widget host(String text, {String id = 'm1', bool enabled = true, bool still = false}) => MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(size: const Size(400, 800), disableAnimations: still),
            child: Scaffold(body: MessageArrive(id: id, enabled: enabled, child: Text(text))),
          ),
        );
    double op(WidgetTester t) => t.widget<Opacity>(find.byKey(_arriveKey)).opacity;
    double shift(WidgetTester t) =>
        t.widget<Transform>(find.descendant(of: find.byKey(_arriveKey), matching: find.byType(Transform)).first).transform.getTranslation().y;

    testWidgets('fades, rises and settles over one second, then stays at rest', (t) async {
      await t.pumpWidget(host('hello'));
      expect(op(t), lessThan(0.05));
      expect(shift(t), greaterThan(SubMotion.sendRise * 0.9), reason: 'starts a little low');
      await t.pump(const Duration(milliseconds: 500));
      expect(op(t), inExclusiveRange(0.5, 1.0), reason: 'ease-out: well on its way at half time, not done');
      await t.pump(const Duration(milliseconds: 400));
      expect(op(t), lessThan(1.0), reason: 'still settling at 900 ms (1 s, not the old 480 ms)');
      await t.pump(const Duration(milliseconds: 120));
      expect(op(t), 1.0);
      expect(shift(t), 0);
      expect(t.hasRunningAnimations, isFalse);
    });

    testWidgets('a rebuild (streamed words) never restarts it, and the same message never plays twice', (t) async {
      await t.pumpWidget(host('Hel'));
      await t.pump(const Duration(milliseconds: 400));
      final mid = op(t);
      await t.pumpWidget(host('Hello the'));
      await t.pump(const Duration(milliseconds: 16));
      expect(op(t), greaterThanOrEqualTo(mid), reason: 'new words do not restart the arrival');
      await t.pump(const Duration(milliseconds: 700));
      expect(op(t), 1.0);
      // Remounted (scrolled away and back, moved into the history): at rest at once.
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(host('Hello there'));
      expect(find.byKey(_arriveKey), findsNothing);
      expect(find.text('Hello there'), findsOneWidget);
    });

    testWidgets('history (not new this session) shows at once', (t) async {
      await t.pumpWidget(host('old', enabled: false));
      expect(find.byKey(_arriveKey), findsNothing);
      expect(t.hasRunningAnimations, isFalse);
    });

    testWidgets('reduce motion: it simply appears', (t) async {
      await t.pumpWidget(host('hi', still: true));
      expect(find.byKey(_arriveKey), findsNothing);
      expect(t.hasRunningAnimations, isFalse);
    });
  });

  group('chat', () {
    testWidgets('a sent message and the reply each arrive over one second', (t) async {
      await _size(t);
      final s = AppState();
      s.messages = [
        ChatMessage(id: 'u1', role: 'user', content: 'First question'),
        ChatMessage(id: 'a1', role: 'assistant', content: 'A short first answer.'),
      ];
      await t.pumpWidget(_app(const ChatList(), state: s));
      await t.pump(const Duration(milliseconds: 100));

      // Sent.
      s.messages = [...s.messages, ChatMessage(id: 'u2', role: 'user', content: 'And a second one')..animateIn = true];
      _notify(s);
      await t.pump();
      expect(_opacity(t, 'u2'), lessThan(0.1));
      await t.pump(const Duration(milliseconds: 500));
      expect(_opacity(t, 'u2'), inExclusiveRange(0.3, 1.0));
      await t.pump(const Duration(milliseconds: 550));
      expect(_opacity(t, 'u2'), 1.0);

      // Received, streaming: it arrives with its first words, and later words do not restart it.
      final a2 = ChatMessage(id: 'a2', role: 'assistant', content: 'The second', streaming: true)..animateIn = true;
      s.messages = [...s.messages, a2];
      _notify(s);
      await t.pump();
      final first = _opacity(t, 'a-a2');
      expect(first, isNotNull);
      expect(first, lessThan(0.1));
      await t.pump(const Duration(milliseconds: 300));
      final mid = _opacity(t, 'a-a2')!;
      a2.content = 'The second answer, with a few more words.';
      _notify(s);
      await t.pump(const Duration(milliseconds: 16));
      expect(_opacity(t, 'a-a2'), greaterThanOrEqualTo(mid), reason: 'a streamed token does not restart the arrival');
      await t.pump(const Duration(milliseconds: 750));
      expect(_opacity(t, 'a-a2'), 1.0);
      a2.streaming = false;
      _notify(s);
      await t.pump(const Duration(milliseconds: 16));
      expect(_opacity(t, 'a-a2'), 1.0, reason: 'finishing the reply does not replay it');
      // The first exchange is history: it never animated.
      expect(_opacity(t, 'u1'), isNull);
      expect(_opacity(t, 'a1'), isNull);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 3));
    });

    testWidgets('history on open does not animate', (t) async {
      await _size(t);
      final s = AppState();
      s.messages = [
        for (var i = 0; i < 6; i++) ...[
          ChatMessage(id: 'u$i', role: 'user', content: 'Question $i'),
          ChatMessage(id: 'a$i', role: 'assistant', content: 'Answer number $i.'),
        ],
      ];
      await t.pumpWidget(_app(const ChatList(), state: s));
      await t.pump();
      expect(find.byKey(_arriveKey), findsNothing);
      // Scrolling back through it does not animate either.
      await t.drag(find.byType(ListView), const Offset(0, 400));
      await t.pump(const Duration(milliseconds: 100));
      expect(find.byKey(_arriveKey), findsNothing);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('reduce motion: new messages simply appear', (t) async {
      await _size(t);
      final s = AppState();
      s.messages = [ChatMessage(id: 'u1', role: 'user', content: 'Hi')];
      await t.pumpWidget(_app(const ChatList(), state: s, still: true));
      await t.pump();
      s.messages = [
        ...s.messages,
        ChatMessage(id: 'u2', role: 'user', content: 'Sent now')..animateIn = true,
        ChatMessage(id: 'a2', role: 'assistant', content: 'Received now')..animateIn = true,
      ];
      _notify(s);
      await t.pump();
      expect(find.byKey(_arriveKey), findsNothing);
      expect(find.byKey(const ValueKey('user-bubble-u2')), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 3));
    });
  });
}
