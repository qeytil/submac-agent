// Phone/system glue: notifications, app visibility, after-task work, phone access.
// Split out of app_state.dart (no behaviour change). Fields stay on AppState.
part of '../app_state.dart';

extension AppStateSystem on AppState {
  Future<void> _initSystem() async {
    try {
      await Projects.I.init();
    } catch (_) {}
    notifyWhenDone = local.prefs.getBool('notifyWhenDone') ?? true;
    // Easy mode was removed (plan 5.3): the normal app is the simple one.
    replyLanguage = local.prefs.getString('replyLanguage') ?? 'auto';
    final b = SystemBridge.I;
    b.onWake = (_) => liveCtl.onWake();
    b.onOverlay = liveCtl.onOverlay;
    b.onNotificationTap = _onNotificationTap;
    // Alarms wait until the bots and scheduled tasks are loaded (AlarmGate, 2026-11-05): Android hands an alarm
    // over the moment Dart listens, which used to be before Scheduler/Bots had loaded, so the task was dropped.
    b.onAlarm = (id) => _alarmGate.run(() => _onAlarm(id));
    b.onBotDecline = (id) => unawaited(declineBotCall(id));
    b.onBotMissed = (id) {
      final bot = Bots.I.byId(id);
      if (bot != null) unawaited(_missedCall(bot));
    };
    b.onNotifEvent = (e) => unawaited(Bots.I.notificationEvent(e));
    Bots.I.onWake = _botWake;
    Bots.I.onReport = _botReport;
    Bots.I.working = (bot) => _officeBusy.contains(bot.id) || (bot.convId.isNotEmpty && runs.any((r) => r.convId == bot.convId && !r.side));
    Bots.I.waitingFor = (bot) => Offices.I.pending.where((a) => a.botId == bot.id).length;
    b.onApproval = (id, ok) => unawaited(Offices.I.answer(id, ok));
    // A reply typed in a notification can be what started SubMac (closed): it waits, like an alarm, until the bots,
    // teams and chats are loaded (it used to find no team or bot yet and was dropped).
    b.onNotifReply = (to, text) => unawaited(_alarmGate.run(() => _notificationReply(to, text)));
    Offices.I.pump = _officePump;
    _wireMissions();
    CodeGit.connect = (why) async {
      final r = await requestConnect('GitHub', why: why);
      return r.contains('is connected') || r.contains('already connected');
    };
    // The kind of the office job a bot does now, for callers that do not pass it (office_post passes its own).
    Offices.I.currentJob = (id) => _officeJobs.values.where((j) => j.botId == id).firstOrNull?.kind;
    // The chain of the job a bot posts from mid-turn (office_post), so its post starts teammates one level deeper.
    Offices.I.jobOf = (id, officeId) {
      final j = _officeJobs.values.where((j) => j.botId == id && j.officeId == officeId).fold<OfficeLiveJob?>(
          null, (a, x) => a == null || x.depth > a.depth ? x : a);
      return j == null ? null : (kind: j.kind, depth: j.depth, cause: j.cause);
    };
    Offices.I.isWorking = (id) {
      if (_officeBusy.contains(id)) return true;
      final bot = Bots.I.byId(id);
      return bot != null && bot.convId.isNotEmpty && runs.any((r) => r.convId == bot.convId && !r.side);
    };
    Offices.I.jobsRunning = (officeId) => _officeJobs.values.any((j) => j.officeId == officeId);
    // Office jobs read Offices.stoppedSince as their stop check, so a stop reaches each of them at its next step.
    // It no longer stops the runs in the members' private chats (those are the owner's own 1:1 conversations, which
    // a team's "stop" used to cut off).
    Offices.I.stopRunning = (officeId) {
      unawaited(Offices.I.expireForOffice(officeId));
    };
    Offices.I.notify = (o, bot, text) async {
      if (bot.quietNow()) return;
      await _officeNotify(o, bot, text);
    };
    // A "[needs you]" post or a question from the lead: the team's notification pops up.
    Offices.I.notifyNeeds = (o, bot, text) async {
      if (bot.quietNow()) return;
      await _officeNotify(o, bot, text, needs: true);
    };
    Bots.I.ring = _botRing;
    Bots.I.connectedAppsOf = botConnectedApps;
    // "Every hour" is one repeating scheduled task of the bot (the bot wakes for it), never one routine per hour.
    Bots.I.scheduleRepeat = (bot, job, repeat) {
      final n = DateTime.now();
      final first = DateTime(n.year, n.month, n.day, n.hour + 1);
      return Scheduler.I.add(job, first.toIso8601String().substring(0, 16), repeat, bot: bot.id);
    };
    Bots.I.repeatsOf = (bot) => [
          for (final t in Scheduler.I.tasks)
            if (t.bot == bot.id && (t.repeat == 'hourly' || t.repeat == 'every_3_hours')) (id: t.id, task: t.task, repeat: t.repeat),
        ];
    Bots.I.cancelRepeat = (bot, id) async {
      if (!Scheduler.I.tasks.any((t) => t.id == id && t.bot == bot.id)) return 'Error: no routine $id.';
      await Scheduler.I.cancel(id);
      return 'Removed.';
    };
    // A removed bot takes its work with it (bug audit 2026-11-07). A scheduled task left behind still fires, and
    // with the bot gone it runs as SubMac's own task; its team jobs kept its membership alive; its mission kept
    // waking it. All of it stops here, while the bot can still be named in the team's lines.
    Bots.I.onRemoved = (b) async {
      for (final t in List.of(Scheduler.I.tasks.where((t) => t.bot == b.id))) {
        await Scheduler.I.cancel(t.id);
      }
      for (final o in List.of(Offices.I.offices.where((o) => o.members.contains(b.id) || o.chiefId == b.id))) {
        await Offices.I.removeMember(o, b.id);
      }
      final m = Missions.I.liveOf('bot', b.id);
      if (m != null) await Missions.I.stop(m);
    };
    Bots.I.consult = _botConsult;
    Bots.I.makeTeam = _botMakeTeam;
    Bots.I.teamsOf = (b) => [
          for (final o in Offices.I.offices)
            if (o.chiefId == b.id)
              '- You lead "${o.name}"${o.goal.isEmpty ? '' : ' (goal: ${o.goal})'}. Give it a job with submac_run_tool name "team_task", '
                  'arguments {"team": "${o.name}", "task": "..."}; for regular team work, make a bot_routine whose instruction says to do that.'
            else if (o.members.contains(b.id))
              '- You are in "${o.name}", led by ${Bots.I.byId(o.chiefId)?.name ?? 'its lead'}. Team folder: ${TeamRun.folderOf(o)}/.',
        ].join('\n');
    // Teams run on opencode (owner, 2026-11-03): every member's part and the lead's work are opencode turns with the
    // bot's own brief and tools; one-answer calls (who speaks, the plan, the combined answer) are one plain model call.
    TeamRun.I
      ..ocTurn = teamTurn
      ..ask = _teamAsk
      // CB-62: a team holds the phone awake while it works; letting go never cuts other work still running.
      ..keepAlive = (on, {String text = ''}) async {
        if (on) {
          await SystemBridge.I.keepAlive(true, text: text);
        } else if (!runs.any((r) => !r.side) && _officeBusy.isEmpty) {
          await SystemBridge.I.keepAlive(false);
        }
      };
    // A browser task started by a scheduled run works with the app closed, so it holds the phone awake the
    // same way a team does, and lets go only when nothing else is running.
    BrowserJobs.keepAwake = (on) async {
      if (on) {
        await SystemBridge.I.keepAlive(true, text: 'Working on your browser task');
      } else if (!runs.any((r) => !r.side) && _officeBusy.isEmpty) {
        await SystemBridge.I.keepAlive(false);
      }
    };
    Bots.I.resolveModel = resolveModelHint;
    Bots.I.isAppConnected = botAppConnected;
    b.onPhoneStop = () {
      for (final r in runs.where((r) => r.phone).toList()) {
        stopRun(r);
      }
      TaskBubble.I.stopAll();
    };
    Scheduler.I.runTask = (t) async {
      // A bot's scheduled task: the bot wakes in its own chat, works on its own, and notifies with the result.
      final bot = t.bot.isEmpty ? null : Bots.I.byId(t.bot);
      if (bot != null && bot.active) {
        final ins = t.watch
            ? '${t.task}\nCheck now and report only what is new or changed since your last check (see your journal and memory). '
                'Nothing important new: reply with only [no reply].'
            : t.task;
        await _botWake(bot, 'your scheduled task${t.repeat == 'none' ? '' : ' (${t.repeat})'}', ins, t.watch ? 'work' : 'message');
        return;
      }
      const quiet = '\n\n[Scheduled run: the user is not watching]\n'
          'Do the task fully on your own: no say, no questions, no confirmations you can avoid. '
          'Your final reply is ONE plain line, under 100 characters, that gives the result itself, the way it should read in the '
          'notification bar: no greeting, no title, no "Here is", no cards, no lists. '
          'Examples: "Rain from 3 pm, 24°C. Take an umbrella." / "Dollar at 1 USD = 27,500 SOS, up 0.4% since yesterday." / '
          '"2 new emails from Amina about the invoice." If the task failed, one line on why.';
      final prompt = t.watch
          ? '${t.task}\n\n[Watcher check] Only report what is new or changed since last time. '
              'Last time you found: ${t.last.isEmpty ? '(this is the first check, so report what you find)' : t.last}\n'
              'If nothing important is new, reply with exactly NO_CHANGE and nothing else.$quiet'
          : '${t.task}$quiet';
      // Every run of the same task goes into one chat, so the sidebar never fills up with repeats.
      String? reuse;
      if (t.convId.isNotEmpty && conversations.any((c) => c.id == t.convId)) {
        if (_lists[t.convId] == null) {
          try {
            _lists[t.convId] = await repo.listMessages(t.convId);
          } catch (_) {}
        }
        if (_lists[t.convId] != null) reuse = t.convId;
      }
      final err = await startBackgroundTask(prompt,
          reuseConvId: reuse,
          ownChatTitle: reuse == null ? '${t.watch ? 'Watching' : 'Scheduled'}: ${_shortTitle(t.task)}' : null,
          scheduled: true,
          onDone: t.watch ? (reply) => Scheduler.I.setLast(t.id, reply) : null);
      if (err == null && reuse == null && lastOwnConvId != null) await Scheduler.I.setConv(t.id, lastOwnConvId!);
      if (err != null) {
        await b.notify(id: t.id.hashCode & 0x7ffffff, title: '', body: 'Couldn’t run “${_shortTitle(t.task)}”: $err', kind: 'scheduled');
        await b.keepAlive(false);
      }
    };
    await b.init();
    // Started by an alarm or a restart with no screen: nothing is on screen, so a bot's result notifies and its
    // approvals never wait on a card (2026-11-05). The screen's lifecycle sets this right once it opens.
    if (await _startedHeadless()) {
      headless = true;
      appVisible = false;
    }
    // The floating task bubble; nothing can be driving the screen yet, so clear any badge left from before.
    TaskBubble.I.attach(this);
    TaskBubble.I.reset();
    // Speed: these don't depend on each other, so they start together; the bots chain below runs meanwhile.
    final sideInits = Future.wait<void>([
      SystemTools.refreshPerms().catchError((_) {}),
      WakeWord.I.init().catchError((_) {}),
      Scheduler.I.init(uid: repo.userId).catchError((_) {}),
    ]);
    try {
      await Bots.I.init();
      // Plan 5.2: bots from before trust levels take the level that matches how SubMac was set ("full" = Trusted).
      var moved = false;
      for (final x in Bots.I.bots.where((x) => x.trust.isEmpty)) {
        x.trust = local.approvalMode == 'full' ? BotTrust.levelTrusted : BotTrust.levelNew;
        moved = true;
      }
      if (moved) await Bots.I.save();
      await WhatsAppTools.init();
      await BotTraces.I.init();
      await SkillLibrary.I.init();
      // CB-46: wakes that came while SubMac could not run them yet.
      unawaited(_runHeldWakes());
    } catch (_) {}
    try {
      await Offices.I.init();
      // CB-64: a team job that was running when SubMac closed says so once ("go" restarts it).
      await TeamRun.I.restore();
      _officePump();
    } catch (_) {}
    try {
      // Missions (owner 2026-11-07): loaded from their files before the alarm gate opens, and every mission that is on
      // gets its alarm again (after a restart its time may have passed: it then wakes in a minute).
      await Missions.I.init();
      await Missions.I.armAll();
    } catch (_) {}
    await sideInits;
    TelegramBridge.I.onMessage = _telegramAsk;
    // Awaited (it only reads the saved token; polling runs on its own) so a bot's first background task can already
    // message the owner on Telegram (bot_telegram).
    await TelegramBridge.I.init().timeout(const Duration(seconds: 10)).catchError((_) {});
    // CB-46 + 2026-11-05: a wake held because SubMac was not ready (account not restored yet, offline at a cold
    // start) is tried again a few times. It used to run only when the home screen opened.
    unawaited(_retryHeldWakes());
    final p = await b.takeLaunchPayload();
    if (p != null) _onNotificationTap(p);
  }

  /// True when no screen started this engine: Flutter has no lifecycle state yet and Android says SubMac is not in
  /// front (an alarm, a restart or a push started it).
  Future<bool> _startedHeadless() async {
    if (!SystemBridge.I.supported) return false;
    try {
      final life = WidgetsBinding.instance.lifecycleState;
      if (life != null && life != AppLifecycleState.detached) return false;
      return !await SystemBridge.I.isForeground();
    } catch (_) {
      return false;
    }
  }

  /// Runs held wakes again after a while, a few times, while SubMac may still be getting ready. When nothing ran,
  /// the foreground service an alarm started is let go after the last try.
  Future<void> _retryHeldWakes() async {
    for (final d in BgRun.heldRetries) {
      if (!Bots.I.hasHeldWakes) return;
      await Future<void>.delayed(d);
      try {
        await _runHeldWakes();
      } catch (_) {}
    }
    if (Bots.I.hasHeldWakes && !runs.any((r) => !r.side) && _officeBusy.isEmpty) await SystemBridge.I.keepAlive(false);
  }

  @visibleForTesting
  Future<void> retryHeldWakesForTest() => _retryHeldWakes();

  /// One alarm, once SubMac is ready (see AlarmGate).
  Future<void> _onAlarm(String id) async {
    if (id == 'rearm') {
      // The phone restarted: starting up has already re-armed every alarm (BootReceiver starts SubMac through this
      // alarm so its foreground service keeps it alive while it does).
      if (!runs.any((r) => !r.side)) await SystemBridge.I.keepAlive(false);
      return;
    }
    if (id.startsWith('office|')) {
      final queued = await Offices.I.fire(id);
      _officePump();
      if (!queued && !runs.any((r) => !r.side) && _officeBusy.isEmpty) await SystemBridge.I.keepAlive(false);
      return;
    }
    if (id.startsWith('mission|')) {
      final woke = await Missions.I.fire(id);
      if (!woke && !runs.any((r) => !r.side) && _officeBusy.isEmpty) await SystemBridge.I.keepAlive(false);
      return;
    }
    if (id.startsWith('bot|')) {
      final woke = await Bots.I.fire(id);
      if (!woke && !runs.any((r) => !r.side)) await SystemBridge.I.keepAlive(false);
    } else {
      await Scheduler.I.fire(id);
    }
  }

  @visibleForTesting
  Future<void> onAlarmForTest(String id) => _alarmGate.run(() => _onAlarm(id));

  @visibleForTesting
  void openAlarmGateForTest() => _alarmGate.open();

  void _onNotificationTap(String payload) {
    if (payload.startsWith('botcall/')) {
      unawaited(answerBotCall(payload.substring(8)));
      return;
    }
    // CB-16: a bot's chat opens in the Bots workspace, on that bot. One already open follows the open chat in place.
    final chatBot = payload.startsWith('botchat/')
        ? Bots.I.byId(payload.substring(8))
        : payload.startsWith('conv/')
            ? Bots.I.byConv(payload.substring(5))
            : null;
    if (chatBot != null || payload.startsWith('botchat/')) {
      if (chatBot == null) return;
      if (BotStatus.I.workspaces > 0 || (!chatBot.active && chatBot.convId.isEmpty)) {
        unawaited(openBot(chatBot));
      } else {
        openRequest.value = null;
        openRequest.value = 'botchat/${chatBot.id}';
      }
      return;
    }
    if (payload.startsWith('botring/')) {
      final b = Bots.I.byId(payload.substring(8));
      if (b != null && _ringing == b.id) incomingCall.value = b;
      return;
    }
    if (payload.startsWith('office/') || payload == 'approvals' || payload == 'inbox' || payload.startsWith('inbox/')) {
      if (payload.startsWith('inbox')) unawaited(Inbox.I.refresh());
      openRequest.value = null;
      openRequest.value = payload;
      return;
    }
    if (payload.startsWith('conv/')) {
      unawaited(openConversation(payload.substring(5)));
    } else if (payload == 'live') {
      liveCtl.openScreen?.call();
    } else if (payload == 'widget/ask' || payload == 'widget/scan') {
      if (payload == 'widget/ask') newChat();
      widgetAction.value = null;
      widgetAction.value = payload.substring(7);
    } else if (payload.startsWith('settings/wake') || payload.startsWith('wake/')) {
      openSystemSettings?.call();
    }
  }

  /// The app moved to/from the background.
  Future<void> setAppVisible(bool v) async {
    appVisible = v;
    TaskBubble.I.visibilityChanged();
    if (v) {
      await SystemTools.refreshPerms();
      await SystemBridge.I.keepAlive(false);
      // Back in the app: the results are on screen, so old "done" notifications go away.
      unawaited(SystemBridge.I.clearTaskNotifications());
      if (repo.backupWaiting) unawaited(repo.sync());
      _notify();
      return;
    }
    unawaited(repo.flush());
    await liveCtl.onAppHidden();
    // Keep tasks running with the app closed.
    if (runs.any((r) => !r.side)) {
      await SystemBridge.I.keepAlive(true, text: 'Working on your task');
    } else if (TelegramBridge.I.on && TelegramBridge.I.paired) {
      await SystemBridge.I.keepAlive(true, text: 'Answering you on Telegram');
    }
  }


  Future<void> refreshPhoneAccess() async {
    phoneAccess = await DeviceAccess.isGranted();
    _notify();
  }

  Future<bool> requestPhoneAccess() async {
    phoneAccess = await DeviceAccess.request();
    _notify();
    return phoneAccess;
  }

  String get firstName {
    final e = repo.email ?? '';
    if (e.isEmpty) return '';
    final raw = e.split('@').first.split(RegExp(r'[._\-+0-9]')).firstWhere((x) => x.isNotEmpty, orElse: () => '');
    if (raw.isEmpty || raw.length > 14) return '';
    return raw[0].toUpperCase() + raw.substring(1).toLowerCase();
  }

  Future<void> saveCustomInstructions(String about, String how) async {
    aboutYou = about;
    howToRespond = how;
    _notify();
    await repo.saveSettings({'about_you': about, 'how_to_respond': how});
  }

  /// Earlier versions let people paste their own AI keys. Those are wiped from the phone once, for good.
  Future<void> _forgetOldModelSetup() async {
    // v2: also drops the single-model leftovers (thinking, showSteps, maxSteps, easyMode).
    if (local.prefs.getBool('cloudOnlyV2') == true) return;
    try {
      await local.forgetModelSetup();
    } catch (_) {}
    await local.prefs.setBool('cloudOnlyV2', true);
  }
}
