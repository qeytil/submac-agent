import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:agent/app_state.dart';
import 'package:agent/services/local_store.dart';
import 'package:agent/ui/day_night.dart';

/// Owner, 2026-10-26: "Make light mode the default for day and dark mode the default for night."
void main() {
  DateTime t(int h, int m, [int s = 0]) => DateTime(2026, 10, 26, h, m, s);

  test('Auto is the default theme', () {
    expect(AppState().themeChoice, ThemeChoice.auto);
    expect(themeChoiceFromStored(null), ThemeChoice.auto);
  });

  test('hour to look at the boundaries: light 07:00 up to 19:00, dark otherwise', () {
    expect(autoBrightness(t(6, 59)), Brightness.dark);
    expect(autoBrightness(t(6, 59, 59)), Brightness.dark);
    expect(autoBrightness(t(7, 0)), Brightness.light);
    expect(autoBrightness(t(12, 0)), Brightness.light);
    expect(autoBrightness(t(18, 59)), Brightness.light);
    expect(autoBrightness(t(18, 59, 59)), Brightness.light);
    expect(autoBrightness(t(19, 0)), Brightness.dark);
    expect(autoBrightness(t(0, 0)), Brightness.dark);
    expect(resolveThemeMode(ThemeChoice.auto, Brightness.light), ThemeMode.light);
    expect(resolveThemeMode(ThemeChoice.auto, Brightness.dark), ThemeMode.dark);
    expect(resolveThemeMode(ThemeChoice.system, Brightness.light), ThemeMode.system);
    expect(resolveThemeMode(ThemeChoice.dark, Brightness.light), ThemeMode.dark);
    expect(resolveThemeMode(ThemeChoice.light, Brightness.dark), ThemeMode.light);
  });

  test('next boundary: the next 07:00 or 19:00 strictly after now', () {
    expect(nextDayNightBoundary(t(3, 0)), t(7, 0));
    expect(nextDayNightBoundary(t(6, 59, 59)), t(7, 0));
    expect(nextDayNightBoundary(t(7, 0)), t(19, 0));
    expect(nextDayNightBoundary(t(18, 59)), t(19, 0));
    expect(nextDayNightBoundary(t(19, 0)), DateTime(2026, 10, 27, 7));
    expect(nextDayNightBoundary(DateTime(2026, 12, 31, 23, 30)), DateTime(2027, 1, 1, 7));
  });

  group('migration', () {
    test('a user who never picked a theme (still on the old default) moves to Auto', () async {
      SharedPreferences.setMockInitialValues({});
      final s = LocalStore();
      await s.init();
      expect(s.themeChoice, ThemeChoice.auto);
    });

    for (final c in ['light', 'dark', 'system']) {
      test('an explicit "$c" choice is kept', () async {
        SharedPreferences.setMockInitialValues({'themeMode': c});
        final s = LocalStore();
        await s.init();
        expect(s.themeChoice.name, c);
      });
    }

    test('choices round-trip, Auto included', () async {
      SharedPreferences.setMockInitialValues({});
      final s = LocalStore();
      await s.init();
      for (final c in ThemeChoice.values) {
        s.themeChoice = c;
        expect(s.themeChoice, c);
      }
    });
  });

  group('boundary timer (injectable clock)', () {
    testWidgets('sleeps to the boundary when it is near, at most a minute otherwise', (tester) async {
      var now = t(18, 59, 30);
      final d = DayNight(clock: () => now)..start();
      expect(d.brightness, Brightness.light);
      expect(d.scheduledDelay, const Duration(seconds: 30));
      now = t(12, 0);
      d.recheck();
      expect(d.scheduledDelay, DayNight.maxWait);
      now = t(6, 59, 59);
      d.recheck();
      expect(d.scheduledDelay, const Duration(seconds: 1));
      d.dispose();
    });

    testWidgets('flips at 19:00 and 07:00 while open, notifying once per flip', (tester) async {
      var now = t(18, 59, 30);
      final d = DayNight(clock: () => now)..start();
      var flips = 0;
      d.addListener(() => flips++);
      // Time moves with the fake timers.
      now = t(18, 59, 59);
      await tester.pump(const Duration(seconds: 29));
      expect(d.brightness, Brightness.light);
      expect(flips, 0);
      now = t(19, 0);
      await tester.pump(const Duration(seconds: 1));
      expect(d.brightness, Brightness.dark);
      expect(flips, 1);
      // Minutes of night: no more notifications.
      for (var i = 1; i <= 5; i++) {
        now = t(19, i);
        await tester.pump(DayNight.maxWait);
      }
      expect(flips, 1);
      now = t(6, 59, 50);
      await tester.pump(DayNight.maxWait);
      expect(d.scheduledDelay, const Duration(seconds: 10));
      now = t(7, 0);
      await tester.pump(const Duration(seconds: 10));
      expect(d.brightness, Brightness.light);
      expect(flips, 2);
      d.dispose();
    });

    testWidgets('stops in the background and re-reads the clock on resume (time or zone changed)', (tester) async {
      var now = t(12, 0);
      final d = DayNight(clock: () => now)..start();
      d.stop();
      expect(d.scheduledDelay, isNull);
      expect(d.running, isFalse);
      now = t(22, 0);
      await tester.pump(const Duration(minutes: 5));
      expect(d.brightness, Brightness.light, reason: 'asleep in the background');
      d.start();
      expect(d.brightness, Brightness.dark);
      d.dispose();
    });

    testWidgets('a clock or time zone change while open is caught within a minute', (tester) async {
      var now = t(12, 0);
      final d = DayNight(clock: () => now)..start();
      now = t(21, 0); // the phone moved to another time zone
      await tester.pump(DayNight.maxWait);
      expect(d.brightness, Brightness.dark);
      d.dispose();
    });
  });

  test('setThemeChoice saves and the resolved look follows the clock', () async {
    SharedPreferences.setMockInitialValues({});
    final app = AppState();
    await app.local.init();
    final saved = DayNight.I;
    addTearDown(() => DayNight.I = saved);
    var now = t(8, 0);
    DayNight.I = DayNight(clock: () => now);
    app.setThemeChoice(ThemeChoice.auto);
    expect(app.themeMode, ThemeMode.light);
    now = t(20, 0);
    DayNight.I.recheck();
    expect(app.themeMode, ThemeMode.dark);
    app.setThemeChoice(ThemeChoice.light);
    expect(app.themeMode, ThemeMode.light);
    expect(app.local.prefs.getString('themeMode'), 'light');
    app.setThemeMode(ThemeMode.system);
    expect(app.themeChoice, ThemeChoice.system);
  });
}
