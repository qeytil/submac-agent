import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// "Always on" (owner 2026-11-08): keep SubMac's foreground service open all day and pulse it every few minutes, so the
/// digital people feel present instead of waking only when an alarm fires. It is on by default; the owner can turn it
/// off in Settings > Advanced. It costs battery: the service holds a wake lock while it runs, which the switch says out
/// loud. Bots themselves never run on a continuous loop, no matter what this is set to.
class AlwaysOn {
  AlwaysOn._();
  static final I = AlwaysOn._();

  static const key = 'always_on';
  /// The steady line the foreground service shows while "Always on" is on (English only, owner 2026-11-08).
  static const body = 'Your digital people are active';

  bool _on = true;
  bool get on => _on;

  /// Reads the saved choice. Defaults to on.
  void load(SharedPreferences prefs) => _on = prefs.getBool(key) ?? true;

  Future<void> set(SharedPreferences prefs, bool v) async {
    _on = v;
    await prefs.setBool(key, v);
  }

  @visibleForTesting
  void debugSet(bool v) => _on = v;
}
