import '../models.dart';
import 'browser_agent.dart';

/// Which Telesia tools an opencode turn may find and run, by who runs it (bots leak audit, owner 2026-11-03).
///
/// Every opencode turn reaches Telesia's tools through the same two MCP tools (find_tools, run_tool), so the list
/// behind them has to be cut per caller: the owner's own chat gets the app's tools only (no bot_make, bot_followup,
/// bot_remember, team_assign, team_task: those act on a bot, and offered to the main agent they invited calls that
/// failed or, routed to the wrong chat, acted on a bot), and a bot (or a team member) gets its own tools on top of the
/// app's, cut by the powers the owner switched off for it, as its old tool list was (tool_catalog `_toolsForRaw`).
/// Pure, so it is tested without the app.
class OcToolScope {
  OcToolScope._();

  static String nameOf(Map<String, dynamic> t) => '${(t['function'] is Map ? t['function'] as Map : t)['name']}';

  /// [app]: the app's tools for anyone. [botOwn], [office], [team]: the caller's own (empty for the owner's chat).
  /// [allowed]: the bot's switched-off powers and app scope; null for the owner's chat.
  /// [exclude]: app tools the caller never gets (a bot: [ownerMemory]).
  static List<Map<String, dynamic>> of({
    required List<Map<String, dynamic>> app,
    List<Map<String, dynamic>> botOwn = const [],
    List<Map<String, dynamic>> office = const [],
    List<Map<String, dynamic>> team = const [],
    bool Function(String name)? allowed,
    Set<String> exclude = const {},
  }) {
    // The owner's chat drives the in-app browser itself (browser_open/read/click/type...) on opencode's own model,
    // never through the browser subagent (browser_task*): that subagent runs on Telesia's own model and spends the
    // user's daily replies (owner 2026-11-18). Bots keep it (a whole unattended job), so the swap is owner-only and
    // only when the browser is offered at all (agentEnabled).
    final owner = botOwn.isEmpty && office.isEmpty && team.isEmpty && allowed == null;
    final browserOn = app.any((t) => _browserTaskTools.contains(nameOf(t)));
    final appTools = owner && browserOn
        ? [
            for (final t in app)
              if (!_browserTaskTools.contains(nameOf(t))) t,
            ...BrowserAgent.definitions,
          ]
        : app;
    final seen = <String>{};
    return [
      for (final t in [...office, ...botOwn, ...team, ...appTools])
        if (!exclude.contains(nameOf(t)) && (allowed?.call(nameOf(t)) ?? true) && seen.add(nameOf(t))) t,
    ];
  }

  /// The browser subagent's tools (a whole job it runs itself, on Telesia's model). See [of].
  static const _browserTaskTools = {
    'browser_task',
    'browser_task_reply',
    'browser_task_wait',
    'browser_task_status',
    'browser_task_stop',
  };

  /// The owner's own memory tools. A bot never writes to the owner's memory (known issue 2026-11-06: a bot's
  /// `remember` landed in the main memory): they are not in a bot's list, and a bot's call to one acts on the bot's
  /// own memory instead ([botMemory]).
  static const ownerMemory = {'remember', 'forget', 'list_memories'};

  /// A bot's call to one of [ownerMemory] as the call on its own memory (bot_remember), or null for any other tool.
  static (String, Map<String, dynamic>)? botMemory(String name, Map<String, dynamic> args) {
    String v(List<String> ks) => ks.map((k) => '${args[k] ?? ''}'.trim()).firstWhere((x) => x.isNotEmpty, orElse: () => '');
    switch (name) {
      case 'remember':
        return ('bot_remember', {'fact': v(['fact', 'text', 'memory'])});
      case 'forget':
        return ('bot_remember', {'forget': v(['match', 'query', 'fact', 'text'])});
      case 'list_memories':
        return ('bot_remember', {'list': true});
    }
    return null;
  }
}

/// What an opencode run hands back when it ends (the old runner's end-of-task step, dropped with it on 2026-11-02).
class OcRunEnd {
  OcRunEnd._();

  /// The reply a background task's callback gets: the newest written row of this run that is a reply (not a thinking
  /// row, not a step), or '' when the run wrote none. Only this run's rows ([wrote]), so a wake that wrote nothing
  /// never hands back an older reply from the same chat.
  static String replyOf(List<ChatMessage> list, Set<String> wrote) {
    for (final m in list.reversed) {
      if (!wrote.contains(m.id) || m.role != 'assistant' || m.name == 'reasoning') continue;
      if (m.toolCalls?.isNotEmpty ?? false) continue;
      if (m.content.trim().isNotEmpty) return m.content.trim();
    }
    return '';
  }
}
