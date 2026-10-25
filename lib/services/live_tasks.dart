/// Real, tracked background tasks started from a Live call, and the guard that stops the voice model from
/// claiming background work that does not exist. Pure Dart (unit tested).
library;

class LiveTask {
  LiveTask(this.id, this.title, this.convId, this.started);
  final String id;
  final String title;
  final String convId;
  final DateTime started;
  /// running | done | stopped | failed
  String status = 'running';
  String result = '';
  DateTime? ended;
  bool get running => status == 'running';
}

class LiveTasks {
  final List<LiveTask> _all = [];
  int _n = 0;

  List<LiveTask> get all => List.unmodifiable(_all);
  List<LiveTask> get running => _all.where((t) => t.running).toList();

  /// Registers a task that really started (the agent run exists). Ids are short so they can be said out loud: T1, T2...
  LiveTask start(String title, String convId, {DateTime? now}) {
    _n++;
    final t = LiveTask('T$_n', title.length > 120 ? '${title.substring(0, 120)}…' : title, convId, now ?? DateTime.now());
    _all.add(t);
    while (_all.length > 30) {
      _all.removeAt(0);
    }
    return t;
  }

  LiveTask? byId(String id) {
    final q = id.trim().toUpperCase();
    for (final t in _all) {
      if (t.id == q) return t;
    }
    return null;
  }

  LiveTask? runningIn(String convId) {
    for (final t in _all.reversed) {
      if (t.convId == convId && t.running) return t;
    }
    return null;
  }

  /// The agent run in [convId] ended. Returns the task it belonged to, if any.
  LiveTask? finish(String convId, {required String status, String result = '', DateTime? now}) {
    final t = runningIn(convId);
    if (t == null) return null;
    t.status = status;
    t.result = result;
    t.ended = now ?? DateTime.now();
    return t;
  }

  /// True when a task was started at or after [since] (this call) or is still running.
  bool anySince(DateTime since) => _all.any((t) => t.running || !t.started.isBefore(since));

  String statusText({String id = '', DateTime? now}) {
    final n = now ?? DateTime.now();
    final list = id.isEmpty ? _all.reversed.take(5).toList() : [if (byId(id) != null) byId(id)!];
    if (list.isEmpty) return id.isEmpty ? 'No background task was started. Nothing is running.' : 'There is no task $id.';
    String ago(DateTime d) {
      final m = n.difference(d).inMinutes;
      return m < 1 ? 'under a minute' : '$m min';
    }

    return [
      for (final t in list)
        switch (t.status) {
          'running' => '${t.id} "${t.title}": still running (${ago(t.started)} so far).',
          'done' => '${t.id} "${t.title}": done. ${t.result.isEmpty ? 'The details are in the chat.' : 'Result: ${t.result}'}',
          'stopped' => '${t.id} "${t.title}": stopped.',
          _ => '${t.id} "${t.title}": failed. ${t.result}',
        },
    ].join('\n');
  }
}

/// Catches the voice model saying work is happening in the background when no task was started.
class LiveGuard {
  static final _claim = RegExp(
      r"(in the background|"
      r"(i'?ll|i will|we'?ll) (let you know|report back|get back to you|tell you|update you|notify you) (when|once|as soon as)|"
      r"(i'?ll|i will) keep you (posted|updated)|"
      r"once (it'?s|it is) (done|finished|complete)[, ]+(i'?ll|i will)|"
      r"(gadaal|xagga dambe) (ka )?(ku )?(socda|shaqeynaya)|waan kuu soo sheegi doonaa marka|"
      r"في الخلفية|سأخبرك (عندما|حين)|سأبلغك)",
      caseSensitive: false);

  static bool claimsBackground(String text) => _claim.hasMatch(text);

  /// The note to inject when [text] claims background work and no real task backs it, else null.
  static String? correction(String text, {required bool taskStarted}) {
    if (taskStarted || !claimsBackground(text)) return null;
    return '(Note from the app, not the user: nothing is running in the background. No task was started, so nothing '
        'will be reported later. Correct yourself in one short sentence, then either do it now with your tools '
        '(open_app, phone_screen, phone_tap, phone_type, whatsapp...), or call live_task to start a real tracked task, '
        'or say plainly that you cannot.)';
  }
}
