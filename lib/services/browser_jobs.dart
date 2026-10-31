import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models.dart';
import 'browser/loop_guard.dart';
import 'browser/shots.dart';
import 'browser_agent.dart';
import 'llm_client.dart';
import 'tool_output_clean.dart';
import '../agent/core.dart';
import '../ui/i18n.dart';

/// One browser task run by the browser subagent (browser-use v2).
///
/// The chat agent hands a goal to a dedicated browser agent. Each step it sees the page (numbered elements + text)
/// and a fresh screenshot with the same numbers, says whether its last action worked, keeps a short memory and a
/// checklist, and acts (up to 6 actions per step). A loop guard catches repeats and stalls (nudge, then re-plan, then
/// a clean stop with a clear message); a step and time budget bounds every task; Stop ends it at once.
class BrowserJob {
  BrowserJob(this.id, this.goal, this.details, this.convId, this.checkInMinutes);
  final String id;
  final String goal;
  final String details;
  final String convId;
  int checkInMinutes;

  /// running | needs (waiting for an answer) | checkin (time box reached) | done | failed | stopped
  String status = 'running';
  final List<PlanStep> plan = [];
  final List<String> facts = [];
  final List<String> progress = [];
  final List<String> inbox = [];

  /// Pages visited (url — title), newest last, so the agent never wanders back unknowingly.
  final List<String> visited = [];

  /// The agent's own judgement of its last step ("Success: the cart shows 2 items").
  String lastEval = '';

  /// How many inbox messages the request in flight carries. They leave the inbox only once that request's answer
  /// is used, so a message is never lost when a newer one cancels the call that carried it.
  int heard = 0;
  final List<_Step> steps = [];
  String result = '';
  String question = '';

  /// The one quiet status line the card shows ("Opening amazon.com").
  String now = tr('Starting');
  final DateTime started = DateTime.now();
  DateTime segmentStart = DateTime.now();
  int segmentSteps = 0;
  bool cancelled = false;

  final LoopGuard guard = LoopGuard();
  StepBudget budget = StepBudget();

  /// Where it ended (for the compact result card).
  String finalUrl = '';
  String finalTitle = '';

  /// Set by the app around each model call: restart the thought with new input / abort it / was it restarted.
  void Function()? steerHook;
  void Function()? cancelHook;

  /// Cancels only the model call in flight (a time limit), not the job.
  void Function()? llmCancel;
  bool Function()? wasSteered;

  /// Completes each time the job stops running (done, needs an answer, check-in).
  Completer<void> stopped = Completer<void>();

  /// The app already told the user how this one ended (for jobs nobody was waiting on).
  bool reported = false;

  /// Old steps keep a short line instead of the whole page they saw, so a long task's memory stays bounded.
  void foldOld({int keep = 64, int max = 300}) {
    for (var i = steps.length - keep - 1; i >= 0; i--) {
      final s = steps[i];
      if (s.result.length > max + 1) s.result = '${s.result.substring(0, max)}…';
    }
  }

  bool get live => status == 'running';
  bool get finished => status == 'done' || status == 'failed' || status == 'stopped';

  String elapsed() {
    final m = DateTime.now().difference(started).inMinutes;
    return m < 1 ? 'under a minute' : '$m min';
  }

  String get host {
    final h = Uri.tryParse(finalUrl)?.host ?? '';
    return h.startsWith('www.') ? h.substring(4) : h;
  }

  /// What the chat agent gets back whenever the job pauses or ends.
  String report() {
    final sb = StringBuffer('Browser task $id — ');
    switch (status) {
      case 'done':
        sb.writeln('DONE after ${steps.length} steps (${elapsed()}).');
        sb.writeln('Result: $result');
      case 'failed':
        sb.writeln('COULD NOT FINISH after ${steps.length} steps (${elapsed()}).');
        sb.writeln('Why: $result');
      case 'stopped':
        sb.writeln('STOPPED.');
      case 'needs':
        sb.writeln('PAUSED, it needs an answer: $question');
        sb.writeln('Answer with browser_task_reply (ask the user with ask_user first if only they know).');
      case 'checkin':
        sb.writeln('CHECK-IN after ${elapsed()} (${steps.length} steps). It is paused. '
            'Tell the user in one line where it stands, then browser_task_reply with "continue" (or new directions), '
            'or browser_task_stop.');
      default:
        sb.writeln('RUNNING: $now (${steps.length} steps, ${elapsed()}).');
    }
    if (plan.isNotEmpty) {
      sb.writeln('Checklist:');
      for (var i = 0; i < plan.length; i++) {
        sb.writeln('  ${plan[i].done ? '[x]' : '[ ]'} ${i + 1}. ${plan[i].text}${plan[i].note.isEmpty ? '' : ' — ${plan[i].note}'}');
      }
    }
    if (facts.isNotEmpty) {
      sb.writeln('Found so far:');
      for (final f in facts.take(40)) {
        sb.writeln('  - $f');
      }
    }
    if (finalUrl.isNotEmpty) sb.writeln('Browser is on: $finalTitle — $finalUrl');
    return sb.toString().trimRight();
  }

  /// The compact card the chat keeps once the task ends: ```browser {json}```.
  String resultFence() {
    var summary = status == 'stopped' ? 'Stopped' : result.trim();
    if (summary.length > 280) summary = '${summary.substring(0, 278)}…';
    final j = {
      'status': status,
      'goal': goal.length > 120 ? '${goal.substring(0, 118)}…' : goal,
      'url': finalUrl,
      'title': finalTitle,
      'summary': summary,
      'steps': steps.length,
      'secs': DateTime.now().difference(started).inSeconds,
    };
    return '```browser\n${jsonEncode(j)}\n```';
  }
}

class PlanStep {
  PlanStep(this.text);
  final String text;
  bool done = false;
  String note = '';
}

class _Step {
  _Step(this.call, this.result);
  final ToolCall call;
  String result;
  String? thought;
  String? shotCall;
}

/// An approval or question waiting on the browser card (inline form) instead of a sheet.
class InlineAsk {
  InlineAsk({required this.convId, required this.title, required this.detail, required this.money});
  final String convId;
  final String title;
  final String detail;
  final bool money;
  final Completer<({bool ok, bool always})> done = Completer<({bool ok, bool always})>();
  void answer(bool ok, {bool always = false}) {
    if (!done.isCompleted) done.complete((ok: ok, always: always && !money));
  }
}

typedef BrowserLlm = Future<LlmResult> Function(BrowserJob job, List<Map<String, dynamic>> payload, List<Map<String, dynamic>> tools);
typedef BrowserTool = Future<String> Function(BrowserJob job, String name, Map<String, dynamic> args, String callId);

/// Runs browser tasks as subagents (up to [maxParallel] at once) and gives the chat agent tools to drive them.
class BrowserJobs extends ChangeNotifier {
  /// Tells the screens something changed (for the job's own agent hooks, which live outside this class).
  void changed() => notifyListeners();

  BrowserJobs._();
  static final BrowserJobs I = BrowserJobs._();

  static const maxParallel = 3;

  /// Hard stop for one run segment even inside the time box, so nothing loops forever unseen.
  static const segmentStepCap = 80;

  /// One model call may take this long before it is abandoned (twice in a row ends the task cleanly).
  static Duration modelLimit = const Duration(seconds: 150);

  final List<BrowserJob> jobs = [];
  int _next = 1;

  // Hooks from the app.
  BrowserLlm? llm;
  BrowserTool? runTool;

  /// A job ended (done, failed, stopped), whatever step it was on.
  void Function(BrowserJob job)? onEnded;

  /// Posts a message in the task's chat (the compact result card when a task ends).
  void Function(String convId, String text)? say;

  /// Whether the model can read screenshots.
  bool Function()? canSee;

  /// The user's own rules for how to work (About you / How to respond), so the subagent follows them too.
  String Function()? userRules;

  /// Approvals waiting inline on a chat's browser card.
  final Map<String, InlineAsk> inline = {};

  /// Chats whose browser card is on screen right now (they get inline forms instead of sheets).
  final Map<String, int> _cards = {};
  void cardShown(String convId, bool on) {
    final n = (_cards[convId] ?? 0) + (on ? 1 : -1);
    if (n <= 0) {
      _cards.remove(convId);
    } else {
      _cards[convId] = n;
    }
  }

  bool cardVisible(String convId) => (_cards[convId] ?? 0) > 0;

  /// Asks for an approval on the card. Ends with "no" after [limit] or when the chat's tasks stop.
  Future<({bool ok, bool always})> askInline(String convId, {required String title, required String detail, required bool money,
      Duration limit = const Duration(minutes: 10)}) async {
    inline[convId]?.answer(false);
    final a = InlineAsk(convId: convId, title: title, detail: detail, money: money);
    inline[convId] = a;
    notifyListeners();
    final r = await Bounded.run<({bool ok, bool always})>(a.done.future, limit, (ok: false, always: false));
    if (inline[convId] == a) inline.remove(convId);
    notifyListeners();
    return r;
  }

  Iterable<BrowserJob> get running => jobs.where((j) => j.live);

  /// The newest task of a chat that is running or waiting on the user (the one its card shows).
  BrowserJob? activeFor(String convId) {
    for (final j in jobs.reversed) {
      if (j.convId == convId && !j.finished) return j;
    }
    return null;
  }

  static const names = {'browser_task', 'browser_task_reply', 'browser_task_wait', 'browser_task_status', 'browser_task_stop'};

  static Map<String, dynamic> _fn(String name, String desc, Map<String, dynamic> props, List<String> required) => {
        'type': 'function',
        'function': {
          'name': name,
          'description': desc,
          'parameters': {'type': 'object', 'properties': props, 'required': required},
        },
      };

  /// Tools the chat agent uses to drive the browser agent.
  static final List<Map<String, dynamic>> definitions = [
    _fn(
        'browser_task',
        'Do anything on a website (sign in, fill forms, book, shop, post, apply, research across pages): the first choice for '
            'any website, before phone control. It hands the job to your browser agent, which uses the built-in browser '
            'like a person and shows the user one quiet live card. Give the full goal with every detail and rule the user '
            'gave (exact words, names, amounts, what to avoid, what "done" looks like). By default it waits and returns '
            'when the job is done, needs an answer, or reaches its check-in. wait:false runs up to 3 jobs in parallel; '
            'then use browser_task_wait.',
        {
          'goal': {'type': 'string', 'description': 'What to achieve, in one or two sentences, with the user\'s exact requirements.'},
          'details': {
            'type': 'string',
            'description': 'Everything else it needs: sites to use, data to enter, preferences, limits, what to bring back.'
          },
          'check_in_minutes': {
            'type': 'integer',
            'description': 'When it pauses to check in with you. Default 20. Use 10 for small jobs, up to 60 for long research.'
          },
          'wait': {'type': 'boolean', 'description': 'Default true. false = start it and return at once (parallel work).'},
        },
        ['goal']),
    _fn(
        'browser_task_reply',
        'Talk to a browser task: answer its question, give new directions, or say "continue" after a check-in. '
            'Waits for its next stop unless wait:false.',
        {
          'id': {'type': 'string'},
          'message': {'type': 'string'},
          'wait': {'type': 'boolean'},
        },
        ['id', 'message']),
    _fn('browser_task_wait', 'Wait until one of your browser tasks stops (done, needs an answer, or check-in) and get its report.', {
      'id': {'type': 'string', 'description': 'Optional: wait for this one; otherwise the first of the running ones.'},
    }, []),
    _fn('browser_task_status', 'See every browser task: what it is doing now, its checklist and what it found so far.', {}, []),
    _fn('browser_task_stop', 'Stop a browser task.', {
      'id': {'type': 'string'},
    }, ['id']),
  ];

  String label(String name, Map<String, dynamic> a) {
    switch (name) {
      case 'browser_task':
        final g = '${a['goal'] ?? ''}'.trim();
        return g.isEmpty ? 'Working in the browser' : (g.length > 48 ? '${g.substring(0, 46)}…' : g);
      case 'browser_task_reply':
        return 'Guiding the browser';
      case 'browser_task_wait':
        final r = running.firstOrNull;
        return r?.now ?? 'Waiting for the browser';
      case 'browser_task_stop':
        return 'Stopping the browser task';
      default:
        return 'Checking the browser';
    }
  }

  /// The chat agent's tool calls.
  Future<String> execute(String name, Map<String, dynamic> a, String convId, {bool Function()? parentCancelled}) async {
    switch (name) {
      case 'browser_task':
        final goal = '${a['goal'] ?? ''}'.trim();
        if (goal.isEmpty) return 'Error: give the goal.';
        if (running.length >= maxParallel) {
          return 'Error: $maxParallel browser tasks are already running (${running.map((j) => j.id).join(', ')}). '
              'Wait for one with browser_task_wait, or stop one.';
        }
        final mins = (a['check_in_minutes'] is num ? (a['check_in_minutes'] as num).toInt() : int.tryParse('${a['check_in_minutes']}') ?? 20)
            .clamp(5, 60)
            .toInt();
        final j = BrowserJob('b${_next++}', goal, '${a['details'] ?? ''}'.trim(), convId, mins);
        jobs.add(j);
        // Finished, reported tasks beyond the newest 20 are forgotten.
        while (jobs.length > 20) {
          final old = jobs.where((x) => x.finished && x.reported).firstOrNull;
          if (old == null) break;
          jobs.remove(old);
        }
        notifyListeners();
        unawaited(_run(j));
        if (a['wait'] == false) {
          return 'Started browser task ${j.id}. It works on its own; use browser_task_wait to get its report.';
        }
        return _waitFor(j, parentCancelled);
      case 'browser_task_reply':
        final j = _byId('${a['id'] ?? ''}', convId);
        if (j == null) return 'Error: no browser task ${a['id']}. ${_ids(convId)}';
        final msg = '${a['message'] ?? ''}'.trim();
        if (msg.isEmpty) return 'Error: say something.';
        if (j.finished) {
          return 'Task ${j.id} has already ended (${j.status}). Start a new browser_task that continues from: ${j.result}';
        }
        j.inbox.add(msg);
        if (!j.live) {
          j.status = 'running';
          j.question = '';
          j.segmentStart = DateTime.now();
          j.segmentSteps = 0;
          j.stopped = Completer<void>();
          j.reported = false;
          j.guard.reset();
          notifyListeners();
          unawaited(_run(j));
        } else {
          j.steerHook?.call();
        }
        if (a['wait'] == false) return 'Sent to ${j.id}.';
        return _waitFor(j, parentCancelled);
      case 'browser_task_wait':
        final id = '${a['id'] ?? ''}'.trim();
        if (id.isNotEmpty) {
          final j = _byId(id, convId);
          if (j == null) return 'Error: no browser task $id. ${_ids(convId)}';
          return _waitFor(j, parentCancelled);
        }
        // Only this chat's tasks: another chat's report never lands here.
        final live = _mine(convId).where((j) => j.live).toList();
        if (live.isEmpty) {
          final last = _mine(convId).lastOrNull;
          return last == null ? 'No browser tasks.' : last.report();
        }
        final deadline = DateTime.now().add(live.first.budget.maxTime + const Duration(minutes: 2));
        while (!live.any((j) => !j.live)) {
          if (parentCancelled?.call() == true || DateTime.now().isAfter(deadline)) {
            for (final j in live) {
              stop(j);
            }
            break;
          }
          await Future.any([...live.map((j) => j.stopped.future), Future<void>.delayed(const Duration(seconds: 1))]);
        }
        return [for (final j in live) if (!j.live) j.report()].join('\n\n');
      case 'browser_task_status':
        final mine = _mine(convId).toList();
        if (mine.isEmpty) return 'No browser tasks.';
        return mine.reversed.take(6).map((j) => j.report()).join('\n\n');
      case 'browser_task_stop':
        final j = _byId('${a['id'] ?? ''}', convId);
        if (j == null) return 'Error: no browser task ${a['id']}. ${_ids(convId)}';
        stop(j);
        return 'Stopped ${j.id}.';
    }
    return 'Error: unknown tool $name';
  }

  Iterable<BrowserJob> _mine(String convId) => jobs.where((j) => j.convId == convId);
  BrowserJob? _byId(String id, String convId) => _mine(convId).where((j) => j.id == id).firstOrNull;
  String _ids(String convId) {
    final mine = _mine(convId);
    return mine.isEmpty ? 'There are none.' : 'Tasks: ${mine.map((j) => '${j.id} (${j.status})').join(', ')}.';
  }

  /// Waits for the job's next stop. Never forever: the task's own time budget (plus a margin) bounds it.
  Future<String> _waitFor(BrowserJob j, bool Function()? parentCancelled) async {
    final deadline = DateTime.now().add(j.budget.maxTime + const Duration(minutes: 2));
    while (j.live) {
      if (parentCancelled?.call() == true) {
        stop(j);
        break;
      }
      if (DateTime.now().isAfter(deadline)) {
        _end(j, 'failed', 'It ran past its time limit without finishing, so it was stopped. ${_progressLine(j)}');
        break;
      }
      await Future.any([j.stopped.future, Future<void>.delayed(const Duration(seconds: 1))]);
    }
    return j.report();
  }

  void stop(BrowserJob j) {
    j.cancelled = true;
    j.cancelHook?.call();
    inline[j.convId]?.answer(false);
    // A paused task (waiting for an answer, or at a check-in) stops too, and lets go of its tab.
    if (!j.finished) _end(j, 'stopped', '');
  }

  /// The user wrote while their task's browser agent works: it hears it at its next step.
  void userSaid(String convId, String text) {
    for (final j in running.where((j) => j.convId == convId)) {
      j.inbox.add('(from the user) $text');
      j.steerHook?.call();
    }
  }

  void stopAllFor(String convId) {
    for (final j in jobs.where((j) => j.convId == convId && !j.finished).toList()) {
      stop(j);
    }
  }

  void _end(BrowserJob j, String status, String result) {
    if (j.finished) return;
    j.status = status;
    if (result.isNotEmpty) j.result = result;
    final b = BrowserAgent.I;
    final t = b.tabFor(j.id) ?? (b.active ? b.tab : null);
    if (t != null && t.url.isNotEmpty) {
      j.finalUrl = t.url;
      j.finalTitle = t.title;
    }
    if (status != 'needs' && status != 'checkin') BrowserAgent.I.releaseJob(j.id);
    if (!j.stopped.isCompleted) j.stopped.complete();
    if (j.finished) {
      j.now = status == 'done' ? tr('Done') : (status == 'stopped' ? tr('Stopped') : tr('Could not finish'));
      say?.call(j.convId, j.resultFence());
    }
    notifyListeners();
    if (j.finished) onEnded?.call(j);
  }

  static String _progressLine(BrowserJob j) {
    final done = j.plan.where((p) => p.done).map((p) => p.text).toList();
    final parts = <String>[
      if (done.isNotEmpty) 'Done so far: ${done.join('; ')}.',
      if (j.facts.isNotEmpty) 'Found: ${j.facts.take(8).join('; ')}.',
    ];
    return parts.join(' ');
  }

  // ------------------------------------------------------------------ the subagent loop

  static final List<Map<String, dynamic>> _ownTools = [
    _fn('plan', 'Write or rewrite your checklist: the steps from here to done, short and concrete. For anything longer than '
        '3 actions do it first, and again when the approach has to change.', {
      'steps': {
        'type': 'array',
        'items': {'type': 'string'}
      },
    }, ['steps']),
    _fn('check', 'Tick a checklist step once you have SEEN it done on the page (number from the checklist).', {
      'step': {'type': 'integer'},
      'note': {'type': 'string', 'description': 'What you verified, very short.'},
    }, ['step']),
    _fn('note', 'Save a fact you will need later (prices, names, links, codes, what you already tried). Old page views are '
        'folded away; notes never are.', {
      'fact': {'type': 'string'},
    }, ['fact']),
    _fn('ask', 'Pause and ask the chat agent something only it or the user can answer (a choice, missing info). '
        'For a sign-in use browser_login; for a one-time code use ask_user.', {
      'question': {'type': 'string'},
    }, ['question']),
    _fn('finish', 'End the task. success:true only when every part of the goal is verified on the page. result: what was done '
        'and everything the user asked to get back (facts, numbers, links), clear and complete.', {
      'success': {'type': 'boolean'},
      'result': {'type': 'string'},
    }, ['success', 'result']),
  ];

  static const Map<String, dynamic> _askUser = {
    'type': 'function',
    'function': {
      'name': 'ask_user',
      'description': 'Ask the user directly and wait, only for a one-time code, a captcha they must solve, or a pick only '
          'they can make right now. It appears on the browser card.',
      'parameters': {
        'type': 'object',
        'properties': {
          'question': {'type': 'string'},
          'options': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': 'The answers to tap, when there are a few (each a few words). Never "Other": the card adds a row for their own words.',
          },
        },
        'required': ['question'],
      },
    },
  };

  @visibleForTesting
  String systemFor(BrowserJob j) => _system(j);

  String _system(BrowserJob j) {
    final rules = userRules?.call() ?? '';
    return '''You are SubMac's browser agent: you use websites on a phone for the user, quickly and carefully, like an expert.
You drive SubMac's built-in browser (Chromium, mobile layout).
${rules.isEmpty ? '' : '\nThe user\'s own rules (they come first):\n$rules\n'}
WHAT YOU SEE EVERY STEP
- The page: title and URL, the numbered interactive elements ("[12] button "Add to cart" @64,71": number, kind, label, where on the screenshot in %; * marks elements that are new since your last step; "(below, scrolls in)" means the action scrolls it in for you), the text in view, notices (pop-ups, sign-in, payment page).
- "Effect:" — what your last action changed. "NOTHING changed" means it missed: never repeat it unchanged.
- A fresh screenshot with the same numbers drawn in coloured boxes. It is the ground truth: check it before you judge a step.

HOW YOU ACT
- browser_act runs 1-6 actions in one step, e.g. type, type, select, click to fill a form. Put a page-changing action last. Fill "evaluation" (did the last step work: success / failure / unsure), "memory" (progress worth keeping) and "next_goal".
- Single tools also exist: browser_open, browser_click, browser_type, browser_select, browser_scroll, browser_find, browser_read, browser_wait, browser_back, browser_tabs, browser_tap_at (only for things without a number: maps, canvases, embedded frames), browser_swipe, browser_drag, browser_download, browser_upload, browser_view, browser_net, browser_fetch, browser_js (last resort).
- The site's data is often a step-saver: "Data: N data calls" means the page's own APIs answered — browser_net lists them (an id reads the JSON body), browser_fetch re-calls one with this page's session (GET/HEAD). Prefer reading an API's exact data over scraping the screen; humans cannot see this layer, you can.
- Only use numbers from the latest view. Prefer a number over tap_at.
- Sign-in: on a sign-in page call browser_login (the user gets a secure form; you never see passwords). Avoid "Sign in with Google/Apple".
- Cookie banners are closed for you. Other pop-ups: close them first.
- Before anything that posts, sends, submits, applies, pays or deletes, set "about" to a short question; the app asks the user. On payment pages the app asks on its own.

HOW YOU WORK
1. For more than 3 actions, call plan first. Tick (check) a step only when the page shows it done.
2. Verify every action from the Effect line and the screenshot. Typing: the field shows the value. Submitting: the page changed. Filters: the results changed.
3. Keep what matters in memory/note: old views are folded away.
4. Go straight to the right URL when you can (search URLs, known paths); use browser_find instead of scrolling around.
5. Finish with finish(success, result). success:true only when every requirement is met and verified; otherwise success:false with what is done and what blocked you. Put ALL the facts, numbers and links the user wanted in result. Never invent a value you did not see.

WHEN STUCK (never the same failing action twice in a row)
- Missed tap: the element may be covered (close the overlay), off screen (scroll), or need its own label/icon; try a different element or the site's search.
- Content not there yet: browser_wait for text, scroll to load more, or browser_reload.
- Wrong place: browser_back, the site's menu or search, a direct URL, or another site.
- Captcha or one-time code: ask_user. Site refuses the in-app browser: try its mobile URL or another site.
- If a whole approach fails twice, change the approach (re-plan), not the click.

TASK
Goal: ${j.goal}
${j.details.isEmpty ? '' : 'Details: ${j.details}\n'}''';
  }

  /// The model sees: its rules, the goal, its notebook, one line per old step, the last steps in full, and the
  /// newest screenshot (always the latest one, even after bookkeeping calls like plan or note).
  @visibleForTesting
  List<Map<String, dynamic>> payloadFor(BrowserJob j, {String? alert}) => _payload(j, alert: alert);

  List<Map<String, dynamic>> _payload(BrowserJob j, {String? alert}) {
    final out = <Map<String, dynamic>>[
      {'role': 'system', 'content': _system(j)},
    ];
    final nb = StringBuffer();
    nb.writeln('NOTEBOOK (step ${j.steps.length}, ${j.elapsed()}; ${j.budget.left()}; check-in at ${j.checkInMinutes} min)');
    if (j.budget.nearlySpent()) {
      nb.writeln('Budget nearly spent: wrap up. Finish with what you have (success:false if parts are missing).');
    }
    if (j.plan.isEmpty) {
      nb.writeln('Checklist: none yet.');
    } else {
      nb.writeln('Checklist:');
      final cur = j.plan.indexWhere((p) => !p.done);
      for (var i = 0; i < j.plan.length; i++) {
        final mark = j.plan[i].done ? '[x]' : (i == cur ? '[>]' : '[ ]');
        nb.writeln('  $mark ${i + 1}. ${j.plan[i].text}${j.plan[i].note.isEmpty ? '' : ' — ${j.plan[i].note}'}');
      }
    }
    if (j.facts.isNotEmpty) {
      nb.writeln('Memory:');
      for (final f in j.facts) {
        nb.writeln('  - $f');
      }
    }
    if (j.visited.isNotEmpty) {
      nb.writeln('Pages visited: ${j.visited.length > 12 ? j.visited.sublist(j.visited.length - 12).join(' | ') : j.visited.join(' | ')}');
    }
    const keep = 3;
    final old = j.steps.length > keep ? j.steps.sublist(0, j.steps.length - keep) : const <_Step>[];
    if (old.isNotEmpty) {
      nb.writeln('Earlier steps (folded):');
      final start = old.length > 50 ? old.length - 50 : 0;
      if (start > 0) nb.writeln('  (… $start earlier steps)');
      for (var i = start; i < old.length; i++) {
        nb.writeln('  #${i + 1} ${_fold(old[i])}');
      }
    }
    out.add({'role': 'user', 'content': 'Start the task.\n\n$nb'});
    final recent = j.steps.length > keep ? j.steps.sublist(j.steps.length - keep) : j.steps;
    for (var k = 0; k < recent.length; k++) {
      final s = recent[k];
      out.add({
        'role': 'assistant',
        'content': s.thought,
        'tool_calls': [s.call.toJson()],
      });
      final whole = k == recent.length - 1 || !BrowserAgent.names.contains(s.call.name);
      out.add({'role': 'tool', 'tool_call_id': s.call.id, 'content': whole ? s.result : _shrink(s.result)});
    }
    final extra = <String>[];
    j.heard = j.inbox.length;
    if (j.inbox.isNotEmpty) {
      extra.add('NEW MESSAGE (act on it now; it overrides earlier instructions where they differ):\n${j.inbox.join('\n')}');
    }
    if (alert != null) extra.add(alert);
    // The newest screenshot of this task, wherever it is in the history (a plan or note call after an action used to
    // drop it, which left the agent blind for the next step).
    Uint8List? shot;
    var shotAge = 0;
    for (var k = j.steps.length - 1; k >= 0 && shot == null; k--) {
      final id = j.steps[k].shotCall;
      if (id != null && ShotGate.same(id)) break; // CB-40: the screen did not change: no picture again
      if (id != null) shot = BrowserAgent.I.shotsByCall[id];
      if (shot == null && BrowserAgent.names.contains(j.steps[k].call.name)) shotAge++;
    }
    if (shot != null && (canSee?.call() ?? false)) {
      final head = shotAge == 0
          ? '[Screenshot now, after your last action. The numbers in the boxes match the element list.]'
          : '[Latest screenshot available (from $shotAge action${shotAge == 1 ? '' : 's'} ago; the page may have changed since).]';
      out.add({
        'role': 'user',
        'content': [
          {'type': 'text', 'text': '$head${extra.isEmpty ? '' : '\n\n${extra.join('\n\n')}'}'},
          {
            'type': 'image_url',
            'image_url': {'url': 'data:image/jpeg;base64,${base64Encode(shot)}'},
          },
        ],
      });
    } else if (extra.isNotEmpty) {
      out.add({'role': 'user', 'content': extra.join('\n\n')});
    }
    return out;
  }

  static String _fold(_Step s) {
    var args = s.call.arguments.replaceAll(RegExp(r'\s+'), ' ');
    if (args.length > 110) args = '${args.substring(0, 108)}…';
    final lines = s.result.split('\n').where((l) => l.trim().isNotEmpty).toList();
    var head = lines.isEmpty ? '' : lines.first;
    final page = lines.where((l) => l.startsWith('Page:')).firstOrNull;
    if (page != null && page != head) head = '$head | $page';
    if (head.length > 170) head = '${head.substring(0, 168)}…';
    return '${s.call.name} $args → $head';
  }

  static String _shrink(String r) {
    final lines = r.split('\n');
    if (lines.length <= 5) return r;
    return '${lines.take(5).join('\n')}\n(older view trimmed)';
  }

  /// Did a browser step change the page? From its Effect line, or the page fingerprint when there is none.
  @visibleForTesting
  static bool changedBy(String out, String fpBefore, String fpAfter) {
    if (out.contains('Effect: NOTHING changed')) return false;
    if (out.contains('Effect:')) return true;
    return fpBefore != fpAfter;
  }

  static bool failedOut(String out) =>
      out.startsWith('Error') || out.startsWith('That did not work') || out.startsWith('Stopped');

  /// Calls the model with a time limit; Stop aborts it at once.
  Future<LlmResult?> _think(BrowserJob j, List<Map<String, dynamic>> payload, List<Map<String, dynamic>> tools) async {
    final c = Completer<LlmResult?>();
    Timer? t;
    void fin(LlmResult? v) {
      if (c.isCompleted) return;
      t?.cancel();
      c.complete(v);
    }

    llm!(j, payload, tools).then(fin, onError: (Object e) {
      if (!c.isCompleted) {
        t?.cancel();
        c.completeError(e);
      }
    });
    t = Timer(modelLimit, () {
      j.llmCancel?.call();
      fin(null);
    });
    j.stopped.future.then((_) => fin(null));
    return c.future;
  }

  /// Runs the browser sub-agent on the Genkit agent core (the same loop as the chat agent): each turn rebuilds the
  /// notebook + newest screenshot ([_payload]), a turn takes at most 3 actions, the loop guard and the step/time budget
  /// are guards, and `finish` / `ask` end the job.
  Future<void> _run(BrowserJob j) async {
    final tools = <Map<String, dynamic>>[...BrowserAgent.definitions, ..._ownTools, _askUser];
    final hooks = _BrowserHooks(this, j, tools);
    final core = AgentCore(
      hooks: hooks,
      transport: hooks.transport,
      tools: tools,
      modelName: 'submac-browser',
      maxSteps: 100000,
      before: [
        (s) {
          if (!j.live || j.cancelled) return 'ended';
          // Budget: a clean end with what was done, never an endless task.
          if (j.budget.spent()) {
            _end(j, 'failed', 'I ran out of my step/time budget before finishing. ${_progressLine(j)}');
            return 'budget';
          }
          // Time box: pause and let the chat agent check in with the user.
          if (DateTime.now().difference(j.segmentStart).inMinutes >= j.checkInMinutes || j.segmentSteps >= segmentStepCap) {
            j.now = tr('Checking in');
            _end(j, 'checkin', '');
            return 'checkin';
          }
          return null;
        },
      ],
      gates: [
        // Words without an action: nudge it back to work, twice, then the words are the result.
        (r) async {
          if (!j.live || j.cancelled || r.hasCalls) return null;
          if (hooks.emptyTries++ < 2) {
            final w = r.text.trim();
            return (
              note: w.isEmpty
                  ? 'You replied with nothing. Take the next action, or call finish.'
                  : 'You wrote "${w.length > 200 ? '${w.substring(0, 200)}…' : w}" but took no action. Act with a tool, or call finish.',
              hold: false,
            );
          }
          return null;
        },
      ],
    );
    j.cancelHook = () {
      core.stop();
      j.llmCancel?.call();
    };
    try {
      final res = await core.run();
      if (j.live && !j.cancelled) {
        if (res.end == RunEnd.done) {
          final t = res.reply?.text.trim() ?? '';
          _end(j, 'done', t.isEmpty ? 'Finished without a summary.' : t);
        } else if (res.end == RunEnd.failed) {
          final e = res.error;
          _end(j, 'failed', hooks.failText ?? 'The model stopped answering: ${e is LlmException ? e.message : e}');
        }
      }
    } catch (e) {
      if (j.live) _end(j, 'failed', 'Something went wrong in the browser task: $e');
    } finally {
      if (j.cancelled && j.live) _end(j, 'stopped', '');
    }
  }

  Future<String> _do(BrowserJob j, ToolCall tc, Map<String, dynamic> a) async {
    switch (tc.name) {
      case 'plan':
        final steps = (a['steps'] is List) ? (a['steps'] as List).map((e) => '$e'.trim()).where((e) => e.isNotEmpty).toList() : <String>[];
        if (steps.isEmpty) return 'Error: give the steps.';
        final kept = {for (final p in j.plan.where((p) => p.done)) p.text};
        j.plan
          ..clear()
          ..addAll(steps.map((s) => PlanStep(s)..done = kept.contains(s)));
        j.guard.reset();
        notifyListeners();
        return 'Checklist saved (${steps.length} steps). Start with step ${j.plan.indexWhere((p) => !p.done) + 1}.';
      case 'check':
        final n = (a['step'] is num ? (a['step'] as num).toInt() : int.tryParse('${a['step']}') ?? 0) - 1;
        if (n < 0 || n >= j.plan.length) return 'Error: no step ${n + 1}.';
        j.plan[n].done = true;
        j.plan[n].note = '${a['note'] ?? ''}'.trim();
        final next = j.plan.indexWhere((p) => !p.done);
        notifyListeners();
        return next < 0 ? 'All steps ticked. Verify the goal against the request, then finish.' : 'Ticked. Next: ${next + 1}. ${j.plan[next].text}';
      case 'note':
      case 'report':
        final f = '${a['fact'] ?? a['text'] ?? ''}'.trim();
        if (f.isEmpty) return 'Error: empty note.';
        _remember(j, f);
        return 'Noted.';
      case 'ask':
        j.question = '${a['question'] ?? ''}'.trim();
        _end(j, 'needs', '');
        return 'Asked.';
      case 'finish':
        final ok = a['success'] != false;
        final res = '${a['result'] ?? ''}'.trim();
        final open = j.plan.where((p) => !p.done).map((p) => p.text).toList();
        if (ok && open.isNotEmpty && !j.steps.any((s) => s.result.startsWith('Unticked steps'))) {
          // One sanity check before claiming success.
          return 'Unticked steps: ${open.join('; ')}. If they are really done (seen on the page), check them and call '
              'finish again; otherwise do them first, or finish with success:false.';
        }
        if (ok && res.isEmpty) return 'Error: put what was done and what the user wanted back in result.';
        _end(j, ok ? 'done' : 'failed', res.isEmpty ? 'Could not finish.' : res);
        return 'Finished.';
    }
    if (tc.name == 'browser_act') {
      final ev = '${a['evaluation'] ?? ''}'.trim();
      if (ev.isNotEmpty) j.lastEval = ev;
      final mem = '${a['memory'] ?? ''}'.trim();
      if (mem.isNotEmpty) _remember(j, mem);
    }
    if (BrowserAgent.names.contains(tc.name)) j.now = BrowserAgent.I.label(tc.name, a);
    notifyListeners();
    return runZoned(() => runTool!(j, tc.name, a, tc.id), zoneValues: {#smBrowserJob: j.id});
  }

  static void _remember(BrowserJob j, String f) {
    final v = f.length > 400 ? '${f.substring(0, 400)}…' : f;
    if (j.facts.isNotEmpty && j.facts.last == v) return;
    j.facts.add(v);
    if (j.facts.length > 60) j.facts.removeAt(0);
  }

  /// A short status for the working line under the chat (the card shows the full status).
  String? lineFor(String convId) {
    final live = running.where((j) => j.convId == convId).toList();
    if (live.isEmpty) return null;
    if (live.length == 1) return live.first.now;
    return '${live.length} browser tasks running';
  }

  /// For tests and debugging.
  @visibleForTesting
  Uint8List? lastShotFor(String callId) => BrowserAgent.I.shotsByCall[callId];

  @visibleForTesting
  void runForTest(BrowserJob j) => unawaited(_run(j));

  @visibleForTesting
  static dynamic stepForTest(ToolCall call, String result, {String? shot}) => _Step(call, result)..shotCall = shot;
}


/// The browser sub-agent's side of a Genkit run.
class _BrowserHooks extends CoreHooks {
  _BrowserHooks(this.jobs, this.j, this.tools);
  final BrowserJobs jobs;
  final BrowserJob j;
  final List<Map<String, dynamic>> tools;
  int emptyTries = 0;
  int slowModel = 0;
  String? failText;
  String? _alert;
  String _thought = '';

  @override
  bool get cancelled => j.cancelled || !j.live;

  @override
  String cleanOutput(String out) => ToolOutputClean.clean(out);

  @override
  Future<Turn> buildTurn(int step, String? notes) async {
    final alert = [if (_alert != null) _alert!, if (notes != null) notes].join('\n\n');
    _alert = null;
    final payload = jobs._payload(j, alert: alert.isEmpty ? null : alert);
    if (j.steps.isEmpty) j.now = tr('Planning');
    jobs.changed();
    return Turn(step: step, payload: payload, tools: tools);
  }

  /// One model call with the job's time limit; Stop ends it at once. At most 3 actions per turn.
  Future<LlmResult> transport(Turn t) async {
    final r = await jobs._think(j, t.payload, tools);
    if (!j.live || j.cancelled) return LlmResult('', const [], 'cancelled');
    if (r == null) throw const _Slow();
    if (r.finishReason == 'cancelled') {
      if (j.inbox.isNotEmpty) throw LlmException('steered');
      return r;
    }
    slowModel = 0;
    // This answer was made with those messages: they are heard now.
    j.inbox.removeRange(0, j.heard.clamp(0, j.inbox.length).toInt());
    j.heard = 0;
    if (r.toolCalls.length <= 3) return r;
    return LlmResult(r.content, r.toolCalls.take(3).toList(), r.finishReason, r.tokens, r.tokensIn, r.tokensOut, r.tokensCached);
  }

  @override
  Future<ErrorAction> onError(Object e) async {
    if (!j.live || j.cancelled) return ErrorAction.stop;
    if (e is _Slow) {
      if (++slowModel >= 2) {
        failText = 'The model did not answer in time twice, so I stopped. ${BrowserJobs._progressLine(j)}';
        return ErrorAction.stop;
      }
      return ErrorAction.retry;
    }
    // A new message arrived mid-thought: think again with it.
    if (j.wasSteered?.call() == true || (e is LlmException && e.message == 'steered')) return ErrorAction.retry;
    failText = 'The model stopped answering: ${e is LlmException ? e.message : e}';
    return ErrorAction.stop;
  }

  @override
  Future<void> commit(Reply r) async {
    _thought = r.text.trim();
    if (r.hasCalls) emptyTries = 0;
  }

  @override
  Future<String> runTool(ToolCall tc, Map<String, dynamic> args, {Object? approved}) async {
    if (!j.live || j.cancelled) return 'Stopped: the task ended.';
    // A new message or a warning arrived after an earlier action of this turn: look again before acting.
    if (j.inbox.isNotEmpty || _alert != null) return 'Skipped: a new message or a warning arrived. Look at the page again before acting.';
    final isBrowser = BrowserAgent.names.contains(tc.name);
    final fpBefore = isBrowser ? BrowserAgent.I.snapFor(j.id).fingerprint : '';
    final out = await jobs._do(j, tc, args);
    final step = _Step(tc, out)..thought = _thought.isEmpty ? null : _thought;
    if (isBrowser && j.live) {
      step.shotCall = tc.id;
      j.budget.steps++;
      j.segmentSteps++;
      final snap = BrowserAgent.I.snapFor(j.id);
      if (snap.url.isNotEmpty) {
        final v = '${snap.host}${Uri.tryParse(snap.url)?.path ?? ''} — ${snap.title.length > 40 ? snap.title.substring(0, 40) : snap.title}';
        if (j.visited.isEmpty || j.visited.last != v) j.visited.add(v);
        if (j.visited.length > 40) j.visited.removeAt(0);
      }
      final v = j.guard.record(StepTrace(
        action: LoopGuard.sig(tc.name, tc.arguments),
        page: snap.fingerprint,
        url: snap.url,
        changed: BrowserJobs.changedBy(out, fpBefore, snap.fingerprint),
        failed: BrowserJobs.failedOut(out),
      ));
      if (v == GuardVerdict.stop) {
        j.steps.add(step);
        jobs._end(j, 'failed', '${j.guard.message(v)} ${BrowserJobs._progressLine(j)}'.trim());
        return out;
      }
      if (v == GuardVerdict.replan) {
        for (final p in j.plan) {
          if (!p.done) p.note = 'blocked';
        }
      }
      if (v != GuardVerdict.ok) _alert = j.guard.message(v);
    }
    j.steps.add(step);
    j.foldOld();
    return out;
  }
}

class _Slow implements Exception {
  const _Slow();
}
