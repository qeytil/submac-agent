// Settings, sign-in/session, banners and app-wide preferences.
// Split out of app_state.dart (no behaviour change). Fields stay on AppState.
part of '../app_state.dart';

extension AppStateSettings on AppState {
  // Models: everything runs on SubMac Cloud. There is nothing for the user to set up, and there
  // is one model: `submac`. It is bound when the conversation starts and never re-picked.
  List<ProviderConfig> get providers => [Cloud.provider];

  ProviderConfig? get activeProvider => Cloud.provider;

  String get model => Cloud.submac;

  /// The one model every call uses (chat, bots, titles, summaries, calls' wrap-up). The server picks the real
  /// model behind `submac` and swaps only when one fails (PLAN 1.1). What a message is about changes the prompt
  /// and the tools, never the model.
  ModelRef get submacRef => ModelRef(Cloud.provider, Cloud.submac);

  /// "Think harder" from the composer, for this app session only ('auto', 'quick' or 'think'). It never changes the
  /// model: 'think' sends the effort hint `high` and gives every step the full prompt. Not saved (PLAN 1.7).
  String get thinking => _thinkingNow;

  void setThinking(String v) {
    _thinkingNow = v;
    _notify();
  }

  /// The chat stays quiet: one working line while SubMac works, and the turn's work (thinking, tools, notes) folded
  /// into categorized sections the user opens (owner, 2026-11-03, replacing "show every step" from earlier that day).
  /// Saying "show steps" in a message still shows that turn's steps in full.
  bool get showSteps => false;

  /// Making a picture is a separate capability switched on from the server, not a model the user picks.
  bool get hasImageModel => Cloud.features.value.image;

  /// The user writes Somali in this chat now: their **newest** message reads Somali, or they chose Somali
  /// replies. Only the newest message decides, so when they switch to English the reply switches too
  /// (owner rule, 2026-10-31: always speak the language the user speaks). Learning it once also tells
  /// calls to speak Somali well from the first word.
  bool somaliIn(List<ChatMessage> list) {
    if (replyLanguage == 'Somali') return true;
    for (final m in list.reversed) {
      if (m.role != 'user' || m.content.startsWith(botWakeMark)) continue;
      if (Somali.detect(m.content)) {
        if (local.prefs.getBool('speaks_somali') != true) local.prefs.setBool('speaks_somali', true);
        return true;
      }
      return false;
    }
    return false;
  }

  /// The current chat is in Somali (for voice typing in the right language).
  bool get somaliNow => somaliIn(messages);

  /// For calls: the user is known to speak Somali (chose it, wrote it before, or the phone is set to Somali).
  bool speaksSomali([String? convId]) {
    if (replyLanguage == 'Somali' || local.prefs.getBool('speaks_somali') == true) return true;
    if (Platform.localeName.toLowerCase().startsWith('so')) return true;
    final list = convId == null ? null : _lists[convId];
    return list != null && somaliIn(list);
  }

  void setReplyLanguage(String v) {
    replyLanguage = v;
    local.prefs.setString('replyLanguage', v);
    _notify();
  }

  void setDeepResearch(bool v) {
    deepResearch = v;
    _notify();
  }

  void pickSkill(Skill? s) {
    pickedSkill = s;
    _notify();
  }

  void setNotifyWhenDone(bool v) {
    notifyWhenDone = v;
    local.prefs.setBool('notifyWhenDone', v);
    _notify();
  }

  bool get fullAccess => approvalMode == 'full';

  /// Token limit per task, in thousands (0 = none). When reached, the task wraps up with a status.
  int get taskBudgetK => local.taskBudgetK;

  void setTaskBudgetK(int v) {
    local.taskBudgetK = v;
    _notify();
  }

  Conversation? get current {
    for (final c in conversations) {
      if (c.id == currentId) return c;
    }
    return null;
  }

  // ---------- init ----------
  Future<void> initLocal() async {
    await local.init();
    // The run journals (a killed task resumes from its journal on the next start).
    await RunJournal.useAppFolder();
    await _forgetOldModelSetup();
    themeMode = local.themeMode;
    agentEnabled = local.agentEnabled;
    approvalMode = local.approvalMode;
    liveVoice = local.liveVoice;
    phoneAccess = await DeviceAccess.isGranted();
    memory.loadLocal();
    BrowserAgent.I.loadSavedLogin = (site) async {
      final raw = await local.secret('login_$site');
      if (raw.isEmpty) return null;
      try {
        return Map<String, String>.from(jsonDecode(raw) as Map);
      } catch (_) {
        return null;
      }
    };
    BrowserAgent.I.saveLogin = (site, u, pw) async {
      await local.setSecret('login_$site', jsonEncode({'username': u, 'password': pw}));
      final sites = savedLoginSites..remove(site)..add(site);
      await local.setSecret('loginSites', jsonEncode(sites));
    };
    _wireBrowserJobs();
    // The chat of the task asking (the zone says which task), not whichever chat used the browser last: with tasks in
    // two chats, a sign-in form used to land in the wrong one.
    String browserChat() {
      final job = BrowserAgent.jobNow;
      return BrowserJobs.I.jobs.where((x) => x.id == job).firstOrNull?.convId ?? _browserConv ?? currentId ?? '';
    }
    BrowserAgent.I.askLogin = (site) => askUser(UserAsk(
          kind: 'login',
          convId: browserChat(),
          title: '$site needs your login',
          prompt: 'SubMac will sign in for you. Your password goes straight into the page; the AI never sees it.',
          site: site,
        ));
    BrowserAgent.I.confirmLogin = (site, user) async {
      final r = await askUser(UserAsk(
          kind: 'login_confirm',
          convId: browserChat(),
          title: 'Sign in to $site?',
          prompt: user.isEmpty ? 'SubMac will use the login you saved on this phone.' : 'SubMac will use your saved login: $user',
          site: site,
          options: const ['Continue', 'Use another account'],
      ));
      if (r == null) return null;
      return r['choice'] == 'Use another account' ? 'other' : 'use';
    };
    memoryEnabled = local.memoryEnabled;
    // Speed: the encrypted reads are slow one by one on Android, so they all run together, alongside the phone setup.
    Future<String> sec(String k) => local.secret(k).catchError((_) => '');
    final keys = Future.wait([sec('loginSites'), sec('braveKey'), sec('tavilyKey'), sec('githubToken'), sec('notionToken'), sec('mcpServers')]);
    final apps = _loadApps().catchError((_) {});
    // Alarms that came while this loads run once it is done (AlarmGate): the bots and scheduled tasks, and also the
    // owner's connected apps and MCP servers, so a bot's run started by an alarm with the app closed can use them
    // (2026-11-06: the gate opened before they were read, and headless runs found no connected apps).
    final system = _initSystem().catchError((_) {});
    try {
      await _loadKeysAndApps(keys, apps);
    } finally {
      await system;
      _alarmGate.open();
    }
  }

  Future<void> _loadKeysAndApps(Future<List<String>> keys, Future<void> apps) async {
    final k = await keys;
    try {
      if (k[0].isNotEmpty) savedLoginSites = List<String>.from(jsonDecode(k[0]) as List);
    } catch (_) {}
    WebTools.braveKey = k[1];
    WebTools.tavilyKey = k[2];
    ConnectorTools.githubToken = k[3];
    ConnectorTools.notionToken = k[4];
    try {
      if (k[5].isNotEmpty) {
        mcpServers = [for (final e in jsonDecode(k[5]) as List) McpServerConfig.fromJson(Map<String, dynamic>.from(e as Map))];
      }
    } catch (_) {}
    await apps;
  }

  Future<void> onSignedIn() async {
    unawaited(Cloud.refreshStatus(force: true));
    // "Always on" (owner 2026-11-08): now there is an account and its bots, hold the steady service.
    unawaited(initAlwaysOn());
    // Plan 2.6: settle replied/ignored and kept_7d, then send queued events (bots load first).
    unawaited(Future<void>.delayed(const Duration(seconds: 30), () => Events.I.sweep([for (final x in Bots.I.bots) (x.id, x.active)])));
    Cloud.usage.removeListener(_usageNotice);
    Cloud.usage.addListener(_usageNotice);
    unawaited(memory.sync().then((_) => _notify()));
    if (mcpServers.isNotEmpty) unawaited(refreshMcpTools());
    // The agent's engine starts with the app, so the first message does not wait for it (owner, 2026-11-02).
    unawaited(warmAgent());
    // Bots are kept in the account too: a new phone gets them back here, and later changes go up by themselves.
    BotSync.I.postToChat = _cloudBotMessage;
    // The cloud handed a job over (it needs the phone): run it here now, in the background, and notify the result.
    BotSync.I.onHandoff = (b, instruction, kind, needs) {
      if (!b.active) return;
      unawaited(_botWake(b, 'handed over from the cloud${needs.isEmpty ? '' : ' (it needs $needs)'}',
          instruction.isEmpty ? Bots.heartbeat : instruction, kind == 'call' ? 'call' : (kind == 'message' ? 'message' : 'work')));
    };
    // "From SubMac": team messages sent "in chat" also appear in the SubMac team chat (edits and deletes follow).
    Inbox.I.onChatItems = _mirrorTeamMessages;
    unawaited(Inbox.I.refresh());
    unawaited(BotSync.I.start().catchError((Object e) => debugPrint('bot sync start: $e')));
    // Saved browser flows are kept in the account too: learned on this phone, replayed on the next one.
    unawaited(SkillSync.I.start().catchError((Object e) => debugPrint('skill sync start: $e')));
    // CB-46: a bot wake that came before the account was restored runs now.
    unawaited(_runHeldWakes().catchError((Object e) => debugPrint('held wakes: $e')));
    // Scheduled tasks belong to the account: arm only this account's.
    unawaited(Scheduler.I.useAccount(repo.userId ?? '').catchError((Object e) => debugPrint('scheduler: $e')));
    await refreshConversations();
    // A task Android killed in the middle picks up where it left off.
    unawaited(resumeKilledRuns().catchError((Object e) => debugPrint('resume runs: $e')));
    try {
      final s = await repo.loadSettings();
      aboutYou = (s['about_you'] ?? '') as String;
      howToRespond = (s['how_to_respond'] ?? '') as String;
      _notify();
    } catch (_) {}
  }

  Future<void> refreshConversations() async {
    // Chats live on the phone: show them at once, then join in anything from the account backup.
    try {
      final here = await repo.localConversations();
      if (here.isNotEmpty || conversations.isEmpty) conversations = here;
    } catch (_) {}
    loadingConversations = conversations.isEmpty;
    _notify();
    try {
      conversations = await repo.listConversations();
    } catch (e) {
      if (conversations.isEmpty) {
        banner = Calm.offline('$e') ? 'You\'re offline. Your chats will appear when you\'re back online.' : 'Your chats didn\'t load. Pull down or reopen SubMac to try again.';
      }
    }
    loadingConversations = false;
    _notify();
    unawaited(_backupRound());
  }

  /// Sends waiting changes to the account backup, then (at most every few hours) packs old chats away.
  Future<void> _backupRound() async {
    try {
      await repo.sync();
      final last = local.prefs.getInt('archiveRunAt') ?? 0;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - last < const Duration(hours: 6).inMilliseconds) return;
      local.prefs.setInt('archiveRunAt', now);
      final n = await repo.archiveOld(skip: {for (final r in runs) r.convId, if (currentId != null) currentId!});
      if (n > 0) {
        for (final c in conversations) {
          final m = repo.store.index[c.id];
          if (m != null) c.archivePath = m['archive_path'] as String?;
        }
        _notify();
      }
    } catch (_) {}
  }

  void clearBanner() {
    banner = null;
    _notify();
  }

  /// Takes the banner [msg] for showing, once: true only for the first caller while it is still the banner. Several
  /// rebuilds in one frame each schedule a show; the rest get false, so the same snackbar never appears twice.
  bool takeBanner(String msg) {
    if (banner != msg) return false;
    banner = null;
    _notify();
    return true;
  }

  void showBanner(String text, [Map<String, String> args = const {}]) {
    banner = text;
    bannerArgs = args;
    _notify();
  }

  /// A banner with `{name}` holes ([args] fill them after translation).
  void setBanner(String text, Map<String, String> args) {
    banner = text;
    bannerArgs = args;
  }

  // ---------- settings ----------
  void setThemeMode(ThemeMode m) {
    themeMode = m;
    local.themeMode = m;
    _notify();
  }

  void setAgentEnabled(bool v) {
    agentEnabled = v;
    local.agentEnabled = v;
    _notify();
  }

  void setApprovalMode(String v) {
    approvalMode = v;
    local.approvalMode = v;
    _notify();
  }

  // ---------- always on ----------
  /// "Always on" (owner 2026-11-08) is on by default: a steady foreground service plus a local pulse, so the digital
  /// people feel present instead of waking only on an alarm. Turning it off keeps the old behaviour: the service runs
  /// only while a task actually does.
  bool get alwaysOn => AlwaysOn.I.on;

  /// Called once at startup, after the local store is ready. It only keeps the phone awake once there is an account to
  /// work for, so a signed-out start never claims "your digital people are active".
  Future<void> initAlwaysOn() async {
    AlwaysOn.I.load(local.prefs);
    if (!AlwaysOn.I.on || repo.userId == null) return;
    await SystemBridge.I.keepAlive(true, text: AlwaysOn.body);
    startAlwaysOnPulse();
  }

  Future<void> setAlwaysOn(bool v) async {
    await AlwaysOn.I.set(local.prefs, v);
    _alwaysOnPulse?.cancel();
    _alwaysOnPulse = null;
    if (v) {
      await SystemBridge.I.keepAlive(true, text: AlwaysOn.body);
      startAlwaysOnPulse();
    } else if (!runs.any((r) => !r.side) && _officeBusy.isEmpty) {
      // Nothing is running now, so the steady service can go; a running task keeps its own hold.
      await SystemBridge.I.keepAlive(false);
    }
    _notify();
  }

  /// The few-minute pulse while "Always on" is on. Idempotent: calling it again restarts the same single timer.
  void startAlwaysOnPulse() {
    if (!AlwaysOn.I.on) return;
    _alwaysOnPulse?.cancel();
    _alwaysOnPulse = Timer.periodic(const Duration(minutes: 5), (_) {
      unawaited(_alwaysOnTick());
    });
  }

  /// One pulse: keep the service steady, and wake a heartbeat the OS killed and never redelivered. Local only: no model
  /// call happens unless a bot is genuinely due.
  Future<void> _alwaysOnTick() async {
    if (!AlwaysOn.I.on) return;
    unawaited(SystemBridge.I.keepAlive(true, text: AlwaysOn.body));
    final now = DateTime.now();
    for (final b in Bots.I.bots) {
      if (!b.active) continue;
      final hb = b.effectiveHeartbeat;
      if (hb <= 0 || b.quietNow(now)) continue;
      final last = b.lastWake ?? now;
      // Only when the exact heartbeat alarm is clearly overdue (the OS killed it); otherwise it already pan.
      if (now.difference(last) < Duration(hours: hb, minutes: 5)) continue;
      // Awaited: the wake's own bookkeeping (its alarm, its line) finishes before the next bot, and before the pulse ends.
      await Bots.I.fire(Bots.alarmId(b, 'hb'));
    }
  }

  @visibleForTesting
  Future<void> alwaysOnTickForTest() => _alwaysOnTick();
}
