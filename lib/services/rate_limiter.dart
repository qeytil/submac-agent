import 'dart:async';
import 'dart:convert';

import '../models.dart';
import 'local_store.dart';

class _Event {
  final DateTime at;
  final int tokens;
  _Event(this.at, this.tokens);
}

/// Client-side pacing: after the server says "busy", holds the next request calmly instead of failing.
class RateLimiter {
  static final Map<String, List<_Event>> _events = {};

  static List<_Event> _recent(String id) {
    final list = _events.putIfAbsent(id, () => []);
    final cutoff = DateTime.now().subtract(const Duration(minutes: 1));
    list.removeWhere((e) => e.at.isBefore(cutoff));
    return list;
  }

  /// When the provider last said "too many requests": nothing goes out before this.
  static final Map<String, DateTime> _coolUntil = {};

  /// The provider answered 429: hold every request to it for [wait] (default 20 s).
  static void cooldown(ProviderConfig p, Duration? wait) {
    final until = DateTime.now().add(wait ?? const Duration(seconds: 20));
    final cur = _coolUntil[p.id];
    if (cur == null || until.isAfter(cur)) _coolUntil[p.id] = until;
  }

  /// How long until a request of [tokens] fits this provider's per-minute limits.
  static Duration waitFor(ProviderConfig p, int tokens) {
    final now = DateTime.now();
    var wait = Duration.zero;
    final cool = _coolUntil[p.id];
    if (cool != null && cool.isAfter(now)) wait = cool.difference(now);
    if (p.rpm <= 0 && p.tpm <= 0) return wait;
    final list = _recent(p.id);
    if (list.isEmpty) return wait;
    if (p.rpm > 0) {
      // Spread requests evenly: agent steps come in bursts, and most providers count in short windows.
      final gap = Duration(milliseconds: 60000 ~/ p.rpm);
      final w1 = list.last.at.add(gap).difference(now);
      if (w1 > wait) wait = w1;
      if (list.length >= p.rpm) {
        final oldest = list[list.length - p.rpm];
        final w = oldest.at.add(const Duration(minutes: 1)).difference(now);
        if (w > wait) wait = w;
      }
    }
    if (p.tpm > 0) {
      // A request bigger than the whole budget still waits for an empty minute.
      final need = tokens > p.tpm ? p.tpm : tokens;
      var used = list.fold<int>(0, (a, e) => a + e.tokens);
      if (used + need > p.tpm) {
        for (final e in list) {
          used -= e.tokens;
          if (used + need <= p.tpm) {
            final w = e.at.add(const Duration(minutes: 1)).difference(now);
            if (w > wait) wait = w;
            break;
          }
        }
      }
    }
    return wait.isNegative ? Duration.zero : wait;
  }

  /// Waits until the request fits, then records it.
  static Future<void> acquire(
    ProviderConfig p,
    int tokens,
    LocalStore store, {
    required void Function(int seconds) onWait,
    required bool Function() cancelled,
  }) async {
    while (true) {
      if (cancelled()) return;
      final w = waitFor(p, tokens);
      if (w <= Duration.zero) break;
      onWait((w.inMilliseconds / 1000).ceil());
      await Future<void>.delayed(w > const Duration(seconds: 1) ? const Duration(seconds: 1) : w);
    }
    _recent(p.id).add(_Event(DateTime.now(), tokens));
  }

  /// Rough token estimate (4 characters per token, images count as ~800).
  static int estimateTokens(List<Map<String, dynamic>> messages, [List<Map<String, dynamic>>? tools]) {
    // Tool definitions are sent with every request and count against token limits too.
    var chars = tools == null ? 0 : jsonEncode(tools).length;
    var images = 0;
    for (final m in messages) {
      final c = m['content'];
      if (c is String) {
        chars += c.length;
      } else if (c is List) {
        for (final part in c) {
          if (part is Map && part['type'] == 'text') chars += (part['text'] ?? '').toString().length;
          if (part is Map && part['type'] == 'image_url') images++;
        }
      }
      final calls = m['tool_calls'];
      if (calls != null) chars += calls.toString().length;
    }
    return chars ~/ 4 + images * 800 + 200;
  }
}
