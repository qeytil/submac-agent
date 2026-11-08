// Bots, teams and offices: hiring, wake-ups, office job pump, bot calls.
// Split out of app_state.dart (no behaviour change). Fields stay on AppState.
part of '../app_state.dart';

extension AppStateBots on AppState {
  /// Plan 2.2: work nobody is watching (a bot's own wake, office work other than answering the owner) runs in the
  /// background lane, on the bots' share of the daily allowance. Chats with the owner never do.
  bool _backgroundLane(String convId) {
    final k = _botWakeConvs[convId];
    if (k == null || k == 'chat') return false;
    return true;
  }

  void _notePaused(Bot b) {
    if (!b.journal.any((e) => e.kind == 'budget' && e.text == AppState.bgPausedText && DateTime.now().difference(e.at).inHours < 20)) {
      b.log('budget', AppState.bgPausedText);
      unawaited(Bots.I.save());
    }
  }

  Set<String> get botConvIds => {for (final b in Bots.I.bots) if (b.convId.isNotEmpty) b.convId};

  String? botConvFor(String botId) {
    final c = Bots.I.byId(botId)?.convId ?? '';
    return c.isEmpty ? null : c;
  }

  Future<bool> _ensureBotConv(Bot b) async {
    // A known chat (even before the chat list has loaded, e.g. woken by an alarm at boot).
    if (b.convId.isNotEmpty) {
      if (_lists[b.convId] == null) {
        try {
          _lists[b.convId] = await repo.listMessages(b.convId);
        } catch (_) {
          return false;
        }
      }
      return true;
    }
    try {
      final c = await repo.createConversation(title: b.name, model: model);
      conversations.insert(0, c);
      _lists[c.id] = <ChatMessage>[];
      b.convId = c.id;
      await Bots.I.save();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// A message a bot wrote while working in the cloud (plan 2.1), posted in its chat once (the id is the same on
  /// every phone). The cloud already sent the notification.
  Future<void> _cloudBotMessage(Bot b, String text, String id) async {
    if (text.trim().isEmpty || !await _ensureBotConv(b)) return;
    final list = _lists[b.convId];
    if (list == null || list.any((m) => m.id == id)) return;
    Events.I.result(b.id, 'cloud');
    // New this session: it arrives with the chat's message animation (once).
    final m = ChatMessage(id: id, role: 'assistant', content: text.trim())..animateIn = true;
    Future<void>.delayed(const Duration(seconds: 2), () => m.animateIn = false);
    list.add(m);
    _notify();
    try {
      await repo.insertMessage(b.convId, m);
    } catch (_) {}
  }

  /// Posts SubMac team messages that were sent "in chat" into one "SubMac team" chat, once each. An edit by the team
  /// replaces the message (same id), a delete removes it. Rendered as a team card (name 'submac_team').
  Future<void> _mirrorTeamMessages(List<InboxItem> all) async {
    if (_mirroring) return;
    _mirroring = true;
    try {
      final want = all.where((i) => i.inChat && i.kind == 'admin_message').toList()..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      Map<String, dynamic> posted = {};
      try {
        posted = Map<String, dynamic>.from(jsonDecode(local.prefs.getString(AppState._teamPostedKey) ?? '{}') as Map);
      } catch (_) {}
      var changed = false;
      for (final it in want) {
        final stamp = it.updatedAt.toUtc().toIso8601String();
        if (it.deleted) {
          if (posted.remove(it.id) != null) {
            for (final l in _lists.values) {
              l.removeWhere((m) => m.id == it.id);
            }
            try {
              await repo.deleteMessages([it.id]);
            } catch (_) {}
            changed = true;
          }
          continue;
        }
        if (posted[it.id] == stamp) continue;
        final conv = await _teamConv();
        if (conv == null) break;
        final list = _lists[conv] ??= await repo.listMessages(conv).catchError((_) => <ChatMessage>[]);
        final m = ChatMessage(id: it.id, role: 'assistant', name: 'submac_team', content: '**${it.title}**\n\n${it.body}'.trim());
        final i = list.indexWhere((x) => x.id == it.id);
        if (i >= 0) {
          list[i] = m;
        } else {
          list.add(m);
        }
        try {
          await repo.insertMessage(conv, m);
          posted[it.id] = stamp;
          changed = true;
        } catch (_) {}
      }
      if (changed) {
        await local.prefs.setString(AppState._teamPostedKey, jsonEncode(posted));
        _notify();
      }
    } finally {
      _mirroring = false;
    }
  }

  /// The "SubMac team" chat (made on first use; made again if the user deleted it).
  Future<String?> _teamConv() async {
    final id = local.prefs.getString(AppState._teamConvKey);
    if (id != null && conversations.any((c) => c.id == id)) return id;
    try {
      final c = await repo.createConversation(title: 'SubMac team');
      conversations.insert(0, c);
      _lists[c.id] = <ChatMessage>[];
      await local.prefs.setString(AppState._teamConvKey, c.id);
      return c.id;
    } catch (_) {
      return null;
    }
  }

  /// Start working with a bot: it gets its own chat, and waits there for the owner's first message (Grok: "a new Bot
  /// waits for its first task"). It no longer speaks first: the empty chat shows its face, name and role, and the bot
  /// answers when the owner writes (owner 2026-10-24: "nobody talks for no reason").
  Future<String?> hireBot(Bot b) async {
    if (!await _ensureBotConv(b)) return 'I need the internet to open this chat. Try again once you\'re online.';
    await Bots.I.hire(b, b.convId);
    await openConversation(b.convId);
    return null;
  }

  /// Plan 5.2 "Hire, don't build": a new colleague from a role spec (RoleHire.spec) or a described bot. Starts New
  /// (asks before every change), knows the answers to its three questions, and has its routine set.
  Future<Bot> hireForJob(Map<String, dynamic> spec, {String origin = '', String roleId = '', Bot? described}) async {
    final b = described ?? await Bots.I.create({...spec, 'name': RoleHire.freeName('${spec['name'] ?? 'Assistant'}', Bots.I.bots.map((x) => x.name))});
    if (described != null) {
      for (final r in (spec['routines'] as List? ?? const [])) {
        final m = Map<String, dynamic>.from(r as Map);
        b.routines.add(BotRoutine(id: 'r${b.routines.length + 1}', time: '${m['time']}', days: '${m['days']}', kind: '${m['kind']}', instruction: '${m['do']}'));
      }
    }
    final voice = '${spec['voice'] ?? ''}';
    if (voice.isNotEmpty) b.voice = voice;
    final ins = BotPackage.scrubSecrets('${spec['instructions'] ?? ''}').trim();
    if (ins.isNotEmpty) b.instructions = b.instructions.isEmpty ? ins : '${b.instructions}\n$ins';
    for (final m in (spec['memory'] as List? ?? const [])) {
      if ('$m'.trim().isNotEmpty && !b.memory.contains('$m')) b.memory.add('$m');
    }
    b
      ..origin = origin.isEmpty ? b.origin : origin
      ..roleId = roleId
      ..trust = BotTrust.levelNew;
    await Bots.I.save();
    return b;
  }

  /// Hires [b] and has it do [task] right away in its chat while the owner watches (fires `hired` now and
  /// `first_result` when the result lands).
  Future<String?> startFirstJob(Bot b, String task) async {
    if (!await _ensureBotConv(b)) return 'I need the internet to open this chat. Try again once you\'re online.';
    b.desk.removeWhere((t) => t.id == 'first');
    b.desk.add(DeskTask('first', task.length > 140 ? '${task.substring(0, 139)}…' : task, status: 'doing'));
    await Bots.I.hire(b, b.convId);
    await openConversation(b.convId);
    _firstJob.add(b.id);
    await _botWake(b, 'first job: the user just hired you and is watching your chat', RoleHire.firstJobPrompt(task), 'chat');
    return null;
  }

  Future<void> openBot(Bot b) async {
    if (!b.active) {
      await hireBot(b);
      return;
    }
    if (!await _ensureBotConv(b)) return;
    noteBotOpened(currentId, Bots.I.byConv(currentId) != null);
    await openConversation(b.convId);
  }

  /// Remembers the chat a bot chat was opened over. Going from one bot to another keeps the first chat.
  void noteBotOpened(String? from, bool fromIsBot) {
    if (fromIsBot && _botOpenedOver) return;
    _backFromBot = fromIsBot ? null : from;
    _botOpenedOver = true;
  }

  @visibleForTesting
  String? get backTargetForTest => _backFromBot;

  /// The phone's Back in a bot's chat: back to the chat it was opened over. False when this is not a bot chat.
  Future<bool> backFromBotChat() async {
    if (Bots.I.byConv(currentId) == null) return false;
    final to = _backFromBot;
    _backFromBot = null;
    _botOpenedOver = false;
    if (to != null && to != currentId && conversations.any((c) => c.id == to)) {
      await openConversation(to);
    } else {
      newChat();
    }
    return true;
  }

  /// Wakes a bot to work on its own. It decides at the end whether to stay silent, keep a note, message or call.
  Future<void> _botWake(Bot b, String reason, String instruction, String kind) async {
    // CB-46: an alarm can start SubMac before it is ready (no account restored yet). The wake waits a little, and is
    // otherwise kept and run once SubMac is ready, never dropped without a word.
    final key = Bots.I.wakeKey(b) ?? '${b.id}|$reason|$instruction';
    if (!await _awaitWakeReady()) {
      // A mission retries by itself (Missions.wake): its wake is never held with a stale plan in it.
      if (kind != 'chat' && kind != 'mission' && await Bots.I.holdWake(b, key, reason, instruction, kind)) {
        b.log('note', 'Woken for $reason before SubMac was ready. I will do it as soon as SubMac is ready.');
        await Bots.I.save();
      }
      return;
    }
    // A check-in that was put off (busy, offline) is still a check-in: it gets the cheap "anything to do?" question
    // first, not a full wake told to "Do this now: Heartbeat check" (BUGHUNT 2026-10-23 #4).
    // A retried one keeps its "(retry)" mark for the outcome, so it is retried once only.
    final asked = instruction;
    if (Bots.isHeartbeat(instruction)) instruction = '';
    if (!_wakeMayClaim(b)) {
      await _wakeLater(b, instruction, kind);
      return;
    }
    // Its own daily token budget is used up: background work waits for tomorrow (chats with the owner still answer).
    if (b.overBudget && kind != 'chat') {
      if (!b.journal.any((e) => e.kind == 'budget' && DateTime.now().difference(e.at).inHours < 20)) {
        b.log('budget', 'Skipped work: today\'s token budget is used up');
        await Bots.I.save();
      }
      return;
    }
    // A plain check-in first asks the fast model one yes/no question on a few lines (~500 tokens) instead of
    // waking the bot with its whole prompt (~20k) only to end with [no reply], which is how most check-ins end.
    if (kind == 'work' && instruction.trim().isEmpty && !await _worthWaking(b)) {
      b.lastWake = DateTime.now();
      b.log('work', 'Checked in: nothing worth your time.');
      await Bots.I.save();
      return;
    }
    // Owner 2026-11-07: a bot is governed by the allowance in its own profile ([b.overBudget], checked above), never
    // by a hardcoded account-wide guard. SubMac's server still refuses a SubMac call when the whole account is out.
    if (!await _ensureBotConv(b)) return;
    b.lastWake = DateTime.now();
    final now = DateTime.now();
    final budget = b.quietNow()
        ? 'It is the user\'s quiet hours now (${b.quietFrom}:00 to ${b.quietTo}:00): do not message or call; @note or [no reply] only.'
        : 'Today you may still send ${b.messagesLeft} message(s) and make ${b.callsLeft} call(s).';
    final String task;
    if (kind == 'mission') {
      // Mission mode (owner 2026-11-07): the instruction carries the goal, plan, log and rules (Missions.wakeInstruction).
      task = '$botWakeMark[Woken: $reason. ${now.toIso8601String().substring(0, 16).replaceFirst('T', ' ')}]\n$instruction\n'
          '${b.quietNow() ? 'It is the owner\'s quiet hours: work, but do not message or call them.' : ''}'.trim();
    } else if (kind == 'chat') {
      task = '$botWakeMark[$reason]\n$instruction\nWrite directly to the user (they are watching this chat). Keep it short.';
    } else {
      final what = instruction.isEmpty
          ? 'This is your regular check-in. Look at your mission, memory, desk and promised follow-ups. Is there something '
              'genuinely useful to do for the user right now (progress on work you own, a deadline coming, news on what you track, '
              'something you promised)? If yes, do the real work with your tools. If not, reply with only [no reply]. Never invent busywork.'
          : 'Do this now: $instruction';
      final style = switch (kind) {
        'message' => 'This routine always ends with @message (one short, specific message).',
        'call' => 'This is a planned call. Prepare what you will say as 2 to 4 short bullet notes, then end with @call: <a short reason '
            'shown on the ringing screen>.',
        _ => '',
      };
      task = '$botWakeMark[Woken: $reason. ${now.toIso8601String().substring(0, 16).replaceFirst('T', ' ')}]\n$what\n\n'
          'You are working in the background: the user is not watching. Work fully on your own, no questions unless essential. '
          'Do the whole job now and deliver the result itself: never a message that you are starting, have queued something, or '
          'will report later, and never ask the user to say "start" or "go".\n'
          'Save what you learn (bot_remember) and keep your desk current (bot_desk).\n'
          'When done, write what the user should see, then put ONE tag alone on the very last line. Nothing worth telling: '
          'reply with only [no reply] (most check-ins end like this; staying quiet is fine).\n'
          '@note = worth keeping in our chat, not worth a notification\n'
          '@message = worth reaching them now: your text above is ONE short, specific message (under 300 characters), like a '
          'colleague texting, with the result itself\n'
          '@call: <reason> = only when it is urgent, or a planned call\n'
          '$budget $style'.trim();
    }
    // The checks above awaited (a model call, the chat loading): an office job may have taken the chat meanwhile.
    if (!_wakeMayClaim(b)) {
      await _wakeLater(b, instruction, kind);
      return;
    }
    _botWakeConvs[b.convId] = kind;
    // With SubMac closed the foreground service (and its wake lock) carries the work; its line names the bot and the
    // task: "<Bot name> · <task title>" (2026-11-05).
    if (kind != 'chat' && !appVisible) {
      final title = kind == 'mission' ? 'Mission: ${Missions.I.liveOf('bot', b.id)?.goal ?? ''}' : (Bots.isHeartbeat(asked) ? '' : asked);
      unawaited(SystemBridge.I.keepAlive(true, text: BgRun.line(b.name, BgRun.title(title))));
    }
    String? err;
    try {
      err = await startBackgroundTask(task, reuseConvId: b.convId, onDone: (reply) => unawaited(_botOutcome(b, reply, kind, instruction: asked.startsWith('(retry) ') ? asked : instruction)));
    } catch (e) {
      err = '$e';
    }
    if (err != null) {
      if (_botWakeConvs[b.convId] == kind) _botWakeConvs.remove(b.convId); // only our own mark
      if (!runs.any((r) => !r.side)) await SystemBridge.I.keepAlive(false);
    }
  }

  /// CB-46: a bot wake can run: a model provider and a signed-in account.
  bool get _wakeReady {
    if (activeProvider == null) return false;
    try {
      return repo.userId != null;
    } catch (_) {
      return false; // the account is not set up yet (a cold start)
    }
  }

  /// Waits up to [Bots.readyWait] for [_wakeReady].
  Future<bool> _awaitWakeReady() async {
    if (_wakeReady) return true;
    final wait = Bots.readyWait;
    final step = wait < const Duration(milliseconds: 250) ? wait : const Duration(milliseconds: 250);
    final until = DateTime.now().add(wait);
    while (DateTime.now().isBefore(until)) {
      await Future<void>.delayed(step);
      if (_wakeReady) return true;
    }
    return _wakeReady;
  }

  /// CB-46: runs the wakes that came before SubMac was ready, once each (at the start, and after signing in).
  Future<void> _runHeldWakes() async {
    if (!_wakeReady) return;
    for (final w in await Bots.I.takeHeldWakes()) {
      final b = Bots.I.byId(w.bot);
      if (b == null || !b.active) continue;
      try {
        await _botWake(b, w.reason, w.instruction, w.kind);
      } catch (e) {
        debugPrint('held wake: $e');
      }
    }
  }

  bool _wakeMayClaim(Bot b) => Bots.wakeMayClaim(
      hasMarker: b.convId.isNotEmpty && _botWakeConvs.containsKey(b.convId),
      running: b.convId.isNotEmpty && runs.any((r) => r.convId == b.convId && !r.side));

  /// Busy (a run or another wake in its own chat): come back in 15 minutes, once (not one more follow-up per busy wake).
  Future<void> _wakeLater(Bot b, String instruction, String kind) async {
    if (kind == 'chat' || kind == 'mission' || Bots.hasPendingFollowup(b, instruction, kind)) return;
    b.followups.add(BotFollowup('f${DateTime.now().millisecondsSinceEpoch % 1000000}', DateTime.now().add(const Duration(minutes: 15)),
        instruction.isEmpty ? Bots.heartbeat : instruction, kind, local: true));
    await Bots.I.save();
    await Bots.I.arm(b);
  }

  /// Is there something worth a full wake right now? Same check the cloud runner does. On any doubt (no answer,
  /// an error) the bot wakes as before.
  Future<bool> _worthWaking(Bot b) async {
    // On the bot's own model (owner 2026-11-06): a bot on one of the owner's providers is never stopped here by
    // SubMac's allowance, and its check is not billed to it either.
    final route = BotModelRoute.of(b);
    String cut(String t, int n) => t.length > n ? '${t.substring(0, n)}…' : t;
    final open = b.desk.where((t) => t.status != 'done').take(12).map((t) => '- (${t.status}) ${cut(t.text, 160)}').join('\n');
    final ups = b.followups.take(6).map((f) => '- ${f.at.toIso8601String().substring(0, 16)} ${cut(f.instruction, 140)}').join('\n');
    final recent = b.journal.reversed.take(5).toList().reversed.map((j) => '- ${j.at.toIso8601String().substring(5, 16)} ${j.kind}: ${cut(j.text, 140)}').join('\n');
    final mem = b.memory.reversed.take(8).toList().reversed.map((m) => '- ${cut(m, 160)}').join('\n');
    final prompt = 'You decide if ${b.name} (${b.role.isEmpty ? 'assistant' : b.role}) should do work for the user right now.\n'
        'Job: ${cut(b.mission.isEmpty ? '(none)' : b.mission, 300)}\nInstructions: ${cut(b.instructions.trim().isEmpty ? '(none)' : b.instructions.trim(), 400)}\n'
        'Working on:\n${open.isEmpty ? 'none' : open}\nPromised follow-ups (each runs by itself at its time; never do one early):\n${ups.isEmpty ? 'none' : ups}\n'
        'Lately:\n${recent.isEmpty ? 'none' : recent}\nSome memory:\n${mem.isEmpty ? 'none' : mem}\n'
        'Now (local time): ${DateTime.now().toIso8601String().substring(0, 16).replaceFirst('T', ' ')}\n\n'
        'Is there something genuinely useful to do now (progress on open work, a deadline, news on what it tracks)? A follow-up that is not '
        'due yet is not a reason: it wakes the bot by itself. Never busywork. '
        'Reply exactly NO, or YES: <the one thing, in one line>.';
    try {
      final t = await BotLlm.complete(b, [
        {'role': 'user', 'content': prompt},
      ], maxTokens: 60, source: 'bot', background: true, route: route, provider: submacRef.provider);
      final a = t.trim();
      if (a.isEmpty) return true;
      return !RegExp(r'^\W*no\b', caseSensitive: false).hasMatch(a);
    } on LlmException catch (e) {
      // The bots' share of today's allowance is used: the full wake would be refused too.
      if (e.code == 'background_paused' || e.code == 'daily_limit') {
        _notePaused(b);
        return false;
      }
      return true;
    } catch (_) {
      return true;
    }
  }

  /// What a wake ended with: stay silent, keep a note, send a message, or call, within the bot's budget.
  Future<void> _botOutcome(Bot b, String reply, String kind, {String instruction = ''}) async {
    final list = _lists[b.convId];
    if (list == null) return;
    // Offline or the provider was busy: a routine or promised follow-up is not lost, it runs again in 10 minutes (once).
    final failure = _wakeFailure(b.convId);
    if (kind == 'mission') {
      await _missionBotOutcome(b, list, reply, failure);
      return;
    }
    if (kind != 'chat' && (failure == 'offline' || failure == 'busy')) {
      await _dropWakeTurn(b.convId);
      if (!instruction.startsWith('(retry) ')) {
        b.followups.add(BotFollowup('f${DateTime.now().millisecondsSinceEpoch % 1000000}', DateTime.now().add(const Duration(minutes: 10)),
            '(retry) ${instruction.isEmpty ? Bots.heartbeat : instruction}', kind, local: true));
        await Bots.I.save();
        await Bots.I.arm(b);
      }
      return;
    }
    // The bots' share (or the whole allowance) ran out mid-wake: pause politely until tomorrow, no retry.
    if (kind != 'chat' && failure == 'credit') {
      await _dropWakeTurn(b.convId);
      _notePaused(b);
      return;
    }
    if (kind == 'chat') {
      final last = list.lastWhere((m) => m.role == 'assistant' && m.content.trim().isNotEmpty, orElse: () => ChatMessage(id: '', role: 'assistant'));
      if (last.id.isNotEmpty) await _rewrite(b.convId, last, BotOutcome.visible(last.content));
      if (_firstJob.remove(b.id)) {
        // Plan 5.2: the first job of a new hire. A real result counts once (plan 2.6 first_result, kind "hire").
        final t = b.desk.where((x) => x.id == 'first').firstOrNull;
        if (last.id.isNotEmpty && failure.isEmpty && last.error == null) {
          Events.I.result(b.id, 'hire');
          if (t != null) {
            t
              ..status = 'done'
              ..updated = DateTime.now();
            b.log('work', 'Done: ${t.text}');
          }
        } else if (t != null) {
          t.status = 'todo';
        }
        await Bots.I.save();
      }
      return;
    }
    final out = BotOutcome.parse(reply);
    // CB-17: a silence tag stuck to real words is not silence: the words stay (as a quiet note, no notification).
    if (out.text.isEmpty && out.kind != 'call') {
      b.log('work', 'Checked in: nothing worth your time.');
      await _dropWakeTurn(b.convId);
      await Bots.I.save();
      return;
    }
    final last = list.lastWhere((m) => m.role == 'assistant' && m.content.trim().isNotEmpty, orElse: () => ChatMessage(id: '', role: 'assistant'));
    final visible = last.id.isEmpty ? out.text : BotOutcome.visible(last.content);
    if (last.id.isNotEmpty) await _rewrite(b.convId, last, visible.isEmpty ? out.text : visible);
    var want = out.kind;
    if (kind == 'message' && want == 'note') want = 'message';
    final may = BgRun.outreach(wakeKind: kind, want: want, allowed: Bots.I.allow(b, want), quiet: b.quietNow());
    final looking = appVisible && currentId == b.convId;
    Events.I.result(b.id, may);
    switch (may) {
      case 'call':
        _ringText[b.id] = visible;
        final rang = await _botRing(b, out.text.isEmpty ? 'Quick call' : out.text);
        if (!rang.startsWith('Ringing')) {
          // Couldn't ring (another call ringing, a Live call): the words still reach the user, never lost.
          _ringText.remove(b.id);
          if (rang.startsWith('Voice calls are not available')) break; // already sent as a notification
          if (Bots.I.allow(b, 'message') == 'message') {
            b.log('message', visible);
            Bots.I.spent(b, 'message');
            if (!looking) {
              await _notifyBot(b, visible);
            }
          } else {
            b.log('note', visible);
            await Bots.I.save();
          }
        }
      case 'message':
        b.log('message', visible);
        Bots.I.spent(b, 'message');
        Events.I.botMessaged(b.id);
        if (!looking) {
          await _notifyBot(b, visible);
        }
      default:
        b.log('note', visible);
        await Bots.I.save();
    }
  }

  /// Plan 5.2: the bot's evening note, posted in its chat like a colleague's end-of-day message.
  Future<void> _botReport(Bot b, String text, {bool notify = false}) async {
    if (!await _ensureBotConv(b)) return;
    final list = _lists[b.convId];
    if (list == null) return;
    // New this session: it arrives with the chat's message animation (once).
    final m = ChatMessage(id: _uuid.v4(), role: 'assistant', content: text.trim())..animateIn = true;
    Future<void>.delayed(const Duration(seconds: 2), () => m.animateIn = false);
    list.add(m);
    _notify();
    try {
      await repo.insertMessage(b.convId, m);
    } catch (_) {}
    if (notify && !(appVisible && currentId == b.convId) && !b.quietNow()) {
      await _notifyBot(b, text);
    }
  }

  /// Replaces a saved message's text (the tag line comes off).
  Future<void> _rewrite(String convId, ChatMessage m, String text) async {
    if (text.trim() == m.content.trim()) return;
    m.content = text.trim();
    _notify();
    try {
      await repo.deleteMessages([m.id]);
      await repo.insertMessage(convId, m);
    } catch (_) {}
  }

  int _ringId(Bot b) => 9100 + (b.id.hashCode % 500).abs();

  /// The bot calls the user: rings at the top of the screen (or full screen), 35 seconds, then a missed call.
  Future<String> _botRing(Bot b, String reason) async {
    final blocked = Bots.callBlock(b);
    if (blocked != null) {
      _ringText.remove(b.id);
      return blocked;
    }
    if (liveCtl.active) return 'The user is already on a call. Send a message instead.';
    if (!liveAvailable || Cloud.calls.value.out) {
      await _notifyBot(b, reason, summarize: false);
      return 'Voice calls are not available right now, so the user got a message instead.';
    }
    if (_ringing != null) return 'Another call is ringing.';
    Bots.I.spent(b, 'call');
    b.log('call', reason);
    _ringing = b.id;
    _ringText[b.id] = _ringText[b.id] ?? reason;
    await SystemBridge.I.ring(id: _ringId(b), botId: b.id, name: b.name, reason: reason, fullScreen: Bots.I.fullScreenCalls);
    if (appVisible) incomingCall.value = b;
    _ringTimer?.cancel();
    // Android's own timer ends the call at 36 s (it survives the app being stopped); this one is a backup.
    _ringTimer = Timer(const Duration(seconds: 40), () {
      if (_ringing == b.id) unawaited(_missedCall(b));
    });
    return 'Ringing the user now. If they do not answer, they get your message.';
  }

  Future<void> _missedCall(Bot b) async {
    if (_ringing != b.id) return;
    _ringing = null;
    _ringTimer?.cancel();
    incomingCall.value = null;
    await SystemBridge.I.ringCancel(_ringId(b));
    b.log('missed', 'Missed call');
    final text = _ringText.remove(b.id) ?? '';
    // Same slot as Android's own missed-call line, so there is only ever one.
    await _notifyBot(b, text.isEmpty ? 'Missed call' : 'Missed call. ${NotifText.summary(text, max: 200, lines: 2)}', summarize: false, id: _ringId(b) + 1000);
    await Bots.I.save();
  }

  Future<void> declineBotCall(String botId) async {
    final b = Bots.I.byId(botId);
    _ringTimer?.cancel();
    _ringing = null;
    incomingCall.value = null;
    if (b == null) return;
    await SystemBridge.I.ringCancel(_ringId(b));
    b.log('missed', 'You declined the call');
    final text = _ringText.remove(b.id) ?? '';
    if (text.isNotEmpty) {
      await _notifyBot(b, text);
    }
    await Bots.I.save();
  }

  /// Answered: a Live voice call with the bot, in its own voice and character, saved in its chat.
  Future<void> answerBotCall(String botId) async {
    final b = Bots.I.byId(botId);
    _ringTimer?.cancel();
    final reason = _ringText.remove(botId) ?? '';
    _ringing = null;
    incomingCall.value = null;
    if (b == null) return;
    await SystemBridge.I.ringCancel(_ringId(b));
    await _startBotCall(b, 'You called the user and they answered. ${reason.isEmpty ? '' : 'What you prepared: $reason. '}'
        'Greet them by voice in one short sentence as ${b.name}, then get to the point.');
  }

  /// The user calls a bot.
  Future<String?> callBot(Bot b) async {
    if (!b.active) {
      final e = await hireBot(b);
      if (e != null) return e;
    }
    return _startBotCall(b, 'The user is calling you. Answer warmly in one short sentence as ${b.name}.');
  }

  Future<String?> _startBotCall(Bot b, String opening) async {
    if (!await _ensureBotConv(b)) return 'This chat isn\'t ready yet. Try again in a moment.';
    final persona = '${Bots.I.promptOf(b)}\n\n# This is a voice call\nYou are on a live voice call with the user, as ${b.name}. '
        'Speak naturally, like a colleague on the phone: short for small talk, and a full, complete answer when they ask for '
        'detail or an explanation. Use your tools when needed and say briefly what you are doing.';
    final r = await liveCtl.start(persona: persona, voice: b.voice, opening: '[Call] $opening', convId: b.convId, bot: b.id);
    if (r == 'needs_key') {
      setBanner('Voice calls aren\'t available right now. Message {name} instead.', {'name': b.name});
      _notify();
      return 'needs_key';
    }
    liveCtl.openScreen?.call();
    return null;
  }

  /// After a call: the bot updates its memory and desk and keeps a short recap.
  Future<void> botCallEnded(String botId, int turns) async {
    final b = Bots.I.byId(botId);
    if (b == null || turns < 3) return;
    await _botWake(b, 'your voice call with the user just ended',
        'The call transcript is the latest part of this chat. Save what you learned (bot_remember), update your desk (bot_desk), '
            'and set follow-ups for anything you promised (bot_followup). Then write a short recap: decisions and next steps. End with @note.',
        'work');
  }

  /// One plain answer for a team (who speaks, the plan, the combined answer): one model call on the bots' lane,
  /// counted toward the bot's own budget (estimated from the text, about 4 characters a token).
  /// On that bot's own model (owner 2026-11-06: the lead's plan and the "who speaks" call used to go to SubMac's model
  /// whatever the lead's profile said).
  Future<String> _teamAsk(Bot b, String system, String user, {int maxTokens = OutputLimits.answer}) async {
    final route = BotModelRoute.of(b);
    if (!route.isByok) {
      await RateLimiter.acquire(submacRef.provider, (system.length + user.length) ~/ 4 + maxTokens, local, onWait: (_) {}, cancelled: () => false);
    }
    // No chat id: a team's decision is no part of the bot's private chat (bots team audit 2026-11-04).
    final t = await BotLlm.complete(b, [
      {'role': 'system', 'content': system},
      {'role': 'user', 'content': user},
    ], maxTokens: maxTokens, continues: ReplyContinuation.maxContinues, source: 'office', background: true, route: route, provider: submacRef.provider);
    b.addTokens((system.length + user.length + t.length) ~/ 4);
    unawaited(Bots.I.save());
    return t;
  }

  /// One expert answer from another bot (no tools), for bot_ask.
  /// On the expert's own model (owner 2026-11-06).
  Future<String> _botConsult(Bot asker, Bot expert, String question) async {
    final route = BotModelRoute.of(expert);
    try {
      if (!route.isByok) await RateLimiter.acquire(submacRef.provider, 1500, local, onWait: (_) {}, cancelled: () => false);
      // An expert view is a full answer: the model's own maximum, continued when it is cut (was 1,200, owner 2026-11-06).
      final t = await BotLlm.complete(expert, [
        {'role': 'system', 'content': '${Bots.I.chatPromptOf(expert)}\n\nYour colleague ${asker.name} (${asker.role}) asks for your expert view. Answer concisely and concretely.'},
        {'role': 'user', 'content': question},
      ], maxTokens: OutputLimits.answer, continues: ReplyContinuation.maxContinues, source: 'bot', background: _backgroundLane(asker.convId), route: route, provider: submacRef.provider);
      expert.log('work', 'Helped ${asker.name}: ${question.length > 80 ? '${question.substring(0, 80)}…' : question}');
      unawaited(Bots.I.save());
      return t.trim();
    } catch (e) {
      return 'Could not reach ${expert.name}: $e';
    }
  }

  void _officePump() {
    // Owner 2026-11-07: team work is governed by each bot's own allowance (checked in _officeRun), not by a hardcoded
    // account-wide day gate.
    _officeWatchdog();
    final q = Offices.I.queue;
    if (q.isEmpty) return;
    var changed = false;
    DateTime? nextRetry;
    // Every ready job starts now (owner 2026-11-04): no cap on how many bots work at once, a bot may do several jobs
    // side by side, and a bot talking with the owner in its own chat still does its team work (each piece of work has
    // its own opencode session). The bots' share and each bot's own budget still hold.
    for (final j in List.of(q)) {
      if (!j.ready) {
        if (nextRetry == null || j.after!.isBefore(nextRetry)) nextRetry = j.after;
        continue;
      }
      final o = Offices.I.byId(j.officeId);
      final b = Bots.I.byId(j.botId);
      if (o == null || b == null || !o.members.contains(b.id)) {
        q.remove(j);
        changed = true;
        continue;
      }
      // The same task already in someone's hands: it waits for that run to end.
      if (j.taskId.isNotEmpty && _officeJobs.values.any((x) => x.officeId == j.officeId && x.taskId == j.taskId && x.kind == j.kind)) continue;
      // One owner message several bots were asked about (a thread): they answer one after another, so each reads what
      // the ones before it said and stays quiet when it is covered (owner 2026-11-05: duplicate answers).
      if (TeamTurns.waitsForThread(j, _officeJobs.values.map((x) => x.thread))) continue;
      // The same bot already answering the same words (a double send): no second answer.
      if (j.kind == 'reply' &&
          _officeJobs.values.any((x) => x.officeId == j.officeId && x.botId == j.botId && x.kind == 'reply' && x.instruction == j.instruction)) {
        q.remove(j);
        changed = true;
        continue;
      }
      if (o.paused && j.kind != 'reply') {
        q.remove(j);
        changed = true;
        continue;
      }
      if (o.onHold && j.kind != 'reply') {
        if (nextRetry == null || o.holdUntil!.isBefore(nextRetry)) nextRetry = o.holdUntil;
        continue;
      }
      q.remove(j);
      changed = true;
      unawaited(_officeRun(o, b, j));
    }
    if (changed) Offices.I.saveSoon();
    // Work waiting for a later time: wake up for it, also with the app closed.
    if (nextRetry != null) {
      final at = nextRetry;
      _retryTimer?.cancel();
      _retryTimer = Timer(at.difference(DateTime.now()) + const Duration(seconds: 1), _officePump);
      final j = q.firstWhere((x) => !x.ready, orElse: () => q.first);
      final o = Offices.I.byId(j.officeId);
      if (o != null) {
        unawaited(SystemBridge.I.scheduleAlarm(Offices.alarmId(o, 'retry'), at.add(const Duration(seconds: 5)),
            label: NotifText.running(o.name, 'Team work')));
      }
    }
  }

  /// Tasks marked "in progress" that nobody is working on (the app was stopped mid-task) go back in line.
  void _officeWatchdog() {
    for (final o in Offices.I.offices) {
      // Paused or "only when I ask": nothing restarts by itself.
      if (o.paused || o.manual) continue;
      // The Chief's rounds: nudge a quiet teammate, then tell the owner if they stay quiet.
      Offices.I.supervise(o);
      for (final t in o.tasks.where((t) => t.status == 'doing')) {
        if (t.owner.isEmpty || _officeJobs.values.any((j) => j.officeId == o.id && j.taskId == t.id)) continue;
        if (Offices.I.queue.any((j) => j.taskId == t.id)) continue;
        t.status = 'todo';
        Offices.I.startIfReady(o, t);
      }
    }
  }


  /// Why a bot's latest wake failed, if it did: offline | busy | credit (allowance used up) | other | ''.
  String _wakeFailure(String convId) {
    final list = _lists[convId];
    if (list == null) return '';
    final start = list.lastIndexWhere((m) => m.role == 'user' && m.content.startsWith(botWakeMark));
    if (start < 0) return '';
    for (final m in list.sublist(start).reversed) {
      final e = m.error;
      if (e == null || e.isEmpty) continue;
      return AppState.failureOf(e);
    }
    return '';
  }

  /// One bot does one piece of office work in its own opencode session (TeamKey: never its private chat), with all
  /// its tools, and posts the result to the team chat only (owner 2026-11-04: team work used to run as a wake inside
  /// the bot's 1:1 chat with the owner, so every reply, step and result showed in both chats). Runs side by side with
  /// any other work: the owner's chats, the bot's own chat, other office jobs.
  Future<void> _officeRun(Office o, Bot b, OfficeJob j) async {
    final key = TeamKey.of(o.id, b.id, job: TeamKey.job());
    final live = OfficeLiveJob(
        botId: b.id, officeId: o.id, kind: j.kind, taskId: j.taskId, thread: j.thread, instruction: j.instruction, depth: j.depth, cause: j.cause);
    _officeJobs[key] = live;
    final startedAt = live.started;
    _notify();
    OfficeTask? t;
    var begun = false;
    try {
      if (!await _ensureBotConv(b)) {
        // No chat yet (offline, not loaded): try again in 2 minutes, a few times, not three times a second.
        if (j.tries < 5) {
          Offices.I.enqueue(j.retry(after: DateTime.now().add(const Duration(minutes: 2)), tries: j.tries + 1));
        }
        return;
      }
      if (!b.active) await Bots.I.hire(b, b.convId);
      if (b.overBudget && j.kind != 'reply') {
        final now = DateTime.now();
        final tomorrow = DateTime(now.year, now.month, now.day + 1, 0, 5);
        if (!b.journal.any((e) => e.kind == 'budget' && now.difference(e.at).inHours < 20)) {
          b.log('budget', 'Paused team work: today\'s budget is used up');
        }
        // One small line in the team chat ("Nova · out of budget"), not a message (owner 2026-11-04).
        TeamStatus.I.flag(o.id, b.id, TeamStatus.outOfBudget,
            detail: '${b.name} used today\'s token budget, so their work continues tomorrow. You can raise it in their settings.');
        Offices.I.enqueue(j.retry(after: tomorrow));
        return;
      }
      t = j.taskId.isEmpty ? null : o.task(j.taskId);
      if ((j.kind == 'task' || j.kind == 'review' || j.kind == 'unblock') && (t == null || !t.open)) return;
      if (j.kind == 'task' && t != null) {
        if (t.owner != b.id) return;
        // Blocked by the owner or waiting for review: an older job never pulls it back to "doing".
        if (t.status != 'todo' && t.status != 'doing') return;
        t.attempts++;
        if (t.attempts > 3) {
          t.status = 'blocked';
          t.result = 'Stopped after three tries without finishing.';
          Offices.I.post(o, b.id, 'Blocked: ${t.title}\n${t.result}', kind: 'update', taskId: t.id);
          Offices.I.taskChanged(o, t, by: b.id);
          return;
        }
        t.status = 'doing';
        t.startedAt = DateTime.now();
        Offices.I.saveSoon();
      }
      o.rollDay();
      o.runsToday++;
      // A thread answer (several bots asked about one message) after a teammate already answered: the bot may stay
      // quiet, and small talk gets no second quick reply at all.
      final covered = j.kind == 'reply' && j.thread.isNotEmpty && Offices.I.threadAnswers(o, j.thread, except: b.id).isNotEmpty;
      // Small talk in the office gets an instant answer in character.
      if (j.kind == 'reply' && QuickLane.laneFor(j.instruction) == QuickLane.quick) {
        if (covered) return;
        final text = NoReply.clean(await _officeQuick(o, b, j.instruction));
        if (Offices.I.stoppedSince(o.id, startedAt)) return; // CB-34: the owner stopped the team meanwhile
        if (text.isEmpty && j.thread.isNotEmpty) return;
        Offices.I.post(o, b.id, text.isNotEmpty ? text : BotManner.noReply(b.name, lang: BotManner.langOf(j.instruction)),
            kind: text.isNotEmpty ? 'chat' : 'system', depth: j.depth, cause: j.cause);
        return;
      }
      final system = '${Bots.I.agentBriefOf(b, team: true)}\n\n${Offices.I.promptFor(o, b, j)}';
      final task = '[Office: ${o.name}]\n# Now\n${Offices.I.jobText(o, b, j)}';
      // The silent running line: "<Team> · <Bot>: <task>" (the result comes as the team's own notification).
      await SystemBridge.I.keepAlive(true,
          text: NotifText.running(o.name, '${b.name}: ${t?.title ?? (j.kind == 'reply' ? 'Your message' : 'Team work')}'));
      begun = true;
      String reply = '';
      String failure = '';
      var finished = true;
      try {
        if (j.kind == 'mission') _missionReplies.remove(key);
        reply = await teamTurn(b, key, system, task,
            stopped: () => Offices.I.stoppedSince(o.id, startedAt),
            // Answering the owner in the team chat is the owner's own conversation (foreground lane); the rest is
            // bot work on the bots' share (owner 2026-11-03).
            background: j.kind != 'reply',
            office: o.id,
            officeJob: j.kind,
            maxSteps: AppState.officeStepCap(j.kind),
            onStatus: (line) {
              live.status = line;
              _throttledNotify();
            });
        if (Offices.I.stoppedSince(o.id, startedAt)) finished = false;
        if (j.kind == 'mission') _missionReplies[key] = reply;
      } catch (e) {
        failure = AppState.failureOf('$e');
        if (failure == 'other') failure = '';
        // The team chat shows it as one small line ("Nova · rate limit", set by teamTurn), never the raw error text.
        finished = false;
      }
      // A failure that is not the bot's fault never burns a try: the work waits and runs again by itself.
      if (failure == 'offline' || failure == 'busy' || failure == 'credit') {
        if (t != null && j.kind == 'task') {
          t.attempts = (t.attempts - 1).clamp(0, 99).toInt();
          if (t.status == 'doing') t.status = 'todo';
        }
        o.runsToday = (o.runsToday - 1).clamp(0, 9999).toInt();
        final wait = switch (failure) { 'offline' => const Duration(minutes: 5), 'busy' => const Duration(minutes: 3), _ => AppState._untilAllowanceResets() };
        // Busy models or no connection: try again a few times, then stop instead of retrying all day (each try costs tokens).
        if (failure != 'credit' && j.tries >= 3) {
          if (t != null && t.status == 'todo') t.result = 'Stopped after 4 tries: the models were busy or the phone was offline. Tap Start to try again.';
          Offices.I.post(o, 'system', '${b.name} stopped trying for now (${failure == 'offline' ? 'no connection' : 'the models were busy'}). '
              '${t == null ? 'Ask again when you are ready.' : 'Tap Start on "${t.title}" to try again.'}', kind: 'system');
          return;
        }
        if (failure == 'credit') {
          final first = !o.onHold;
          o.holdUntil = DateTime.now().add(wait);
          if (first) {
            final share = Cloud.background.value.pausedNow;
            Offices.I.post(o, 'system',
                share
                    ? 'Paused until tomorrow to save your daily allowance. Work picks up again by itself, and you can still message the team.'
                    : 'Today\'s allowance is used up, so the team rests until tomorrow. Work picks up again by itself.',
                kind: 'system');
            await _officeNotify(o, b, share ? 'The team paused until tomorrow to save your daily allowance.' : 'The team rests until tomorrow: today\'s allowance is used up.');
          }
        }
        Offices.I.enqueue(j.retry(after: DateTime.now().add(wait), tries: failure == 'credit' ? j.tries : j.tries + 1));
        return;
      }
      final out = BotOutcome.parse(reply);
      // The owner spoke to this bot (or it was given a task): what it wrote is posted even with a stray silence tag on
      // it (that used to throw a real answer away). Elsewhere the bot may stay quiet, which is normal.
      // A thread answer may pass when a teammate covered it (it was told so).
      // An assignment always reports back (owner 2026-11-06: the one who handed it out waits for it).
      final mustAnswer = (j.kind == 'reply' && !covered) || j.kind == 'task' || j.kind == 'assign';
      if (out.text.trim().isEmpty || (out.kind == 'silent' && !mustAnswer)) {
        // CB-37: a direct request that ended with nothing to show says so (it used to leave the owner waiting).
        if (j.kind == 'reply' && mustAnswer && finished && !Offices.I.stoppedSince(o.id, startedAt)) {
          Offices.I.post(o, 'system', BotManner.noReply(b.name, lang: BotManner.langOf(j.instruction)), kind: 'system');
        }
      } else if (Offices.I.stoppedSince(o.id, startedAt)) {
        // CB-34: stopped by the owner; nothing more goes into the team chat.
      } else {
        // The team chat only: nothing of it is written to the bot's private chat.
        final visible = BotOutcome.visible(reply);
        // Posted once: a reply the bot already put in the chat itself (office_post during the turn) or that repeats a
        // teammate is dropped by Offices.post (TeamDedupe). A reply to the owner's message links to it.
        final before = o.posts.length;
        // Its chain goes with it (TeamReact): teammates it names, and anyone waiting for its post, take their turn next,
        // one level deeper. An answer to a teammate's post links to that post.
        final p = Offices.I.post(o, b.id, visible.isEmpty ? out.text : visible,
            kind: j.kind == 'digest' ? 'report' : 'chat',
            taskId: j.taskId,
            replyTo: j.kind == 'reply' ? j.thread : j.post,
            depth: j.depth,
            cause: j.cause);
        // An answer to the owner while they are not looking at the team (2026-11-05: a reply typed in the team's
        // notification is answered in that notification's conversation). A "[needs you]" post told them already, and a
        // dropped duplicate says nothing new.
        // Also a result the owner asked for by name ("Amal, analyze Nova's research once it posts") and the lead's
        // summary once the reports it waited for are in (owner 2026-11-06).
        final forOwner = j.kind == 'reply' || (j.kind == 'react' && (j.instruction.contains('The owner asked:') || b.id == o.chiefId));
        if (forOwner && p.kind != 'ask' && o.posts.length > before && !b.quietNow()) {
          await _officeNotify(o, b, p.text);
        }
        if (j.kind == 'digest') {
          final line = (visible.isEmpty ? out.text : visible).trim().split('\n').firstWhere((l) => l.trim().isNotEmpty, orElse: () => 'Your daily report is ready.');
          if (o.digestCall && Bots.callBlock(b) == null) {
            _ringText[b.id] = visible;
            await _botRing(b, 'Daily report: ${o.name}');
          } else {
            await _officeNotify(o, b, line);
          }
        }
      }
      // Work that ended without a word on its task goes back to the queue once more.
      if (t != null && j.kind == 'task' && t.status == 'doing') {
        t.status = 'todo';
        if (Bots.requeueAfterRun(finished: finished, kind: j.kind, status: 'doing')) {
          Offices.I.startIfReady(o, t);
        } else {
          // Stopped: it waits for the owner, and the stop never counts as a try.
          t.attempts = (t.attempts - 1).clamp(0, 99).toInt();
          Offices.I.post(o, 'system', '${b.name} stopped "${t.title}". Tap Start to continue.', kind: 'system', taskId: t.id);
        }
      }
      b.log('work', '${o.name}: ${j.kind}${t == null ? '' : ' "${t.title}"'}', team: true);
      unawaited(Bots.I.save());
    } catch (e) {
      // Nothing started: undo what this job claimed, so the task isn't left mislabelled.
      if (!begun) {
        final tt = t;
        if (tt != null && tt.status == 'doing') {
          tt.status = 'todo';
          if (j.kind == 'task') tt.attempts = (tt.attempts - 1).clamp(0, 99).toInt();
        }
      }
      // One small line in the team chat ("Nova · no connection"), never the raw error text.
      if (!Offices.I.stoppedSince(o.id, startedAt)) TeamStatus.I.failBot(o.id, b.id, e);
    } finally {
      _officeJobs.remove(key);
      // A team's mission run ended (not when it went back in line to retry): the mission notes it and comes back by itself.
      if (j.kind == 'mission' && !Offices.I.queue.any((q) => q.officeId == j.officeId && q.kind == 'mission')) {
        unawaited(_missionTeamEnded(o, _missionReplies.remove(key) ?? ''));
      }
      Offices.I.saveSoon();
      if (_officeJobs.isEmpty && !runs.any((r) => !r.side) && !(TelegramBridge.I.on && TelegramBridge.I.paired && !appVisible)) {
        unawaited(SystemBridge.I.keepAlive(false));
      }
      _notify();
      Future<void>.delayed(const Duration(milliseconds: 300), _officePump);
    }
  }

  /// Removes the latest wake and everything after it from a bot's chat (a check-in with nothing to say).
  /// Removes a wake that ended with nothing to show (silent, offline, out of allowance). CB-17: only the rows the
  /// wake wrote itself go (its mark and its own replies and tool results); what the owner typed during the wake, and
  /// the quick replies to it, stay.
  Future<void> _dropWakeTurn(String convId) async {
    final wrote = _wakeRows.remove(convId);
    final list = _lists[convId];
    if (list == null) return;
    final gone = WakeTurn.rowsToDrop(list, wrote);
    if (gone.isEmpty) return;
    final ids = {for (final m in gone) m.id};
    list.removeWhere((m) => ids.contains(m.id));
    _notify();
    try {
      await repo.deleteMessages(ids.toList());
    } catch (_) {}
  }

  @visibleForTesting
  Future<void> officeRunForTest(Office o, Bot b, OfficeJob j) => _officeRun(o, b, j);
  @visibleForTesting
  Future<String> teamAskForTest(Bot b, String system, String user) => _teamAsk(b, system, user);
  @visibleForTesting
  Future<String> officeQuickForTest(Office o, Bot b, String text) => _officeQuick(o, b, text);
  @visibleForTesting
  Future<String> botConsultForTest(Bot asker, Bot expert, String q) => _botConsult(asker, expert, q);
  @visibleForTesting
  Future<bool> worthWakingForTest(Bot b) => _worthWaking(b);
  @visibleForTesting
  Future<void> botOutcomeForTest(Bot b, String reply, String kind) => _botOutcome(b, reply, kind);
  @visibleForTesting
  Future<void> botWakeForTest(Bot b, String reason, String instruction, String kind) => _botWake(b, reason, instruction, kind);
  @visibleForTesting
  Future<void> runHeldWakesForTest() => _runHeldWakes();
  @visibleForTesting
  Map<String, Set<String>> get wakeRowsForTest => _wakeRows;

  /// A one-line instant reply in the office chat, in the bot's own character.
  Future<String> _officeQuick(Office o, Bot b, String text) async {
    // On the bot's own model (owner 2026-11-06), like the rest of its team work.
    final route = BotModelRoute.of(b);
    try {
      if (!route.isByok) await RateLimiter.acquire(submacRef.provider, 600, local, onWait: (_) {}, cancelled: () => false);
      final recent = o.posts.reversed.take(6).toList().reversed.map((x) =>
          '${x.from == 'you' ? 'Owner' : (Bots.I.byId(x.from)?.name ?? 'System')}: ${x.text.length > 200 ? '${x.text.substring(0, 200)}…' : x.text}');
      final t = await BotLlm.complete(b, source: 'office', maxTokens: 400, route: route, provider: submacRef.provider, [
        {
          'role': 'system',
          'content': '${Bots.I.quickPromptOf(b)}\nYou are in the "${o.name}" team chat with the owner and your teammates'
              '${b.id == o.chiefId ? ' (you are the lead)' : ''}. Reply in one or two short, natural sentences, in the owner\'s language. '
              'No lists, no emoji.\nLatest chat:\n${recent.join('\n')}'
        },
        {'role': 'user', 'content': text},
      ]);
      return t.trim();
    } catch (_) {
      return '';
    }
  }

  /// A bot working in the background wants to do something that needs the owner's OK: one approval card (Approve ·
  /// Edit · Not now) in the app, batched with similar asks, and a notification to answer from.
  Future<bool> _askApproval(Bot b, Office? o, ActionRequest req, {String tool = '', String? convId}) async {
    final kind = req.kind.isNotEmpty ? req.kind : BotTrust.kindOf(tool, '${req.title} ${req.detail}', destructive: req.destructive);
    final a = Approval(
        id: Approval.newId(),
        convId: convId ?? '',
        kind: kind,
        botId: b.id,
        officeId: o?.id ?? '',
        title: req.title,
        body: req.body.isNotEmpty ? req.body : req.detail,
        group: ApprovalGroups.keyFor(tool, kind),
        detail: req.body.isNotEmpty ? req.detail : '',
        editText: req.edit?.value);
    final note = 9900 + (a.id.hashCode % 90).abs();
    if (o != null) Offices.I.post(o, b.id, 'Waiting for your OK: ${req.title}', kind: 'ask');
    // Similar asks already waiting: the notification says "3 emails to send" (the app shows them as one card).
    final same = Offices.I.pending.where((x) => x.group == a.group).length + 1;
    final title = same > 1 ? '$same ${ApprovalGroups.noun(a.group, same)}' : req.title;
    await SystemBridge.I.notifyApproval(id: note, approvalId: a.id, name: o == null ? b.name : '${b.name} · ${o.name}', title: title, body: a.body);
    // A run nobody is watching (a scheduled task, SubMac closed) waits a few minutes, not three hours: then it moves
    // on, and one notification says what still needs the owner's OK (2026-11-05).
    final unattended = unattendedRun(convId);
    final ok = await Offices.I.ask(a, wait: unattended ? BgRun.approvalWait : const Duration(hours: 3));
    await SystemBridge.I.ringCancel(note);
    if (!ok && unattended && a.status == 'expired') unawaited(_bgNeeds(convId ?? '', req.title));
    if (ok && a.edited.isNotEmpty && req.edit != null) {
      req.edit!
        ..value = a.edited
        ..edited = true;
    }
    if (a.wantsChange) req.wantsChange = true;
    if (a.status != 'expired') unawaited(Bots.I.recordAnswer(b, approved: ok, edited: a.edited.isNotEmpty || a.wantsChange));
    if (o != null) Offices.I.post(o, 'system', '${ok ? 'Approved' : (a.status == 'expired' ? 'No answer, skipped' : 'Not now')}: ${req.title}', kind: 'system');
    return ok;
  }

  /// The owner answered a message right from its notification.
  Future<void> _notificationReply(String to, String text) async {
    if (text.trim().isEmpty) return;
    text = AiKeys.redact(text).text;
    final route = NotifRoute.parse(to, isBotConv: Bots.I.isBotConv);
    if (route == null) {
      _releaseIfIdle();
      return;
    }
    if (route.from == NotifFrom.team) {
      final o = Offices.I.byId(route.id);
      // Same routing as typing in the team chat: only whoever is addressed (or picked) answers. Their answers come
      // back in the team's notification while the owner is away (_officeRun).
      if (o != null) TeamRun.I.send(o, text);
      _releaseIfIdle(later: true);
      return;
    }
    // 'botchat/<bot>': the bot's private chat.
    final convId = route.id.isNotEmpty && to.startsWith('botchat/') ? (Bots.I.byId(route.id)?.convId ?? '') : route.id;
    if (convId.isEmpty) {
      _releaseIfIdle();
      return;
    }
    if (_lists[convId] == null) {
      try {
        _lists[convId] = await repo.listMessages(convId);
      } catch (_) {
        return;
      }
    }
    final task = runs.where((r) => r.convId == convId && !r.side).firstOrNull;
    final list = _lists[convId]!;
    final m = ChatMessage(id: _uuid.v4(), role: 'user', content: text.trim());
    // CB-1: the reply is in the chat (and saved) also when a task is running; the task hears it at its next step, a
    // final answer already streaming is followed by an answer to it, and a step still waiting restarts to hear it.
    list.add(m);
    try {
      await repo.insertMessage(convId, m);
    } catch (_) {}
    Bots.I.userReplied(convId);
    if (task != null && !task.cancelled && runs.contains(task)) {
      task.inbox.add(text.trim());
      // R2 item 1: only a step that restarts to hear it is "reading"; a tool still running keeps its own line.
    if (task.inModel) task.show(RunPhase.waiting, RunStatus.reading);
      if (task.inModel) task.client?.cancelForSteer();
      _notify();
      return;
    }
    _notifyConvs.add(convId);
    _notifReplyConvs.add(convId);
    final bot = Bots.I.byConv(convId);
    await SystemBridge.I.keepAlive(true, text: NotifText.running(bot?.name ?? 'SubMac', 'Your reply'));
    _notify();
    unawaited(_runAgent(convId));
  }

  /// A notification reply that started nothing (an unknown chat, a team message nobody answers) lets the foreground
  /// service it started go, unless other work runs. [later]: a team answers through its job queue, so this checks again
  /// after a while.
  void _releaseIfIdle({bool later = false}) {
    if (appVisible) return;
    bool idle() => _officeJobs.isEmpty && Offices.I.queue.isEmpty && TeamRun.I.running.isEmpty && !runs.any((r) => !r.side);
    if (!later) {
      if (idle()) unawaited(SystemBridge.I.keepAlive(false));
      return;
    }
    Timer(const Duration(seconds: 20), () {
      if (!appVisible && idle()) unawaited(SystemBridge.I.keepAlive(false));
    });
  }

  /// Members are hired the moment they join an office, quietly (no first-meeting message).
  Future<String?> prepareOfficeBots(List<String> ids) async {
    for (final id in ids) {
      final b = Bots.I.byId(id);
      if (b == null) continue;
      if (!await _ensureBotConv(b)) return '${b.name} needs the internet to get started. Try again once you\'re online.';
      if (!b.active) await Bots.I.hire(b, b.convId);
    }
    return null;
  }

  /// A new office from a template: built-in bots join as they are; described roles become new bots first.
  Future<Office?> createOfficeFromTemplate(OfficeTemplate t, {String? goal}) async {
    Future<String?> resolve(String spec) async {
      if (Bots.I.byId(spec) != null) return spec;
      final b = await createBotFromText(spec);
      return b?.id;
    }
    final chief = await resolve(t.chief);
    if (chief == null) return null;
    final members = <String>[chief];
    for (final m in t.members) {
      final id = await resolve(m);
      if (id != null && !members.contains(id)) members.add(id);
    }
    final err = await prepareOfficeBots(members);
    if (err != null) return null;
    final o = await Offices.I.create(name: t.name, goal: goal ?? t.goal, icon: t.icon, members: members, chiefId: chief, rules: t.rules);
    return o;
  }

  /// The Chief made a team (team_make create): resolve each member — an existing bot's name, or a plain
  /// description that becomes a new bot — hire them, and open the office. Returns an error line, or null.
  Future<String?> _botMakeTeam(Bot chief, Map<String, dynamic> spec) async {
    final members = <String>[];
    String? lead;
    final wantLead = '${spec['chief'] ?? ''}'.trim().toLowerCase();
    for (final m in (spec['members'] as List? ?? const [])) {
      final text = '$m'.trim();
      if (text.isEmpty) continue;
      var id = Bots.I.byName(text)?.id;
      if (id == null) {
        final nb = await createBotFromText(text);
        id = nb?.id;
        if (id == null) return 'Could not make a bot from "${text.length > 40 ? '${text.substring(0, 40)}…' : text}". Try again with plainer words.';
      }
      if (!members.contains(id)) members.add(id);
      if (lead == null && (wantLead.isEmpty || wantLead == text.toLowerCase() || Bots.I.byId(id)?.name.toLowerCase() == wantLead)) lead = id;
    }
    if (members.length < 2) return 'A team needs at least two members.';
    lead ??= members.first;
    final err = await prepareOfficeBots(members);
    if (err != null) return err;
    final icon = '${spec['icon'] ?? ''}'.trim();
    await Offices.I.create(
        name: '${spec['name'] ?? ''}',
        goal: '${spec['goal'] ?? ''}',
        icon: icon.isEmpty ? 'work' : icon,
        members: members,
        chiefId: lead,
        rules: '${spec['rules'] ?? ''}');
    return null;
  }

  /// The team chat's live rows (owner 2026-11-04): one small line per bot, "Nova is working…" while its turn thinks or
  /// runs steps and "Nova is typing…" while its reply streams (gone when its message lands); who has a message from the
  /// owner waiting ("Idil · Read your message"); and a bot whose work failed as "Nova · rate limit". Never tool names,
  /// never raw error text. Team chat only: a bot's private chat never shows these.
  List<TeamStatusLine> officeActivity(String officeId) {
    final busy = <String, DateTime>{};
    for (final j in _officeJobs.values) {
      if (j.officeId != officeId) continue;
      final had = busy[j.botId];
      if (had == null || j.started.isBefore(had)) busy[j.botId] = j.started;
    }
    final waiting = <String, String>{};
    for (final j in Offices.I.queue) {
      if (j.officeId != officeId || j.kind != 'reply' || waiting.containsKey(j.botId)) continue;
      waiting[j.botId] = j.ready ? 'Read your message' : 'Will reply soon';
    }
    return TeamStatus.I.linesFor(officeId, bot: Bots.I.byId, busy: busy, waiting: waiting);
  }

  List<String> officeWorking(String officeId) {
    final o = Offices.I.byId(officeId);
    if (o == null) return const [];
    final out = <String>[];
    for (final id in {for (final j in _officeJobs.values) if (j.officeId == officeId) j.botId}) {
      final b = Bots.I.byId(id);
      if (b == null) continue;
      final t = o.tasks.where((t) => t.owner == id && t.status == 'doing').map((t) => t.title).firstOrNull;
      out.add(t == null ? '${b.name} is working' : '${b.name}: $t');
    }
    return out;
  }

  /// Bots and offices this person can send a shared file or text to.
  bool get hasTeam => Bots.I.hired.isNotEmpty || Offices.I.any;

  /// Something shared from another app goes to an office chat.
  void shareToOffice(Office o, Map<String, dynamic> share) {
    final text = '${share['text'] ?? ''}'.trim();
    final files = [for (final f in (share['files'] as List? ?? const [])) f is Map ? '${f['path'] ?? f['name'] ?? ''}' : '$f'];
    final body = [
      if (text.isNotEmpty) text,
      for (final f in files)
        if (f.isNotEmpty) '[Shared file: $f]',
    ].join('\n');
    if (body.isNotEmpty) TeamRun.I.send(o, body);
  }

  /// Make a new bot from a plain description.
  Future<Bot?> createBotFromText(String desc) async {
    final route = submacRef;
    try {
      await RateLimiter.acquire(route.provider, 1500, local, onWait: (_) {}, cancelled: () => false);
      final raw = await LlmClient().complete(source: 'agent', maxTokens: OutputLimits.structured, provider: route.provider, model: route.model, messages: [
        {
          'role': 'system',
          'content': 'You design AI colleagues ("bots") that live in a phone app, work on what the user asks and can call the user. '
              'From the user\'s description, reply with JSON only (no code fence): {"name": short human first name, "role": job title, '
              '"persona": 3-5 sentences: expertise, character, how they work and talk (a calm, professional, adult colleague: polite, '
              'plain and warm, no hype, no emoji, no exclamation marks, no cute or childish wording), "mission": one sentence, "icon": one of '
              'person, school, gavel, trending_up, travel_explore, fitness_center, payments, edit, code, work, favorite, campaign, '
              '"proactivity": free|quiet|balanced|active (free = no daily limit, the default), "heartbeat_hours": 6 by '
              'default (a light self-wake; 3-24, or 0 if the user wants it to act only when they ask), '
              '"routines": [] unless the user asked for scheduled work, else [{"time":"HH:MM","days":"daily|weekdays|mon,wed","kind":"work|message|call","do":"what to do"}]. '
              'A bot decides and acts on its own; the user can set a limit or take it offline. '
              '"first_meeting": what to ask the user in the first chat (say what you can take on and suggest one or two first tasks)}. Write in the user\'s language.'
        },
        {'role': 'user', 'content': desc},
      ]);
      final m = RegExp(r'\{[\s\S]*\}').firstMatch(raw);
      if (m == null) return null;
      final spec = Map<String, dynamic>.from(jsonDecode(m.group(0)!) as Map);
      return await Bots.I.create(spec);
    } catch (_) {
      return null;
    }
  }
}
