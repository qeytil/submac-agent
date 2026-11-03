import 'dart:async';
import 'dart:convert';

/// Which SubMac chat (or team member) a SubMac tool call from opencode belongs to.
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
  Future<String?> take(String tool, Map<String, dynamic> args, {Duration wait = const Duration(milliseconds: 1500)}) async {
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
    final same = _open.where((e) => e.tool == tool).toList();
    if (same.length == 1) {
      _open.remove(same.first);
      return same.first.conv;
    }
    return null;
  }

  int get openCount => _open.length;
}
