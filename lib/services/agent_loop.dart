import 'dart:async';
import 'dart:convert';

/// The thinking parts of SubMac's agent loop, kept pure (no Flutter, no state) so they are unit-tested and the
/// loop in app_state.dart stays readable. Ideas borrowed from open projects are listed in docs/third-party.md:
///  - stuck detection (OpenHands StuckDetector, MIT; Roo Code ToolRepetitionDetector, Apache-2.0)
///  - parallel independent tool calls (smolagents ToolCallingAgent, Apache-2.0; LangGraph ToolNode, MIT)
///  - observation masking of old results (SWE-agent LastNObservations, MIT)
///  - stable prefix + recitation at the end of the context (Manus "Context Engineering" blog, ideas only)
///  - graceful step budgets (OpenAI Agents SDK max_turns, MIT)
/// All code here is our own Dart; nothing was copied.

// ---------------------------------------------------------------------------------------------------------------
// Stuck / loop detection
// ---------------------------------------------------------------------------------------------------------------

/// What kind of loop the agent is in.
enum LoopKind { none, repeat, pingPong, repeatedError, failingTool }

class LoopSignal {
  const LoopSignal(this.kind, {this.tool = ''});
  final LoopKind kind;
  final String tool;
  bool get stuck => kind != LoopKind.none;

  /// A loop means the current model is not finding a way: a stronger one should drive the rest of the task.
  bool get escalate => kind == LoopKind.repeat || kind == LoopKind.pingPong || kind == LoopKind.repeatedError;

  static const none = LoopSignal(LoopKind.none);

  /// The note the model reads at the end of its next request.
  String get guidance {
    switch (kind) {
      case LoopKind.none:
        return '';
      case LoopKind.repeat:
        return '# You are repeating yourself\n'
            'Your last actions were the same and did not move the task on. Do not do it again. '
            'Look at the latest result, then take a different path (another element, scroll, go back, a direct link, another site or tool). '
            'If nothing can work, tell the user plainly what blocks you and what they can do.';
      case LoopKind.pingPong:
        return '# You are going back and forth\n'
            'You keep switching between the same two actions without progress. Stop that pattern: decide what you actually '
            'need, then take one new action that gets it, or tell the user plainly what blocks you.';
      case LoopKind.repeatedError:
        return '# The same call keeps failing\n'
            'Your last calls to $tool were identical and all failed. Do not send it again unchanged. Read the error, change '
            'the inputs or use another way${ToolRecovery.alternatives(tool).isEmpty ? '' : ' (${ToolRecovery.alternatives(tool)})'}.';
      case LoopKind.failingTool:
        return '# $tool is not working right now\n'
            'It failed several times in a row. Use another way${ToolRecovery.alternatives(tool).isEmpty ? '' : ': ${ToolRecovery.alternatives(tool)}'}. '
            'If there is none, tell the user in one plain line what did not work and what they can do.';
    }
  }
}

/// Watches the tool calls of one task and notices when it is stuck. Patterns (thresholds as in OpenHands):
///  repeat         same call and same result 3 times, or the same call 6 times whatever it returned
///                 (scrolling and waiting may legitimately repeat: 9 times for those)
///  repeatedError  same call failing 3 times in a row
///  failingTool    the same tool failing 3 times in a row with different inputs
///  pingPong       A B A B A B with two different calls
class LoopGuard {
  final List<_Step> _steps = [];
  static const _window = 12;

  /// Patient tools: repeating them is often the right thing (scroll to find something, wait for a page).
  static const _patient = {'phone_scroll', 'browser_scroll', 'phone_wait', 'browser_wait', 'browser_task_wait', 'phone_swipe', 'browser_swipe'};

  void record(String name, String args, String output) {
    _steps.add(_Step('$name ${canonicalArgs(args)}', name, _digest(output), ToolRecovery.isError(output)));
    if (_steps.length > _window) _steps.removeAt(0);
  }

  /// Start over (after a nudge was given, or the user spoke). The strike count stays: it is for the whole task.
  void reset() => _steps.clear();

  /// How many stuck notes this task already got. After [maxStrikes] the task stops instead of being nudged again
  /// (before, a model that ignored the note was nudged every three steps until the 1000-step ceiling).
  int strikes = 0;
  static const maxStrikes = 3;

  /// Counts one stuck note; true when this was the last one allowed and the task must wrap up now.
  bool strike() => ++strikes >= maxStrikes;

  /// The last note: stop using tools and tell the user plainly.
  static const giveUp = '# You are stuck: stop now\n'
      'The same thing has failed or repeated several times despite earlier notes. Call no more tools. In two or three plain '
      'lines tell the user what you tried, what blocked it, and what they could do or tell you (another site, a detail, a '
      'login) so you can carry on.';

  int get length => _steps.length;

  LoopSignal check() {
    final n = _steps.length;
    if (n >= 3) {
      final l3 = _steps.sublist(n - 3);
      final sameCall = l3.every((s) => s.sig == l3.last.sig);
      if (sameCall && l3.every((s) => s.error)) return LoopSignal(LoopKind.repeatedError, tool: l3.last.name);
      if (sameCall && !_patient.contains(l3.last.name) && l3.every((s) => s.out == l3.last.out)) {
        return LoopSignal(LoopKind.repeat, tool: l3.last.name);
      }
      if (l3.every((s) => s.error && s.name == l3.last.name)) return LoopSignal(LoopKind.failingTool, tool: l3.last.name);
    }
    // Core loop v3: the "same call six times, whatever it returned" rule is gone. Polling a build, a job or a page that
    // is still changing is legitimate; only the same call with the SAME result is a loop. Patient tools (scroll, wait)
    // get nine identical tries instead of three.
    if (n >= 9 && _patient.contains(_steps.last.name)) {
      final tail = _steps.sublist(n - 9);
      if (tail.every((s) => s.sig == tail.last.sig && s.out == tail.last.out)) return LoopSignal(LoopKind.repeat, tool: tail.last.name);
    }
    if (n >= 6) {
      final t = _steps.sublist(n - 6);
      final a = t[0].sig, b = t[1].sig;
      if (a != b && t[2].sig == a && t[4].sig == a && t[3].sig == b && t[5].sig == b) {
        return LoopSignal(LoopKind.pingPong, tool: t[5].name);
      }
    }
    return LoopSignal.none;
  }

  /// Arguments in a stable form (keys sorted, spacing ignored) so {"a":1,"b":2} equals {"b": 2, "a": 1}.
  static String canonicalArgs(String args) {
    final t = args.trim();
    if (t.isEmpty) return '{}';
    try {
      return jsonEncode(_sorted(jsonDecode(t)));
    } catch (_) {
      return t.replaceAll(RegExp(r'\s+'), ' ');
    }
  }

  static dynamic _sorted(dynamic v) {
    if (v is Map) {
      final keys = v.keys.map((k) => '$k').toList()..sort();
      return {for (final k in keys) k: _sorted(v[k])};
    }
    if (v is List) return [for (final e in v) _sorted(e)];
    return v;
  }

  static int _digest(String s) => s.length > 4000 ? Object.hash(s.length, s.substring(0, 2000), s.substring(s.length - 2000)) : s.hashCode;
}

class _Step {
  _Step(this.sig, this.name, this.out, this.error);
  final String sig;
  final String name;
  final int out;
  final bool error;
}

// ---------------------------------------------------------------------------------------------------------------
// Parallel tool calls
// ---------------------------------------------------------------------------------------------------------------

/// Plans which tool calls of one reply may run at the same time. Only calls that read and change nothing are run
/// together, and only when they sit next to each other: anything that changes something (a file, a screen, a page,
/// a message) is a barrier and runs alone, in order. Results always go back to the model in the original order.
class ParallelPlan {
  /// Read-only tools: safe to run side by side.
  static const safe = {
    'web_search', 'fetch_url', 'wikipedia', 'get_weather', 'currency_convert', 'find_place', 'read_rss', 'youtube_transcript',
    'list_memories', 'recall', 'skill_search', 'skill_use', 'knowledge_search', 'knowledge_read',
    'read_file', 'list_dir', 'read_pdf', 'read_text_in_image', 'read_document', 'calculate', 'docs_list', 'docs_read',
    'prayer_times', 'hijri_date', 'qibla', 'quran', 'money_report', 'somali_knowledge', 'somali_knowledge_read',
    'email_list', 'email_read', 'email_search', 'apps_list_tools', 'list_scheduled', 'list_mcp',
    'browser_task_status', 'task_status',
  };

  /// Most calls run at once (keeps the phone and the network calm).
  static const maxTogether = 6;

  static bool isSafe(String name) => safe.contains(name);

  /// Batches of call indexes, in order. [names] are the tool names; [broken] marks calls whose arguments did not
  /// parse (they run alone, so their error is reported in place).
  static List<List<int>> batches(List<String> names, {Set<int> broken = const {}, int max = maxTogether}) {
    final out = <List<int>>[];
    List<int>? cur;
    for (var i = 0; i < names.length; i++) {
      final ok = isSafe(names[i]) && !broken.contains(i);
      if (ok && cur != null && cur.length < max) {
        cur.add(i);
        continue;
      }
      cur = [i];
      out.add(cur);
      if (!ok) cur = null;
    }
    return out;
  }

  /// Runs [run] for every index of [batch] at once and returns the outputs in the batch's order.
  static Future<List<String>> runBatch(List<int> batch, Future<String> Function(int index) run) =>
      Future.wait([for (final i in batch) run(i)]);
}

// ---------------------------------------------------------------------------------------------------------------
// Tool results: clipping, masking, recovery
// ---------------------------------------------------------------------------------------------------------------

class ResultClip {
  /// A fresh result larger than this is cut in the middle (head and tail kept: the end often holds the error or the
  /// total). ~5k tokens; a web page used to go in at up to 30k characters and was re-sent for three more steps.
  static const freshMax = 20000;

  static String fresh(String v, {int max = freshMax}) {
    if (v.length <= max) return v;
    final headLen = (max * 0.8).floor();
    final tailLen = (max * 0.15).floor();
    var head = v.substring(0, headLen);
    final nl = head.lastIndexOf('\n');
    if (nl > headLen * 0.7) head = head.substring(0, nl);
    var tail = v.substring(v.length - tailLen);
    final nl2 = tail.indexOf('\n');
    if (nl2 >= 0 && nl2 < tailLen * 0.3) tail = tail.substring(nl2 + 1);
    final cut = v.length - head.length - tail.length;
    return '$head\n…[$cut characters cut from the middle to save room. If you need that part, read it again with a narrower request.]\n$tail';
  }

  /// An older result (masked observation): its start and end, enough to remember what it said. Errors are short
  /// and kept whole. Deterministic, so the same old result is byte-identical on every step (cache-friendly).
  static String old(String v) {
    if (v.length <= 600) return v;
    var cut = 380;
    final nl = v.lastIndexOf('\n', 380);
    if (nl > 250) cut = nl;
    var tail = v.substring(v.length - 120);
    final nl2 = tail.indexOf('\n');
    if (nl2 >= 0 && nl2 < 60) tail = tail.substring(nl2 + 1);
    return '${v.substring(0, cut)}\n…(older result trimmed)…\n$tail';
  }
}

class ToolRecovery {
  static final _err = RegExp(
      r'^\s*(error\b|error:|failed\b|could not\b|couldn.t\b|not allowed\b|not set up\b|timed out\b|no results\b|nothing found\b)|took too long|\bstatus (4|5)\d\d\b|\bHTTP (4|5)\d\d\b',
      caseSensitive: false);

  static bool isError(String output) => _err.hasMatch(output.length > 300 ? output.substring(0, 300) : output);

  static final _transient = RegExp(
      r'took too long|timed? ?out|timeout|connection (reset|closed|refused|failed)|socketexception|network|temporar|try again later|'
      r'\b(502|503|504|429)\b|too many requests|unavailable|handshake',
      caseSensitive: false);

  /// A failure worth one quiet retry: a read-only call that hit a network hiccup.
  static bool retryOnce(String name, String output) =>
      ParallelPlan.isSafe(name) && isError(output) && _transient.hasMatch(output.length > 400 ? output.substring(0, 400) : output);

  /// A step a person would call a failure: a tool error, an action the user refused, or a command that exited
  /// badly. One rule for the loop, the transcript and the "How I did it" list, so they never disagree.
  static bool stepFailed(String output) =>
      output.startsWith('Error') ||
      output.startsWith('The user said no') ||
      RegExp(r'^exit_code: [1-9-]').hasMatch(output) ||
      isError(output);

  /// Another way to get the same thing, in plain words for the model. Empty when there is no honest second
  /// route. Exact routes first, then by family, so the long tail of tools never dead-ends on its first failure.
  static String alternatives(String name) {
    switch (name) {
      case 'fetch_url':
        return 'try web_search for another source, or browser_open for pages that need a real browser';
      case 'web_search':
        return 'try different words, wikipedia, or fetch_url on a site you know has it';
      case 'wikipedia':
        return 'try web_search';
      case 'browser_task':
      case 'browser_open':
      case 'browser_click':
      case 'browser_tap_at':
        return 'try fetch_url for reading, a direct link, or another site';
      case 'browser_read':
        return 'try browser_view first, then fetch_url on the same address';
      case 'browser_login':
        return 'ask the user to sign in once in the browser, then carry on without signing in again';
      case 'find_place':
        return 'try web_search with the place and city';
      case 'get_weather':
        return 'try web_search "weather <city>"';
      case 'read_pdf':
        return 'try read_document, or read_text_in_image for scanned pages';
      case 'read_document':
        return 'try read_pdf, or read_file when it is plain text';
      case 'phone_tap':
      case 'phone_long_press':
      case 'phone_type':
        return 'try open_link with a deep link, or phone_screen then another element';
      case 'phone_screen':
        return 'try phone_nav to bring the app back, or open_app';
      case 'apps_run_tool':
      case 'apps_list_tools':
        return 'check the tool and its ids with apps_list_tools, or ask the user to reconnect the app';
      case 'run_shell':
        return 'try read_file, write_file, list_dir or code_run instead of a raw shell command';
      case 'email_send':
        return 'confirm the address with email_list, or save the text with note and tell the user to send it';
      case 'email_read':
      case 'email_search':
        return 'try email_list, or a different search word';
      case 'send_sms':
        return 'try open_link with an sms: link, or share_text and let the user tap send';
      case 'call_number':
        return 'try open_link with a tel: link';
      case 'add_calendar_event':
      case 'phone_calendar_add':
        return 'read the day with phone_calendar first, or use open_link with a calendar link';
      case 'generate_image':
      case 'generate_video':
        return 'try a shorter, plainer prompt, or use an existing image found with web_search';
      case 'code_run':
      case 'code_build':
        return 'try code_check or code_search to see the real error, then a smaller step';
      case 'schedule_task':
      case 'cancel_scheduled':
        return 'check what is set with list_scheduled, or do the step now';
      case 'read_file':
      case 'edit_file':
      case 'append_file':
        return 'list the folder with list_dir first, then read the exact path';
      case 'write_file':
        return 'write to a shorter path in the workspace, or build it in parts with append_file';
      case 'list_dir':
        return 'try run_shell with pwd and ls to see where the workspace is';
      case 'share_text':
        return 'try open_link, or write_file then open the file';
      case 'read_sms':
      case 'read_notifications':
        return 'ask the user to read it to you if the phone does not allow access';
    }
    if (name.startsWith('browser_')) return 'use fetch_url for reading, or browser_read, or a direct link';
    if (name.startsWith('phone_')) return 'use open_link or open_app, or phone_screen then another element';
    if (name.startsWith('biz_')) return 'check biz_setup and biz_records, or record it as a note and tell the user';
    if (name.startsWith('health_')) return 'check health_check and health_people, or log it as a note';
    if (name.startsWith('money_')) return 'check money_report, or add the entry with money_add';
    if (name.startsWith('docs_')) return 'try docs_read or read_document, or fetch_url on the shared link';
    if (name.startsWith('skill_')) return 'search again with skill_search, or do the task directly without a skill';
    if (name.startsWith('code_')) return 'use code_search to find the file, or code_run for a smaller step';
    if (name.startsWith('office_')) return 'check office_board, or ask the owner with office_ask_owner';
    if (name.startsWith('bot_')) return 'check bot_desk, or send the message in the chat app directly';
    if (name.startsWith('apps_')) return 'list the app tools with apps_list_tools, or ask the user to reconnect the app';
    return '';
  }

  /// Marks a result that already carries a hint, so it is never added twice.
  static const _hintMark = '(That did not work. Another way:';

  /// What the model reads after a call: the result itself, plus another route when it failed, so a dead end is
  /// never repeated. A successful result is returned untouched, and a made-up route is never added.
  static String withHint(String name, String output) {
    if (output.trim().isEmpty || !isError(output) || output.contains(_hintMark)) return output;
    final alt = alternatives(name);
    if (alt.isEmpty) return output;
    return '$output\n\n(That did not work. Another way: $alt. '
        'Do not send the same call again; if none of this can work, tell the user in one plain line what blocked you.)';
  }
}

// ---------------------------------------------------------------------------------------------------------------
// Planning: when a request needs a visible checklist (one model, PLAN 1.1: nothing here ever picks a model)
// ---------------------------------------------------------------------------------------------------------------

class TurnRouter {
  /// A request that clearly needs a plan (several instructions, a build, a long brief). Used to start the checklist
  /// early, not to pick a slower model.
  static bool needsPlan(String text) {
    final t = text.trim();
    if (t.length > 600) return true;
    final asks = RegExp(r'(^|\n)\s*(\d+[.)]|[-*•])\s+').allMatches(t).length;
    if (asks >= 3) return true;
    return RegExp(r'\b(build|create|make|design|develop|write)\b.{0,40}\b(web ?site|app|game|shop|store|landing|system|platform|business plan|report|book)\b',
            caseSensitive: false)
        .hasMatch(t);
  }
}

// ---------------------------------------------------------------------------------------------------------------
// Context engineering: notes at the end, checklist recitation, step budget, final answer shape
// ---------------------------------------------------------------------------------------------------------------

class TailNote {
  static const open = '<app-note>\n(From the SubMac app, not from the user. Follow it; never mention it.)\n';
  static const close = '\n</app-note>';

  /// Puts this step's notes at the end of the request instead of inside the system prompt, so the system prompt and
  /// the history stay byte-identical from one step to the next and the provider's prefix cache keeps hitting.
  ///
  /// The user's words are always the last thing the model reads:
  ///  - when the request ends on the newest user message, the note goes in FRONT of their words (same message);
  ///  - otherwise (later steps, after tool results) a short user message carries the note, then [request]: the task
  ///    in the user's own words, recited verbatim and marked as theirs (see [TaskBrief.recital]).
  /// Never stored in the chat.
  static List<Map<String, dynamic>> attach(List<Map<String, dynamic>> payload, String? note, {String request = ''}) {
    final n = note?.trim() ?? '';
    final r = request.trim();
    if ((n.isEmpty && r.isEmpty) || payload.isEmpty) return payload;
    final text = n.isEmpty ? '' : '$open$n$close';
    final out = List<Map<String, dynamic>>.of(payload);
    final last = out.last;
    if (last['role'] == 'user') {
      if (text.isEmpty) return payload;
      final c = last['content'];
      if (c is String) {
        out[out.length - 1] = {...last, 'content': '$text\n\n$c'};
        return out;
      }
      if (c is List) {
        out[out.length - 1] = {
          ...last,
          'content': [{'type': 'text', 'text': text}, ...c],
        };
        return out;
      }
    }
    out.add({'role': 'user', 'content': [if (text.isNotEmpty) text, if (r.isNotEmpty) r].join('\n\n')});
    return out;
  }

  /// The text the model reads last in [payload] (for tests and checks).
  static String lastText(List<Map<String, dynamic>> payload) {
    if (payload.isEmpty) return '';
    final c = payload.last['content'];
    if (c is String) return c;
    if (c is List) {
      for (final p in c.reversed) {
        if (p is Map && p['type'] == 'text') return '${p['text']}';
      }
    }
    return '';
  }
}

/// The task as the user asked for it: their original request plus every change they made while it ran. A correction
/// mid-task AMENDS the request (original + change); it replaces it only when the user clearly drops the old one.
class TaskBrief {
  TaskBrief(String original) : original = original.trim();

  final String original;
  final List<String> changes = [];

  /// Most characters recited from one message (longer ones are already in full a few messages up).
  static const reciteMax = 1500;

  void amend(String text) {
    final t = text.trim();
    if (t.isEmpty || t == original || changes.contains(t)) return;
    changes.add(t);
    if (changes.length > 6) changes.removeAt(0);
  }

  bool get isEmpty => original.isEmpty && changes.isEmpty;

  static String _quote(String s) {
    final t = s.trim();
    if (t.length <= reciteMax) return '"$t"';
    return '"${t.substring(0, 1150)} … ${t.substring(t.length - 300)}" (long; the full text is above)';
  }

  /// The user's request, verbatim, for the very end of a later step. Empty for app-made wakes.
  String recital({String must = ''}) {
    if (isEmpty) return '';
    final sb = StringBuffer('# Reminder of the task (the user\'s own words; not a new message: carry on from where you are)\n');
    if (original.isNotEmpty) sb.writeln(_quote(original));
    if (changes.isNotEmpty) {
      sb.writeln('Then, during the task, they said (each one amends the request above; keep everything it does not change):');
      for (final c in changes) {
        sb.writeln('- ${_quote(c)}');
      }
    }
    if (must.isNotEmpty) sb.writeln(must);
    return sb.toString().trim();
  }

  /// Read when the user writes while the task runs: amend the task, do not replace it.
  static String steer(String said, {required bool acked}) =>
      '# The user just spoke to you during this task\n'
      'Their words: $said\n'
      'This amends the task: keep their original request and everything they asked for in it, and apply this change '
      '(a different site, a step skipped or added, a detail changed). Drop the original only if they clearly say to stop or '
      'start something else. '
      '${acked ? 'A quick reply already answered them, so do not repeat it: act on it straight away' : 'In this reply, first call `say` with one short, plain sentence that answers them or says what you will do now, then act on it straight away in the same reply'}. '
      'If they asked you to stop, say so and end the task with no more tools.';
}

class Recite {
  /// The task's checklist, recited at the end of every step while it is open (keeps the plan in the model's recent
  /// attention on long tasks). When every step is done, it turns into the final check.
  static String checklist(List<String> todo, Set<int> done) {
    if (todo.isEmpty) return '';
    final next = [for (var i = 0; i < todo.length; i++) if (!done.contains(i)) i];
    if (next.isEmpty) return finalCheck(allDone: true);
    final sb = StringBuffer('# Your checklist (${done.length}/${todo.length} done)\n');
    for (var i = 0; i < todo.length; i++) {
      sb.writeln('${i + 1}. [${done.contains(i) ? 'x' : ' '}] ${todo[i]}${i == next.first ? '  <- now' : ''}');
    }
    sb.write('Work on the step marked now; mark steps done with todo as you finish them.');
    return sb.toString();
  }

  /// Self-check before the final answer (reflection without an extra model call) and the shape of a good final
  /// reply for someone who is not technical.
  static String finalCheck({bool allDone = false, String selfCheck = ''}) =>
      '# Before your final reply\n'
      '${allDone ? 'Every checklist step is marked done. ' : ''}${selfCheck.isEmpty ? '' : '$selfCheck '}Re-read the user\'s request and check the result against each thing they asked for '
      '(name, details, language, length, style). If something is missing or a tool result did not confirm it, fix it now with your tools. '
      'Then reply: lead with the result in plain words (what they get and where), then at most three short lines on what you did or what is left, '
      'then the one next step they can tap or say. No tool names, no raw JSON, no file paths in the text (use a ```file card).';
}

class StepBudget {
  /// Two steps before the task really stops: wrap up gracefully instead of stopping mid-way.
  ///
  /// [limit] is the checkpoint period. A checkpoint is not the end: the task carries on there while it makes
  /// progress, so the note is only given when the caller says the task [willPause] at the coming checkpoint, or two
  /// steps before the hard [ceiling]. (Before, the note fired at step 48 of every task, so long tasks wrapped up and
  /// asked for "continue" although they would have gone on, and later checkpoints got no wrap-up at all.)
  static String? note(int step, int limit, {bool willPause = true, int ceiling = 0}) {
    if (ceiling > 0 && step == ceiling - 2) return _text;
    if (limit < 6 || step < limit - 2 || (step + 2) % limit != 0 || !willPause) return null;
    return _text;
  }

  static const _text = '# Two steps left for this task\n'
      'Finish the most important part now. In your next reply call no more tools unless one is essential: tell the user '
      'what is done, what is left, and that they can send "continue" to keep going.';
}

/// A task that must stop spending (its size limit, today's allowance, or a bot's daily token budget): one wrap-up
/// note, then a hard stop two steps later if it still reaches for tools. Before, a bot over its budget got the same
/// note again on every step and never stopped (BUGHUNT 2026-10-23 #1).
enum WrapUp { none, note, stop }

class SpendStop {
  static WrapUp decide({required bool over, required bool wantsTools, required int wrapUpAt, required int step}) {
    if (!over || !wantsTools) return WrapUp.none;
    if (wrapUpAt < 0) return WrapUp.note;
    return step - wrapUpAt >= 2 ? WrapUp.stop : WrapUp.none;
  }
}

/// Blank replies: models sometimes answer nothing mid-task. Up to [max] blanks IN A ROW are nudged; any real reply
/// resets the count. Before, the count was for the whole task, so a long build died at its third blank of the day
/// with "The answer stopped in the middle of the task" (BUGHUNT 2026-10-23 #2).
class BlankGuard {
  static const max = 2;
  int inRow = 0;

  /// A blank came back: true when it should be nudged once more, false when the task must end.
  bool retry() {
    if (inRow >= max) return false;
    inRow++;
    return true;
  }

  void gotReply() => inRow = 0;
}

/// Simple measures of a request, used by tests and the loop's own bookkeeping.
class PayloadStats {
  /// Characters two requests share from the start (what a prefix cache can reuse).
  static int sharedPrefix(List<Map<String, dynamic>> a, List<Map<String, dynamic>> b) {
    final x = jsonEncode(a), y = jsonEncode(b);
    final n = x.length < y.length ? x.length : y.length;
    var i = 0;
    while (i < n && x.codeUnitAt(i) == y.codeUnitAt(i)) {
      i++;
    }
    return i;
  }

  static int chars(List<Map<String, dynamic>> p) => jsonEncode(p).length;
}

// ---------------------------------------------------------------------------------------------------------------
// Agent loop fixes (2026-10-24, branch fix/agent-loop). Each was seen in production chats.
// ---------------------------------------------------------------------------------------------------------------

/// The task's own checklist (the `todo` tool). Models resend the whole list with only the newest step in `done`;
/// that used to clear every earlier tick, so the list never finished and the model kept re-ticking steps back and
/// forth (16 todo calls in one landing-page task), each one also resetting the "carry on" nudge budget.
/// Now ticks are cumulative: a resent list keeps the ticks of every step whose text is unchanged.
class Checklist {
  static const maxSteps = 30;

  /// Applies one `todo` call to [todo] / [done] (0-based indexes). [steps] replaces the list when it is a non-empty
  /// list; [doneArg] holds 1-based step numbers now finished. Returns true when a step became done that was not
  /// done before (real progress), false for a call that changed nothing or only re-ticked.
  static bool apply(List<String> todo, Set<int> done, {Object? steps, Object? doneArg}) {
    final before = <String>{
      for (final i in done)
        if (i >= 0 && i < todo.length) _key(todo[i]),
    };
    if (steps is List && steps.isNotEmpty) {
      final fresh = [for (final s in steps) '$s'.trim()].where((s) => s.isNotEmpty).take(maxSteps).toList();
      if (fresh.isNotEmpty) {
        todo
          ..clear()
          ..addAll(fresh);
        done.clear();
        for (var i = 0; i < todo.length; i++) {
          if (before.contains(_key(todo[i]))) done.add(i);
        }
      }
    }
    if (doneArg is List) {
      for (final d in doneArg) {
        final i = (d is num ? d.toInt() : int.tryParse('$d'.trim()) ?? 0) - 1;
        if (i >= 0 && i < todo.length) done.add(i);
      }
    }
    final after = <String>{for (final i in done) _key(todo[i])};
    return after.difference(before).isNotEmpty;
  }

  static String _key(String s) => s.toLowerCase().replaceAll(RegExp(r'[\s\p{P}]+', unicode: true), ' ').trim();
}

/// A reply that only announces work ("Creating a simple to-do list note.") and calls no tool. The task used to end
/// there, so the user had to say "go ahead" before anything happened.
class Announce {
  static const _verbs = 'create|make|write|build|draft|generate|set up|add|save|search|look up|look for|check|open|start|prepare|'
      'compose|send|book|find|fetch|design|put together|do|get|run|fix|update';
  static const _ing = 'creating|making|writing|building|drafting|generating|setting up|adding|saving|searching|looking up|looking for|'
      'checking|opening|starting|preparing|composing|sending|booking|finding|fetching|designing|putting together|fixing|updating';
  static final _lead = RegExp(
      "^(on it[,.!:]|(let me|i(['’]| wi)ll|i(['’]| a)m going to)( now| first)? ($_verbs)\\b|"
      "(i(['’]| a)m |now |first,? )?($_ing)\\b)",
      caseSensitive: false);

  /// True for a short one-line status that promises an action, with no question, choices or result card in it.
  static bool only(String reply) {
    final t = reply.trim();
    if (t.isEmpty || t.length > 160 || t.contains('\n') || t.contains('?') || t.contains('```')) return false;
    if (!RegExp(r'([.…:!]|\.\.\.)$').hasMatch(t)) return false;
    return _lead.hasMatch(t);
  }
}

/// Final replies a later one replaces. The finish check (and the "checklist still open" nudge) runs after a final
/// reply was already shown, so the user got two or three finals in a row ("Your landing page is ready…" twice,
/// two seconds apart). The newer final now replaces the held one, keeping any file or page card only it had.
class FinalReply {
  static final _card = RegExp(r'```(file|page)\n[\s\S]*?\n```');

  /// [now] plus the ```file / ```page cards of [old] that [now] does not already show.
  static String carryCards(String old, String now) {
    final missing = <String>[
      for (final m in _card.allMatches(old))
        if (!now.contains(m.group(0)!)) m.group(0)!,
    ];
    if (missing.isEmpty) return now;
    final base = now.trimRight();
    return base.isEmpty ? missing.join('\n\n') : '$base\n\n${missing.join('\n\n')}';
  }
}
