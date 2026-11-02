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
    b.onAlarm = (id) async {
      if (id == 'rearm') {
        // The phone restarted: starting up has already re-armed every alarm.
        if (!runs.any((r) => !r.side)) await SystemBridge.I.keepAlive(false);
        return;
      }
      if (id.startsWith('office|')) {
        final queued = await Offices.I.fire(id);
        _officePump();
        if (!queued && !runs.any((r) => !r.side) && _officeBusy.isEmpty) await SystemBridge.I.keepAlive(false);
        return;
      }
      if (id.startsWith('bot|')) {
        final woke = await Bots.I.fire(id);
        if (!woke && !runs.any((r) => !r.side)) await SystemBridge.I.keepAlive(false);
      } else {
        await Scheduler.I.fire(id);
      }
    };
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
    b.onNotifReply = (to, text) => unawaited(_notificationReply(to, text));
    Offices.I.pump = _officePump;
    CodeGit.connect = (why) async {
      final r = await requestConnect('GitHub', why: why);
      return r.contains('is connected') || r.contains('already connected');
    };
    Offices.I.currentJob = (id) {
      final bot = Bots.I.byId(id);
      if (bot == null || !_officeBusy.contains(id)) return null;
      return _officeJobKind[bot.convId];
    };
    Offices.I.isWorking = (id) {
      if (_officeBusy.contains(id)) return true;
      final bot = Bots.I.byId(id);
      return bot != null && bot.convId.isNotEmpty && runs.any((r) => r.convId == bot.convId && !r.side);
    };
    Offices.I.jobsRunning = (officeId) => _officeBusyIn.values.contains(officeId);
    Offices.I.stopRunning = (officeId) {
      for (final id in [for (final e in _officeBusyIn.entries) if (e.value == officeId) e.key]) {
        final bot = Bots.I.byId(id);
        if (bot == null || bot.convId.isEmpty) continue;
        for (final r in runs.where((r) => r.convId == bot.convId && !r.side).toList()) {
          stopRun(r);
        }
      }
    };
    Offices.I.notify = (o, bot, text) async {
      if (bot.quietNow()) return;
      await _officeNotify(o, bot, text);
    };
    Bots.I.ring = _botRing;
    Bots.I.consult = _botConsult;
    Bots.I.makeTeam = _botMakeTeam;
    // Teams run on the Genkit agent core; members get their own tools and ask the owner through approval interrupts.
    TeamRun.I
      ..llm = _teamLlm
      ..toolsFor = _memberTools
      ..runTool = _memberTool
      ..approvalFor = _memberApproval
      ..answer = _memberAnswer
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
    await sideInits;
    TelegramBridge.I.onMessage = _telegramAsk;
    unawaited(TelegramBridge.I.init());
    final p = await b.takeLaunchPayload();
    if (p != null) _onNotificationTap(p);
  }

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

  Future<void> _afterTask(String convId, List<ChatMessage> list, bool cancelled) async {
    if (deepResearch && !runs.any((r) => !r.side)) {
      deepResearch = false;
      _notify();
    }
    final scheduledRun = _scheduledConvs.remove(convId);
    final wanted = _notifyConvs.remove(convId) || !appVisible;
    if (!runs.any((r) => !r.side) && !(TelegramBridge.I.on && TelegramBridge.I.paired && !appVisible)) {
      await SystemBridge.I.keepAlive(false);
    }
    final done = _doneCbs.remove(convId);
    if (done != null && !cancelled) {
      final reply = list.lastWhere((m) => m.role == 'assistant' && m.content.trim().isNotEmpty,
          orElse: () => ChatMessage(id: '', role: 'assistant', content: '')).content.trim();
      if (!Bots.I.isBotConv(convId) && (reply.trim() == 'NO_CHANGE' || (reply.contains('NO_CHANGE') && reply.length < 40))) {
        // A watcher found nothing new: stay quiet and leave no clutter behind.
        unawaited(deleteConversation(convId));
        return;
      }
      done(reply);
    }
    // A bot's own wake decides for itself whether to reach out (and how), through its interruption budget.
    if (_botWakeConvs.remove(convId) != null) return;
    if (cancelled || !notifyWhenDone || !wanted) return;
    // A bot answered while the app was closed: it texts like a colleague, and the owner can reply from the notification.
    final replier = Bots.I.byConv(convId);
    if (replier != null && !(appVisible && currentId == convId)) {
      final last = list.lastWhere((m) => m.role == 'assistant' && m.content.trim().isNotEmpty, orElse: () => ChatMessage(id: '', role: 'assistant'));
      if (last.id.isNotEmpty) {
        await SystemBridge.I.notifyBot(
            id: 9200 + (replier.id.hashCode % 500).abs(), name: replier.name, body: BotOutcome.visible(last.content), payload: 'conv/$convId', reply: true);
      }
      return;
    }
    // A task started from Live: Live says it out loud if the call is still on, and a notification always follows.
    final fromLive = _liveTaskConvs.contains(convId);
    // Looking at this chat right now: the reply is on screen, no notification needed.
    if (appVisible && currentId == convId && !fromLive) return;
    var text = '';
    for (final m in list.reversed) {
      if (m.role == 'assistant' && m.content.trim().isNotEmpty) {
        text = m.content.trim();
        break;
      }
    }
    final c = conversations.where((e) => e.id == convId).firstOrNull;
    var media = '';
    for (final m in list.reversed) {
      if (m.role == 'user') break;
      final r = m.role == 'tool' ? m.content : '';
      if (r.startsWith('IMAGE_SAVED')) media = 'image';
      if (r.startsWith('AUDIO_SAVED')) media = 'sound';
      if (r.startsWith('VIDEO_SAVED')) media = 'video';
      final card = AiModels.readCard(r);
      if (card != null) media = switch ('${card['kind']}') { 'image' || 'images' => 'image', 'audio' => 'sound', 'video' => 'video', _ => '' };
      if (media.isNotEmpty) break;
    }
    var n = AppState.notificationFor(c?.title ?? '', text, media: media);
    if (scheduledRun && n.$3 != 'scheduled') n = AppState.notificationFor('Scheduled: ${c?.title ?? ''}', text, media: media);
    await SystemBridge.I.notify(
      id: convId.hashCode & 0x7ffffff,
      title: n.$1,
      body: n.$2,
      kind: n.$3,
      payload: 'conv/$convId',
    );
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
