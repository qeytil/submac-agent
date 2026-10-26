import 'package:shared_preferences/shared_preferences.dart';

/// The first-launch intro plays once per install. [seen] is read before the first frame (main()), so the intro never
/// delays a later cold start: once the flag is set the app goes straight to sign-in or chat.
class IntroFlag {
  IntroFlag._();

  static const key = 'intro_seen_v1';

  /// Read once at start-up. True until [load] says otherwise only in tests that never call it.
  static bool seen = true;

  static Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      seen = p.getBool(key) ?? false;
    } catch (_) {
      seen = true; // Prefs unreadable: never risk blocking the start.
    }
  }

  /// Set when the intro finishes or is skipped (and quietly for someone already signed in, who never sees it).
  static Future<void> markSeen() async {
    seen = true;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(key, true);
    } catch (_) {}
  }
}

/// The 18+ / Terms / Privacy tick is on the sign-in screen itself. When someone signs in or up with it ticked, this
/// remembers it until the account is signed in, so the agreement can be saved on the account right after (the same
/// user_metadata write as before). It survives the trip out to the browser for Google and an app restart while an
/// email code is pending, and it expires after a day.
class ConsentPending {
  ConsentPending._();

  static const key = 'consent_ticked_at';
  static const life = Duration(hours: 24);

  static DateTime? _at;

  /// The tick was given on this phone, recently enough to count.
  static bool get active {
    final at = _at;
    return at != null && DateTime.now().difference(at) < life;
  }

  static Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final ms = p.getInt(key);
      _at = ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
    } catch (_) {}
  }

  /// Called when a sign-in or sign-up action is pressed with the box ticked.
  static Future<void> mark({DateTime? now}) async {
    final at = now ?? DateTime.now();
    _at = at;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt(key, at.millisecondsSinceEpoch);
    } catch (_) {}
  }

  /// Once the account carries the agreement (or the tick is no longer wanted).
  static Future<void> clear() async {
    _at = null;
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove(key);
    } catch (_) {}
  }
}
