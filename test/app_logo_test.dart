import 'dart:io';

import 'package:agent/widgets/logo.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('New Telesia logo', () {
    test('launcher icon sources exist at full size', () {
      for (final f in ['assets/icon.png', 'assets/icon_ios.png', 'assets/icon_fg.png', 'assets/icon_bg.png', 'assets/icon_mono.png']) {
        final file = File(f);
        expect(file.existsSync(), isTrue, reason: f);
        final b = file.readAsBytesSync();
        // PNG IHDR: width and height at bytes 16..23
        final w = (b[16] << 24) | (b[17] << 16) | (b[18] << 8) | b[19];
        final h = (b[20] << 24) | (b[21] << 16) | (b[22] << 8) | b[23];
        expect([w, h], [1024, 1024], reason: f);
      }
    });

    test('launcher config points at the new icon files', () {
      final pub = File('pubspec.yaml').readAsStringSync();
      expect(pub, contains('image_path: assets/icon.png'));
      expect(pub, contains('image_path_ios: assets/icon_ios.png'));
      expect(pub, contains('adaptive_icon_foreground: assets/icon_fg.png'));
      expect(pub, contains('adaptive_icon_background: assets/icon_bg.png'));
      expect(pub, contains('adaptive_icon_foreground_inset: 0'));
      expect(pub, contains('adaptive_icon_monochrome: assets/icon_mono.png'));
      expect(pub, contains('- assets/brand/'));
    });

    test('the launch screen is Telesia, not the white Flutter template (light and dark, Android 12+)', () {
      for (final f in ['android_native/res/drawable/launch_background.xml', 'android_native/res/drawable-v21/launch_background.xml']) {
        final x = File(f).readAsStringSync();
        expect(x, contains('@color/telesia_launch_sky'), reason: f);
        expect(x, contains('@drawable/ic_launcher_foreground'), reason: f);
      }
      expect(File('android_native/res/values/telesia_launch.xml').readAsStringSync(), contains('telesia_launch_sky'));
      for (final f in ['android_native/res/values-v31/styles.xml', 'android_native/res/values-night-v31/styles.xml']) {
        final x = File(f).readAsStringSync();
        expect(x, contains('name="LaunchTheme"'), reason: f);
        expect(x, contains('name="NormalTheme"'), reason: f);
        expect(x, contains('android:windowSplashScreenBackground'), reason: f);
      }
    });

    test('the APK build refuses an icon set without the themed layer or the launch mark', () {
      final y = File('.github/workflows/apk.yml').readAsStringSync();
      expect(y, contains('dart run flutter_launcher_icons'));
      expect(y, contains('ic_launcher_monochrome'));
      expect(y, contains('ic_launcher_foreground'));
    });

    test('in-app marks parse as vectors', () async {
      for (final f in [AppLogo.tileAsset, AppLogo.plainAsset]) {
        final info = await vg.loadPicture(SvgStringLoader(File(f).readAsStringSync()), null);
        expect(info.size, const Size(1024, 1024), reason: f);
        info.picture.dispose();
      }
    });

    testWidgets('AppLogo draws the vector mark at the asked size', (t) async {
      await t.pumpWidget(const MaterialApp(home: Scaffold(body: Center(child: AppLogo(size: 48)))));
      final pic = find.byType(SvgPicture);
      expect(pic, findsOneWidget);
      expect(t.getSize(pic), const Size(48, 48));
      expect(find.bySemanticsLabel('Telesia'), findsOneWidget);
      expect(find.text('S'), findsNothing); // the old serif letter is gone
    });

    testWidgets('AppLogo without tile uses the plain mark', (t) async {
      await t.pumpWidget(const MaterialApp(home: Scaffold(body: Center(child: AppLogo(size: 28, tile: false)))));
      final w = t.widget<SvgPicture>(find.byType(SvgPicture));
      expect((w.bytesLoader as SvgAssetLoader).assetName, AppLogo.plainAsset);
    });
  });
}
