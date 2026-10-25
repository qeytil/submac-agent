// Which tools each chat, bot and live call gets; recall.
// Split out of app_state.dart (no behaviour change). Fields stay on AppState.
part of '../app_state.dart';

extension AppStateToolCatalog on AppState {
  /// All tools offered to the model for a normal (non-side) reply.
  List<Map<String, dynamic>> _toolList() => [
        // Looking things up works even when "Let it take action" is off.
        ...WebTools.definitions,
        ...SkillLibrary.definitions,
        ...LifeTools.definitions,
        ...CalcTools.definitions,
        ...BizTools.definitions,
        ...HealthTools.definitions,
        ...CodeTools.definitions,
        ...MediaCoder.definitions,
        // The user's own AI models (their base URL + key, called from the phone).
        ...AiModels.definitions,
        AppState.sayTool,
        AppState.todoTool,
        if (memoryEnabled) ...MemoryStore.definitions,
        SystemTools.settingsTool,
        if (agentEnabled) ...[
          // The browser is driven by its own subagent; the chat agent manages it. Early, so caps never drop it.
          ...BrowserJobs.definitions,
          for (final d in SystemTools.definitions())
            if ((d['function'] as Map)['name'] != 'app_settings') d,
          ...AgentTools.definitions,
          ...PhoneTools.definitions,
          WhatsAppTools.definition,
          ...DocTools.definitions,
          ...DocMaker.definitions,
          ...ConnectorCatalog.definitions(),
          // CB-42: with no mail account connected, an email to send is a draft card with a Send button (mail app).
          if (ConnectorCatalog.connectedEmails().isEmpty) OutboundGuard.draftToolDef,
          ConnectorCatalog.apiCallTool,
          ...SetupTools.definitions,
          AppState.askUserTool,
          AppState.connectAppTool,
          AppState.sitesTool,
          AppState.projectsTool,
          ..._mcpToolDefs(),
          if (hasImageModel) AgentTools.imageTool,
        ],
      ];

  /// The audio cookbook rides along with code_media only when the chat is about sound (saves tokens on every other step).
  List<Map<String, dynamic>> _toolsFor(String convId) {
    var list = _toolsForRaw(convId);
    final recent = (_lists[convId] ?? const <ChatMessage>[]).reversed.where((m) => m.role == 'user').take(4);
    // The WhatsApp know-how rides along only when the chat is about WhatsApp (saves tokens on every other step).
    if (_waTalk(convId)) {
      list = [
        for (final t in list)
          if ('${(t['function'] as Map?)?['name']}' == WhatsAppTools.tool) WhatsAppTools.withGuide else t,
      ];
    }
    if (!recent.any((m) => AppState._soundHint.hasMatch(m.content))) return list;
    return [
      for (final t in list)
        if ('${(t['function'] as Map?)?['name']}' == 'code_media') MediaCoder.withAudioGuide.first else t,
    ];
  }

  bool _waTalk(String convId) => (_lists[convId] ?? const <ChatMessage>[])
      .reversed
      .where((m) => m.role == 'user')
      .take(4)
      .any((m) => WhatsAppTools.hint.hasMatch(m.content));

  List<Map<String, dynamic>> _toolsForRaw(String convId) {
    final b = Bots.I.byConv(convId);
    if (b == null) return _toolList();
    final all = BotPowers.filter([if (_officeCtx.containsKey(convId)) ...Offices.definitions, ...Bots.I.definitionsFor(b), ..._toolList()], b.effectiveOff);
    if (!b.appsScoped) return all;
    return [
      for (final t in all)
        if (_botAppOk(b, '${(t['function'] as Map?)?['name']}', const {})) t,
    ];
  }

  /// The bot's own MCP entry for this server, or null when it is not one of its apps.
  BotApp? _botMcp(Bot b, McpServerConfig s) =>
      b.apps.where((a) => a.kind == 'mcp' && AppState._normUrl(a.ref) == AppState._normUrl(s.url)).firstOrNull;

  bool _botToolOk(Bot b, McpTool t) {
    if (!b.appsScoped) return true;
    final a = _botMcp(b, t.server);
    return a != null && (a.tools.isEmpty || a.tools.contains(t.name));
  }

  /// Bots set up with their own apps reach only those (each with the owner's own login). Everything that is not an
  /// app tool (web, files, memory, its desk...) is always allowed here; powers decide those.
  bool _botAppOk(Bot b, String name, Map<String, dynamic> args) {
    if (!b.appsScoped) return true;
    if (name.startsWith('mcp_')) {
      final t = mcpTools.where((e) => e.fnName == name).firstOrNull;
      return t != null && _botToolOk(b, t);
    }
    if (name == 'apps_list_tools') return b.apps.any((a) => a.kind == 'mcp');
    if (name == 'apps_run_tool') {
      if (args.isEmpty) return b.apps.any((a) => a.kind == 'mcp');
      final t = _findMcpTool('${args['tool'] ?? ''}', '${args['app'] ?? ''}', bot: b);
      return t != null;
    }
    final conns = {for (final a in b.apps) if (a.kind == 'connector') a.ref};
    if (ConnectorCatalog.emailTools.contains(name)) return conns.any((c) => ConnectorCatalog.byId(c)?.kind == 'email');
    if (name == 'api_call') {
      final c = '${args['connector'] ?? ''}'.trim();
      return c.isEmpty || conns.contains(c);
    }
    if (name.startsWith('app_') && !name.startsWith('apps_')) {
      return conns.any((c) => ConnectorCatalog.toolName(c) == name);
    }
    return true;
  }

  /// Is this app connected for the owner (their own key or sign-in)?
  bool botAppConnected(BotApp a) {
    if (a.kind == 'connector') return ConnectorCatalog.connected.containsKey(a.ref);
    return mcpServers.any((s) => s.enabled && AppState._normUrl(s.url) == AppState._normUrl(a.ref));
  }

  /// How an MCP server the owner has is connected, for a bot's app entry (never the key itself).
  BotApp botAppFromServer(McpServerConfig s) {
    final key = s.headers.keys.where((k) => k.isNotEmpty).firstOrNull ?? '';
    return BotApp(
      kind: 'mcp',
      ref: s.url,
      name: s.name,
      auth: s.oauth.isNotEmpty ? 'oauth' : (key.isNotEmpty ? 'key' : 'none'),
      keyHeader: s.oauth.isNotEmpty ? '' : key,
    );
  }

  /// One-tap connect of an MCP app a bot came with, using the owner's own key (for key-based servers).
  Future<String?> connectBotMcpWithKey(BotApp a, String key) async {
    final k = key.trim();
    if (k.isEmpty) return 'Add the key first.';
    final header = a.keyHeader.isEmpty ? 'Authorization' : a.keyHeader;
    final value = header.toLowerCase() == 'authorization' && !RegExp(r'^(bearer|basic)\s', caseSensitive: false).hasMatch(k) ? 'Bearer $k' : k;
    final existing = mcpServers.where((s) => AppState._normUrl(s.url) == AppState._normUrl(a.ref)).firstOrNull;
    final s = existing ?? McpServerConfig(id: _uuid.v4(), name: a.name, url: a.ref);
    s.headers[header] = value;
    s.enabled = true;
    await upsertMcpServer(s);
    return null;
  }

  /// One-tap connect of an MCP app a bot came with: sign in (or open straight away when it needs nothing).
  Future<String?> connectBotMcp(BotApp a) =>
      connectMcpUrl(a.ref, name: a.name, signIn: a.auth == 'oauth' ? true : (a.auth == 'none' ? false : null));

  /// A model name from a bot package mapped to one of the owner's providers that offers it ('auto' when none does).
  String resolveModelHint(String hint) => 'auto';

  /// Finds lines matching [query] in facts, the bot's memory and journal, and loaded chats. Local and free.
  String recall(String query, {String? botId}) {
    final words = query.toLowerCase().split(RegExp(r'[^\p{L}\p{N}]+', unicode: true)).where((w) => w.length > 2).toSet();
    if (words.isEmpty) return 'Give a few key words to look for.';
    int score(String t) {
      final l = t.toLowerCase();
      return words.where(l.contains).length;
    }
    final hits = <(int, String)>[];
    void add(String where, String text) {
      final t = text.trim();
      if (t.isEmpty) return;
      final s = score(t);
      if (s > 0) hits.add((s, '[$where] ${AppState._clip(t, 240)}'));
    }
    for (final f in memory.facts) {
      add('fact', f.fact);
    }
    final b = botId == null ? null : Bots.I.byId(botId);
    if (b != null) {
      for (final m in b.memory) {
        add('your memory', m);
      }
      for (final j in b.journal) {
        add('journal', j.text);
      }
    }
    for (final c in conversations.take(60)) {
      final list = _lists[c.id];
      if (score(c.title) > 0) hits.add((score(c.title), '[chat title] ${c.title}'));
      if (list == null) continue;
      final cut = _compactCut(list);
      if (cut != null) add('summary of "${AppState._clip(c.title, 40)}"', cut.$1);
      for (final m in list.reversed.take(200)) {
        if ((m.role == 'user' || m.role == 'assistant') && !m.content.startsWith(botWakeMark)) {
          add('chat "${AppState._clip(c.title, 40)}"', m.content);
        }
      }
    }
    if (hits.isEmpty) return 'Nothing found for "$query". Ask the user.';
    hits.sort((a, b) => b.$1.compareTo(a.$1));
    final seen = <String>{};
    final out = <String>[];
    for (final h in hits) {
      if (seen.add(h.$2)) out.add(h.$2);
      if (out.length >= 8) break;
    }
    return out.join('\n');
  }

  /// Tools for Live voice: everything chat has. Browser steps run through live_task (the full agent drives them).
  List<Map<String, dynamic>> liveTools() => [
        // Task tools first so the 120-tool Live limit never drops them.
        if (agentEnabled) ...AppState.liveTaskTools,
        AppState.recallTool,
        if (liveCtl.botId != null) ...Bots.I.definitionsFor(Bots.I.byId(liveCtl.botId!)),
        for (final d in _toolList())
          if (!AppState._liveSkip('${(d['function'] as Map)['name']}')) d,
      ];
}
