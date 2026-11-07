import 'dart:convert';

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../agent/core.dart';
import '../models.dart';
import 'bot_manner.dart';
import 'llm_client.dart';
import 'bots.dart';
import 'no_reply.dart';
import 'offices.dart';
import 'output_limits.dart';
import 'quick_lane.dart';
import 'system_bridge.dart';
import 'team_floor.dart';
import 'team_key.dart';
import 'team_status.dart';
import 'tool_output_clean.dart';

/// A team is a group chat, the Grok way (docs.x.ai/grok-bot/chat-and-collaboration; owner 2026-10-24, team intelligence):
///
///  1. Nothing starts by itself. Creating or opening a team runs nothing, and no bot speaks on a timer.
///  2. Whoever is addressed answers, and only they: an @mention ("@Nova"), a reply to a bot's message, or a message that
///     starts with a member's name ("Nova, …"). Several mentions = each of them; @team / @everyone = all. The lead is a
///     member like the others here: it answers only when it is addressed.
///  3. Nobody addressed: the team decides who, if anyone, should speak (one small model decision with the roster and the
///     recent chat, [floorSystem]): the member whose role fits or who was already talking with the owner answers; "none"
///     is a normal outcome. Only when the owner clearly asks the team to work on something together does the lead take it
///     and coordinate (step 4).
///  4. A team job: the lead restates the goal and posts who does what, then the team starts at once (it asks first only
///     when it truly needs something). The lead hands each part to a member by name; each member reports in their own
///     voice and can build on a teammate's part; the lead closes with one combined answer whose parts open on tap.
///  5. While a job runs, what the owner writes reaches the lead and the members still to report, with one short system
///     line saying so (CB-37); "stop" stops it, and also every member reply the team started (CB-34).
///  6. "@silent" in the owner's message: it is posted and nobody answers.
class TeamRun extends ChangeNotifier {
  TeamRun._();
  static final TeamRun I = TeamRun._();

  /// The wire under every team agent run (set by AppState): one model call for bot [b] (tools allowed).
  /// Every model call of a team (who speaks, the plan, each member's part, the combined answer) runs on the Genkit agent
  /// core (lib/agent/core.dart); this is only its transport.
  Future<LlmResult> Function(Bot b, Turn t, {int maxTokens})? llm;

  /// A plain one-answer wire, used when [llm] is not set (tests, and older callers). No tools.
  Future<String> Function(Bot b, String system, String user, {int maxTokens})? ask;

  /// A member's own tools (OpenAI definitions) for its part of a job; empty = it answers from what it knows.
  List<Map<String, dynamic>> Function(Bot b)? toolsFor;

  /// Runs one of a member's tools (its powers, approvals and trust apply). [approved]: the owner already said yes.
  Future<String> Function(Bot b, ToolCall c, Map<String, dynamic> args, {Object? approved})? runTool;

  /// Whether a member's call needs the owner's OK first (non-null = the Genkit interrupt data), and the owner's answer.
  Future<Map<String, dynamic>?> Function(Bot b, ToolCall c, Map<String, dynamic> args)? approvalFor;
  Future<ToolApproval> Function(Bot b, ToolCall c, Map<String, dynamic> args, Map<String, dynamic> data)? answer;

  /// The most model calls one member may make for its part.
  static const memberSteps = 10;

  /// Teams on opencode (owner, 2026-11-03): one opencode turn for bot [b] in a fresh session of its own, with its own
  /// brief and tools. [key] routes its tool calls (`team:<team>:<bot>`); [assign] is the lead's hand-off to a member.
  /// Set by the app; when null (tests, older callers) teams use [llm] / [ask] as before.
  Future<String> Function(Bot b, String key, String system, String task,
      {bool Function()? stopped, Future<String> Function(String member, String ask)? assign})? ocTurn;

  static const assignName = 'team_assign';
  static const taskName = 'team_task';

  /// The lead's hand-off on opencode: one tool for every member, by name.
  static const assignTool = {
    'type': 'function',
    'function': {
      'name': assignName,
      'description': 'Team lead only, during a team job: hand a member their part and wait for their result. Parts that do not '
          'depend on each other can be handed off at once and run side by side.',
      'parameters': {
        'type': 'object',
        'properties': {
          'member': {'type': 'string', 'description': 'The member\'s name'},
          'ask': {'type': 'string', 'description': 'Their part: clear and self-contained, with what teammates found when it builds on it'},
        },
        'required': ['member', 'ask'],
      },
    },
  };

  /// A lead gives its team a job (from a routine, a follow-up, or when the owner asks in the lead's own chat).
  static const taskTool = {
    'type': 'function',
    'function': {
      'name': taskName,
      'description': 'For a bot that leads a team: give the team a job. The team plans it, does it and posts the result in its '
          'team chat. Use it from a routine for regular team work ("every Monday: the weekly report").',
      'parameters': {
        'type': 'object',
        'properties': {
          'team': {'type': 'string', 'description': 'The team\'s name (may be left out when you lead one team)'},
          'task': {'type': 'string'},
        },
        'required': ['task'],
      },
    },
  };

  /// The team's shared folder in SubMac's workspace.
  static String folderOf(Office o) => 'teams/${o.id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}';

  static String _folderNote(Office o, {bool lead = false}) => '\n\n# Team folder\nThe team shares the folder ${folderOf(o)}/ '
      '(relative to your working directory): GOAL.md (the job), BOARD.md (who does what, and status) and the files the team makes. '
      '${lead ? 'Write GOAL.md and BOARD.md when the work starts and keep BOARD.md current as parts come back. ' : 'Read GOAL.md and BOARD.md first. '}'
      'Put real work products (drafts, tables, documents) there and mention their paths in your result.';

  /// A job given by a lead's routine or by team_task: the same as the owner giving the team a task, minus the chat
  /// message. Busy teams say so instead of starting a second job.
  String startJob(Office o, String task) {
    final lead = Bots.I.byId(o.chiefId);
    if (lead == null) return 'Error: the team has no lead.';
    if (busy(o) || awaitingGo(o)) return 'The team "${o.name}" is busy with another job. Try again later.';
    final members = [for (final id in o.members) if (id != o.chiefId) Bots.I.byId(id)].whereType<Bot>().take(maxParts).toList();
    if (members.isEmpty) return 'Error: the team has no members besides the lead.';
    if (lead.overBudget) return 'Not started: ${lead.name}\'s token budget for today is used up. It runs again tomorrow.';
    Offices.I.post(o, lead.id, task, assigns: false);
    work = _propose(o, lead, members, task, lang: BotManner.langOf(task));
    return 'Started: the team "${o.name}" is on it and will post the result in its team chat.';
  }

  bool get _wired => llm != null || ask != null;

  Transport _wire(Bot b, int maxTokens) => (t) async {
        final l = llm;
        if (l != null) return l(b, t, maxTokens: maxTokens);
        final sys = t.payload.where((m) => m['role'] == 'system').map((m) => '${m['content']}').join('\n\n');
        final user = t.payload.where((m) => m['role'] != 'system').map((m) => m['content'] is String ? m['content'] as String : jsonEncode(m['content'])).join('\n\n');
        final text = await ask!(b, sys, user, maxTokens: maxTokens);
        return LlmResult(text, const [], 'stop', (sys.length + user.length + text.length) ~/ 4, (sys.length + user.length) ~/ 4, text.length ~/ 4);
      };

  /// One model answer for [b] on the agent core (no tools, one step).
  Future<String> _once(Bot b, String system, String user, {int maxTokens = OutputLimits.answer, String? office}) async {
    // On opencode, a one-answer call (who speaks, the plan, the combined answer) is one plain model call: no agent core.
    final a = ask;
    if (ocTurn != null && a != null) return a(b, system, user, maxTokens: maxTokens);
    final r = await _agent(b, system, user, tools: const [], maxTokens: maxTokens, maxSteps: 1, office: office,
        stopped: office == null ? null : () => _stopped.contains(office));
    return r.text;
  }

  /// A team agent run for bot [b] on the Genkit core: its [tools] (and [extra] tools such as hand-offs, run by
  /// [onExtra]) until it answers. Approvals of its own tools are Genkit interrupts answered by the owner.
  Future<({String text, int steps})> _agent(Bot b, String system, String user,
      {List<Map<String, dynamic>> tools = const [],
      List<Map<String, dynamic>> extra = const [],
      Future<String> Function(ToolCall c, Map<String, dynamic> args)? onExtra,
      int maxTokens = OutputLimits.answer,
      int maxSteps = memberSteps,
      bool Function()? stopped,
      String? office,
      bool summarizeOnHalt = false}) async {
    final hooks = _TeamHooks(this, b, system, user, [...tools, ...extra], {for (final e in extra) Wire.toolName(e)}, onExtra, stopped ?? () => false);
    final core = AgentCore(hooks: hooks, transport: _wire(b, maxTokens), tools: [...tools, ...extra], maxSteps: maxSteps, modelName: 'submac-team');
    // Registered while it runs, so the owner's "stop" cancels the model call or tool in flight (not only the next step).
    if (office != null) {
      (_cores[office] ??= {}).add(core);
      ((_coreBots[office] ??= {})[b.id] ??= 0);
      _coreBots[office]![b.id] = _coreBots[office]![b.id]! + 1;
    }
    final RunResult res;
    try {
      res = await core.run();
    } finally {
      if (office != null) {
        _cores[office]?.remove(core);
        if (_cores[office]?.isEmpty ?? false) _cores.remove(office);
        final n = (_coreBots[office]?[b.id] ?? 1) - 1;
        if (n <= 0) {
          _coreBots[office]?.remove(b.id);
          if (_coreBots[office]?.isEmpty ?? false) _coreBots.remove(office);
        } else {
          _coreBots[office]![b.id] = n;
        }
      }
    }
    if (res.end == RunEnd.failed && hooks.lastText.isEmpty) throw res.error ?? 'failed';
    // CB-65: a member that ran out of steps keeps its work: one last call with no tools sums up what it found.
    if (res.end == RunEnd.halted && summarizeOnHalt && !(stopped?.call() ?? false)) {
      final r = await _wire(b, maxTokens)(hooks.summaryTurn(core.state.step));
      final t = r.content.trim();
      if (t.isNotEmpty) return (text: t, steps: core.state.step + 1);
    }
    return (text: (res.reply?.text ?? hooks.lastText).trim(), steps: core.state.step);
  }

  /// The bot's own prompt (who it is). Tests swap it for a short one.
  @visibleForTesting
  String Function(Bot b) promptOf = (b) => Bots.I.chatPromptOf(b);

  /// Teams running right now (office ids).
  final Set<String> running = {};

  /// CB-34: a team is busy while its own run works OR any member reply it started (an office job queued or running
  /// through [Offices.askBot]) is still going, so "stop" always reaches it instead of waking someone new.
  bool busy(Office o) => running.contains(o.id) || Offices.I.jobsFor(o.id);

  /// The bots a running team job still counts on (the lead, and members whose part is not back yet), by office id. A
  /// message the owner addresses to anyone else while the job runs is answered by them directly (it used to go into
  /// the job's inbox, which nobody read once their part was done).
  final Map<String, Set<String>> _jobBots = {};

  /// Plans waiting on the owner's answer to the lead's questions (or "Go"), by office id.
  final Map<String, TeamPlan> pending = {};
  bool awaitingGo(Office o) => pending.containsKey(o.id);

  /// What the owner said while the team worked, read by the members still to report and by the lead's answer.
  final Map<String, List<String>> _inbox = {};
  final Set<String> _stopped = {};

  /// The agent cores working for each team right now (lead and members), by office id.
  final Map<String, Set<AgentCore>> _cores = {};

  /// The bots with a core working for each team right now (bot id -> cores), so a stop can drop their asks.
  final Map<String, Map<String, int>> _coreBots = {};

  /// Stops team [officeId]'s work now: marks it stopped and cancels every model call and tool in flight. An ask a
  /// member is waiting on is dropped too, so its stopped run does not wait hours for an answer that does nothing.
  void stopWork(String officeId) {
    if (running.contains(officeId) || (_cores[officeId]?.isNotEmpty ?? false)) _stopped.add(officeId);
    for (final c in [...?_cores[officeId]]) {
      c.stop();
    }
    // On opencode the members' turns are not in [_coreBots]. Their approval cards belong to the team (team work runs
    // under its own key, never the member's private chat), so the team's waiting cards go.
    if (ocTurn != null) unawaited(Offices.I.expireForOffice(officeId));
    for (final id in {...?_coreBots[officeId]?.keys}) {
      final conv = Bots.I.byId(id)?.convId ?? '';
      if (conv.isNotEmpty) unawaited(Offices.I.expireFor(conv));
    }
  }

  /// CB-34: everything team [o] has going stops: its own run, every member reply job queued or running for it, and
  /// a plan waiting on the owner.
  void halt(Office o) {
    stopWork(o.id);
    Offices.I.stopJobs(o.id);
  }

  /// CB-60: team [officeId] is gone: its waiting plan, what the owner said and its journal entry go too.
  void forget(String officeId) {
    pending.remove(officeId);
    _inbox.remove(officeId);
    _unnote(officeId);
    notifyListeners();
  }

  /// CB-62: holds the phone awake while a team works (set by AppState, which knows about the other work that holds it;
  /// unset: the bridge directly).
  Future<void> Function(bool on, {String text})? keepAlive;
  int _awake = 0;
  Future<void> _hold(Office o) async {
    _awake++;
    try {
      await (keepAlive ?? SystemBridge.I.keepAlive)(true, text: '${o.name} · Team work');
    } catch (_) {}
  }

  Future<void> _release() async {
    _awake = (_awake - 1).clamp(0, 1 << 20).toInt();
    if (_awake > 0) return;
    try {
      await (keepAlive ?? (bool on, {String text = ''}) => SystemBridge.I.keepAlive(on))(false, text: '');
    } catch (_) {}
  }

  /// CB-61: a notification for a team post the owner should see while away (the app is in the background or another
  /// screen is open). The notifier itself (AppState) skips the team on screen and respects the bot's quiet hours.
  void _tell(Office o, Bot b, String text) {
    final n = Offices.I.notify;
    if (n == null || text.trim().isEmpty) return;
    final line = text.trim().split('\n').firstWhere((l) => l.trim().isNotEmpty, orElse: () => text.trim());
    unawaited(n(o, b, line).catchError((_) {}));
  }

  // ---------------------------------------------------------------- CB-64: a journal of running team jobs

  static const _journalKey = 'team_runs_v1';
  final Map<String, Map<String, dynamic>> _journal = {};

  void _note(Office o, TeamPlan plan, {bool planned = true}) {
    _journal[o.id] = {
      'job': plan.job,
      'lang': plan.lang,
      'planned': planned,
      'parts': [for (final p in plan.parts) {'bot': p.bot.id, 'ask': p.ask}],
      'at': DateTime.now().toIso8601String(),
    };
    unawaited(_saveJournal());
  }

  void _unnote(String officeId) {
    if (_journal.remove(officeId) != null) unawaited(_saveJournal());
  }

  Future<void> _saveJournal() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_journalKey, jsonEncode(_journal));
    } catch (_) {}
  }

  /// On start (after [Offices.init]): a team job that was running when SubMac closed is not resumed by itself
  /// (background runs never auto-resume); the team says so once, and "go" starts it again.
  Future<void> restore() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_journalKey);
      _journal.clear();
      if (raw == null || raw.isEmpty) return;
      final m = jsonDecode(raw);
      if (m is! Map) return;
      for (final e in m.entries) {
        final o = Offices.I.byId('${e.key}');
        final j = e.value;
        if (o == null || j is! Map || running.contains(o.id)) continue;
        final parts = <({Bot bot, String ask})>[
          for (final x in (j['parts'] as List? ?? const []))
            if (x is Map && Bots.I.byId('${x['bot']}') != null && o.members.contains('${x['bot']}'))
              (bot: Bots.I.byId('${x['bot']}')!, ask: '${x['ask'] ?? ''}'),
        ];
        final lang = '${j['lang'] ?? 'en'}';
        pending[o.id] = TeamPlan(job: '${j['job'] ?? ''}', parts: parts, lang: lang, replan: j['planned'] != true || parts.isEmpty);
        Offices.I.post(o, 'system', BotManner.interrupted(lang: lang), kind: 'system');
      }
      await p.remove(_journalKey);
      Offices.I.saveSoon();
      notifyListeners();
    } catch (e) {
      debugPrint('team journal: $e');
    }
  }

  /// Cores running for [officeId] (tests).
  @visibleForTesting
  int coresFor(String officeId) => _cores[officeId]?.length ?? 0;

  /// The newest piece of work started by [send] (tests wait on it).
  @visibleForTesting
  Future<void>? work;

  /// At most this many members work on one job.
  static const maxParts = 4;

  /// "Go" and its friends (English and Somali): the owner approves the plan.
  static final _go = RegExp(
      r'^(go|go ahead|yes|yes please|yep|yeah|ok(ay)?|ok go|start|start it|approve|approved|proceed|do it|sounds good|looks good|'
      r'haa|haye|bilow|bilaw|bilaaba|ku bilow|waa hagaag|hagaag|sii wad)[\s,.!]*(please|pls|thanks|walaal)?[\s,.!]*$',
      caseSensitive: false);

  /// "Stop" and its friends: the owner stops the work or drops the plan.
  static final _stop = RegExp(r'^(stop|stop it|stop now|cancel|cancel it|never mind|nevermind|not now|hold on|jooji|iska daa|ha bilaabin)[\s,.!]*$',
      caseSensitive: false);

  static bool isGo(String t) => _go.hasMatch(t.trim());

  /// "hi team", "thanks everyone": a greeting to the team, not a task (the word "team" alone never makes it work).
  static bool isSmallTalk(String t) =>
      QuickLane.laneFor(t.replaceAll(RegExp(r'\b(team|everyone|everybody|all|guys|kooxda|koox)\b', caseSensitive: false), ' ')
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim()) ==
      QuickLane.quick;
  static bool isStop(String t) => _stop.hasMatch(t.trim());

  /// The owner wrote [text] in team [o], optionally as a reply to post [replyTo]. Always true (a message while the team
  /// works reaches the lead).
  ///
  /// Team awareness (owner 2026-11-05): the owner can hand the team to the lead ("lead, take over", "I'm away") and
  /// take it back ("I'm back"); see [TeamLeadMode]. Who answers is decided by cheap rules first ([TeamFloor.rules]),
  /// then by one small model call; several bots asked about one message answer one after another (a thread).
  bool send(Office o, String text, {String replyTo = ''}) {
    var t = text.trim();
    if (t.isEmpty) return true;
    final lead = Bots.I.byId(o.chiefId);
    // "@silent": the owner only wants it on record. Nobody answers.
    if (NoReply.ownerWantsQuiet(t)) {
      Offices.I.ownerPost(o, t, replyTo: replyTo);
      return true;
    }
    OfficePost? posted;
    // Lead mode: the owner hands over or comes back. A task that comes with it is routed as usual.
    final cmd = isStop(t) ? null : TeamLeadMode.commandOf(t);
    if (cmd != null && lead != null) {
      posted = _owner(o, t, replyTo);
      final want = cmd == 'delegate';
      if (o.delegated != want) {
        o.delegated = want;
        final lang = BotManner.langOf(t);
        Offices.I.post(o, 'system', want ? BotManner.leadTakesOver(lead.name, lang: lang) : BotManner.ownerLeads(lead.name, lang: lang), kind: 'system');
      }
      Offices.I.saveSoon();
      notifyListeners();
      final rest = TeamLeadMode.rest(t);
      if (rest.split(' ').where((w) => w.isNotEmpty).length < 3) return true;
      t = rest;
    }
    return _route(o, t, replyTo: replyTo, posted: posted);
  }

  bool _route(Office o, String t, {String replyTo = '', OfficePost? posted}) {
    final lead = Bots.I.byId(o.chiefId);
    final members = [for (final id in o.members) if (id != o.chiefId) Bots.I.byId(id)].whereType<Bot>().take(maxParts).toList();
    final lang = BotManner.langOf(t);
    OfficePost say() => posted ??= _owner(o, t, replyTo);
    final to = addressed(o, t, replyTo: replyTo);
    // "Stop" stops everything the team has going: its run and every member reply it started (CB-34). It never goes to
    // the "who speaks" decision, which used to wake a member instead.
    if (isStop(t) && pending[o.id] == null) {
      final was = busy(o);
      final lang = RegExp(r'^(jooji|iska daa|ha bilaabin)', caseSensitive: false).hasMatch(t) ? 'so' : BotManner.langOf(t);
      say();
      halt(o);
      Offices.I.post(o, 'system', BotManner.stopped(lang: lang), kind: 'system');
      if (!was) debugPrint('team stop: nothing was running in ${o.id}');
      notifyListeners();
      return true;
    }
    // Working: the message reaches the work (the lead and the members still to report), and the owner sees that it
    // did (CB-37: it used to vanish into the inbox without a word).
    if (running.contains(o.id)) {
      final p = say();
      final inJob = _jobBots[o.id] ?? {for (final id in o.members) id};
      final direct = [for (final b in to) if (!inJob.contains(b.id)) b];
      Offices.I.addOwnerWatches(o, t, addressed: to);
      if (direct.isNotEmpty) _ask(o, direct, t, replyTo: replyTo, thread: direct.length > 1 ? p.id : '');
      if (direct.length < to.length || to.isEmpty) {
        (_inbox[o.id] ??= []).add(t);
        Offices.I.post(o, 'system', BotManner.noted(lang: lang), kind: 'system');
      }
      notifyListeners();
      return true;
    }
    final plan = pending[o.id];
    if (plan != null && lead != null && (to.isEmpty || to.contains(lead))) {
      say();
      if (isGo(t)) {
        pending.remove(o.id);
        // A job interrupted before the lead had a plan (CB-64) starts again from the plan.
        work = plan.replan ? _propose(o, lead, members, plan.job, lang: plan.lang) : _run(o, lead, plan);
      } else if (isStop(t)) {
        pending.remove(o.id);
        _inbox.remove(o.id);
        Offices.I.stopJobs(o.id);
        Offices.I.post(o, lead.id, BotManner.planCancelled(lang: plan.lang), assigns: false);
        notifyListeners();
      } else {
        // An answer to the lead's question, or a change: the lead updates the plan.
        work = _propose(o, lead, members, '${plan.job}\n\nThe owner added: $t', lang: plan.lang == 'en' ? lang : plan.lang);
      }
      return true;
    }
    // "Amal, analyze Nova's research once it posts": saved as a watch, so Amal takes its turn the moment Nova posts,
    // without the owner writing again (owner 2026-11-06). A message that is only that needs no answer now.
    final watches = Offices.I.addOwnerWatches(o, t, addressed: to);
    if (watches.isNotEmpty) {
      say();
      if (to.isEmpty) return true;
    }
    // The owner writing is the owner being here: the lead leads an owner's message only when handed the team
    // ("lead, take over", "I'm away") or when the owner gives the job to the lead by name (decided below).
    final leading = o.delegated;
    // Addressed: only they answer.
    if (to.isNotEmpty) {
      final everyone = Offices.mentionsEveryone(t);
      final p = say();
      // "@team": every member, one after another, each for their own role (or quiet when covered). While the lead leads,
      // a job for the whole team goes to the lead to plan instead.
      if (everyone) {
        if (leading && lead != null && members.isNotEmpty && _wired && looksLikeTeamTask(t)) {
          work = _propose(o, lead, members, t, lang: lang);
          return true;
        }
        _ask(o, to, t, replyTo: replyTo, thread: p.id);
        return true;
      }
      final others = [for (final b in to) if (b.id != lead?.id) b];
      // The lead, when addressed, decides itself whether the owner hands it a job for the team (that is the owner
      // telling it to lead) or is just talking to it as a colleague.
      if (lead != null && to.contains(lead) && members.isNotEmpty && _wired) {
        final thread = others.isEmpty ? '' : p.id;
        _ask(o, others, t, replyTo: replyTo, thread: thread);
        work = _decide(o, lead, members, t, replyTo: replyTo, leadAddressed: true, lang: lang, thread: thread);
      } else {
        _ask(o, to, t, replyTo: replyTo, thread: to.length > 1 ? p.id : '');
      }
      return true;
    }
    // Nobody addressed.
    if (!_wired || (lead == null && members.isEmpty)) {
      if (posted == null) {
        Offices.I.ownerPost(o, t, replyTo: replyTo);
      }
      return true;
    }
    final p = say();
    // CB-36: two or more listed deliverables is a team job. The lead plans it only while it leads (the owner away or
    // handed over); while the owner is here the team decides which members take part.
    if (leading && lead != null && members.isNotEmpty && looksLikeTeamTask(t)) {
      work = _propose(o, lead, members, t, lang: lang);
      return true;
    }
    if (!looksLikeTeamTask(t)) {
      // Cheap rules first: a role named, or the owner answering a bot's question a moment ago.
      final pick = TeamFloor.rules(o, t);
      if (!pick.needModel && pick.speakers.length == 1) {
        _ask(o, pick.speakers, t, replyTo: replyTo);
        return true;
      }
    }
    work = _decide(o, lead, members, t, replyTo: replyTo, lang: lang, thread: p.id);
    return true;
  }

  /// Asks [bots] to answer the owner's [t]. With a [thread] (several bots, one message) they answer one after another.
  void _ask(Office o, List<Bot> bots, String t, {String replyTo = '', String thread = ''}) {
    for (final b in bots) {
      Offices.I.askBot(o, b.id, t, replyTo: replyTo, thread: thread);
    }
  }

  /// Who the owner is talking to in [t]: @mentions (or @team), the author of the bot message they reply to, or a member
  /// whose name opens the message ("Nova, could you…", "hey Nova:"). Empty: nobody in particular.
  static List<Bot> addressed(Office o, String t, {String replyTo = ''}) {
    final out = <Bot>[...Offices.I.mentioned(o, t)];
    if (replyTo.isNotEmpty) {
      final q = o.posts.where((p) => p.id == replyTo).firstOrNull;
      final b = q == null ? null : Bots.I.byId(q.from);
      if (b != null && o.members.contains(b.id) && !out.contains(b)) out.add(b);
    }
    if (out.isEmpty) {
      final m = RegExp(r'^(?:(?:hey|hi|ok|okay|so|and|walaal)\s+)?([\w\u0600-\u06FF-]+)\s*[,:،]', caseSensitive: false).firstMatch(t);
      if (m != null) {
        final n = m.group(1)!.toLowerCase();
        for (final id in o.members) {
          final b = Bots.I.byId(id);
          if (b != null && b.name.toLowerCase() == n) out.add(b);
        }
      }
    }
    return out;
  }

  /// The system prompt of the "who speaks" decision. Instructions, not a rule table: the model reads the room, with
  /// every message labelled (owner, lead, member and role) and the situation (TeamTranscript, owner 2026-11-05).
  @visibleForTesting
  static String floorSystem(Office o, Bot? lead, List<Bot> members, {bool leadAddressed = false}) {
    final leading = TeamLeadMode.leads(o);
    final sb = StringBuffer('# Who speaks\n');
    if (leadAddressed) {
      sb.writeln('The owner just wrote to ${lead?.name}, the lead of the team "${o.name}". Decide whether they are asking the lead to '
          'run a piece of work with the team (it needs several members, or they ask the lead to organise, plan or hand it out: '
          '"team_task": true) or simply talking to the lead (a question, a chat, something the lead answers itself: false).');
    } else {
      sb.writeln('You read the group chat of the team "${o.name}" and decide, the way the people in a real work chat would, who '
          'answers the owner\'s newest message, if anyone. ONE member answers: the one who is asked, or whose job it clearly is; the '
          'others stay quiet. Nobody answers just to acknowledge or to show they are there, and nobody answers what a teammate already '
          'answered.');
      sb.writeln('- The message continues a conversation with one member (answers their question, follows up on what they '
          'said): that member answers.');
      sb.writeln('- A question or request that fits one member\'s role: that member, even if it is not the lead.');
      if (leading) {
        sb.writeln('- The lead is leading right now (the owner is away or handed over). When the owner asks the team for work that '
            'needs several members, set "team_task": true and the lead will plan and assign it.');
      } else {
        sb.writeln('- The owner is here and leads; the lead is a member like the others (pick the lead only for its own role or when '
            'the owner talks to it). When the owner asks for work that needs several roles, set "team_task": true and list in '
            '"speakers" only the members whose roles are needed, most relevant first (at most 3). Nobody coordinates them.');
      }
      sb.writeln('- A greeting or thanks to everyone: one member at most replies, briefly, or nobody.');
      sb.writeln('- A note, an FYI, the owner thinking aloud, or nothing anyone needs to answer: "none". Silence is normal.');
    }
    sb
      ..writeln('\n${TeamTranscript.observer(o)}')
      ..write('\nReply with JSON only, no code fence: {"speaker":"<member name or none>","speakers":[],"team_task":false}');
    return sb.toString();
  }

  /// The decision step: who answers (or nobody), or a team job. A job goes to the lead to plan when the owner told
  /// the lead to (addressed it with a job) or the lead leads (owner away or handed over); otherwise the members the
  /// job needs answer one after another (a thread), each for its own role.
  Future<void> _decide(Office o, Bot? lead, List<Bot> members, String t,
      {String replyTo = '', bool leadAddressed = false, String lang = 'en', String thread = ''}) async {
    final all = [if (lead != null) lead, ...members];
    Bot? speaker;
    final speakers = <Bot>[];
    var teamTask = false;
    var none = false;
    try {
      final asker = lead ?? members.first;
      final raw = await _once(asker, floorSystem(o, lead, members, leadAddressed: leadAddressed), t, maxTokens: 160);
      final m = RegExp(r'\{[\s\S]*\}').firstMatch(raw);
      final j = m == null ? null : jsonDecode(m.group(0)!);
      if (j is Map) {
        teamTask = j['team_task'] == true || '${j['team_task']}'.toLowerCase() == 'true';
        final n = '${j['speaker'] ?? ''}'.trim().toLowerCase();
        none = n == 'none' || n == 'nobody';
        speaker = all.where((b) => b.name.toLowerCase() == n).firstOrNull;
        for (final x in (j['speakers'] as List? ?? const [])) {
          final s = '$x'.trim().toLowerCase();
          final b = all.where((b) => b.name.toLowerCase() == s).firstOrNull;
          if (b != null && !speakers.contains(b) && speakers.length < 3) speakers.add(b);
        }
      }
    } catch (e) {
      debugPrint('team floor: $e');
      if (leadAddressed && lead != null) {
        Offices.I.askBot(o, lead.id, t, replyTo: replyTo);
        return;
      }
      Offices.I.post(o, 'system', BotManner.nobody(lang: lang), kind: 'system');
      return;
    }
    if (leadAddressed) speaker = lead;
    final leads = leadAddressed || o.delegated;
    if (teamTask && lead != null && members.isNotEmpty && leads) {
      // The lead plans and hands the parts out: the replies already asked of the teammates for this message go, so
      // nobody answers twice (once on their own, once with their part).
      if (thread.isNotEmpty) Offices.I.queue.removeWhere((q) => q.officeId == o.id && q.thread == thread && q.kind == 'reply');
      await _propose(o, lead, members, t, lang: lang);
      return;
    }
    if (teamTask && !leads) {
      final who = speakers.isNotEmpty ? speakers : [if (speaker != null) speaker];
      if (who.isNotEmpty) {
        _ask(o, who, t, replyTo: replyTo, thread: thread);
        return;
      }
    }
    if (speaker != null) {
      // The lead talked to alongside named teammates answers in the same thread, after them.
      Offices.I.askBot(o, speaker.id, t, replyTo: replyTo, thread: leadAddressed ? thread : '');
      return;
    }
    // CB-37: no speaker the team knows (a name that is no member, or no answer at all) used to drop the message without a
    // word. A deliberate "none" stays silent: a note or an FYI needs no answer (owner, 2026-10-24: silence is normal).
    if (!none) Offices.I.post(o, 'system', BotManner.nobody(lang: lang), kind: 'system');
  }

  static final _bullet = RegExp(r'^\s*(?:[-*•▪◦]|\(?(?:\d{1,2}|[a-h]|[\u0660-\u0669]{1,2})[.)\-:])\s+\S', multiLine: true, caseSensitive: false);
  static final _inlineNum = RegExp(r'(?:^|[\s,;:،؛])\(?(?:\d{1,2}|[\u0660-\u0669]{1,2})\)\s*\S');
  static final _deliverable = RegExp(
      r'^(?:please\s+|also\s+|then\s+|and\s+)?(?:compare|find|make|write|draft|create|research|list|prepare|build|summari[sz]e|plan|design|check|'
      r'send|collect|calculate|translate|review|look up|put together|samee|sameeya|qor|raadi|isbarbar dhig|diyaari|soo saar|hubi|soo ururi|xisaabi|'
      r'tarjun)\b',
      caseSensitive: false);
  // Arabic letters are no \w to RegExp, so no \b here (a verb may also carry a suffix: اكتبها).
  static final _deliverableAr = RegExp(r'^(?:ثم\s+)?(?:قارن|اكتب|ابحث|أعد|اعد|جهز|جهّز|اصنع|لخص|صمم|حضر|حضّر|ارسل|أرسل|اجمع|احسب|ترجم|راجع|ضع|انشئ|أنشئ)');

  /// CB-36: whether [t] lists two or more deliverables: bullet or numbered lines, inline "1) … 2) …", or two or more
  /// clauses that each open on a deliverable verb ("compare three laptops, make a table and draft an email";
  /// Somali "iyo", Arabic "و" join them too).
  @visibleForTesting
  static bool looksLikeTeamTask(String t) {
    if (_bullet.allMatches(t).length >= 2) return true;
    if (_inlineNum.allMatches(t).length >= 2) return true;
    final clauses = t
        .split(RegExp(r'[,;،؛\n]|\band then\b|\bthen\b|\band\b|\biyo\b|\bkadibna\b|\s+و(?=\S)|\s+ثم\s+', caseSensitive: false))
        .map((c) => c.trim().replaceFirst(RegExp(r'^(?:can you|could you|please|team|kooxda|fadlan|الرجاء|من فضلك|يا فريق)[\s,،]+', caseSensitive: false), ''))
        .where((c) => c.isNotEmpty);
    return clauses.where((c) => _deliverable.hasMatch(c) || _deliverableAr.hasMatch(c)).length >= 2;
  }

  /// The owner's Start / Go tap (same as writing "Go").
  bool approve(Office o) => awaitingGo(o) && send(o, 'Go');

  /// The owner's Cancel tap on a waiting plan.
  void cancelPlan(Office o) {
    if (!awaitingGo(o)) return;
    send(o, 'Cancel');
  }

  OfficePost _owner(Office o, String t, [String replyTo = '']) {
    final p = Offices.I.post(o, 'you', t, replyTo: replyTo);
    o.lastOwnerPost = DateTime.now();
    return p;
  }

  static String _roster(List<Bot> members) => [for (final b in members) '- ${b.name}: ${b.role}${b.mission.isEmpty ? '' : '. ${b.mission}'}'].join('\n');

  /// Step 2: the lead posts the plan, then starts the team right away unless it has to ask the owner something.
  Future<void> _propose(Office o, Bot lead, List<Bot> members, String job, {String lang = 'en'}) async {
    TeamPlan? startNow;
    running.add(o.id);
    notifyListeners();
    _note(o, TeamPlan(job: job, parts: const [], lang: lang), planned: false);
    await _hold(o);
    try {
      final sys = '${promptOf(lead)}\n\n${BotManner.lead}\n\n# Plan for the owner\nYou lead the team "${o.name}"'
          '${o.goal.isEmpty ? '' : ' (team goal: ${o.goal})'}.\nMembers:\n${_roster(members)}\n\n${TeamTranscript.observer(o, max: 10)}\n\n'
          'The owner just gave the team the task below. Understand it, then split it into concrete subtasks: one part per member at '
          'most, only members whose role fits; each part a specific, self-contained ask written for that member\'s role (what to do, '
          'what to hand back), never the owner\'s message copied or forwarded. When a part needs another part\'s result, say so in '
          '"after" (the member it waits for). "reply": one short line in your own words on what the team will deliver (do not repeat '
          'the owner\'s message). The team starts right after your message, so ask questions (at most two) only when something you '
          'truly need is missing or it is a judgment call only the owner can make; otherwise leave "questions" empty. Write in the '
          'owner\'s language.\n'
          'Reply with JSON only, no code fence: {"reply":"<one line>","questions":["…"],"parts":[{"bot":"<member name>","ask":"<their part>","after":""}]}';
      String reply = '';
      final questions = <String>[];
      final parts = <({Bot bot, String ask})>[];
      // A failed model call ends here (the outer catch says so); only an unreadable reply falls back to "everyone".
      final raw = await _once(lead, sys, job, maxTokens: OutputLimits.structured, office: o.id);
      try {
        final m = RegExp(r'\{[\s\S]*\}').firstMatch(raw);
        final j = m == null ? null : jsonDecode(m.group(0)!);
        if (j is Map) {
          reply = '${j['reply'] ?? ''}'.trim();
          for (final q in (j['questions'] as List? ?? const [])) {
            final s = '$q'.trim();
            if (s.isNotEmpty && questions.length < 2) questions.add(s);
          }
          for (final e in (j['parts'] as List? ?? const [])) {
            if (e is! Map) continue;
            final name = '${e['bot'] ?? ''}'.trim().toLowerCase();
            final b = members.where((x) => x.name.toLowerCase() == name || x.role.toLowerCase() == name).firstOrNull;
            var a = '${e['ask'] ?? ''}'.trim();
            final after = '${e['after'] ?? ''}'.trim();
            // The lead copying the owner's message into a part is no plan (owner 2026-11-05): the member gets a part
            // for its role instead, and the owner's words stay where they are (in the chat every member reads).
            if (a.isNotEmpty && b != null && TeamDedupe.parrots(job, a)) a = roleAsk(b);
            if (b != null && after.isNotEmpty && after.toLowerCase() != b.name.toLowerCase() && members.any((x) => x.name.toLowerCase() == after.toLowerCase())) {
              a = '$a (after ${members.firstWhere((x) => x.name.toLowerCase() == after.toLowerCase()).name})';
            }
            if (b != null && a.isNotEmpty && !parts.any((x) => x.bot == b)) parts.add((bot: b, ask: a));
          }
        }
      } catch (_) {}
      // An unreadable plan: each member takes the part of the job that fits its role (never the owner's words copied).
      if (parts.isEmpty) parts.addAll([for (final b in members) (bot: b, ask: roleAsk(b))]);
      if (TeamDedupe.parrots(job, reply)) reply = '';
      // "Stop" while the lead was still thinking: no plan is left waiting.
      if (_stopped.contains(o.id)) return;
      final plan = TeamPlan(job: job, parts: parts, lang: lang);
      if (questions.isEmpty) {
        // Grok-style: nothing to ask, so the team gets going right away.
        final text = planText(plan, reply: reply, starting: true);
        Offices.I.post(o, lead.id, text, assigns: false);
        _tell(o, lead, text);
        startNow = plan;
      } else {
        pending[o.id] = plan;
        Offices.I.post(o, lead.id, planText(plan, reply: reply, questions: questions), assigns: false);
        _tell(o, lead, questions.first);
      }
    } catch (_) {
      // CB-19: a stop makes the lead's call fail; that is no failure to report.
      if (!_stopped.contains(o.id)) {
        Offices.I.post(o, 'system', BotManner.couldNotFinish(lang: lang), kind: 'system');
        _tell(o, lead, BotManner.couldNotFinish(lang: lang));
      }
    } finally {
      running.remove(o.id);
      _stopped.remove(o.id);
      if (startNow == null) _unnote(o.id);
      Offices.I.saveSoon();
      notifyListeners();
      // Starting right away: the run holds the phone awake before this lets go, so it never drops in between.
      if (startNow == null) await _release();
    }
    final go = startNow;
    if (go != null) {
      try {
        await _run(o, lead, go);
      } finally {
        await _release();
      }
    }
  }

  /// A member's part when the lead's plan gave none it could use: the side of the owner's request its role covers.
  /// The request itself is in the team chat (and in the member's prompt), so it is not repeated here.
  static String roleAsk(Bot b) => 'Take the part of the owner\'s request that fits your role'
      '${b.role.trim().isEmpty ? '' : ' (${b.role.trim()})'}, do it fully and hand back a concrete result.';

  /// The lead's message with the plan: the goal, any questions, who does what, and the question to start.
  static String planText(TeamPlan p, {String reply = '', List<String> questions = const [], bool starting = false}) {
    final sb = StringBuffer();
    if (reply.isNotEmpty) sb.writeln(reply);
    if (questions.isNotEmpty) {
      if (sb.isNotEmpty) sb.writeln();
      for (final q in questions) {
        sb.writeln(q);
      }
    }
    if (sb.isNotEmpty) sb.writeln();
    sb.writeln(BotManner.planHeader(lang: p.lang));
    for (final x in p.parts) {
      sb.writeln('- ${x.bot.name}: ${_short(x.ask, 140)}');
    }
    sb
      ..writeln()
      ..write(starting ? BotManner.startingNow(lang: p.lang) : BotManner.askGo(lang: p.lang));
    return sb.toString().trim();
  }

  /// Step 3: the approved plan, as a conversation. The lead runs on the agent core with one hand-off tool per member of
  /// the plan; each hand-off runs that member's part (its own agent run, with its own tools) and posts it in the chat.
  /// Parts the lead did not hand off still run, in order, so a job always finishes; then the lead writes one answer.
  Future<void> _run(Office o, Bot lead, TeamPlan plan) async {
    running.add(o.id);
    _jobBots[o.id] = {lead.id, for (final p in plan.parts) p.bot.id};
    notifyListeners();
    _note(o, plan);
    await _hold(o);
    final done = <({Bot bot, String text})>[];
    final handed = <Bot>{};
    Future<String> doPart(Bot b, String ask) async {
      if (_stopped.contains(o.id)) return 'Stopped by the owner.';
      if (handed.contains(b)) return '${b.name} already did their part: ${_short(done.firstWhere((d) => d.bot == b, orElse: () => (bot: b, text: '')).text, 600)}';
      handed.add(b);
      // The plan already showed this part: a hand-off line only when the lead changed it (owner 2026-11-05: the same
      // ask was posted twice, in the plan and again as a hand-off).
      final planned = plan.parts.where((p) => p.bot == b).firstOrNull?.ask ?? '';
      if (!TeamDedupe.near(planned, ask, at: 0.7) && planned.trim() != ask.trim()) {
        Offices.I.post(o, lead.id, BotManner.handOff(b.name, ask, lang: plan.lang), assigns: false);
      }
      // No cap on how many members work at once (owner 2026-11-04): every hand-off starts now, each member in its own
      // opencode session, side by side with the owner's chat and other bots.
      final r = await _part(o, lead, b, ask, plan, [...done]);
      _jobBots[o.id]?.remove(b.id);
      // CB-19: a part cut short by the owner's stop posts nothing (it used to say "I could not finish my part").
      if (_stopped.contains(o.id)) return 'Stopped by the owner.';
      done.add((bot: b, text: r.result));
      // A part that failed posts no "could not finish" bubble: the team chat shows one small line instead
      // ("Nova · rate limit", owner 2026-11-04), and the lead still hears about it.
      if (r.note == BotManner.partFailed(lang: plan.lang) && r.result == r.note) return r.result;
      final post = Offices.I.post(o, b.id, r.note, dedupe: false, assigns: false);
      post.parts.add((from: b.id, text: r.result));
      Offices.I.saveSoon();
      return r.result;
    }

    try {
      String leadAnswer = '';
      final offs = [for (final p in plan.parts) handoffTool(p.bot, p.ask)];
      final byTool = {for (var i = 0; i < plan.parts.length; i++) Wire.toolName(offs[i]): plan.parts[i]};
      final oc = ocTurn;
      if (oc != null && plan.parts.isNotEmpty) {
        // On opencode: the lead works in its own session and hands parts off with team_assign (one tool, by name).
        final roster = [for (final p in plan.parts) '- ${p.bot.name} (${p.bot.role}): ${_short(p.ask, 300)}'].join('\n');
        final sys = '${Bots.I.opencodeBriefOf(lead, team: true)}\n\n${BotManner.lead}\n\n# Lead the work\nYou lead the team "${o.name}". The owner '
            'approved this plan for the task: "${plan.job}"${_ownerSaid(o)}\nPlanned parts:\n$roster\n'
            'Hand each part to its member with submac_run_tool name "$assignName", arguments {"member": "<name>", "ask": "<their part>"}. '
            'Parts that do not depend on each other can be handed off together; they run side by side. When a later part needs what '
            'an earlier member found, hand them off one at a time and include what they need. When every part is back, write ONE clear '
            'answer for the owner: the result first, then what matters, then the next step if there is one. Credit a teammate by name '
            'only where it helps. Plain, calm words in the owner\'s language. Never forward the owner\'s message as an ask: each '
            'ask is a concrete subtask for that member\'s role, with anything it needs from teammates.${_folderNote(o, lead: true)}\n\n'
            '${TeamTranscript.build(o, lead, max: 12)}';
        try {
          leadAnswer = (await oc(lead, TeamKey.of(o.id, lead.id, job: TeamKey.job()), sys, 'Start the work.', stopped: () => _stopped.contains(o.id),
                  assign: (member, a) async {
            final n = member.trim().toLowerCase();
            final p = plan.parts.where((p) => p.bot.name.toLowerCase() == n || p.bot.role.toLowerCase() == n).firstOrNull;
            if (p == null) return 'Error: no member named "$member" in this job. Members: ${plan.parts.map((p) => p.bot.name).join(', ')}.';
            return doPart(p.bot, a.trim().isEmpty ? p.ask : a.trim());
          }))
              .trim();
        } catch (e) {
          leadAnswer = '';
          if (!_stopped.contains(o.id)) TeamStatus.I.failBot(o.id, lead.id, e);
        }
      } else if (llm != null && offs.isNotEmpty) {
        final sys = '${promptOf(lead)}\n\n${BotManner.lead}\n\n# Lead the work\nYou lead the team "${o.name}". The owner approved this plan '
            'for the task: "${plan.job}"${_ownerSaid(o)}\nHand each part to its member with their hand-off tool. Parts that do not '
            'depend on each other can be handed off together in one message; they then run side by side (like sub-agents), so do that '
            'when you can. When a later part needs what an earlier member found, hand them off one at a time, in order. When every part '
            'is back, write ONE clear answer for the owner: the result first, then what matters, then the next step if there is one. '
            'Credit a teammate by name only where it helps. Plain, calm words in the owner\'s language.';
        try {
          final r = await _agent(lead, sys, 'Start the work.', extra: offs, maxSteps: plan.parts.length + 3, maxTokens: OutputLimits.answer,
              stopped: () => _stopped.contains(o.id), office: o.id, onExtra: (c, a) async {
            final p = byTool[c.name];
            if (p == null) return 'Error: no such teammate.';
            final ask = '${a['ask'] ?? ''}'.trim();
            return doPart(p.bot, ask.isEmpty ? p.ask : ask);
          });
          leadAnswer = r.text;
        } catch (_) {
          leadAnswer = '';
        }
      }
      // Parts the lead did not hand off still run, so the job always finishes: all of them at once.
      final left = [for (final p in plan.parts) if (!handed.contains(p.bot)) p];
      final leftover = left.isNotEmpty && !_stopped.contains(o.id);
      if (leftover) await Future.wait([for (final p in left) doPart(p.bot, p.ask)]);
      if (_stopped.contains(o.id) || done.isEmpty) return;
      final answer = (!leftover && leadAnswer.isNotEmpty) ? leadAnswer : await _combine(lead, plan, done, o);
      if (_stopped.contains(o.id)) return;
      final post = Offices.I.post(o, lead.id, answer, kind: 'answer', assigns: false);
      _tell(o, lead, answer);
      for (final d in done) {
        post.parts.add((from: d.bot.id, text: d.text));
      }
      lead.log('work', 'Led ${o.name}: ${_short(plan.job, 80)}', team: true);
    } catch (e) {
      if (!_stopped.contains(o.id)) {
        Offices.I.post(o, 'system', BotManner.couldNotFinish(lang: plan.lang), kind: 'system');
        _tell(o, lead, BotManner.couldNotFinish(lang: plan.lang));
      }
    } finally {
      running.remove(o.id);
      _jobBots.remove(o.id);
      _stopped.remove(o.id);
      _inbox.remove(o.id);
      _unnote(o.id);
      Offices.I.saveSoon();
      notifyListeners();
      await _release();
    }
  }

  /// The lead's hand-off tool for one member: `handoff_<name>` with the ask in the member's own words.
  static Map<String, dynamic> handoffTool(Bot b, String ask) {
    final slug = b.name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
    final id = b.id.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    final name = 'handoff_${slug.isEmpty ? 'member' : slug}_${id.length > 6 ? id.substring(0, 6) : id}';
    return {
      'type': 'function',
      'function': {
        'name': name.length > 60 ? name.substring(0, 60) : name,
        'description': 'Hand ${b.name} (${b.role}) their part of the job and wait for their result. Planned part: ${_short(ask, 300)}',
        'parameters': {
          'type': 'object',
          'properties': {
            'ask': {'type': 'string', 'description': 'The part for ${b.name}, clear and self-contained (you may refine the planned part with what teammates reported).'},
          },
          'required': ['ask'],
        },
      },
    };
  }

  String _ownerSaid(Office o) {
    final l = _inbox[o.id] ?? const <String>[];
    return l.isEmpty ? '' : '\nWhile the team worked, the owner also said (follow it): ${l.map((t) => '"$t"').join(' then ')}';
  }

  /// One member's turn: a short note to the lead for the chat, and the full result (kept with the post, opened on tap).
  Future<({String note, String result})> _part(Office o, Bot lead, Bot b, String part, TeamPlan plan, List<({Bot bot, String text})> before) async {
    try {
      final notes = before.isEmpty
          ? ''
          : '\n\nWhat teammates already reported:\n${[for (final d in before) '- ${d.bot.name}: ${_short(d.text, 600)}'].join('\n')}';
      final oc = ocTurn;
      final sys = '${oc != null ? Bots.I.opencodeBriefOf(b, team: true) : promptOf(b)}\n\n${BotManner.member(lead.name)}\n\n'
          '${oc != null ? '${TeamTranscript.build(o, b, max: 12)}\n\n' : ''}# Your part\nYou are ${b.name} (${b.role.isEmpty ? 'member' : b.role}) in the team "${o.name}", led by ${lead.name}. '
          'The owner asked the team: "${plan.job}"${_ownerSaid(o)}$notes\n\n${lead.name} gave you the part below. Do it well, then reply in two '
          'pieces: first one or two short sentences to ${lead.name} for the team chat (what you did and anything they should know; name a '
          'teammate if you build on their work), then a line with only ---, then your full result: concrete, no greeting, no questions back.';
      if (oc != null) {
        final raw = (await oc(b, TeamKey.of(o.id, b.id, job: TeamKey.job()), sys + _folderNote(o), part, stopped: () => _stopped.contains(o.id))).trim();
        b.log('work', 'Team part for ${o.name}: ${_short(part, 60)}', team: true);
        if (raw.isEmpty && !_stopped.contains(o.id)) TeamStatus.I.flag(o.id, b.id, TeamStatus.noReply);
        return splitReport(raw, lang: plan.lang);
      }
      final tools = toolsFor?.call(b) ?? const <Map<String, dynamic>>[];
      final raw = (await _agent(b, sys, part,
              tools: tools, maxTokens: OutputLimits.answer, stopped: () => _stopped.contains(o.id), office: o.id, summarizeOnHalt: true))
          .text
          .trim();
      b.log('work', 'Team part for ${o.name}: ${_short(part, 60)}', team: true);
      return splitReport(raw, lang: plan.lang);
    } catch (e) {
      // The team chat's small line for it ("Nova · timed out"); a stop by the owner is no failure.
      if (!_stopped.contains(o.id)) TeamStatus.I.failBot(o.id, b.id, e);
      final f = BotManner.partFailed(lang: plan.lang);
      return (note: f, result: f);
    }
  }

  /// "note --- result" from a member. Without the line, the first sentence or two is the note.
  static ({String note, String result}) splitReport(String raw, {String lang = 'en'}) {
    final t = raw.trim();
    if (t.isEmpty) {
      final f = BotManner.partFailed(lang: lang);
      return (note: f, result: f);
    }
    final m = RegExp(r'\n\s*-{3,}\s*\n').firstMatch(t);
    if (m != null) {
      final note = t.substring(0, m.start).trim();
      final result = t.substring(m.end).trim();
      if (note.isNotEmpty && result.isNotEmpty) return (note: note, result: result);
      return (note: _short(note.isEmpty ? result : note, 280), result: result.isEmpty ? note : result);
    }
    final first = t.split(RegExp(r'\n\s*\n')).first.trim();
    return (note: _short(first, 280), result: t);
  }

  Future<String> _combine(Bot lead, TeamPlan plan, List<({Bot bot, String text})> parts, Office o) async {
    final sys = '${promptOf(lead)}\n\n${BotManner.lead}\n\n# Combine\nYou lead the team "${o.name}". Your members did their parts of the '
        'owner\'s task.${_ownerSaid(o)}\nWrite ONE clear answer for the owner: the result first, then what matters, then the next step if '
        'there is one. Merge the parts; credit a teammate by name only where it helps. Plain, calm words in the owner\'s language.';
    final user = 'The task: ${plan.job}\n\n${[for (final p in parts) '## ${p.bot.name} (${p.bot.role})\n${p.text}'].join('\n\n')}';
    final r = (await _once(lead, sys, user, maxTokens: OutputLimits.answer, office: o.id)).trim();
    return r.isEmpty ? parts.map((p) => p.text).join('\n\n') : r;
  }

  static String _short(String s, [int n = 60]) {
    final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length > n ? '${t.substring(0, n)}…' : t;
  }

  /// Tests: the bots a running job still counts on.
  @visibleForTesting
  void jobBotsForTest(String officeId, Set<String> bots) => _jobBots[officeId] = bots;

  /// Tests: forget every team's state.
  @visibleForTesting
  void reset() {
    running.clear();
    _jobBots.clear();
    pending.clear();
    _inbox.clear();
    _stopped.clear();
    _cores.clear();
    _coreBots.clear();
    _journal.clear();
    _awake = 0;
    work = null;
  }
}

/// A plan the lead proposed: the task and who does which part.
class TeamPlan {
  TeamPlan({required this.job, required this.parts, String lang = 'en', bool somali = false, this.replan = false})
      : lang = somali ? 'so' : lang;
  final String job;
  final List<({Bot bot, String ask})> parts;

  /// The owner's language for the fixed phrases: en | so | ar (CB-63).
  final String lang;
  bool get somali => lang == 'so';

  /// Restored after SubMac closed before the lead had a plan (CB-64): "go" plans again.
  final bool replan;
}


/// A team agent run's side of the Genkit core: a short private history (the prompt, the ask, this run's steps), the
/// member's tools through the app, hand-off tools through the team.
class _TeamHooks extends CoreHooks {
  _TeamHooks(this.team, this.bot, this.system, this.user, this.tools, this.extra, this.onExtra, this.stopped);
  final TeamRun team;
  final Bot bot;
  final String system, user;
  final List<Map<String, dynamic>> tools;
  final Set<String> extra;
  final Future<String> Function(ToolCall c, Map<String, dynamic> args)? onExtra;
  final bool Function() stopped;
  final List<Map<String, dynamic>> _history = [];
  String lastText = '';

  @override
  bool get cancelled => stopped();

  /// CB-65: the last call of a member that hit its step cap: what it did so far, as plain text, and no tools.
  Turn summaryTurn(int step) {
    final sb = StringBuffer();
    for (final m in _history) {
      final c = m['content'];
      if (m['role'] == 'tool') {
        sb.writeln('Tool result: ${c ?? ''}');
      } else if (m['role'] == 'assistant') {
        if (c is String && c.trim().isNotEmpty) sb.writeln('You wrote: $c');
        for (final t in (m['tool_calls'] as List? ?? const [])) {
          final f = t is Map ? t['function'] : null;
          if (f is Map) sb.writeln('You called ${f['name']} ${f['arguments'] ?? ''}');
        }
      }
    }
    var work = sb.toString().trim();
    if (work.length > 12000) work = '…${work.substring(work.length - 12000)}';
    return Turn(step: step, payload: [
      {'role': 'system', 'content': system},
      {
        'role': 'user',
        'content': '$user\n\n# Your work so far\n${work.isEmpty ? '(nothing yet)' : work}\n\nYou have used all your steps, so no more tools. '
            'Sum up what you found now, in the same two-piece format: the note, a line with only ---, then your full result.'
      },
    ]);
  }

  @override
  Future<Turn> buildTurn(int step, String? notes) async => Turn(step: step, payload: [
        {'role': 'system', 'content': system},
        {'role': 'user', 'content': user},
        ..._history,
        if (notes != null) {'role': 'user', 'content': notes},
      ], tools: tools.isEmpty ? null : tools);

  @override
  Future<void> commit(Reply r) async {
    if (r.text.trim().isNotEmpty) lastText = r.text.trim();
    _history.add({
      'role': 'assistant',
      'content': r.text.isEmpty && r.hasCalls ? null : r.text,
      if (r.hasCalls) 'tool_calls': [for (final c in r.calls) c.toJson()],
    });
  }

  @override
  Future<Map<String, dynamic>?> approvalFor(ToolCall call, Map<String, dynamic> args) async {
    if (extra.contains(call.name)) return null;
    return team.approvalFor?.call(bot, call, args);
  }

  @override
  Future<ToolApproval> answer(ToolCall call, Map<String, dynamic> args, Map<String, dynamic> data) async =>
      await team.answer?.call(bot, call, args, data) ?? const ToolApproval.no('The owner did not approve this. Do not retry it.');

  @override
  Future<String> runTool(ToolCall call, Map<String, dynamic> args, {Object? approved}) async {
    if (extra.contains(call.name)) return onExtra == null ? 'Error: not available.' : onExtra!(call, args);
    final r = team.runTool;
    if (r == null) return 'Error: tools are not available here.';
    return r(bot, call, args, approved: approved);
  }

  @override
  String cleanOutput(String out) => ToolOutputClean.clean(out);

  /// The lead handing off several members in one message: their parts are independent by that choice,
  /// so they run side by side (the agent core starts them together and awaits each in turn). The
  /// member's own tools stay in order — approvals and one-at-a-time phone hands are theirs alone.
  @override
  List<List<int>> parallel(List<ToolCall> calls) {
    final idx = <int>[for (var i = 0; i < calls.length; i++) if (extra.contains(calls[i].name)) i];
    return idx.length >= 2 ? [idx] : const [];
  }

  @override
  Future<void> toolDone(ToolCall call, Map<String, dynamic> args, String output) async {
    _history.add({'role': 'tool', 'tool_call_id': call.id, 'content': output});
  }

  @override
  Future<ErrorAction> onError(Object error) async => ErrorAction.stop;
}
