import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:agent/main.dart' show SkyBackground, SkyBackgroundState, skyTick, skyStep;
import 'package:agent/theme.dart';
import 'package:agent/ui/sky.dart';

Widget _at(Size size, bool dark, {bool still = false, int hour = 12, DateTime Function()? clock}) => MediaQuery(
      data: MediaQueryData(size: size, disableAnimations: still),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: SizedBox.fromSize(size: size, child: SkyBackground(dark: dark, clock: clock ?? () => DateTime(2026, 10, 24, hour), child: const Text('page')))),
      ),
    );

DateTime _t(int h, [int m = 0]) => DateTime(2026, 10, 24, h, m);

/// Perceived brightness (0..1) of a colour, for "warmer / brighter than" checks.
double _warmth(Color c) => c.r - c.b;

void main() {
  _coverMain();

  // ---------------------------------------------------------------- phases and colours (owner 2026-10-26: live sky)
  test('phases at key times: night, blue hour, sunrise, golden hours, day, sunset, dusk', () {
    expect(skyPhaseAt(_t(2)), SkyPhase.night);
    expect(skyPhaseAt(_t(5, 30)), SkyPhase.blueHour);
    expect(skyPhaseAt(_t(6, 30)), SkyPhase.sunrise);
    expect(skyPhaseAt(_t(7, 30)), SkyPhase.goldenMorning);
    expect(skyPhaseAt(_t(12)), SkyPhase.day);
    expect(skyPhaseAt(_t(18)), SkyPhase.goldenEvening);
    expect(skyPhaseAt(_t(19)), SkyPhase.sunset);
    expect(skyPhaseAt(_t(20)), SkyPhase.dusk);
    expect(skyPhaseAt(_t(22)), SkyPhase.night);
  });

  test('colours at key times: deep indigo night with stars, blue day, orange sunrise and sunset, warm golden hours', () {
    final night = skyAt(_t(1));
    expect(night.stars, 1);
    expect(night.light, 0);
    expect(night.top.b, greaterThan(night.top.r), reason: 'night is blue, not grey');
    expect(contrastRatio(night.top, Colors.black), lessThan(1.3), reason: 'deep night');

    final noon = skyAt(_t(12));
    expect(noon.light, 1);
    expect(noon.stars, 0);
    expect(noon.top.b, greaterThan(noon.top.r + 0.2), reason: 'clear blue day');

    final blue = skyAt(_t(5, 30));
    expect(blue.top.b, greaterThan(blue.top.r));
    expect(blue.light, greaterThan(0));
    expect(blue.light, lessThan(0.3));

    // Sunrise and sunset horizons are orange (red well above blue), golden hours warm too.
    for (final t in [_t(6, 40), _t(18, 45), _t(19, 5)]) {
      final h = skyAt(t).horizon;
      expect(_warmth(h), greaterThan(0.35), reason: 'orange horizon at $t: $h');
    }
    for (final t in [_t(7, 30), _t(18)]) {
      final s = skyAt(t);
      expect(_warmth(s.horizon), greaterThan(0.15), reason: 'golden horizon at $t');
      expect(s.glowStrength, greaterThan(noon.glowStrength), reason: 'golden hours glow more than noon');
    }
    expect(_warmth(skyAt(_t(12)).horizon), lessThan(0), reason: 'the day horizon is pale blue, not golden');
  });

  test('the sky eases minute by minute with no jumps all day (continuity)', () {
    var prev = skyAtMinute(0);
    for (var m = 1; m <= 24 * 60 * 4; m++) {
      final cur = skyAtMinute(m / 4); // every 15 seconds
      for (var i = 0; i < 3; i++) {
        final a = prev.stops[i], b = cur.stops[i];
        final d = [(a.r - b.r).abs(), (a.g - b.g).abs(), (a.b - b.b).abs()].reduce((x, y) => x > y ? x : y);
        expect(d, lessThan(0.012), reason: 'stop $i jumps at minute ${m / 4}');
      }
      expect((prev.light - cur.light).abs(), lessThan(0.01));
      expect((prev.stars - cur.stars).abs(), lessThan(0.01));
      prev = cur;
    }
    // Midnight wraps without a seam.
    expect(skyAtMinute(24 * 60 - 0.01).top.toARGB32(), skyAtMinute(0).top.toARGB32());
  });

  test('the Auto look switches when the sky is half lit: light at 07:00 into golden morning, dark at 19:00 into sunset', () {
    final at7 = skyAt(_t(7)).light, at19 = skyAt(_t(19)).light;
    expect(at7, inInclusiveRange(0.5, 0.85));
    expect(at19, inInclusiveRange(0.25, 0.6));
    expect(skyAt(_t(6)).light, lessThan(at7));
    expect(skyAt(_t(20)).light, lessThan(at19));
  });

  test('the sun crosses the sky with the time and sets; the moon shows at night', () {
    expect(sunPosition(_t(3)), isNull);
    expect(sunPosition(_t(22)), isNull);
    final morning = sunPosition(_t(7))!, noon = sunPosition(_t(12, 52))!, evening = sunPosition(_t(19))!;
    expect(morning.dx, lessThan(noon.dx));
    expect(noon.dx, lessThan(evening.dx));
    expect(noon.dy, lessThan(morning.dy), reason: 'higher at midday');
    expect(noon.dy, lessThan(evening.dy));
    expect(moonPosition(_t(12)), isNull);
    expect(moonPosition(_t(23)), isNotNull);
    expect(moonPosition(_t(2)), isNotNull);
  });

  test('text stays readable on the sky in both looks at every minute (4.5:1 over the veil)', () {
    for (var m = 0; m < 24 * 60; m += 5) {
      final look = skyAtMinute(m.toDouble());
      final lv = lightVeilFor(look), dv = darkVeilFor(look);
      for (final s in skySurfaces(look)) {
        expect(contrastRatio(Palette.light.text, Color.lerp(s, Palette.light.bg, lv)!), greaterThanOrEqualTo(4.5), reason: 'light look at minute $m');
        expect(contrastRatio(Palette.dark.text, Color.lerp(s, Palette.dark.bg, dv)!), greaterThanOrEqualTo(4.5), reason: 'dark look at minute $m');
      }
    }
  });

  // ---------------------------------------------------------------- the widget
  testWidgets('a phone shows the drawn sky and the page on top (no pictures)', (t) async {
    await t.pumpWidget(_at(const Size(390, 844), false));
    expect(find.byKey(const ValueKey('sky-paint')), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(find.text('page'), findsOneWidget);
  });

  testWidgets('the light look veils a night sky; Ink veils the bright day', (t) async {
    await t.pumpWidget(_at(const Size(390, 844), false, hour: 23));
    expect(find.byKey(const ValueKey('night-veil')), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(_at(const Size(390, 844), true, hour: 12));
    expect(find.byKey(const ValueKey('day-veil')), findsOneWidget);
    expect(find.byKey(const ValueKey('night-veil')), findsNothing);
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(_at(const Size(390, 844), true, hour: 23));
    expect(find.byKey(const ValueKey('night-veil')), findsNothing);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('low repaint rate: a few paints a minute while drifting, not every frame', (t) async {
    await t.pumpWidget(_at(const Size(390, 844), false));
    await t.pump();
    final s = t.state<SkyBackgroundState>(find.byType(SkyBackground));
    expect(s.driftRunning, isTrue);
    final before = SkyPainter.paints;
    // A minute of frames at 60 fps.
    for (var i = 0; i < 60 * 60; i++) {
      await t.pump(const Duration(microseconds: 16667));
    }
    final paints = SkyPainter.paints - before;
    expect(paints, lessThanOrEqualTo(60 ~/ skyStep.inSeconds + 2), reason: '$paints paints in a minute');
    expect(paints, greaterThanOrEqualTo(60 ~/ skyStep.inSeconds - 1), reason: 'it still moves');
    expect(t.binding.hasScheduledFrame, isFalse, reason: 'no frame is waiting between steps');
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('reduce motion: a still sky for the current time, no drift, still following the clock', (t) async {
    var now = _t(12);
    await t.pumpWidget(_at(const Size(390, 844), false, still: true, clock: () => now));
    final s = t.state<SkyBackgroundState>(find.byType(SkyBackground));
    expect(s.driftRunning, isFalse);
    final p0 = s.driftPhase;
    final before = SkyPainter.paints;
    await t.pump(const Duration(seconds: 29));
    expect(s.driftPhase, p0);
    expect(SkyPainter.paints - before, 0, reason: 'nothing repaints while the time stands');
    expect(s.look, skyAt(_t(12)));
    now = _t(18, 50);
    await t.pump(skyTick);
    expect(s.look, skyAt(now), reason: 'jumps straight to the new sky, no fade');
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('the drift and clock stop in the background and come back on resume', (t) async {
    await t.pumpWidget(_at(const Size(390, 844), false));
    final s = t.state<SkyBackgroundState>(find.byType(SkyBackground));
    s.didChangeAppLifecycleState(AppLifecycleState.paused);
    expect(s.ticking, isFalse);
    final before = SkyPainter.paints;
    await t.pump(const Duration(minutes: 2));
    expect(SkyPainter.paints - before, 0);
    s.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(s.driftRunning, isTrue);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('the sky changes while the app is open as the clock moves', (t) async {
    for (final dark in [false, true]) {
      var now = _t(15, 0);
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(_at(const Size(390, 844), dark, clock: () => now));
      final s = t.state<SkyBackgroundState>(find.byType(SkyBackground));
      expect(s.night, 0);
      now = _t(20, 45);
      await t.pump(skyStep);
      await t.pump(const Duration(seconds: 4));
      expect(s.night, 1, reason: 'dark=$dark');
      now = DateTime(2026, 10, 25, 9);
      await t.pump(skyStep);
      await t.pump(const Duration(seconds: 4));
      expect(s.night, 0);
    }
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('a minute passing changes the sky a little, without a fade', (t) async {
    var now = DateTime(2026, 10, 24, 18, 40, 50);
    await t.pumpWidget(_at(const Size(390, 844), false, clock: () => now));
    final s = t.state<SkyBackgroundState>(find.byType(SkyBackground));
    final a = s.look;
    now = DateTime(2026, 10, 24, 18, 41, 2);
    await t.pump(skyStep);
    expect(s.look, isNot(a));
    expect(t.binding.hasScheduledFrame, isFalse, reason: 'no fade animation for a one-minute step');
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('coming back to the app re-reads the clock at once', (t) async {
    var now = _t(12);
    await t.pumpWidget(_at(const Size(390, 844), true, still: true, clock: () => now));
    final s = t.state<SkyBackgroundState>(find.byType(SkyBackground));
    expect(s.night, 0);
    now = _t(23);
    s.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await t.pump();
    expect(s.night, 1);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('a UTC clock is read as the user\'s local time', (t) async {
    final local = _t(13);
    await t.pumpWidget(_at(const Size(390, 844), false, still: true, clock: () => local.toUtc()));
    final s = t.state<SkyBackgroundState>(find.byType(SkyBackground));
    expect(s.night, skyNightness(local));
    await t.pumpWidget(const SizedBox());
  });
}

// Owner, 2026-10-24: the sky must cover any screen "however tall and wide", and after a rotation or a resize.
void _coverMain() {
  const sizes = [Size(1080, 2640), Size(390, 844), Size(1600, 2560), Size(2560, 1600), Size(2208, 1768)];
  for (final size in sizes) {
    testWidgets('the sky covers a ${size.width.toInt()}x${size.height.toInt()} screen, and after turning it', (t) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      for (final s in [size, size.flipped]) {
        t.view.physicalSize = s;
        await t.pumpWidget(_at(s, false));
        final r = t.getRect(find.byKey(const ValueKey('sky-paint')));
        expect(r.left, lessThanOrEqualTo(0.01));
        expect(r.top, lessThanOrEqualTo(0.01));
        expect(r.right, greaterThanOrEqualTo(s.width - 0.01));
        expect(r.bottom, greaterThanOrEqualTo(s.height - 0.01));
      }
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });
  }
}
