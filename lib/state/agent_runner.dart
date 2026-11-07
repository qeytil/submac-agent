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

  /// Team work running right now, by its route key ([TeamKey]: never the bot's private chat id), with that turn's stop
  /// check, so its browser jobs live as long as the turn does.
  static final Map<String, bool Function()> teamLive = {};

  /// The sessions of every opencode turn running now, by route key: the turn's own session and the subagent sessions
  /// opencode starts under it. A SubMac call from a session in none of them comes from no running turn (see
  /// McpRoutes.watchOrphans) and is refused, never run as another chat.
  static final Map<String, Set<String>> _ocFamilies = {};
  static bool _ocOwned(String session) => _ocFamilies.values.any((f) => f.contains(session));

  /// The office job each piece of office work is doing, by its route key (reply | task | review | chief | digest |
  /// unblock | mention), for the mention rule in office_post.
  static final Map<String, String> ocOfficeJob = {};

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
        // Always findable (owner 2026-11-04, visuals): with no picture model on the server it says so and names the
        // ways that work (an .svg/.html file, code_media, the user's own model).
        AgentTools.imageTool,
        // The user's own AI models (their base URL + key), as the old chat had them: pictures, video, speech.
        ...AiModels.definitions,
        // The user's media providers (Settings > Media models): media_generate, only while one is set up. Found with
        // find_tools like every app tool, never in the per-message listing (owner 2026-11-04).
        ...MediaGen.definitions(MediaProviderStore.I),
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
    final teamKey = TeamKey.isKey(conv);
    final b = Bots.I.byConv(conv);
    if (b == null) return OcToolScope.of(app: _ocAppTools());
    return OcToolScope.of(
      app: _ocAppTools(),
      botOwn: Bots.I.definitionsFor(b),
      // Office tools only for office work, which runs under its own team key (never in the bot's private chat).
      office: teamKey && _officeCtx.containsKey(conv) ? Offices.definitions : const [],
      team: [if (teamKey && _teamAssign.containsKey(conv)) TeamRun.assignTool, TeamRun.taskTool],
      allowed: (n) => BotPowers.allowed(b.effectiveOff, n) && (!b.appsScoped || _botAppOk(b, n, const {})),
      // A bot never writes the owner's memory: its `remember` is its own bot_remember (known issue, 2026-11-06).
      exclude: OcToolScope.ownerMemory,
    );
  }

  /// The only text added to opencode's own prompt: the name SubMac (owner, 2026-11-03). A bot's chat gets the bot's
  /// own brief instead (who it is, what it knows and owns, its tools).
  String _ocLayer([String? convId]) {
    final b = Bots.I.byConv(convId);
    // The bot's private chat: its brief without its team work (that stays in the team chat).
    return b == null ? SubMacStyle.identity : Bots.I.opencodeBriefOf(b);
  }

  /// A run nobody is watching could not do something without the owner's OK: one notification says what, and the
  /// bot's journal keeps it (BgRun, 2026-11-05).
  Future<void> _bgNeeds(String convId, String what) async {
    final bot = Bots.I.byConv(convId);
    final text = BgRun.needs(what);
    if (bot != null) {
      bot.log('note', text);
      unawaited(Bots.I.save());
    }
    try {
      await SystemBridge.I.notify(
          id: 9800 + (convId.hashCode % 90).abs(),
          title: bot?.name ?? 'SubMac',
          body: text,
          payload: bot != null ? 'botchat/${bot.id}' : 'conv/$convId',
          kind: 'attention');
    } catch (_) {}
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
      // An owner message the daily allowance blocked runs at launch now the engine is up (owner 2026-11-07).
      unawaited(PendingTurns.I.drain());
    } catch (e) {
      debugPrint('opencode warm start: $e');
    }
  }

  /// Gives the engine SubMac's MCP server, and turns opencode's permission and question requests into the ask card.
  void _ocWire(OpenCodeEngine oc) {
    // An owner message the daily allowance blocked runs again once the allowance is back (PendingTurns, 2026-11-07).
    PendingTurns.I.run = runBlockedTurn;
    // New BYOK settings restart the engine only while no turn runs (owner 2026-11-03).
    oc.busy ??= () => _ocLive.isNotEmpty;
    // Two MCP tools only (find, run); the full SubMac set is looked up when a task needs it (SubMacGateway).
    // Bots leak audit (2026-11-03): the caller is found first, for find_tools as well as run_tool, so each turn finds
    // and runs only its own tools (see _mcpTools), and a call with no route goes to the only turn running or is
    // refused; it no longer runs as the chat on screen (a bot's bot_remember used to land on the open bot's chat, and
    // its approval card in the owner's chat).
    oc.mcp ??= SubMacMcp(
      // find_tools and run_tool, plus generate_image by name while the server can make pictures (SubMacGateway.listing).
      tools: () => SubMacGateway.listing([if (hasImageModel) AgentTools.imageTool]),
      call: (name, args) async {
        final (rn, ra) = name == SubMacGateway.runName ? SubMacGateway.inner(args) : (name, args);
        // Several turns at once (the owner's chat, bots, team members side by side): only an exact match routes.
        // With several turns at once the call's own event can come late (busy event stream): wait longer before
        // giving up, since a call with no route is refused ("could not tell which chat", B 2026-11-06).
        final routed = await _routes.take(rn, ra,
            fuzzy: _ocLive.length <= 1, wait: _ocLive.length > 1 ? const Duration(seconds: 5) : const Duration(milliseconds: 1500));
        // A call from a session no running turn owns is refused (McpRoutes.orphan), never run as the only live turn.
        final conv = routed == McpRoutes.orphan ? null : (routed ?? McpRoutes.soleLive(_ocLive));
        final gate = SubMacGateway(
          tools: () => _mcpTools(conv),
          // A bot's `remember`, `forget`, `list_memories`: run as its own memory (see _runToolAfterChecksInner).
          redirect: (n) => Bots.I.byConv(conv) != null ? OcToolScope.botMemory(n, const {})?.$1 : null,
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
        // Team work asks in the team (its chat and the approvals inbox, with a notification), never in the member's
        // private chat with the owner (bots team audit 2026-11-04).
        if (TeamKey.isKey(conv)) return _teamPermission(conv, title, prompt, options);
        final r = await askUser(UserAsk(kind: 'text', convId: conv, title: title, prompt: prompt, options: options));
        return r?['answer'];
      },
      permit: oc.replyPermission,
      answer: oc.replyQuestion,
      // A subagent's session asks in the chat of the turn that started it.
      convOf: (s) => McpRoutes.rootConv(s, oc.convOf, _ocParent),
      autopilot: () => FullAccess.I.on,
      // A bot's scheduled task with nobody watching (2026-11-05): answered at once by what the owner already
      // allowed (Full access, or the bot works "On its own"); anything else is refused and the owner is told.
      unattended: (conv, perm) {
        if (!unattendedRun(conv)) return null;
        final bot = Bots.I.byConv(conv);
        return perm.isEmpty ? 'reject' : BgRun.permission(perm: perm, fullAccess: FullAccess.I.on, botLevel: bot?.level ?? BotTrust.levelNew);
      },
      refused: (conv, title, detail) => unawaited(_bgNeeds(conv, '$title ${detail.split('\n').first}')),
    );
    _ocAskSub = oc.events.listen((e) {
      // Runs before every turn's own listener: tool calls of sessions no running turn owns are marked, so their
      // SubMac call is refused rather than run as another chat.
      _routes.watchOrphans(e, _ocOwned);
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
    // Team work never runs as a chat turn: it has its own engine turn (_teamTurn), and opencode is reserved for the
    // owner's chat. This is a backstop against the main chat list being borrowed for a team key.
    if (TeamKey.isKey(convId)) return;
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
    // A new turn: the save guard's counts for this chat start again (SaveGuard).
    SaveGuard.I.newTurn(convId);
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
    var engineTurn = false;
    // This turn was the owner's own message and it hit the daily allowance (see the error block below).
    var blockedByAllowance = false;
    try {
      if (lastUser == null) return;
      sentId = lastUser.id;
      run.show(RunPhase.starting, RunStatus.starting);
      _notify();
      // A bot's own turn runs on SubMac's bot engine, never opencode (owner 2026-11-07): opencode is reserved for
      // the SubMac agent (the owner's chat). Everything below is the opencode path and does not apply to bots.
      final turnBot = Bots.I.byConv(convId);
      if (turnBot != null) {
        await _runBotTurn(convId, run, list, turnBot);
        // The same follow-up as the opencode path (a message the owner sent while the bot worked) — queued as a
        // microtask so this turn is out of [runs] first, or the new turn is refused as "already running".
        if (!run.cancelled && sentId != null && chain < 3) {
          final newest = list.lastWhere((m) => m.role == 'user', orElse: () => list.first);
          if (newest.role == 'user' && newest.id != sentId) {
            final nextConv = convId;
            final nextChain = chain + 1;
            scheduleMicrotask(() => unawaited(_runAgent(nextConv, chain: nextChain)));
          }
        }
        return;
      }
      final oc = OpenCodeEngine.I;
      _ocWire(oc);
      await oc.ensure(turn: true);
      engineTurn = true;
      final session = await oc.sessionFor(convId, title: run.title);
      run.onStop = () => unawaited(oc.abort(session));
      if (run.cancelled) return;
      final turn = OpenCodeTurn(session);
      final shown = <String, ChatMessage>{}; // part id -> the chat row showing it
      final saved = <String>{};
      var done = Completer<void>();
      Future<void> save(ChatMessage m) async {
        if (!saved.add(m.id)) return;
        await _save(convId, m);
      }

      void sync() {
        for (final p in turn.parts.values) {
          if (p.kind == 'text' || p.kind == 'reasoning') {
            // The rest of a reply that was cut and continued (owner 2026-11-06): it goes on in the cut reply's row.
            if (p.kind == 'text' && p.continues != null) {
              final root = turn.rootOf(p);
              final rm = shown[root.id];
              if (rm != null) {
                rm.content = turn.chainText(root);
                continue;
              }
            }
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
            m.content = p.kind == 'text' ? turn.chainText(p) : p.text;
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
        // Every streamed word arrives as its own engine event. Rebuilding the whole app on each one made the chat
        // stutter while a reply streamed (and bots' background turns rebuilt the open chat too): batched like the
        // reply's own reveal (bug hunt 2026-11-06). The turn's end still notifies at once.
        _throttledNotify();
      }

      // The allowance lane and model of this turn (owner 2026-11-03, see OcLane): a bot's wake and office work bill
      // to the bots' share (background lane); the owner's own chats, and the owner typing in a bot's chat, stay
      // foreground. A bot's chat runs on the bot's own model setting.
      final laneBot = Bots.I.byConv(convId);
      final bg = _backgroundLane(convId);
      final laneModel = OcLane.pick(background: bg, officeWork: bg && _officeCtx.containsKey(convId), botModel: laneBot?.model);
      // A mission run (owner 2026-11-07) also stops at the mission's own daily token budget, whichever comes first.
      final guard = OcBgGuard(
          background: bg,
          budgetLeft: Missions.minLeft(OcBgGuard.leftOf(laneBot?.tokenBudgetK ?? 0, laneBot?.tokensTodayNow ?? 0),
              bg && laneBot != null ? Missions.I.leftFor('bot', laneBot.id) : null),
          byok: OcLane.isByok(laneModel));
      String? stopped;
      // SubMac's tools may have changed since opencode listed them (an app connected, its tools loaded). Re-listed
      // only while no other turn works (OpenCodeEngine.syncMcp).
      await ensureMcpTools().catchError((Object _) {});
      await oc.syncMcp().catchError((Object _) {});
      // This turn's session and the subagent sessions opencode starts under it: their SubMac calls route here.
      final family = {session};
      _ocLive.add(convId);
      _ocFamilies[convId] = family;
      var seen = DateTime.now();
      final sub = oc.events.listen((e) {
        _routes.watch(e, convId, family);
        if (turn.apply(e)) {
          seen = DateTime.now();
          sync();
        }
        // Background work stops when the bots' share is refused or the bot's own budget runs out (owner 2026-11-03).
        final why = stopped == null ? guard.check(turn) : null;
        if (why != null) {
          stopped = why;
          unawaited(oc.abort(session));
          if (!done.isCompleted) done.complete();
        }
        if ((turn.done || turn.error != null) && !done.isCompleted) done.complete();
      });
      final began = DateTime.now().subtract(const Duration(seconds: 2));
      try {
        run.show(RunPhase.waiting, RunStatus.waiting);
        _notify();
        final layer = _ocLayer(convId);
        await oc.prompt(session, await _partsFor(lastUser), system: layer, model: laneModel);
        while (true) {
          final sent = DateTime.now();
          var drops = oc.streamDrops;
          var checked = sent;
          while (!done.isCompleted && !run.cancelled) {
            await Future.any([done.future, Future<void>.delayed(const Duration(seconds: 1))]);
            if (done.isCompleted || run.cancelled) break;
            // The event stream dropped, or nothing changed for a while: ask the engine itself, so a lost stream or a
            // stopped engine never leaves the chat "Working" forever (bug hunt 2026-11-06).
            final now = DateTime.now();
            if (OcWatch.due(now: now, sent: sent, seen: seen, checked: checked, dropped: oc.streamDrops != drops)) {
              checked = now;
              drops = oc.streamDrops;
              if (await oc.recover(turn, since: began)) {
                sync();
                if (!done.isCompleted) done.complete();
              }
            }
          }
          // The reply stopped because it ran out of room (finish "length"): opencode ends the turn quietly there, so
          // the reply used to stop mid-sentence. It is continued in the same session (owner 2026-11-06).
          if (run.cancelled || stopped != null || !turn.shouldContinue) break;
          turn.beginContinue();
          done = Completer<void>();
          run.show(RunPhase.writing, RunStatus.writing);
          await oc.prompt(session, [{'type': 'text', 'text': ReplyContinuation.prompt}], system: layer, model: laneModel);
        }
      } finally {
        await sub.cancel();
        _ocLive.remove(convId);
        if (identical(_ocFamilies[convId], family)) _ocFamilies.remove(convId);
        _ocBgStopped(stopped, turn, laneBot);
        // The bots' share as the server now counts it, so the next wake knows whether to wait for tomorrow.
        if (bg) unawaited(Cloud.refreshStatus());
        // A bot's opencode work counts toward its own daily budget.
        final bot = Bots.I.byConv(convId);
        if (bot != null && turn.tokens > 0) {
          bot.addTokens(turn.tokens);
          unawaited(Bots.I.save());
          // ...and toward its mission while a mission run goes on.
          if (bg) Missions.I.addTokens('bot', bot.id, turn.tokens);
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
      if (!run.cancelled) await _ocShowVisuals(convId, turn, list, shown, run, began);
      for (final m in list.where((m) => shown.containsValue(m)).toList()) {
        await save(m);
      }
      // Still cut after every continuation: say so under the reply instead of leaving it to look finished.
      if (!run.cancelled && turn.leftCut) {
        final note = ChatMessage(id: _uuid.v4(), role: 'assistant', error: ReplyContinuation.cutNote)..animateIn = true;
        list.add(note);
        run.wrote.add(note.id);
      }
      if (turn.error != null && !run.cancelled) {
        // A BYOK key refused or out of quota: the provider's next key takes over for the next turn (owner 2026-11-03).
        if (OcLane.isByok(laneModel)) {
          final next = await ByokStore.I.rotateAfter(laneModel['providerID']!, turn.error);
          if (next != null) turn.error = '${turn.error}\n\nSwitched to $next for the next message.';
        }
        final err = ChatMessage(id: _uuid.v4(), role: 'assistant', error: turn.error)..animateIn = true;
        list.add(err);
        run.wrote.add(err.id);
        // The owner's own message that hit the daily allowance is kept and run when the allowance is back, instead of
        // the intent vanishing (owner 2026-11-07). A bot's background work keeps waiting for its own next wake.
        if (OcLane.isAllowanceText(turn.error)) {
          blockedByAllowance = true; // no point draining right after hitting the wall
          if (!side && !bg && lastUser != null) {
            err.error = '${turn.error}\n\n_Saved. I will run this as soon as your allowance refreshes._';
            await PendingTurns.I.add(convId, lastUser.id);
          }
        }
      }
    } catch (e) {
      if (!run.cancelled) {
        run.show(RunPhase.failed, RunStatus.failed);
        final err = ChatMessage(id: _uuid.v4(), role: 'assistant', error: '$e')..animateIn = true;
        list.add(err);
        run.wrote.add(err.id);
      }
    } finally {
      if (engineTurn) OpenCodeEngine.I.endTurn();
      screen.release(convId);
      _ocLive.remove(convId);
      runs.remove(run);
      _ocRunEnded(convId, list, run);
      if (!run.finished.isCompleted) run.finished.complete();
      _notify();
      // The allowance may be back: an owner message blocked earlier gets its turn now (owner 2026-11-07). A turn that
      // itself just hit the allowance leaves the waiting ones for a later try.
      if (!run.cancelled && !blockedByAllowance) unawaited(PendingTurns.I.drain());
    }
    // A message the user sent while this turn ran gets its own turn now.
    if (!run.cancelled && sentId != null && chain < 3) {
      final newest = list.lastWhere((m) => m.role == 'user', orElse: () => list.first);
      if (newest.role == 'user' && newest.id != sentId) unawaited(_runAgent(convId, chain: chain + 1));
    }
  }

  /// A bot's own turn on SubMac's bot engine ([BotAgentEngine]), never opencode (owner 2026-11-07): a bot is a digital
  /// person that works on its own, on the phone, under its own profile (its model, its allowance, its notes folder).
  /// Its own BYOK model answers when that provider can take tools; otherwise SubMac's lane does. Every tool is called
  /// directly through the app's tool router — no MCP gateway, no opencode session.
  Future<void> _runBotTurn(String convId, AgentRun run, List<ChatMessage> list, Bot b) async {
    final cfg = BotAgents.I.forBot(b);
    final model = BotBrowserModel.of(b, submacRef);
    final own = model.byok;
    final submac = model.submac ?? submacRef;
    final bg = _backgroundLane(convId);
    // SubMac's tools may have changed since the last turn (an app connected, its tools loaded).
    await ensureMcpTools().catchError((Object _) {});
    final tools = AppState._capTools(_mcpTools(convId)) ?? const <Map<String, dynamic>>[];
    final brief = Bots.I.agentBriefOf(b);
    // A compacted chat keeps its summary plus the messages after the cut.
    final cut = _compactCut(list);
    final system = cut == null ? brief : '$brief\n\n# Earlier in this conversation\n${cut.$1}';
    final history = _botHistory(cut?.$2 ?? list);
    final engine = BotAgentEngine(
      config: cfg,
      cancelled: () => run.cancelled,
      // Background work stops at the bot's own allowance (or its mission's). A bot on its own key is not billed by
      // SubMac, so that allowance never cuts its own-model work (owner 2026-11-07: it must not fight BYOK).
      stop: () => bg && own == null && (b.overBudget || (Missions.I.leftFor('bot', b.id) ?? 1) == 0),
      onStep: (r) {
        if (r.tokens <= 0) return;
        b.addTokens(r.tokens);
        if (bg) Missions.I.addTokens('bot', b.id, r.tokens);
        unawaited(Bots.I.save());
      },
      step: (messages, defs) async {
        final asst = ChatMessage(id: _uuid.v4(), role: 'assistant', streaming: true)..animateIn = true;
        list.add(asst);
        run.wrote.add(asst.id);
        run.show(RunPhase.waiting, RunStatus.waiting);
        _throttledNotify();
        try {
          final LlmResult r;
          final pick = own;
          if (pick != null) {
            // The owner's own provider, straight from the phone (an OpenAI-shaped tool call).
            r = await BotBrowserModel.byokStep(pick, messages, defs);
            asst.content = r.content;
            if (r.content.trim().isNotEmpty) run.show(RunPhase.writing, RunStatus.writing);
          } else {
            // SubMac's lane: the same resilient stream as the owner's chat (retries, limits, "SubMac is busy").
            r = await _streamResilient(run: run, route: submac, payload: messages, tools: defs, asst: asst);
          }
          asst.streaming = false;
          if (asst.content.trim().isEmpty) {
            // Nothing to show for this step (a tool call, or a silent step): the tool row shows the call itself.
            list.remove(asst);
            run.wrote.remove(asst.id);
          } else {
            await _save(convId, asst);
          }
          _throttledNotify();
          return r;
        } catch (e) {
          asst.streaming = false;
          if (asst.content.trim().isEmpty) {
            list.remove(asst);
            run.wrote.remove(asst.id);
          }
          rethrow;
        }
      },
      runTool: (call) async {
        final args = _botArgs(call.arguments);
        final label = stepLabel(call.name, args);
        final row = ChatMessage(id: _uuid.v4(), role: 'assistant', toolCalls: [call])..animateIn = true;
        list.add(row);
        run.wrote.add(row.id);
        run.trail.add(RunStep(label));
        run.show(RunPhase.tool, label);
        _throttledNotify();
        final out = await _runRouted(call.name, args, convId)
            .catchError((Object e) => 'Error in ${call.name}: $e');
        final clipped = out.length <= cfg.maxToolChars ? out : '${out.substring(0, cfg.maxToolChars)}\n...';
        final res = ChatMessage(id: _uuid.v4(), role: 'tool', toolCallId: call.id, name: call.name, content: clipped);
        list.add(res);
        run.wrote.add(res.id);
        if (run.trail.isNotEmpty) run.trail.last.ended = DateTime.now();
        await _save(convId, row);
        await _save(convId, res);
        _throttledNotify();
        return clipped;
      },
    );
    final result = await engine.run(system: system, history: history, tools: tools);
    if (result.stopped == 'stopped') {
      final note = ChatMessage(
        id: _uuid.v4(),
        role: 'assistant',
        error: "Today's allowance for me is used up, so I'll pick this up again tomorrow.",
      )..animateIn = true;
      list.add(note);
      run.wrote.add(note.id);
      await _save(convId, note);
    }
  }

  /// The conversation as model messages (OpenAI shape) for a bot turn: the user's lines, the bot's replies, and the
  /// tool calls with their results. Thinking rows, compact markers and error rows are not part of the model's history.
  List<Map<String, dynamic>> _botHistory(List<ChatMessage> msgs) {
    final out = <Map<String, dynamic>>[];
    for (final m in msgs) {
      if (AppState.isCompactMark(m) || m.name == 'reasoning' || m.error != null) continue;
      if (m.role == 'user') {
        if (m.content.trim().isNotEmpty) out.add({'role': 'user', 'content': m.content});
      } else if (m.role == 'assistant') {
        final calls = m.toolCalls ?? const <ToolCall>[];
        if (calls.isNotEmpty) {
          out.add({
            'role': 'assistant',
            'content': m.content,
            'tool_calls': [for (final c in calls) c.toJson()],
          });
        } else if (m.content.trim().isNotEmpty) {
          out.add({'role': 'assistant', 'content': m.content});
        }
      } else if (m.role == 'tool') {
        out.add({'role': 'tool', 'tool_call_id': m.toolCallId ?? '', 'name': m.name ?? '', 'content': m.content});
      }
    }
    if (out.length <= 80) return out;
    // Keep the newest rows, but never start on a tool result: a tool row must follow the assistant call it answers.
    var start = out.length - 80;
    while (start < out.length && out[start]['role'] == 'tool') {
      start++;
    }
    return out.sublist(start);
  }

  /// A tool call's arguments as a map (a model can send malformed JSON; the tool then sees none).
  Map<String, dynamic> _botArgs(String raw) {
    try {
      final v = jsonDecode(raw);
      return v is Map<String, dynamic> ? v : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  /// Runs an owner message a turn could not answer because the account's daily allowance was used up (PendingTurns,
  /// owner 2026-11-07). Settles the waiting entry when it ran, or when the owner already moved on or the message was
  /// answered meanwhile; keeps it for a later try when the allowance is still out or the chat is busy.
  Future<void> runBlockedTurn(String convId, String msgId) async {
    if (runs.any((r) => r.convId == convId)) return; // busy: leave it for the next trigger
    var loaded = _lists[convId];
    if (loaded == null) {
      if (convId == currentId) {
        loaded = messages;
      } else {
        try {
          loaded = await repo.listMessages(convId);
        } catch (_) {
          return; // the chat may load next time
        }
        _lists[convId] = loaded;
      }
    }
    // A final alias: closures below read it, and a reassigned local would lose its non-null promotion there.
    final msgs = loaded;
    final at = msgs.indexWhere((m) => m.id == msgId);
    if (at < 0) {
      await PendingTurns.I.remove(msgId); // the chat or the message is gone: nothing is owed
      return;
    }
    final after = msgs.skip(at + 1);
    // The owner moved on (a newer message carries the thread), or it was answered meanwhile: nothing to run.
    if (after.any((m) => m.role == 'user') || after.any((m) => m.role == 'assistant' && m.error == null)) {
      await PendingTurns.I.remove(msgId);
      return;
    }
    final here = msgs[at];
    final newestUser = msgs.reversed.firstWhere((m) => m.role == 'user', orElse: () => here);
    if (newestUser.id != msgId) {
      await PendingTurns.I.remove(msgId); // a newer message is the one to run
      return;
    }
    final before = msgs.length;
    await _runAgent(convId);
    if (msgs.length == before) return; // nothing ran (another turn held the chat): try later
    final tail = msgs.reversed.firstWhere((m) => m.role == 'assistant', orElse: () => here);
    // Still out of allowance: keep it. Otherwise it ran: the entry is settled.
    if (!OcLane.isAllowanceText(tail.error)) await PendingTurns.I.remove(msgId);
  }

  /// The pictures, drawings, pages and videos the turn made with opencode's own tools (a written .svg, a script's
  /// .png, an .html page) or named in its answer, shown as cards under the answer (owner 2026-11-04: "no visual
  /// output ability, why?"). opencode does not know SubMac's cards, so the chat finds its visuals itself.
  Future<void> _ocShowVisuals(String convId, OpenCodeTurn turn, List<ChatMessage> list, Map<String, ChatMessage> shown, AgentRun run, DateTime began) async {
    try {
      final ws = await AgentTools.workspaceDir();
      final bot = Bots.I.byConv(convId);
      final calls = <(String, Map<String, dynamic>)>[];
      final outs = <String>[];
      for (final p in turn.parts.values) {
        if (p.kind != 'tool') continue;
        calls.add((p.tool, p.input));
        if (p.output != null) outs.add(p.output!);
      }
      final answer = list.lastWhere(
          (m) => shown.containsValue(m) && m.role == 'assistant' && m.name == null && (m.toolCalls?.isEmpty ?? true) && m.error == null,
          orElse: () => ChatMessage(id: '', role: 'user'));
      final text = answer.id.isEmpty ? '' : answer.content;
      final cards = TurnVisuals.cardsFor(
        answer: TurnVisuals.liftImages(text),
        workspace: ws,
        calls: calls,
        toolOutputs: outs,
        // Files a script made: a bot's turn looks in its own folder only; the owner's chat skips the bots' and teams'
        // folders, which other turns write to meanwhile.
        made: bot == null
            ? await TurnVisuals.madeSinceAsync(Directory(ws), began, skip: const {'bots', 'teams'})
            : await TurnVisuals.madeSinceAsync(Directory('$ws/${Bots.botFolder(bot)}'), began),
      );
      if (cards.isEmpty) return;
      if (answer.id.isNotEmpty) {
        answer.content = TurnVisuals.attach(answer.content, cards);
        return;
      }
      final m = ChatMessage(id: _uuid.v4(), role: 'assistant', content: cards)..animateIn = true;
      shown['visuals:${m.id}'] = m;
      list.add(m);
      run.wrote.add(m.id);
    } catch (e) {
      debugPrint('turn visuals: $e');
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
    if (TeamKey.isKey(conv)) {
      final bot = Bots.I.byConv(conv);
      if (bot == null) return 'Error: this team member is gone.';
      if (name == TeamRun.assignName) {
        final h = _teamAssign[conv];
        if (h == null) return 'Error: team_assign works only while you lead a team job.';
        return h('${args['member'] ?? ''}', '${args['ask'] ?? ''}');
      }
      if (name == TeamRun.taskName) return _teamTask(bot, args);
      // Everything runs under the team key itself (bots team audit 2026-11-04): it acts as the member (Bots.byConv
      // reads the key), its approval cards and asks go to the team, its browser jobs and screen steps belong to the
      // team work. It used to run as the member's private chat, so cards, browser results and "working" lines of team
      // work showed up in the bot's 1:1 conversation with the owner.
      return runToolWithApproval(name, args, convId: conv);
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

  /// One opencode turn for a team member or lead, or one office job, in a fresh session that is deleted afterwards
  /// (nothing piles up, and no member sees another's session or its own private chat's). [key] ([TeamKey]) routes its
  /// SubMac tool calls, approval cards and asks; [assign] is the lead's hand-off. Returns the answer text; throws when
  /// the turn failed.
  ///
  /// Nothing of it is written to the bot's private chat: the caller posts the result in the team chat (owner
  /// 2026-11-04: team work shows only in the team chat). Turns run side by side with no cap: each has its own session.
  ///
  /// [background]: bills to the bots' share (default); an office reply to the owner's own message is foreground.
  /// [office]: an office job of that office (its office tools are offered). [onStatus]: the live line ("Searching
  /// the web") for the team chat.
  Future<String> teamTurn(Bot b, String key, String system, String task,
      {bool Function()? stopped,
      Future<String> Function(String member, String ask)? assign,
      int maxSteps = 40,
      bool background = true,
      String? office,
      String? officeJob,
      void Function(String line)? onStatus}) async {
    // The team chat's live line for this bot ("Nova is working…" / "Nova is typing…") while the turn runs, and its
    // small issue line ("Nova · rate limit") when it fails (owner 2026-11-04). Team keys only: never a private chat.
    TeamStatus.I.begin(key);
    try {
      return await _teamTurn(b, key, system, task,
          stopped: stopped,
          assign: assign,
          maxSteps: maxSteps,
          background: background,
          office: office,
          officeJob: officeJob,
          onStatus: onStatus);
    } catch (e) {
      TeamStatus.I.fail(key, e);
      rethrow;
    } finally {
      TeamStatus.I.end(key);
    }
  }

/// One bot's part of a team's work, on SubMac's own bot engine (owner 2026-11-07): opencode is reserved for the
  /// owner's chat. The turn is the same loop as a bot's own chat ([BotAgentEngine]), but it writes no chat rows: its
  /// team key is no conversation, and only its answer is posted to the team chat by its caller. Its own BYOK model
  /// answers when it can take tools; otherwise SubMac's office lane does. Every tool is called by name through the
  /// app's router under [key] (team_assign, team_task, the office tools and the bot's own).
  Future<String> _teamTurn(Bot b, String key, String system, String task,
      {bool Function()? stopped,
      Future<String> Function(String member, String ask)? assign,
      int maxSteps = 40,
      bool background = true,
      String? office,
      String? officeJob,
      void Function(String line)? onStatus}) async {
    SaveGuard.I.newTurn(key);
    // The model this turn runs on, kept for the debug hook and the BYOK key rotation (tests read it).
    final laneModel = OcLane.pick(background: background, officeWork: true, botModel: b.model);
    final dbg = AppState.debugTeamTurn;
    if (dbg != null) return dbg(b, key, system, task, model: laneModel, background: background, officeJob: officeJob);
    final model = BotBrowserModel.of(b, submacRef);
    final own = model.byok;
    final submac = model.submac ?? submacRef;
    // Answering the owner in the team chat is the owner's own conversation; the rest is office work on the bots'
    // share (the same lane opencode's office provider billed to).
    final source = background ? UsageSource.office : UsageSource.agent;
    final until = DateTime.now().add(const Duration(minutes: 30));
    var over = false;
    var timedOut = false;
    // The turn is over: the owner stopped the team, or it ran out of time. Also the predicate a browser or media job
    // under this key reads to end with it.
    bool dead() {
      if (over || (stopped?.call() ?? false)) return true;
      if (DateTime.now().isAfter(until)) {
        timedOut = true;
        return true;
      }
      return false;
    }

    final outs = <String>[];
    var lastCut = false;
    final run = AgentRun(convId: key, side: true, title: _shortTitle(task));
    try {
      await ensureMcpTools().catchError((Object _) {});
      if (assign != null) _teamAssign[key] = assign;
      if (office != null) _officeCtx[key] = office;
      if (officeJob != null) ocOfficeJob[key] = officeJob;
      teamLive[key] = dead;
      final cfg = BotAgentConfig(
        botId: b.id,
        name: b.name,
        folder: Bots.botFolder(b),
        maxSteps: maxSteps.clamp(6, 80).toInt(),
      );
      final tools = AppState._capTools(_mcpTools(key)) ?? const <Map<String, dynamic>>[];
      final engine = BotAgentEngine(
        config: cfg,
        cancelled: dead,
        // Nobody is watching: the bot's own allowance (and its team mission's) stops office work between steps. A
        // bot on its own key is not billed by SubMac, so that allowance never cuts its own-model work.
        stop: () => background &&
            own == null &&
            (b.overBudget || (office != null && (Missions.I.leftFor('team', office) ?? 1) == 0)),
        onStep: (r) {
          if (r.tokens <= 0) return;
          b.addTokens(r.tokens);
          if (office != null) Missions.I.addTokens('team', office, r.tokens);
          unawaited(Bots.I.save());
        },
        step: (messages, defs) async {
          TeamStatus.I.phase(key, TeamPhase.working);
          final asst = ChatMessage(id: _uuid.v4(), role: 'assistant', streaming: true);
          final LlmResult r;
          final pick = own;
          if (pick != null) {
            // The owner's own provider, straight from the phone (an OpenAI-shaped tool call).
            r = await BotBrowserModel.byokStep(pick, messages, defs);
            asst.content = r.content;
          } else {
            r = await _streamResilient(
              run: run,
              route: submac,
              payload: messages,
              tools: defs,
              asst: asst,
              cancelled: dead,
              backgroundOverride: background,
              sourceOverride: source,
            );
          }
          lastCut = r.cutOff;
          if (asst.content.trim().isNotEmpty) {
            TeamStatus.I.phase(key, TeamPhase.typing);
            onStatus?.call('Writing');
          }
          return r;
        },
        runTool: (call) async {
          final args = _botArgs(call.arguments);
          final label = stepLabel(call.name, args);
          TeamStatus.I.phase(key, TeamPhase.working);
          onStatus?.call(label);
          final out = await _runRouted(call.name, args, key)
              .catchError((Object e) => 'Error in ${call.name}: $e');
          outs.add(out);
          return out.length <= cfg.maxToolChars ? out : '${out.substring(0, cfg.maxToolChars)}\n...';
        },
      );
      try {
        final result = await engine.run(system: system, history: [
          {'role': 'user', 'content': task},
        ], tools: tools);
        if (timedOut) throw OpenCodeError('${b.name} ran out of time (30 min).');
        if (result.stopped == 'cancelled' || (stopped?.call() ?? false)) return '';
        if (result.stopped == 'stopped') {
          // Stopped mid-turn by the bot's own daily budget: it keeps what it wrote, and the team chat says why.
          TeamStatus.I.fail(key, '${b.name} used today\'s token budget. You can raise it in their settings.');
          if (!b.journal.any((e) => e.kind == 'budget' && DateTime.now().difference(e.at).inHours < 20)) {
            b.log('budget', 'Stopped work: today\'s token budget is used up');
            unawaited(Bots.I.save());
          }
        }
        // Pictures, video and sound the member made with media_generate show under its reply in the team chat.
        final made = MediaGen.cardsFromOutputs(outs);
        // Still cut after every continuation: the team chat says so instead of the part looking finished.
        var answer = result.reply;
        if (lastCut && answer.isNotEmpty) answer = '$answer\n\n_(${ReplyContinuation.cutNote})_';
        return TurnVisuals.attach(answer.trim(), made);
      } catch (e) {
        // A BYOK key refused or out of quota: the provider's next key takes over for the next turn.
        final pick = own;
        if (pick != null) await ByokStore.I.rotateAfter(pick.provider.id, '$e');
        rethrow;
      }
    } finally {
      over = true;
      screen.release(key);
      // Its screen steps (phone, browser) were owned by its key: the task bubble lets go of them now.
      TaskBubble.I.runEnded(key);
      if (identical(teamLive[key], dead)) teamLive.remove(key);
      if (assign != null && identical(_teamAssign[key], assign)) _teamAssign.remove(key);
      if (office != null) _officeCtx.remove(key);
      if (officeJob != null) ocOfficeJob.remove(key);
      if (background) unawaited(Cloud.refreshStatus());
      // The team's waiting approval cards of this work go with it (they live under its key).
      unawaited(Offices.I.expireFor(key));
    }
  }

  /// An opencode permission or question from team work ([key]): asked in the team, never in the member's private
  /// chat. A permission becomes the team's approval card (team chat line, approvals inbox, notification); a question
  /// from opencode's question tool has nobody to answer it there, so it is skipped and the member carries on.
  Future<String?> _teamPermission(String key, String title, String prompt, List<String> options) async {
    final b = Bots.I.byConv(key);
    if (b == null) return null;
    final isPermission = options.contains(OpenCodeAsks.allow) && options.contains(OpenCodeAsks.deny);
    if (!isPermission) return null;
    final o = Offices.I.byId(TeamKey.officeOf(key));
    final req = ActionRequest(title: title, body: prompt, detail: prompt);
    final ok = await _askApproval(b, o, req, tool: 'opencode', convId: key);
    return ok ? OpenCodeAsks.allow : OpenCodeAsks.deny;
  }

  /// A background turn stopped by [OcBgGuard] (owner 2026-11-03). `paused`: the bots' share is used up today, so
  /// later wakes wait for tomorrow (Cloud.markBackgroundPaused) and the turn ends on the allowance message (a wake's
  /// outcome reads it as 'credit': one quiet note, no retry). `budget`: the bot's own budget ran out mid-turn; it
  /// keeps what it wrote and notes it once.
  void _ocBgStopped(String? why, OpenCodeTurn turn, Bot? b) {
    if (why == OcBgGuard.paused) {
      Cloud.markBackgroundPaused();
      turn.error = '${AppState.bgPausedText}.';
      if (b != null) _notePaused(b);
    } else if (why == OcBgGuard.budget && b != null) {
      if (!b.journal.any((e) => e.kind == 'budget' && DateTime.now().difference(e.at).inHours < 20)) {
        b.log('budget', 'Stopped work: today\'s token budget is used up');
        unawaited(Bots.I.save());
      }
    } else if (why == OcBgGuard.credit) {
      // The whole daily allowance is used up (bug audit 2026-11-07): one clear line instead of opencode retrying a
      // refused call until the turn times out.
      turn.error = 'You\'ve used today\'s allowance. It refreshes tomorrow.';
      if (b != null) _notePaused(b);
    } else if (why == OcBgGuard.stuck) {
      // A provider that keeps refusing (one call was retried 82 times): stop with a line that reads as "busy", so a
      // bot's wake is retried later and the owner's chat is not left on "retrying".
      turn.error = 'The model provider is busy and kept failing. Nothing you wrote was lost; try again in a few minutes.';
    }
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
    final scheduled = _scheduledConvs.remove(convId);
    final fromNote = _notifReplyConvs.remove(convId);
    _notifyConvs.remove(convId);
    // The owner is away and waits on this: SubMac's own scheduled task, or an answer to a notification reply. It ends
    // with its own notification: who it is from and a short summary of the result (owner 2026-11-05).
    try {
      _notifyRunEnd(convId, list, run, scheduled: scheduled && !Bots.I.isBotConv(convId), fromNote: fromNote);
    } catch (_) {}
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
