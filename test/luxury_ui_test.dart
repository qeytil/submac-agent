import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:agent/app_state.dart';
import 'package:agent/models.dart';
import 'package:agent/screens/bots_screen.dart';
import 'package:agent/screens/bots_workspace.dart';
import 'package:agent/screens/home_screen.dart';
import 'package:agent/screens/live_screen.dart';
import 'package:agent/services/bots.dart';
import 'package:agent/services/offices.dart';
import 'package:agent/theme.dart';
import 'package:agent/ui/tokens.dart';
import 'package:agent/widgets/bot_list.dart';
import 'package:agent/widgets/chat/activity.dart';
import 'package:agent/widgets/chat/blocks.dart';
import 'package:agent/widgets/chat/document_tile.dart';
import 'package:agent/widgets/chat/entrance.dart';
import 'package:agent/widgets/chat/message_actions.dart';
import 'package:agent/widgets/composer.dart';
import 'package:agent/widgets/message_view.dart';

// Luxury UI (feature/luxury-ui): the chat's free-standing components and the Grok-style bots list.
// `flutter test --update-goldens test/luxury_ui_test.dart` also saves screenshots of the chat and the bots page
// to test/goldens/luxury_*.png (not compared in CI, so font rendering differences never turn the build red).

Future<void> _loadFonts() async {
  Future<void> load(String family, List<String> files) async {
    final l = FontLoader(family);
    for (final f in files) {
      final file = File('assets/fonts/$f');
      if (file.existsSync()) l.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
    }
    await l.load();
  }

  await load('Geist', ['Geist-Regular.ttf', 'Geist-Medium.ttf', 'Geist-SemiBold.ttf', 'Geist-Bold.ttf']);
  await load('InstrumentSerif', ['InstrumentSerif-Regular.ttf', 'InstrumentSerif-Italic.ttf']);
  await load('GeistMono', ['GeistMono-Regular.ttf', 'GeistMono-Medium.ttf']);
  // Material icons for the screenshots (from the Flutter SDK, when it is there).
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root != null) {
    final f = File('$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
    if (f.existsSync()) {
      final l = FontLoader('MaterialIcons')..addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
      await l.load();
    }
  }
}

Widget _host(Widget child, {AppState? state, bool dark = false, bool still = false, bool scroll = true}) => ChangeNotifierProvider<AppState>.value(
      value: state ?? AppState(),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(dark ? Brightness.dark : Brightness.light),
        home: MediaQuery(
          data: MediaQueryData(size: const Size(400, 860), disableAnimations: still),
          child: Scaffold(body: scroll ? SingleChildScrollView(child: child) : child),
        ),
      ),
    );

/// Opens a bot's chat in the Bots workspace without the network.
Future<void> _openNoNetwork(AppState s, Bot b) async {
  s.currentId = b.convId;
  s.messages = [];
  s.loadingMessages = false;
  s.notifyListeners();
}

Bot _bot(String id, String name, String role) => Bot(id: id, name: name, role: role, persona: '')
  ..active = true
  ..convId = 'conv-$id';

void main() {
  setUpAll(_loadFonts);

  group('blocks', () {
    test('each fenced output becomes its own kind of component', () {
      expect(blockKindOf(null), BlockKind.text);
      expect(blockKindOf('file'), BlockKind.document);
      expect(blockKindOf('photos'), BlockKind.media);
      expect(blockKindOf('summary'), BlockKind.report);
      expect(blockKindOf('graph'), BlockKind.chart);
      expect(blockKindOf('table'), BlockKind.table);
      expect(blockKindOf('plan'), BlockKind.plan);
      expect(blockKindOf('dart'), BlockKind.code);
    });

    test('the entrance stagger is short and capped', () {
      expect(Entrance.staggerFor(0), Duration.zero);
      expect(Entrance.staggerFor(1), LuxMotion.stagger);
      expect(Entrance.staggerFor(40), LuxMotion.maxStagger);
    });

    testWidgets('prose sits on the paper with no bubble', (t) async {
      await t.pumpWidget(_host(const Padding(padding: EdgeInsets.all(24), child: MessageText('Plain words, no box.'))));
      final filled = find.ancestor(
        of: find.textContaining('Plain words'),
        matching: find.byWidgetPredicate((w) => w is Container && w.decoration is BoxDecoration && (w.decoration as BoxDecoration).color != null),
      );
      expect(filled, findsNothing);
    });

    testWidgets('a reply\'s words sit in their own bubble', (t) async {
      await t.pumpWidget(_host(const Padding(padding: EdgeInsets.all(24), child: ReplyBubble(child: MessageText('Answer words.')))));
      expect(find.byKey(const ValueKey('reply-bubble')), findsOneWidget);
    });

    testWidgets('an entrance plays once and settles; reduced motion shows at once', (t) async {
      await t.pumpWidget(_host(const Entrance(child: Text('Rising'))));
      expect(t.widget<Opacity>(find.ancestor(of: find.text('Rising'), matching: find.byType(Opacity))).opacity, lessThan(0.5));
      await t.pumpAndSettle();
      expect(t.widget<Opacity>(find.ancestor(of: find.text('Rising'), matching: find.byType(Opacity))).opacity, 1);
      await t.pumpWidget(_host(const Entrance(child: Text('Still')), still: true));
      expect(t.widget<Opacity>(find.ancestor(of: find.text('Still'), matching: find.byType(Opacity))).opacity, 1);
    });

    testWidgets('a document is a tile with its type and size, no card', (t) async {
      var taps = 0;
      await t.pumpWidget(_host(DocumentTile(name: 'Quarterly report.pdf', meta: '1.2 MB', onTap: () => taps++)));
      expect(find.text('Quarterly report.pdf'), findsOneWidget);
      expect(find.text('PDF'), findsOneWidget);
      expect(find.text('1.2 MB'), findsOneWidget);
      await t.tap(find.text('Quarterly report.pdf'));
      expect(taps, 1);
    });

    testWidgets('the activity indicator is plain text only and rests under reduced motion', (t) async {
      await t.pumpWidget(_host(const StatusWord('Working', kind: ActivityKind.working), still: true));
      await t.pumpAndSettle(); // would time out if the word kept breathing
      expect(find.text('Working'), findsOneWidget);
      // No dot, icon or glyph next to it.
      expect(find.descendant(of: find.byType(StatusWord), matching: find.byType(CustomPaint)), findsNothing);
      expect(find.descendant(of: find.byType(StatusWord), matching: find.byType(Icon)), findsNothing);
    });

    testWidgets('the status word rests (does not pulse) while Telesia works', (t) async {
      // Owner (2026-10-31): the progress word no longer breathes; it says what Telesia is doing and stays still.
      await t.pumpWidget(_host(const StatusWord('Thinking')));
      await t.pumpAndSettle(); // would time out if the word kept animating
      expect(find.text('Thinking'), findsOneWidget);
      expect(find.descendant(of: find.byType(StatusWord), matching: find.byType(Breath)), findsNothing);
      expect(find.descendant(of: find.byType(StatusWord), matching: find.byType(Icon)), findsNothing);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('the live mark on a task line breathes, and rests under reduced motion', (t) async {
      // Claude-style progress: only the chat's task line asks for the living mark, and only the dot's
      // opacity moves (no Breath widget, no icon, no repaint of the word).
      await t.pumpWidget(_host(const StatusWord('Working', kind: ActivityKind.working, live: true)));
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('Working'), findsOneWidget);
      expect(find.descendant(of: find.byType(StatusWord), matching: find.byType(Breath)), findsNothing);
      expect(find.descendant(of: find.byType(StatusWord), matching: find.byType(Icon)), findsNothing);
      // Remove animations: the mark stands still (this settles; a breathing mark would time out).
      await t.pumpWidget(_host(const StatusWord('Working', kind: ActivityKind.working, live: true), still: true));
      await t.pumpAndSettle();
      expect(find.text('Working'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    });
  });

  group('messages', () {
    testWidgets('a short message of yours is set in the bold display sans, in a soft bubble', (t) async {
      final m = ChatMessage(id: 'u1', role: 'user', content: 'Plan a weekend in Zanzibar');
      await t.pumpWidget(_host(UserMessageView(message: m)));
      final text = t.widget<Text>(find.text('Plan a weekend in Zanzibar'));
      expect(text.style?.fontFamily, 'Geist');
      expect(text.style?.fontWeight, FontWeight.w600);
      final filled = find.ancestor(
        of: find.text('Plan a weekend in Zanzibar'),
        matching: find.byWidgetPredicate((w) => w is Container && w.decoration is BoxDecoration && (w.decoration as BoxDecoration).color != null),
      );
      expect(filled, findsOneWidget);
    });

    testWidgets('an answer shows no buttons until tapped; a hold opens the sheet', (t) async {
      selectedReply.value = null;
      final m = ChatMessage(id: 'a1', role: 'assistant', content: 'Here is the plan. Would you like me to book it?');
      await t.pumpWidget(_host(AssistantMessageView(message: m, toolResults: const {}, showActions: true, isLast: true)));
      await t.pumpAndSettle();
      expect(find.byTooltip('Copy'), findsNothing);
      expect(find.byTooltip('Try again'), findsNothing);
      await t.tap(find.textContaining('Here is the plan'));
      await t.pumpAndSettle();
      expect(find.byTooltip('Copy'), findsOneWidget);
      expect(find.byTooltip('Try again'), findsOneWidget);
      // Tap again: the row fades away.
      await t.tap(find.textContaining('Here is the plan'));
      await t.pumpAndSettle();
      expect(find.byTooltip('Copy'), findsNothing);
      // Hold: every action, plus replies worked out from the answer.
      await t.longPress(find.textContaining('Here is the plan'));
      await t.pumpAndSettle();
      expect(find.text('Select text'), findsOneWidget);
      expect(find.text('Share'), findsOneWidget);
      expect(find.text('Reply'), findsOneWidget);
      expect(find.text('Quick replies'), findsOneWidget);
    });

    testWidgets('a message still streaming has no actions at all', (t) async {
      selectedReply.value = null;
      final m = ChatMessage(id: 'a2', role: 'assistant', content: 'Working on it', streaming: true);
      await t.pumpWidget(_host(AssistantMessageView(message: m, toolResults: const {}, showActions: true, isLast: true)));
      await t.pump(const Duration(milliseconds: 600));
      await t.tap(find.byType(AssistantMessageView));
      await t.pump(const Duration(milliseconds: 600));
      expect(find.byTooltip('Copy'), findsNothing);
    });

    testWidgets('the action sheet runs the chosen action', (t) async {
      var copied = 0;
      await t.pumpWidget(_host(Builder(
        builder: (c) => TextButton(
          onPressed: () => showMessageActions(c, actions: [MessageAction('Copy', 'copy', () => copied++)]),
          child: const Text('open'),
        ),
      )));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      await t.tap(find.text('Copy'));
      await t.pumpAndSettle();
      expect(copied, 1);
    });
  });

  group('bots', () {
    tearDown(() {
      Bots.I.bots.clear();
      Offices.I.offices.clear();
    });

    // The bots page is the Bots workspace now (owner 2026-10-24); its own tests are in bots_workspace_test.dart.
    testWidgets('the bots page opens the workspace: a chat, a folded rail with bots and teams', (t) async {
      SharedPreferences.setMockInitialValues({});
      BotsWorkspace.debugOpenBot = _openNoNetwork;
      addTearDown(() => BotsWorkspace.debugOpenBot = null);
      final lead = _bot('b1', 'Hodan', 'Research lead');
      Bots.I.bots.addAll([lead, _bot('b2', 'Amal', 'Bookkeeper')]);
      Offices.I.offices.add(Office(id: 'o1', name: 'Launch team', members: ['b1', 'b2'], chiefId: 'b1'));
      await t.pumpWidget(_host(const BotsScreen(), scroll: false, still: true));
      await t.pumpAndSettle();
      expect(find.byType(BotsWorkspace), findsOneWidget);
      expect(find.text('Amal'), findsNothing, reason: 'the rail starts folded');
      await t.tap(find.byKey(const ValueKey('ws-rail')));
      await t.pumpAndSettle();
      expect(find.text('Hodan'), findsWidgets);
      expect(find.text('Amal'), findsOneWidget);
      expect(find.text('Launch team'), findsOneWidget);
      expect(find.text('New digital person'), findsOneWidget);
      expect(find.text('People store'), findsOneWidget);
    });
  });

  group('screenshots', () {
    // A chat composed from the real components (top bar marks, your message, the activity line, an answer
    // with a table, a document and code, the composer), and the bots page, light and dark.
    Widget chat(AppState s) {
      final user = ChatMessage(id: 'u', role: 'user', content: 'Compare three phones under \$400 for my mother');
      final answer = ChatMessage(
        id: 'a',
        role: 'assistant',
        content: 'Here are the three I would choose. All have large, bright screens and simple setups.\n\n'
            '```table\n{"title":"Phones under \$400","columns":["Phone","Price","Battery"],"rows":[["Galaxy A35","\$329","2 days"],["Pixel 8a","\$399","1.5 days"],["Moto G Power","\$249","2.5 days"]]}\n```\n\n'
            'For your mother I would pick the **Galaxy A35**: the easiest screen to read and the longest support.\n\n'
            '```python\nprices = {"A35": 329, "8a": 399, "G Power": 249}\nprint(min(prices, key=prices.get))\n```',
      );
      final second = ChatMessage(id: 'u2', role: 'user', content: 'Make a one-page summary I can print');
      return Column(children: [
        SafeArea(
          bottom: false,
          child: SizedBox(
            height: 60,
            child: Row(children: [
              const SizedBox(width: Lux.gutter - Space.x1),
              ChatWordmark(onTap: () {}),
              const Spacer(),
              BarIcon(icon: 'phone', tooltip: 'Call Telesia', onTap: () {}),
              BarIcon(icon: 'plus', tooltip: 'New chat', onTap: () {}),
              const SizedBox(width: Lux.gutter - Space.x3),
            ]),
          ),
        ),
        Expanded(
          child: ListView(padding: EdgeInsets.zero, children: [
            UserMessageView(message: user),
            AssistantMessageView(message: answer, toolResults: const {}, showActions: true, isLast: false),
            UserMessageView(message: second),
            const WorkingLine(),
          ]),
        ),
        const Composer(),
      ]);
    }

    for (final dark in [false, true]) {
      testWidgets('chat ${dark ? 'dark' : 'light'}', (t) async {
        t.view.physicalSize = const Size(1200, 2580);
        t.view.devicePixelRatio = 3;
        addTearDown(t.view.reset);
        final s = AppState();
        await t.pumpWidget(ChangeNotifierProvider<AppState>.value(
          value: s,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: buildTheme(dark ? Brightness.dark : Brightness.light),
            home: MediaQuery(data: const MediaQueryData(size: Size(400, 860), disableAnimations: true), child: Scaffold(body: chat(s))),
          ),
        ));
        await t.pump(const Duration(milliseconds: 500));
        await t.pump(const Duration(milliseconds: 500));
        // No app name in the header.
        expect(find.text('Telesia'), findsNothing);
        if (autoUpdateGoldenFiles) await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/v2_chat_${dark ? 'dark' : 'light'}.png'));
        await t.pumpWidget(const SizedBox());
      });

      testWidgets('bots ${dark ? 'dark' : 'light'}', (t) async {
        t.view.physicalSize = const Size(1200, 2580);
        t.view.devicePixelRatio = 3;
        addTearDown(t.view.reset);
        final lead = _bot('b1', 'Hodan', 'Research lead');
        Bots.I.bots.addAll([lead, _bot('b2', 'Amal', 'Bookkeeper'), _bot('b3', 'Rank', 'Website and search')]);
        Offices.I.offices.add(Office(id: 'o1', name: 'Launch team', members: ['b1', 'b2', 'b3'], chiefId: 'b1'));
        addTearDown(() {
          Bots.I.bots.clear();
          Offices.I.offices.clear();
        });
        BotsWorkspace.debugOpenBot = _openNoNetwork;
        addTearDown(() => BotsWorkspace.debugOpenBot = null);
        await t.pumpWidget(_host(const BotsScreen(), dark: dark, still: true, scroll: false));
        await t.pumpAndSettle();
        await t.tap(find.byKey(const ValueKey('ws-rail')));
        await t.pumpAndSettle();
        if (autoUpdateGoldenFiles) await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/v2_bots_${dark ? 'dark' : 'light'}.png'));
        await t.pumpWidget(const SizedBox());
      });
    }
  });

  group('call', () {
    Widget call({Bot? bot, CallPhase phase = CallPhase.listening, String status = 'Listening'}) => CallView(
          bot: bot,
          status: status,
          phase: phase,
          level: 0.3,
          note: '12 min left today',
          captions: const [(true, 'What is on my calendar tomorrow?'), (false, 'Two meetings: design review at 10 and lunch with Amal at 1.')],
          onFloat: () {},
          onCaptions: () {},
          onMute: () {},
          onRetry: () {},
          onEnd: () {},
        );

    testWidgets('a Telesia call and a bot call look different, with plain controls', (t) async {
      await t.pumpWidget(_host(call(), still: true, scroll: false));
      await t.pump();
      expect(find.byKey(const ValueKey('telesia-call')), findsOneWidget);
      expect(find.text('Telesia'), findsOneWidget);
      expect(find.text('Mute'), findsOneWidget);
      expect(find.text('End'), findsOneWidget);
      // No Material buttons and no filled or outlined controls.
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(OutlinedButton), findsNothing);
      await t.pumpWidget(_host(call(bot: _bot('b1', 'Hodan', 'Research lead'), phase: CallPhase.speaking, status: 'Speaking'), still: true, scroll: false));
      await t.pump();
      expect(find.byKey(const ValueKey('bot-call')), findsOneWidget);
      expect(find.text('Hodan'), findsOneWidget);
      expect(find.text('Research lead'), findsOneWidget);
      expect(find.text('Speaking'), findsOneWidget);
    });

    testWidgets('an ended call offers Again', (t) async {
      var again = 0;
      await t.pumpWidget(_host(
          CallView(
            bot: null,
            status: 'Call ended',
            phase: CallPhase.ended,
            canRetry: true,
            onFloat: () {},
            onCaptions: () {},
            onMute: () {},
            onRetry: () => again++,
            onEnd: () {},
          ),
          still: true,
          scroll: false));
      await t.tap(find.text('Again'));
      expect(again, 1);
    });

    for (final dark in [false, true]) {
      for (final botCall in [false, true]) {
        testWidgets('call screenshot ${botCall ? 'bot' : 'telesia'} ${dark ? 'dark' : 'light'}', (t) async {
          t.view.physicalSize = const Size(1200, 2580);
          t.view.devicePixelRatio = 3;
          addTearDown(t.view.reset);
          await t.pumpWidget(_host(call(bot: botCall ? _bot('b1', 'Hodan', 'Research lead') : null), dark: dark, still: true, scroll: false));
          await t.pump(const Duration(milliseconds: 500));
          if (autoUpdateGoldenFiles) {
            await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/v2_call_${botCall ? 'bot' : 'telesia'}_${dark ? 'dark' : 'light'}.png'));
          }
          await t.pumpWidget(const SizedBox());
        });
      }
    }
  });

  group('rules', () {
    test('motion comes from one set', () {
      expect(LuxMotion.settle, same(SubMotion.settle));
      expect(SubMotion.staggerFor(100), SubMotion.maxStagger);
      expect(SubMotion.sendScale, greaterThanOrEqualTo(0.97));
    });

    test('display text is a bold sans, never the serif', () {
      final d = Brand.display(size: 32);
      expect(d.fontFamily, 'Geist');
      expect(d.fontWeight, FontWeight.w600);
      expect(Brand.serif(size: 32).fontFamily, 'Geist');
    });

    testWidgets('the composer has no box or outline, and the mic only dictates', (t) async {
      await t.pumpWidget(_host(const Composer(), scroll: false));
      await t.pump();
      final boxed = find.descendant(
        of: find.byType(Composer),
        matching: find.byWidgetPredicate((w) =>
            (w is Container && w.decoration is BoxDecoration && (w.decoration as BoxDecoration).border != null) ||
            (w is AnimatedContainer && w.decoration is BoxDecoration && (w.decoration as BoxDecoration).border != null)),
      );
      expect(boxed, findsNothing);
      expect(find.byTooltip('Speak'), findsOneWidget);
      final mic = find.ancestor(of: find.byTooltip('Speak'), matching: find.byType(InkResponse));
      if (mic.evaluate().isNotEmpty) {
        expect(t.widget<InkResponse>(mic.first).onLongPress, isNull);
      }
    });
  });

  test('drawer helpers', () {
    expect(showTeams(), isA<bool>());
  });
}
