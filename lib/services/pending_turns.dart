import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Owner messages a turn could not answer because the account's daily allowance was used up.
///
/// Before, such a message got an error line and was never acted on: the owner's command ("stop the scheduled task")
/// simply did not happen until they retyped it (owner 2026-11-07). Here the chat and the message are remembered, so
/// the turn runs again by itself as soon as the allowance is available — on the next app resume, or right after a
/// later turn shows the allowance is back. Only the owner's own messages in their own chats are kept; a bot's
/// background work keeps waiting for its own next wake, as before.
class PendingTurns {
  PendingTurns._();

  /// The one instance the app uses.
  static final PendingTurns I = PendingTurns._();

  static const _key = 'pending_turns_v1';

  SharedPreferences? _p;
  final List<Map<String, String>> _items = [];
  bool _loaded = false;
  bool _draining = false;

  /// Set by AppState: run the blocked turn of [convId] whose message is [msgId]. It removes the entry itself when it
  /// is settled (it ran, or the owner already moved on); returning without removing keeps it for a later try.
  Future<void> Function(String convId, String msgId)? run;

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      _p = await SharedPreferences.getInstance();
      final raw = _p!.getString(_key);
      if (raw == null || raw.isEmpty) return;
      for (final x in jsonDecode(raw) as List) {
        final m = Map<String, String>.from(x as Map);
        if ((m['c'] ?? '').isNotEmpty && (m['m'] ?? '').isNotEmpty) _items.add(m);
      }
    } catch (_) {
      // A stored blob we cannot read is dropped: the message is still in the chat either way.
    }
  }

  Future<void> _store() async {
    try {
      await _p?.setString(_key, jsonEncode(_items));
    } catch (_) {}
  }

  /// Remembers the owner's [msgId] in [convId] as waiting for the allowance. Adding the same message twice does
  /// nothing.
  Future<void> add(String convId, String msgId) async {
    if (convId.isEmpty || msgId.isEmpty) return;
    await _load();
    if (_items.any((e) => e['m'] == msgId)) return;
    _items.add({'c': convId, 'm': msgId});
    await _store();
  }

  /// Forgets [msgId] (it ran, or the owner moved on).
  Future<void> remove(String msgId) async {
    await _load();
    final before = _items.length;
    _items.removeWhere((e) => e['m'] == msgId);
    if (_items.length != before) await _store();
  }

  /// Runs the waiting turns, oldest first. Safe to call often: a call made while a drain is running does nothing.
  Future<void> drain() async {
    if (_draining) return;
    await _load();
    final f = run;
    if (f == null || _items.isEmpty) return;
    _draining = true;
    try {
      // A copy: `run` drops settled entries as it goes.
      for (final e in List<Map<String, String>>.from(_items)) {
        final conv = e['c'] ?? '';
        final msg = e['m'] ?? '';
        if (conv.isEmpty || msg.isEmpty) continue;
        await f(conv, msg);
      }
    } catch (_) {
      // A failure here leaves the entries in place: the next trigger tries again.
    } finally {
      _draining = false;
    }
  }
}
