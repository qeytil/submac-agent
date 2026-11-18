import 'package:flutter/foundation.dart';

import 'ai_keys.dart';

/// The user's own Gemini key for Live voice (Settings -> Voice). When one is set, calls go straight to Google with
/// this key: no Telesia Cloud pass and no daily call minutes. Stored encrypted, apart from the config, like the
/// BYOK keys; the call screen and the controller read [enabled] synchronously.
class LiveKeys {
  LiveKeys._();

  static const _keyEntry = 'live_gemini_key';
  static const _modelEntry = 'live_gemini_model';

  /// The Gemini Live endpoint for a raw API key (Telesia Cloud's pass URL uses ?access_token instead).
  static const wsUrl =
      'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent';

  /// Used when the user sets a key but leaves the model empty.
  static const defaultModel = 'gemini-3.8-live';

  /// Rebuilt by [load] and [save]; widgets listen to it.
  static final ValueNotifier<bool> hasKey = ValueNotifier<bool>(false);

  static String _key = '';
  static String _model = '';

  static String get key => _key;
  static String get model => _model.isEmpty ? defaultModel : _model;
  static bool get enabled => _key.isNotEmpty;

  static AiSecretStore get _store => AiKeys.store;

  /// Reads the saved key + model. Safe to call more than once.
  static Future<void> load() async {
    try {
      _key = (await _store.read(_keyEntry)) ?? '';
      _model = (await _store.read(_modelEntry)) ?? '';
    } catch (_) {
      _key = '';
      _model = '';
    }
    hasKey.value = _key.isNotEmpty;
  }

  /// Saves the key and model, or clears both when they are empty.
  static Future<void> save(String key, String model) async {
    _key = key.trim();
    _model = model.trim();
    if (_key.isEmpty) {
      await _store.delete(_keyEntry);
    } else {
      await _store.write(_keyEntry, _key);
    }
    if (_model.isEmpty) {
      await _store.delete(_modelEntry);
    } else {
      await _store.write(_modelEntry, _model);
    }
    hasKey.value = _key.isNotEmpty;
  }

  static Future<void> clear() => save('', '');
}
