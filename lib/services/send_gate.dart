import 'dart:async';

/// One run per chat, claimed at the very top of `send()` before anything is awaited (PLAN 1.4).
///
/// Without it a second message sent while the first was still saving or uploading its photo found no task running
/// and started a second agent: two answers, two charges. Now the first send claims the chat at once; a message sent
/// while the claim is open waits until the first message is saved, then joins the same task (its words are in the
/// chat the task reads, or reach it through the task's inbox once its first step has started).
class SendGate {
  /// The key for a chat that has no id yet (its first message is creating it).
  static const newChat = '\u0000new';

  final Map<String, SendClaim> _claims = {};

  static String keyOf(String? convId) => convId ?? newChat;

  /// The open claim on this chat, if a send is still getting ready.
  SendClaim? openOn(String? convId) {
    final c = _claims[keyOf(convId)];
    return c == null || c.released ? null : c;
  }

  /// Claims the chat. Synchronous on purpose: call it before the first await in send().
  SendClaim claim(String? convId) {
    final c = SendClaim._(this, keyOf(convId));
    _claims[c._keys.first] = c;
    return c;
  }

  /// The user left the new-chat draft ("+" again, or opened another chat) while its first message was still saving.
  /// That claim keeps covering its own chat (by id, once created), but the next new draft is a different chat:
  /// a message typed there must never wait on it and end up in the first chat.
  void forgetNewChat() => _claims.remove(newChat);

  void _drop(SendClaim c) {
    for (final k in c._keys) {
      if (identical(_claims[k], c)) _claims.remove(k);
    }
  }
}

class SendClaim {
  SendClaim._(this._gate, String key) : _keys = [key];
  final SendGate _gate;
  final List<String> _keys;
  final Completer<String?> _ready = Completer<String?>();
  bool released = false;

  /// The chat got its id (a new chat was created): the claim covers that id too.
  void alias(String convId) {
    if (released || _keys.contains(convId)) return;
    _keys.add(convId);
    _gate._claims[convId] = this;
  }

  /// Completes with the chat id once the first message is saved (null when it could not be saved).
  Future<String?> get ready => _ready.future;

  /// The first message is saved and its task is about to start (or it failed: [convId] null). Releases the claim:
  /// from here the task itself is in the run list, and later messages reach it the usual way.
  void open(String? convId) {
    if (released) return;
    released = true;
    _gate._drop(this);
    if (!_ready.isCompleted) _ready.complete(convId);
  }
}
