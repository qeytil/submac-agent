// Bots working with SubMac closed (owner bug 2026-11-05: "bots cannot do scheduled background tasks without me
// opening the app"). The rules a run nobody is watching follows, kept here as plain functions so they are tested
// without a phone. The flow end to end is in docs/bots-background.md.
import 'dart:async';

import 'trust.dart';

/// Alarms that reach Dart before SubMac has loaded its bots and scheduled tasks wait here, in order, and run once it
/// has. Android hands the alarm over as soon as Dart says it is ready to listen, which is before the bots and the
/// scheduled tasks are loaded: a scheduled task fired then found no task (Scheduler not loaded), was dropped and
/// turned the foreground service off.
class AlarmGate {
  AlarmGate({this.maxWait = const Duration(seconds: 45)});

  /// The longest an alarm waits for the start-up: after that it runs anyway (a slow or failed step must never
  /// swallow it).
  final Duration maxWait;
  final _ready = Completer<void>();

  bool get isOpen => _ready.isCompleted;

  /// SubMac finished starting up: waiting alarms run now, in the order they came.
  void open() {
    if (!_ready.isCompleted) _ready.complete();
  }

  /// Runs [f] once SubMac is ready (or after [maxWait]).
  Future<void> run(Future<void> Function() f) async {
    if (!isOpen) {
      await _ready.future.timeout(maxWait, onTimeout: () {});
    }
    await f();
  }
}

/// What a bot run nobody is watching does where a run on screen would ask the owner.
class BgRun {
  BgRun._();

  /// How long a bot working in the background waits on an approval notification before it moves on (it used to wait
  /// three hours, holding the phone awake, with the task stuck until the app was opened).
  static Duration approvalWait = const Duration(minutes: 3);

  /// The retries for a wake held because SubMac was not ready yet (no account restored, cold start offline). They
  /// used to run only when the home screen opened.
  static List<Duration> heldRetries = const [Duration(seconds: 15), Duration(seconds: 45), Duration(minutes: 2)];

  /// The work runs unattended: a bot's own wake (not a chat with the owner) or a scheduled run, and the owner is not
  /// looking at that chat.
  static bool unattended({String? wakeKind, required bool scheduled, required bool onScreen}) {
    if (onScreen) return false;
    return scheduled || (wakeKind != null && wakeKind != 'chat');
  }

  /// The ongoing notification while the bot works: "<Bot name> · <task title>".
  static String line(String botName, String title) {
    final n = botName.trim().isEmpty ? 'SubMac' : botName.trim();
    final t = title.trim();
    return t.isEmpty ? n : '$n · $t';
  }

  /// A short title for the notification: the task's first line, or [fallback] (a check-in has no instruction).
  static String title(String instruction, {String fallback = 'Check-in', int max = 48}) {
    var t = instruction.replaceAll(RegExp(r'^\(retry\)\s*'), '').split('\n').first.replaceAll(RegExp(r'[#*_`]'), '').trim();
    if (t.isEmpty) t = fallback;
    if (t.length > max) t = '${t.substring(0, max - 1).trimRight()}…';
    return t;
  }

  /// opencode asks before a shell command (bash), a file outside the workspace (external_directory) or a repeated
  /// step (doom_loop). With nobody to answer, the run must not wait on a card. 'once' = allowed because the owner
  /// already allowed this kind of work (Full access, or the bot works "On its own"); 'reject' = refused at once, and
  /// the owner is told what was needed. A repeated step is always stopped.
  static String permission({required String perm, required bool fullAccess, required String botLevel}) {
    if (perm == 'doom_loop') return 'reject';
    if (fullAccess) return 'once';
    if (botLevel == BotTrust.levelTrusted && (perm == 'bash' || perm == 'edit' || perm == 'webfetch')) return 'once';
    return 'reject';
  }

  /// The notification that says what the work needed when it could not ask.
  static String needs(String what) {
    final w = what.trim().replaceAll(RegExp(r'\s+'), ' ');
    final cut = w.length > 90 ? '${w.substring(0, 89).trimRight()}…' : w;
    return 'Needs your OK: ${cut.isEmpty ? 'an action' : cut}. Open SubMac to allow it.';
  }

  /// How a bot's result reaches the owner. A result they asked for on a schedule (a "message" routine or scheduled
  /// task) always notifies, outside quiet hours: the bot's daily message cap is for messages it starts itself (owner
  /// 2026-11-05: an hourly news task went quiet after the third run). [allowed] is what Bots.allow gave.
  static String outreach({required String wakeKind, required String want, required String allowed, required bool quiet}) {
    if (wakeKind == 'message' && want == 'message' && allowed == 'note' && !quiet) return 'message';
    return allowed;
  }

  /// What opencode's tool is told when a permission was refused because nobody is watching.
  static const refusedNote = 'Not allowed in a background run (nobody is watching to approve it).';
}
