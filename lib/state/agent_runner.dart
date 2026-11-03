// The chat's agent: opencode, on the phone (owner, 2026-11-02: "delete the old agent ... just use opencode and our
// chat ui, not our submac instructions and system prompt and output style; we customize the behaviour later").
//
// SubMac's own step loop, system prompt, reply format and guards are gone. A chat message goes to the chat's opencode
// session as it is; opencode answers with its own prompts and tools, and the reply is shown in SubMac's chat:
// text parts become SubMac's reply, tool parts become steps (a tool call and its result).
part of '../app_state.dart';

extension AppStateAgentRunner on AppState {
  // Lives as long as the app: one listener for every chat.
  // ignore: cancel_subscriptions
  static StreamSubscription<Map<String, dynamic>>? _ocAskSub;

  /// Which chat (or team member) an MCP call belongs to, matched on the tool and its arguments (see McpRoutes).
  static final McpRoutes _routes = McpRoutes();

  /// One driver of the phone's screen at a time among chats, bots and team members.
  static final ScreenLease screen = ScreenLease();

  /// Chats whose bot is working in a team turn right now (no chat run of their own), with that turn's stop check, so
  /// its browser jobs live as long as the turn does.
  static final Map<String, bool Function()> teamLive = {};

  /// The opencode turns running now, by route key (a chat id, or `team:<team>:<bot>` for a team member's part). A
  /// SubMac call with no matching part goes to the only one running, never to the chat on screen (bots leak audit,
  /// 2026-11-03: a bot's call used to act on whatever chat was open).
  static final Set<String> _ocLive = {};

  /// Child session -> parent session (opencode's `task` tool runs subagents in child sessions), so a subagent's
  /// approval card shows in the chat that started it.
  static final Map<String, String> _ocParent = {};

  /// The lead of a team job hands parts to members with team_assign: its handler, by the lead's route key.
  static final Map<String, Future<String> Function(String member, String ask)> _teamAssign = {};

  /// SubMac's tools offered to opencode through SubMac's MCP server. Layer 1 (owner, 2026-11-02): memory and the
  /// everyday helpers; the browser, the phone and Live come in the next layers. Each call runs through SubMac's own
  /// gate, so a risky one shows SubMac's approval card first.
  List<Map<String, dynamic>> _ocAppTools() => [
        if (memoryEnabled) ...MemoryStore.definitions,
        ...LifeTools.definitions,
        // The app, its outputs, apps and connectors (owner, 2026-11-02).
        SystemTools.settingsTool,
        // Layer 2 and 3 (owner, 2026-11-03): the browser agent for websites, and control of the phone and its apps.
        // Behind "Let it take action", as in the old chat.
        if (agentEnabled) ...[
          ...BrowserJobs.definitions,
          for (final d in SystemTools.definitions())
            if ((d['function'] as Map)['name'] != 'app_settings') d,
          ...PhoneTools.definitions,
          WhatsAppTools.definition,
        ],
        AppState.projectsTool,
        AppState.sitesTool,
        ...DocTools.definitions,
        ...DocMaker.definitions,
        ...MediaCoder.definitions,
        if (hasImageModel) AgentTools.imageTool,
        AppState.connectAppTool,
        ...ConnectorCatalog.definitions(),
        ConnectorCatalog.apiCallTool,
        // Every app tool: find_tools searches them, so none is out of reach (2026-11-03: Canva's generate-image and
        // Composio's execute tool were cut by the 8-tool cap the old chat used).
        ..._mcpToolDefs(all: true),
        AppState.addMcpServerTool,
      ];

  /// The SubMac tools the turn [conv] may find and run (bots leak audit, 2026-11-03; see OcToolScope). The owner's
  /// chat: the app's tools only (bot and team tools are no longer offered to the main agent). A bot's chat: its own
  /// tools (bot_make only for the Chief), the office tools while it does office work, team_task, and the app's tools,
  /// cut by the powers the owner switched off for it. A team member's part (`team:<team>:<bot>`): its own tools,
  /// team_assign and team_task, and the app's tools, cut the same way.
  List<Map<String, dynamic>> _mcpTools([String? conv]) {
    final teamKey = conv != null && conv.startsWith('team:');
    final b = teamKey ? Bots.I.byId(conv.split(':').last) : Bots.I.byConv(conv);
    if (b == null) return OcToolScope.of(app: _ocAppTools());
    return OcToolScope.of(
      app: _ocAppTools(),
      botOwn: Bots.I.definitionsFor(b),
      office: !teamKey && _officeCtx.containsKey(conv) ? Offices.definitions : const [],
      team: [if (teamKey) TeamRun.assignTool, TeamRun.taskTool],
      allowed: (n) => BotPowers.allowed(b.effectiveOff, n) && (!b.appsScoped || _botAppOk(b, n, const {})),
    );
  }

  /// The only text added to opencode's own prompt: the name SubMac (owner, 2026-11-03). A bot's chat gets the bot's
  /// own brief instead (who it is, what it knows and owns, its tools).
  String _ocLayer([String? convId]) {
    final b = Bots.I.byConv(convId);
    return b == null ? SubMacStyle.identity : Bots.I.opencodeBriefOf(b);
  }

  /// Starts opencode in the background at launch (after sign-in), so the first message does not wait for the engine.
  /// Once the connected apps' tools have loaded, opencode is given the fresh list. Failures stay quiet: the first
  /// message starts the engine again and shows any error there.
  Future<void> warmAgent() async {
    try {
      final oc = OpenCodeEngine.I;
      _ocWire(oc);
      await oc.ensure();
      await ensureMcpTools().catchError((Object _) {});
      await oc.syncMcp();
    } catch (e) {
      debugPrint('opencode warm start: $e');
    }
  }

  /// Gives the engine SubMac's MCP server, and turns opencode's permission and question requests into the ask card.
  void _ocWire(OpenCodeEngine oc) {
    // Two MCP tools only (find, run); the full SubMac set is looked up when a task needs it (SubMacGateway).
    // Bots leak audit (2026-11-03): the caller is found first, for find_tools as well as run_tool, so each turn finds
    // and runs only its own tools (see _mcpTools), and a call with no route goes to the only turn running or is
    // refused; it no longer runs as the chat on screen (a bot's bot_remember used to land on the open bot's chat, and
    // its approval card in the owner's chat).
    oc.mcp ??= SubMacMcp(
      tools: () => SubMacGateway.definitions,
      call: (name, args) async {
        final (rn, ra) = name == SubMacGateway.runName ? SubMacGateway.inner(args) : (name, args);
        final conv = await _routes.take(rn, ra) ?? McpRoutes.soleLive(_ocLive);
        final gate = SubMacGateway(
          tools: () => _mcpTools(conv),
          run: (n, a) async {
            if (conv == null) {
              return 'Error: SubMac could not tell which chat this call came from (several are working). Call it once more.';
            }
            if (n == 'add_mcp_server') return addMcpServerFromChat(a);
            return _runRouted(n, a, conv);
          },
        );
        return gate.call(name, args);
      },
    );
    if (_ocAskSub != null) return;
    final asks = OpenCodeAsks(
      ask: (conv, title, prompt, options) async {
        // A request from a session of no SubMac chat is refused (Deny / skipped): it used to show in whatever chat
        // was open, so a bot's or team member's "Run this command?" landed in the owner's chat (2026-11-03).
        if (conv.isEmpty) return null;
        final r = await askUser(UserAsk(kind: 'text', convId: conv, title: title, prompt: prompt, options: options));
        return r?['answer'];
      },
      permit: oc.replyPermission,
      answer: oc.replyQuestion,
      // A subagent's session asks in the chat of the turn that started it.
      convOf: (s) => McpRoutes.rootConv(s, oc.convOf, _ocParent),
      autopilot: () => FullAccess.I.on,
    );
    _ocAskSub = oc.events.listen((e) {
      final props = e['properties'];
      if ((e['type'] == 'session.created' || e['type'] == 'session.updated') && props is Map) {
        final info = props['info'];
        if (info is Map && info['parentID'] != null && info['id'] != null) _ocParent['${info['id']}'] = '${info['parentID']}';
      }
      unawaited(asks.handle(e).catchError((Object _) => false));
    });
  }

  /// Runs one opencode turn for the newest user message of [convId]. [side] and [chain] are kept for the callers
  /// (bots, calls): opencode queues a message sent while a reply is still being written, so both run the same way.
  Future<void> _runAgent(String convId, {bool side = false, int chain = 0}) async {
    final list = _lists[convId] ?? messages;
    _lists[convId] = list;
    ChatMessage? lastUser;
    for (final m in list.reversed) {
      if (m.role == 'user') {
        lastUser = m;
        break;
      }
    }
    // One run per chat at a time; a message sent meanwhile is picked up when it ends (see the end of this method).
    if (runs.any((r) => r.convId == convId)) return;
    final run = AgentRun(convId: convId, side: false, title: _shortTitle(lastUser?.content ?? 'Task'));
    runs.add(run);
    // A bot's wake keeps the rows it writes, so a wake that ends silent removes only those (CB-17).
    if (_botWakeConvs.containsKey(convId)) _wakeRows[convId] = run.wrote;
    _notify();
    final testRun = AppState.debugRunAgent;
    if (testRun != null) {
      try {
        await testRun(this, run);
      } finally {
        runs.remove(run);
        if (!run.finished.isCompleted) run.finished.complete();
        _notify();
      }
      return;
    }
    String? sentId;
    try {
      if (lastUser == null) return;
      sentId = lastUser.id;
      run.show(RunPhase.starting, RunStatus.starting);
      _notify();
      final oc = OpenCodeEngine.I;
      _ocWire(oc);
      await oc.ensure();
      final session = await oc.sessionFor(convId, title: run.title);
      run.onStop = () => unawaited(oc.abort(session));
      if (run.cancelled) return;
      final turn = OpenCodeTurn(session);
      final shown = <String, ChatMessage>{}; // part id -> the chat row showing it
      final saved = <String>{};
      final done = Completer<void>();
      Future<void> save(ChatMessage m) async {
        if (!saved.add(m.id)) return;
        await _save(convId, m);
      }

      void sync() {
        for (final p in turn.parts.values) {
          if (p.kind == 'text' || p.kind == 'reasoning') {
            var m = shown[p.id];
            if (m == null) {
              if (p.text.trim().isEmpty) continue;
              // Thinking is its own row (name 'reasoning'), drawn as opencode desktop draws it.
              m = ChatMessage(id: _uuid.v4(), role: 'assistant', streaming: true, name: p.kind == 'reasoning' ? 'reasoning' : null)
                ..animateIn = true;
              shown[p.id] = m;
              list.add(m);
              run.wrote.add(m.id);
            }
            m.content = p.text;
            if (p.kind == 'reasoning' && p.finished) m.streaming = false;
          } else {
            // SubMac's own tools come back from opencode as submac_<name>: shown under their own name.
            var tool = p.tool.startsWith('submac_') ? p.tool.substring(7) : p.tool;
            var input = p.input;
            // A SubMac tool run through the gateway shows (and routes) as the tool itself.
            if (tool != p.tool && tool == SubMacGateway.runName) {
              final (n, a) = SubMacGateway.inner(p.input);
              if (n.isNotEmpty) {
                tool = n;
                input = a;
              }
            }
            var m = shown[p.id];
            if (m == null) {
              m = ChatMessage(
                id: _uuid.v4(),
                role: 'assistant',
                toolCalls: [ToolCall(id: p.callId, name: tool, arguments: jsonEncode(input))],
              );
              shown[p.id] = m;
              list.add(m);
              run.wrote.add(m.id);
              run.trail.add(RunStep(p.title ?? stepLabel(tool, input)));
            } else {
              m.toolCalls = [ToolCall(id: p.callId, name: tool, arguments: jsonEncode(input))];
            }
            if (p.finished && !shown.containsKey('${p.id}:out')) {
              final out = ChatMessage(
                  id: _uuid.v4(), role: 'tool', toolCallId: p.callId, name: tool, content: _clip(p.output ?? ''));
              shown['${p.id}:out'] = out;
              list.add(out);
              run.wrote.add(out.id);
              if (run.trail.isNotEmpty) {
                run.trail.last.ended = DateTime.now();
                run.trail.last.failed = p.status == 'error';
              }
              unawaited(save(m).then((_) => save(out)));
            }
          }
        }
        // The live line: what opencode is doing now.
        final last = turn.parts.values.isEmpty ? null : turn.parts.values.last;
        if (turn.retry != null && turn.retry!.isNotEmpty) {
          run.show(RunPhase.retrying, turn.retry!);
        } else if (last != null && last.kind == 'tool' && !last.finished) {
          run.show(RunPhase.tool, last.title ?? stepLabel(last.tool.replaceFirst('submac_', ''), last.input));
        } else if (turn.reasoning) {
          run.show(RunPhase.thinking, RunStatus.thinking);
        } else if (last != null && last.kind == 'text') {
          run.show(RunPhase.writing, RunStatus.writing);
        }
        _notify();
      }

      // This turn's session and the subagent sessions opencode starts under it: their SubMac calls route here.
      final family = {session};
      _ocLive.add(convId);
      final sub = oc.events.listen((e) {
        _routes.watch(e, convId, family);
        if (turn.apply(e)) sync();
        if ((turn.done || turn.error != null) && !done.isCompleted) done.complete();
      });
      try {
        run.show(RunPhase.waiting, RunStatus.waiting);
        _notify();
        // SubMac's tools may have changed since opencode listed them (an app connected, its tools loaded).
        await ensureMcpTools().catchError((Object _) {});
        await oc.syncMcp().catchError((Object _) {});
        await oc.prompt(session, await _partsFor(lastUser), system: _ocLayer(convId));
        while (!done.isCompleted && !run.cancelled) {
          await Future.any([done.future, Future<void>.delayed(const Duration(seconds: 1))]);
        }
      } finally {
        await sub.cancel();
        _ocLive.remove(convId);
        // A bot's opencode work counts toward its own daily budget.
        final bot = Bots.I.byConv(convId);
        if (bot != null && turn.tokens > 0) {
          bot.addTokens(turn.tokens);
          unawaited(Bots.I.save());
        }
      }
      for (final m in shown.values) {
        m.streaming = false;
        if (m.role == 'assistant' && m.content.trim().isEmpty && (m.toolCalls?.isEmpty ?? true)) {
          list.remove(m);
          continue;
        }
        if (run.cancelled && m.role == 'assistant' && m.toolCalls == null) m.stopped = true;
      }
      for (final m in list.where((m) => shown.containsValue(m)).toList()) {
        await save(m);
      }
      if (turn.error != null && !run.cancelled) {
        final err = ChatMessage(id: _uuid.v4(), role: 'assistant', error: turn.error)..animateIn = true;
        list.add(err);
        run.wrote.add(err.id);
      }
    } catch (e) {
      if (!run.cancelled) {
        run.show(RunPhase.failed, RunStatus.failed);
        final err = ChatMessage(id: _uuid.v4(), role: 'assistant', error: '$e')..animateIn = true;
        list.add(err);
        run.wrote.add(err.id);
      }
    } finally {
      screen.release(convId);
      _ocLive.remove(convId);
      runs.remove(run);
      _ocRunEnded(convId, list, run);
      if (!run.finished.isCompleted) run.finished.complete();
      _notify();
    }
    // A message the user sent while this turn ran gets its own turn now.
    if (!run.cancelled && sentId != null && chain < 3) {
      final newest = list.lastWhere((m) => m.role == 'user', orElse: () => list.first);
      if (newest.role == 'user' && newest.id != sentId) unawaited(_runAgent(convId, chain: chain + 1));
    }
  }

  /// Runs a SubMac tool for the chat [conv] its call came from. A team member's part runs under the route key
  /// `team:<team>:<bot>`: its own bot tools act on that bot, and team_assign reaches the lead's job.
  Future<String> _runRouted(String name, Map<String, dynamic> args, String? conv) async {
    if (ScreenLease.drives(name)) {
      final who = conv ?? currentId ?? '';
      final busy = screen.take(who, label: _screenLabel(who));
      if (busy != null) return busy;
    }
    if (conv != null && conv.startsWith('team:')) {
      final bot = Bots.I.byId(conv.split(':').last);
      if (name == TeamRun.assignName) {
        final h = _teamAssign[conv];
        if (h == null) return 'Error: team_assign works only while you lead a team job.';
        return h('${args['member'] ?? ''}', '${args['ask'] ?? ''}');
      }
      if (name == TeamRun.taskName) return _teamTask(bot, args);
      final home = (bot == null || bot.convId.isEmpty) ? null : bot.convId;
      if (Bots.names.contains(name)) {
        if (home == null) return 'Error: ${bot?.name ?? 'this member'} has no chat of its own for that tool.';
        return Bots.I.execute(name, args, home);
      }
      // A member with no chat of its own gets no tools rather than the open chat's (its powers and approval cards
      // used to be the owner's chat's; bots leak audit, 2026-11-03).
      if (home == null) return 'Error: ${bot?.name ?? 'this member'} has no chat of its own, so SubMac tools are off for it.';
      return runToolWithApproval(name, args, convId: home);
    }
    if (name == TeamRun.assignName) return 'Error: team_assign works only while you lead a team job.';
    if (name == TeamRun.taskName) return _teamTask(Bots.I.byConv(conv), args);
    return runToolWithApproval(name, args, convId: conv ?? currentId);
  }

  String _screenLabel(String who) {
    if (who.startsWith('team:')) return Bots.I.byId(who.split(':').last)?.name ?? 'a team member';
    return Bots.I.byConv(who)?.name ?? 'SubMac';
  }

  /// team_task: a team's lead gives its team a job (from a routine, a follow-up, or the owner asking in its chat).
  Future<String> _teamTask(Bot? lead, Map<String, dynamic> args) async {
    if (lead == null) return 'Error: team_task works only for a bot that leads a team.';
    final name = '${args['team'] ?? ''}'.trim().toLowerCase();
    final task = '${args['task'] ?? ''}'.trim();
    if (task.isEmpty) return 'Error: give the task.';
    final led = Offices.I.offices.where((o) => o.chiefId == lead.id).toList();
    final o = led.where((o) => o.name.toLowerCase() == name).firstOrNull ?? (led.length == 1 && name.isEmpty ? led.first : null);
    if (o == null) {
      return led.isEmpty
          ? 'Error: ${lead.name} leads no team.'
          : 'Error: no team named "$name". Teams ${lead.name} leads: ${led.map((o) => o.name).join(', ')}.';
    }
    return TeamRun.I.startJob(o, task);
  }

  /// One opencode turn for a team member or lead, in a fresh session that is deleted afterwards (nothing piles up,
  /// and no member sees another's session). [key] routes its SubMac tool calls (`team:<team>:<bot>`); [assign] is the
  /// lead's hand-off. Returns the answer text; throws when the turn failed.
  Future<String> teamTurn(Bot b, String key, String system, String task,
      {bool Function()? stopped, Future<String> Function(String member, String ask)? assign, int maxSteps = 40}) async {
    final oc = OpenCodeEngine.I;
    _ocWire(oc);
    await oc.ensure();
    await ensureMcpTools().catchError((Object _) {});
    await oc.syncMcp().catchError((Object _) {});
    // Its permission and question cards show in the member's own chat, or the team's chat when it has none: never the
    // chat that happens to be open (it used to fall back to currentId, the owner's chat; 2026-11-03).
    final session = await oc.newSession(title: '${b.name}: ${_shortTitle(task)}', conv: b.convId.isEmpty ? await _teamConv() : b.convId);
    final turn = OpenCodeTurn(session);
    if (assign != null) _teamAssign[key] = assign;
    final home = b.convId;
    var over = false;
    bool live() => over || (stopped?.call() ?? false);
    if (home.isNotEmpty) teamLive[home] = live;
    final family = {session};
    _ocLive.add(key);
    final sub = oc.events.listen((e) {
      _routes.watch(e, key, family);
      turn.apply(e);
    });
    var aborted = false;
    try {
      await oc.prompt(session, [{'type': 'text', 'text': task}], system: system);
      final from = DateTime.now();
      final until = from.add(const Duration(minutes: 30));
      while (true) {
        if (turn.error != null) break;
        // Idle with nothing written in the first seconds may be the state before the prompt started: keep waiting.
        if (turn.done && (turn.parts.isNotEmpty || DateTime.now().difference(from) > const Duration(seconds: 8))) break;
        if (stopped?.call() ?? false) {
          aborted = true;
          await oc.abort(session);
          break;
        }
        // The step cap: a member that keeps going stops here and keeps what it wrote so far.
        if (turn.parts.values.where((p) => p.kind == 'tool').length > maxSteps) {
          await oc.abort(session);
          break;
        }
        if (DateTime.now().isAfter(until)) {
          await oc.abort(session);
          throw OpenCodeError('${b.name} ran out of time (30 min).');
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    } finally {
      over = true;
      _ocLive.remove(key);
      screen.release(key);
      await sub.cancel();
      if (home.isNotEmpty && identical(teamLive[home], live)) teamLive.remove(home);
      if (assign != null && identical(_teamAssign[key], assign)) _teamAssign.remove(key);
      if (turn.tokens > 0) {
        b.addTokens(turn.tokens);
        unawaited(Bots.I.save());
      }
      unawaited(oc.dropSession(session));
    }
    if (aborted) return '';
    if (turn.error != null && turn.answer.isEmpty) throw OpenCodeError(turn.error!);
    return turn.answer;
  }

  /// The user's message as opencode parts: its words, then each attachment (a file on the phone as a file part, a
  /// text pulled from a PDF as text).
  Future<List<Map<String, dynamic>>> _partsFor(ChatMessage m) async {
    final ws = await AgentTools.workspaceDir();
    final parts = <Map<String, dynamic>>[];
    if (m.content.trim().isNotEmpty) parts.add({'type': 'text', 'text': m.content});
    for (final a in m.attachments) {
      final local = a.localPath;
      if (local != null && local.isNotEmpty) {
        final abs = local.startsWith('/') ? local : '$ws/$local';
        parts.add({'type': 'file', 'mime': a.mime, 'filename': a.name, 'url': Uri.file(abs).toString()});
      } else if (a.bytes != null) {
        parts.add({
          'type': 'file',
          'mime': a.mime,
          'filename': a.name,
          'url': 'data:${a.mime};base64,${base64Encode(a.bytes!)}',
        });
      } else if (a.extractedText != null) {
        parts.add({'type': 'text', 'text': '${a.name}:\n${a.extractedText}'});
      }
    }
    if (parts.isEmpty) parts.add({'type': 'text', 'text': m.content});
    return parts;
  }

  /// A run ended: what the old runner's end-of-task step did for background work (it went with the old runner on
  /// 2026-11-02 and nothing replaced it). Without it a bot's wake never got its outcome (no @note/@message/@call, a
  /// silent check-in's rows stayed), its wake mark stayed set so every later wake of that bot was put off for good
  /// ("busy", come back in 15 minutes), an office job waited on a reply that never came, and the "working" notice
  /// stayed on (bots leak audit, 2026-11-03).
  void _ocRunEnded(String convId, List<ChatMessage> list, AgentRun run) {
    _scheduledConvs.remove(convId);
    _notifyConvs.remove(convId);
    if (!runs.any((r) => !r.side) && !(TelegramBridge.I.on && TelegramBridge.I.paired && !appVisible)) {
      unawaited(SystemBridge.I.keepAlive(false));
    }
    final done = _doneCbs.remove(convId);
    _botWakeConvs.remove(convId);
    if (done == null || run.cancelled) return;
    final reply = OcRunEnd.replyOf(list, run.wrote);
    if (!Bots.I.isBotConv(convId) && (reply == 'NO_CHANGE' || (reply.contains('NO_CHANGE') && reply.length < 40))) {
      // A watcher found nothing new: stay quiet and leave no clutter behind (as before).
      unawaited(deleteConversation(convId));
      return;
    }
    done(reply);
  }

  String _clip(String s) => s.length <= 8000 ? s : '${s.substring(0, 8000)}\n…';

  /// Runs killed with the app used to resume on the next start; opencode keeps its own sessions, so nothing to do.
  Future<void> resumeKilledRuns() async {}
}
