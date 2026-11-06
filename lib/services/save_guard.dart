import 'mcp_routes.dart';

/// Stops a bot from saving the same thing over and over (owner bug 2026-11-06: "bots save responsibility notes
/// infinitely").
///
/// What happened (Weriye, 2026-11-05): asked for news "every hour", the bot had no way to say "every hour" with
/// bot_routine, so it made one daily routine per hour, one call at a time and some in parallel; two parallel calls
/// crashed on a list changed while it was walked, so it removed them all and started over, and again after the owner's
/// next message: 133 bot_routine calls and 25 "responsibilities" for one ask. Every call answered as a success, so
/// nothing told the model to stop.
///
/// Two rules, per caller ([scope]: the chat or team key the call routes to) and per turn:
/// - the same save with the same arguments again: answered with the first result, not run twice;
/// - more than [caps] saves of one kind in one turn (or in [window], for runs that never mark a turn): refused with a
///   line that says to stop and tell the owner what is set up.
/// Removing, listing and updating are never counted (a clean-up must always be possible). Pure, so it is tested
/// without the app.
class SaveGuard {
  SaveGuard({this.window = const Duration(minutes: 10), DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  static final SaveGuard I = SaveGuard();

  final Duration window;
  final DateTime Function() _clock;

  /// Saves of one kind allowed in one turn.
  static const caps = <String, int>{
    'bot_routine': 6,
    'bot_remember': 12,
    'bot_followup': 8,
    'bot_lesson': 6,
    'bot_watch': 6,
    'bot_desk': 25,
    'remember': 12,
  };

  static const _labels = <String, String>{
    'bot_routine': 'routines',
    'bot_remember': 'memory lines',
    'bot_followup': 'follow-ups',
    'bot_lesson': 'lessons',
    'bot_watch': 'watches',
    'bot_desk': 'desk tasks',
    'remember': 'memories',
  };

  final Map<String, List<({String key, String tool, DateTime at, String result})>> _done = {};

  /// Whether this call saves something new (and so counts): an add, never a remove, list or update.
  static bool isSave(String tool, Map<String, dynamic> args) {
    if (!caps.containsKey(tool)) return false;
    final action = '${args['action'] ?? ''}'.trim().toLowerCase();
    switch (tool) {
      case 'bot_remember':
        return '${args['forget'] ?? ''}'.trim().isEmpty && args['list'] != true && '${args['list']}' != 'true';
      case 'bot_followup':
      case 'remember':
        return true;
      case 'bot_routine':
        // A call with no action but a time, an instruction or a repeat is an add (see Bots.execute).
        return action == 'add' ||
            (action.isEmpty && ['instruction', 'time', 'repeat', 'every_hours', 'cron'].any((k) => '${args[k] ?? ''}'.trim().isNotEmpty));
      default:
        return action == 'add';
    }
  }

  void _prune(String scope) {
    final cut = _clock().subtract(window);
    _done[scope]?.removeWhere((e) => e.at.isBefore(cut));
    if (_done[scope]?.isEmpty ?? false) _done.remove(scope);
    if (_done.length > 200) _done.remove(_done.keys.first);
  }

  /// What to answer instead of running the call, or null to run it.
  String? before(String scope, String tool, Map<String, dynamic> args) {
    if (!isSave(tool, args)) return null;
    _prune(scope);
    final list = _done[scope] ?? const [];
    final key = McpRoutes.keyOf(tool, args);
    final same = list.where((e) => e.key == key).firstOrNull;
    if (same != null) {
      return 'Already done a moment ago: ${same.result} Nothing new was saved. Do not repeat this call; carry on with the task.';
    }
    final n = list.where((e) => e.tool == tool).length;
    final cap = caps[tool]!;
    if (n >= cap) {
      return 'Error: not saved. $n ${_labels[tool]} in this task is the limit. Do not call $tool again now'
          '${tool == 'bot_routine' ? ': a job that repeats is ONE routine with "repeat" (hourly or every_3_hours) or "every_hours", never one routine per time' : ''}. '
          'Tell the owner in one line what is set up.';
    }
    return null;
  }

  /// Notes a save that ran (an error is not noted: fixing the arguments and trying again is fine).
  void after(String scope, String tool, Map<String, dynamic> args, String result) {
    if (!isSave(tool, args) || result.startsWith('Error') || result.startsWith('Already done')) return;
    _prune(scope);
    final r = result.length > 160 ? '${result.substring(0, 159)}…' : result;
    (_done[scope] ??= []).add((key: McpRoutes.keyOf(tool, args), tool: tool, at: _clock(), result: r));
  }

  /// A new turn of [scope] starts (a new message, a wake, a team part): its counts start again.
  void newTurn(String scope) => _done.remove(scope);

  void clear() => _done.clear();
}
