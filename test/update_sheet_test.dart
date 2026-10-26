import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agent/services/update_logic.dart';
import 'package:agent/theme.dart';
import 'package:agent/widgets/update_window.dart';

// The update sheet (fix/app-updater): every state on a small and a large phone, light and dark, the three app
// languages, reduced motion, and the "What's new" sheet.

const _notes = 'Downloads now continue where they stopped, clearer messages when they cannot, and the update is '
    'checked before it installs.';

Release _rel({DateTime? requiredAt}) => Release(
      id: 'r175',
      versionCode: 175,
      versionName: '1.13.105',
      notes: _notes,
      parts: const [ReleasePart('android/175/part-00.bin', 41943040), ReleasePart('android/175/part-01.bin', 30641955)],
      sizeBytes: 72584995,
      sha256: 'a' * 64,
      requiredAt: requiredAt,
    );

UpdateState _st(UpdatePhase ph, {int bytes = 0, UpdateIssue issue = UpdateIssue.none, StopReason reason = StopReason.none}) =>
    UpdateState(phase: ph, releaseCode: 175, bytes: bytes, total: 72584995, issue: issue, reason: reason);

final _cases = <String, UpdateSheetData>{
  'available': UpdateSheetData(release: _rel()),
  'required': UpdateSheetData(release: _rel(requiredAt: DateTime.utc(2026, 10, 1)), forced: true),
  'downloading': UpdateSheetData(release: _rel(), state: _st(UpdatePhase.downloading, bytes: 29800000)),
  'waiting_network': UpdateSheetData(release: _rel(), state: _st(UpdatePhase.downloading, bytes: 29800000, reason: StopReason.waitingNetwork)),
  'verifying': UpdateSheetData(release: _rel(), state: _st(UpdatePhase.verifying, bytes: 72584995)),
  'ready': UpdateSheetData(release: _rel(), state: _st(UpdatePhase.downloaded, bytes: 72584995)),
  'needs_permission': UpdateSheetData(release: _rel(), state: _st(UpdatePhase.downloaded, issue: UpdateIssue.needsPermission)),
  'installing': UpdateSheetData(release: _rel(), state: _st(UpdatePhase.installing)),
  'low_storage': UpdateSheetData(
      release: _rel(), state: _st(UpdatePhase.cancelled, issue: UpdateIssue.failed, reason: StopReason.lowStorage), neededBytes: 145169990),
  'server': UpdateSheetData(release: _rel(), state: _st(UpdatePhase.cancelled, bytes: 41943040, issue: UpdateIssue.failed, reason: StopReason.server)),
  'bad_file': UpdateSheetData(release: _rel(), state: _st(UpdatePhase.cancelled, issue: UpdateIssue.badFile)),
  'bad_signature': UpdateSheetData(release: _rel(), state: _st(UpdatePhase.cancelled, issue: UpdateIssue.badSignature)),
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

final _calls = <String>[];

Future<void> _pump(WidgetTester tester, UpdateSheetData data,
    {double width = 430, bool dark = false, String lang = 'en', bool still = false, bool laterAllowed = true}) async {
  tester.view.devicePixelRatio = 2.0;
  tester.view.physicalSize = Size(width * 2, (width < 360 ? 640 : 932) * 2);
  addTearDown(tester.view.reset);
  _calls.clear();
  await tester.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildTheme(dark ? Brightness.dark : Brightness.light),
    home: MediaQuery(
      data: MediaQueryData(size: Size(width, width < 360 ? 640 : 932), disableAnimations: still),
      child: Directionality(
        textDirection: lang == 'ar' ? TextDirection.rtl : TextDirection.ltr,
        child: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: UpdateSheetView(
              t: UpdateText(lang),
              data: data,
              onUpdate: () => _calls.add('update'),
              onLater: data.forced || !laterAllowed ? null : () => _calls.add('later'),
              onCancel: () => _calls.add('cancel'),
              onRetry: () => _calls.add('retry'),
              onInstall: () => _calls.add('install'),
              onOpenSettings: () => _calls.add('settings'),
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 400));
}

String _allText(WidgetTester tester) => tester.widgetList<Text>(find.byType(Text)).map((t) => t.data ?? t.textSpan?.toPlainText() ?? '').join('\n');

void main() {
  setUpAll(_loadFonts);

  for (final width in [320.0, 430.0]) {
    for (final dark in [false, true]) {
      for (final e in _cases.entries) {
        testWidgets('${e.key} at ${width.toInt()} dp ${dark ? 'dark' : 'light'}: fits, plain words, at most one primary', (tester) async {
          await _pump(tester, e.value, width: width, dark: dark);
          expect(tester.takeException(), isNull);
          final text = _allText(tester);
          for (final bad in ['android/', 'https://', 'sha256', 'aaaaaaaa', 'r175', 'APK', 'Exception', 'null', 'DownloadManager']) {
            expect(text.contains(bad), isFalse, reason: '"$bad" must not show');
          }
          expect(find.byType(FilledButton).evaluate().length, lessThanOrEqualTo(1));
          expect(find.text('Version 1.13.105 · 69.2 MB'), findsOneWidget); // version and size, always
        });
      }
    }
  }

  testWidgets('available: logo, notes, Update now and Later', (tester) async {
    await _pump(tester, _cases['available']!);
    expect(find.text('A new version of SubMac'), findsOneWidget);
    expect(find.byKey(const ValueKey('upd_notes')), findsOneWidget);
    await tester.tap(find.text('Update now'));
    await tester.tap(find.text('Later'));
    expect(_calls, ['update', 'later']);
  });

  testWidgets('required: no Later anywhere', (tester) async {
    await _pump(tester, _cases['required']!);
    expect(find.text('Please update SubMac'), findsOneWidget);
    expect(find.text('Later'), findsNothing);
    expect(find.text('Keep going in the background'), findsNothing);
    expect(find.text('Update now'), findsOneWidget);
    await _pump(tester, UpdateSheetData(release: _rel(requiredAt: DateTime.utc(2026, 10, 1)), forced: true, state: _st(UpdatePhase.downloading, bytes: 10)));
    expect(find.text('Keep going in the background'), findsNothing);
    expect(find.text('Cancel download'), findsOneWidget);
  });

  testWidgets('downloading: a real bar, percent, MB done of total, Cancel', (tester) async {
    await _pump(tester, _cases['downloading']!);
    final bar = tester.widget<LinearProgressIndicator>(find.byKey(const ValueKey('upd_bar')));
    expect(bar.value, closeTo(29800000 / 72584995, 1e-6));
    expect(find.text('41% · 28.4 MB of 69.2 MB'), findsOneWidget);
    await tester.tap(find.text('Cancel download'));
    expect(_calls, ['cancel']);
  });

  testWidgets('waiting for the network: says so, offers Try now', (tester) async {
    await _pump(tester, _cases['waiting_network']!);
    expect(find.textContaining('Waiting for a connection'), findsOneWidget);
    await tester.tap(find.text('Try now'));
    expect(_calls, ['retry']);
  });

  testWidgets('verifying: a checking state with no buttons', (tester) async {
    await _pump(tester, _cases['verifying']!);
    expect(find.byKey(const ValueKey('upd_verifying')), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
  });

  testWidgets('ready: Install', (tester) async {
    await _pump(tester, _cases['ready']!);
    await tester.tap(find.text('Install'));
    expect(_calls, ['install']);
  });

  testWidgets('needs permission: guidance and Open settings (deep link)', (tester) async {
    await _pump(tester, _cases['needs_permission']!);
    expect(find.byKey(const ValueKey('upd_allow')), findsOneWidget);
    expect(find.textContaining('Allow from this source'), findsOneWidget);
    expect(find.textContaining('continues by itself'), findsOneWidget);
    await tester.tap(find.text('Open settings'));
    expect(_calls, ['settings']);
  });

  testWidgets('stopped: each reason has its line and a retry', (tester) async {
    await _pump(tester, _cases['low_storage']!);
    expect(find.text('Not enough space on this phone. Free up about 138.4 MB and try again.'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await _pump(tester, _cases['server']!);
    expect(find.textContaining("update server isn't answering"), findsOneWidget);
    await tester.tap(find.text('Continue download')); // bytes are kept
    expect(_calls, ['retry']);
    await _pump(tester, _cases['bad_file']!);
    expect(find.textContaining("didn't check out"), findsOneWidget);
    await tester.tap(find.text('Download again'));
    expect(_calls, ['update']);
  });

  testWidgets('bad signature: blocked, no way to install or download', (tester) async {
    await _pump(tester, _cases['bad_signature']!);
    expect(find.textContaining("isn't signed by SubMac"), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.text('Install'), findsNothing);
  });

  testWidgets('Somali and Arabic follow the app language', (tester) async {
    await _pump(tester, _cases['available']!, lang: 'so');
    expect(find.text('Nooc cusub oo SubMac ah'), findsOneWidget);
    expect(find.text('Hadda cusboonaysii'), findsOneWidget);
    expect(find.text('Mar dambe'), findsOneWidget);
    await _pump(tester, _cases['available']!, lang: 'ar');
    expect(find.text('إصدار جديد من SubMac'), findsOneWidget);
    expect(find.text('حدّث الآن'), findsOneWidget);
    expect(find.text('لاحقًا'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _pump(tester, _cases['downloading']!, lang: 'ar', width: 320);
    expect(tester.takeException(), isNull);
  });

  test('notification words come from Dart in each language', () {
    expect(const UpdateText('en').nativeWords('1.13.105')['ready'], 'Your SubMac update is ready. Tap to install.');
    expect(const UpdateText('so').nativeWords('1.13.105')['ready'], contains('SubMac'));
    expect(const UpdateText('so').nativeWords('1.13.105')['ready'], isNot(contains('Tap to install')));
    expect(const UpdateText('ar').nativeWords('1.13.105')['downloading'], 'جارٍ تنزيل تحديث SubMac');
  });

  testWidgets('reduced motion: no spinner and no easing bar', (tester) async {
    await _pump(tester, _cases['verifying']!, still: true);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await _pump(tester, _cases['downloading']!, still: true);
    expect(find.byType(TweenAnimationBuilder<double>), findsNothing);
    await _pump(tester, _cases['downloading']!);
    expect(find.byType(TweenAnimationBuilder<double>), findsOneWidget);
  });

  testWidgets("What's new in X", (tester) async {
    var done = 0;
    tester.view.devicePixelRatio = 2.0;
    tester.view.physicalSize = const Size(640, 1280);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(body: WhatsNewView(t: const UpdateText('en'), release: _rel(), onDone: () => done++)),
    ));
    expect(find.text("What's new in 1.13.105"), findsOneWidget);
    expect(find.text(_notes), findsOneWidget);
    await tester.tap(find.text('Got it'));
    expect(done, 1);
    expect(tester.takeException(), isNull);
  });
}
