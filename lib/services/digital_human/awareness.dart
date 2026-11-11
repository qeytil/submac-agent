import 'dart:async';
import 'package:flutter/foundation.dart';

import 'heartbeat.dart';
export 'heartbeat.dart';

/// What the world around us looks like right now (owner 2026-11).
///
/// A digital person is not isolated in a chat window. It watches notifications,
/// notices when a team goes quiet, sees prices shift, hears a mention in WhatsApp,
/// and senses when the owner has been idle too long. This layer collects those
/// signals and turns them into [AwarenessInsight] objects the brain can act on.
///
/// Insights are not spam. They are scored for value and urgency; only the ones
/// worth interrupting with reach the inbox.
class SituationalAwareness {
  SituationalAwareness({required this.id, required this.heartbeat});

  final String id;
  final Heartbeat heartbeat;

  Timer? _watcher;
  static const _watchInterval = Duration(minutes: 5);

  /// The most recent thing we noticed that might matter.
  AwarenessInsight? latestInsight;

  /// How many thoughts we have generated since last reset.
  int insightCount = 0;

  /// Start watching. Call once per person when the app opens.
  void start() {
    stop();
    _watcher = Timer.periodic(_watchInterval, (_) => observe());
  }

  void stop() {
    _watcher?.cancel();
    _watcher = null;
  }

  /// One observation cycle: check triggers, emit insights if worth it.
  Future<void> observe() async {
    if (!heartbeat.isAlive) return;
    await _checkExternalTriggers();
    await _checkInternalDynamics();
    await _checkUserSilence();
    await _checkCuriosityGap();
  }

  /// Notifications, mentions, price changes, site updates — anything that came
  /// from outside this person's own head.
  Future<void> _checkExternalTriggers() async {
    // Stub: in production this hooks into:
    // * bot_inbox.dart events (WhatsApp, email, site monitors)
    // * push.dart notifications
    // * connector_catalog.dart feeds
    // For now we simulate curiosity with a synthetic trigger.
  }

  /// Team silence, unfinished threads, messages aimed at us that we missed.
  Future<void> _checkInternalDynamics() async {
    // Stub: hooks into:
    // * team_floor.dart conversation flow
    // * bot_inbox.dart unread count
    // * teams/ channels where we are mentioned
  }

  /// Owner hasn't opened the app or typed in a while — are they okay?
  Future<void> _checkUserSilence() async {
    // Stub: would read from a user activity tracker; here we just note it.
  }

  /// Nothing is urgent but something is interesting — explore, learn, prepare.
  Future<void> _checkCuriosityGap() async {
    if (heartbeat.idleTime.inMinutes < 30) return; // too busy to wonder
    if (insightCount > 0) return; // already thinking about something
    // In production: pick a topic from memory, run a lightweight search,
    // surface an insight if the result is surprising or useful.
  }

  /// Record an insight the person generated itself.
  void note(AwarenessInsight insight) {
    latestInsight = insight;
    insightCount++;
    if (kDebugMode) {
      debugPrint('[AW:$id] insight: ${insight.title} (${insight.urgency})');
    }
  }

  /// Record something external that arrived (notification, watch trigger, etc.).
  void receive(AwarenessInsight insight) {
    note(insight);
    heartbeat.markActive();
  }

  Map<String, dynamic> snapshot() => {
        'alive': heartbeat.isAlive,
        'idleMin': heartbeat.idleTime.inMinutes,
        'latest': latestInsight?.toJson(),
        'insightsGenerated': insightCount,
      };
}

/// One thought the awareness layer surfaced — worth acting on or just noise.
class AwarenessInsight {
  AwarenessInsight({
    required this.title,
    this.detail = '',
    this.urgency = 'low',
    this.source = 'internal',
    this.actionHint = '',
    DateTime? at,
  }) : at = at ?? DateTime.now();

  final String title;
  final String detail;
  /// 'low' | 'medium' | 'high' | 'critical'
  final String urgency;
  /// 'internal' (self-generated) | 'external' (notification) | 'team' (mention)
  final String source;
  final String actionHint;
  final DateTime at;

  Map<String, dynamic> toJson() => {
        'title': title,
        'detail': detail,
        'urgency': urgency,
        'source': source,
        'hint': actionHint,
        'at': at.toIso8601String(),
      };

  static AwarenessInsight fromJson(Map<String, dynamic> j) => AwarenessInsight(
        title: '${j['title'] ?? ''}',
        detail: '${j['detail'] ?? ''}',
        urgency: '${j['urgency'] ?? 'low'}',
        source: '${j['source'] ?? 'internal'}',
        actionHint: '${j['hint'] ?? ''}',
        at: DateTime.tryParse('${j['at']}') ?? DateTime.now(),
      );

  @override
  String toString() => '[${urgency.toUpperCase()}] $title';
}
