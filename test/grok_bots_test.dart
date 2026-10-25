import 'dart:io';

import 'package:agent/app_state.dart';
import 'package:agent/screens/bots_screen.dart';
import 'package:agent/screens/bots_workspace.dart';
import 'package:agent/services/bot_status.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:agent/services/bots.dart';
import 'package:agent/services/offices.dart';
import 'package:agent/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

// `flutter test --update-goldens test/grok_bots_test.dart` also saves screenshots of the Grok-style Bots screen
// (phone and wide, light and dark) to test/goldens/grok_bots_*.png. They are not compared in CI.

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
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root != null) {
    final f = File('$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
    if (f.existsSync()) await (FontLoader('MaterialIcons')..addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())))).load();
  }
}

Bot _bot(String id, String name, String role, String last) => Bot(id: id, name: name, role: role, persona: '')
  ..active = true
  ..convId = 'c$id'
  ..log('work', last);

/// RESTYLE.md Dev 2: the Chief, bot_make, and a team run's answer with its parts.
void main() {
  test('the Chief template is ready to lead', () {
    final c = BotTemplates.chief;
    expect(c.id, 'chief');
    expect(c.name, 'Chief');
    expect(c.builtIn, isFalse, reason: 'built-in bots nobody started are removed at start; the Chief must stay');
    expect(c.heartbeatHours, 0, reason: 'bots never work on their own unless the owner asks');
    expect(c.routines, isEmpty);
  });

  test('only the Chief gets bot_make', () {
    final c = BotTemplates.chief;
    final other = BotTemplates.researcher;
    bool has(Bot b) => Bots.I.definitionsFor(b).any((d) => (d['function'] as Map)['name'] == 'bot_make');
    Bots.I.chiefId = c.id;
    expect(has(c), isTrue);
    expect(has(other), isFalse);
    expect(Bots.I.definitionsFor(null).any((d) => (d['function'] as Map)['name'] == 'bot_make'), isFalse);
    Bots.I.chiefId = other.id;
    expect(has(other), isTrue);
    expect(has(c), isFalse);
    Bots.I.chiefId = '';
    expect(Bots.names, contains('bot_make'));
  });

  test('a team answer keeps every member\'s part', () {
    final p = OfficePost(id: 'p1', from: 'chief', text: 'Combined', kind: 'answer')
      ..parts.addAll([(from: 'nova', text: 'Research'), (from: 'amal', text: 'Numbers')]);
    final back = OfficePost.fromJson(p.toJson());
    expect(back.kind, 'answer');
    expect(back.parts.length, 2);
    expect(back.parts.first.from, 'nova');
    expect(back.parts.last.text, 'Numbers');
    expect(OfficePost.fromJson(OfficePost(id: 'p2', from: 'you', text: 'hi').toJson()).parts, isEmpty);
  });

  group('screenshots', () {
    setUpAll(_loadFonts);
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      BotStatus.I.reset();
      // Open a bot's chat without the network.
      BotsWorkspace.debugOpenBot = (s, b) async {
        s.currentId = b.convId;
        s.messages = [];
        s.loadingMessages = false;
        s.notifyListeners();
      };
    });
    tearDown(() {
      BotsWorkspace.debugOpenBot = null;
      BotStatus.I.reset();
      Bots.I.bots.clear();
      Offices.I.offices.clear();
      Bots.I.chiefId = '';
    });

    for (final (name, size) in [('phone', const Size(400, 860)), ('wide', const Size(1200, 800))]) {
      for (final dark in [false, true]) {
        testWidgets('Bots screen, $name, ${dark ? 'dark' : 'light'}', (t) async {
          t.view.physicalSize = size;
          t.view.devicePixelRatio = 1;
          addTearDown(t.view.reset);
          final chief = BotTemplates.chief
            ..active = true
            ..convId = 'cchief'
            ..log('work', 'Made a new bot: Idil (Sales lead).');
          Bots.I.bots.addAll([
            chief,
            _bot('nova', 'Nova', 'Researcher', 'Found 3 suppliers under \$2 a kilo, with links.'),
            _bot('amal', 'Amal', 'Bookkeeper', 'October costs are in. Rent is 41% of spend.'),
            _bot('idil', 'Idil', 'Sales lead', 'Drafted 12 follow-ups for this week.'),
          ]);
          Bots.I.chiefId = chief.id;
          final team = Office(id: 'o1', name: 'Launch team', members: ['chief', 'nova', 'idil'], chiefId: 'chief');
          Offices.I.offices.add(team);
          team.posts.add(OfficePost(id: 'p1', from: 'chief', text: 'Launch plan ready: 3 steps, first one Monday.', kind: 'answer'));
          await t.pumpWidget(ChangeNotifierProvider<AppState>.value(
            value: AppState(),
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: buildTheme(dark ? Brightness.dark : Brightness.light),
              home: MediaQuery(data: MediaQueryData(size: size, disableAnimations: true), child: const BotsScreen()),
            ),
          ));
          await t.pumpAndSettle();
          // The Bots screen is the workspace now: the Chief's chat, then the rail with every bot and team.
          expect(find.text('Chief'), findsWidgets);
          await t.tap(find.byKey(const ValueKey('ws-rail')));
          await t.pumpAndSettle();
          expect(find.text('Launch team'), findsOneWidget);
          if (autoUpdateGoldenFiles) {
            await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/grok_bots_${name}_${dark ? 'dark' : 'light'}.png'));
          }
        });
      }
    }
  });
}
