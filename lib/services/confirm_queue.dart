import 'dart:async';

/// The in-app approval sheet, one ask at a time (approval cards bug hunt, 2026-10-24).
///
/// Before: every run that needed an OK opened its own sheet at once. Two tasks (two chats, or a browser task working
/// while another chat runs) stacked two sheets, the one underneath answered later than it looked, and a sheet from a
/// background chat popped up over whatever chat was open with nothing to say where it came from. Stopping a task left
/// its sheet up, and approving it then acted for a task that was already stopped.
///
/// Now asks wait their turn; an ask whose task was stopped while it waited is answered "no" without showing, and the
/// sheet that is up closes when its task is stopped.
class ConfirmQueue {
  Future<void> _tail = Future<void>.value();
  int _gen = 0;
  final Map<String, int> _stoppedAt = {};
  String? _openConv;
  Object? _openToken;
  void Function()? _close;

  /// The chat whose ask is on screen right now (null = none, or an ask with no chat).
  String? get openConv => _openConv;

  /// Shows [show] when every earlier ask is answered. False without showing when [convId]'s task stopped meanwhile.
  /// [token] names the ask (its request), so [closeFor] can close exactly this sheet.
  Future<bool> run(String? convId, Future<bool> Function() show, {Object? token}) async {
    final ticket = ++_gen;
    final before = _tail;
    final done = Completer<void>();
    _tail = done.future;
    try {
      await before;
      if (convId != null && (_stoppedAt[convId] ?? 0) > ticket) return false;
      _openConv = convId;
      _openToken = token;
      _close = null;
      return await show();
    } finally {
      _openConv = null;
      _openToken = null;
      _close = null;
      done.complete();
    }
  }

  /// The sheet now on screen tells the queue how to close it.
  void onClose(void Function() close) => _close = close;

  /// The ask [token] got no answer in time (CB-42): its sheet closes if it is the one on screen.
  void closeFor(Object token) {
    if (identical(_openToken, token)) _close?.call();
  }

  /// [convId]'s task was stopped: its waiting asks are dropped and its open sheet closes ("no").
  void stopped(String convId) {
    _stoppedAt[convId] = ++_gen;
    if (_openConv == convId) _close?.call();
  }
}
