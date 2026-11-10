import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The app's own language is English (owner 2026-11-08: the app shows English only; the reply language is a separate
/// setting). [AppLang.I] stays for the few callers that asked which language to use, and always answers English.
class AppLang extends ChangeNotifier {
  AppLang._();
  static final I = AppLang._();

  static const _key = 'ui_language';

  /// Ignored: the app is English only. Kept so older code and tests can still set it.
  String choice = 'en';

  String get code => 'en';
  Locale get locale => const Locale('en');
  bool get rtl => false;

  Future<void> load() async {
    // English only: drop any language a past version saved.
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove(_key);
    } catch (_) {}
  }

  Future<void> set(String c) async {
    choice = 'en';
    notifyListeners();
  }
}

/// The app's own words (English). `tr('Settings')` looks the key up in [Strings.table] (which may reword it) and fills
/// `{name}`-style holes from [args].
String tr(String en, [Map<String, String> args = const {}]) {
  var s = Strings.table['en']?[en] ?? en;
  args.forEach((k, v) => s = s.replaceAll('{$k}', v));
  return s;
}

/// Reworded English for the app (owner 2026-11-08: the bots are digital people). A key is the English text in the code;
/// when there is no entry here, [tr] shows the key as it is.
class Strings {
  Strings._();

  static const Map<String, Map<String, String>> table = {
    // Owner 2026-11-08: the bots are digital people. This English map overrides the key text; Somali/Arabic below
    // carry the same wording. Every other key has no entry here and still shows as before.
    'en': {
      'Bots': 'Digital people',
      'bot': 'digital person',
      'bots': 'digital people',
      'New bot': 'New digital person',
      'Edit bot': 'Edit digital person',
      'Bot store': 'People store',
      'Bot Store': 'People store',
      'Hide bots': 'Hide people',
      'Show bots': 'Show people',
      'Ready-made bots': 'Ready-made digital people',
      'A bot someone shared': 'A digital person someone shared',
      'Hold a bot to make it the lead.': 'Hold a digital person to make them the lead.',
      'Bots work for you: research, keep track, message you when it matters.':
          'Your digital people work for you: research, keep track, message you when it matters.',
      'A team needs at least two bots. Make another bot first, then put them together.':
          'A team needs at least two digital people. Make another one first, then put them together.',
      'On: Telesia and your bots act without asking. Payments and purchases still ask every time.':
          'On: Telesia and your digital people act without asking. Payments and purchases still ask every time.',
      'Off: Telesia and your bots ask before sending, deleting or changing things for you. Small, safe steps go ahead.':
          'Off: Telesia and your digital people ask before sending, deleting or changing things for you. Small, safe steps go ahead.',
      'Telesia and your bots will send, post, change and delete things for you without asking first. Payments and purchases still ask every time. You can turn this off anytime.':
          'Telesia and your digital people will send, post, change and delete things for you without asking first. Payments and purchases still ask every time. You can turn this off anytime.',
      "Each bot picks its own model in its profile. Bots left on Default use your chats' model.":
          "Each digital person picks their own model in their profile. Ones left on Default use your chat's model.",
      'Give it a task in its chat. It carries the work through and comes back when it needs you.':
          'Give them a task in their chat. They carry the work through and come back when they need you.',
    },
  };
}
