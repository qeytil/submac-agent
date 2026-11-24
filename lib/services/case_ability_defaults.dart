import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'case_abilities.dart';

/// Settings → Investigation: the ability set every new case starts from (docs/investigation.md §10).
///
/// Not const: the owner may change it, and the change is kept on the phone. Phone records never appear here (they are
/// turned on per case). New cases seed from [CaseAbilities.defaults] through `CaseAbilities.defaultLevels()`.
class CaseAbilityDefaults extends ChangeNotifier {
  CaseAbilityDefaults._();
  static final I = CaseAbilityDefaults._();

  static const _key = 'cases_abilities_default_v1';
  bool _loaded = false;

  /// The abilities the owner may set as defaults (all but the per-case opt-in ones).
  List<Ability> get editable => [for (final a in CaseAbilities.all) if (!CaseAbilities.optIn.contains(a.id)) a];

  String levelOf(String id) => CaseAbilities.levelOf(CaseAbilities.defaults, id);

  Future<void> init() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_key);
      if (raw != null) CaseAbilities.defaults = CaseAbilities.merge(jsonDecode(raw));
    } catch (_) {}
    notifyListeners();
  }

  Future<void> setLevel(String id, String level) async {
    CaseAbilities.defaults[id] = level;
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_key, jsonEncode(CaseAbilities.defaults));
    } catch (_) {}
  }
}
