// Professional bots, the Grok way (2026-10-24): the opening and greeting guard, Full access, Allow always, and the new
// create screen. Research: docs/grok-bots-research.md.
import 'package:agent/app_state.dart';
import 'package:agent/screens/hire_screen.dart';
import 'package:agent/screens/settings_screen.dart' show FullAccessTile;
import 'package:agent/services/bot_ask.dart';
import 'package:agent/services/bot_manner.dart';
import 'package:agent/services/full_access.dart';
import 'package:agent/services/tools.dart';
import 'package:agent/services/trust.dart';
import 'package:agent/theme.dart';
import 'package:agent/ui/motion.dart';
import 'package:agent/widgets/approval_card.dart' show ConfirmInline;
import 'package:agent/widgets/bot_list.dart' show DrawerSection;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _app(Widget home, {bool dark = false}) => ChangeNotifierProvider<AppState>.value(
      value: AppState(),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(dark ? Brightness.dark : Brightness.light),
        home: MediaQuery(data: const MediaQueryData(size: Size(400, 860), disableAnimations: true), child: home),
      ),
    );

/// Like [_app] but with motion on: the motion tests need the animations to run (the form tests use reduced motion).
Widget _moving(Widget home) => ChangeNotifierProvider<AppState>.value(
      value: AppState(),
      child: MaterialApp(debugShowCheckedModeBanner: false, theme: buildTheme(Brightness.light), home: home),
    );

/// A tall window, so the whole form and its suggestions are laid out at once.
void _tall(WidgetTester t) {
  t.view.physicalSize = const Size(400, 4200);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await FullAccess.I.set(false);
  });

  group('no tools on the opening turn or on a greeting', () {
    test('the first meeting holds; routines and team jobs do not', () {
      expect(BotAsk.askFirst(text: '', wakeReason: 'first meeting: the user just hired you and is looking at your chat'), isTrue);
      expect(BotAsk.askFirst(text: '', wakeReason: 'routine 08:00'), isFalse);
      expect(BotAsk.askFirst(text: '', wakeReason: 'your voice call with the user just ended'), isFalse);
    });

    test('greetings and small talk hold, in English, Somali and Arabic', () {
      for (final t in ['hi', 'Hello!', 'good morning', 'thanks', 'salaam', 'iska warran', 'مرحبا', 'how are you']) {
        expect(BotAsk.askFirst(text: t), isTrue, reason: t);
      }
    });

    test('a real request runs (Grok: message a bot and it gets the work done)', () {
      for (final t in [
        'Find the three cheapest flights to Nairobi',
        'Draft a reply to Amal about the invoice',
        'fadlan ii qor warbixin',
        'what are my open orders this week and which are late',
      ]) {
        expect(BotAsk.askFirst(text: t), isFalse, reason: t);
      }
    });

    test('a yes to the bot\'s own question is the go-ahead; a running task is never held', () {
      expect(BotAsk.askFirst(text: 'yes', answeringBot: true), isFalse);
      expect(BotAsk.askFirst(text: 'the first one', answeringBot: true), isFalse);
      expect(BotAsk.askFirst(text: 'hi', midTask: true), isFalse);
    });

    test('the wake reason is read from the app\'s wake text', () {
      expect(BotAsk.wakeReasonOf('[first meeting: the user just hired you]\nIntroduce yourself'), 'first meeting: the user just hired you');
      expect(BotAsk.wakeReasonOf('[Woken: routine 08:00. 2026-10-24 08:00]\nDo this now'), 'routine 08:00. 2026-10-24 08:00');
      expect(BotAsk.wakeReasonOf('no bracket'), '');
    });

    test('the held turn greets, says what it can do and suggests one or two tasks as tap replies', () {
      final n = BotAsk.turnNote(opening: true);
      expect(n, contains('no tools'));
      expect(n, contains('```choices\n['));
      expect(n, contains('two or three'));
      expect(BotManner.block, contains(BotAsk.rule));
    });
  });

  group('Full access', () {
    test('off: changes ask, small changes in Telesia\'s space do not; money always asks', () {
      expect(FullAccess.shouldAsk(level: BotTrust.levelNew, kind: 'change', tool: 'mcp_x', fullAccess: false), isTrue);
      expect(FullAccess.shouldAsk(level: BotTrust.levelNew, kind: 'change', tool: 'write_file', fullAccess: false), isFalse);
      expect(FullAccess.shouldAsk(level: BotTrust.levelNew, kind: 'change', tool: 'edit_file', fullAccess: false), isFalse);
      expect(FullAccess.shouldAsk(level: BotTrust.levelTrusted, kind: 'change', tool: 'mcp_x', fullAccess: false), isFalse);
      expect(FullAccess.shouldAsk(level: BotTrust.levelTrusted, kind: 'send', tool: 'email_send', fullAccess: false), isTrue);
      expect(FullAccess.shouldAsk(level: BotTrust.levelTrusted, kind: 'money', tool: 'browser_click', fullAccess: false), isTrue);
    });

    test('on: nothing asks except money', () {
      for (final k in ['change', 'send', 'delete']) {
        expect(FullAccess.shouldAsk(level: BotTrust.levelNew, kind: k, tool: 'email_send', fullAccess: true), isFalse, reason: k);
      }
      expect(FullAccess.shouldAsk(level: BotTrust.levelNew, kind: 'money', tool: 'browser_click', fullAccess: true), isTrue);
      expect(BotTrust.kindOf('browser_click', 'Place order'), 'money');
    });

    test('off by default, remembered when turned on', () async {
      SharedPreferences.setMockInitialValues({});
      await FullAccess.I.load();
      expect(FullAccess.I.on, isFalse);
      await FullAccess.I.set(true);
      await FullAccess.I.load();
      expect(FullAccess.I.on, isTrue);
    });

    testWidgets('the Settings switch explains itself and asks once before turning on', (t) async {
      await t.pumpWidget(_app(const Scaffold(body: FullAccessTile())));
      expect(find.text('Full access'), findsOneWidget);
      expect(find.textContaining('Small, safe steps go ahead'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('full-access')));
      await t.pumpAndSettle();
      expect(find.text('Turn on Full access?'), findsOneWidget);
      await t.tap(find.text('Turn on'));
      await t.pumpAndSettle();
      expect(FullAccess.I.on, isTrue);
      expect(find.textContaining('Payments and purchases still ask every time'), findsOneWidget);
    });

    Future<bool?> openCard(WidgetTester t, ActionRequest req) async {
      bool? result;
      await t.pumpWidget(_app(Scaffold(
        body: ConfirmInline(request: req, onAnswer: (ok) => result = ok),
      )));
      await t.pumpAndSettle();
      return result;
    }

    testWidgets('an approval offers Allow always, which approves and marks the ask', (t) async {
      final req = ActionRequest(title: 'Send this email to amal@example.com?', body: 'Invoice', detail: 'Hi Amal', confirmLabel: 'Send');
      await openCard(t, req);
      expect(find.byKey(const ValueKey('allow-always')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('allow-always')));
      await t.pumpAndSettle();
      expect(req.allowAlways, isTrue);
    });

    testWidgets('a payment never offers Allow always', (t) async {
      final req = ActionRequest(title: 'Pay 20 USD for the order?', body: '', detail: 'checkout', confirmLabel: 'Pay');
      await openCard(t, req);
      expect(find.byKey(const ValueKey('allow-always')), findsNothing);
    });
  });

  group('the create screen', () {
    for (final dark in [false, true]) {
      testWidgets('renders the Grok-like form on the sky (${dark ? 'dark' : 'light'})', (t) async {
        _tall(t);
        await t.pumpWidget(_app(const HireScreen(), dark: dark));
        await t.pump();
        expect(t.takeException(), isNull);
        expect(find.text('New bot'), findsOneWidget);
        for (final label in ['Name', 'Role', 'What it does', 'Instructions', 'Can use']) {
          expect(find.text(label), findsOneWidget, reason: label);
        }
        expect(find.byKey(const ValueKey('power-web')), findsOneWidget);
        // The primary button waits for a name.
        final save = find.byKey(const ValueKey('bot-save'));
        await t.scrollUntilVisible(save, 200, scrollable: find.byType(Scrollable).first);
        expect(t.widget<FilledButton>(find.descendant(of: save, matching: find.byType(FilledButton))).onPressed, isNull);
        await t.enterText(find.byKey(const ValueKey('bot-name')), 'Hodan');
        await t.pump();
        expect(t.widget<FilledButton>(find.descendant(of: save, matching: find.byType(FilledButton))).onPressed, isNotNull);
        // No outlined fields or boxes: every field uses the theme's borderless look.
        for (final f in t.widgetList<TextField>(find.byType(TextField))) {
          final b = f.decoration?.border;
          expect(b == null || b.borderSide == BorderSide.none, isTrue);
        }
      });
    }

    testWidgets('a suggested role fills the form', (t) async {
      _tall(t);
      await t.pumpWidget(_app(const HireScreen()));
      await t.pump();
      final row = find.text('Researcher');
      expect(row, findsOneWidget);
      await t.tap(row);
      await t.pump();
      expect(find.text('Nova'), findsWidgets);
    });
  });

  group('smooth menu and pages', () {
    testWidgets('a folding section keeps its rows while it folds, then lets them go (no jump)', (t) async {
      final rows = [for (var i = 0; i < 5; i++) SizedBox(height: 40, child: Text('row $i'))];
      await t.pumpWidget(_moving(Scaffold(body: ListView(children: [DrawerSection(title: 'Fold test', id: 'fold-test', children: rows)]))));
      final open = t.getSize(find.byType(DrawerSection)).height;
      await t.tap(find.text('Fold test'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 80));
      final mid = t.getSize(find.byType(DrawerSection)).height;
      expect(find.text('row 0'), findsOneWidget, reason: 'rows stay while folding');
      expect(mid, lessThan(open));
      await t.pumpAndSettle();
      final folded = t.getSize(find.byType(DrawerSection)).height;
      expect(mid, greaterThan(folded));
      expect(find.text('row 0'), findsNothing);
      await t.tap(find.text('Fold test'));
      await t.pumpAndSettle();
      expect(t.getSize(find.byType(DrawerSection)).height, open);
    });

    testWidgets('with reduced motion a section folds at once', (t) async {
      final rows = [for (var i = 0; i < 3; i++) SizedBox(height: 40, child: Text('still $i'))];
      await t.pumpWidget(_app(Scaffold(body: ListView(children: [DrawerSection(title: 'Still fold', id: 'still-fold', children: rows)]))));
      await t.tap(find.text('Still fold'));
      await t.pump();
      expect(find.text('still 0'), findsNothing);
      await t.tap(find.text('Still fold'));
      await t.pump();
    });

    testWidgets('pushing a page fades the one underneath out fully (no two pages at once)', (t) async {
      final key = GlobalKey<NavigatorState>();
      await t.pumpWidget(MaterialApp(
        navigatorKey: key,
        theme: buildTheme(Brightness.light),
        home: const Scaffold(body: Text('first page')),
      ));
      key.currentState!.push(MaterialPageRoute(builder: (_) => const Scaffold(body: Text('second page'))));
      await t.pump();
      // Near the end of the push the page underneath is (almost) gone. After the push it is offstage, and an offstage
      // route is always given a finished animation, so the check has to be made while the push is still running.
      await t.pump(const Duration(milliseconds: 290));
      final fades = t.widgetList<FadeTransition>(find.ancestor(of: find.text('first page', skipOffstage: false), matching: find.byType(FadeTransition)));
      expect(fades.any((f) => f.opacity.value < 0.05), isTrue);
      await t.pumpAndSettle();
      expect(find.text('first page'), findsNothing);
      expect(find.text('second page'), findsOneWidget);
      expect(const SubPageTransitions(), isA<PageTransitionsBuilder>());
    });
  });
}
