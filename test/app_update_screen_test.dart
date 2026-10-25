import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agent/services/update_logic.dart';
import 'package:agent/theme.dart';
import 'package:agent/widgets/update_window.dart';

// Settings > App update screen, drawn from fixed data on a small (320 dp) and a large (430 dp) phone, light and
// dark, English and Somali. `flutter test --update-goldens test/app_update_screen_test.dart` also saves screenshots
// to test/goldens/ (they are not compared in CI, so font rendering differences never turn the build red).

const _notes = 'Faster answers when the phone is busy, a calmer Settings page, and a fix for voice calls that cut '
    'long replies short. Updates now download as one file, so they finish sooner on slow connections.';

Release _rel() => Release(
      id: 'r1',
      versionCode: 86,
      versionName: '1.13.53',
      notes: _notes,
      storage: 'r2',
      fileUrl: 'https://pub-x.r2.dev/android/86-0a1b2c3d/SubMac-86.apk',
      sizeBytes: 66270000,
      sha256: 'a' * 64,
      requiredAt: DateTime.utc(2026, 11, 1, 9),
    );

final _cases = <String, AppUpdateViewData>{
  'never_checked': const AppUpdateViewData(currentName: '1.13.52'),
  'up_to_date': const AppUpdateViewData(currentName: '1.13.53', checked: true),
  'check_failed': const AppUpdateViewData(currentName: '1.13.52', checked: true, checkFailed: true),
  'available': AppUpdateViewData(currentName: '1.13.52', checked: true, release: _rel()),
  'downloading': AppUpdateViewData(
      currentName: '1.13.52',
      checked: true,
      release: _rel(),
      state: const UpdateState(phase: UpdatePhase.downloading, releaseCode: 86, bytes: 27800000, total: 66270000)),
  'ready': AppUpdateViewData(
      currentName: '1.13.52', checked: true, release: _rel(), state: const UpdateState(phase: UpdatePhase.downloaded, releaseCode: 86)),
  'needs_permission': AppUpdateViewData(
      currentName: '1.13.52',
      checked: true,
      release: _rel(),
      state: const UpdateState(phase: UpdatePhase.downloaded, releaseCode: 86, issue: UpdateIssue.needsPermission)),
  'failed': AppUpdateViewData(
      currentName: '1.13.52', checked: true, release: _rel(), state: const UpdateState(phase: UpdatePhase.cancelled, releaseCode: 86, issue: UpdateIssue.failed)),
};

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
  await load('InstrumentSerif', ['InstrumentSerif-Regular.ttf']);
}

Future<void> _pump(WidgetTester tester, {required double width, required AppUpdateViewData data, bool dark = false, bool so = false}) async {
  tester.view.devicePixelRatio = 2.0;
  tester.view.physicalSize = Size(width * 2, (width < 360 ? 640 : 932) * 2);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildTheme(dark ? Brightness.dark : Brightness.light),
    home: AppUpdateView(t: UpdateText(so), data: data, onCheck: () {}, onDownload: () {}, onCancel: () {}, onInstall: () {}, onOpenSettings: () {}),
  ));
  await tester.pump(const Duration(milliseconds: 50));
}

String _allText(WidgetTester tester) => tester.widgetList<Text>(find.byType(Text)).map((t) => t.data ?? t.textSpan?.toPlainText() ?? '').join('\n');

void main() {
  setUpAll(_loadFonts);

  for (final width in [320.0, 430.0]) {
    for (final dark in [false, true]) {
      for (final e in _cases.entries) {
        testWidgets('${e.key} at ${width.toInt()} dp ${dark ? 'dark' : 'light'}: fits, plain words, one primary button', (tester) async {
          await _pump(tester, width: width, data: e.value, dark: dark);
          expect(tester.takeException(), isNull); // no overflow
          final text = _allText(tester);
          // No raw addresses, ids, checks or jargon.
          for (final bad in ['android/', 'https://', 'r2.dev', 'sha256', 'aaaaaaaa', 'r1', 'APK', 'Exception', 'null']) {
            expect(text.contains(bad), isFalse, reason: '"$bad" must not show');
          }
          expect(find.byKey(const ValueKey('upd_status')), findsOneWidget);
          expect(tester.widgetList(find.byType(FilledButton)).length, lessThanOrEqualTo(1));
          final pngName = 'goldens/app_update_${e.key}_${width.toInt()}_${dark ? 'dark' : 'light'}.png';
          if (autoUpdateGoldenFiles) await expectLater(find.byType(AppUpdateView), matchesGoldenFile(pngName));
        });
      }
    }
  }

  testWidgets('status lines and buttons for each moment (English)', (tester) async {
    Future<String> status(AppUpdateViewData d) async {
      await _pump(tester, width: 430, data: d);
      return tester.widget<Text>(find.byKey(const ValueKey('upd_status'))).data!;
    }

    expect(await status(_cases['up_to_date']!), 'Up to date');
    expect(find.text('Check for updates'), findsOneWidget);
    expect(await status(_cases['available']!), 'Update available · 1.13.53');
    expect(find.text('Download · 63.2 MB'), findsOneWidget);
    expect(find.byKey(const ValueKey('upd_notes')), findsOneWidget);
    expect(await status(_cases['downloading']!), 'Downloading 41%');
    expect(find.byKey(const ValueKey('upd_bar')), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.text('Cancel download'), findsOneWidget);
    expect(await status(_cases['ready']!), 'Ready to install');
    expect(find.text('Install'), findsOneWidget);
    await status(_cases['needs_permission']!);
    expect(find.text('Open settings'), findsOneWidget);
    await status(_cases['failed']!);
    expect(find.text('The download stopped. You can download it again.'), findsOneWidget);
  });

  testWidgets('Somali labels', (tester) async {
    await _pump(tester, width: 320, data: _cases['available']!, so: true);
    expect(find.text('Cusboonaysiinta app-ka'), findsOneWidget);
    expect(find.text('Cusboonaysiin ayaa diyaar ah · 1.13.53'), findsOneWidget);
    expect(find.text('Soo deji · 63.2 MB'), findsOneWidget);
    expect(find.text('WAXA CUSUB'), findsOneWidget);
    await _pump(tester, width: 320, data: _cases['up_to_date']!, so: true);
    expect(find.text('Hubi cusboonaysiin'), findsOneWidget);
  });

  testWidgets('long notes wrap inside the card on a small phone', (tester) async {
    await _pump(tester, width: 320, data: _cases['available']!);
    final box = tester.getSize(find.byKey(const ValueKey('upd_notes')));
    expect(box.width, lessThanOrEqualTo(320 - 2 * 16 - 2 * 16));
    expect(box.height, greaterThan(14.5 * 1.5 * 3)); // several lines, not one clipped line
  });

  testWidgets('primary button calls the right action', (tester) async {
    var downloads = 0, checks = 0;
    tester.view.devicePixelRatio = 2.0;
    tester.view.physicalSize = const Size(860, 1864);
    addTearDown(tester.view.reset);
    Widget app(AppUpdateViewData d) => MaterialApp(
          theme: buildTheme(Brightness.light),
          home: AppUpdateView(t: const UpdateText(false), data: d, onCheck: () => checks++, onDownload: () => downloads++),
        );
    await tester.pumpWidget(app(_cases['available']!));
    await tester.tap(find.byKey(const ValueKey('upd_primary')));
    await tester.pumpWidget(app(_cases['up_to_date']!));
    await tester.tap(find.byKey(const ValueKey('upd_primary')));
    expect(downloads, 1);
    expect(checks, 1);
  });
}
