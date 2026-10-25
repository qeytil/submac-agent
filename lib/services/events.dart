import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Plan 2.6: a few product events about bots, so we can see what works: hired, first_result, replied, ignored,
/// kept_7d, shared, hired_from_share. Batched and fire-and-forget: queued on the phone (kept across restarts) and sent
/// through the `log_events` RPC at most every 20 seconds. Users can never read them back.
///
/// Never PII: props carry only short labels and numbers (`from`, `kind`, `how`, `mins`), never names, text, emails,
/// codes or links. The server keeps only those keys too.
class Events {
  Events._();
  static final I = Events._();

  static const _queueKey = 'ev_queue';
  static const _replyWindow = Duration(hours: 24);
  final List<Map<String, dynamic>> _q = [];
  SharedPreferences? _prefs;
  bool _loaded = false;
  bool _sending = false;
  Timer? _timer;

  Future<SharedPreferences> _p() async {
    final p = _prefs ??= await SharedPreferences.getInstance();
    if (!_loaded) {
      _loaded = true;
      try {
        final raw = p.getString(_queueKey);
        if (raw != null && raw.isNotEmpty) {
          for (final e in jsonDecode(raw) as List) {
            if (e is Map) _q.add(Map<String, dynamic>.from(e));
          }
        }
      } catch (_) {}
    }
    return p;
  }

  /// Queues one event; never throws, never waits.
  void log(String kind, {String? botId, Map<String, Object>? props}) => unawaited(_add(kind, botId, props));

  Future<void> _add(String kind, String? botId, Map<String, Object>? props) async {
    try {
      final p = await _p();
      _q.add({
        'kind': kind,
        if (botId != null && botId.isNotEmpty) 'bot_id': botId.length > 64 ? botId.substring(0, 64) : botId,
        if (props != null && props.isNotEmpty) 'props': props,
        'at': DateTime.now().toUtc().toIso8601String(),
      });
      while (_q.length > 200) {
        _q.removeAt(0);
      }
      await p.setString(_queueKey, jsonEncode(_q));
      _timer ??= Timer(const Duration(seconds: 20), () => unawaited(flush()));
    } catch (_) {}
  }

  /// Sends what is queued (50 at a time). Quietly keeps the queue when offline or signed out.
  Future<void> flush() async {
    _timer = null;
    if (_sending) return;
    try {
      final p = await _p();
      if (_q.isEmpty) return;
      final c = Supabase.instance.client;
      if (c.auth.currentUser == null) return;
      _sending = true;
      final batch = _q.take(50).toList();
      await c.rpc('log_events', params: {'p_events': batch});
      _q.removeRange(0, batch.length);
      await p.setString(_queueKey, jsonEncode(_q));
      if (_q.isNotEmpty) _timer ??= Timer(const Duration(seconds: 5), () => unawaited(flush()));
    } catch (e) {
      debugPrint('events: $e');
    } finally {
      _sending = false;
    }
  }

  /// True only the first time [key] is seen on this phone (first result per bot, kept 7 days per hire).
  Future<bool> once(String key) async {
    try {
      final p = await _p();
      if (p.getBool('ev_once_$key') == true) return false;
      await p.setBool('ev_once_$key', true);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// A bot was hired: counts it and remembers when, for kept_7d.
  void hired(String botId, String origin) {
    final from = origin.startsWith('store:') ? 'store' : (origin == 'shared' ? 'share' : (origin.startsWith('role:') ? 'role' : 'own'));
    log('hired', botId: botId, props: {'from': from});
    unawaited(_markHired(botId));
  }

  Future<void> _markHired(String botId) async {
    try {
      final p = await _p();
      await p.setString('ev_hire_$botId', DateTime.now().toUtc().toIso8601String());
      await p.remove('ev_once_k7_$botId');
    } catch (_) {}
  }

  /// A bot's first visible result after it joined (a message, note or call).
  void result(String botId, String kind) => unawaited(_result(botId, kind));

  Future<void> _result(String botId, String kind) async {
    if (await once('fr_$botId')) log('first_result', botId: botId, props: {'kind': kind});
  }

  /// A bot sent the owner a message: replied if they write back within a day, ignored otherwise.
  void botMessaged(String botId) => unawaited(_botMessaged(botId));

  Future<void> _botMessaged(String botId) async {
    try {
      final p = await _p();
      // An earlier message still unanswered is settled first, so each message counts once.
      await _settle(p, botId, force: true);
      await p.setString('ev_msg_$botId', DateTime.now().toUtc().toIso8601String());
    } catch (_) {}
  }

  /// The owner wrote in a bot's chat.
  void ownerWrote(String botId) => unawaited(_ownerWrote(botId));

  Future<void> _ownerWrote(String botId) async {
    try {
      final p = await _p();
      final at = DateTime.tryParse(p.getString('ev_msg_$botId') ?? '');
      if (at == null) return;
      await p.remove('ev_msg_$botId');
      final mins = DateTime.now().toUtc().difference(at).inMinutes;
      log(mins <= _replyWindow.inMinutes ? 'replied' : 'ignored', botId: botId, props: {'mins': mins});
    } catch (_) {}
  }

  Future<void> _settle(SharedPreferences p, String botId, {bool force = false}) async {
    final at = DateTime.tryParse(p.getString('ev_msg_$botId') ?? '');
    if (at == null) return;
    if (!force && DateTime.now().toUtc().difference(at) < _replyWindow) return;
    await p.remove('ev_msg_$botId');
    log('ignored', botId: botId);
  }

  /// On sign-in: messages left unanswered for a day count as ignored, and bots still hired 7 days after their hire
  /// count as kept. [bots] are (id, still hired).
  Future<void> sweep(Iterable<(String, bool)> bots) async {
    try {
      final p = await _p();
      for (final (id, active) in bots) {
        await _settle(p, id);
        final hiredAt = DateTime.tryParse(p.getString('ev_hire_$id') ?? '');
        if (hiredAt == null) continue;
        if (!active) {
          await p.remove('ev_hire_$id');
          continue;
        }
        if (DateTime.now().toUtc().difference(hiredAt) >= const Duration(days: 7) && await once('k7_$id')) {
          log('kept_7d', botId: id);
        }
      }
    } catch (_) {}
    await flush();
  }
}
