import 'dart:async';
import 'dart:convert';

import 'telesia_gateway.dart';

/// Which Telesia chat (or team member) a Telesia tool call from opencode belongs to.
///
/// An MCP call from opencode does not say which session made it. The session's own event stream does: a tool part
/// with the tool's name and arguments appears there as the call starts. Each such part is noted here with its chat,
/// and the MCP call takes the entry with the same name and the same arguments. Matching on the arguments (not only the
/// name) keeps two chats, two bots or two team members that run the same tool at once apart, so one bot's memory,
/// desk or approval never lands on another (no leaks between chats).
///
/// Entries are taken once and expire, so the table never grows. Pure, so it is tested without the app.
class McpRoutes {
  McpRoutes({this.ttl = const Duration(minutes: 10), this.max = 200, DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final Duration ttl;
  final int max;
  final DateTime Function() _clock;
  final List<({String key, String tool, String conv, DateTime at, String part})> _open = [];
  final Set<String> _seenParts = {};

  /// Arguments in a fixed key order, so the same call matches however its map was built.
  static String canon(Object? v) {
    if (v is Map) {
      final keys = v.keys.map((k) => '$k').toList()..sort();
      return '{${keys.map((k) => '${jsonEncode(k)}:${canon(v[k])}').join(',')}}';
    }
    if (v is List) return '[${v.map(canon).join(',')}]';
    if (v is num && v == v.roundToDouble() && v.abs() < 1e15) return '${v.toInt()}';
    return jsonEncode(v);
  }

  static String keyOf(String tool, Map<String, dynamic> args) => '$tool ${canon(args)}';

  void _prune() {
    final cut = _clock().subtract(ttl);
    _open.removeWhere((e) => e.at.isBefore(cut));
    while (_open.length > max) {
      _open.removeAt(0);
    }
    if (_seenParts.length > max * 4) _seenParts.clear();
  }

  /// A tool part seen in [conv]'s event stream. [part] is the part's id: a part is noted once however many updates
  /// it gets.
  void note(String tool, Map<String, dynamic> args, String conv, {required String part}) {
    if (tool.isEmpty || !_seenParts.add(part)) return;
    _prune();
    _open.add((key: keyOf(tool, args), tool: tool, conv: conv, at: _clock(), part: part));
  }

  /// The chat of an MCP call. The event may arrive a moment after the call, so this waits up to [wait] for it. Null:
  /// no matching part (the caller falls back to the open chat).
  ///
  /// [fuzzy]: when no entry has the same arguments, take the only open entry of that tool. Only safe while one turn
  /// runs: with several, that entry may be another turn's call whose own MCP request has not arrived yet, and taking
  /// it would run this call as the other chat (bots team audit 2026-11-04).
  ///
  /// [orphan] (''): the call came from a session no running turn owns (see [watchOrphans]); the caller refuses it.
  Future<String?> take(String tool, Map<String, dynamic> args,
      {Duration wait = const Duration(milliseconds: 1500), bool fuzzy = true}) async {
    final key = keyOf(tool, args);
    final until = _clock().add(wait);
    while (true) {
      _prune();
      final i = _open.indexWhere((e) => e.key == key);
      if (i >= 0) return _open.removeAt(i).conv;
      if (!_clock().isBefore(until)) break;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    // Arguments that did not survive the trip byte for byte: the only open call of that tool, when there is one.
    if (!fuzzy) return null;
    final same = _open.where((e) => e.tool == tool).toList();
    if (same.length == 1) {
      _open.remove(same.first);
      return same.first.conv;
    }
    return null;
  }

  int get openCount => _open.length;

  /// Notes the Telesia gateway calls (find_tools, run_tool) in one engine event for [conv], when the event comes from
  /// a session of [family]: the turn's own session and every sub-session opencode starts under it (its `task` tool
  /// runs a subagent in a child session). The family grows here as `session.created`/`session.updated` events name a
  /// parent in it. Without this, a subagent's Telesia call had no route and ran as whatever chat was open (a bot's
  /// work could land in the owner's chat and the other way round; 2026-11-03).
  void watch(Map<String, dynamic> e, String conv, Set<String> family) {
    final props = e['properties'];
    if (props is! Map) return;
    final type = e['type'];
    if (type == 'session.created' || type == 'session.updated') {
      final info = props['info'];
      if (info is Map && info['id'] != null && family.contains('${info['parentID']}')) family.add('${info['id']}');
      return;
    }
    if (type != 'message.part.updated') return;
    final p = props['part'];
    if (p is! Map || p['type'] != 'tool' || !family.contains('${p['sessionID']}')) return;
    final st = p['state'] is Map ? p['state'] as Map : const {};
    if (st['status'] != 'running' || st['input'] is! Map) return;
    final input = Map<String, dynamic>.from(st['input'] as Map);
    final tool = TelesiaGateway.bare('${p['tool'] ?? ''}');
    if (tool == TelesiaGateway.runName) {
      final (n, a) = TelesiaGateway.inner(input);
      if (n.isNotEmpty) note(n, a, conv, part: '${p['id']}');
    } else if ((tool == TelesiaGateway.findName || TelesiaGateway.directNames.contains(tool)) && '${p['tool']}' != tool) {
      note(tool, input, conv, part: '${p['id']}');
    }
  }

  /// The route of a call that came from no running turn's session.
  static const orphan = '';

  /// Notes Telesia gateway calls made by sessions that no running turn owns ([owned] is false for them): a turn that
  /// was stopped while opencode still finished a step, a deleted team session, the opencode test screen. They are
  /// noted as [orphan], so their MCP call is refused instead of falling back to "the only turn running", which ran
  /// it as that other chat (a leak). Call it before the turns' own [watch] for each event.
  void watchOrphans(Map<String, dynamic> e, bool Function(String session) owned) {
    if (e['type'] != 'message.part.updated') return;
    final props = e['properties'];
    final p = props is Map ? props['part'] : null;
    if (p is! Map || p['type'] != 'tool') return;
    final session = '${p['sessionID'] ?? ''}';
    if (session.isEmpty || owned(session)) return;
    watch(e, orphan, {session});
  }

  /// The Telesia chat of [session]: its own, or the nearest parent's ([parent]: child session -> parent, from
  /// `session.created` events). A subagent's permission or question card shows in the chat whose turn started it,
  /// never in whatever chat happens to be open (2026-11-03).
  static String? rootConv(String session, String? Function(String session) convOf, Map<String, String> parent) {
    var s = session;
    for (var i = 0; i < 16; i++) {
      final c = convOf(s);
      if (c != null) return c;
      final up = parent[s];
      if (up == null) return null;
      s = up;
    }
    return null;
  }

  /// Where a call with no matching part goes: the only Telesia turn running (chat, bot or team member), or null when
  /// there are several or none. Never "the chat on screen": that is how one bot's call used to act on another chat.
  static String? soleLive(Iterable<String> live) {
    final l = live.toSet();
    return l.length == 1 ? l.first : null;
  }
}
