/// Each picture is sent to the model once (PLAN 1.4). The first step after a photo arrives carries the picture; every
/// later step (in this task and the next ones) gets a one-line note instead, so long tasks don't re-upload the same
/// megabytes on every step. A picture counts as sent only when the step that carried it got an answer
/// ([commit]); a failed or restarted step sends it again.
class ImageOnce {
  final Map<String, Set<String>> _sent = {};
  final Map<String, Set<String>> _pending = {};

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
    if (p != null && p.isNotEmpty) (_sent[conv] ??= <String>{}).addAll(p);
  }

  /// "Regenerate" asks about the same photo again: let its pictures go out once more.
  void unsend(String conv, String messageId) {
    _sent[conv]?.removeWhere((k) => k.startsWith('$messageId#'));
  }

  bool wasSent(String conv, String key) => _sent[conv]?.contains(key) ?? false;

  void forget(String conv) {
    _sent.remove(conv);
    _pending.remove(conv);
  }

  /// The one-line note a later step gets in place of the picture.
  static String note(String name, String? localPath) =>
      '[Photo "$name" was shown to you earlier in this chat${localPath == null ? '' : ' (saved at $localPath)'}.]';
}
