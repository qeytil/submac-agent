// Owner feedback 2026-10-23: bots live in the sidebar under one foldable "Bots" section with the Chief first,
// and the phone's Back leaves a bot's chat. Each test failed before its fix.
import 'package:agent/app_state.dart';
import 'package:agent/services/bots.dart';
import 'package:agent/theme.dart';
import 'package:agent/widgets/bot_list.dart';
import 'package:agent/screens/bots_workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Bot _bot(String id, String name, String role) => Bot(id: id, name: name, role: role, persona: '')
  ..active = true
  ..convId = 'conv-$id';

Widget _host(Widget child, AppState state) => ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: MediaQuery(
          data: const MediaQueryData(size: Size(400, 860), disableAnimations: true),
          child: Scaffold(body: SingleChildScrollView(child: child)),
        ),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() {
    Bots.I.bots.clear();
    Bots.I.chiefId = '';
  });

  group('sidebar bots', () {
    // Owner 2026-10-24: tapping Bots in the menu opens the Bots workspace (every bot and team lives in its rail).
    testWidgets('one Bots entry with the Chief\'s face; it opens the Bots workspace', (t) async {
      final chief = _bot('chief', 'Chief', 'Chief of staff');
      Bots.I.bots.addAll([_bot('b2', 'Amal', 'Bookkeeper'), chief]);
      Bots.I.chiefId = chief.id;
      var opened = 0;
      await t.pumpWidget(_host(DrawerBots(onOpen: () => opened++), AppState()));
      await t.pumpAndSettle();
      final entry = find.byKey(const ValueKey('drawer-bots'));
      expect(entry, findsOneWidget);
      expect(find.descendant(of: entry, matching: find.text('Digital people')), findsOneWidget);
      expect(find.descendant(of: entry, matching: find.byType(ChiefFace)), findsOneWidget);
      // The list itself is in the workspace, not in the menu.
      expect(find.text('Amal'), findsNothing);
      BotsWorkspace.debugOpenBot = (s, b) async {
        s.currentId = b.convId;
        s.messages = [];
        s.notifyListeners();
      };
      addTearDown(() => BotsWorkspace.debugOpenBot = null);
      await t.tap(entry);
      await t.pumpAndSettle();
      expect(opened, 1);
      expect(find.byType(BotsWorkspace), findsOneWidget);
    });

    testWidgets('the Bots entry is there even before any bot', (t) async {
      await t.pumpWidget(_host(const DrawerBots(), AppState()));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('drawer-bots')), findsOneWidget);
    });

    testWidgets('search still finds bots in the menu', (t) async {
      Bots.I.bots.addAll([_bot('b2', 'Amal', 'Bookkeeper'), _bot('b3', 'Nova', 'Researcher')]);
      await t.pumpWidget(_host(const DrawerBots(query: 'ama'), AppState()));
      await t.pumpAndSettle();
      expect(find.text('Amal'), findsOneWidget);
      expect(find.text('Nova'), findsNothing);
    });

    // A bot the Chief just made has no chat and is not active; the search used to drop it, so the owner could not even
    // find the bot by name after being told it was "in the sidebar under Bots".
    testWidgets('search finds a bot that has not started yet, and says so', (t) async {
      Bots.I.bots.add(Bot(id: 'u9', name: 'Sales bot', role: 'Sales', persona: ''));
      await t.pumpWidget(_host(const DrawerBots(query: 'sales'), AppState()));
      await t.pumpAndSettle();
      expect(find.text('Sales bot'), findsOneWidget);
      expect(find.text('Not started'), findsOneWidget);
    });
  });

  group('Back from a bot chat', () {
    test('goes back to a new chat when the bot chat was opened over one', () async {
      final state = AppState();
      Bots.I.bots.add(_bot('b1', 'Nova', 'Researcher'));
      state.noteBotOpened(null, false);
      state.currentId = 'conv-b1';
      expect(await state.backFromBotChat(), isTrue);
      expect(state.currentId, isNull);
    });

    test('is not handled outside a bot chat (the app may close)', () async {
      final state = AppState();
      Bots.I.bots.add(_bot('b1', 'Nova', 'Researcher'));
      state.currentId = 'some-chat';
      expect(await state.backFromBotChat(), isFalse);
      expect(state.currentId, 'some-chat');
    });

    test('bot to bot keeps the first chat as the way back', () {
      final state = AppState();
      state.noteBotOpened('chat-1', false);
      state.noteBotOpened('conv-b1', true);
      expect(state.backTargetForTest, 'chat-1');
    });
  });
}
