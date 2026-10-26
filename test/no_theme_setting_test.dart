import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:agent/app_state.dart';
import 'package:agent/screens/settings_screen.dart';
import 'package:agent/theme.dart';
import 'package:agent/ui/day_night.dart';

/// Owner, 2026-10-26: "Since it's sky and time based, we don't need the dark mode and its settings in the app."
void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    // The Account page reads the signed-in email from Supabase; an offline client with no session is enough.
    await Supabase.initialize(
      url: 'http://fake.local',
      publishableKey: 'anon-key',
      authOptions: const FlutterAuthClientOptions(localStorage: EmptyLocalStorage(), autoRefreshToken: false),
    );
  });

  testWidgets('Settings has no theme picker (no Theme group, no Auto/System/Light/Dark chips)', (t) async {
    SharedPreferences.setMockInitialValues({'themeMode': 'dark'});
    final app = AppState();
    await app.local.init();
    t.view.physicalSize = const Size(1080, 4000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: app,
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: app.themeMode,
        builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: child!),
        home: const SettingsScreen(),
      ),
    ));
    await t.pump();
    expect(find.text('Theme'), findsNothing);
    await t.tap(find.text('Account'));
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Sign out'), findsOneWidget, reason: 'the Account page is open');
    expect(find.text('Theme'), findsNothing);
    for (final w in ['Auto', 'System', 'Light', 'Dark']) {
      expect(find.text(w), findsNothing, reason: w);
    }
    for (final k in ['auto', 'system', 'light', 'dark']) {
      expect(find.byKey(ValueKey('theme-$k')), findsNothing, reason: k);
    }
    // Drain the status refresh timer started by the screen.
    await t.pump(const Duration(seconds: 20));
  });

  test('settings source has no theme choice left', () {
    final src = File('lib/screens/settings_screen.dart').readAsStringSync();
    expect(src, isNot(contains('ThemeChoice')));
    expect(src, isNot(contains("'Theme'")));
    expect(src, isNot(contains('theme-')));
  });

  test('the mode is always the time-of-day look, whatever a stored value says', () async {
    final saved = DayNight.I;
    addTearDown(() => DayNight.I = saved);
    for (final stored in ['light', 'dark', 'system', 'auto']) {
      SharedPreferences.setMockInitialValues({'themeMode': stored});
      final app = AppState();
      await app.local.init();
      DayNight.I = DayNight(clock: () => DateTime(2026, 10, 26, 13));
      expect(app.themeMode, ThemeMode.light, reason: 'day, stored $stored');
      DayNight.I = DayNight(clock: () => DateTime(2026, 10, 26, 23));
      expect(app.themeMode, ThemeMode.dark, reason: 'night, stored $stored');
    }
  });
}
