import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'ai_models.dart';
import 'biz_tools.dart';
import 'code_tools.dart';
import 'health_tools.dart';
import 'browser_agent.dart';
import 'browser_jobs.dart';
import 'connector_tools.dart';
import 'doc_maker.dart';
import 'doc_tools.dart';
import 'media_coder.dart';
import 'phone_tools.dart';
import 'setup_tools.dart';
import 'system_tools.dart';
import 'tools.dart';
import 'web_tools.dart';
import 'whatsapp.dart';

/// What a bot may use. Each tool belongs to one power; memory, its desk, office tools and plain talk are always on.
class BotPowers {
  static const all = ['web', 'browser', 'phone', 'files', 'apps'];

  static const labels = {
    'web': 'Search the web',
    'browser': 'Use the browser',
    'phone': 'Phone: screen, texts, calls',
    'files': 'Files and code',
    'apps': 'Connected apps and email',
  };

  static const blurbs = {
    'web': 'Search, read pages, weather, maps, Wikipedia',
    'browser': 'Open sites, sign in, fill forms, shop',
    'phone': 'Read texts and notifications, tap the screen, call or text',
    'files': 'Read and write files, make documents, pictures and sounds',
    'apps': 'Email, calendar, Notion and the other apps you connected',
  };

  static const _core = {
    'say', 'ask_user', 'more_tools', 'calculate', 'skill_search', 'skill_use', 'skill_install', 'skill_remove', 'skill_save', 'remember', 'forget', 'list_memories',
    'schedule_task', 'list_scheduled', 'cancel_scheduled',
    'prayer_times', 'hijri_date', 'quran', 'qibla', 'money_add', 'money_report', 'money_delete',
    'somali_knowledge', 'somali_knowledge_read',
    'bot_remember', 'bot_desk', 'bot_followup', 'bot_routine', 'bot_watch', 'bot_call', 'bot_ask', 'knowledge_search', 'knowledge_read', 'bot_lesson',
    // A message to the owner's own Telegram chat is like a notification: never taken away by a switched-off power.
    'bot_telegram',
    // The Chief's hiring tools are its core duty: they are never taken away by a switched-off power
    // (bot_make used to fall through groupOf to 'apps' and vanish when apps was off).
    'bot_make', 'team_make',
    'office_board', 'office_post', 'office_brief', 'office_ask_owner', 'office_kpi', 'docs_share', 'docs_list', 'docs_read',
  };

  /// The power a tool needs, or '' when it is always allowed.
  static String groupOf(String name) {
    if (_core.contains(name) || BizTools.names.contains(name) || HealthTools.names.contains(name)) return '';
    if (WebTools.names.contains(name) || name == 'fetch_url') return 'web';
    if (BrowserAgent.names.contains(name) || BrowserJobs.names.contains(name)) return 'browser';
    if (SystemTools.names.contains(name) || PhoneTools.names.contains(name) || WhatsAppTools.names.contains(name)) return 'phone';
    if (CodeTools.names.contains(name)) return 'files';
    if (AgentTools.fileNames.contains(name) ||
        const {'generate_image', 'generate_video', 'make_image', 'make_video', 'media_generate'}.contains(name) ||
        DocMaker.names.contains(name) ||
        DocTools.names.contains(name) ||
        AiModels.names.contains(name) ||
        MediaCoder.names.contains(name)) {
      return 'files';
    }
    if (SetupTools.names.contains(name)) return 'apps';
    if (ConnectorTools.names.contains(name) || name == 'api_call' || name.startsWith('app_') || name.startsWith('email_') || name.startsWith('mcp_')) {
      return 'apps';
    }
    return 'apps';
  }

  /// Plugins: skills on top of a power that the owner can switch off one by one. Stored in powersOff by id.
  static const plugins = ['whatsapp'];
  static const pluginLabels = {'whatsapp': 'WhatsApp'};
  static const pluginBlurbs = {'whatsapp': 'Read new messages, reply, send, share files and start calls on WhatsApp (needs Phone)'};
  static const pluginPower = {'whatsapp': 'phone'};

  static bool allowed(Set<String> off, String name) {
    if (off.isEmpty) return true;
    if (WhatsAppTools.names.contains(name) && off.contains('whatsapp')) return false;
    final g = groupOf(name);
    return g.isEmpty || !off.contains(g);
  }

  static List<Map<String, dynamic>> filter(List<Map<String, dynamic>> tools, Set<String> off) => off.isEmpty
      ? tools
      : [
          for (final t in tools)
            if (allowed(off, '${(t['function'] as Map?)?['name']}')) t,
        ];

  /// A line for the bot's prompt so it never promises what it may not do.
  static String note(Set<String> off) {
    if (off.isEmpty) return '';
    final names = [
      for (final g in all) if (off.contains(g)) labels[g]!.toLowerCase(),
      for (final g in plugins) if (off.contains(g)) pluginLabels[g]!,
    ];
    if (names.isEmpty) return '';
    return 'The owner switched off some of your powers: ${names.join(', ')}. You cannot use those. When a job needs one, '
        'say so plainly and suggest who could do it (another bot or the owner).';
  }
}

/// One step a bot took: a tool call or its final answer.
class TraceStep {
  TraceStep(this.at, this.tool, this.input, this.output, {this.ms = 0, this.failed = false});
  final DateTime at;
  final String tool;
  final String input;
  final String output;
  final int ms;
  final bool failed;
  Map<String, dynamic> toJson() => {'at': at.toIso8601String(), 't': tool, 'i': input, 'o': output, 'ms': ms, 'f': failed};
  static TraceStep fromJson(Map<String, dynamic> j) => TraceStep(
      DateTime.tryParse('${j['at']}') ?? DateTime.now(), '${j['t']}', '${j['i'] ?? ''}', '${j['o'] ?? ''}',
      ms: (j['ms'] as num?)?.toInt() ?? 0, failed: j['f'] == true);
}

/// One run of a bot from start to finish: what started it, each step, the tokens it used.
class TraceRun {
  TraceRun(this.id, this.botId, this.start, this.why);
  final String id;
  final String botId;
  final DateTime start;
  /// What started it ("You: …", "Routine: …", "Office task: …").
  final String why;
  DateTime? end;
  int tokens = 0;
  String result = '';
  bool failed = false;
  final List<TraceStep> steps = [];

  Duration get took => (end ?? DateTime.now()).difference(start);

  Map<String, dynamic> toJson() => {
        'id': id, 'b': botId, 's': start.toIso8601String(), 'w': why, 'e': end?.toIso8601String(), 'tk': tokens, 'r': result, 'f': failed,
        'st': steps.map((e) => e.toJson()).toList(),
      };
  static TraceRun fromJson(Map<String, dynamic> j) {
    final r = TraceRun('${j['id']}', '${j['b']}', DateTime.tryParse('${j['s']}') ?? DateTime.now(), '${j['w'] ?? ''}')
      ..end = DateTime.tryParse('${j['e']}')
      ..tokens = (j['tk'] as num?)?.toInt() ?? 0
      ..result = '${j['r'] ?? ''}'
      ..failed = j['f'] == true;
    for (final s in (j['st'] as List? ?? const [])) {
      r.steps.add(TraceStep.fromJson(Map<String, dynamic>.from(s as Map)));
    }
    return r;
  }
}

/// The record of what each bot did, kept on the phone (the last 30 runs per bot).
class BotTraces {
  BotTraces._();
  static final BotTraces I = BotTraces._();

  final Map<String, List<TraceRun>> _runs = {};
  final Map<String, TraceRun> _open = {};
  SharedPreferences? _p;
  bool _dirty = false;

  Future<void> init() async {
    _p = await SharedPreferences.getInstance();
    try {
      final m = jsonDecode(_p!.getString('bot_traces_v1') ?? '{}') as Map;
      for (final e in m.entries) {
        _runs['${e.key}'] = [for (final r in e.value as List) TraceRun.fromJson(Map<String, dynamic>.from(r as Map))];
      }
    } catch (_) {}
    // Runs cut off by the app stopping.
    for (final l in _runs.values) {
      for (final r in l.where((r) => r.end == null)) {
        r.end = r.steps.isEmpty ? r.start : r.steps.last.at;
        r.failed = true;
        r.result = r.result.isEmpty ? 'Stopped when the app closed' : r.result;
      }
    }
  }

  List<TraceRun> of(String botId) => List.unmodifiable((_runs[botId] ?? const <TraceRun>[]).reversed);

  static String _cut(String s, int n) {
    final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length > n ? '${t.substring(0, n)}…' : t;
  }

  void begin(String botId, String why) {
    final open = _open[botId];
    if (open != null) finish(botId, open.result, failed: open.failed);
    final r = TraceRun('${DateTime.now().millisecondsSinceEpoch}', botId, DateTime.now(), _cut(why, 140));
    _open[botId] = r;
    final l = _runs.putIfAbsent(botId, () => []);
    l.add(r);
    while (l.length > 30) {
      l.removeAt(0);
    }
    _save();
  }

  void step(String botId, String tool, String input, String output, {int ms = 0}) {
    final r = _open[botId];
    if (r == null) return;
    final failed = output.startsWith('Error') || output.startsWith('The owner did not approve');
    r.steps.add(TraceStep(DateTime.now(), tool, _cut(input, 240), _cut(output, 400), ms: ms, failed: failed));
    if (r.steps.length > 60) r.steps.removeAt(0);
    _save();
  }

  void tokens(String botId, int n) {
    final r = _open[botId];
    if (r != null) r.tokens += n;
  }

  void finish(String botId, String result, {bool failed = false}) {
    final r = _open.remove(botId);
    if (r == null) return;
    r.end = DateTime.now();
    r.result = _cut(result, 300);
    r.failed = failed;
    _save(now: true);
  }

  void clear(String botId) {
    _runs.remove(botId);
    _open.remove(botId);
    _save(now: true);
  }

  void _save({bool now = false}) {
    if (now) {
      _dirty = false;
      _p?.setString('bot_traces_v1', jsonEncode({for (final e in _runs.entries) e.key: e.value.map((r) => r.toJson()).toList()}));
      return;
    }
    if (_dirty) return;
    _dirty = true;
    Future<void>.delayed(const Duration(seconds: 3), () {
      if (_dirty) _save(now: true);
    });
  }
}
