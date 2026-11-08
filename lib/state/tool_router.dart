// Tool dispatch and approvals: browser jobs, runToolWithApproval, risk checks, ask-user, project/site tools.
// Split out of app_state.dart (no behaviour change). Fields stay on AppState.
part of '../app_state.dart';

extension AppStateTools on AppState {
  void _wireBrowserJobs() {
    final j = BrowserJobs.I;
    // A bot's browser task thinks on the bot's own model (owner 2026-11-07, BotBrowserModel); SubMac's on SubMac's.
    j.botOf = (convId) => Bots.I.byConv(convId)?.id ?? '';
    // With no screen (started by an alarm, or SubMac in the background) the browser opens off-screen web views, and
    // falls back to read-only page reads when those cannot start (owner 2026-11-07, docs/bot-autonomy.md).
    BrowserAgent.noScreen = () => headless || !appVisible;
    j.llm = (job, payload, tools) async {
      final pick = BotBrowserModel.of(job.botId.isEmpty ? null : Bots.I.byId(job.botId), submacRef);
      final own = pick.byok;
      if (own != null) {
        final msgs = pick.sees ? payload : BotBrowserModel.withoutImages(payload);
        final r = await BotBrowserModel.byokStep(own, msgs, tools);
        final bot = Bots.I.byId(job.botId);
        if (bot != null && r.tokens > 0) bot.addTokens(r.tokens);
        return r;
      }
      final route = pick.submac ?? submacRef;
      final run = _jobRuns[job.id] ??= AgentRun(convId: job.convId, side: true, title: 'Browser');
      run.cancelled = job.cancelled;
      job.steerHook = () => run.client?.cancelForSteer();
      job.llmCancel = run.stop;
      job.wasSteered = () => run.client?.steered == true;
      final asst = ChatMessage(id: '', role: 'assistant', content: '');
      try {
        return await _streamResilient(run: run, route: route, payload: payload, tools: tools, asst: asst);
      } finally {
        if (job.finished) {
          _jobRuns.remove(job.id);
          TaskBubble.I.runEnded(job.convId);
        }
      }
    };
    j.onEnded = (job) {
      _jobRuns.remove(job.id);
      // A stopped or finished task never leaves its sign-in or code form behind.
      if (!j.running.any((o) => o.convId == job.convId)) {
        for (final a in asks.where((a) => a.convId == job.convId && (a.kind == 'login' || a.kind == 'login_confirm' || a.site == 'browser')).toList()) {
          answerAsk(a, null);
        }
      }
      // Another job of the same chat still drives the screen: its owner stays.
      if (!j.running.any((o) => o.convId == job.convId)) TaskBubble.I.runEnded(job.convId);
    };
    j.runTool = (job, name, args, callId) {
      _browserConv = job.convId;
      return runToolWithApproval(name, args, callId: callId, convId: job.convId);
    };
    // Every route behind `submac` can see pictures (PLAN 1.1), so screenshots always go along.
    j.canSee = () => canSee;
    j.say = (convId, text) => unawaited(_sayIn(convId, text));
    BrowserAgent.I.approveDialog = (message, host, job) async {
      final conv = j.jobs.where((x) => x.id == job).firstOrNull?.convId ?? _browserConv ?? currentId;
      final kind = BotTrust.kindOf('browser_dialog', message);
      if (!FullAccess.shouldAsk(level: fullAccess ? BotTrust.levelTrusted : BotTrust.levelNew, kind: kind, tool: 'browser_dialog', fullAccess: FullAccess.I.on)) {
        return true;
      }
      final req = ActionRequest(
        title: '${host.isEmpty ? 'The site' : host} asks: OK?',
        body: message.length > 300 ? '${message.substring(0, 300)}…' : message,
        detail: message,
        confirmLabel: 'OK',
      )..kind = kind;
      if (conv != null && appVisible && currentId == conv && j.cardVisible(conv)) {
        return (await j.askInline(conv, title: req.title, detail: req.body, money: kind == 'money')).ok;
      }
      return _confirmInApp(req, conv);
    };
    j.userRules = () {
      final sb = StringBuffer();
      if (howToRespond.trim().isNotEmpty) sb.writeln('How they want things done: ${howToRespond.trim()}');
      if (aboutYou.trim().isNotEmpty) sb.writeln('About them: ${aboutYou.trim()}');
      return sb.toString().trim();
    };
    j.addListener(() {
      for (final r in runs.where((r) => !r.side)) {
        final line = BrowserJobs.I.lineFor(r.convId);
        if (line != null) r.show(RunPhase.tool, line);
      }
      // A job started with wait:false ended while nobody was waiting: tell the user what it found.
      for (final job in BrowserJobs.I.jobs) {
        if (job.live || job.reported) continue;
        job.reported = true;
        // Team work's browser jobs report to the team turn that started them, never into a chat or a notification
        // of their own (they used to report in the member's private chat).
        if (TeamKey.isKey(job.convId)) continue;
        final waiting = runs.any((r) => r.convId == job.convId && !r.side);
        if (!waiting) {
          final msg = switch (job.status) {
            'done' => job.result,
            'failed' => 'The browser task couldn\'t finish: ${job.result}',
            'needs' => job.question,
            'checkin' => 'The browser task has been working ${job.elapsed()}: ${job.now}. Say "continue" to keep it going.',
            _ => '',
          };
          if (msg.isNotEmpty) {
            unawaited(_sayIn(job.convId, msg));
            // A background job (started by a scheduled task) reaches the user the way a finished task does, even
            // when the run that started it has already ended.
            if (job.unattended) {
              unawaited(SystemBridge.I.notify(
                  id: job.convId.hashCode & 0x7ffffff,
                  title: 'Scheduled: browser task',
                  body: msg.length > 300 ? '${msg.substring(0, 300)}…' : msg,
                  kind: 'scheduled',
                  payload: 'conv/${job.convId}'));
            }
          }
        }
      }
      if (BrowserJobs.I.running.isEmpty && !runs.any((r) => r.browsing)) BrowserAgent.I.taskEnded();
      _throttledNotify();
    });
  }

  /// A short assistant line in a chat (progress from a browser task).
  Future<void> _sayIn(String convId, String text) async {
    final list = _lists[convId];
    if (list == null || text.trim().isEmpty) return;
    final sm = ChatMessage(id: _uuid.v4(), role: 'assistant', content: text.trim())..animateIn = true;
    list.add(sm);
    Future<void>.delayed(const Duration(seconds: 2), () => sm.animateIn = false);
    _notify();
    await _save(convId, sm);
  }

  Future<String> runToolWithApproval(String name, Map<String, dynamic> args, {String? callId, String? convId}) async {
    // Every screen step (phone, WhatsApp, browser) is seen by the task bubble, whoever runs it (a task, a bot, Live).
    TaskBubble.I.stepStarted(convId, name, _toolLabel(name, args));
    try {
      final out = await _runToolInner(name, args, callId: callId, convId: convId);
      return out.trim().isEmpty ? 'Done (the tool returned nothing to show).' : out;
    } on TimeoutException {
      return 'Error: $name took too long and was stopped. Try once more, or take another way.';
    } catch (e) {
      var msg = '$e';
      if (msg.length > 600) msg = '${msg.substring(0, 600)}…';
      return 'Error in $name: $msg\nRead this, fix the inputs or try another way. Do not repeat the exact same call. '
          'If it cannot work, tell the user plainly in one line.';
    } finally {
      TaskBubble.I.stepFinished(convId, name);
    }
  }

  /// The old single path (check, ask, run) for callers outside the agent core: Live, the browser sub-agent's page
  /// tools, a Run button in a code block. The agent core asks through Genkit interrupts instead ([toolGate] then
  /// [presentApproval] then [runGated]).
  Future<String> _runToolInner(String name, Map<String, dynamic> args, {String? callId, String? convId}) async {
    final g = await toolGate(name, args, convId);
    if (g.blocked != null) return g.blocked!;
    if (g.ask != null) {
      final ok = await presentApproval(g, name, args, convId);
      if (!ok) return g.refusal;
    }
    return runGated(g, name, args, callId: callId, convId: convId);
  }

  /// Decides, without running anything, what a tool call needs: refused outright (a bot's switched-off power, an app
  /// it was not given, a read-only app), the user's OK first (an [ToolGate.ask] the approval card shows), or nothing.
  Future<ToolGate> toolGate(String name, Map<String, dynamic> args, String? convId) async {
    final scoped = Bots.I.byConv(convId);
    if (scoped != null && !BotPowers.allowed(scoped.effectiveOff, name)) {
      if (scoped.sandbox && BotPowers.allowed(scoped.powersOff, name)) {
        return ToolGate.blocked('Not allowed: ${scoped.name}\'s knowledge sandbox is on, so there is no web or browser. Answer only from your '
            'knowledge (knowledge_search), or say plainly that it is not in what you were given.');
      }
      return ToolGate.blocked('Not allowed: the owner switched off "${BotPowers.labels[BotPowers.groupOf(name)]}" for ${scoped.name}. '
          'Do not try it another way. Say what you would need, or hand it to someone who can.');
    }
    if (scoped != null && !_botAppOk(scoped, name, args)) {
      final need = Bots.I.appsNeeded(scoped).map((a) => a.name).join(', ');
      return ToolGate.blocked('Not set up: this app is not one of ${scoped.name}\'s apps${need.isEmpty ? '' : ' (still to connect: $need)'}. '
          'Do not try it another way. Tell the owner in one line which app you need and that they can add or connect it in your settings > Apps.');
    }
    // Read-only apps (plan 4): a change is refused outright, even with Full access on.
    final roMsg = _readOnlyBlock(name, args);
    if (roMsg != null) return ToolGate.blocked(roMsg);
    // CB-42: a send never drives the mail app, and taps or typing in another app wait for the draft's OK in the chat.
    final outMsg = _outboundBlock(name, args, convId);
    if (outMsg != null) return ToolGate.blocked(outMsg);
    final worker = Bots.I.byConv(convId);
    // Team work runs under its team key, which names its team (its trust rule, and where its approval card shows).
    final officeId = _officeCtx[convId] ?? TeamKey.officeOf(convId);
    final office = officeId.isEmpty ? null : Offices.I.byId(officeId);
    // WhatsApp: every message, file and call to someone needs the user's OK, even with Full access on or a Trusted bot,
    // unless the user trusted this bot for WhatsApp (or its office is trusted). Plan 5.2 keeps this rule as it was.
    if (WhatsAppTools.names.contains(name)) {
      final req = WhatsAppTools.approvalFor(args);
      if (req == null) return ToolGate.none(whatsapp: true);
      // Owner 2026-11-08: a bot and a team member are people, not an app workflow. No approval card: they send, and
      // their brief tells them to ask the owner in words first when the message is not already their clear
      // instruction. The owner's own chat keeps the card (every WhatsApp message to someone is shown before it goes).
      if (worker != null) return ToolGate.none(whatsapp: true);
      req.kind = 'send';
      if (FullAccess.I.on) return ToolGate.none(whatsapp: true);
      return ToolGate(ask: req, kind: 'send', whatsapp: true, worker: worker, office: office,
          refusal: AppState._notApproved(req, 'Not sent: the user did not approve this WhatsApp ${args['action']} (or did not answer in time). '
              'Do not retry it or try another way; ask what they would like instead, or note it as waiting on them.'));
    }
    // Owner 2026-11-08: bots and team members are people, not an approval workflow. No gate, no card, no "say start":
    // they decide and act, and their brief says to ask the owner in words first for money, sending as them, deleting or
    // a big account change. SubMac's own chat keeps its card for the actions it takes for the owner.
    if (worker != null) return ToolGate.none();
    // SubMac's own chat (the owner's, or a scheduled run of theirs): it follows Settings > Trust level ("full" =
    // Trusted): a card first for the action the owner asked it to take.
    final risk = await _riskFor(name, args);
    if (risk == null) return ToolGate.none();
    var kind = BotTrust.kindOf(name, '${risk.title} ${risk.detail}', destructive: risk.destructive);
    // A press on a payment page is money, whatever its button says ("Continue"): money always asks.
    if (BrowserAgent.names.contains(name) && BrowserAgent.I.snapFor(BrowserAgent.jobNow).moneyPage) kind = 'money';
    // SubMac's own settings that change how it works always ask (Full access, a trusted team or bot included).
    if (name == 'app_settings') kind = FullAccess.alwaysAskKind;
    final level = fullAccess ? BotTrust.levelTrusted : BotTrust.levelNew;
    // Full access (Settings) acts without asking; money always asks. Small changes in SubMac's own space never ask.
    final ask = FullAccess.shouldAsk(level: level, kind: kind, tool: name, fullAccess: FullAccess.I.on) &&
        (office?.trust != 'trusted' || kind == 'money' || kind == FullAccess.alwaysAskKind);
    final field = kind == 'send' ? AppState._editField(name, args) : null;
    final req = field == null ? risk : risk.withEdit(field.$2);
    req.kind = kind;
    // A scheduled run has nobody to answer a press that needs the user's OK: it is refused at once, with the reason,
    // instead of waiting minutes for an answer that cannot come.
    if (ask && BrowserAgent.names.contains(name) && Zone.current[#smUnattended] == true) {
      return ToolGate.blocked('Stopped: "${req.title}" needs the user\'s OK and nobody is watching (this is a scheduled run). '
          'Do not try another way. Finish with success:false and say in one line exactly what needs their approval.');
    }
    if (!ask) return ToolGate.none(field: field, req: req);
    return ToolGate(ask: req, kind: kind, field: field, worker: worker, office: office,
        refusal: AppState._notApproved(req, 'The user said no to this action. Do not retry it; ask what they would like instead.'));
  }

  /// Shows the approval for [g] where the user can answer it: a bot working in the background asks from a notification;
  /// outside SubMac the floating bubble asks; the browser card asks inline; otherwise the in-app sheet. True = approved.
  Future<bool> presentApproval(ToolGate g, String name, Map<String, dynamic> args, String? convId) async {
    final req = g.ask;
    if (req == null) return true;
    final worker = g.worker;
    final kind = g.kind;
    bool ok;
    if (worker != null && !(appVisible && currentId == convId)) {
      // A bot working in the background never pulls the app up: it asks from a notification and waits.
      ok = await _askApproval(worker, g.office, req, tool: name, convId: convId);
      return ok;
    }
    if (confirmCallback == null) {
      // No screen at all (SubMac started by an alarm for its own scheduled task): nobody can answer, so it is refused
      // at once and one notification says what still needs the owner's OK (same rule as a bot's run, bg_runs.dart).
      if (convId != null && unattendedRun(convId)) {
        g.refusal = OutboundGuard.noAnswer(readOnly: _readOnlyTask(name, convId));
        unawaited(_bgNeeds(convId, req.title));
      }
      return false;
    }
    // CB-42 / CB-44: an approval nobody answers no longer holds the task forever. A read-only task (look up, compare,
    // price) waits a minute and then answers from what it found; any other task ends with what is still waiting.
    final readOnly = _readOnlyTask(name, convId);
    final limit = OutboundGuard.waitFor(readOnly: readOnly);
    final asked = DateTime.now();
    if (!g.whatsapp && BrowserAgent.names.contains(name) && convId != null && appVisible && currentId == convId && BrowserJobs.I.cardVisible(convId)) {
      // The browser card is on screen: the approval appears on it, as an inline form (same rules, same answer).
      final r = await BrowserJobs.I.askInline(convId, title: req.title, detail: req.detail, money: kind == 'money', limit: limit);
      ok = r.ok;
      req.allowAlways = r.always;
      if (!ok && DateTime.now().difference(asked) >= limit) req.timedOut = true;
    } else {
      // Outside SubMac while this chat drives the screen: ask in the floating bubble. Otherwise the question needs
      // the screen: bring SubMac up if it's in the background (floating Live), with a notification that opens it.
      Future<bool> show() async => await TaskBubble.I.confirm(req, convId) ?? await _confirmInApp(req, convId);
      ok = await show().timeout(limit, onTimeout: () {
        req.timedOut = true;
        TaskBubble.I.dropConfirm(req);
        confirmQueue.closeFor(req);
        return false;
      });
    }
    if (req.timedOut) {
      g.refusal = OutboundGuard.noAnswer(readOnly: readOnly);
      return false;
    }
    // A send the user approved in the chat (they saw its words): taps and typing for this request may go on.
    if (ok && kind == 'send' && convId != null) OutboundGuard.approve(convId, _goalOf(convId));
    if (worker != null) unawaited(Bots.I.recordAnswer(worker, approved: ok, edited: req.edit?.edited == true || req.wantsChange));
    // "Allow always" turns on Full access; money never does (WhatsApp's Allow always is honoured the same way).
    if (ok && req.allowAlways && kind != 'money' && kind != FullAccess.alwaysAskKind) unawaited(FullAccess.I.set(true));
    return ok;
  }

  /// The arguments as the user approved them (their edit to the message, when they made one).
  Map<String, dynamic> approvedArgs(ToolGate g, String name, Map<String, dynamic> args) {
    final e = g.ask?.edit;
    if (g.whatsapp) {
      if (e != null && e.edited && e.value.trim().isNotEmpty && e.value.trim() != '${args['message'] ?? ''}'.trim()) {
        return {...args, 'message': e.value.trim()};
      }
      return args;
    }
    final field = g.field;
    if (field != null && e != null && e.edited && e.value.trim().isNotEmpty) return AppState._withEdit(name, args, field.$1, e.value.trim());
    return args;
  }

  /// Runs a call whose gate is passed (approved, or no approval needed). [args] are the approved arguments.
  Future<String> runGated(ToolGate g, String name, Map<String, dynamic> args, {String? callId, String? convId, Map<String, dynamic>? original}) async {
    final before = original ?? args;
    final edited = g.ask?.edit?.edited == true ? approvedArgs(g, name, before) : args;
    if (g.whatsapp) {
      final waEdited = '${edited['message'] ?? ''}' != '${before['message'] ?? ''}' ? '${edited['message']}'.trim() : '';
      final wasVisible = appVisible;
      final out = await WhatsAppTools.execute(edited, convId: convId, afterUi: () async {
        if (!wasVisible) return;
        await Future<void>.delayed(const Duration(milliseconds: 700));
        await SystemBridge.I.bringToFront();
      });
      return waEdited.isEmpty ? out : '(The user edited the message before approving. What went: "$waEdited")\n$out';
    }
    final field = g.field;
    final changed = field != null && !identical(edited, before) && jsonEncode(edited) != jsonEncode(before);
    final out = await _runToolAfterChecks(name, edited, callId: callId, convId: convId);
    if (changed) {
      final v = g.ask?.edit?.value.trim() ?? '';
      return '(The user edited the text before approving. What went: "$v")\n$out';
    }
    return out;
  }

  /// The inline ask, one at a time: a thin card under the newest message of the task's own chat (owner,
  /// 2026-10-31), never a sheet. It is skipped (or folded away) when that chat's task is stopped.
  Future<bool> _confirmInApp(ActionRequest req, String? convId) {
    final cb = confirmCallback;
    if (cb == null) return Future<bool>.value(false);
    return confirmQueue.run(convId, token: req, () async {
      // Nobody answered while it waited its turn: the task has already moved on.
      if (req.timedOut) return false;
      // The card lives under the messages of the chat it belongs to, so it never needs a "from" line.
      req.convId ??= convId;
      req.where = '';
      // CB-42: SubMac is in the background (another app is in front, e.g. one a task opened): a high-priority
      // notification says an OK is waiting and opens SubMac on the sheet, so the ask is never hidden.
      int? note;
      if (!appVisible) {
        note = 9600 + ((convId ?? 'none').hashCode % 90).abs();
        await OutboundGuard.notify(id: note, title: 'SubMac needs your OK', body: req.title, payload: convId == null ? '' : 'conv/$convId');
        await SystemBridge.I.bringToFront();
      }
      HapticFeedback.lightImpact(); // SubHaptics.attention (part file)
      try {
        return await cb(req);
      } finally {
        if (note != null) unawaited(OutboundGuard.cancelNotice(note));
      }
    });
  }

  /// The request this chat's task is working on: the user's newest message there.
  String _goalOf(String convId) {
    final list = _lists[convId];
    if (list == null) return '';
    for (final m in list.reversed) {
      if (m.role == 'user') return m.content;
    }
    return '';
  }

  /// The task behind this approval only looks things up (its browser task's goal, or the chat's request).
  bool _readOnlyTask(String name, String? convId) {
    if (BrowserAgent.names.contains(name)) {
      final id = BrowserAgent.jobNow;
      final job = id == null ? null : BrowserJobs.I.jobs.where((j) => j.id == id).firstOrNull;
      if (job != null) return PageRisk.readOnlyGoal(job.goal);
    }
    return convId != null && PageRisk.readOnlyGoal(_goalOf(convId));
  }

  /// CB-42: why this call may not run for a send request, or null. A send never opens the mail app to type and press
  /// Send in it; and until the user approved the draft in this chat, taps and typing in another app wait.
  String? _outboundBlock(String name, Map<String, dynamic> args, String? convId) {
    if (convId == null || convId.isEmpty) return null;
    if (name != 'open_app' && name != 'phone_tap' && name != 'phone_type') return null;
    final goal = _goalOf(convId);
    if (!OutboundGuard.isSendGoal(goal)) return null;
    if (name == 'open_app') {
      if (!OutboundGuard.isMailApp('${args['name'] ?? ''}')) return null;
      return OutboundGuard.mailAppNote(connected: ConnectorCatalog.connectedEmails().isNotEmpty);
    }
    if (OutboundGuard.isApproved(convId, goal)) return null;
    return OutboundGuard.draftFirstNote;
  }

  /// CB-42: an email with no mail account connected is a draft card in the chat. Its Send button opens the phone's mail
  /// app with everything filled in (a mailto: compose intent); the user presses send there.
  Future<String> _emailDraftTool(Map<String, dynamic> a, String? convId) async {
    final body = '${a['body'] ?? ''}'.trim();
    if (body.isEmpty) return 'Error: no body. Write the whole email in "body".';
    final card = OutboundGuard.draftCard(to: '${a['to'] ?? ''}', cc: '${a['cc'] ?? ''}', subject: '${a['subject'] ?? ''}', body: body);
    final cid = convId ?? currentId ?? '';
    if (_lists[cid] == null) {
      return 'Show this draft to the user in your reply, exactly as a ```draft block, and say its Send button opens their '
          'mail app filled in:\n```draft\n$card\n```';
    }
    OutboundGuard.shown(cid, _goalOf(cid), card);
    await _sayIn(cid, '```draft\n$card\n```');
    return 'The draft is on the user\'s screen as a card in this chat. Its Send button opens their mail app with '
        'everything filled in, and they press send there themselves. Do not open the mail app or any other app, and do '
        'not tap or type anything to send it. Do not repeat the draft: reply in one short line that it is ready above.';
  }

  Future<String> _runToolAfterChecks(String name, Map<String, dynamic> args, {String? callId, String? convId}) async {
    final out = await _runToolAfterChecksInner(name, args, callId: callId, convId: convId);
    if (convId != null && const {'write_file', 'append_file', 'edit_file'}.contains(name) && !out.startsWith('Error')) {
      final p = '${args['path'] ?? ''}'.trim();
      if (p.isNotEmpty) _lastMade[convId] = p;
    }
    return out;
  }

  Future<String> _runToolAfterChecksInner(String name, Map<String, dynamic> args, {String? callId, String? convId}) async {
    if (AppState.liveTaskToolNames.contains(name)) return _liveTaskTool(name, args);
    if (AppState._screenActs.contains(name) && BrowserAgent.I.windowOpen && BrowserJobs.I.running.isNotEmpty && args['outside_browser'] != true) {
      // The web page lives in the in-app browser; phone_* acts on the user's real screen.
      return 'Not done: a browser task is working in the browser on screen, and $name would touch the user\'s real screen, '
          'not the web page. For the page, steer it with browser_task_reply. Only if the user asked you to use another app on '
          'their phone: repeat this call with "outside_browser": true.';
    }
    // A bot's own schedule: the bot wakes for it and does the work itself (not a separate SubMac chat).
    if (name == 'schedule_task' && Bots.I.byConv(convId) != null) {
      return Scheduler.I.add('${args['task'] ?? ''}', '${args['when'] ?? ''}', '${args['repeat'] ?? 'none'}',
          watch: args['watch'] == true, bot: Bots.I.byConv(convId)!.id, inMinutes: int.tryParse('${args['in_minutes'] ?? ''}'));
    }
    if (SystemTools.names.contains(name)) return SystemTools.execute(this, name, args);
    if (SetupTools.names.contains(name)) return SetupTools.execute(this, name, args);
    if (MediaCoder.names.contains(name)) return MediaCoder.execute(name, args);
    if (AiModels.names.contains(name)) return AiModels.I.execute(name, args, callId: callId);
    if (MediaGen.names.contains(name)) return _mediaGenerate(args, convId);
    if (name == 'generate_image') return _generateImage(args, convId);
    if (name == 'generate_video') return _generateVideo(args, convId);
    if (name == 'ask_user') return _askUserTool(args, convId);
    if (name == OutboundGuard.draftTool) return _emailDraftTool(args, convId);
    if (name == 'sites') return _sitesTool(args);
    if (name == 'projects') return _projectsTool(args, convId);
    if (name == 'connect_app') return requestConnect('${args['app'] ?? ''}', why: '${args['why'] ?? ''}', convId: convId);
    if (Missions.names.contains(name)) return _missionTool(name, args, convId);
    if (Bots.names.contains(name)) return Bots.I.execute(name, args, convId);
    if (SkillLibrary.names.contains(name)) {
      final who = Bots.I.byConv(convId);
      return SkillLibrary.I.execute(name, args, who?.id ?? SkillLibrary.agent, who: who?.name ?? 'SubMac');
    }
    if (Offices.names.contains(name)) {
      final o = _officeCtx[convId] == null ? null : Offices.I.byId(_officeCtx[convId]!);
      final b = Bots.I.byConv(convId);
      if (o == null || b == null) return 'Error: office tools only work during office work.';
      return Offices.I.execute(name, args, o, b, job: AppStateAgentRunner.ocOfficeJob[convId]);
    }
    if (BrowserJobs.names.contains(name)) {
      final id = convId ?? currentId ?? '';
      return BrowserJobs.I.execute(name, args, id,
          // A scheduled task, or team work (no chat to answer in), has nobody to answer a check-in, so its browser
          // work runs unattended.
          unattended: _scheduledConvs.contains(id) || TeamKey.isKey(id), parentCancelled: () {
        final r = runs.where((r) => r.convId == convId && !r.side).firstOrNull;
        // A team member's turn has no chat run: its job lives as long as the turn.
        if (r == null) {
          final team = AppStateAgentRunner.teamLive[convId];
          return team == null || team();
        }
        return r.cancelled;
      });
    }
    if (BrowserAgent.names.contains(name)) {
      return BrowserAgent.I.execute(name, args, callId: callId, shots: canSee);
    }
    if (WebTools.names.contains(name)) return WebTools.execute(name, args);
    // A bot's memory call acts on the bot's own memory, never the owner's (known issue 2026-11-06).
    final botMem = Bots.I.byConv(convId) == null ? null : OcToolScope.botMemory(name, args);
    if (botMem != null) return Bots.I.execute(botMem.$1, botMem.$2, convId);
    if (MemoryStore.names.contains(name)) {
      final r = await memory.execute(name, args);
      _notify();
      return r;
    }
    if (PhoneTools.names.contains(name)) return PhoneTools.execute(name, args);
    if (DocTools.names.contains(name)) return DocTools.execute(name, args);
    if (DocMaker.names.contains(name)) return DocMaker.execute(name, args);
    if (LifeTools.names.contains(name)) return LifeTools.execute(name, args);
    if (CalcTools.names.contains(name)) return CalcTools.execute(name, args);
    if (BizTools.names.contains(name)) return BizTools.execute(name, args);
    if (HealthTools.names.contains(name)) return HealthTools.execute(name, args);
    if (CodeTools.names.contains(name)) return CodeTools.execute(name, args);
    if (ForgedTools.handles(name)) {
      return ForgedTools.execute(name, args, taken: {for (final t in _toolList()) '${(t['function'] as Map?)?['name']}'});
    }
    if (ConnectorTools.names.contains(name)) return ConnectorTools.execute(name, args);
    if (ConnectorCatalog.isConnectorTool(name)) return ConnectorCatalog.execute(name, args);
    if (name == 'apps_list_tools') return _appTools(args, bot: Bots.I.byConv(convId));
    if (name == 'apps_run_tool') {
      final t = _findMcpTool('${args['tool'] ?? ''}', '${args['app'] ?? ''}', bot: Bots.I.byConv(convId));
      if (t == null) return 'Error: no connected app has a tool called "${args['tool']}". Call apps_list_tools to see the exact names.';
      var a = args['arguments'];
      if (a is String) {
        try {
          a = jsonDecode(a);
        } catch (_) {}
      }
      try {
        return await McpClient.of(t.server).callTool(t.name, a is Map ? Map<String, dynamic>.from(a) : <String, dynamic>{});
      } catch (e) {
        return 'Error: ${t.server.name} said: $e';
      }
    }
    if (name.startsWith('mcp_')) {
      for (final t in mcpTools) {
        if (t.fnName == name) {
          try {
            return await McpClient.of(t.server).callTool(t.name, args);
          } catch (e) {
            return 'Error: ${t.server.name} said: $e';
          }
        }
      }
      return 'Error: that connector tool is not available right now.';
    }
    return AgentTools.execute(name, args);
  }

  /// Where the media a chat makes is saved (media providers, owner 2026-11-04): the owner's chats in media/, a bot's
  /// private chat in its own folder, team work in its team's folder, so a team's results stay with the team.
  Future<String> _mediaFolder(String? convId) async {
    final ws = await AgentTools.workspaceDir();
    if (TeamKey.isKey(convId)) {
      final o = Offices.I.byId(TeamKey.officeOf(convId));
      if (o != null) return MediaGen.folderFor(ws, teamFolder: TeamRun.folderOf(o));
    }
    final b = Bots.I.byConv(convId);
    return MediaGen.folderFor(ws, botFolder: b == null ? '' : Bots.botFolder(b));
  }

  /// The turn that called a tool was stopped (its chat's Stop, or its team work ended): long media jobs end with it.
  bool _callerStopped(String? convId) {
    final r = runs.where((r) => r.convId == convId && !r.side).firstOrNull;
    if (r != null) return r.cancelled;
    final team = AppStateAgentRunner.teamLive[convId];
    return team != null && team();
  }

  /// A long media job's progress on the calling chat's working line.
  void _mediaProgress(String? convId, String line) {
    for (final r in runs.where((r) => r.convId == convId && !r.side)) {
      r.show(RunPhase.tool, line);
    }
    _throttledNotify();
  }

  /// media_generate: the user's own media provider, called from the phone; the result is saved in the calling chat's
  /// folder and comes back as a card in that chat (or, for team work, under the member's team reply).
  Future<String> _mediaGenerate(Map<String, dynamic> args, String? convId) async {
    return MediaGen.I.generate(
      args,
      folder: await _mediaFolder(convId),
      workspace: await AgentTools.workspaceDir(),
      cancelled: () => _callerStopped(convId),
      progress: (line) => _mediaProgress(convId, line),
    );
  }

  Future<String> _generateImage(Map<String, dynamic> args, [String? convId]) async {
    final prompt = '${args['prompt'] ?? ''}'.trim();
    if (prompt.isEmpty) return 'Error: give a prompt that describes the picture.';
    if (!Cloud.features.value.image) {
      // No picture model on SubMac's server: the user's own image provider makes it (owner 2026-11-04, "no server
      // image model needed"), so "draw X" works with their key.
      if (MediaProviderStore.I.has(MediaKind.image)) {
        return MediaGen.I.generateImageCompat(args,
            folder: await _mediaFolder(convId), cancelled: () => _callerStopped(convId), progress: (line) => _mediaProgress(convId, line));
      }
      // Neither: say so, and name the ways that still work, so the agent still answers with a visual (owner 2026-11-04).
      return AgentTools.imageOffNote;
    }
    try {
      final bytes = await Cloud.image(prompt, size: TurnVisuals.sizeFor(args));
      final ws = await AgentTools.workspaceDir();
      final dir = Directory('$ws/media');
      await dir.create(recursive: true);
      final f = File('${dir.path}/image_${DateTime.now().millisecondsSinceEpoch}.png');
      await f.writeAsBytes(bytes);
      return 'IMAGE_SAVED ${f.path}\nThe image is shown to the user and saved in their Library.';
    } catch (e) {
      return 'Error: the picture could not be made ($e). ${AgentTools.imageOtherWays}';
    }
  }

  Future<String> _generateVideo(Map<String, dynamic> args, [String? convId]) async => MediaProviderStore.I.has(MediaKind.video)
      // The user's own video provider (Settings > Media models) makes it.
      ? _mediaGenerate({...args, 'kind': 'video'}, convId)
      : 'Error: making videos is not available yet. Tell the user plainly, and offer a slideshow video from pictures instead if it helps.';

  void _clearAwaiting(String id) {
    if (awaitingReply != id) return;
    awaitingReply = null;
    _notify();
  }

  Future<Map<String, String>?> askUser(UserAsk a) {
    // Team work has no chat card to ask in (its team chat is no conversation, and the member's private chat is not
    // the place: bots team audit 2026-11-04). The question is skipped at once and the member carries on, instead of
    // waiting on a card nobody can see.
    if (TeamKey.isKey(a.convId)) return Future<Map<String, String>?>.value(null);
    asks.add(a);
    final signIn = a.kind == 'login' || a.kind == 'login_confirm';
    if (signIn) BrowserAgent.I.setSheetUp(true);
    if (_liveTaskConvs.contains(a.convId) && onLiveTaskNews != null) {
      onLiveTaskNews!(a.kind == 'login' || a.kind == 'connect' || a.secret
          ? '[Task update] The task needs the user to ${a.kind == 'login' ? 'sign in' : (a.kind == 'connect' ? 'connect an app' : 'enter something private')}: "${a.title}". '
              'Tell them a card is on the screen to tap. Do not ask for it out loud.'
          : '[Task update] The task asks: "${a.title}"'
              '${a.options.isEmpty ? '' : ' Options: ${a.options.join(', ')}.'} Ask the user, then call answer_task.');
    }
    _notify();
    return a.done.future.whenComplete(() {
      asks.remove(a);
      if (!asks.any((e) => e.kind == 'login' || e.kind == 'login_confirm')) BrowserAgent.I.setSheetUp(false);
      _notify();
    });
  }

  void answerAsk(UserAsk a, Map<String, String>? v) {
    if (!a.done.isCompleted) a.done.complete(v);
  }

  Future<String> _projectsTool(Map<String, dynamic> a, String? convId) async {
    await Projects.I.init();
    final action = '${a['action'] ?? 'list'}';
    final here = Projects.I.forChat(convId);
    String names() => Projects.I.list.isEmpty ? 'none yet' : Projects.I.list.map((p) => '"${p.name}"').join(', ');
    if (action == 'list') {
      if (Projects.I.list.isEmpty) return 'The user has no projects yet. create makes one.';
      final sb = StringBuffer();
      for (final p in Projects.I.list) {
        final n = (await Projects.I.files(p.id)).length;
        sb.writeln('- "${p.name}": ${Projects.I.chatsIn(p.id).length} chats, $n files${p == here ? ' (this chat is in it)' : ''}'
            '${p.instructions.isEmpty ? '' : '. Notes: ${p.instructions.length > 160 ? '${p.instructions.substring(0, 160)}…' : p.instructions}'}');
      }
      return sb.toString().trim();
    }
    if (action == 'create') {
      final name = '${a['name'] ?? a['project'] ?? ''}'.trim();
      if (name.isEmpty) return 'Error: give the new project a name.';
      final dup = AppState._projectFor(name);
      if (dup != null && dup.name.toLowerCase() == name.toLowerCase()) return 'A project named "${dup.name}" already exists; use it.';
      final p = await Projects.I.create(name, instructions: '${a['note'] ?? ''}');
      return 'Created the project "${p.name}". To put this chat in it, call add_chat.';
    }
    final pq = '${a['project'] ?? ''}';
    final p = pq.trim().isEmpty ? (here ?? (Projects.I.list.length == 1 ? Projects.I.list.first : null)) : AppState._projectFor(pq);
    if (p == null) {
      return Projects.I.list.isEmpty
          ? 'The user has no projects yet. Ask if you should create one (and its name), then call create.'
          : 'Which project? Theirs: ${names()}. If it is unclear, ask the user with ask_user, then call again with the name.';
    }
    switch (action) {
      case 'add_chat':
        if (convId == null || convId.isEmpty) return 'Error: no chat to add.';
        if (here?.id == p.id) return 'This chat is already in "${p.name}".';
        await Projects.I.assign(convId, p.id);
        return 'This chat is now in the project "${p.name}"${here == null ? '' : ' (moved from "${here.name}")'}. Its notes and files apply from now on.';
      case 'save_file':
        final path = '${a['path'] ?? ''}'.trim();
        final content = a['content'];
        if (path.isNotEmpty) {
          final f = File(path.startsWith('/') ? path : '${await AgentTools.workspaceDir()}/$path');
          if (!await f.exists()) return 'Error: no file at $path. Check the path with list_files, or pass content instead.';
          final name = '${a['name'] ?? ''}'.trim().isEmpty ? f.uri.pathSegments.last : '${a['name']}'.trim();
          await Projects.I.addFile(p.id, name, await f.readAsBytes());
          return 'Saved $name into the project "${p.name}".';
        }
        if (content is String && content.isNotEmpty) {
          final name = '${a['name'] ?? ''}'.trim().isEmpty ? 'note.md' : '${a['name']}'.trim();
          await Projects.I.addFile(p.id, name, utf8.encode(content));
          return 'Saved $name into the project "${p.name}".';
        }
        return 'Error: pass path (a file you made) or content (the text to save).';
      case 'add_note':
        final note = '${a['note'] ?? a['content'] ?? ''}'.trim();
        if (note.isEmpty) return 'Error: note is empty.';
        await Projects.I.update(p, instructions: p.instructions.isEmpty ? note : '${p.instructions}\n$note');
        return 'Added to the notes of "${p.name}": $note';
    }
    return 'Error: unknown action $action.';
  }

  Future<String> _sitesTool(Map<String, dynamic> a) async {
    await Sites.I.init();
    final action = '${a['action'] ?? 'list'}';
    if (action == 'list') {
      if (Sites.I.list.isEmpty) return 'No sites published from SubMac yet.';
      return [
        for (final s in Sites.I.list)
          '- "${s.title}": ${s.statusLine}${s.url.isEmpty ? '' : ' · ${s.url}'}${s.host.isEmpty ? '' : ' (${s.hostName})'}'
      ].join('\n');
    }
    if (action != 'unpublish') return 'Error: action must be list or unpublish.';
    final s = AppState._siteFor('${a['site'] ?? ''}');
    if (s == null) {
      final live = Sites.I.list.where((x) => x.url.isNotEmpty).map((x) => '"${x.title}" (${x.url})').join(', ');
      return live.isEmpty ? 'No site is online right now.' : 'Which one? Online now: $live. Ask the user, then call again with its title or address.';
    }
    if (s.host == SiteHost.vercel) {
      return '"${s.title}" lives in the user\'s own Vercel account (${s.url}), and the Vercel connection cannot delete projects. '
          'Tell them in one line: on vercel.com open the project "${s.vercelProject.isEmpty ? s.title : s.vercelProject}", then Settings, then Delete Project. '
          'Offer to open https://vercel.com/dashboard for them with open_link.';
    }
    if (s.isExpired) {
      await Sites.I.removeFreeLink(s).catchError((_) {});
      return '"${s.title}" was already offline (its free link had ended).';
    }
    try {
      final url = s.url;
      await Sites.I.removeFreeLink(s);
      return '"${s.title}" is offline now. $url no longer opens. It stays saved on the phone: Publish brings it back.';
    } catch (e) {
      return 'Error: could not take "${s.title}" offline: ${Calm.short(e)}. Try once more.';
    }
  }

  /// One way to connect an app from a task: the connect sheet, never a raw link. Returns a line for the model.
  Future<String> requestConnect(String name, {String why = '', String? convId}) async {
    if (name.trim().isEmpty) return 'Error: say which app to connect.';
    final preset = McpOAuth.presetFor(name);
    final def = preset == null ? AppState._connDefFor(name) : null;
    if (preset == null && def == null) {
      return 'No ready-made connection for "$name". Sign-in apps: ${McpOAuth.presets.map((p) => p.name).join(', ')}. '
          'Key apps: ${ConnectorCatalog.all.map((d) => d.name).join(', ')}. For another app, ask the user for its MCP server link, then connect_mcp with url.';
    }
    final label = preset?.name ?? def!.name;
    if (preset != null) {
      final on = mcpServers.where((s) => s.url == preset.url && s.enabled).firstOrNull;
      if (on != null && (mcpStatus[on.id] ?? 'Connected').startsWith('Connected')) return '$label is already connected. Use its tools.';
    } else if (ConnectorCatalog.connected.containsKey(def!.id)) {
      return '$label is already connected. Use its tools.';
    }
    final cid = convId ?? currentId ?? '';
    final r = await askUser(UserAsk(
      kind: 'connect',
      convId: cid,
      title: 'Connect $label',
      prompt: why.trim().isNotEmpty ? why.trim() : (preset?.blurb ?? def!.blurb),
      site: preset != null ? 'mcp:${preset.id}' : 'app:${def!.id}',
    ));
    if (r == null || r['ok'] != 'true') {
      return 'The user chose not to connect $label now. Carry on without it if you can, or say in one line what it would let you do.';
    }
    if (preset != null) await refreshMcpTools();
    (_convGroups[cid] ??= <String>{}).add(ToolScope.apps);
    return '$label is connected. Its tools are ready: carry on with the task now.';
  }

  Future<String> _askUserTool(Map<String, dynamic> a, String? convId) async {
    final q = (a['question'] ?? '').toString().trim();
    if (q.isEmpty) return 'Error: no question';
    final r = await askUser(UserAsk(
      kind: 'text',
      convId: convId ?? currentId ?? '',
      title: q,
      prompt: '',
      // Any shape (a list, "A, B, C", a JSON string, labelled objects); it crashed on anything but a list of strings.
      options: Choices.parse(a['options']),
      secret: a['secret'] == true,
      site: BrowserAgent.jobNow != null ? 'browser' : '',
    ));
    if (r == null) return 'The user skipped this question. Carry on without it or ask what they prefer.';
    // CB-42: "Send it" to the draft shown in this question approves the send, so the other app may be used now.
    final cid = convId ?? currentId ?? '';
    final goal = cid.isEmpty ? '' : _goalOf(cid);
    if (OutboundGuard.isSendGoal(goal) && OutboundGuard.saysYes(r['answer'] ?? '')) OutboundGuard.approve(cid, goal);
    return 'User answered: ${r['answer'] ?? ''}';
  }

  Future<void> forgetLogin(String site) async {
    await local.setSecret('login_$site', '');
    savedLoginSites.remove(site);
    await local.setSecret('loginSites', jsonEncode(savedLoginSites));
    _notify();
  }

  /// SubMac can look at pictures: every route behind `submac` must accept images (PLAN 1.1 model checks; the server
  /// filters routes by capability). This used to test the model name for "submac-", which the one name `submac`
  /// never matched, so browsing and phone tasks sent no screenshots at all.
  bool get canSee => true;

  /// The refusal text when [name] would change something in an app the user set to read only, else null.
  String? _readOnlyBlock(String name, Map<String, dynamic> args) {
    McpTool? t;
    if (name == 'apps_run_tool') {
      t = _findMcpTool('${args['tool'] ?? ''}', '${args['app'] ?? ''}');
    } else if (name.startsWith('mcp_')) {
      for (final e in mcpTools) {
        if (e.fnName == name) t = e;
      }
    }
    if (t == null || !t.server.readOnly || AppState._readOnlyTool.hasMatch(t.name)) return null;
    return 'Not allowed: ${t.server.name} is set to read only, so SubMac can look things up there but not change anything. '
        'Do not try it another way. Tell the user in one line, and that they can turn off "Read only" in Apps > ${t.server.name}.';
  }

  Future<ActionRequest?> _riskFor(String name, Map<String, dynamic> args) async {
    if (name == 'sites' && args['action'] == 'unpublish') {
      final s = AppState._siteFor('${args['site'] ?? ''}');
      if (s == null || s.host != SiteHost.free || s.isExpired) return null;
      return ActionRequest(
        title: 'Take "${s.title}" offline?',
        body: 'Its link stops working now. The site stays on your phone, so you can publish it again later.',
        detail: s.url,
        confirmLabel: 'Take offline',
        destructive: true,
      );
    }
    if (name == 'phone_tap') {
      final about = (args['about'] ?? '').toString().trim();
      final id = (args['id'] is num) ? (args['id'] as num).toInt() : int.tryParse('${args['id']}') ?? -1;
      final byText = (args['text'] ?? '').toString().trim();
      final label = (args['id'] == null && byText.isNotEmpty ? byText : SystemTools.labelFor(id)).replaceAll('"', '');
      if (about.isEmpty && !AppState._riskyClick.hasMatch(label)) return null;
      return ActionRequest(
        title: about.isNotEmpty ? about : 'Tap "$label" on your phone?',
        body: 'This may send, post, pay or delete something for you.',
        detail: label,
        confirmLabel: 'Allow',
      );
    }
    if (BrowserAgent.names.contains(name)) {
      // Browser presses: the decision uses the task's own latest view (labels, and whether it is a payment page).
      final job = BrowserAgent.jobNow;
      final page = BrowserAgent.I.snapFor(job);
      final g = BrowserGate.check(name, args, BrowserAgent.I.labelsFor(job), page, readOnly: _readOnlyTask(name, null));
      if (g == null) return null;
      return ActionRequest(
        title: g.title,
        body: page.moneyPage ? 'This is a payment page: this may spend your money.' : 'This may post, send or submit something for you.',
        detail: '${page.url.isEmpty ? BrowserAgent.I.url : page.url}${g.label.isEmpty ? '' : '\n${g.label}'}',
        confirmLabel: 'Allow',
      );
    }
    if (name == 'apps_run_tool') {
      final t = _findMcpTool('${args['tool'] ?? ''}', '${args['app'] ?? ''}');
      if (t == null) return null;
      final a = args['arguments'];
      return _riskFor(t.fnName, a is Map ? Map<String, dynamic>.from(a) : <String, dynamic>{});
    }
    if (name.startsWith('mcp_')) {
      McpTool? t;
      for (final e in mcpTools) {
        if (e.fnName == name) t = e;
      }
      final tool = t?.name ?? name;
      if (AppState._readOnlyTool.hasMatch(tool)) return null;
      return ActionRequest(
        title: 'Let ${t?.server.name ?? 'the connector'} do this?',
        body: 'SubMac wants to use "${tool.replaceAll('_', ' ').toLowerCase()}". It may change things in your connected account.',
        detail: AppState.plainDetails(args),
        confirmLabel: 'Allow',
      );
    }
    if (ConnectorCatalog.isConnectorTool(name)) {
      if (ConnectorCatalog.isRead(name, args)) return null;
      final app = name == 'api_call' ? 'this website' : ConnectorCatalog.appNameFor(name);
      if (name == 'email_send') {
        return ActionRequest(
          title: 'Send this email to ${args['to']}?',
          body: '${args['subject'] ?? ''}',
          detail: '${args['body'] ?? ''}',
          confirmLabel: 'Send',
        );
      }
      return ActionRequest(
        title: 'Make a change in $app?',
        body: 'This will send, post or change something in your account.',
        detail: AppState.plainDetails({'address': args['path'] ?? args['url'], if (args['query'] is Map) ...Map<String, dynamic>.from(args['query'] as Map), if (args['body'] != null) ...(args['body'] is Map ? Map<String, dynamic>.from(args['body'] as Map) : {'content': args['body']})}),
        confirmLabel: 'Allow',
      );
    }
    if (ConnectorTools.names.contains(name)) {
      if (!ConnectorTools.isWrite(args)) return null;
      return ActionRequest(
        title: name == 'github_api' ? 'Make a change on GitHub?' : 'Make a change in Notion?',
        body: 'This will change something in your account.',
        detail: AppState.plainDetails({'address': args['path'], if (args['body'] != null) ...(args['body'] is Map ? Map<String, dynamic>.from(args['body'] as Map) : {'content': args['body']})}),
        confirmLabel: 'Allow',
      );
    }
    if (CodeTools.names.contains(name)) return CodeTools.riskFor(name, args);
    // An own tool in shell (or the test run of one being made) is a shell command: the same approval as run_shell.
    final forgedShell = name == ForgedTools.make ? ForgedTools.makeShellCode(args) : ForgedTools.shellCodeOf(name);
    if (forgedShell != null) return AgentTools.riskFor('run_shell', {'command': forgedShell});
    return AgentTools.riskFor(name, args);
  }
}
