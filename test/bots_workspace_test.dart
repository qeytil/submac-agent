// The Bots workspace (owner, 2026-10-24): one Grok-style screen for bots and teams. It opens on the Chief's chat with
// no header bar, a thin rail folded by default that swaps chats in place, folds when the keyboard opens, and shows a
// status ring on every head. These tests pin each part of the owner's spec.
import 'package:agent/app_state.dart';
import 'package:agent/models.dart';
import 'package:agent/screens/bots_workspace.dart';
import 'package:agent/screens/hire_screen.dart';
import 'package:agent/screens/home_screen.dart' show ChatList;
import 'package:agent/screens/bot_store_screen.dart';
import 'package:agent/screens/offices_screen.dart';
import 'package:agent/services/bot_status.dart';
import 'package:agent/services/bots.dart';
import 'package:agent/services/offices.dart';
import 'package:agent/services/team_run.dart';
import 'package:agent/theme.dart';
import 'package:agent/ui/tokens.dart';
import 'package:agent/widgets/chat/edge_fade.dart' show FloatingChatFrame;
import 'package:agent/widgets/composer.dart';
import 'package:agent/widgets/status_ring.dart';
import 'package:agent/widgets/team_face.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Bot _bot(String id, String name, String role) => Bot(id: id, name: name, role: role, persona: '')
  ..active = true
  ..convId = 'conv-$id';

class _Pushes extends NavigatorObserver {
  final routes = <Route<dynamic>>[];
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => routes.add(route);
}

const _phone = Size(400, 860);

Widget _app(
  AppState s, {
  Size size = _phone,
  TextDirection dir = TextDirection.ltr,
  bool still = true,
  double keyboard = 0,
  Widget home = const BotsWorkspace(),
  NavigatorObserver? observer,
}) =>
    ChangeNotifierProvider<AppState>.value(
      value: s,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        navigatorObservers: [if (observer != null) observer],
        builder: (context, child) => MediaQuery(
          data: MediaQueryData(
            size: size,
            padding: const EdgeInsets.only(top: 24),
            viewInsets: EdgeInsets.only(bottom: keyboard),
            disableAnimations: still,
          ),
          child: Directionality(textDirection: dir, child: child!),
        ),
        home: home,
      ),
    );

/// Opens a bot's chat the way the app does, without the network: its chat becomes the open one.
final _chats = <String, List<ChatMessage>>{};
final _opened = <String>[];
Future<void> _open(AppState s, Bot b) async {
  s.noteBotOpened(s.currentId, Bots.I.byConv(s.currentId) != null);
  _opened.add(b.id);
  s.currentId = b.convId;
  s.messages = _chats[b.convId] ?? <ChatMessage>[];
  s.loadingMessages = false;
  s.notifyListeners();
}

void _size(WidgetTester t, Size size) {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
}

BotsWorkspaceState _ws(WidgetTester t) => t.state<BotsWorkspaceState>(find.byType(BotsWorkspace));

Future<void> _openRail(WidgetTester t) async {
  await t.tap(find.byKey(const ValueKey('ws-rail')));
  await t.pumpAndSettle();
}

final _working = <String>{};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({'office_bg_asked': true});
    _chats.clear();
    _opened.clear();
    _working.clear();
    BotStatus.I.reset();
    RailPins.I.reset();
    Composer.drafts.clear();
    BotsWorkspace.debugOpenBot = _open;
    final chief = _bot('chief', 'Chief', 'Chief of staff');
    Bots.I.bots.addAll([chief, _bot('nova', 'Nova', 'Researcher'), _bot('amal', 'Amal', 'Bookkeeper')]);
    Bots.I.chiefId = chief.id;
    Offices.I.offices.add(Office(id: 'o1', name: 'Launch team', members: ['chief', 'nova'], chiefId: 'chief'));
  });

  tearDown(() {
    BotsWorkspace.debugOpenBot = null;
    Bots.I.bots.clear();
    Bots.I.chiefId = '';
    Bots.I.working = null;
    Offices.I.offices.clear();
    Offices.I.approvals.clear();
    TeamRun.I.running.clear();
    BotStatus.I.reset();
  });

  AppState state() {
    final s = AppState();
    Bots.I.working = (b) => _working.contains(b.id);
    return s;
  }

  group('opening', () {
    testWidgets('opens on the Chief, with no header bar: the greeting says who it is', (t) async {
      _size(t, _phone);
      final s = state();
      await t.pumpWidget(_app(s));
      await t.pumpAndSettle();
      expect(_ws(t).active, 'b:chief');
      expect(_opened, ['chief']);
      expect(s.currentId, 'conv-chief');
      expect(find.byType(AppBar), findsNothing);
      expect(find.byKey(const ValueKey('greeting-bot-name')), findsOneWidget);
      expect(find.text('Chief of staff'), findsOneWidget);
      // The floating controls: rail toggle, call, "+".
      for (final k in ['ws-rail', 'ws-call', 'ws-plus']) {
        expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
      }
      expect(find.byType(Composer), findsOneWidget);
    });

    testWidgets('opens on the team it was asked for (deep links keep working)', (t) async {
      _size(t, _phone);
      await t.pumpWidget(_app(state(), home: const OfficeScreen(officeId: 'o1')));
      await t.pumpAndSettle();
      expect(_ws(t).active, 't:o1');
      expect(find.byType(TeamChat), findsOneWidget);
      expect(find.byKey(const ValueKey('greeting-team-name')), findsOneWidget);
      expect(find.byType(AppBar), findsNothing);
    });
  });

  group('rail', () {
    // A bot the Chief makes in chat is created with no chat and not active (Bots.create). The rail used to list only
    // started bots, so the new bot was in no list at all: the Chief said "it is in Bots" and the owner found nothing.
    testWidgets('lists a bot that has not started yet', (t) async {
      _size(t, _phone);
      Bots.I.bots.add(Bot(id: 'u9', name: 'Sales bot', role: 'Sales', persona: ''));
      await t.pumpWidget(_app(state()));
      await t.pumpAndSettle();
      await _openRail(t);
      expect(find.byKey(const ValueKey('rail-b:u9')), findsOneWidget,
          reason: 'an unstarted bot must be reachable, not invisible');
    });

    testWidgets('is folded by default, opens narrow without covering the chat, and folds again', (t) async {
      _size(t, _phone);
      await t.pumpWidget(_app(state()));
      await t.pumpAndSettle();
      expect(_ws(t).railOpen, isFalse);
      expect(find.byKey(const ValueKey('rail-b:nova')), findsNothing);
      await _openRail(t);
      expect(_ws(t).railOpen, isTrue);
      final nova = find.byKey(const ValueKey('rail-b:nova'));
      expect(nova, findsOneWidget);
      expect(find.byKey(const ValueKey('rail-t:o1')), findsOneWidget);
      // Narrow, on the start edge, no scrim over the chat.
      expect(t.getTopRight(nova).dx, lessThanOrEqualTo(Lux.railWidth));
      expect(Lux.railWidth, lessThanOrEqualTo(96));
      expect(find.byKey(const ValueKey('greeting-bot-name')), findsOneWidget, reason: 'the chat stays visible');
      // The Chief comes first and wears the crown.
      expect(t.getTopLeft(find.byKey(const ValueKey('rail-b:chief'))).dy, lessThan(t.getTopLeft(nova).dy));
      // Toggle folds it.
      await t.tap(find.byKey(const ValueKey('ws-rail')));
      await t.pumpAndSettle();
      expect(_ws(t).railOpen, isFalse);
      expect(find.byKey(const ValueKey('rail-b:nova')), findsNothing);
    });

    testWidgets('slides with transforms only: no overflow or exception mid-animation, chat never relaid out', (t) async {
      _size(t, _phone);
      await t.pumpWidget(_app(state(), still: false));
      await t.pumpAndSettle();
      final chatBefore = t.getRect(find.byType(Composer));
      await t.tap(find.byKey(const ValueKey('ws-rail')));
      for (var i = 0; i < 8; i++) {
        await t.pump(const Duration(milliseconds: 30));
        expect(t.takeException(), isNull);
        expect(t.getRect(find.byType(Composer)), chatBefore, reason: 'the chat does not move or resize while the rail slides');
      }
      await t.pumpAndSettle();
      expect(_ws(t).railOpen, isTrue);
      await t.tap(find.byKey(const ValueKey('ws-rail')));
      for (var i = 0; i < 6; i++) {
        await t.pump(const Duration(milliseconds: 30));
        expect(t.takeException(), isNull);
      }
      await t.pumpAndSettle();
      expect(t.hasRunningAnimations, isFalse);
      expect(find.byType(SlideTransition), findsWidgets);
    });

    testWidgets('a tap on the chat folds it', (t) async {
      _size(t, _phone);
      await t.pumpWidget(_app(state()));
      await t.pumpAndSettle();
      await _openRail(t);
      await t.tapAt(const Offset(300, 400));
      await t.pumpAndSettle();
      expect(_ws(t).railOpen, isFalse);
    });

    testWidgets('right to left: the rail and its toggle sit on the right', (t) async {
      _size(t, _phone);
      await t.pumpWidget(_app(state(), dir: TextDirection.rtl));
      await t.pumpAndSettle();
      expect(t.getCenter(find.byKey(const ValueKey('ws-rail'))).dx, greaterThan(_phone.width / 2));
      await _openRail(t);
      final nova = find.byKey(const ValueKey('rail-b:nova'));
      expect(t.getTopLeft(nova).dx, greaterThanOrEqualTo(_phone.width - Lux.railWidth));
    });

    for (final (name, size) in [('small', const Size(320, 568)), ('tall', const Size(412, 1400)), ('tablet', const Size(1024, 1366))]) {
      testWidgets('$name screen: opens and folds cleanly, everything reachable', (t) async {
        _size(t, size);
        await t.pumpWidget(_app(state(), size: size));
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
        await _openRail(t);
        expect(t.takeException(), isNull);
        expect(find.byKey(const ValueKey('rail-new-bot')), findsOneWidget);
        expect(find.byKey(const ValueKey('rail-store')), findsOneWidget);
        expect(t.getBottomLeft(find.byKey(const ValueKey('rail-store'))).dy, lessThanOrEqualTo(size.height));
        expect(Lux.railWidth / size.width, lessThan(0.3), reason: 'most of the chat stays visible');
        await t.tap(find.byKey(const ValueKey('ws-rail')));
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
      });
    }

    testWidgets('New bot and Bot store are pinned at the foot, under every head', (t) async {
      _size(t, _phone);
      final pushes = _Pushes();
      await t.pumpWidget(_app(state(), observer: pushes));
      await t.pumpAndSettle();
      await _openRail(t);
      final team = t.getBottomLeft(find.byKey(const ValueKey('rail-t:o1'))).dy;
      expect(t.getTopLeft(find.byKey(const ValueKey('rail-new-bot'))).dy, greaterThan(team));
      expect(t.getTopLeft(find.byKey(const ValueKey('rail-store'))).dy, greaterThan(t.getTopLeft(find.byKey(const ValueKey('rail-new-bot'))).dy));
      expect(find.text('New digital person'), findsOneWidget);
      expect(find.text('People store'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('rail-new-bot')));
      await t.pumpAndSettle();
      expect(find.byType(HireScreen), findsOneWidget);
      Navigator.of(t.element(find.byType(HireScreen))).pop();
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('rail-store')));
      await t.pumpAndSettle();
      expect(find.byType(BotStoreScreen), findsOneWidget);
    });
  });

  group('swapping', () {
    testWidgets('tapping a bot or a team swaps the chat in place, on the same route', (t) async {
      _size(t, _phone);
      final pushes = _Pushes();
      final s = state();
      await t.pumpWidget(_app(s, observer: pushes));
      await t.pumpAndSettle();
      final before = pushes.routes.length;
      final ws = _ws(t);
      await _openRail(t);
      await t.tap(find.byKey(const ValueKey('rail-b:nova')));
      await t.pumpAndSettle();
      expect(_ws(t), same(ws));
      expect(pushes.routes.length, before, reason: 'no new screen');
      expect(_ws(t).active, 'b:nova');
      expect(s.currentId, 'conv-nova');
      expect(find.text('Nova'), findsWidgets);
      expect(_ws(t).railOpen, isTrue, reason: 'the rail stays while you swap');
      await t.tap(find.byKey(const ValueKey('rail-t:o1')));
      await t.pumpAndSettle();
      expect(_ws(t).active, 't:o1');
      expect(find.byType(TeamChat), findsOneWidget);
      expect(pushes.routes.length, before);
      await t.tap(find.byKey(const ValueKey('rail-b:chief')));
      await t.pumpAndSettle();
      expect(_ws(t).active, 'b:chief');
      expect(find.byType(TeamChat), findsNothing);
    });

    testWidgets('the swap cross-fades without exceptions and never shows the new chat in the old one', (t) async {
      _size(t, _phone);
      _chats['conv-chief'] = [ChatMessage(id: 'c1', role: 'user', content: 'Chief question'), ChatMessage(id: 'c2', role: 'assistant', content: 'Chief answer')];
      _chats['conv-nova'] = [ChatMessage(id: 'n1', role: 'user', content: 'Nova question'), ChatMessage(id: 'n2', role: 'assistant', content: 'Nova answer')];
      await t.pumpWidget(_app(state(), still: false));
      await t.pumpAndSettle();
      expect(find.text('Chief answer'), findsOneWidget);
      await _openRail(t);
      await t.tap(find.byKey(const ValueKey('rail-b:nova')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 60));
      expect(t.takeException(), isNull);
      // Mid cross-fade: each list shows its own chat, never two copies of the new one.
      expect(find.text('Nova answer'), findsOneWidget);
      expect(find.text('Chief answer'), findsOneWidget);
      await t.pumpAndSettle();
      expect(find.text('Chief answer'), findsNothing);
      expect(find.text('Nova answer'), findsOneWidget);
    });

    testWidgets('each chat keeps its own draft', (t) async {
      _size(t, _phone);
      await t.pumpWidget(_app(state()));
      await t.pumpAndSettle();
      final box = find.descendant(of: find.byType(Composer), matching: find.byType(TextField));
      await t.enterText(box, 'for the chief');
      await t.pump();
      await _openRail(t);
      await t.tap(find.byKey(const ValueKey('rail-b:nova')));
      await t.pumpAndSettle();
      expect(t.widget<TextField>(box).controller!.text, isEmpty);
      await t.tap(find.byKey(const ValueKey('rail-b:chief')));
      await t.pumpAndSettle();
      expect(t.widget<TextField>(box).controller!.text, 'for the chief');
    });

    testWidgets('each chat keeps its scroll position', (t) async {
      _size(t, _phone);
      _chats['conv-chief'] = [
        for (var i = 0; i < 40; i++) ChatMessage(id: 'm$i', role: i.isEven ? 'user' : 'assistant', content: 'Line $i of a long chat with the chief.'),
      ];
      _chats['conv-nova'] = [ChatMessage(id: 'n1', role: 'user', content: 'Hi')];
      await t.pumpWidget(_app(state()));
      await t.pumpAndSettle();
      ScrollPosition pos() => t.state<ScrollableState>(find.descendant(of: find.byKey(const ValueKey('m')), matching: find.byType(Scrollable)).first).position;
      await t.drag(find.byKey(const ValueKey('m')), const Offset(0, 300));
      await t.pumpAndSettle();
      final kept = pos().pixels;
      expect(kept, greaterThan(0));
      await _openRail(t);
      await t.tap(find.byKey(const ValueKey('rail-b:nova')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('rail-b:chief')));
      await t.pumpAndSettle();
      expect(pos().pixels, closeTo(kept, 1));
    });
  });

  group('keyboard and Back', () {
    testWidgets('the composer taking the cursor folds the rail', (t) async {
      _size(t, _phone);
      await t.pumpWidget(_app(state()));
      await t.pumpAndSettle();
      await _openRail(t);
      final box = find.descendant(of: find.byType(Composer), matching: find.byType(TextField));
      await t.showKeyboard(box);
      await t.pumpAndSettle();
      expect(_ws(t).railOpen, isFalse);
    });

    testWidgets('the keyboard coming up folds the rail', (t) async {
      _size(t, _phone);
      final s = state();
      await t.pumpWidget(_app(s));
      await t.pumpAndSettle();
      await _openRail(t);
      await t.pumpWidget(_app(s, keyboard: 300));
      await t.pumpAndSettle();
      expect(_ws(t).railOpen, isFalse);
    });

    testWidgets('a team\'s composer folds the rail too', (t) async {
      _size(t, _phone);
      await t.pumpWidget(_app(state(), home: const OfficeScreen(officeId: 'o1')));
      await t.pumpAndSettle();
      await _openRail(t);
      await t.showKeyboard(find.byKey(const ValueKey('team-composer')));
      await t.pumpAndSettle();
      expect(_ws(t).railOpen, isFalse);
    });

    testWidgets('Back folds an open rail first, then goes back to the chat you came from', (t) async {
      _size(t, _phone);
      final s = state();
      await t.pumpWidget(_app(s, home: Builder(
        builder: (c) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const BotsWorkspace())),
              child: const Text('open bots'),
            ),
          ),
        ),
      )));
      await t.tap(find.text('open bots'));
      await t.pumpAndSettle();
      expect(s.currentId, 'conv-chief');
      await _openRail(t);
      final nav = t.state<NavigatorState>(find.byType(Navigator));
      await nav.maybePop();
      await t.pumpAndSettle();
      expect(find.byType(BotsWorkspace), findsOneWidget, reason: 'Back folded the rail');
      expect(_ws(t).railOpen, isFalse);
      await nav.maybePop();
      await t.pumpAndSettle();
      expect(find.byType(BotsWorkspace), findsNothing);
      expect(find.text('open bots'), findsOneWidget);
      expect(s.currentId, isNull, reason: 'back on the new chat it was opened over');
    });
  });

  group('status rings', () {
    RingState ring(WidgetTester t, String key) => t.widget<StatusRing>(find.byKey(ValueKey('ring-$key'))).state;

    testWidgets('grey when idle, green while working, yellow while waiting, blue when done, cleared on open', (t) async {
      _size(t, _phone);
      final s = state();
      await t.pumpWidget(_app(s));
      await t.pumpAndSettle();
      await _openRail(t);
      for (final k in ['b:chief', 'b:nova', 'b:amal', 't:o1']) {
        expect(ring(t, k), RingState.idle, reason: k);
      }
      // Nova starts working: its ring and its team's ring turn green.
      _working.add('nova');
      s.notifyListeners();
      await t.pump();
      expect(ring(t, 'b:nova'), RingState.working);
      expect(ring(t, 't:o1'), RingState.working, reason: 'a member works');
      // Nova asks for an OK: yellow wins.
      Offices.I.approvals.add(Approval(id: 'a1', botId: 'nova', title: 'Send the email'));
      BotStatus.I.recompute();
      await t.pump();
      expect(ring(t, 'b:nova'), RingState.waiting);
      Offices.I.approvals.clear();
      BotStatus.I.recompute();
      // Nova finishes while the Chief is on screen: blue until opened.
      _working.remove('nova');
      s.notifyListeners();
      await t.pump();
      expect(ring(t, 'b:nova'), RingState.done);
      expect(ring(t, 't:o1'), RingState.done, reason: 'the team finished too, unread');
      final p = Palette.light;
      expect(StatusRing.colorFor(p, RingState.done), p.statusDone);
      // Opening Nova's chat reads it.
      await t.tap(find.byKey(const ValueKey('rail-b:nova')));
      await t.pumpAndSettle();
      expect(ring(t, 'b:nova'), RingState.idle);
      expect(ring(t, 't:o1'), RingState.done);
      await t.tap(find.byKey(const ValueKey('rail-t:o1')));
      await t.pumpAndSettle();
      expect(ring(t, 't:o1'), RingState.idle);
    });

    testWidgets('finishing in the chat on screen is read at once', (t) async {
      _size(t, _phone);
      final s = state();
      await t.pumpWidget(_app(s));
      await t.pumpAndSettle();
      await _openRail(t);
      _working.add('chief');
      s.notifyListeners();
      await t.pump();
      expect(ring(t, 'b:chief'), RingState.working);
      _working.remove('chief');
      s.notifyListeners();
      await t.pump();
      expect(ring(t, 'b:chief'), RingState.idle);
    });

    testWidgets('a team waiting for the go-ahead, or with unread posts', (t) async {
      _size(t, _phone);
      final s = state();
      await t.pumpWidget(_app(s));
      await t.pumpAndSettle();
      await _openRail(t);
      Offices.I.approvals.add(Approval(id: 'a2', botId: 'chief', officeId: 'o1', title: 'Publish the page'));
      BotStatus.I.recompute();
      await t.pump();
      expect(ring(t, 't:o1'), RingState.waiting);
      Offices.I.approvals.clear();
      Offices.I.byId('o1')!.unread = 2;
      BotStatus.I.recompute();
      await t.pump();
      expect(ring(t, 't:o1'), RingState.done);
    });

    testWidgets('only the working ring moves, and it stands still under reduced motion', (t) async {
      _size(t, _phone);
      final s = state();
      await t.pumpWidget(_app(s, still: false));
      await t.pumpAndSettle();
      await _openRail(t);
      expect(t.hasRunningAnimations, isFalse, reason: 'idle rings are still');
      _working.add('nova');
      s.notifyListeners();
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(t.hasRunningAnimations, isTrue);
      expect(find.descendant(of: find.byKey(const ValueKey('ring-b:nova')), matching: find.byType(RotationTransition)), findsOneWidget);
      _working.remove('nova');
      s.notifyListeners();
      await t.pumpAndSettle();
      expect(t.hasRunningAnimations, isFalse);
      // Reduced motion: green, but no turning.
      await t.pumpWidget(_app(s, still: true));
      _working.add('nova');
      s.notifyListeners();
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(ring(t, 'b:nova'), RingState.working);
      final turns = t.widget<RotationTransition>(find.descendant(of: find.byKey(const ValueKey('ring-b:nova')), matching: find.byType(RotationTransition))).turns;
      expect((turns as AnimationController).isAnimating, isFalse, reason: 'the ring stands still');
      expect(turns.value, 0);
    });

    test('the status colours are four distinct theme tokens in both looks', () {
      for (final p in [Palette.light, Palette.dark]) {
        final c = {for (final s in RingState.values) StatusRing.colorFor(p, s)};
        expect(c.length, 4);
      }
    });
  });

  group('pins', () {
    testWidgets('a pinned bot moves up under the Chief', (t) async {
      _size(t, _phone);
      await t.pumpWidget(_app(state()));
      await t.pumpAndSettle();
      await _openRail(t);
      final amal = find.byKey(const ValueKey('rail-b:amal'));
      final nova = find.byKey(const ValueKey('rail-b:nova'));
      await RailPins.I.toggle('b:amal');
      await t.pumpAndSettle();
      expect(t.getTopLeft(amal).dy, lessThan(t.getTopLeft(nova).dy));
      await RailPins.I.toggle('b:amal');
      await RailPins.I.toggle('b:nova');
      await t.pumpAndSettle();
      expect(t.getTopLeft(nova).dy, lessThan(t.getTopLeft(amal).dy));
    });
  });

  // v1.13.94+161 (owner 2026-10-24): a light frosted header with who you are talking to, the rail's soft open edge,
  // the Telesia mark at the rail's foot, and the floating frosted composer.
  group('header, rail edge and floating composer', () {
    testWidgets('the header shows the active bot (small face in its ring + name) in a floating pill, and swaps in place', (t) async {
      _size(t, _phone);
      await t.pumpWidget(_app(state()));
      await t.pumpAndSettle();
      final header = find.byKey(const ValueKey('ws-header'));
      expect(header, findsOneWidget);
      // v1.13.95+165: no band. Each control and the name pill blur only their own small shape.
      final blurs = find.descendant(of: header, matching: find.byType(BackdropFilter));
      expect(blurs, findsNWidgets(4), reason: 'toggle, name pill, Call, "+"');
      for (final e in blurs.evaluate()) {
        expect((e.renderObject! as RenderBox).size.width, lessThan(_phone.width * 0.75), reason: 'no full-width band');
      }
      expect(find.descendant(of: header, matching: find.byKey(const ValueKey('ws-who-pill'))), findsOneWidget);
      expect(find.descendant(of: header, matching: find.byKey(const ValueKey('ws-header-name'))), findsOneWidget);
      expect(t.widget<Text>(find.byKey(const ValueKey('ws-header-name'))).data, 'Chief');
      expect(find.byKey(const ValueKey('ws-head-ring-b:chief')), findsOneWidget);
      // The rail toggle, Call and "+" live in the header.
      for (final k in ['ws-rail', 'ws-call', 'ws-plus']) {
        expect(find.descendant(of: header, matching: find.byKey(ValueKey(k))), findsOneWidget, reason: k);
      }
      // Its height is the chat's top inset (safe area + controls), so the list scrolls behind it.
      expect(t.getSize(header).height, closeTo(24 + 56, 0.5));
      await _openRail(t);
      await t.tap(find.byKey(const ValueKey('rail-b:nova')));
      await t.pumpAndSettle();
      expect(t.widget<Text>(find.byKey(const ValueKey('ws-header-name'))).data, 'Nova');
      expect(find.byKey(const ValueKey('ws-head-ring-b:nova')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('rail-t:o1')));
      await t.pumpAndSettle();
      expect(t.widget<Text>(find.byKey(const ValueKey('ws-header-name'))).data, 'Launch team');
      expect(t.takeException(), isNull);
    });

    testWidgets('the header swap cross-fades without exceptions (motion on), right to left too', (t) async {
      _size(t, _phone);
      await t.pumpWidget(_app(state(), still: false, dir: TextDirection.rtl));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('ws-rail')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('rail-b:nova')));
      for (var i = 0; i < 6; i++) {
        await t.pump(const Duration(milliseconds: 40));
        expect(t.takeException(), isNull);
      }
      await t.pumpAndSettle();
      expect(t.widget<Text>(find.byKey(const ValueKey('ws-header-name'))).data, 'Nova');
      // RTL: the name sits on the right half, next to the toggle.
      expect(t.getCenter(find.byKey(const ValueKey('ws-header-name'))).dx, greaterThan(_phone.width / 2));
    });

    test('the rail is rounded on its open side only, mirrored in right to left; its width is unchanged', () {
      final ltr = railEdge(TextDirection.ltr), rtl = railEdge(TextDirection.rtl);
      expect(ltr.topRight.x, greaterThan(0));
      expect(ltr.bottomRight.x, greaterThan(0));
      expect(ltr.topLeft, Radius.zero);
      expect(rtl.topLeft.x, greaterThan(0));
      expect(rtl.topRight, Radius.zero);
      expect(Lux.railWidth, 84);
    });

    testWidgets('the rail keeps its sizes and its foot; the small "+" became the Telesia mark', (t) async {
      _size(t, _phone);
      await t.pumpWidget(_app(state()));
      await t.pumpAndSettle();
      await _openRail(t);
      expect(find.byKey(const ValueKey('rail-add')), findsNothing);
      final mark = find.byKey(const ValueKey('rail-telesia'));
      expect(mark, findsOneWidget);
      final sem = t.ensureSemantics();
      expect(find.bySemanticsLabel('Back to Telesia'), findsOneWidget);
      sem.dispose();
      expect(find.byKey(const ValueKey('rail-new-bot')), findsOneWidget);
      expect(find.byKey(const ValueKey('rail-store')), findsOneWidget);
      expect(find.byKey(const ValueKey('rail-edge')), findsOneWidget);
      expect(t.getSize(find.byKey(const ValueKey('rail-edge'))).width, Lux.railWidth);
    });

    testWidgets('the Telesia mark goes back to the main chat', (t) async {
      _size(t, _phone);
      final s = state();
      await t.pumpWidget(_app(s, home: Builder(
        builder: (c) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const BotsWorkspace())),
              child: const Text('main chat'),
            ),
          ),
        ),
      )));
      await t.tap(find.text('main chat'));
      await t.pumpAndSettle();
      await _openRail(t);
      await t.tap(find.byKey(const ValueKey('rail-telesia')));
      await t.pumpAndSettle();
      expect(find.byType(BotsWorkspace), findsNothing);
      expect(find.text('main chat'), findsOneWidget);
      expect(s.currentId, isNull, reason: 'back on the chat it was opened over');
    });

    testWidgets('the composer floats: "+", the field and the mic each have their own frosted blur, no strip', (t) async {
      _size(t, _phone);
      await t.pumpWidget(_app(state()));
      await t.pumpAndSettle();
      for (final k in ['composer-plus', 'composer-field', 'composer-trailing']) {
        final piece = find.byKey(ValueKey(k));
        expect(piece, findsOneWidget, reason: k);
        expect(find.descendant(of: piece, matching: find.byType(BackdropFilter)), findsOneWidget, reason: k);
      }
      // The footer floats over the chat: the conversation area reaches the bottom of the screen behind it.
      final footer = find.byKey(const ValueKey('chat-footer'));
      expect(footer, findsOneWidget);
      expect(t.getBottomLeft(footer).dy, _phone.height);
    });

    testWidgets('the newest message rests fully above the floating composer', (t) async {
      _size(t, _phone);
      // Scroll offsets are kept per chat for the app run; start this chat at its newest message.
      ChatList.offsets.clear();
      _chats['conv-chief'] = [
        for (var i = 0; i < 31; i++) ChatMessage(id: 'm$i', role: i.isEven ? 'user' : 'assistant', content: 'Line $i of the chat.'),
      ];
      await t.pumpWidget(_app(state()));
      await t.pumpAndSettle();
      final footerTop = t.getTopLeft(find.byKey(const ValueKey('chat-footer'))).dy;
      expect(t.getBottomLeft(find.byKey(const ValueKey('user-bubble-m30'))).dy, lessThanOrEqualTo(footerTop));
      // Both edges of the list fade softly.
      expect(find.byKey(const ValueKey('chat-edge-fade')), findsOneWidget);
    });

    testWidgets('a team chat has the floating frosted composer too', (t) async {
      _size(t, _phone);
      await t.pumpWidget(_app(state(), home: const OfficeScreen(officeId: 'o1')));
      await t.pumpAndSettle();
      final field = find.byKey(const ValueKey('team-composer-field'));
      expect(field, findsOneWidget);
      expect(find.descendant(of: field, matching: find.byType(BackdropFilter)), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-footer')), findsOneWidget);
    });

    testWidgets('the keyboard lifts the floating composer with it', (t) async {
      _size(t, _phone);
      await t.pumpWidget(_app(state(), keyboard: 300));
      await t.pumpAndSettle();
      expect(t.getBottomLeft(find.byKey(const ValueKey('chat-footer'))).dy, closeTo(_phone.height - 300, 1));
    });
  });

  // v1.13.95+165 (owner: "glitchy open/close", "header too big and solid").
  group('rail motion and floating header (v1.13.95+165)', () {
    testWidgets('the blur never sits inside a fade; only the rail contents fade', (t) async {
      _size(t, _phone);
      await t.pumpWidget(_app(state(), still: false));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('ws-rail')));
      await t.pump(const Duration(milliseconds: 60));
      final edge = find.byKey(const ValueKey('rail-edge'));
      final blur = find.descendant(of: edge, matching: find.byType(BackdropFilter));
      expect(blur, findsOneWidget);
      final slide = find.byKey(const ValueKey('rail-slide'));
      for (final type in [FadeTransition, Opacity]) {
        final above = find.ancestor(of: blur, matching: find.byType(type)).evaluate().toSet();
        final inRail = find.descendant(of: slide, matching: find.byType(type)).evaluate().toSet();
        expect(above.intersection(inRail), isEmpty, reason: 'a backdrop blur under a fade shows no blur, then pops in ($type)');
      }
      expect(find.descendant(of: blur, matching: find.byKey(const ValueKey('rail-content-fade'))), findsOneWidget);
      // The moving picture is cached: the repaint boundary is inside the slide.
      expect(find.descendant(of: find.byKey(const ValueKey('rail-slide')), matching: find.byType(RepaintBoundary)), findsWidgets);
      await t.pumpAndSettle();
    });

    testWidgets('opening and folding never rebuilds or relays out the chat', (t) async {
      _size(t, _phone);
      await t.pumpWidget(_app(state(), still: false));
      await t.pumpAndSettle();
      final frame = t.element(find.byType(FloatingChatFrame));
      final before = t.getRect(find.byType(Composer));
      var rebuilt = 0;
      debugOnRebuildDirtyWidget = (e, _) {
        if (e == frame) rebuilt++;
      };
      addTearDown(() => debugOnRebuildDirtyWidget = null);
      await t.tap(find.byKey(const ValueKey('ws-rail')));
      for (var i = 0; i < 12; i++) {
        await t.pump(const Duration(milliseconds: 30));
        expect(t.getRect(find.byType(Composer)), before);
      }
      await t.tap(find.byKey(const ValueKey('ws-rail')));
      await t.pumpAndSettle();
      expect(rebuilt, 0, reason: 'the rail flag is a notifier: only the rail layer, the toggle and the Back guard follow it');
      expect(t.element(find.byType(FloatingChatFrame)), same(frame));
    });

    testWidgets('a toggle mid-flight turns around smoothly (no jump), and settles', (t) async {
      _size(t, _phone);
      await t.pumpWidget(_app(state(), still: false));
      await t.pumpAndSettle();
      final edge = find.byKey(const ValueKey('rail-edge'));
      await t.tap(find.byKey(const ValueKey('ws-rail')));
      await t.pump(const Duration(milliseconds: 16));
      await t.pump(const Duration(milliseconds: 90));
      var last = t.getTopLeft(edge).dx;
      await t.tap(find.byKey(const ValueKey('ws-rail')));
      for (var i = 0; i < 20; i++) {
        await t.pump(const Duration(milliseconds: 16));
        if (edge.evaluate().isEmpty || find.byKey(const ValueKey('rail-edge'), skipOffstage: true).evaluate().isEmpty) break;
        final x = t.getTopLeft(edge).dx;
        expect((x - last).abs(), lessThan(Lux.railWidth / 2), reason: 'frame $i jumped from $last to $x');
        expect(x, lessThanOrEqualTo(last + 0.5), reason: 'folding only moves the rail out');
        last = x;
      }
      await t.pumpAndSettle();
      expect(_ws(t).railOpen, isFalse);
      expect(t.hasRunningAnimations, isFalse);
      expect(find.byKey(const ValueKey('rail-b:nova')), findsNothing);
    });

    testWidgets('reduced motion: the rail appears and goes at once', (t) async {
      _size(t, _phone);
      await t.pumpWidget(_app(state(), still: true));
      await t.pumpAndSettle();
      // One frame: fully open (the tap's ink ripple may still run; the rail itself does not move).
      await t.tap(find.byKey(const ValueKey('ws-rail')));
      await t.pump();
      expect(_ws(t).railOpen, isTrue);
      expect(t.getTopLeft(find.byKey(const ValueKey('rail-edge'))).dx, 0);
      expect(find.byKey(const ValueKey('rail-b:nova')), findsOneWidget);
      // One frame: gone.
      await t.tap(find.byKey(const ValueKey('ws-rail')));
      await t.pump();
      expect(find.byKey(const ValueKey('rail-b:nova')), findsNothing);
    });

    testWidgets('right to left: the rail slides in from the right edge', (t) async {
      _size(t, _phone);
      await t.pumpWidget(_app(state(), still: false, dir: TextDirection.rtl));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('ws-rail')));
      await t.pump(const Duration(milliseconds: 16));
      await t.pump(const Duration(milliseconds: 60));
      final mid = t.getTopLeft(find.byKey(const ValueKey('rail-edge'))).dx;
      expect(mid, greaterThan(_phone.width - Lux.railWidth));
      await t.pumpAndSettle();
      expect(t.getTopLeft(find.byKey(const ValueKey('rail-edge'))).dx, closeTo(_phone.width - Lux.railWidth, 0.5));
    });

    testWidgets('the keyboard going down does not fold a rail you just opened; coming up does', (t) async {
      _size(t, _phone);
      final s = state();
      await t.pumpWidget(_app(s, keyboard: 300));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('ws-rail')));
      // The keyboard slides down over a few frames while the rail opens.
      for (final k in [240.0, 160.0, 80.0, 0.0]) {
        await t.pumpWidget(_app(s, keyboard: k));
        await t.pump();
      }
      await t.pumpAndSettle();
      expect(_ws(t).railOpen, isTrue, reason: 'it used to snap shut while the keyboard was still going down');
      await t.pumpWidget(_app(s, keyboard: 120));
      await t.pumpAndSettle();
      expect(_ws(t).railOpen, isFalse);
    });

    testWidgets('a team chat gets the same floating header: pill with the team face, no band', (t) async {
      _size(t, _phone);
      await t.pumpWidget(_app(state(), home: const OfficeScreen(officeId: 'o1')));
      await t.pumpAndSettle();
      final header = find.byKey(const ValueKey('ws-header'));
      expect(find.descendant(of: header, matching: find.byKey(const ValueKey('ws-who-pill'))), findsOneWidget);
      expect(find.descendant(of: header, matching: find.byType(TeamFace)), findsOneWidget);
      expect(find.descendant(of: header, matching: find.byKey(const ValueKey('ws-call'))), findsNothing);
      expect(t.getSize(header).height, closeTo(24 + 56, 0.5));
      for (final e in find.descendant(of: header, matching: find.byType(BackdropFilter)).evaluate()) {
        expect((e.renderObject! as RenderBox).size.width, lessThan(_phone.width * 0.75));
      }
      // The face in the pill is small, with its tiny ring.
      expect(t.getSize(find.descendant(of: header, matching: find.byType(TeamFace))).width, lessThanOrEqualTo(WorkspaceHeader.faceSize + 0.5));
    });
  });
}
