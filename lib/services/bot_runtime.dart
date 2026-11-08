import 'dart:math' as math;

import 'bot_inbox.dart';

/// Each digital person's own runtime state (owner 2026-11-08).
///
/// The owner asked for people who run on their own runtime, so many of them never conflict: their own rhythm, their own
/// line, their own presence. This is the per-bot piece the rest of the app reads. It is deliberately a plain object, not
/// a Dart isolate: the model's network round-trip is the real cost, so physical isolation would add memory without
/// making a turn faster; logical isolation is what removes the conflicts (see docs/bot-runtime.md).
enum BotPhase { idle, thinking, working, waiting, off }

/// One bot's runtime: what it is doing now, when it last woke and when it will wake next, and how many turns it has in
/// flight. Kept for the life of the app by [RuntimeHost].
class BotRuntime {
  BotRuntime(this.botId);

  final String botId;

  /// What the person is doing now, for its ring, its row and its chat.
  BotPhase phase = BotPhase.idle;

  /// When it last woke on its own, and when its next heartbeat is due (both its own, not a shared clock).
  DateTime? lastWakeAt;
  DateTime? nextWakeAt;

  /// Turns of this person running now (a bot may run one at a time, but the count keeps the door open for tools and
  /// calls that overlap a turn).
  int inFlight = 0;

  /// A wake that arrived while this person was busy, waiting its turn on this person's own line ('' = none).
  DateTime? queuedAt;

  /// Events about the world aimed at THIS person only. A burst becomes one wake with one digest (owner 2026-11-08).
  late final BotInbox inbox = BotInbox(botId);

  @override
  String toString() => 'BotRuntime($botId, ${phase.name}, inFlight=$inFlight)';
}

/// One [BotRuntime] per bot, kept for the life of the app. The host is the single owner of per-person state, so nothing
/// about one person's rhythm leaks into another's.
class RuntimeHost {
  RuntimeHost._();
  static final RuntimeHost I = RuntimeHost._();

  final Map<String, BotRuntime> _byId = {};

  BotRuntime of(String botId) => _byId.putIfAbsent(botId, () => BotRuntime(botId));

  void forget(String botId) => _byId.remove(botId);

  /// Tests: start from nobody.
  void clear() => _byId.clear();

  /// A stable offset inside a wake window, taken from the bot's id, so a crowd of people never lands on the same minute
  /// ("thundering herd", owner 2026-11-08). Up to a quarter of the window, at most 90 minutes; the same person keeps the
  /// same offset on every wake, so its rhythm is its own and steady.
  static Duration jitter(String botId, Duration window) {
    final span = math.min(window.inMinutes ~/ 4, 90);
    if (span <= 0) return Duration.zero;
    return Duration(minutes: _hash(botId) % span);
  }

  /// A small, stable string hash (not String.hashCode, which need not be stable across runs): tests and the schedule
  /// both rely on the same person getting the same offset every time.
  static int _hash(String s) {
    var h = 7;
    for (final c in s.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return h;
  }
}
