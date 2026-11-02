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

  /// Which chat an MCP call belongs to: SubMac's tool name -> the chat whose opencode turn is calling it now (the MCP
  /// request itself does not say which session it came from).
  static final Map<String, String> _mcpConv = {};

  /// SubMac's tools offered to opencode through SubMac's MCP server. Layer 1 (owner, 2026-11-02): memory and the
  /// everyday helpers; the browser, the phone and Live come in the next layers. Each call runs through SubMac's own
  /// gate, so a risky one shows SubMac's approval card first.
  List<Map<String, dynamic>> _mcpTools() => [
        if (memoryEnabled) ...MemoryStore.definitions,
        ...LifeTools.definitions,
      ];

  /// Gives the engine SubMac's MCP server, and turns opencode's permission and question requests into the ask card.
  void _ocWire(OpenCodeEngine oc) {
    oc.mcp ??= SubMacMcp(
      tools: _mcpTools,
      call: (name, args) => runToolWithApproval(name, args, convId: _mcpConv[name] ?? currentId),
    );
    if (_ocAskSub != null) return;
    final asks = OpenCodeAsks(
      ask: (conv, title, prompt, options) async {
        final r = await askUser(UserAsk(
            kind: 'text', convId: conv.isEmpty ? (currentId ?? '') : conv, title: title, prompt: prompt, options: options));
        return r?['answer'];
      },
      permit: oc.replyPermission,
      answer: oc.replyQuestion,
      convOf: oc.convOf,
    );
    _ocAskSub = oc.events.listen((e) => unawaited(asks.handle(e).catchError((Object _) => false)));
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
          if (p.kind == 'text') {
            var m = shown[p.id];
            if (m == null) {
              if (p.text.trim().isEmpty) continue;
              m = ChatMessage(id: _uuid.v4(), role: 'assistant', streaming: true)..animateIn = true;
              shown[p.id] = m;
              list.add(m);
              run.wrote.add(m.id);
            }
            m.content = p.text;
          } else {
            // SubMac's own tools come back from opencode as submac_<name>: shown under their own name.
            final tool = p.tool.startsWith('submac_') ? p.tool.substring(7) : p.tool;
            if (tool != p.tool && !p.finished) _mcpConv[tool] = convId;
            var m = shown[p.id];
            if (m == null) {
              m = ChatMessage(
                id: _uuid.v4(),
                role: 'assistant',
                toolCalls: [ToolCall(id: p.callId, name: tool, arguments: jsonEncode(p.input))],
              );
              shown[p.id] = m;
              list.add(m);
              run.wrote.add(m.id);
              run.trail.add(RunStep(p.title ?? stepLabel(tool, p.input)));
            } else {
              m.toolCalls = [ToolCall(id: p.callId, name: tool, arguments: jsonEncode(p.input))];
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

      final sub = oc.events.listen((e) {
        if (turn.apply(e)) sync();
        if ((turn.done || turn.error != null) && !done.isCompleted) done.complete();
      });
      try {
        run.show(RunPhase.waiting, RunStatus.waiting);
        _notify();
        await oc.prompt(session, await _partsFor(lastUser));
        while (!done.isCompleted && !run.cancelled) {
          await Future.any([done.future, Future<void>.delayed(const Duration(seconds: 1))]);
        }
      } finally {
        await sub.cancel();
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
      runs.remove(run);
      if (!run.finished.isCompleted) run.finished.complete();
      _notify();
    }
    // A message the user sent while this turn ran gets its own turn now.
    if (!run.cancelled && sentId != null && chain < 3) {
      final newest = list.lastWhere((m) => m.role == 'user', orElse: () => list.first);
      if (newest.role == 'user' && newest.id != sentId) unawaited(_runAgent(convId, chain: chain + 1));
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

  String _clip(String s) => s.length <= 8000 ? s : '${s.substring(0, 8000)}\n…';

  /// Runs killed with the app used to resume on the next start; opencode keeps its own sessions, so nothing to do.
  Future<void> resumeKilledRuns() async {}
}
