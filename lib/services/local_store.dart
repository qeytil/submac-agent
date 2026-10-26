import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../ui/day_night.dart';


/// Device-local settings. Saved logins and app tokens never leave the device (encrypted storage).
class LocalStore {
  // Kept on purpose: flutter_secure_storage 10 reads this to migrate data saved by 9.x. Drop it only after every phone ran a v10 build.
  // ignore: deprecated_member_use
  static const _secure = FlutterSecureStorage(aOptions: AndroidOptions(encryptedSharedPreferences: true));
  late SharedPreferences _prefs;
  SharedPreferences get prefs => _prefs;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  /// Everything SubMac keeps on this phone, gone (account deleted).
  Future<void> wipeAll() async {
    try {
      await _secure.deleteAll();
    } catch (_) {}
    await _prefs.clear();
  }

  /// Removes everything older versions kept about the user's own AI providers and keys.
  Future<void> forgetModelSetup() async {
    for (final k in const ['providers', 'liveKey']) {
      try {
        await _secure.delete(key: k);
      } catch (_) {}
    }
    for (final k in _prefs.getKeys().toList()) {
      if (k == 'activeProviderId' || k == 'autoMode' || k == 'lastAutoPick' || k == 'backupModel' || k == 'liveModel' ||
          k == 'thinking' || k == 'showSteps' || k == 'maxSteps' || k == 'easyMode' ||
          k.startsWith('model_') || k.startsWith('role_') || k.startsWith('roleSrc_') || k.startsWith('usage_') || k.startsWith('rl_')) {
        await _prefs.remove(k);
      }
    }
  }

  /// Older builds had Settings > Theme (auto/system/light/dark). The look now always follows the time of day, so any
  /// saved choice is ignored and the stored key is removed.
  Future<void> clearLegacyThemeMode() async {
    if (_prefs.containsKey(legacyThemeModeKey)) await _prefs.remove(legacyThemeModeKey);
  }

  bool get agentEnabled => _prefs.getBool('agentEnabled') ?? true;
  set agentEnabled(bool v) => _prefs.setBool('agentEnabled', v);

  String get approvalMode => _prefs.getString('approvalMode') ?? ((_prefs.getBool('confirmShell') ?? true) ? 'ask' : 'full');
  set approvalMode(String v) => _prefs.setString('approvalMode', v);

  /// Most tokens (in thousands) one task may use before it wraps up with a status. 0 = Auto: a task keeps going
  /// while today's allowance has room (it stops with a reserve left, so the user can still chat). The old fixed
  /// default (150k) stopped long builds half way, so a stored 150 counts as Auto too.
  int get taskBudgetK {
    final v = _prefs.getInt('taskBudgetK') ?? 0;
    if (v <= 0 || v == 150) return 0;
    return v < 50 ? 50 : (v > 5000 ? 5000 : v);
  }
  set taskBudgetK(int v) => _prefs.setInt('taskBudgetK', v);

  // Live voice
  String get liveVoice => _prefs.getString('liveVoice') ?? 'Kore';
  set liveVoice(String v) => _prefs.setString('liveVoice', v);

  // ---------- v1.4 ----------
  /// Generic encrypted values (connector tokens, search keys).
  Future<String> secret(String key) async {
    try {
      return (await _secure.read(key: key)) ?? '';
    } catch (_) {
      return '';
    }
  }

  Future<void> setSecret(String key, String value) async {
    if (value.isEmpty) {
      await _secure.delete(key: key);
    } else {
      await _secure.write(key: key, value: value);
    }
  }

  /// Memory facts cached on the device (synced to the account when possible).
  List<Map<String, dynamic>> get memories {
    try {
      final raw = _prefs.getString('memories');
      if (raw == null) return [];
      return [for (final e in jsonDecode(raw) as List) Map<String, dynamic>.from(e as Map)];
    } catch (_) {
      return [];
    }
  }

  set memories(List<Map<String, dynamic>> v) => _prefs.setString('memories', jsonEncode(v));

  bool get memoryEnabled => _prefs.getBool('memoryEnabled') ?? true;
  set memoryEnabled(bool v) => _prefs.setBool('memoryEnabled', v);

  /// The name the owner shows on bots they publish to the Bot Store ('' = "A SubMac user").
  String get storeAuthorName => _prefs.getString('store_author') ?? '';
  set storeAuthorName(String v) => _prefs.setString('store_author', v);
}
