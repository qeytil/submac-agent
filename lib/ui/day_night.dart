import 'dart:async';

import 'package:flutter/material.dart';

/// The look the user picked in Settings > Account > Theme (owner, 2026-10-26: "Make light mode the default for day and
/// dark mode the default for night").
///
/// * [auto] (the default): light from 07:00 to 19:00 on the phone's own clock, dark the rest of the night. It switches
///   while the app is open ([DayNight]).
/// * [system]: follows the phone's own light/dark setting.
/// * [light] / [dark]: always that look.
enum ThemeChoice { auto, system, light, dark }

/// Light starts at this local hour and ends at [dayEndHour] (dark from then until [dayStartHour] next morning).
const int dayStartHour = 7;
const int dayEndHour = 19;

/// True from 07:00:00 up to (not including) 19:00:00 local time.
bool isDaytime(DateTime t) => t.hour >= dayStartHour && t.hour < dayEndHour;

/// The look [ThemeChoice.auto] shows at [t] (device local time).
Brightness autoBrightness(DateTime t) => isDaytime(t) ? Brightness.light : Brightness.dark;

/// The next moment the auto look flips (the next 07:00 or 19:00 strictly after [now], local time). Built from calendar
/// fields, so a daylight-saving day still lands on the wall-clock hour.
DateTime nextDayNightBoundary(DateTime now) {
  final today7 = DateTime(now.year, now.month, now.day, dayStartHour);
  final today19 = DateTime(now.year, now.month, now.day, dayEndHour);
  if (now.isBefore(today7)) return today7;
  if (now.isBefore(today19)) return today19;
  return DateTime(now.year, now.month, now.day + 1, dayStartHour);
}

/// The look MaterialApp gets for a choice: auto resolves to light or dark by the clock.
ThemeMode resolveThemeMode(ThemeChoice c, Brightness auto) => switch (c) {
      ThemeChoice.auto => auto == Brightness.light ? ThemeMode.light : ThemeMode.dark,
      ThemeChoice.system => ThemeMode.system,
      ThemeChoice.light => ThemeMode.light,
      ThemeChoice.dark => ThemeMode.dark,
    };

/// Parses a stored choice. Nothing stored (a user who never picked a theme, still on the old default) means auto;
/// an explicit light/dark/system is kept as it was.
ThemeChoice themeChoiceFromStored(String? s) => switch (s) {
      'light' => ThemeChoice.light,
      'dark' => ThemeChoice.dark,
      'system' => ThemeChoice.system,
      _ => ThemeChoice.auto,
    };

/// The clock behind [ThemeChoice.auto]. It holds the current auto look and notifies only when it flips, so the app
/// rebuilds twice a day at most. It sleeps on a timer to the next boundary, never longer than [maxWait]: a phone whose
/// clock or time zone changes while SubMac is open is caught within that, and [recheck] (on every resume) catches it at
/// once. Timers stop while the app is in the background.
class DayNight extends ChangeNotifier {
  DayNight({DateTime Function()? clock}) : _clock = clock ?? DateTime.now {
    _brightness = autoBrightness(now());
  }

  static DayNight I = DayNight();

  /// The longest the timer sleeps before re-reading the clock (time zone or clock changed while the app was open).
  static const Duration maxWait = Duration(minutes: 1);

  DateTime Function() _clock;
  late Brightness _brightness;
  Timer? _timer;
  Duration? _delay;
  bool _running = false;

  /// Local time now (a UTC clock is read as local).
  DateTime now() {
    final t = _clock();
    return t.isUtc ? t.toLocal() : t;
  }

  /// For tests: swap the clock and re-read it.
  set clock(DateTime Function() c) {
    _clock = c;
    recheck();
  }

  Brightness get brightness => _brightness;

  /// How long the timer is set for (null when stopped). For tests.
  Duration? get scheduledDelay => _delay;
  bool get running => _running;

  /// Starts the boundary timer (app in front).
  void start() {
    _running = true;
    recheck();
  }

  /// Stops it (app in the background).
  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
    _delay = null;
  }

  /// Re-reads the clock, notifies if the look flipped, and sets the timer to the next boundary.
  void recheck() {
    final t = now();
    final b = autoBrightness(t);
    if (b != _brightness) {
      _brightness = b;
      notifyListeners();
    }
    _timer?.cancel();
    _timer = null;
    _delay = null;
    if (!_running) return;
    var d = nextDayNightBoundary(t).difference(t);
    if (d > maxWait) d = maxWait;
    if (d < Duration.zero) d = Duration.zero;
    _delay = d;
    _timer = Timer(d, recheck);
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
