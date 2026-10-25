import 'dart:io';

import 'package:agent/app_state.dart';
import 'package:agent/services/bots.dart';
import 'package:agent/theme.dart';
import 'package:agent/widgets/avatar_picker.dart';
import 'package:agent/widgets/sub_avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

// SubMac's avatar set. `flutter test --update-goldens test/avatars_test.dart` also saves the whole set and the
// picker to test/goldens/avatars_*.png (not compared in CI).

Future<void> _loadFonts() async {
  final l = FontLoader('Geist');
  for (final f in ['Geist-Regular.ttf', 'Geist-Medium.ttf', 'Geist-SemiBold.ttf', 'Geist-Bold.ttf']) {
    final file = File('assets/fonts/$f');
    if (file.existsSync()) l.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
  }
  await l.load();
}

void main() {
  test('a look round-trips and bad looks are ignored', () {
    const s = AvatarSpec('ghost', 'red', 'spark');
    expect(s.look, 'av:ghost.red.spark');
    expect(AvatarSpec.parse(s.look), s);
    expect(AvatarSpec.parse('calm'), isNull);
    expect(AvatarSpec.parse('av:ghost.red'), isNull);
    expect(AvatarSpec.parse('av:cube.red.dots'), isNull);
    expect(AvatarSpec.parse(null), isNull);
  });

  test('every bot gets a stable face of its own', () {
    expect(AvatarSpec.seeded('nova'), AvatarSpec.seeded('nova'));
    final faces = {for (var i = 0; i < 40; i++) AvatarSpec.seeded('bot$i').look};
    expect(faces.length, greaterThan(30));
  });

  test('every combination draws', () {
    for (final sh in AvatarSpec.shapes) {
      for (final e in AvatarSpec.eyeKinds) {
        final svg = AvatarSpec(sh, 'ink', e).svg;
        expect(svg, startsWith('<svg'));
        expect(svg, isNot(contains('null')));
      }
    }
  });

  group('screens', () {
    setUpAll(_loadFonts);
    tearDown(() => Bots.I.bots.clear());

    testWidgets('the whole set', (t) async {
      t.view.physicalSize = const Size(840, 520);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(20),
            child: Wrap(spacing: 20, runSpacing: 20, children: [
              for (var i = 0; i < 24; i++)
                SubAvatar(
                  spec: AvatarSpec(AvatarSpec.shapes[i % 12], AvatarSpec.colors[(i * 5) % 12], AvatarSpec.eyeKinds[i % 6]),
                  size: 80,
                ),
            ]),
          ),
        ),
      ));
      await t.pumpAndSettle();
      expect(find.byType(SubAvatar), findsNWidgets(24));
      if (autoUpdateGoldenFiles) await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/avatars_set.png'));
    });

    for (final dark in [false, true]) {
      testWidgets('the picker, ${dark ? 'dark' : 'light'}', (t) async {
        t.view.physicalSize = const Size(400, 860);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        final bot = Bot(id: 'nova', name: 'Nova', role: 'Researcher', persona: '')..active = true;
        Bots.I.bots.add(bot);
        await t.pumpWidget(ChangeNotifierProvider<AppState>.value(
          value: AppState(),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: buildTheme(dark ? Brightness.dark : Brightness.light),
            home: Scaffold(
              body: Builder(builder: (c) => TextButton(onPressed: () => pickAvatar(c, bot), child: const Text('open'))),
            ),
          ),
        ));
        await t.tap(find.text('open'));
        await t.pumpAndSettle();
        expect(find.text('Use this look'), findsOneWidget);
        await t.tap(find.byTooltip('ghost'));
        await t.pumpAndSettle();
        if (autoUpdateGoldenFiles) {
          await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/avatars_picker_${dark ? 'dark' : 'light'}.png'));
        }
        await t.tap(find.text('Use this look'));
        await t.pumpAndSettle();
        expect(AvatarSpec.parse(bot.look)?.shape, 'ghost');
      });
    }
  });
}
