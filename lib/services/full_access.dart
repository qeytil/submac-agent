import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'trust.dart';

/// Full access (owner, 2026-10-24: "approvals ask for even small things"). Off by default. When the owner turns it on,
/// Telesia and every bot stop asking for approvals and just act, the way a Grok Bot with "Always allow" rules does
/// (docs/grok-bots-research.md). One kind still asks every time: spending money (a payment, a purchase, an order or a
/// booking), because it cannot be taken back. Deleting the account is never an agent action; it keeps its own confirm in
/// Settings.
///
/// With Full access off, small everyday changes no longer ask either ([smallTools]: saving or editing a file in Telesia's
/// own workspace, restoring a snapshot that is saved first). Read-only actions never asked.
///
/// Approvals are enforced only on the phone (the cloud bot run has no action tools; it hands such work to the phone), so
/// this setting lives on the phone and needs no server copy.
class FullAccess extends ChangeNotifier {
  FullAccess._();
  static final FullAccess I = FullAccess._();

  static const _key = 'full_access_v1';

  /// On: act without asking (money still asks).
  bool on = false;

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      on = p.getBool(_key) ?? false;
    } catch (_) {}
    notifyListeners();
  }

  Future<void> set(bool v) async {
    on = v;
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_key, v);
    } catch (_) {}
  }

  /// Changes to how Telesia itself works (app_settings: approval mode, standing instructions, the always-on microphone):
  /// they ask every time, even with Full access on, and never offer "Allow always" (a page or message must never be
  /// able to raise Telesia's own trust or plant instructions).
  static const alwaysAskKind = 'settings';

  /// Small, easily undone changes inside Telesia's own space: never worth an approval card.
  static const smallTools = {'write_file', 'edit_file', 'append_file', 'code_snapshot'};

  /// Whether an action of [kind] (BotTrust.kindOf: money | send | delete | change) by [tool] asks the owner first.
  /// [level] is the bot's trust level (or Telesia's own, from Settings > Trust level).
  static bool shouldAsk({required String level, required String kind, required String tool, required bool fullAccess}) {
    if (kind == 'money' || kind == alwaysAskKind) return true;
    if (fullAccess) return false;
    if (kind == 'change' && smallTools.contains(tool)) return false;
    return BotTrust.needsAsk(level, kind);
  }
}
