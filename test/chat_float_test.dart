import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:agent/app_state.dart';
import 'package:agent/models.dart';
import 'package:agent/screens/home_screen.dart';
import 'package:agent/theme.dart';
import 'package:agent/ui/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

// Owner, 2026-10-24: no header bar on the chat. Menu, Call and "+" float on their own in small blurred circles, the
// chat scrolls full height behind them, and the list keeps a top inset so nothing is hidden under them.

const _statusBar = 24.0;

Widget _host(Widget child, {TextDirection dir = TextDirection.ltr, AppState? state}) => ChangeNotifierProvider<AppState>.value(
      value: state ?? AppState(),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        home: MediaQuery(
          data: const MediaQueryData(size: Size(400, 860), padding: EdgeInsets.only(top: _statusBar), disableAnimations: true),
          child: Directionality(textDirection: dir, child: Scaffold(body: child)),
        ),
      ),
    );

Widget _bar({VoidCallback? hold, VoidCallback? menu}) => Stack(children: [
      Positioned(
        top: 0,
        left: 0,
        right: 0,
        child: ChatFloatBar(onMenu: menu ?? () {}, onMenuHold: hold, onCall: () {}, onNew: () {}),
      ),
    ]);

void main() {
  testWidgets('menu, call and new chat float in blurred circles, below the status bar, with no bar behind them', (t) async {
    await t.pumpWidget(_host(_bar()));
    for (final k in ['top-menu', 'top-call', 'top-new']) {
      expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
      expect(find.descendant(of: find.byKey(ValueKey(k)), matching: find.byType(BackdropFilter)), findsOneWidget, reason: k);
      expect(find.descendant(of: find.byKey(ValueKey(k)), matching: find.byType(ClipOval)), findsOneWidget, reason: k);
      expect(t.getTopLeft(find.byKey(ValueKey(k))).dy, greaterThanOrEqualTo(_statusBar), reason: '$k clears the status bar');
      expect(t.getSize(find.byKey(ValueKey(k))), const Size(Lux.tap, Lux.tap));
    }
    expect(find.byType(AppBar), findsNothing);
    // Exactly three blurs: one per button, none behind the row.
    expect(find.byType(BackdropFilter), findsNWidgets(3));
    final f = t.widget<BackdropFilter>(find.byType(BackdropFilter).first).filter;
    expect(f, isA<ImageFilter>());
  });

  testWidgets('right to left: the menu sits on the right, new chat on the left', (t) async {
    await t.pumpWidget(_host(_bar(), dir: TextDirection.rtl));
    expect(t.getCenter(find.byKey(const ValueKey('top-menu'))).dx, greaterThan(t.getCenter(find.byKey(const ValueKey('top-new'))).dx));
    await t.pumpWidget(_host(_bar()));
    expect(t.getCenter(find.byKey(const ValueKey('top-menu'))).dx, lessThan(t.getCenter(find.byKey(const ValueKey('top-new'))).dx));
  });

  testWidgets('tap opens the menu; hold runs the old header actions', (t) async {
    var menu = 0, hold = 0;
    await t.pumpWidget(_host(_bar(menu: () => menu++, hold: () => hold++)));
    await t.tap(find.byKey(const ValueKey('top-menu')));
    await t.longPress(find.byKey(const ValueKey('top-menu')));
    await t.pump();
    expect(menu, 1);
    expect(hold, 1);
  });

  testWidgets('the chat list starts below the floating buttons and still rests on the newest message', (t) async {
    t.view.physicalSize = const Size(400, 860);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final s = AppState();
    s.messages = [
      ChatMessage(id: 'u1', role: 'user', content: 'First question'),
      ChatMessage(id: 'a1', role: 'assistant', content: 'A short first answer.'),
    ];
    await t.pumpWidget(_host(const ChatList(), state: s));
    await t.pump(const Duration(milliseconds: 400));
    final list = t.widget<ListView>(find.descendant(of: find.byType(ChatList), matching: find.byType(ListView)).first);
    final pad = list.padding! as EdgeInsets;
    expect(pad.top, Space.x3 + _statusBar + chatFloatHeight);
    expect(chatFloatHeight, Space.x2 + Lux.tap + Space.x2);
    // Newest message at the foot of the chat, not at the top.
    expect(t.getBottomLeft(find.byKey(const ValueKey('user-bubble-u1'))).dy, greaterThan(860 * 0.5));
    await t.pumpWidget(const SizedBox());
  });

  test('the chat screen has no app bar any more', () {
    final src = File('lib/screens/home_screen.dart').readAsStringSync();
    expect(src.contains('appBar:'), isFalse);
    expect(src.contains('ChatFloatBar('), isTrue);
  });
}
