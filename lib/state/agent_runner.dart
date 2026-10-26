// The agent step loop (_runAgent) and finish/checkpoint logic.
// Split out of app_state.dart (no behaviour change). Fields stay on AppState.
part of '../app_state.dart';

extension AppStateAgentRunner on AppState {
  /// Most follow-on runs in a row for messages that arrived after a run's last step (CB-1).
  static const maxFollowOns = 3;

  /// [chain]: how many runs in a row were started only to answer messages that arrived as the previous one ended (CB-1).
  Future<void> _runAgent(String convId, {bool side = false, int chain = 0}) async {
    final list = _lists[convId] ?? messages;
    _lists[convId] = list;
    final ownerChat = !side && Bots.I.byConv(convId) == null;
    // One model, `submac`, for every step of every task (PLAN 1.1). The server picks the real model behind it.
    final route = submacRef;
    final model = route.model;
    String? lastUserText, lastUserId;
    for (final m in list.reversed) {
      if (m.role == 'user') {
        lastUserText = m.content;
        lastUserId = m.id;
        break;
      }
    }
    // CB-22: one main run per chat. A second start (two "Try again" taps, a wake racing a send) never runs a second
    // agent on the same chat (double answers, double spend). Side replies are separate and stay allowed.
    if (!side && runs.any((r) => r.convId == convId && !r.side)) return;
    final run = AgentRun(convId: convId, side: side, title: _shortTitle(lastUserText ?? 'Task'));
    // CB-17: a bot wake remembers which rows it wrote, so a silent wake can remove exactly those.
    if (!side && _botWakeConvs.containsKey(convId)) _wakeRows[convId] = run.wrote;
    // The user's own requirements, kept where the finish check can re-read them.
    if (lastUserText != null) run.contract.addAll(PromptContract.extract(lastUserText));
    // The request in the user's own words (app-made wakes carry their own job text) and its hard constraints.
    final userAsk = (lastUserText == null || lastUserText.startsWith(botWakeMark)) ? '' : lastUserText;
    run.brief = TaskBrief(userAsk);
    run.must = ConstraintReader.read(userAsk);
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
    // The task line is on screen before anything slow happens (app tool lists can take a few seconds to load).
    if (!side) await ensureMcpTools();
    // Every bot run is written down step by step, so the owner can see exactly what it did.
    final tracer = side ? null : Bots.I.byConv(convId);
    if (tracer != null) BotTraces.I.begin(tracer.id, _traceWhy(convId, lastUserText ?? ''));

    String? sideNote;
    if (side) {
      final task = runs.where((r) => r.convId == convId && !r.side).toList();
      sideNote = '# Multitasking\n'
          'A task is still running in the background${task.isEmpty ? '' : ': "${task.first.title}" (${task.first.statusEnglish})'}. '
          'Answer the user\'s newest message now, briefly. Tools are not available in this reply. '
          'If they ask about the task, say plainly what it has done so far and what it is doing now; it keeps going and its result will appear in the chat. '
          'If they change the plan or ask to stop, confirm it in one sentence ("Okay, switching to Amazon." / "Stopping now."): the task hears them and acts on it.';
    }
    var planRestored = false;
    if (!side && !_botWakeConvs.containsKey(convId)) {
      final plan = _restorePlan(convId, run);
      if (plan != null) {
        planRestored = true;
        sideNote = sideNote == null ? plan : '$sideNote\n\n$plan';
      }
    }
    // The skill picked for a message belongs to that message's chat only (never another chat's or a bot's run).
    final skillNote = side ? null : _skillNotes.remove(convId);
    if (skillNote != null) {
      sideNote = sideNote == null ? skillNote : '$sideNote\n\n$skillNote';
      _skillNoteUsed = true;
    }
    // A run the phone killed, resumed on the next start: its note, and the full toolbox.
    final resumeNote = side ? null : _resumeNotes.remove(convId);
    if (resumeNote != null) {
      sideNote = sideNote == null ? resumeNote : '$sideNote\n\n$resumeNote';
      run.show(RunPhase.starting, RunStatus.resuming);
    }
    // Frustration: notice it and change approach instead of repeating what failed.
    if (lastUserText != null) {
      final earlier = <String>[];
      var errs = 0, seen = 0, skippedLast = false;
      for (final m in list.reversed) {
        if (seen++ > 12) break;
        if (m.role == 'user') {
          if (!skippedLast) {
            skippedLast = true;
          } else if (earlier.length < 3) {
            earlier.add(m.content);
          }
        } else if (m.role == 'assistant' && m.error != null) {
          errs++;
        }
      }
      final g = Calm.guidance(Calm.frustration(lastUserText, earlier: earlier, recentErrors: errs));
      if (g.isNotEmpty) sideNote = sideNote == null ? g : '$sideNote\n\n$g';
    }
    // Speed: a greeting gets an instant reply; a short everyday message starts with the core tools only.
    var lane = QuickLane.full;
    if (!side && lastUserText != null) {
      ChatMessage? lu;
      for (final m in list.reversed) {
        if (m.role == 'user') {
          lu = m;
          break;
        }
      }
      lane = QuickLane.laneFor(lastUserText,
          hasAttachments: lu?.attachments.isNotEmpty ?? false, answeringQuestion: AppState._answersOurQuestion(list));
      final hadAssistant = list.any((m) => m.role == 'assistant' && m.content.trim().isNotEmpty);
      if (lastUserText.startsWith(botWakeMark) ||
          _liveTaskConvs.contains(convId) ||
          _officeCtx.containsKey(convId) ||
          _skillNoteUsed ||
          (hadAssistant && AppState._affirmative.hasMatch(lastUserText.trim()))) {
        lane = QuickLane.full;
      }
    }
    // Grok-style bots (2026-10-24): in a bot's own chat, the first meeting and plain small talk get no tools at all; the bot
    // says what it can take on and suggests one or two first tasks (BotAsk). Any real request runs as usual.
    // Office (team) jobs, live tasks and the owner's routines are never held.
    String? askNote;
    if (!side && lastUserText != null && Bots.I.byConv(convId) != null && !_officeCtx.containsKey(convId)) {
      final wake = lastUserText.startsWith(botWakeMark) ? BotAsk.wakeReasonOf(lastUserText.substring(botWakeMark.length)) : null;
      final hold = BotAsk.askFirst(
        text: wake == null ? lastUserText : '',
        wakeReason: wake,
        answeringBot: AppState._answersOurQuestion(list),
        midTask: planRestored || _liveTaskConvs.contains(convId) || runs.any((r) => r.convId == convId && r != run && !r.side),
      );
      if (hold) {
        lane = QuickLane.quick;
        askNote = BotAsk.turnNote(opening: wake != null);
      }
    }
    // Skills that clearly fit this message: a quiet hint, so the agent reads the proven method before it starts.
    if (!side && lane != QuickLane.quick && lastUserText != null && !lastUserText.startsWith(botWakeMark)) {
      // An APK request: the fact and the built-in skill, so nobody answers "you need Android Studio".
      final apk = ApkBuild.noteFor(lastUserText);
      if (apk.isNotEmpty) sideNote = sideNote == null ? apk : '$sideNote\n\n$apk';
      // A website or UI request: the design skill's process (brief, choices, plan, complete files, check, deliver).
      final design = DesignSkills.noteFor(lastUserText);
      if (design.isNotEmpty) sideNote = sideNote == null ? design : '$sideNote\n\n$design';
      final target = Bots.I.byConv(convId)?.id ?? SkillLibrary.agent;
      final fits = SkillLibrary.I.suggestFor(lastUserText);
      if (fits.isNotEmpty) {
        final hint = '# Skills that may fit this request\n'
            '${fits.map((s) => '- ${s.line}${SkillLibrary.I.has(target, s.id) ? ' (installed)' : ''}').join('\n')}\n'
            'If one truly fits the task, read it with skill_use before you start, then follow it. The user\'s own words win wherever the '
            'skill says otherwise (their steps, format, length, language, what to avoid). Ignore them if they do not fit.';
        sideNote = sideNote == null ? hint : '$sideNote\n\n$hint';
      }
    }
    // Think harder: every step gets the full prompt and the effort hint `high`, even for short messages.
    final thinkHard = !side && thinking == 'think' && Bots.I.byConv(convId) == null;
    if (thinkHard || resumeNote != null) lane = QuickLane.full;
    if (!side) _scopeFor(convId, list, lastUserText ?? '');
    _skillNoteUsed = false;
    // The whole task runs on the Genkit agent core (lib/agent/core.dart): one loop for the main agent, bots and team
    // members. What follows only wires SubMac's prompt, tools, approvals, guards and chat into it.
    final hooks = _MainHooks(this, run, convId, list,
        side: side, ownerChat: ownerChat, lane: lane, thinkHard: thinkHard, sideNote: sideNote, askNote: askNote, lastUserText: lastUserText, tracer: tracer);
    // The header keeps where the run started (so a resume settles every call of this run, even with messages typed
    // mid-task after them) and whether it is background work (a bot wake or a team job, which is not resumed).
    final journal = side
        ? null
        : await RunJournal.open(runId: run.id, convId: convId, kind: tracer != null ? 'bot' : 'main', meta: {
            'title': run.title,
            if (lastUserId != null) 'from': lastUserId,
            if (_botWakeConvs[convId] != null) 'background': _botWakeConvs[convId],
            if (_officeCtx[convId] != null) 'office': _officeCtx[convId],
            if (_officeJobKind[convId] != null && _officeCtx[convId] != null) 'jobKind': _officeJobKind[convId],
          });
    final core = AgentCore(
      hooks: hooks,
      transport: hooks.transport,
      tools: side ? const [] : [..._toolsFor(convId), AppState._moreToolsDef, AppState.sayTool, AppState.todoTool],
      gates: side ? const [] : hooks.gates(),
      before: side ? const [] : hooks.beforeGuards(),
      after: side ? const [] : hooks.afterGuards(),
      log: journal ?? const RunLog(),
      maxSteps: side ? 1 : AppState.longTaskCeiling,
    );
    run.onStop = core.stop;
    var outcome = 'done';
    // Where this run's own messages start (CB-42: did the user see any reply from it?).
    final runFrom = list.length;
    try {
      final res = await core.run();
      outcome = res.end.name;
      final halt = core.state.haltReason;
      if (res.end == RunEnd.halted && banner == null) {
        if (halt == 'step_cap' || halt == null || halt.trim().isEmpty) {
          setBanner('Paused after {n} steps, the most for one task. Send "continue" to keep going.', {'n': '${core.state.step}'});
        } else {
          banner = halt;
          bannerArgs = const {};
        }
      }
      // CB-42: the stop after repeated unknown tools (CB-3) ended the run with only a banner that goes away, so the
      // user saw nothing in the chat. When the run wrote nothing visible, it leaves one short reply that says so.
      if (res.end == RunEnd.halted && halt == ToolNames.stopText && !side && !run.cancelled && !_visibleSince(list, runFrom)) {
        await _sayIn(convId, ToolNames.stopReplyFor(hooks.userLang));
      }
      if (res.end == RunEnd.failed && res.error != null && !run.cancelled && !hooks.answeredFailure) hooks.failWith(res.error!);
    } finally {
      await journal?.close(run.cancelled ? 'stopped' : outcome);
      runs.remove(run);
      // "Worked for 1m 12s" over the final answer of a task that took real steps.
      if (!side && run.trail.isNotEmpty) {
        final fin = list.lastWhere((m) => m.role == 'assistant' && (m.toolCalls?.isEmpty ?? true) && m.content.trim().isNotEmpty,
            orElse: () => ChatMessage(id: '', role: 'assistant'));
        if (fin.id.isNotEmpty) workedFor[fin.id] = DateTime.now().difference(run.started);
      }
      // A stopped task can finish after the user already started a new one here: leave that one's tools alone.
      if (!side && !runs.any((r) => r.convId == convId && !r.side)) _allToolsNow.remove(convId);
      if (!side && !_botWakeConvs.containsKey(convId)) _savePlan(convId, run);
      // Plan 5.5: a soft tap when a real task (one that took steps) finishes in the chat on screen.
      if (tracer != null) {
        final last = list.lastWhere((m) => m.role == 'assistant', orElse: () => ChatMessage(id: '', role: 'assistant', content: ''));
        BotTraces.I.finish(tracer.id, last.error ?? (run.cancelled ? 'Stopped' : BotOutcome.visible(last.content)),
            failed: last.error != null || run.cancelled);
        unawaited(Bots.I.save());
        if (!run.cancelled) unawaited(_learnFrom(tracer, lastUserText ?? ''));
      }
      if (!side && Offices.I.queue.isNotEmpty) Future<void>.delayed(const Duration(milliseconds: 500), _officePump);
      if (run.phone && !runs.any((r) => r.phone)) unawaited(SystemBridge.I.phoneBadge(false));
      TaskBubble.I.runEnded(convId);
      if (run.browsing && !runs.any((r) => r.browsing) && BrowserJobs.I.running.isEmpty) BrowserAgent.I.taskEnded();
      if (!side) _liveTaskFinished(convId, list, run.cancelled);
      if (!side) unawaited(_afterTask(convId, list, run.cancelled));
      if (!side && !run.cancelled) _compactLater(convId, list);
      if (!_hasRun(convId)) _notifyTimer?.cancel();
      if (!side && !run.cancelled && currentId != convId) {
        final c = conversations.where((e) => e.id == convId).toList();
        setBanner('Task finished in "{chat}".', {'chat': c.isEmpty ? tr('another chat') : c.first.title});
      }
      _notify();
      _bumpConversation(convId);
      try {
        await repo.updateConversation(convId, {'model': model});
      } catch (_) {}
      if (!run.finished.isCompleted) run.finished.complete();
      // CB-1: a message that reached the inbox after the last step was built (the final answer was already streaming,
      // so it could not restart that step) is answered by a follow-on run, never left unanswered. At most
      // [maxFollowOns] in a row, so a stuck inbox can never loop. A failed run shows its error instead.
      if (!side && !run.cancelled && outcome != 'failed' && run.inbox.isNotEmpty && chain < AppStateAgentRunner.maxFollowOns) {
        unawaited(_runAgent(convId, chain: chain + 1));
      }
    }
  }

  /// Whether an assistant message with words the user can read was added to [list] at or after [from].
  bool _visibleSince(List<ChatMessage> list, int from) {
    for (var i = from < 0 ? 0 : from; i < list.length; i++) {
      final m = list[i];
      if (m.role == 'assistant' && m.error == null && m.content.trim().isNotEmpty) return true;
    }
    return false;
  }

  /// Tasks the phone killed in the middle (their journal has no end and a stale heartbeat) pick up where they left off:
  /// every call the chat shows without an answer is settled first (nothing is run again here; a side effect is
  /// reported as unknown, a read as safe to call again, a waiting approval as not done), then the agent goes on.
  /// Team members' and browser sub-runs are settled by their parent task, so only chat runs resume. Safe to call
  /// more than once (app start and every return to the app).
  Future<void> resumeKilledRuns() async {
    if (_resumingRuns || repo.userId == null) return;
    _resumingRuns = true;
    try {
      await RunJournal.prune();
      for (final p in await RunJournal.pending()) {
        // Still alive in this process (the phone only paused the app) or already handled.
        if (runs.any((r) => r.id == p.runId) || !_resumedRuns.add(p.runId)) continue;
        if (p.kind != 'main' && p.kind != 'bot') {
          await p.markHandled('parent_settles');
          continue;
        }
        // Too old to pick up quietly, or the chat is busy with a newer task: leave it as the chat shows it.
        if (DateTime.now().toUtc().difference(p.lastBeat) > const Duration(hours: 6) || _hasRun(p.convId)) {
          await p.markHandled('skipped');
          continue;
        }
        // Background work (a bot routine/wake or a team job) is not resumed: its limits (background lane, office step
        // cap, the bot's spend stop) and its job around it (the team task's status, the bot's report) live only in the
        // process that died, so a resume would run it as the owner's own long task. Its cut-off calls are still
        // settled in the chat (a send or payment says "unknown, check first"); the routine runs again at its next time
        // and the team task waits for the owner or the lead.
        final background = p.meta['background'] != null || p.meta['office'] != null;
        // Marked first: if the resume itself dies, it is never retried in a loop.
        await p.markHandled(background ? 'skipped_background' : 'resumed');
        List<ChatMessage> list;
        try {
          list = _lists[p.convId] ?? await repo.listMessages(p.convId);
        } catch (_) {
          continue;
        }
        _lists[p.convId] = list;
        if (currentId == p.convId) messages = list;
        final from = p.meta['from'];
        final open = ResumeSettle.unanswered(list,
            fromId: from is String ? from : null, journalIds: [for (final c in [...p.unfinished, ...p.waiting]) c.id]);
        final plan = p.plan();
        for (final c in open) {
          final tm = ChatMessage(id: _uuid.v4(), role: 'tool', content: plan.textFor(c), toolCallId: c.id, name: c.name);
          list.add(tm);
          await _save(p.convId, tm);
        }
        if (background) continue;
        // A run that died before any step or after its final reply has nothing to continue.
        final last = list.isEmpty ? null : list.last;
        if (last == null || (last.role == 'assistant' && (last.toolCalls?.isEmpty ?? true) && last.content.trim().isNotEmpty)) continue;
        _resumeNotes[p.convId] = ResumeSettle.note(open.length);
        banner = 'A task stopped when SubMac closed. It is picking up where it left off.';
        _notify();
        unawaited(_runAgent(p.convId));
      }
    } finally {
      _resumingRuns = false;
    }
  }

  /// A reply the loop sends back for more work (open checklist, an announced step, the finish check). It stays on
  /// screen; the next final reply replaces it (see [_replaceHeld]).
  Future<void> _holdReply(String convId, List<ChatMessage> list, AgentRun run, ChatMessage asst) async {
    await _replaceHeld(convId, list, run, asst);
    if (asst.content.trim().isNotEmpty) run.heldReply = asst;
  }

  /// A newer final reply replaces the held one: the held one leaves the chat (and the backup), and any file or page
  /// card only it showed moves to the new reply.
  Future<void> _replaceHeld(String convId, List<ChatMessage> list, AgentRun run, ChatMessage now) async {
    final old = run.heldReply;
    run.heldReply = null;
    if (old == null || identical(old, now) || now.content.trim().isEmpty) return;
    final merged = FinalReply.carryCards(old.content, now.content);
    list.remove(old);
    workedFor.remove(old.id);
    try {
      await repo.deleteMessages([old.id]);
    } catch (_) {}
    if (merged != now.content) {
      now.content = merged;
      await _save(convId, now);
    }
    _notify();
  }

  String? _checkpointBlock(String convId, AgentRun run) => AppState.checkpointReason(
        cancelled: run.cancelled,
        lowAllowance: taskBudgetK > 0 ? run.tokens >= taskBudgetK * 1000 : AppState.allowanceLow(),
        // Background bot wakes stay short; the owner's own chats (with the agent or a bot) may run long.
        background: _botWakeConvs.containsKey(convId),
        doneNow: run.todoDone.length,
        doneAtCheckpoint: run.doneAtCheckpoint,
        writesSinceCheckpoint: run.writesSinceCheckpoint,
        steps: run.step,
      );

  /// The note for the finish check: re-read the request, test, and the unfinished spots found in the files it wrote.
  Future<String> _finishCheckNote(AgentRun run) async {
    final hits = <String>[];
    for (final p in run.touched) {
      if (hits.length >= 12) break;
      try {
        final f = File(await CodeTools.resolve(p));
        if (!await f.exists() || await f.length() > 600 * 1024 || !CodeTools.isText(p)) continue;
        final lines = const LineSplitter().convert(await f.readAsString());
        for (var i = 0; i < lines.length && hits.length < 12; i++) {
          if (AppState.unfinished.hasMatch(lines[i])) {
            final t = lines[i].trim();
            hits.add('$p:${i + 1}: ${t.length > 120 ? '${t.substring(0, 120)}…' : t}');
          }
        }
      } catch (_) {}
    }
    final sb = StringBuffer('# Before you finish: check the work\n')
      ..writeln('Do not reply yet. First:')
      ..writeln('1. Re-read the user\'s request and every detail they gave. List anything not done yet.')
      ..writeln('2. Test it for real: run the code (code_run, or code_build test for a full project), code_check the files, open a page '
          'you built. Fix what fails.')
      ..writeln('3. No half work: no stubs, placeholder text, "TODO", empty functions or invented data the user did not give.');
    if (hits.isNotEmpty) sb.writeln('Unfinished spots in the files you wrote:\n${hits.join('\n')}');
    if (run.todo.isNotEmpty) sb.writeln('Your checklist:\n${AppState._todoText(run)}');
    sb.writeln('If something is missing, do it now with your tools. When it is truly complete and tested, give the final reply: '
        'what you built, how you tested it (the real result), how to open or use it, and anything the user must do.');
    return sb.toString().trim();
  }

  /// A long task's checklist outlives the task: after a pause, "continue" picks up the same plan.
  void _savePlan(String convId, AgentRun run) {
    final key = 'plan_$convId';
    final open = run.todo.isNotEmpty && run.todoDone.length < run.todo.length;
    if (!open) {
      local.prefs.remove(key);
      return;
    }
    local.prefs.setString(key, jsonEncode({'steps': run.todo, 'done': run.todoDone.toList(), 'at': DateTime.now().toIso8601String()}));
  }

  /// Restores a paused task's checklist into [run]; returns the note for the model, or null.
  String? _restorePlan(String convId, AgentRun run) {
    final raw = local.prefs.getString('plan_$convId');
    if (raw == null || run.todo.isNotEmpty) return null;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final at = DateTime.tryParse('${j['at']}');
      if (at == null || DateTime.now().difference(at) > const Duration(days: 14)) {
        local.prefs.remove('plan_$convId');
        return null;
      }
      run.todo.addAll([for (final s in j['steps'] as List) '$s']);
      run.todoDone.addAll([for (final d in j['done'] as List) (d as num).toInt()]);
      run.doneAtCheckpoint = run.todoDone.length;
      run.planLive = false;
      return '# Your plan from earlier in this chat (paused)\n${AppState._todoText(run)}\n'
          'If the user\'s new message carries on this work ("continue", "go on", yes, a hint or an answer), pick up at the first open '
          'step now and keep going until all are done. If they asked for something else, leave this plan (call todo with new steps if needed).';
    } catch (_) {
      local.prefs.remove('plan_$convId');
      return null;
    }
  }

  /// A tiny prompt for small talk: who you are, the user, the language, and the last few lines of the chat.
  List<Map<String, dynamic>> _quickPayload(String convId, List<ChatMessage> list, {String? askNote}) {
    final b = Bots.I.byConv(convId);
    final sb = StringBuffer();
    if (b != null) {
      sb.writeln(Bots.I.quickPromptOf(b));
    } else {
      sb.writeln('You are ${AppConfig.appName}, a capable agent on the user\'s Android phone: you browse, use apps, make documents '
          'and media, remember things and run tasks for them. You talk like a sharp, warm friend.');
      sb.writeln(HouseRules.core);
    }
    if (aboutYou.trim().isNotEmpty) sb.writeln('About the user: ${aboutYou.trim()}');
    if (howToRespond.trim().isNotEmpty) sb.writeln('How they want replies: ${howToRespond.trim()}');
    sb
      ..writeln('Now: ${DateTime.now().toIso8601String().substring(0, 16).replaceFirst('T', ' ')}.')
      ..writeln(askNote ??
          'This is small talk. Reply at once in one or two short, natural sentences, the way a friend texts back. '
              'No lists, no headings, no cards, no emoji. Do not offer a menu of what you can do. '
              'If they greet you, greet them back and, at most, ask one light question.')
      ..writeln(somaliIn(list)
          ? Somali.quickGuide
          : replyLanguage == 'auto'
              ? 'Reply in the language they wrote in (Somali replies in natural everyday Somali).'
              : 'Always reply in $replyLanguage.');
    final out = <Map<String, dynamic>>[
      {'role': 'system', 'content': sb.toString().trim()},
    ];
    final recent = <Map<String, dynamic>>[];
    for (final m in list.reversed) {
      if (recent.length >= 8) break;
      if (m.streaming || m.content.trim().isEmpty) continue;
      if (m.role == 'user' && !m.content.startsWith(botWakeMark)) {
        recent.add({'role': 'user', 'content': m.content});
      } else if (m.role == 'assistant' && (m.toolCalls == null || m.toolCalls!.isEmpty)) {
        final c = m.content.length > 600 ? '${m.content.substring(0, 600)}…' : m.content;
        recent.add({'role': 'assistant', 'content': c});
      }
    }
    // A chat must start with the user.
    while (recent.isNotEmpty && recent.last['role'] != 'user') {
      recent.removeLast();
    }
    // The first meeting has no message of the owner's yet: the turn opens on a quiet stand-in.
    if (recent.isEmpty && askNote != null) recent.add({'role': 'user', 'content': '(The owner has opened your chat.)'});
    out.addAll(recent.reversed);
    return out;
  }
}

/// SubMac's side of an agent run on the Genkit core: the prompt of every step, tools and approvals, the guards, and the
/// chat on screen. One instance per run (main chat, bot chat, office work, side reply).
class _MainHooks extends CoreHooks {
  _MainHooks(this.app, this.run, this.convId, this.list,
      {required this.side,
      required this.ownerChat,
      required this.lane,
      required this.thinkHard,
      required this.sideNote,
      required this.askNote,
      required this.lastUserText,
      required this.tracer});

  final AppState app;
  final AgentRun run;
  final String convId;
  final List<ChatMessage> list;
  final bool side, ownerChat, thinkHard;
  final String lane;
  final String? sideNote, askNote, lastUserText;
  final Bot? tracer;

  /// The reply streaming right now (one per model call).
  ChatMessage? _asst;
  bool _quickNow = false;
  List<Map<String, dynamic>>? _stepTools;
  int _trimTo = 0; // >0 when even a compacted chat was too long: send only the latest part.
  bool _compactedOnError = false;
  bool _allTools = false;

  /// The current reply is kept as it is (cut off by the length limit) and the next one continues it.
  bool _keep = false;

  /// CB-10: the message the next model call writes into (a cut-off reply it continues, or a dropped step it redoes), and
  /// the text that message already holds from earlier calls. A continuation joins the same message: one bubble, one
  /// save, and repair, the card check, Copy and Try again see the whole reply.
  ChatMessage? _carry;
  String _prefix = '';

  /// CB-24: the carried message's own part came from a dropped call: it stays on screen until the retry's first word
  /// replaces it.
  bool _redo = false;

  /// CB-1: the final reply is answered (kept and saved as it is) and the same run goes on to answer the inbox.
  bool _answered = false;
  int _inboxRounds = 0;

  /// The run's failure was already answered in the chat (CB-30): no error card on top of it.
  bool answeredFailure = false;

  /// The recent part of the chat when even a compacted chat was too long ([_trimTo]). The latest summary stays in front,
  /// so falling back to the recent part never drops what the summary kept (CB-30).
  List<ChatMessage> _trimmed() {
    final tail = app._tail(list, _trimTo);
    final mark = list.lastWhere(AppState.isCompactMark, orElse: () => ChatMessage(id: '', role: 'system'));
    if (mark.id.isEmpty || tail.contains(mark)) return tail;
    return [mark, ...tail];
  }

  /// Launch hardening H-1: the language of the user's latest message that says enough to tell (null: unknown).
  String? get userLang => ReplyLang.ofChat(
      list.reversed.where((m) => m.role == 'user' && !m.content.startsWith(botWakeMark)).map((m) => m.content));

  /// Replies sent back for being in the wrong language (one round per run).
  int _langFixes = 0;

  /// Approval gates of this turn's calls, by call id (asked through an interrupt, then run with the user's answer).
  final Map<String, ToolGate> _gates = {};
  final Map<String, _GroupRow> _groupRows = {};
  final Map<String, RunStep> _rows = {};
  final Map<String, DateTime> _t0 = {};

  @override
  bool get cancelled => run.cancelled;

  String get _laneNow => (side || _quickNow) ? QuickLane.quick : (_allTools ? (run.step <= 1 ? lane : QuickLane.full) : QuickLane.light);

  // ---------------------------------------------------------------- turns

  @override
  Future<Turn> buildTurn(int step, String? notes) async {
    _allTools = _allTools || lane == QuickLane.full || app._allToolsNow.contains(convId);
    final segment = run.browsing && AppState.maxSteps < 150 ? 150 : AppState.maxSteps;
    String? stepNote = sideNote;
    void add(String? n) {
      if (n == null || n.trim().isEmpty) return;
      stepNote = stepNote == null ? n : '$stepNote\n\n$n';
    }

    if (!side && run.checkpointNote) {
      run.checkpointNote = false;
      add('# Checkpoint (step $step)\n'
          'You are deep into a long task. Re-read the user\'s request and your checklist${run.todo.isEmpty ? ' (make one with todo now)' : ''}, '
          'then carry on with the next open step. Keep files saved as you go.${run.todo.isEmpty ? '' : '\n${AppState._todoText(run)}'}');
      run.doneAtCheckpoint = run.todoDone.length;
      run.writesSinceCheckpoint = 0;
    }
    final cap = _officeCap();
    if (cap > 0 && step >= cap && !run.officeCapNoted) {
      run.officeCapNoted = true;
      add('# Step budget for this office work is used\n'
          'Stop working now: call no more tools. Post what is done and what is left in two or three plain lines, '
          'and update your task on the board (office_board) if one is open.');
    }
    run.step = step + 1;
    // R2 item 1: no canned "Thinking" here. The line changes when the request goes out (agent_stream.dart), and says
    // what that request is for (run.nextCall).
    // Stuck? (same call again and again, the same failure, back and forth): a clear note for this step.
    if (!side && !run.cancelled && step > 0) {
      final sig = run.guard.check();
      if (sig.stuck) {
        run.guard.reset();
        // A few notes were ignored: the next reply must be the plain status, no more tools.
        final note = run.guard.strike() ? LoopGuard.giveUp : sig.guidance;
        if (run.guard.strikes >= LoopGuard.maxStrikes && run.stuckStopAt < 0) run.stuckStopAt = step - 1;
        add(note);
      }
    }
    add(notes);
    if (run.inbox.isNotEmpty) {
      final said = run.inbox.map((t) => '"$t"').join(' then ');
      // A correction amends the task (original + change); the recital at the end of later steps carries both.
      for (final t in run.inbox) {
        run.brief.amend(t);
      }
      run.must = ConstraintReader.read([run.brief.original, ...run.brief.changes].join('\n'));
      run.inbox.clear();
      final acked = run.inboxAcked;
      run.inboxAcked = false;
      run.nextCall = (RunStatus.reading, const {});
      add(TaskBrief.steer(said, acked: acked));
    }
    // (v1.13.101) No "keep the user in the loop" nudge any more: the owner wants the agent to work quietly (no
    // narration in chat unless asked, 2026-10-24), and the nudge made the model spend a step on a `say` line every six
    // steps. Progress shows in the status line.
    if (!side) {
      // Recitation (end of the request): the open checklist keeps the plan in view on long tasks; once real work was
      // done, the final check keeps the answer honest and shaped for the user.
      add(run.todo.isNotEmpty ? Recite.checklist(run.todo, run.todoDone) : (run.toolCalls >= 3 ? Recite.finalCheck(selfCheck: run.must.selfCheck()) : ''));
      // The hard constraints in the user's words (count, language, format, don't/only), compact, every step.
      add(run.must.mustLine());
      // Launch hardening H-1: the reply's language, at the end of every step (tool results in English no longer pull a
      // Somali or Arabic answer into English). Not for app-made wakes (a routine, a team job).
      if (!(lastUserText ?? '').startsWith(botWakeMark)) add(ReplyLang.anchor(userLang, setting: app.replyLanguage));
      // Plan, then act: a request with several parts starts with a visible checklist.
      if (step == 0 && ownerChat && run.todo.isEmpty && lane == QuickLane.full && TurnRouter.needsPlan(lastUserText ?? '')) {
        add('# This request has several parts\n'
            'If one detail only the user knows is truly missing, ask that one short question first (ask_user). Otherwise `say` one short line on what you will do, '
            'call todo with the steps, and start the first one in this same reply.');
      }
      // Wrap-up two steps before the task really stops: the coming checkpoint pauses it, or the ceiling.
      final willPause = (step + 2) % segment == 0 && app._checkpointBlock(convId, run) != null;
      add(StepBudget.note(step, segment, willPause: willPause, ceiling: AppState.longTaskCeiling));
    }
    _quickNow = lane == QuickLane.quick && step == 0;
    // Effort hint (PLAN 1.1): `low` for greetings, short questions and step 1; `high` for "think harder".
    final effort = thinkHard ? 'high' : ((step == 0 || _quickNow) ? 'low' : null);
    _stepTools = (side || _quickNow) ? null : (_allTools ? app._scopedTools(convId) : app._lightTools(convId));
    // A side reply (the user wrote while a task runs) answers in a line or two with no tools: it gets the small prompt
    // (house rules, the user, the language, the last few lines) instead of the whole agent prompt. It sent about 7k
    // prompt tokens for each of these short answers (v1.13.101).
    List<Map<String, dynamic>> build() => side
        ? app._quickPayload(convId, list, askNote: stepNote)
        : _quickNow
        ? app._quickPayload(convId, list, askNote: askNote)
        : app._payload(_trimTo > 0 ? _trimmed() : list,
            sideNote: stepNote, withShot: !side && run.browsing, request: side ? '' : run.brief.recital(), convId: convId);
    // From here a new message can't be in this step's payload: it reaches the task through its inbox.
    if (!side) run.payloadBuilt = true;
    var payload = build();
    // Close to SubMac's window (x-submac-window): quietly fold the older part of the chat into a summary, then carry
    // on. (Only when the chat itself is a big part of it: the tool list alone never triggers a summary.)
    if (!side &&
        !_quickNow &&
        RateLimiter.estimateTokens(payload, _stepTools) > ContextWindow.compactAt() &&
        RateLimiter.estimateTokens(payload.skip(1).toList()) > ContextWindow.tokens * 0.3) {
      run.show(RunPhase.checking, RunStatus.compacting);
      app._notify();
      if (await app._autoCompact(convId, list, app.submacRef)) payload = build();
    }
    return Turn(step: step, payload: payload, tools: _stepTools, hints: {'effort': effort, 'lane': _laneNow});
  }

  int _officeCap() => (!side && app._officeCtx.containsKey(convId) && app._botWakeConvs[convId] == 'office')
      ? AppState.officeStepCap(app._officeJobKind[convId] ?? '', browsing: run.browsing)
      : 0;

  @override
  void modelStarted(int step) {
    _keep = false;
    final carry = _carry;
    _carry = null;
    if (carry != null && list.contains(carry)) {
      // Continues (or redoes) the reply already on screen in the same bubble.
      carry.streaming = true;
      _asst = carry;
    } else {
      final asst = ChatMessage(id: _uuid.v4(), role: 'assistant', streaming: true)..animateIn = true;
      _asst = asst;
      _prefix = '';
      _redo = false;
      list.add(asst);
      run.wrote.add(asst.id);
    }
    run.inModel = true;
    app._notify();
  }

  @override
  String partialText() => _asst?.content ?? '';

  /// Stop while the reply streamed (CB-2): the words already on screen stay, are saved, and the bubble is marked as
  /// stopped. Only an empty bubble leaves the chat.
  @override
  Future<void> onStopped(Reply r) async {
    final asst = _asst;
    _asst = null;
    _carry = null;
    run.inModel = false;
    if (asst == null) return;
    await _keepStopped(asst);
  }

  Future<void> _keepStopped(ChatMessage asst) async {
    asst.streaming = false;
    if (asst.content.trim().isEmpty) {
      list.remove(asst);
      app._notify();
      return;
    }
    if (!list.contains(asst)) return;
    asst.toolCalls = null;
    asst.stopped = true;
    // A card left open where it stopped is closed, so the half reply still draws.
    asst.content = ReplySchema.repair(asst.content);
    app._notify();
    await app._save(convId, asst);
  }

  /// A step that is sent again (a steer, a drop): a continuation keeps the part it continues, anything else goes.
  void _dropStep(ChatMessage? asst, {bool redo = false}) {
    if (asst == null) return;
    asst.streaming = false;
    if (_prefix.isEmpty && (!redo || asst.content.isEmpty)) {
      list.remove(asst);
      return;
    }
    if (!redo) asst.content = _prefix;
    _carry = asst;
    _redo = redo && asst.content.length > _prefix.length;
  }

  /// The wire: one model call through ai-chat with the app's time limits and quiet retries (agent_stream.dart).
  Future<LlmResult> transport(Turn t) async {
    final asst = _asst ?? (ChatMessage(id: _uuid.v4(), role: 'assistant', streaming: true));
    final redoFrom = _redo ? _prefix : null;
    _redo = false;
    try {
      final r = await app._streamResilient(
        run: run,
        route: app.submacRef,
        payload: t.payload,
        tools: t.tools,
        asst: asst,
        redoFrom: redoFrom,
        lane: '${t.hints['lane'] ?? QuickLane.full}',
        effort: t.hints['effort'] as String?,
      );
      // The pictures this step carried were received: later steps get a one-line note instead (PLAN 1.4).
      if (!_quickNow) app._imagesOnce.commit(convId);
      return r;
    } finally {
      run.inModel = false;
      asst.streaming = false;
    }
  }

  @override
  Future<ErrorAction> onError(Object e) async {
    final asst = _asst;
    run.inModel = false;
    asst?.streaming = false;
    // The user spoke mid-step: the step starts again and hears them (it is not counted; nothing to rewind).
    if (run.client?.steered == true && !run.cancelled) {
      run.client?.steered = false;
      run.nextCall = (RunStatus.reading, const {});
      _dropStep(asst);
      app._notify();
      return ErrorAction.retry;
    }
    if (run.cancelled) {
      // CB-2: the words already shown stay (an empty bubble goes).
      _asst = null;
      if (asst != null) await _keepStopped(asst);
      return ErrorAction.stop;
    }
    final es = e.toString();
    // Too long for the model: quietly compact the chat and retry. Only if that is not possible, fall back to sending
    // the recent part. The user sees no error either way.
    final tooLong = Calm.isContextTooLong(es) || (e is LlmException && e.isTooLong);
    // CB-30: the user's own message is the long part (a huge paste): folding the chat cannot make it fit, so nothing is
    // sent again. The reply says so in the app's language and offers the two ways that work.
    if (!side && tooLong && (asst?.content.isEmpty ?? true)) {
      final mine = list.lastWhere((m) => m.role == 'user', orElse: () => ChatMessage(id: '', role: 'user'));
      if (PasteGuard.messageAloneTooLong(mine.content)) {
        final a = asst ?? ChatMessage(id: _uuid.v4(), role: 'assistant');
        if (!list.contains(a)) {
          list.add(a);
          run.wrote.add(a.id);
        }
        a.streaming = false;
        a.content = PasteGuard.tooLongReply(PasteGuard.kbOf(mine.content));
        _asst = null;
        answeredFailure = true;
        app._notify();
        await app._save(convId, a);
        return ErrorAction.stop;
      }
    }
    if (!side && _trimTo == 0 && (asst?.content.isEmpty ?? true) && tooLong) {
      if (asst != null) list.remove(asst);
      if (!_compactedOnError && await app._autoCompact(convId, list, app.submacRef, force: true)) {
        _compactedOnError = true;
      } else {
        _trimTo = 16;
      }
      app._notify();
      return ErrorAction.retry;
    }
    // The connection dropped in the middle of a reply: the step is sent again (never patched with "continue where it
    // stopped"). At most twice in a row (PLAN 1.3). too_long is final (CB-30): the same request is never re-sent.
    // CB-24: the partial reply stays on screen until the retry's first word replaces it.
    if (!side && StreamPolicy.canReissueAfterDrop(run.dropsInRow) &&
        !(e is LlmException && (e.isFinal || e.isAuth || e.isTooLong || e.message.startsWith('You have used today')))) {
      run.dropsInRow++;
      _dropStep(asst, redo: true);
      // Said as it is: the line dropped and this step is sent again (attempt N of M).
      final at = {'i': '${run.dropsInRow}', 'm': '${StreamPolicy.dropContinues}'};
      run.show(RunPhase.retrying, RunStatus.reconnecting, at);
      run.nextCall = (RunStatus.reconnecting, at);
      app._notify();
      return ErrorAction.retry;
    }
    return ErrorAction.stop;
  }

  /// The run failed for good: the error stays on the last reply (or a fresh one).
  void failWith(Object e) {
    run.show(RunPhase.failed, RunStatus.failed);
    var asst = _asst;
    if (asst == null || !list.contains(asst)) {
      asst = ChatMessage(id: _uuid.v4(), role: 'assistant');
      list.add(asst);
      run.wrote.add(asst.id);
    }
    asst.streaming = false;
    // A steer is never shown as an error word ("steered").
    // Stored with its code and status and without class names, so the card can say it in the app's language (CB-27).
    asst.error = AgentCore.isSteer(e) ? AgentCore.steerStopText : ErrorCopy.store(AgentCore.causeOf(e));
    app._notify();
    if (asst.content.isNotEmpty) unawaited(app._save(convId, asst));
  }

  // ---------------------------------------------------------------- replies

  @override
  Future<void> discard(Reply r, {bool hold = false}) async {
    final asst = _asst;
    if (asst == null) return;
    asst.streaming = false;
    if (_answered) {
      // CB-1: a final answer, kept and saved like any other; the next call answers the message that came in meanwhile.
      _answered = false;
      await commit(r);
      _asst = null;
      app._notify();
      return;
    }
    if (_keep) {
      // Kept as it is (cut off by the length limit): the next reply continues it in the same message (CB-10).
      asst.content = _prefix + r.text;
      asst.toolCalls = null;
      await app._save(convId, asst);
      _prefix = asst.content;
      _carry = asst;
    } else if (_prefix.isNotEmpty) {
      // A continuation sent back by another check: the part it continued stays as it was (never deleted with it).
      asst.content = hold ? _prefix + r.text : _prefix;
      asst.toolCalls = null;
      if (!hold) asst.content = ReplySchema.repair(asst.content);
      await app._save(convId, asst);
    } else if (hold) {
      asst.content = r.text;
      asst.toolCalls = null;
      // Shown now; the final reply that follows replaces it (no second "it's ready" message).
      await app._holdReply(convId, list, run, asst);
    } else {
      list.remove(asst);
    }
    _asst = null;
    app._notify();
  }

  @override
  Future<void> commit(Reply r) async {
    final asst = _asst;
    if (asst == null) return;
    run.inModel = false;
    asst.streaming = false;
    run.dropsInRow = 0;
    // CB-10: a continuation is joined to the part it continues (one message).
    asst.content = _prefix + r.text;
    asst.toolCalls = r.callsOrNull;
    // Entrance animation is for the moment it arrives, never again on a later rebuild.
    Future<void>.delayed(const Duration(seconds: 2), () => asst.animateIn = false);
    if (r.hasCalls) {
      run.openCalls
        ..clear()
        ..addAll(r.calls.map((c) => c.id));
      run.blanks.gotReply();
      _trackWrites(r.calls);
      await app._save(convId, asst);
      app._notify();
      return;
    }
    // A final reply.
    if (asst.content.trim().isEmpty) {
      if (run.cancelled) {
        list.remove(asst);
      } else if (!run.noToolsAfterStop) {
        asst.error = r.step == 0 ? 'No answer came back. Please try again.' : 'The answer stopped in the middle of the task. Send "continue" to carry on.';
      } else {
        list.remove(asst);
      }
      app._notify();
      return;
    }
    run.blanks.gotReply();
    // Local card fixes (ReplySchema.repair): a markdown table becomes a table card, an open card at the end is closed.
    if (!r.cutOff) asst.content = ReplySchema.repair(asst.content);
    // A reply cut off inside a ```page block is told to save the page to files instead, so its half page never stays
    // in the chat as a second, broken preview.
    if (r.cutOff && '```'.allMatches(asst.content).length.isOdd) {
      final at = asst.content.lastIndexOf('```');
      if (asst.content.startsWith('```page', at) || asst.content.startsWith('```html', at)) {
        asst.content = asst.content.substring(0, at).trimRight();
      }
    }
    if (!side) {
      // The same site preview never shows twice in one run (a repeated card in this reply or a later one).
      final before = run.shownCards.length;
      asst.content = dropRepeatPageCards(asst.content, run.shownCards);
      if (run.shownCards.length > before) run.sitePage = null; // the reply showed its page: nothing to add
      // A site was built but the reply forgot its card: add it, so Open and Publish are always there.
      if (run.sitePage != null && !asst.content.contains('```file') && !asst.content.contains('```page')) {
        final p = run.sitePage!;
        final full = p.startsWith('/') && File(p).existsSync() ? p : AgentTools.cardPath(p.startsWith('/') ? p : '${await AgentTools.workspaceDir()}/$p');
        if (File(full).existsSync()) {
          if (run.shownCards.add(full)) asst.content = '${asst.content.trimRight()}\n\n```file\n$full\n```';
          run.sitePage = null;
        }
      }
    }
    await app._save(convId, asst);
    // Files this reply shows are kept in the account, so the chat shows them on the user's other phones too.
    unawaited(MediaStore.I.keepAllIn(asst.content).catchError((_) {}));
    if (!side) await app._replaceHeld(convId, list, run, asst);
    app._notify();
  }

  void _trackWrites(List<ToolCall> calls) {
    for (final c in calls) {
      Map<String, dynamic> a;
      try {
        final d = jsonDecode(c.arguments.trim().isEmpty ? '{}' : c.arguments);
        a = d is Map ? Map<String, dynamic>.from(d) : {};
      } catch (_) {
        continue;
      }
      final wp = c.name == 'write_file' ? '${a['path'] ?? ''}' : '';
      if (RegExp(r'\.html?$', caseSensitive: false).hasMatch(wp) && (run.sitePage == null || wp.toLowerCase().endsWith('index.html'))) {
        run.sitePage = wp;
      }
      // Any change to a page, style or script marks the site for a check before the final reply (SiteGate).
      final cp = const {'write_file', 'append_file', 'edit_file'}.contains(c.name) ? '${a['path'] ?? ''}' : '';
      if (RegExp(r'\.(html?|css|js|mjs)$', caseSensitive: false).hasMatch(cp)) {
        run.siteDirty = true;
        final isPage = RegExp(r'\.html?$', caseSensitive: false).hasMatch(cp);
        if (isPage && (run.siteEntry == null || cp.toLowerCase().endsWith('index.html'))) run.siteEntry = cp;
      }
    }
  }

  // ---------------------------------------------------------------- guards

  /// Before each model call: checkpoints of long tasks, an office round's step cap.
  List<FutureOr<String?> Function(RunState s)> beforeGuards() => [
        (s) {
          final segment = run.browsing && AppState.maxSteps < 150 ? 150 : AppState.maxSteps;
          if (!run.checkpoints.due(s.step, segment)) return null;
          run.checkpointNote = true;
          return app._checkpointBlock(convId, run);
        },
        (s) {
          final cap = _officeCap();
          return (cap > 0 && s.step >= cap + 2) ? AppState.officeCapReason : null;
        },
      ];

  /// Every model call's true usage is counted here, also replies without tool calls (often a run's biggest output)
  /// and replies a finish gate sent back: the bot's daily budget (its own work only) and Bot Activity, and the task's
  /// own size.
  @override
  void usage(Reply r) {
    final t = tracer;
    if (t != null) {
      // CB-20: billing units (uncached×0.3 + cached×0.1 + out×1, as the server counts them), and only the bot's own
      // work (a wake, team work) goes to its daily budget; what the owner types to it never does.
      final units = UsageUnits.of(r.tokensIn, r.tokensOut, cached: r.tokensCached, fallback: r.tokens);
      if (units > 0) {
        if (UsageSource.isBotWork(app._usageSource(convId, side: side))) t.addTokens(units);
        BotTraces.I.tokens(t.id, units);
      }
      return;
    }
    if (side) return;
    // The model's own token count for this call: the output, and how much the prompt grew (the earlier chat was
    // already counted), so long builds are not stopped after a handful of steps.
    if (r.tokensIn > 0 || r.tokensOut > 0) {
      final grew = r.tokensIn - run.lastPromptTokens;
      run.tokens += r.tokensOut + (run.lastPromptTokens == 0 ? r.tokensIn : (grew > 0 ? grew : 0));
      run.lastPromptTokens = r.tokensIn;
    } else {
      run.tokens += r.tokens;
    }
  }

  @override
  String cleanOutput(String out) => ToolOutputClean.clean(out);

  /// After a reply that wants tools: the bot's daily budget, the task's own budget (true usage from the model), and
  /// the stuck stop. Each may leave a note for the next step or take the tools away.
  List<ReplyGuard> afterGuards() => [
        (r, s) async {
          final step = r.step;
          final t = tracer;
          if (t != null && r.tokens > 0) {
            // Over its own budget in the middle of background work: one note to finish, then a hard stop.
            final spend = SpendStop.decide(over: t.overBudget && app._botWakeConvs.containsKey(convId), wantsTools: r.hasCalls, wrapUpAt: run.wrapUpAt, step: step);
            if (spend == WrapUp.note) {
              run.wrapUpAt = step;
              s.note('Your daily token budget is used up. Stop working now: call no more tools, and write a two-line status of what is done and what is left.');
            } else if (spend == WrapUp.stop) {
              _stopTools(s);
            }
          }
        },
        (r, s) async {
          if (tracer != null) return;
          final step = r.step;
          final over = app.taskBudgetK > 0 ? run.tokens >= app.taskBudgetK * 1000 : AppState.allowanceLow();
          if (!over) return;
          if (run.wrapUpAt < 0) {
            run.wrapUpAt = step;
            s.note('# ${app.taskBudgetK > 0 ? 'This task reached its size limit' : 'Today\'s allowance is nearly used'}\n'
                'Stop working now: call no more tools. Save anything unsaved first only if it takes no tool. In two or three plain '
                'lines, tell the user what is done, what is left, and that they can send "continue" to carry on'
                '${app.taskBudgetK > 0 ? '' : ' (tomorrow, when the allowance refreshes)'}.');
          } else if (step - run.wrapUpAt >= 2) {
            app.banner = app.taskBudgetK > 0
                ? 'This task reached its size limit, so it paused. Send "continue" to keep going.'
                : 'Paused to keep a little of today\'s allowance for you. Send "continue" to carry on (it refreshes tomorrow).';
            _stopTools(s);
          }
        },
        (r, s) async {
          // Stuck and told to stop, but it still reaches for tools: end the task here with what it said.
          if (run.stuckStopAt >= 0 && r.step > run.stuckStopAt) {
            app.banner = 'SubMac stopped: it kept hitting the same problem. Send a hint or another way, then "continue".';
            _stopTools(s);
          }
        },
      ];

  void _stopTools(RunState s) {
    s.noMoreTools = true;
    run.noToolsAfterStop = true;
  }

  // ---------------------------------------------------------------- finish gates

  /// Checks a final reply must pass, in order: not blank, proven, page checked, not cut off, checklist done, work
  /// checked, valid cards.
  List<FinishGate> gates() => [
        // CB-1: a message the user sent while this final answer streamed (too late to restart the step). The answer is
        // kept as it is, and the same run answers the new message next (buildTurn reads the inbox), at most 3 times.
        (r) async {
          if (run.cancelled || run.inbox.isEmpty || r.blank || r.cutOff || _inboxRounds >= AppStateAgentRunner.maxFollowOns) return null;
          _inboxRounds++;
          _answered = true;
          run.nextCall = (RunStatus.reading, const {});
          return (note: '', hold: false);
        },
        // Blank: models sometimes go blank mid-task (often after a screenshot). Nudge once or twice instead of going silent.
        (r) async {
          if (!r.blank || run.cancelled) return null;
          if (run.blanks.retry()) {
            run.nextCall = (RunStatus.revising, const {});
            return (note: '# Your last reply was empty\nContinue the task with your next action, or if it is finished or blocked, tell the user in one or two plain sentences.', hold: false);
          }
          return null;
        },
        // Truth gate: a claim that something was done needs a tool result from this task behind it. Without one the
        // model gets exactly one chance to do it, or to say plainly what is not done.
        (r) async {
          if (r.blank || r.cutOff || run.wrapUpAt >= 0 || run.truthNudges >= 1 || AppState._waitsOnUser(r.text)) return null;
          final unproven = Truth.unproven(r.text, run.evidence);
          if (unproven == null) return null;
          run.truthNudges++;
          run.nextCall = (RunStatus.revising, const {});
          return (
            note: '# That is not proven yet\n$unproven\nDo it now with your tools, or say plainly what is not done and why. '
                'Never say something was sent, saved, booked, created, posted, paid for, installed or finished '
                'unless a tool result in this task shows it.${PromptContract.block(run.contract)}',
            hold: false,
          );
        },
        // Site gate (owner 2026-10-24: "unfinished ugly broken websites"): a page this task wrote is checked before the
        // final reply goes out; problems go back to the model. A broken ```page card in the reply is sent back once.
        (r) async {
          if (r.blank || r.cutOff || run.wrapUpAt >= 0 || AppState._waitsOnUser(r.text)) return null;
          String? gateNote;
          if (run.siteEntry != null && run.siteDirty) {
            run.siteDirty = false;
            run.show(RunPhase.checking, RunStatus.checkingPage);
            app._notify();
            final ws = await AgentTools.workspaceDir();
            final e = run.siteEntry!;
            final full = e.startsWith('/') ? e : await CodeTools.resolve(e);
            final dir = File(full).parent.path;
            final report = await SiteCheck.run(full, alone: dir == ws || dir == '$ws/pages');
            switch (SiteGate.decide(ok: report.ok, fixes: run.siteFixes, explained: run.siteExplained)) {
              case SiteStep.pass:
                break;
              case SiteStep.fix:
                run.siteFixes++;
                gateNote = SiteGate.fixNote(report);
              case SiteStep.explain:
                run.siteExplained = true;
                gateNote = SiteGate.explainNote(report);
            }
          }
          final inline = gateNote == null && run.pageFixes < 1 ? SiteGate.pageBlock(r.text) : null;
          if (inline != null) {
            final bad = SiteCheck.inlinePage(inline);
            if (bad.isNotEmpty) {
              run.pageFixes++;
              gateNote = SiteGate.pageNote(bad);
            }
          }
          if (gateNote == null) return null;
          run.nextCall = (RunStatus.revising, const {});
          return (note: gateNote, hold: false);
        },
        // Cut off by the length limit in the middle of a reply: the part that came stays, the next reply carries on.
        (r) async {
          if (!r.cutOff || run.cutOffs >= 6 || run.wrapUpAt >= 0) return null;
          run.cutOffs++;
          final openFence = '```'.allMatches(r.text).length.isOdd;
          _keep = !openFence;
          run.nextCall = (RunStatus.continuing, const {});
          return (
            note: '# Your last reply was cut off by the length limit\n'
                '${openFence ? 'It stopped inside a code or page block, which cannot be continued in chat. Do not repeat it in chat: '
                    'save the whole thing to files instead (write_file, then append_file in parts of about 150 lines), '
                    'then show it with a ```file block.' : 'Continue exactly where it stopped, without repeating what you already wrote.'}',
            hold: false,
          );
        },
        // Stopped with checklist steps still open (or promised a next step without taking it): keep going.
        (r) async {
          final open = [if (run.planLive) for (var i = 0; i < run.todo.length; i++) if (!run.todoDone.contains(i)) i];
          // "Creating a simple to-do list note." with no tool call: the work was only announced (any step, tools on).
          final announced = _stepTools != null && Announce.only(r.text);
          if (run.wrapUpAt >= 0 || run.nudges >= 3 || AppState._waitsOnUser(r.text)) return null;
          if (!(open.isNotEmpty || announced || (run.step > 1 && AppState._promisesMore.hasMatch(AppState._tailOf(r.text))))) return null;
          run.nudges++;
          return (
            note: open.isNotEmpty
                ? '# Your checklist still has open steps\n${AppState._todoText(run)}\n'
                    'Do not stop or ask whether to continue: do the next open step now with your tools. '
                    'Only stop if you are truly blocked or need something only the user can give (then say exactly what), '
                    'or if a step is no longer needed (mark it done).'
                : '# You said you would do more but stopped\nDo it now with your tools, without asking whether to continue. '
                    'If it is all finished, reply with the final result instead.',
            hold: true,
          );
        },
        // Finish check: a long build re-reads the request, tests, and fixes unfinished parts before its final reply.
        (r) async {
          if (run.wrapUpAt >= 0 || run.verified || AppState._waitsOnUser(r.text)) return null;
          if (!((run.planLive && run.todo.length >= 3) || run.writes >= 3)) return null;
          run.verified = true;
          run.nextCall = (RunStatus.revising, const {});
          return (note: await app._finishCheckNote(run), hold: true);
        },
        // CB-39: a file card and a few words, for a request that never asked for a file: one round to answer in the chat.
        (r) async {
          if (r.blank || r.cutOff || run.wrapUpAt >= 0 || AppState._waitsOnUser(r.text)) return null;
          final ask = lastUserText ?? '';
          if (ask.startsWith(botWakeMark)) return null;
          if (!InlineAnswer.needsInline(reply: _prefix + r.text, userText: ask, rounds: run.inlineFixes)) return null;
          run.inlineFixes++;
          run.nextCall = (RunStatus.revising, const {});
          return (note: InlineAnswer.note, hold: false);
        },
        // The reply's cards must be valid (typed Hark-style blocks checked against their schema); one fix round.
        (r) async {
          if (r.blank || r.cutOff || run.formatFixes >= 1) return null;
          // What the app fixes by itself (a markdown table, a card left open at the end) never costs a model call:
          // commit() repairs it. Only what needs the model goes back.
          // CB-10: checked on the whole reply, a continuation joined to the part it continues.
          final problems = ReplySchema.problems(ReplySchema.repair(_prefix + r.text));
          if (problems.isEmpty) return null;
          run.formatFixes++;
          run.nextCall = (RunStatus.revising, const {});
          return (note: ReplySchema.fixNote(problems), hold: false);
        },
        // Launch hardening H-1: a final reply plainly in another language than the user's (a Somali question answered in
        // English after English web pages) goes back once to be written in their language. Never when they asked for a
        // translation or another language, and never when the app's reply language is set by hand.
        (r) async {
          // A continuation (_prefix) is not rewritten: its first part is already on screen.
          if (r.blank || r.cutOff || _prefix.isNotEmpty || run.wrapUpAt >= 0 || _langFixes >= 1 || app.replyLanguage != 'auto') return null;
          final ask = lastUserText ?? '';
          if (ask.startsWith(botWakeMark)) return null;
          final lang = userLang;
          if (lang == null || !ReplyLang.mismatch(r.text, lang, userText: [ask, ...run.brief.changes].join('\n'))) return null;
          _langFixes++;
          run.nextCall = (RunStatus.revising, const {});
          return (note: ReplyLang.fixNote(lang), hold: false);
        },
      ];

  // ---------------------------------------------------------------- tools

  @override
  List<List<int>> parallel(List<ToolCall> calls) {
    final broken = <int>{};
    for (var i = 0; i < calls.length; i++) {
      try {
        final d = jsonDecode(calls[i].arguments.trim().isEmpty ? '{}' : calls[i].arguments);
        if (d is! Map) broken.add(i);
      } catch (_) {
        broken.add(i);
      }
    }
    final out = ParallelPlan.batches([for (final c in calls) c.name], broken: broken).where((b) => b.length > 1).toList();
    for (final group in out) {
      final (k, a) = AppState.groupStatus([for (final j in group) calls[j]]);
      run.show(RunPhase.tool, k, a);
      for (final j in group) {
        run.running[calls[j].id] = (k, a);
      }
      final gr = _GroupRow(RunStep(RunStatus.english(k, a)), group.length);
      app._addStep(run, gr.row);
      app._bgLine(run);
      for (final j in group) {
        _groupRows[calls[j].id] = gr;
      }
    }
    if (out.isNotEmpty) app._notify();
    return out;
  }

  static const _inline = {'todo', 'more_tools', 'say'};

  @override
  Future<Map<String, dynamic>?> approvalFor(ToolCall call, Map<String, dynamic> args) async {
    if (_inline.contains(call.name)) return null;
    final g = await app.toolGate(call.name, args, convId);
    _gates[call.id] = g;
    if (g.ask == null) return null;
    run.show(RunPhase.approval, RunStatus.approval);
    app._notify();
    return g.toInterrupt(call.name);
  }

  @override
  Future<ToolApproval> answer(ToolCall call, Map<String, dynamic> args, Map<String, dynamic> data) async {
    final g = _gates[call.id] ?? await app.toolGate(call.name, args, convId);
    _gates[call.id] = g;
    if (g.ask == null) return ToolApproval.yes(args: args);
    final ok = await app.presentApproval(g, call.name, args, convId);
    if (!ok) return ToolApproval.no(g.refusal);
    return ToolApproval.yes(args: app.approvedArgs(g, call.name, args));
  }

  @override
  Future<String> runTool(ToolCall tc, Map<String, dynamic> args, {Object? approved}) async {
    if (tc.name == 'todo') {
      // Ticks add up: a resent list keeps the ticks of unchanged steps. Only a newly finished step earns a fresh "carry
      // on" budget, and the loop guard sees these calls like any other.
      final progressed = Checklist.apply(run.todo, run.todoDone, steps: args['steps'], doneArg: args['done']);
      if (progressed) run.nudges = 0;
      run.planLive = true;
      return AppState._todoText(run);
    }
    if (tc.name == 'more_tools') {
      _allTools = true;
      app._allToolsNow.add(convId);
      return 'Every tool is available now. Carry on with the task.';
    }
    if (tc.name == 'say') {
      run.quietSteps = 0;
      final said = '${args['text'] ?? ''}'.trim();
      if (said.isNotEmpty) {
        final sm = ChatMessage(id: _uuid.v4(), role: 'assistant', content: said)..animateIn = true;
        list.add(sm);
        run.wrote.add(sm.id);
        Future<void>.delayed(const Duration(seconds: 2), () => sm.animateIn = false);
        await app._save(convId, sm);
      }
      app._notify();
      return 'Shown to the user. Keep working.';
    }
    final phoneStep = (tc.name.startsWith('phone_') && tc.name != 'phone_settings') || tc.name == 'open_app';
    if (phoneStep) {
      run.phone = true;
      run.browsing = true; // the model that can see drives, like the browser
      SystemTools.wantShots = app.canSee;
      SystemTools.pendingShot = null;
    }
    if (BrowserAgent.names.contains(tc.name) || BrowserJobs.names.contains(tc.name)) {
      run.browsing = true;
      BrowserAgent.I.onStopTask = () => app.stopRun(run);
      app._browserConv = convId;
      if (app._liveWantsWindow && app._liveTaskConvs.contains(convId) && tc.name != 'browser_open') {
        app._liveWantsWindow = false;
        BrowserAgent.I.openWindow();
      }
    }
    // One row in the live step list per step; reads running together share the group's row.
    if (!_groupRows.containsKey(tc.id)) {
      final (k, a) = app._toolStatus(tc.name, args);
      run.show(RunPhase.tool, k, a);
      run.running[tc.id] = (k, a);
      final row = RunStep(RunStatus.english(k, a));
      _rows[tc.id] = row;
      app._addStep(run, row);
      app._bgLine(run);
    }
    run.quietSteps++;
    app._notify();
    _t0[tc.id] = DateTime.now();
    final usedGroup = ToolScope.groupOf(tc.name);
    if (usedGroup.isNotEmpty) (app._convGroups[convId] ??= <String>{}).add(usedGroup);
    run.pendingCalls.add(tc.id);
    try {
      var g = _gates.remove(tc.id);
      if (g == null || (g.ask != null && approved == null)) {
        // Early reads (no approval asked) and calls the core runs directly: the gate decides here.
        g = await app.toolGate(tc.name, args, convId);
        if (g.ask != null && approved == null) {
          final ok = await app.presentApproval(g, tc.name, args, convId);
          if (!ok) return g.refusal;
        }
      }
      if (g.blocked != null) return g.blocked!;
      // CB-38: a second read-only browser task is not started; weak searches past the budget carry a stop note.
      final capped = run.search.before(tc.name, args);
      if (capped != null) return capped;
      return run.search.after(tc.name, await _recovering(g, tc, args));
    } finally {
      run.pendingCalls.remove(tc.id);
    }
  }

  /// Runs a passed call; a read-only call that hit a network hiccup gets one quiet retry before the agent sees an error.
  Future<String> _recovering(ToolGate g, ToolCall tc, Map<String, dynamic> args) async {
    Future<String> once() async {
      TaskBubble.I.stepStarted(convId, tc.name, app._toolLabel(tc.name, args));
      try {
        final out = await app.runGated(g, tc.name, args, callId: tc.id, convId: convId);
        return out.trim().isEmpty ? 'Done (the tool returned nothing to show).' : out;
      } on TimeoutException {
        return 'Error: ${tc.name} took too long and was stopped. Try once more, or take another way.';
      } catch (e) {
        var msg = '$e';
        if (msg.length > 600) msg = '${msg.substring(0, 600)}…';
        return 'Error in ${tc.name}: $msg\nRead this, fix the inputs or try another way. Do not repeat the exact same call. '
            'If it cannot work, tell the user plainly in one line.';
      } finally {
        TaskBubble.I.stepFinished(convId, tc.name);
      }
    }

    var out = await once();
    if (ToolRecovery.retryOnce(tc.name, out)) {
      await Future<void>.delayed(const Duration(milliseconds: 800));
      out = await once();
    }
    return out;
  }

  @override
  Future<void> toolDone(ToolCall tc, Map<String, dynamic> args, String output) async {
    // R2 item 1: the line never keeps a finished step's label. Another step still running shows instead; when the
    // last call of this reply is in, the next request goes out at once.
    run.running.remove(tc.id);
    run.openCalls.remove(tc.id);
    if (!run.cancelled) {
      if (run.running.isNotEmpty) {
        final (k, a) = run.running.values.last;
        run.show(RunPhase.tool, k, a);
      } else if (run.openCalls.isEmpty) {
        run.show(RunPhase.waiting, RunStatus.waiting);
      }
    }
    run.guard.record(tc.name, tc.arguments, output);
    if (!_inline.contains(tc.name)) {
      run.toolCalls++;
      run.failsInRow = ToolRecovery.isError(output) ? run.failsInRow + 1 : 0;
      // What actually happened, so a completion claim can be checked against it.
      run.evidence.add(Evidence(tool: tc.name, ok: !ToolRecovery.isError(output), summary: output.length <= 240 ? output : output.substring(0, 240)));
    }
    final row = _rows.remove(tc.id);
    if (row != null) {
      row.ended = DateTime.now();
      row.failed = AppState.stepFailed(output);
    } else {
      final gr = _groupRows.remove(tc.id);
      if (gr != null) {
        gr.left--;
        if (!AppState.stepFailed(output)) gr.anyOk = true;
        if (gr.left <= 0) {
          gr.row.ended = DateTime.now();
          gr.row.failed = !gr.anyOk;
        }
      }
    }
    final t0 = _t0.remove(tc.id);
    final t = tracer;
    if (t != null && !_inline.contains(tc.name)) {
      BotTraces.I.step(t.id, tc.name, tc.arguments, output, ms: t0 == null ? 0 : DateTime.now().difference(t0).inMilliseconds);
    }
    final phoneStep = (tc.name.startsWith('phone_') && tc.name != 'phone_settings') || tc.name == 'open_app';
    if (phoneStep && SystemTools.pendingShot != null) {
      app._phoneShot = SystemTools.pendingShot;
      app._phoneShotCall = tc.id;
      SystemTools.pendingShot = null;
    }
    if (AppState._writesWork(tc.name, args) && !output.startsWith('Error')) {
      run.writes++;
      run.writesSinceCheckpoint++;
      run.nudges = 0;
      run.planLive = true;
      final p = '${args['path'] ?? args['file'] ?? ''}'.trim();
      if (p.isNotEmpty && run.touched.length < 200) run.touched.add(p);
    }
    final content = _inline.contains(tc.name) ? output : ToolRecovery.withHint(tc.name, output);
    final tm = ChatMessage(id: _uuid.v4(), role: 'tool', content: content, toolCallId: tc.id, name: tc.name);
    list.add(tm);
    run.wrote.add(tm.id);
    app._notify();
    await app._save(convId, tm);
    // A picture, sound or video a tool made (IMAGE_SAVED ...) is kept in the account for the user's other phones.
    if (RegExp(r'^(IMAGE|AUDIO|VIDEO|FILE)_SAVED ').hasMatch(output)) {
      unawaited(MediaStore.I.keepAllIn(output).catchError((_) {}));
    }
  }

  @override
  String brokenText(Reply r) => r.cutOff
      ? 'Error: this call was cut off because it was too long for one reply, so nothing was done. '
          'Split it: write_file the first part (about 150 lines), then append_file the rest in parts of the same size.'
      : 'Error: the arguments of this call were not valid JSON, so nothing was done. Send it again with valid JSON.';
}
