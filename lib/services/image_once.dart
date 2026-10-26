import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Each picture is sent to the model once (PLAN 1.4). The first step after a photo arrives carries the picture; every
/// later step (in this task and the next ones) gets a one-line note instead, so long tasks don't re-upload the same
/// megabytes on every step. A picture counts as sent only when the step that carried it got an answer
/// ([commit]); a failed or restarted step sends it again.
///
/// CB-31: the sent keys are kept on the phone ([ImageOnceStore]), so a restart does not send every picture in the
/// history out again.
class ImageOnce {
  final Map<String, Set<String>> _sent = {};
  final Map<String, Set<String>> _pending = {};
  final ImageOnceStore _store;

  /// Completes when the kept keys are loaded.
  late final Future<void> ready;

  ImageOnce({ImageOnceStore? store}) : _store = store ?? PrefsImageOnceStore() {
    ready = _load();
  }

  /// At most this many chats and keys per chat are kept (oldest first out).
  static const keepChats = 200, keepKeys = 200;

  Future<void> _load() async {
    try {
      final kept = await _store.read();
      for (final e in kept.entries) {
        // Merge: a commit that happened before the load finished stays.
        (_sent[e.key] ??= <String>{}).addAll(e.value);
      }
    } catch (_) {}
  }

  void _save() {
    final out = <String, List<String>>{};
    final convs = _sent.keys.where((c) => _sent[c]!.isNotEmpty).toList();
    for (final c in convs.skip(convs.length > keepChats ? convs.length - keepChats : 0)) {
      final keys = _sent[c]!.toList();
      out[c] = keys.length > keepKeys ? keys.sublist(keys.length - keepKeys) : keys;
    }
    _store.write(out).catchError((_) {});
  }

  static String keyOf(String messageId, int index) => '$messageId#$index';

  /// A payload for [conv] is being built: forget what an earlier, unanswered build planned to send.
  void begin(String conv) => _pending[conv] = <String>{};

  /// True when the picture still has to go out (and remembers it for [commit]); false = send the note instead.
  bool take(String conv, String key) {
    if (_sent[conv]?.contains(key) ?? false) return false;
    (_pending[conv] ??= <String>{}).add(key);
    return true;
  }

  /// The step that carried the pictures got an answer: from now on they are notes.
  void commit(String conv) {
    final p = _pending.remove(conv);
    if (p == null || p.isEmpty) return;
    // Newest chat last, so the oldest is dropped first when [keepChats] is reached.
    final had = _sent.remove(conv) ?? <String>{};
    _sent[conv] = had..addAll(p);
    _save();
  }

  /// "Regenerate" asks about the same photo again: let its pictures go out once more.
  void unsend(String conv, String messageId) {
    _sent[conv]?.removeWhere((k) => k.startsWith('$messageId#'));
    _save();
  }

  bool wasSent(String conv, String key) => _sent[conv]?.contains(key) ?? false;

  /// Everything forgotten (all chats were deleted).
  void clear() {
    _sent.clear();
    _pending.clear();
    _save(); // CB-18 clear x CB-31 kept keys: the persisted keys of the deleted chats go too
  }

  void forget(String conv) {
    _sent.remove(conv);
    _pending.remove(conv);
    _save();
  }

  /// The one-line note a later step gets in place of the picture.
  static String note(String name, String? localPath) =>
      '[Photo "$name" was shown to you earlier in this chat${localPath == null ? '' : ' (saved at $localPath)'}.]';
}

/// Where [ImageOnce] keeps its sent keys between app runs (CB-31).
abstract class ImageOnceStore {
  Future<Map<String, List<String>>> read();
  Future<void> write(Map<String, List<String>> sent);
}

/// The phone's preferences: one small JSON map, chat id -> picture keys.
class PrefsImageOnceStore implements ImageOnceStore {
  static const key = 'image_once_sent_v1';

  @override
  Future<Map<String, List<String>>> read() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(key);
    if (raw == null || raw.isEmpty) return {};
    final j = jsonDecode(raw);
    if (j is! Map) return {};
    return {
      for (final e in j.entries)
        if (e.value is List) '${e.key}': [for (final k in e.value as List) '$k'],
    };
  }

  @override
  Future<void> write(Map<String, List<String>> sent) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(key, jsonEncode(sent));
  }
}
