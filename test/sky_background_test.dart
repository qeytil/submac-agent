import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:math' as math;

import 'package:agent/main.dart' show SkyBackground, SkyBackgroundState, skyNightness, skyTick, skyDrift, skyCovers;

Widget _at(Size size, bool dark, {bool still = false, int hour = 12, DateTime Function()? clock}) => MediaQuery(
      data: MediaQueryData(size: size, disableAnimations: still),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: SizedBox.fromSize(size: size, child: SkyBackground(dark: dark, clock: clock ?? () => DateTime(2026, 10, 24, hour), child: const Text('page')))),
      ),
    );

void main() {
  _coverMain();
  testWidgets('a phone shows the sky upright and the page on top', (t) async {
    await t.pumpWidget(_at(const Size(390, 844), false));
    expect(find.byKey(const ValueKey('daylight-bg')), findsOneWidget);
    expect(find.byType(RotatedBox), findsNothing);
    expect(find.text('page'), findsOneWidget);
  });

  testWidgets('a wide tablet turns the sky so it fills without stretching', (t) async {
    t.view.physicalSize = const Size(1280, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(_at(const Size(1280, 800), true, hour: 23));
    expect(find.byKey(const ValueKey('night-bg')), findsOneWidget);
    expect(find.byType(RotatedBox), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('the sky drifts slowly, and stands still with reduced motion', (t) async {
    await t.pumpWidget(_at(const Size(390, 844), false));
    expect(find.byType(Transform), findsWidgets);
    await t.pump(const Duration(seconds: 5));
    expect(t.takeException(), isNull);
    await t.pumpWidget(_at(const Size(390, 844), false, still: true));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('daylight-bg')), findsOneWidget);
  });

  test('the sky follows the clock and eases through dusk and dawn', () {
    expect(skyNightness(DateTime(2026, 10, 24, 12)), 0);
    expect(skyNightness(DateTime(2026, 10, 24, 22)), 1);
    expect(skyNightness(DateTime(2026, 10, 24, 2)), 1);
    final dusk = skyNightness(DateTime(2026, 10, 24, 18));
    expect(dusk, greaterThan(0));
    expect(dusk, lessThan(1));
    expect(skyNightness(DateTime(2026, 10, 24, 18, 30)), greaterThan(dusk));
    expect(skyNightness(DateTime(2026, 10, 24, 6)), closeTo(0.5, 0.01));
  });

  testWidgets('a light-look phone at night shows the night sky', (t) async {
    await t.pumpWidget(_at(const Size(390, 844), false, hour: 23));
    expect(find.byKey(const ValueKey('night-bg')), findsOneWidget);
    expect(find.byKey(const ValueKey('daylight-bg')), findsNothing);
  });

  testWidgets('the light look veils the night sky so dark text stays readable; Ink needs no veil at night', (t) async {
    await t.pumpWidget(_at(const Size(390, 844), false, hour: 23));
    expect(find.byKey(const ValueKey('night-veil')), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(_at(const Size(390, 844), false, hour: 12));
    expect(find.byKey(const ValueKey('night-veil')), findsNothing);
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(_at(const Size(390, 844), true, hour: 23));
    expect(find.byKey(const ValueKey('night-veil')), findsNothing);
  });

  test('day 07-17, dusk 17-19, night 19-05, dawn 05-07', () {
    expect(skyNightness(DateTime(2026, 10, 24, 7)), 0);
    expect(skyNightness(DateTime(2026, 10, 24, 16, 59)), 0);
    expect(skyNightness(DateTime(2026, 10, 24, 17)), 0);
    expect(skyNightness(DateTime(2026, 10, 24, 19)), 1);
    expect(skyNightness(DateTime(2026, 10, 24, 4, 59)), 1);
    expect(skyNightness(DateTime(2026, 10, 24, 5)), 1);
  });

  testWidgets('the dark look follows the clock too: daylight by day with a night veil so light text reads', (t) async {
    await t.pumpWidget(_at(const Size(390, 844), true, hour: 12));
    expect(find.byKey(const ValueKey('daylight-bg')), findsOneWidget);
    expect(find.byKey(const ValueKey('night-bg')), findsNothing);
    expect(find.byKey(const ValueKey('day-veil')), findsOneWidget);
    expect(find.byKey(const ValueKey('night-veil')), findsNothing);
  });

  testWidgets('the sky changes while the app is open as the clock moves', (t) async {
    var now = DateTime(2026, 10, 24, 16, 50);
    for (final dark in [false, true]) {
      now = DateTime(2026, 10, 24, 16, 50);
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(_at(const Size(390, 844), dark, still: true, clock: () => now));
      final s = t.state<SkyBackgroundState>(find.byType(SkyBackground));
      expect(s.night, 0);
      now = DateTime(2026, 10, 24, 20, 5);
      await t.pump(skyTick);
      await t.pump();
      expect(s.night, 1, reason: 'dark=$dark');
      expect(find.byKey(const ValueKey('night-bg')), findsOneWidget);
      // Back to the morning: the next tick brings the day back.
      now = DateTime(2026, 10, 25, 8);
      await t.pump(skyTick);
      await t.pump();
      expect(s.night, 0);
    }
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('coming back to the app re-reads the clock at once', (t) async {
    var now = DateTime(2026, 10, 24, 12);
    await t.pumpWidget(_at(const Size(390, 844), true, still: true, clock: () => now));
    final s = t.state<SkyBackgroundState>(find.byType(SkyBackground));
    expect(s.night, 0);
    now = DateTime(2026, 10, 24, 23);
    s.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await t.pump();
    expect(s.night, 1);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('a UTC clock is read as the user\'s local time', (t) async {
    final local = DateTime(2026, 10, 24, 13);
    await t.pumpWidget(_at(const Size(390, 844), false, still: true, clock: () => local.toUtc()));
    final s = t.state<SkyBackgroundState>(find.byType(SkyBackground));
    expect(s.night, skyNightness(local));
    await t.pumpWidget(const SizedBox());
  });
}

// Owner, 2026-10-24: the sky must cover any screen "however tall and wide", with no gap at any frame of the drift and
// none after a rotation or a resize.
void _expectCovers(WidgetTester t, Size size, String key) {
  final r = t.getRect(find.byKey(ValueKey(key)));
  expect(r.left, lessThanOrEqualTo(0.01), reason: '$size left edge');
  expect(r.top, lessThanOrEqualTo(0.01), reason: '$size top edge');
  expect(r.right, greaterThanOrEqualTo(size.width - 0.01), reason: '$size right edge');
  expect(r.bottom, greaterThanOrEqualTo(size.height - 0.01), reason: '$size bottom edge');
}

void _coverMain() {
  const sizes = [
    Size(1080, 2640), // tall phone
    Size(1080, 2400),
    Size(390, 844),
    Size(1600, 2560), // tablet, upright
    Size(2560, 1600), // tablet, landscape
    Size(2208, 1768), // foldable, open
  ];
  for (final size in sizes) {
    testWidgets('the sky covers a ${size.width.toInt()}x${size.height.toInt()} screen at every frame, and after turning it', (t) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(_at(size, false));
      expect(t.widget<Image>(find.byKey(const ValueKey('daylight-bg'))).fit, BoxFit.cover);
      for (var i = 0; i < 24; i++) {
        _expectCovers(t, size, 'daylight-bg');
        await t.pump(const Duration(seconds: 40) ~/ 24);
      }
      // Turned (or resized): still covered, at once and as it keeps drifting.
      final turned = size.flipped;
      t.view.physicalSize = turned;
      await t.pumpWidget(_at(turned, false));
      for (var i = 0; i < 6; i++) {
        _expectCovers(t, turned, 'daylight-bg');
        await t.pump(const Duration(seconds: 7));
      }
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });
  }

  test('the drift never zooms less than its shift needs, at any phase', () {
    for (var i = 0; i <= 720; i++) {
      final d = skyDrift(i / 720 * 2 * math.pi);
      expect(skyCovers(d), isTrue, reason: 'phase $i: $d');
    }
  });
}
