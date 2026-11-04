import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'services/choices.dart';
import 'agent/run_journal.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart' hide User;
import 'package:uuid/uuid.dart';

import 'config.dart';
import 'models.dart';
import 'services/calc.dart';
import 'services/confirm_queue.dart';
import 'services/biz_tools.dart';
import 'services/health_tools.dart';
import 'services/code_git.dart';
import 'services/code_tools.dart';
import 'services/forged_tools.dart';
import 'services/mcp_oauth.dart';
import 'services/mcp_known.dart';
import 'services/mcp_routes.dart';
import 'services/team_key.dart';
import 'services/team_status.dart';
import 'services/screen_lease.dart';
import 'services/media_coder.dart';
import 'services/ai_keys.dart';
import 'services/ai_models.dart';
import 'services/setup_tools.dart';
import 'services/projects.dart';
import 'services/byok.dart';
import 'services/cloud.dart';
import 'services/llm_client.dart';
import 'agent/core.dart';
import 'services/agent_loop.dart';
import 'services/quick_lane.dart';
import 'services/opencode.dart';
import 'services/oc_lanes.dart';
import 'services/oc_scope.dart';
import 'services/submac_gateway.dart';
import 'services/turn_visuals.dart';
import 'services/submac_mcp.dart';
import 'services/submac_style.dart';
import 'services/usage_accounting.dart';
import 'services/local_store.dart';
import 'services/repo.dart';
import 'services/device_access.dart';
import 'services/live_session.dart';
import 'services/tools.dart';
import 'services/truth.dart';
import 'services/connector_tools.dart';
import 'services/doc_tools.dart';
import 'services/mcp_client.dart';
import 'services/memory_store.dart';
import 'services/phone_tools.dart';
import 'services/rate_limiter.dart';
import 'services/retry_plan.dart';
import 'services/paste_guard.dart';
import 'services/web_tools.dart';
import 'services/browser_agent.dart';
import 'services/browser_jobs.dart';
import 'services/browser/skill_sync.dart';
import 'services/bot_package.dart';
import 'services/bots.dart';
import 'services/bot_powers.dart';
import 'services/bot_sync.dart';
import 'services/events.dart';
import 'services/inbox.dart';
import 'services/skill_library.dart';
import 'services/somali.dart';
import 'services/calm.dart';
import 'services/skills_catalog.dart';
import 'services/connector_catalog.dart';
import 'services/run_status.dart';
export 'services/run_status.dart' show RunPhase, RunStatus;
import 'services/live_controller.dart';
import 'services/push.dart';
import 'services/system_bridge.dart';
import 'services/system_tools.dart';
import 'services/task_bubble.dart';
import 'services/wake_word.dart';
import 'services/live_tasks.dart';
import 'services/whatsapp.dart';
import 'services/telegram_bridge.dart';
import 'services/doc_maker.dart';
import 'services/life_tools.dart';
import 'services/offices.dart';
import 'services/bot_status.dart';
import 'services/bot_manner.dart';
import 'services/team_run.dart';
import 'widgets/chat/reply_quote.dart' show ReplyRef, ReplyCodec;
import 'widgets/composer.dart' show Composer;
import 'services/roles.dart';
import 'services/full_access.dart';
import 'services/trust.dart';
import 'services/image_once.dart';
import 'services/photo_prep.dart';
import 'services/send_gate.dart';
import 'services/session_rules.dart';
import 'services/stream_policy.dart';
import 'services/search_budget.dart';
import 'services/sites.dart';
import 'services/tool_scope.dart';
import 'services/constraints.dart';
import 'services/house_rules.dart';
import 'services/outbound_guard.dart';

part 'state/agent_runner.dart';
part 'state/agent_stream.dart';
part 'state/bots_controller.dart';
part 'state/chat_controller.dart';
part 'state/connectors.dart';
part 'state/live_calls.dart';
part 'state/settings_store.dart';
part 'state/system_phone.dart';
part 'state/tool_catalog.dart';
part 'state/tool_router.dart';

const _uuid = Uuid();

class AppState extends ChangeNotifier {
  // notifyListeners is @protected; the split-out extensions call this instead.
  void _notify() => notifyListeners();

  final repo = Repo();
  final local = LocalStore();
  late final memory = MemoryStore(local);

  /// Text/files shared into SubMac from other apps, picked up by the composer.
  final shareInbox = ValueNotifier<Map<String, dynamic>?>(null);
  /// Home-screen widget taps: 'ask' focuses the composer, 'scan' opens the camera.
  final widgetAction = ValueNotifier<String?>(null);

  /// The message the user is replying to in the open chat (swipe or hold a message, then Reply), shown above the
  /// composer. Its convId says which chat it belongs to; another chat never sends it.
  final replyDraft = ValueNotifier<ReplyRef?>(null);

  // Connectors
  List<McpServerConfig> mcpServers = [];
  List<McpTool> mcpTools = [];
  Map<String, String> mcpStatus = {};
  bool memoryEnabled = true;

  // One model for every job: `submac`. The server picks the real model behind it (PLAN 1.1).
  /// "Think harder" for this session only (see [thinking]); never saved.
  String _thinkingNow = 'auto';

  static bool usableProvider(ProviderConfig p) => Cloud.isCloud(p);

  // Live voice (a short-lived pass from SubMac Cloud per call; no key on the phone)
  String liveVoice = 'Kore';
  /// A one-time Live mode for the next session ('translate' = live interpreter).
  String liveMode = '';

  static String _clip(String s, int n) => s.length <= n ? s : '${s.substring(0, n)}…';

  static const String _liveRules = '# Live voice\n'
      'You are talking out loud with the user in real time. Speak naturally and warmly, in clear spoken sentences. '
      'Fit the length to what they asked: a quick question or small talk gets a sentence or two; when they ask you to '
      'explain, teach, tell a story, describe, compare, give steps, read something out or go into detail, give the whole '
      'answer out loud, as long as it really needs, and finish it. Do not cut it short, do not stop halfway to ask whether '
      'to go on, and do not pad it with filler or repeat yourself. For steps or several points, say them in order in '
      'flowing speech ("first", "then", "after that"). If the user starts talking, stop and listen. '
      'No markdown, no lists read aloud, no URLs. Ask one thing at a time. '
      'Only say something is done when a tool result shows it. '
      'Confirm before you send, post, pay, buy or delete anything they did not clearly ask for.\n'
      '# Doing things on the phone (you do them yourself, now)\n'
      '- Opening an app, WhatsApp, tapping, typing, reading the screen, alarms, texts, contacts, notifications: do it yourself, '
      'right now, during the call, with your tools: open_app, phone_screen, phone_tap, phone_type, phone_scroll, phone_nav, '
      'whatsapp, set_alarm and the rest. Chain the steps one after another until it is really done: open the app, read the '
      'screen, tap, type, check the screen again.\n'
      '- Before each step say three or four words of progress ("Opening WhatsApp", "Typing it", "Sending"), then call the tool. '
      'When the last tool result shows it worked, say so in one short sentence ("Sent.").\n'
      '- For WhatsApp messages use the whatsapp tool (it opens the chat and presses Send itself); a card on screen asks the '
      'user to approve first.\n'
      '- If a tool says phone control is off, tell the user how to switch it on. Never pretend.\n'
      '# Background tasks (rare, and only real ones)\n'
      '- NEVER say you are doing something "in the background", or that you will "report back" or "let them know when it is '
      'done", unless live_task returned a task id (like T1) in this call. Otherwise do it now, or say you cannot.\n'
      '- live_task is only for genuinely long jobs: website work (browsing, signing in, forms, booking, shopping), deep '
      'research, documents. It hands the job to the full SubMac agent, which keeps running after the call and posts the result in '
      'the chat with a notification. Say the task id when you start one.\n'
      '- Use task_status when they ask how it is going and stop_task to stop one.\n'
      '- Messages starting with [Task update] come from the app, not the user. Tell the user the news in one or two short sentences. '
      'If a task asks a question, ask the user out loud and pass their answer with answer_task. '
      'Never ask for passwords or card numbers out loud: a sign-in card appears on screen for that.\n'
      '- The browser runs out of sight. If they want to watch it, call browser_show; to hide it, browser_hide.';

  // ---------- Live: hand-off tasks to the full agent ----------
  /// The Live screen listens here for task news to speak.
  void Function(String text)? onLiveTaskNews;
  final Set<String> _liveTaskConvs = {};

  static final List<Map<String, dynamic>> liveTaskTools = [
    {
      'type': 'function',
      'function': {
        'name': 'live_task',
        'description': 'Start a REAL tracked task run by the full SubMac agent (browser, connected apps, saved logins, files, '
            'documents, research). Only for long jobs: websites, research, documents. Phone steps (apps, WhatsApp, taps) you do '
            'yourself instead. Returns a task id (T1...); the result arrives later as a [Task update] and in the chat.',
        'parameters': {
          'type': 'object',
          'properties': {
            'task': {'type': 'string', 'description': 'The complete job in plain words, with every detail the user gave.'},
            'in_chat': {'type': 'boolean', 'description': 'True when the user chose to continue this in chat.'},
            'show_browser': {'type': 'boolean', 'description': 'True when the user wants to watch the browser.'},
          },
          'required': ['task'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'task_status',
        'description': 'What the tasks started with live_task are doing (all, or one by id).',
        'parameters': {
          'type': 'object',
          'properties': {
            'id': {'type': 'string', 'description': 'Task id like T1 (optional).'}
          },
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'stop_task',
        'description': 'Stop the running background task(s).',
        'parameters': {'type': 'object', 'properties': {}},
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'answer_task',
        'description': 'Pass the user\'s spoken answer to the question a background task asked.',
        'parameters': {
          'type': 'object',
          'properties': {
            'answer': {'type': 'string', 'description': 'The user\'s answer.'}
          },
          'required': ['answer'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'browser_show',
        'description': 'Show the small live browser window so the user can watch the task.',
        'parameters': {
          'type': 'object',
          'properties': {
            'full_screen': {'type': 'boolean', 'description': 'Show it full screen.'}
          },
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'browser_hide',
        'description': 'Hide the browser window again; the task keeps working.',
        'parameters': {'type': 'object', 'properties': {}},
      },
    },
  ];

  static final Set<String> liveTaskToolNames = {
    for (final d in liveTaskTools) '${(d['function'] as Map)['name']}'
  };


  /// Tasks Live really started (ids T1, T2...), with their status and result.
  final liveTasks = LiveTasks();
  String? _lastLiveTaskConv;

  /// Runs [task] as a normal agent turn in the current chat (or a new one) without blocking.
  /// Returns an error message, or null when it started.
  String? lastOwnConvId;
  String? _tgConv;
  DateTime _tgLast = DateTime(2000);

  /// Called with the final reply when a background task with its own chat finishes.
  final Map<String, void Function(String reply)> _doneCbs = {};

  /// Runs a tool, asking the user first when the action is risky (Ask mode).
  /// Runs a tool and never lets it crash the task: any failure comes back to the model as a plain,
  /// actionable message, so it can fix its inputs, try another way, or tell the user.
  // ---------- bots ----------
  /// Bot chats with a wake running now (and the kind of wake).
  final Map<String, String> _botWakeConvs = {};

  /// CB-17: the rows the running (or just finished) wake in each bot chat wrote itself. A silent wake removes only
  /// these, never what the owner typed meanwhile or the quick replies to it.
  final Map<String, Set<String>> _wakeRows = {};

  /// Where the phone's Back goes from a bot's chat: the chat that was open before the first bot chat
  /// (null = a new chat). Set only while a bot chat is open (see backFromBotChat).
  String? _backFromBot;
  bool _botOpenedOver = false;

  /// Plan 2.2 office caps: most steps one piece of office work may take (a teammate's budget per task, the Chief's
  /// planning round). Answering the owner keeps the normal limit. Near the cap the bot is told to wrap up.
  static int officeStepCap(String kind, {bool browsing = false}) => switch (kind) {
        'reply' => 30,
        'mention' => 8,
        'task' || 'unblock' => browsing ? 60 : 25,
        _ => 10, // chief, review, digest
      };

  /// Why a piece of bot work failed, from its error text: credit (allowance used up) | offline | busy | other.
  static String failureOf(String e) {
    if (RegExp(r'allowance|done a lot today|refreshes tomorrow|resting until tomorrow', caseSensitive: false).hasMatch(e)) return 'credit';
    if (RegExp(r"you're offline|connection dropped|took too long|network error|socketexception|failed host lookup|connection (refused|reset|closed)|timed? ?out|no internet", caseSensitive: false).hasMatch(e)) return 'offline';
    if (RegExp(r"busy|couldn't reach its models|couldn't get an answer just now|lost the connection|short break|\b429\b|too many requests|\b50[234]\b|unavailable", caseSensitive: false).hasMatch(e)) return 'busy';
    return 'other';
  }

  /// One "paused" line a day in a bot's activity log when its share of the allowance is used.
  static const bgPausedText = 'Paused until tomorrow to save your daily allowance';
  /// The bot whose call is ringing, and what it prepared to say.
  String? _ringing;
  final Map<String, String> _ringText = {};
  Timer? _ringTimer;
  /// The in-app incoming call screen watches this.
  final ValueNotifier<Bot?> incomingCall = ValueNotifier<Bot?>(null);

  // ---------- "From SubMac" in chat ----------
  static const _teamConvKey = 'team_conv_id';
  static const _teamPostedKey = 'team_posted';
  bool _mirroring = false;

  /// Bots doing their first job right now (plan 5.2 hire flow): their first result is counted once it lands.
  final Set<String> _firstJob = {};

  // ---------- offices ----------
  /// Office work running right now (its team key, see TeamKey) -> its office. Office work runs under its own key and
  /// its own opencode session, never in the bot's private chat (bots team audit 2026-11-04).
  final Map<String, String> _officeCtx = {};
  /// Office jobs running now, by team key. No cap on how many run at once, or on one bot doing two (owner
  /// 2026-11-04: bots work natively and in parallel).
  final Map<String, OfficeLiveJob> _officeJobs = {};
  /// Bots running an office job now.
  Set<String> get _officeBusy => {for (final j in _officeJobs.values) j.botId};
  /// The office the user is looking at (no notifications for it, unread stays 0).
  String? viewingOffice;
  /// Opens an office or the approvals inbox from a notification (the home screen listens).
  final ValueNotifier<String?> openRequest = ValueNotifier<String?>(null);

  Timer? _retryTimer;

  /// Time until the daily cloud allowance refreshes (midnight UTC), plus a few minutes.
  static Duration _untilAllowanceResets() {
    final now = DateTime.now().toUtc();
    final next = DateTime.utc(now.year, now.month, now.day + 1, 0, 5);
    return next.difference(now);
  }

  // ---------- browser subagent ----------
  final Map<String, AgentRun> _jobRuns = {};

  /// The tool result when an ask was not approved; "Edit" on an ask with nothing to edit means "change it first".
  static String _notApproved(ActionRequest req, String no) => req.wantsChange
      ? 'Not done yet: the owner wants something changed first. Ask them in one short line what to change, then try again with their change.'
      : no;

  /// The text the owner may change before something is sent: (argument path, current text), or null.
  static (String, String)? _editField(String name, Map<String, dynamic> args) {
    Map<String, dynamic> a = args;
    var prefix = '';
    if (name == 'apps_run_tool' && args['arguments'] is Map) {
      a = Map<String, dynamic>.from(args['arguments'] as Map);
      prefix = 'arguments.';
    }
    for (final k in const ['message', 'body', 'text', 'content', 'caption', 'comment']) {
      final v = a[k];
      if (v is String && v.trim().isNotEmpty) return ('$prefix$k', v);
    }
    return null;
  }

  static Map<String, dynamic> _withEdit(String name, Map<String, dynamic> args, String path, String value) {
    if (path.startsWith('arguments.')) {
      final inner = Map<String, dynamic>.from(args['arguments'] as Map)..[path.substring(10)] = value;
      return {...args, 'arguments': inner};
    }
    return {...args, path: value};
  }

  /// The latest file the agent made or changed in each chat, so "this" / "it" in the next message has a clear target.
  final Map<String, String> _lastMade = {};

  /// The chat a Live call is being saved into (set on the first saved turn).
  String? liveConvId;
  bool _liveSaving = false;
  int _liveSaved = 0;

  // ---------- phone-level features: Live anywhere, notifications, schedules ----------
  late final LiveController liveCtl = LiveController(this);
  bool notifyWhenDone = true;
  bool appVisible = true;

  /// Easy mode was removed (PLAN 1.7). Always false; kept only so older screens still read it until Dev 3 drops them.
  bool get easyMode => false;
  /// Reply language: auto (match the user), or a fixed one such as Somali.
  String replyLanguage = 'auto';

  /// Deep research for the next message (set from the + menu).
  bool deepResearch = false;

  /// A skill picked from the chips or the Skills page: shown as a chip in the composer,
  /// and its instructions ride along with the next message only.
  Skill? pickedSkill;
  /// The picked skill's note, by the chat its message was sent in; only that chat's next task takes it.
  final Map<String, String> _skillNotes = {};

  /// A killed run's resume note, by chat: the next task in that chat (the resumed one) starts with it.
  final Map<String, String> _resumeNotes = {};


  /// Chats a background task is being started in right now (between "is it free?" and the run starting).
  final Set<String> _bgStarting = {};

  final Set<String> _notifyConvs = {};

  /// Opens Advanced > System permissions (set by the home screen).
  void Function()? openSystemSettings;

  /// A calm notification: the title names the task, the body says the result in one or two plain sentences.
  /// A short, elegant notification: the task as a headline and one quiet line. Never the full reply.
  /// Returns (title, line, kind).
  /// One short line that says what matters: "Your image is ready", "Scheduled: Go to the grocery store",
  /// or the reply's own first sentence when it is short ("I posted the picture, go check").
  static (String, String, String) notificationFor(String convTitle, String reply, {String media = ''}) {
    final scheduled0 = convTitle.startsWith('Scheduled:');
    var task0 = convTitle.replaceFirst(RegExp(r'^(Scheduled|Watching):\s*'), '').replaceAll(RegExp(r'[#*_`]'), '').trim();
    if (task0.length > 60) task0 = '${task0.substring(0, 58).trimRight()}…';
    final plain0 = reply.replaceAll(RegExp(r'```[\s\S]*?```'), ' ').replaceAll(RegExp(r'[#*_`>]'), '').replaceAll(RegExp(r'\s+'), ' ').trim();
    final first = RegExp(r'^.+?[.!?](\s|$)').firstMatch(plain0)?.group(0)?.trim() ?? plain0;
    if (plain0.endsWith('?') && plain0.length > 70) return (task0, 'I need a quick answer from you', 'attention');
    if (scheduled0) {
      // The result itself, in one line that fits the bar. No subject, no "Scheduled:" label.
      var line = plain0.split(RegExp(r'(?<=[.!?])\s+|\n|---')).where((e) => e.trim().isNotEmpty).take(2).join(' ').trim();
      if (line.isEmpty) line = '${task0.isEmpty ? 'Your scheduled task' : task0} is done';
      if (line.length > 110) line = '${line.substring(0, 108).trimRight()}…';
      return ('', line, 'scheduled');
    }
    if (media.isNotEmpty && (first.isEmpty || first.length > 70)) return (task0, 'Your $media is ready', 'done');
    if (first.isNotEmpty && first.length <= 70) return (task0, first.replaceAll(RegExp(r'[.]$'), ''), 'done');
    return (task0, task0.isEmpty || task0.toLowerCase() == 'new chat' ? 'Your task is done' : '$task0 is done', 'done');
  }

  // Preferences
  ThemeMode themeMode = ThemeMode.system;
  bool agentEnabled = true;
  /// 'ask' = confirm risky actions, 'full' = do everything without asking.
  String approvalMode = 'ask';
  bool phoneAccess = false;
  /// Steps between checkpoints of a long task (no longer a setting).
  static const maxSteps = 50;

  String aboutYou = '';
  String howToRespond = '';

  // Chats
  List<Conversation> conversations = [];
  String? currentId;
  List<ChatMessage> messages = [];
  bool loadingConversations = false;
  bool loadingMessages = false;
  String? banner;
  /// Values for the `{name}` holes of [banner], so the banner is translated as one sentence (tr(banner, bannerArgs)).
  Map<String, String> bannerArgs = const {};

  /// Agent runs in flight, across all chats. Several can run at once:
  /// a long task keeps going while the user chats on.
  final List<AgentRun> runs = [];
  final Map<String, List<ChatMessage>> _lists = {};

  /// One run per chat, claimed at the top of send() before any await (PLAN 1.4).
  final SendGate _sendGate = SendGate();

  /// CB-22: chats whose "Try again" is removing the old reply and has not started its run yet. Claimed synchronously,
  /// so a second tap in the same frame does nothing.
  final Set<String> _regenerating = {};

  /// Test seam: when set, _runAgent registers the run (guards included) and then runs this instead of the model loop.
  @visibleForTesting
  static Future<void> Function(AppState app, AgentRun run)? debugRunAgent;

  /// Each picture goes to the model once; later steps get a one-line note (PLAN 1.4).
  final ImageOnce _imagesOnce = ImageOnce();


  /// How long each finished task worked, by the id of its final reply ("Worked for 1m 12s"). This session only.
  final Map<String, Duration> workedFor = {};
  Future<bool> Function(ActionRequest req)? confirmCallback;
  /// The in-app approval sheet shows one ask at a time and closes when its task is stopped.
  final ConfirmQueue confirmQueue = ConfirmQueue();

  /// The one live approval ask (owner, 2026-10-31): a thin card under the newest message of the task's own
  /// chat — never a modal sheet over half the screen. ConfirmQueue still lets one ask through at a time.
  final ValueNotifier<ConfirmAsk?> confirmNow = ValueNotifier(null);

  /// Shows [req] as the inline ask of [convId]'s chat; completes when the card is answered.
  Future<bool> askInChat(String? convId, ActionRequest req) {
    final c = Completer<bool>();
    confirmNow.value = ConfirmAsk(convId: convId, req: req, answer: (ok) {
      if (!c.isCompleted) c.complete(ok);
      if (identical(confirmNow.value?.req, req)) confirmNow.value = null;
    });
    return c.future;
  }

  /// The ask left without an answer (its task stopped, or nobody answered in time): it folds away as "no".
  void dropConfirm() {
    final a = confirmNow.value;
    confirmNow.value = null;
    a?.answer(false);
  }

  // ---------- browser + questions for the user ----------
  String? _browserConv;
  List<String> savedLoginSites = [];

  /// Things a running task needs from the user (a login, a code, a choice).
  /// Shown as a calm card above the composer; the task waits, the chat stays free.
  final List<UserAsk> asks = [];

  /// UI hook (chat feel): the id of the user message just sent whose task has not started yet, so the
  /// chat shows "Thinking" the instant the message is sent (before saving and uploading finish).
  String? awaitingReply;

  /// Talk to the user in the middle of a task without stopping it.
  static final Map<String, dynamic> sayTool = {
    'type': 'function',
    'function': {
      'name': 'say',
      'description': 'Send the user a short chat message right now while you keep working (the task does not stop). '
          'Use it to acknowledge something they said mid-task, share a useful finding, or tell them you are changing course. '
          'One or two plain sentences. Not every step: only when it helps them.',
      'parameters': {
        'type': 'object',
        'properties': {'text': {'type': 'string', 'description': 'What to tell the user.'}},
        'required': ['text'],
      },
    },
  };

  /// The task's checklist, so long builds (an app, a site, many files) keep going until every step is done.
  static final Map<String, dynamic> todoTool = {
    'type': 'function',
    'function': {
      'name': 'todo',
      'description': 'Your checklist for a long task (several files, an app, a website, many steps). Call it first with `steps` '
          '(short, concrete, in order), then call it with `done` as you finish each one. The task keeps going while steps are open, '
          'so never stop to ask "shall I continue?". Skip it for quick jobs.',
      'parameters': {
        'type': 'object',
        'properties': {
          'steps': {'type': 'array', 'items': {'type': 'string'}, 'description': 'The full list (replaces the old one).'},
          'done': {'type': 'array', 'items': {'type': 'integer'}, 'description': 'Numbers of the steps now finished (1 = first).'},
        },
      },
    },
  };


  static final Map<String, dynamic> askUserTool = {
    'type': 'function',
    'function': {
      'name': 'ask_user',
      'description': 'Ask the user something you need to keep going (a choice, a detail, a one-time code). '
          'The task waits for the answer; the user can keep chatting meanwhile. Ask one clear question; when it has likely answers, '
          'list them in options. Never use it for passwords: the browser agent signs in on a secure sheet.',
      'parameters': {
        'type': 'object',
        'properties': {
          'question': {'type': 'string', 'description': 'Short plain question.'},
          'options': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': 'Answers to tap, as a list of strings. ${Choices.rule} Leave it out only for free text (a name, an address, a code).'
          },
          'secret': {'type': 'boolean', 'description': 'Hide what they type (e.g. a verification code).'},
        },
        'required': ['question'],
      },
    },
  };

  /// Shows the connect sheet for an app (the agent asked for it, or a task needs it) and waits for the user.
  static final Map<String, dynamic> connectAppTool = {
    'type': 'function',
    'function': {
      'name': 'connect_app',
      'description': 'Show the user the connect sheet for an app, when they ask to connect one or your task needs one that is not connected. '
          'They tap Connect and sign in on the app\'s own page (or paste its key on the sheet); you wait, then its tools are ready. '
          'Always use this to connect: never open sign-in or token pages yourself (open_link, run_shell, the browser) and never ask for keys in chat.',
      'parameters': {
        'type': 'object',
        'properties': {
          'app': {'type': 'string', 'description': 'The app, e.g. "Notion", "GitHub", "Vercel", "Supabase", "Canva", "Zapier".'},
          'why': {'type': 'string', 'description': 'One short line shown on the sheet: what connecting lets you do for them now.'},
        },
        'required': ['app'],
      },
    },
  };

  /// Adds an MCP server the user gives in chat (address, plus a key or token when it needs one).
  static final Map<String, dynamic> addMcpServerTool = {
    'type': 'function',
    'function': {
      'name': 'add_mcp_server',
      'description': 'Connect an MCP server to SubMac from its address (and its key or token, when the user gives one). It is saved '
          'in the user\'s Apps, and its tools become SubMac tools. Without a key, SubMac opens the server\'s own sign-in if it has one. '
          'This is how to add MCP servers here; the engine\'s own config file is managed by the app. Composio: pass the user\'s '
          'key as token (ck_... or ak_...); SubMac knows its address. If it fails, report the error; never say it connected.',
      'parameters': {
        'type': 'object',
        'properties': {
          'name': {'type': 'string', 'description': 'Short name, e.g. "Linear".'},
          'url': {'type': 'string', 'description': 'The MCP endpoint, e.g. https://mcp.example.com/mcp'},
          'token': {'type': 'string', 'description': 'API key or token, if given. Sent as "Authorization: Bearer <token>" unless header is set.'},
          'header': {'type': 'string', 'description': 'Header name for the token when the server wants another one, e.g. "x-api-key".'},
          'headers': {'type': 'object', 'description': 'Any other headers the server needs.'},
        },
        'required': ['url'],
      },
    },
  };

  /// The user's published sites: list them, or take one offline when they ask.
  static final Map<String, dynamic> sitesTool = {
    'type': 'function',
    'function': {
      'name': 'sites',
      'description': 'The websites the user published from SubMac. action "list" shows each one (title, where, address, status). '
          'action "unpublish" takes one offline (only when the user asks): pass site as its title or address.',
      'parameters': {
        'type': 'object',
        'properties': {
          'action': {'type': 'string', 'enum': ['list', 'unpublish']},
          'site': {'type': 'string', 'description': 'Title or address of the site (for unpublish).'},
        },
        'required': ['action'],
      },
    },
  };

  /// The user's SubMac projects: list, create, put this chat in one, save a file or a note into one.
  static final Map<String, dynamic> projectsTool = {
    'type': 'function',
    'function': {
      'name': 'projects',
      'description': 'The user\'s SubMac projects (folders of chats, files and standing instructions). When they say "my project" or '
          '"add this to my project", this is the tool. action: "list" | "create" (name, optional note) | "add_chat" (puts THIS chat in '
          'the project, so it keeps its context) | "save_file" (copies a file from the workspace by path, or saves content as name, into '
          'the project\'s files) | "add_note" (adds a standing note or instruction to the project). project = its name.',
      'parameters': {
        'type': 'object',
        'properties': {
          'action': {'type': 'string', 'enum': ['list', 'create', 'add_chat', 'save_file', 'add_note']},
          'project': {'type': 'string', 'description': 'Project name (not needed for list).'},
          'name': {'type': 'string', 'description': 'create: new project name. save_file: file name to save as.'},
          'path': {'type': 'string', 'description': 'save_file: a file that already exists in the workspace.'},
          'content': {'type': 'string', 'description': 'save_file: text to save when there is no file yet.'},
          'note': {'type': 'string', 'description': 'create/add_note: the instruction or note text.'},
        },
        'required': ['action'],
      },
    },
  };

  static Project? _projectFor(String q) {
    final t = q.trim().toLowerCase();
    if (t.isEmpty) return null;
    final all = Projects.I.list;
    final exact = all.where((p) => p.name.toLowerCase() == t || p.id == q.trim()).firstOrNull;
    if (exact != null) return exact;
    final hits = all.where((p) => p.name.toLowerCase().contains(t) || t.contains(p.name.toLowerCase())).toList();
    return hits.length == 1 ? hits.first : null;
  }

  static Site? _siteFor(String q) {
    final t = q.trim().toLowerCase().replaceFirst(RegExp(r'^https?://'), '').replaceAll(RegExp(r'/+$'), '');
    if (t.isEmpty) return null;
    final live = Sites.I.list.where((s) => s.url.isNotEmpty).toList();
    for (final s in live) {
      final u = s.url.toLowerCase().replaceFirst(RegExp(r'^https?://'), '').replaceAll(RegExp(r'/+$'), '');
      if (u == t || s.id == q.trim() || s.title.toLowerCase() == t) return s;
    }
    final hits = live.where((s) => s.title.toLowerCase().contains(t) || s.url.toLowerCase().contains(t)).toList();
    return hits.length == 1 ? hits.first : null;
  }

  static ConnDef? _connDefFor(String name) {
    final q = name.trim().toLowerCase();
    for (final d in ConnectorCatalog.all) {
      if (d.id == q || d.name.toLowerCase() == q) return d;
    }
    for (final d in ConnectorCatalog.all) {
      if (d.name.toLowerCase().startsWith(q)) return d;
    }
    return null;
  }

  Timer? _notifyTimer;
  /// Chats running a scheduled task right now: they notify with a one-line result only.
  final Set<String> _scheduledConvs = {};

  /// Apps being signed in to right now (by preset id or url), for the spinner on their row.
  final Set<String> mcpSigningIn = {};

  /// The last connect that didn't finish, per app key: shown as "Not connected · Try again" until the next try.
  final Map<String, String> mcpConnectError = {};

  /// Connected app tools for the model. Few tools: all of them, ready to call. Many: the
  /// most useful ones directly, and apps_list_tools/apps_run_tool reach every other tool, so the
  /// provider's tool limit is never hit however many apps are connected.
  static const _directMcpLimit = 8;
  /// Loads the tool lists of every enabled server.
  DateTime _mcpListedAt = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void>? _mcpRefreshing;

  static final _soundHint = RegExp(
      r'\b(music|song|melody|beat|beats|sound|sounds|audio|ringtone|jingle|tune|instrumental|ambient|lofi|lo-fi|drum|piano|guitar|hees|muusig|codka|موسيقى|صوت|نغمة)\b',
      caseSensitive: false);

  static String _normUrl(String u) {
    var t = u.trim().split('#').first;
    while (t.endsWith('/')) {
      t = t.substring(0, t.length - 1);
    }
    return t.toLowerCase();
  }

  /// Live-only tool (plan 3, step 4): searches what the phone already knows, without a model call.
  static final Map<String, dynamic> recallTool = <String, dynamic>{
    'type': 'function',
    'function': <String, dynamic>{
      'name': 'recall',
      'description': 'Search what you already know before asking the user again: saved facts about them, '
          'your bot memory and journal (on a bot call), recent chats and their summaries. Use it when they mention '
          'something from before ("like last time", a name, a past plan) that is not in your prompt.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'query': <String, dynamic>{'type': 'string', 'description': 'A few key words to look for.'},
        },
        'required': ['query'],
      },
    },
  };

  /// Tools a voice call does without (plan 3, step 7): browser steps (live_task drives them), documents, media by code,
  /// skills, app setup, and each app's own tools (apps_list_tools + apps_run_tool still reach every app).
  /// Fewer declarations: faster connect and fewer wrong picks.
  static bool liveSkip(String n) => _liveSkip(n);
  static bool _liveSkip(String n) =>
      BrowserAgent.names.contains(n) ||
      BrowserJobs.names.contains(n) ||
      DocTools.names.contains(n) ||
      DocMaker.names.contains(n) ||
      SetupTools.names.contains(n) ||
      MediaCoder.names.contains(n) ||
      SkillLibrary.names.contains(n) ||
      n == 'ask_user' ||
      n == 'say' ||
      n == 'todo' ||
      n.startsWith('mcp_');

  static const _screenActs = {'phone_tap', 'phone_long_press', 'phone_type', 'phone_scroll', 'phone_gesture'};
  static final _readOnlyTool = RegExp(r'(^|_)(get|list|search|read|fetch|find|query|retrieve|lookup|describe|show|view)', caseSensitive: false);

  static final _riskyClick = RegExp(
      r'\b(post|publish|send|submit|apply|pay|buy|order|checkout|place order|book|confirm|delete|remove|tweet|share|transfer|donate|subscribe)\b',
      caseSensitive: false);

  /// What an action will send, in plain lines ("Title: Weekly plan") instead of raw JSON, for the approval sheet.
  static String plainDetails(Map<String, dynamic> args, [String indent = '']) {
    final sb = StringBuffer();
    var n = 0;
    for (final e in args.entries) {
      if (e.value == null || '${e.value}'.isEmpty) continue;
      if (++n > 12) {
        sb.writeln('$indent…and more');
        break;
      }
      final k = e.key.replaceAll(RegExp(r'[_\-]+'), ' ').replaceAllMapped(RegExp(r'([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]}').trim();
      final label = k.isEmpty ? 'Value' : k[0].toUpperCase() + k.substring(1).toLowerCase();
      final v = e.value;
      if (v is Map) {
        sb.writeln('$indent$label:');
        sb.write(plainDetails(Map<String, dynamic>.from(v), '$indent  '));
      } else if (v is List) {
        final items = v.map((x) => x is Map ? x.values.where((y) => y is! Map && y is! List).take(2).join(' · ') : '$x').toList();
        sb.writeln('$indent$label: ${items.take(5).join(', ')}${items.length > 5 ? ' (+${items.length - 5} more)' : ''}');
      } else {
        var t = '$v'.replaceAll(RegExp(r'\s+'), ' ').trim();
        if (t.length > 280) t = '${t.substring(0, 280)}…';
        sb.writeln('$indent$label: $t');
      }
    }
    return sb.toString().trimRight();
  }

  /// One gentle heads-up per day when the allowance gets close, and one when replies turn lighter.
  void _usageNotice() {
    final u = Cloud.usage.value;
    if (u.state != 'notice' && u.state != 'light') return;
    final key = 'usageNote_${u.state}';
    final today = DateTime.now().toUtc().toIso8601String().substring(0, 10);
    if (local.prefs.getString(key) == today) return;
    local.prefs.setString(key, today);
    banner = u.state == 'notice'
        ? 'Heads up: you\'ve used most of today\'s allowance. It refreshes tomorrow.'
        : 'Busy day! Replies will be a little shorter until tomorrow.';
    notifyListeners();
  }


  /// The project a new chat will join when it starts (set by "New chat" inside a project).
  String? newChatProject;



  /// The exact time, to the minute, with the weekday and zone. It goes at the END of the prompt, so the long part before
  /// it stays byte-identical from step to step and providers can reuse their prompt cache. It used to be rounded to the
  /// hour, and the model then scheduled "in 30 minutes" at 12:56 for 12:30: the time had "passed", so the job ran at once
  /// and the bot said the wait was over (owner, 2026-11-02).
  static String _nowLine([DateTime? at]) => nowLineFor(at ?? DateTime.now());

  /// [_nowLine] for a given moment (tested).
  static String nowLineFor(DateTime n) {
    const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    final o = n.timeZoneOffset;
    final sign = o.isNegative ? '-' : '+';
    final oh = o.inMinutes.abs() ~/ 60, om = o.inMinutes.abs() % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    return 'Now: ${days[n.weekday - 1]} ${n.year}-${two(n.month)}-${two(n.day)} ${two(n.hour)}:${two(n.minute)} '
        '(phone\'s local time, UTC$sign${two(oh)}:${two(om)}).';
  }


  // ---------- auto-compaction ----------
  /// A compaction marker: a quiet 'system' row holding the summary. Its name carries the id of the last
  /// message it covers ("compact:<id>"), so the summary is never recomputed and survives a restart.
  static bool isCompactMark(ChatMessage m) => m.role == 'system' && (m.name ?? '').startsWith('compact:');







  /// An older wake prompt in a bot's chat, cut to what it asked for (the team snapshot before "# Now" is dropped).
  static String shrinkWake(String t) {
    final now = t.indexOf('\n# Now\n');
    var head = t.split('\n').first;
    var body = now >= 0 ? t.substring(now + 7) : t.substring(head.length);
    body = body.replaceAll(RegExp(r'\n{2,}'), '\n').trim();
    if (body.length > 500) body = '${body.substring(0, 500)}…';
    if (head.length > 120) head = head.substring(0, 120);
    return '$head\n$body\n(older work request, shortened)';
  }




  static String _tailOf(String s) => s.length > 300 ? s.substring(s.length - 300) : s;

  // ---------- long horizon ----------
  /// The most steps one task may take, however well it goes (a runaway guard; a full app build fits well inside).
  static const longTaskCeiling = 1000;

  /// Today's allowance is nearly used (keeps a reserve so the user can still chat). Own keys report nothing: never low.
  static bool allowanceLow() {
    final u = Cloud.usage.value;
    return u.resting || u.light || u.ratio >= 0.9;
  }

  /// Why a long task should pause at a checkpoint, or null to go on (pure on its inputs; unit tested).
  /// Why a team member's round stopped at its step cap (shown to the owner; never an empty banner).
  static const officeCapReason = 'The team task used its step budget for this round, so it paused. Send "continue" to keep going.';

  static String? checkpointReason({required bool cancelled, required bool lowAllowance, required bool background,
      required int doneNow, required int doneAtCheckpoint, required int writesSinceCheckpoint, required int steps,
      int freshSinceCheckpoint = 0}) {
    if (cancelled) return 'Stopped.';
    if (background) return 'Paused after $steps steps. Send "continue" to keep going.';
    if (lowAllowance) return 'Paused to keep a little of today\'s allowance for you. Send "continue" to carry on (it refreshes tomorrow).';
    // Core loop v3: research, analysis and debugging move a task on by READING (new pages, new outputs, new errors),
    // not by writing files. Six tool results never seen before in this task count as progress (harness audit #5).
    if (doneNow > doneAtCheckpoint || writesSinceCheckpoint >= 2 || freshSinceCheckpoint >= 6) return null;
    return 'Paused after $steps steps: the last ones did not move the task on. Send "continue" with any hint, or a different approach.';
  }


  /// Unfinished-work signs in code or text (pure; unit tested).
  static final unfinished = RegExp(
      r'\b(TODO|FIXME|TBD)\b|lorem ipsum|coming soon|not (yet )?implemented|implement (this|me|later)|placeholder (text|content|data)|'
      r'(\.\.\.|…)\s*(rest|remaining|existing|other) (of (the )?)?(code|content|functions?|styles?|items?)|\bpass\s*#|'
      r'your[_ -]?api[_ -]?key|example\.com/(api|placeholder)',
      caseSensitive: false);

  /// The reply asks the user something (a question, a choice): stopping there is right.
  /// SubMac's own last reply (before the newest user message) asked the user something.
  static bool _answersOurQuestion(List<ChatMessage> list) {
    var sawUser = false;
    for (final m in list.reversed) {
      if (m.role == 'user') {
        if (sawUser) return false;
        sawUser = true;
        continue;
      }
      if (!sawUser || m.role != 'assistant') continue;
      if (m.toolCalls?.any((c) => c.name == 'ask_user') ?? false) return true;
      if (m.content.trim().isEmpty) continue;
      return _waitsOnUser(m.content);
    }
    return false;
  }

  /// Test hooks for the prompt and safety tests (no network, no state change).
  @visibleForTesting
  String livePromptForTest() => _liveBasePrompt(null);
  /// The step built last for [convId] got its answer (what the runner does after a model call).
  @visibleForTesting
  void imagesSentForTest(String convId) => _imagesOnce.commit(convId);
  @visibleForTesting
  Map<String, List<ChatMessage>> get listsForTest => _lists;
  @visibleForTesting
  Map<String, String> get resumeNotesForTest => _resumeNotes;
  @visibleForTesting
  List<Map<String, dynamic>> lightToolsForTest(String convId) => _lightTools(convId);
  @visibleForTesting
  List<Map<String, dynamic>> scopedToolsForTest(String convId) => _scopedTools(convId);
  @visibleForTesting
  List<Map<String, dynamic>> allToolsForTest(String convId) => _toolsFor(convId);
  @visibleForTesting
  Map<String, String> get skillNotesForTest => _skillNotes;
  @visibleForTesting
  SendGate get sendGateForTest => _sendGate;
  @visibleForTesting
  static bool answersOurQuestionForTest(List<ChatMessage> list) => _answersOurQuestion(list);

  static bool _waitsOnUser(String s) {
    final t = s.trim();
    return t.endsWith('?') || RegExp(r'\?\s*(\n|$)').hasMatch(_tailOf(t)) || t.contains('```choices') || t.contains('```confirm');
  }


  /// Tool groups open in each chat (only ever grow, so the prompt prefix stays stable turn to turn).
  final Map<String, Set<String>> _convGroups = {};

  /// Chats whose current task opened the whole toolbox with more_tools (cleared when the task ends).
  final Set<String> _allToolsNow = {};


  static const _lightNames = {
    'skill_search', 'skill_use',
    'say', 'web_search', 'fetch_url', 'get_weather', 'wikipedia', 'currency_convert', 'find_place', 'remember',
    'list_memories', 'set_alarm', 'set_timer', 'ask_user', 'prayer_times', 'hijri_date', 'quran', 'calculate',
  };

  static final Map<String, dynamic> _moreToolsDef = {
    'type': 'function',
    'function': {
      'name': 'more_tools',
      'description': 'Open your full toolbox (browser, phone control, texts and calls, WhatsApp, files and documents, Python, '
          'connected apps and email, scheduled tasks, pictures and sound, prayer times and the money notebook). '
          'Call it first whenever the request needs any tool you do not see here. Never tell the user you cannot do something before calling it.',
      'parameters': {
        'type': 'object',
        'properties': {
          'why': {'type': 'string'},
        },
      },
    },
  };

  /// Providers cap the number of tools (OpenAI: 128). Core tools come first, so trim the tail (extra apps/MCP).
  static List<Map<String, dynamic>>? _capTools(List<Map<String, dynamic>>? tools) {
    if (tools == null) return null;
    final seen = <String>{};
    final out = <Map<String, dynamic>>[];
    for (final t in tools) {
      final n = '${(t['function'] as Map?)?['name']}';
      if (seen.add(n)) out.add(t);
      if (out.length >= 120) break;
    }
    return out;
  }

  /// A tool result that means the step did not work (shown as "didn't work" in the step list).
  static bool stepFailed(String r) => ToolRecovery.stepFailed(r);


  /// One line for several read-only steps running together (English).
  static String groupLabel(List<ToolCall> calls) {
    final (k, a) = groupStatus(calls);
    return RunStatus.english(k, a);
  }

  /// The same as a status key with its holes (translated on screen).
  static (String, Map<String, String>) groupStatus(List<ToolCall> calls) {
    final names = calls.map((c) => c.name).toSet();
    final n = {'n': '${calls.length}'};
    if (names.length == 1 && names.first == 'fetch_url') return ('Reading {n} pages', n);
    if (names.length == 1 && names.first == 'web_search') return ('Searching the web ({n} searches)', n);
    if (names.every((x) => x == 'web_search' || x == 'fetch_url')) return ('Searching and reading {n} sources', n);
    if (names.every((x) => x == 'read_file' || x == 'list_dir' || x == 'read_pdf')) return ('Reading {n} files', n);
    return ('Checking {n} things at once', n);
  }

}


class RunStep {
  RunStep(this.label);
  final String label;
  final DateTime started = DateTime.now();
  DateTime? ended;
  bool failed = false;
  bool get done => ended != null;
}

class AgentRun {
  AgentRun({required this.convId, required this.side, required this.title});
  final String convId;
  final bool side;
  final String title;
  // R2 item 1: the live line follows the run's real events (lib/services/run_status.dart). [status] is an English key
  // with {holes} in [statusArgs], shown through the app's i18n.
  RunPhase _phase = RunPhase.starting;
  String _status = RunStatus.starting;
  Map<String, String> _args = const {};
  /// When the status line last changed, so a long wait can say so instead of looking frozen.
  DateTime statusAt = DateTime.now();
  RunPhase get phase => _phase;
  String get status => _status;
  Map<String, String> get statusArgs => _args;
  /// Words only, phase unchanged (a browser job's own progress line).
  set status(String v) => show(_phase, v);

  /// What the task is doing now: [phase], and the line's key with its holes.
  void show(RunPhase phase, String key, [Map<String, String> args = const {}]) {
    if (phase == _phase && key == _status && _sameArgs(args, _args)) return;
    _phase = phase;
    _status = key;
    _args = args;
    statusAt = DateTime.now();
  }

  static bool _sameArgs(Map<String, String> a, Map<String, String> b) =>
      a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

  /// The line in the app language, and in English (for the model and logs).
  String get statusText => RunStatus.text(_status, _args);
  String get statusEnglish => RunStatus.english(_status, _args);

  /// The waiting line of the next model call (a new message to read, a reply sent back, a retry after a drop).
  (String, Map<String, String>) nextCall = (RunStatus.waiting, const {});

  /// Tool calls running right now with their line (call id → key, holes), oldest first.
  final Map<String, (String, Map<String, String>)> running = {};

  /// Tool calls of the current model reply that have not returned yet.
  final Set<String> openCalls = {};

  /// The steps this task has taken so far, newest last (plain labels, never tool names).
  final List<RunStep> trail = [];
  int step = 0;
  bool browsing = false;
  /// Driving the phone right now (the red-dot layer and badge are up).
  bool phone = false;
  bool cancelled = false;
  LlmClient? client;
  final DateTime started = DateTime.now();
  /// What the user said while this task was working; read at the next step.
  final List<String> inbox = [];
  /// True while waiting on the model (false while a tool runs).
  bool inModel = false;
  /// A quick reply already answered the user's newest message; the task only has to act on it.
  bool inboxAcked = false;
  /// Tool calls since the user last heard from the agent (a say, or the start).
  int quietSteps = 0;
  final BlankGuard blanks = BlankGuard();
  /// Tokens this task has used so far, and the step it was told to wrap up at (its token limit).
  int tokens = 0;
  int wrapUpAt = -1;
  /// The step at which the loop guard told the task to stop (it was stuck); -1 while not stuck.
  int stuckStopAt = -1;
  /// The prompt size of the last step: each step only adds what is new (the earlier chat was already counted).
  int lastPromptTokens = 0;
  /// The task's own checklist (todo tool): steps, and which are done. While steps are open the task does not just stop.
  final List<String> todo = [];
  final Set<int> todoDone = {};
  /// The web page this task wrote (sites/.../index.html), so its card is never missing from the final reply.
  String? sitePage;
  /// The page this task built (kept after its card is shown), whether a page, style or script changed since its last
  /// check, and the rounds of fixes the site check asked for (SiteGate: the final reply waits until the page passes).
  String? siteEntry;
  bool siteDirty = false;
  int siteFixes = 0;
  bool siteExplained = false;
  /// A broken ```page card was sent back once.
  int pageFixes = 0;
  /// Page and file cards already shown in this run's replies, so a later reply never shows the same preview again.
  final Set<String> shownCards = <String>{};
  /// Times SubMac nudged the model to carry on (stopped with steps left, or cut off by the length limit).
  int nudges = 0;
  int cutOffs = 0;
  /// Notices loops (same call, same failing call, back and forth) across this task's tool calls.
  final LoopGuard guard = LoopGuard();
  /// Tool calls made so far, and failed ones in a row (for the final check and escalation).
  int toolCalls = 0;
  int failsInRow = 0;
  /// The request in the user's own words, amended by what they said mid-task (recited at the end of later steps).
  TaskBrief brief = TaskBrief('');
  /// The hard constraints read from the request (the "Must:" line and the final self-check).
  Constraints must = Constraints.none;
  /// Drops in a row continued with "continue" (reset when a step finishes): at most 2 per step (PLAN 1.3).
  int dropsInRow = 0;
  /// CB-38: searches that came back empty or Wikipedia-only, and read-only browser tasks, in this task.
  final SearchBudget search = SearchBudget();
  /// CB-39: fix rounds spent asking for a file-only reply to be written in the chat.
  int inlineFixes = 0;
  /// The first step's payload has been built: a message sent now reaches the task through its inbox.
  bool payloadBuilt = false;

  /// Long tasks run in segments of maxSteps: at each checkpoint the task goes on only while it is making progress
  /// (steps ticked off, files written) and today's allowance has room.
  int doneAtCheckpoint = 0;
  int writesSinceCheckpoint = 0;

  /// Successful tool results this task had never seen before (by digest), since the last checkpoint (core loop v3).
  int freshSinceCheckpoint = 0;
  final Set<int> seenOutputs = {};
  /// When the last checkpoint was (by distance, so a turn of several model calls can't skip one), and whether the
  /// next model call carries the checkpoint note.
  final CheckpointClock checkpoints = CheckpointClock();
  bool checkpointNote = false;
  /// The office step-budget note was given (once, at or after the cap).
  bool officeCapNoted = false;

  /// Work this task wrote (files made or changed), for the finish check.
  int writes = 0;
  final Set<String> touched = {};

  /// The finish check ran (re-read the request, test, look for unfinished code) before the final reply.
  bool verified = false;

  /// What this task's tool results actually proved (the truth gate reads it).
  final List<Evidence> evidence = [];
  /// Times the truth gate sent the model back to prove a completion claim (max one per task).
  int truthNudges = 0;
  /// The user's explicit requirements, re-shown to the model when it tries to finish.
  final List<String> contract = [];

  /// False while the checklist is one restored from a paused task that this task has not taken up yet (it calls
  /// todo or writes work): an unrelated new request is never pushed back onto the old plan.
  bool planLive = true;

  /// A final reply the loop sent back for more work; the next final reply replaces it (no duplicate answers).
  ChatMessage? heldReply;

  /// Tool calls running right now. A call of a stopped task is not among them, so the next request tells the model
  /// it was cancelled instead of "Still running in the background".
  final Set<String> pendingCalls = {};

  /// This run's id (its journal file is named after it).
  final String id = _uuid.v4();

  /// Stops the Genkit run (set by the runner): the model call or tool in progress ends and no new step starts.
  void Function()? onStop;

  /// The reply-format check sent a reply back once already.
  int formatFixes = 0;

  /// A guard took the tools away (budget, stuck): an empty last reply just ends the task quietly.
  bool noToolsAfterStop = false;

  void stop() {
    // The line says what happens now (the call or tool in flight is cut), never the last step's label.
    show(RunPhase.stopping, RunStatus.stopping);
    cancelled = true;
    client?.cancel();
    onStop?.call();
  }

  /// CB-17: ids of the chat rows this run added itself (its replies, tool results and says).
  final Set<String> wrote = {};

  /// Completes when the run has fully ended (its last write is done), so delete-all can wait for it (CB-18).
  final Completer<void> finished = Completer<void>();
  Future<void> get whenFinished => finished.future;
}

/// Something a running task needs from the user.
class UserAsk {
  UserAsk({
    required this.kind,
    required this.convId,
    required this.title,
    required this.prompt,
    this.site = '',
    this.options = const [],
    this.secret = false,
  });
  final String kind; // login | login_confirm | text | connect (site = 'mcp:<preset id>' or 'app:<connector id>')
  final String convId;
  final String title;
  final String prompt;
  final String site;
  final List<String> options;
  final bool secret;
  final Completer<Map<String, String>?> done = Completer<Map<String, String>?>();
}

/// What a tool call needs before it runs (see AppStateTools.toolGate): refused outright ([blocked]), the user's OK
/// ([ask], shown on the approval card), or nothing. The agent core turns [ask] into a Genkit interrupt.
class ToolGate {
  ToolGate({this.ask, this.kind = '', this.field, this.worker, this.office, this.whatsapp = false, this.refusal = '', this.req}) : blocked = null;
  ToolGate.blocked(String this.blocked)
      : ask = null,
        kind = '',
        field = null,
        worker = null,
        office = null,
        whatsapp = false,
        refusal = '',
        req = null;
  ToolGate.none({this.whatsapp = false, this.field, this.req})
      : blocked = null,
        ask = null,
        kind = '',
        worker = null,
        office = null,
        refusal = '';

  final String? blocked;
  final ActionRequest? ask;

  /// money | send | delete | change (BotTrust kinds).
  final String kind;

  /// The editable field of a send (path in the arguments, label), when the card lets the user edit the text.
  final (String, String)? field;
  final Bot? worker;
  final Office? office;
  final bool whatsapp;

  /// What the model reads when the user said no (or, set by presentApproval, when nobody answered in time).
  String refusal;
  final ActionRequest? req;

  /// The interrupt data the agent core carries for this ask (also written to the run journal).
  Map<String, dynamic> toInterrupt(String tool) => {
        'tool': tool,
        'kind': kind,
        'title': ask?.title ?? '',
        'detail': ask?.detail ?? '',
        'whatsapp': whatsapp,
      };
}


/// One office job running now (bots team audit 2026-11-04): who, for which team, what kind, and its live line.
class OfficeLiveJob {
  OfficeLiveJob({required this.botId, required this.officeId, required this.kind, this.taskId = ''}) : started = DateTime.now();
  final String botId;
  final String officeId;
  final String kind;
  final String taskId;
  final DateTime started;
  String status = 'Getting started';
}
