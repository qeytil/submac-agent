import 'dart:async';

/// Menu search inside chats (CB-32): the search box used to look at titles only.
/// This looks through the words already saved on the phone (never the network) and gives back,
/// for each chat that matches, the line that matched so the menu can show it under the title.
class ChatSearch {
  ChatSearch(this._rows, {this.cap = cap200});

  /// The saved rows of one chat (null when the chat is not on the phone).
  final Future<List<Map<String, dynamic>>?> Function(String chatId) _rows;

  /// Most chats read for one search, newest first, so a long history stays quick.
  final int cap;
  static const cap200 = 200;

  /// How long the box waits after the last key before reading chats.
  static const debounce = Duration(milliseconds: 250);

  /// Shortest query that reads message text; one letter matches almost everything.
  static const minChars = 2;

  /// Chat id -> the line that matched, for up to [cap] of [ids] (pass them newest first).
  Future<Map<String, String>> search(Iterable<String> ids, String query) async {
    final q = query.trim().toLowerCase();
    final out = <String, String>{};
    if (q.length < minChars) return out;
    for (final id in ids.take(cap)) {
      List<Map<String, dynamic>>? rows;
      try {
        rows = await _rows(id);
      } catch (_) {
        rows = null;
      }
      if (rows == null) continue;
      final line = matchLine(rows, q);
      if (line != null) out[id] = line;
    }
    return out;
  }

  static final _replyHead = RegExp(r'^\[Reply to .+? · #[\w-]+\]\n> ?.*\n\n?');
  static final _noise = RegExp(r'<think(ing)?>[\s\S]*?(</think(ing)?>|$)|```[\s\S]*?(```|$)', caseSensitive: false);

  /// The first line of a user or assistant message containing [query], cut to about [width] characters
  /// around the match. Tool output, system rows, card fences and reply quotes are not searched.
  static String? matchLine(List<Map<String, dynamic>> rows, String query, {int width = 80}) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return null;
    // Newest first: the line most likely to be the one the user remembers.
    for (final r in rows.reversed) {
      final role = '${r['role'] ?? ''}';
      if (role != 'user' && role != 'assistant') continue;
      final text = '${r['content'] ?? ''}'.replaceFirst(_replyHead, '').replaceAll(_noise, ' ');
      if (!text.toLowerCase().contains(q)) continue;
      for (final raw in text.split('\n')) {
        final line = raw.replaceAll(RegExp(r'[#*_>`]+'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
        final at = line.toLowerCase().indexOf(q);
        if (at < 0) continue;
        if (line.length <= width) return line;
        var start = (at - width ~/ 3).clamp(0, line.length);
        final end = (start + width).clamp(0, line.length);
        if (end - start < width) start = (end - width).clamp(0, line.length);
        return '${start > 0 ? '…' : ''}${line.substring(start, end).trim()}${end < line.length ? '…' : ''}';
      }
    }
    return null;
  }
}
