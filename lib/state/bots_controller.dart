// Bots, teams and offices: hiring, wake-ups, office job pump, bot calls.
// Split out of app_state.dart (no behaviour change). Fields stay on AppState.
part of '../app_state.dart';

extension AppStateBots on AppState {
  /// Plan 2.2: work nobody is watching (a bot's own wake, office work other than answering the owner) runs in the
  /// background lane, on the bots' share of the daily allowance. Chats with the owner never do.
  bool _backgroundLane(String convId) {
    final k = _botWakeConvs[convId];
    if (k == null || k == 'chat') return false;
    if (k == 'office' && _officeJobKind[convId] == 'reply') return false;
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
    final m = ChatMessage(id: id, role: 'assistant', content: text.trim());
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
    if (activeProvider == null) return;
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
    // A busy day, or the bots' share of today's allowance is used: the owner's own chats come first, so background
    // work waits for tomorrow (one note a day, no retries; the next wake after midnight UTC runs as usual).
    if (kind != 'chat' && (Cloud.usage.value.light || Cloud.usage.value.resting || Cloud.background.value.pausedNow)) {
      _notePaused(b);
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
    if (!await _ensureBotConv(b)) return;
    b.lastWake = DateTime.now();
    final now = DateTime.now();
    final budget = b.quietNow()
        ? 'It is the user\'s quiet hours now (${b.quietFrom}:00 to ${b.quietTo}:00): do not message or call; @note or [no reply] only.'
        : 'Today you may still send ${b.messagesLeft} message(s) and make ${b.callsLeft} call(s).';
    final String task;
    if (kind == 'chat') {
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

  bool _wakeMayClaim(Bot b) => Bots.wakeMayClaim(
      officeBusy: _officeBusy.contains(b.id),
      hasMarker: b.convId.isNotEmpty && _botWakeConvs.containsKey(b.convId),
      running: b.convId.isNotEmpty && runs.any((r) => r.convId == b.convId && !r.side));

  /// Busy (talking with the user, or at team work): come back in 15 minutes, once (not one more follow-up per busy wake).
  Future<void> _wakeLater(Bot b, String instruction, String kind) async {
    if (kind == 'chat' || Bots.hasPendingFollowup(b, instruction, kind)) return;
    b.followups.add(BotFollowup('f${DateTime.now().millisecondsSinceEpoch % 1000000}', DateTime.now().add(const Duration(minutes: 15)),
        instruction.isEmpty ? Bots.heartbeat : instruction, kind));
    await Bots.I.save();
    await Bots.I.arm(b);
  }

  /// Is there something worth a full wake right now? Same check the cloud runner does. On any doubt (no answer,
  /// an error) the bot wakes as before.
  Future<bool> _worthWaking(Bot b) async {
    final ref = submacRef;
    String cut(String t, int n) => t.length > n ? '${t.substring(0, n)}…' : t;
    final open = b.desk.where((t) => t.status != 'done').take(12).map((t) => '- (${t.status}) ${cut(t.text, 160)}').join('\n');
    final ups = b.followups.take(6).map((f) => '- ${f.at.toIso8601String().substring(0, 16)} ${cut(f.instruction, 140)}').join('\n');
    final recent = b.journal.reversed.take(5).toList().reversed.map((j) => '- ${j.at.toIso8601String().substring(5, 16)} ${j.kind}: ${cut(j.text, 140)}').join('\n');
    final mem = b.memory.reversed.take(8).toList().reversed.map((m) => '- ${cut(m, 160)}').join('\n');
    final prompt = 'You decide if ${b.name} (${b.role.isEmpty ? 'assistant' : b.role}) should do work for the user right now.\n'
        'Job: ${cut(b.mission.isEmpty ? '(none)' : b.mission, 300)}\nInstructions: ${cut(b.instructions.trim().isEmpty ? '(none)' : b.instructions.trim(), 400)}\n'
        'Working on:\n${open.isEmpty ? 'none' : open}\nPromised follow-ups:\n${ups.isEmpty ? 'none' : ups}\n'
        'Lately:\n${recent.isEmpty ? 'none' : recent}\nSome memory:\n${mem.isEmpty ? 'none' : mem}\n'
        'Now (local time): ${DateTime.now().toIso8601String().substring(0, 16).replaceFirst('T', ' ')}\n\n'
        'Is there something genuinely useful to do now (progress on open work, a promise, a deadline, news on what it tracks)? Never busywork. '
        'Reply exactly NO, or YES: <the one thing, in one line>.';
    try {
      final t = await (LlmClient()..background = true)
          .complete(source: 'bot', maxTokens: 60, provider: ref.provider, model: ref.model, messages: [
        {'role': 'user', 'content': prompt},
      ]);
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
    if (kind != 'chat' && (failure == 'offline' || failure == 'busy')) {
      await _dropWakeTurn(b.convId);
      if (!instruction.startsWith('(retry) ')) {
        b.followups.add(BotFollowup('f${DateTime.now().millisecondsSinceEpoch % 1000000}', DateTime.now().add(const Duration(minutes: 10)),
            '(retry) ${instruction.isEmpty ? Bots.heartbeat : instruction}', kind));
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
    final may = Bots.I.allow(b, want);
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
            b.log('message', visible.split('\n').first);
            Bots.I.spent(b, 'message');
            if (!looking) {
              await SystemBridge.I.notifyBot(id: 9200 + (b.id.hashCode % 500).abs(), name: b.name, body: visible, payload: 'conv/${b.convId}', reply: true);
            }
          } else {
            b.log('note', visible.split('\n').first);
            await Bots.I.save();
          }
        }
      case 'message':
        b.log('message', visible.split('\n').first);
        Bots.I.spent(b, 'message');
        Events.I.botMessaged(b.id);
        if (!looking) {
          await SystemBridge.I.notifyBot(id: 9200 + (b.id.hashCode % 500).abs(), name: b.name, body: visible, payload: 'conv/${b.convId}', reply: true);
        }
      default:
        b.log('note', visible.split('\n').first);
        await Bots.I.save();
    }
  }

  /// Plan 5.2: the bot's evening note, posted in its chat like a colleague's end-of-day message.
  Future<void> _botReport(Bot b, String text, {bool notify = false}) async {
    if (!await _ensureBotConv(b)) return;
    final list = _lists[b.convId];
    if (list == null) return;
    final m = ChatMessage(id: _uuid.v4(), role: 'assistant', content: text.trim());
    list.add(m);
    _notify();
    try {
      await repo.insertMessage(b.convId, m);
    } catch (_) {}
    if (notify && !(appVisible && currentId == b.convId) && !b.quietNow()) {
      await SystemBridge.I.notifyBot(id: 9200 + (b.id.hashCode % 500).abs(), name: b.name, body: text.split('\n').first, payload: 'conv/${b.convId}');
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
      await SystemBridge.I.notifyBot(id: 9200 + (b.id.hashCode % 500).abs(), name: b.name, body: reason, payload: 'conv/${b.convId}');
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
    await SystemBridge.I.notifyBot(
        id: _ringId(b) + 1000, name: b.name, body: text.isEmpty ? 'Missed call' : 'Missed call. $text', payload: 'conv/${b.convId}', reply: true);
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
      await SystemBridge.I.notifyBot(id: 9200 + (b.id.hashCode % 500).abs(), name: b.name, body: text, payload: 'conv/${b.convId}');
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

  /// One expert answer from another bot (no tools), for bot_ask.
  /// One answer for a team run (TeamRun): the owner is watching, so it is not background work.
  /// The wire under team agent runs (TeamRun on the Genkit core): one model call for a member, tools allowed, on the
  /// bots' background lane.
  Future<LlmResult> _teamLlm(Bot b, Turn t, {int maxTokens = 1500}) async {
    final route = submacRef;
    await RateLimiter.acquire(route.provider, RateLimiter.estimateTokens(t.payload, t.tools), local, onWait: (_) {}, cancelled: () => false);
    final client = LlmClient()
      ..background = true
      ..chatId = b.convId.isEmpty ? null : b.convId;
    final r = await client.streamChat(
      provider: route.provider,
      model: route.model,
      messages: t.payload,
      tools: AppState._capTools(t.tools),
      maxTokens: maxTokens,
      source: 'office',
      onDelta: (_) {},
    );
    final units = UsageUnits.ofResult(r); // CB-20: billing units, as the server counts them
    if (units > 0) b.addTokens(units);
    unawaited(Bots.I.save());
    return r;
  }

  /// A member's tools for its part of a team job: the everyday core set of its own chat (its powers and apps apply at
  /// run time). A bot without a chat of its own answers from what it knows.
  List<Map<String, dynamic>> _memberTools(Bot b) {
    if (b.convId.isEmpty) return const [];
    return [
      for (final t in _lightTools(b.convId))
        if (!const {'more_tools', 'ask_user', 'say', 'todo'}.contains(Wire.toolName(t)) && !Offices.names.contains(Wire.toolName(t))) t,
    ];
  }

  Future<Map<String, dynamic>?> _memberApproval(Bot b, ToolCall c, Map<String, dynamic> args) async {
    final g = await toolGate(c.name, args, b.convId);
    _memberGates[c.id] = g;
    return g.ask == null ? null : g.toInterrupt(c.name);
  }

  Future<ToolApproval> _memberAnswer(Bot b, ToolCall c, Map<String, dynamic> args, Map<String, dynamic> data) async {
    final g = _memberGates[c.id] ?? await toolGate(c.name, args, b.convId);
    _memberGates[c.id] = g;
    if (g.ask == null) return ToolApproval.yes(args: args);
    final ok = await presentApproval(g, c.name, args, b.convId);
    return ok ? ToolApproval.yes(args: approvedArgs(g, c.name, args)) : ToolApproval.no(g.refusal);
  }

  Future<String> _memberTool(Bot b, ToolCall c, Map<String, dynamic> args, {Object? approved}) async {
    var g = _memberGates.remove(c.id);
    if (g == null || (g.ask != null && approved == null)) {
      g = await toolGate(c.name, args, b.convId);
      if (g.ask != null && approved == null && !await presentApproval(g, c.name, args, b.convId)) return g.refusal;
    }
    if (g.blocked != null) return g.blocked!;
    try {
      final out = await runGated(g, c.name, args, callId: c.id, convId: b.convId);
      return out.trim().isEmpty ? 'Done (the tool returned nothing to show).' : out;
    } catch (e) {
      return 'Error in ${c.name}: $e';
    }
  }

  Future<String> _botConsult(Bot asker, Bot expert, String question) async {
    final route = submacRef;
    try {
      await RateLimiter.acquire(route.provider, 1500, local, onWait: (_) {}, cancelled: () => false);
      final t = await (LlmClient()..background = _backgroundLane(asker.convId)).complete(source: 'bot', maxTokens: 1200, provider: route.provider, model: route.model, messages: [
        {'role': 'system', 'content': '${Bots.I.chatPromptOf(expert)}\n\nYour colleague ${asker.name} (${asker.role}) asks for your expert view. Answer concisely and concretely.'},
        {'role': 'user', 'content': question},
      ]);
      expert.log('work', 'Helped ${asker.name}: ${question.length > 80 ? '${question.substring(0, 80)}…' : question}');
      unawaited(Bots.I.save());
      return t.trim();
    } catch (e) {
      return 'Could not reach ${expert.name}: $e';
    }
  }

  void _officePump() {
    // Offices pause on a busy day so the owner's own chats keep their allowance; they pick up again tomorrow.
    if (Cloud.usage.value.light || Cloud.usage.value.resting) return;
    _officeWatchdog();
    final q = Offices.I.queue;
    if (q.isEmpty) return;
    final bgPaused = Cloud.background.value.pausedNow;
    var changed = false;
    DateTime? nextRetry;
    for (final j in List.of(q)) {
      if (_officeBusy.length >= AppState._officeParallel) break;
      // The bots' share of today's allowance is used: office work waits for the next UTC day (owner replies still run).
      if (bgPaused && j.kind != 'reply') {
        final at = DateTime.now().add(Cloud.untilBackgroundResets());
        if (nextRetry == null || at.isBefore(nextRetry)) nextRetry = at;
        continue;
      }
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
      if (_officeBusy.contains(b.id)) continue;
      // Busy with the owner in its own chat: the office waits for it.
      if (b.convId.isNotEmpty && runs.any((r) => r.convId == b.convId && !r.side)) continue;
      if (o.paused && j.kind != 'reply') {
        q.remove(j);
        changed = true;
        continue;
      }
      if (o.onHold && j.kind != 'reply') {
        if (nextRetry == null || o.holdUntil!.isBefore(nextRetry)) nextRetry = o.holdUntil;
        continue;
      }
      if (j.kind != 'reply' && o.runsLeft - (_officeStarting[o.id] ?? 0) <= 0) {
        q.remove(j);
        changed = true;
        final k = '${o.id}${o.dayKey}';
        if (_limitNoted.add(k)) {
          Offices.I.post(o, 'system',
              'Today\'s work limit is reached (${o.dailyLimit} sessions). The team carries on tomorrow, or raise the limit under Bots in the team.',
              kind: 'system');
        }
        continue;
      }
      q.remove(j);
      changed = true;
      if (j.kind != 'reply') _officeStarting[o.id] = (_officeStarting[o.id] ?? 0) + 1;
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
      if (o != null) unawaited(SystemBridge.I.scheduleAlarm(Offices.alarmId(o, 'retry'), at.add(const Duration(seconds: 5))));
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
        if (t.owner.isEmpty || _officeBusy.contains(t.owner)) continue;
        if (Offices.I.queue.any((j) => j.taskId == t.id)) continue;
        final b = Bots.I.byId(t.owner);
        if (b != null && runs.any((r) => r.convId == b.convId && !r.side)) continue;
        t.status = 'todo';
        Offices.I.startIfReady(o, t);
      }
    }
  }

  /// What started a bot's run, in a few words, for its trace.
  String _traceWhy(String convId, String lastUser) {
    if (!lastUser.startsWith(botWakeMark)) return 'You: $lastUser';
    final office = _officeCtx[convId];
    if (office != null) {
      final now = lastUser.indexOf('# Now');
      return 'Team: ${now >= 0 ? lastUser.substring(now + 5).trim() : 'work'}';
    }
    final i = lastUser.indexOf('Do this now:');
    final kind = _botWakeConvs[convId] ?? 'work';
    final label = switch (kind) { 'call' => 'Call', 'message' => 'Message', _ => 'Work' };
    return '$label: ${i >= 0 ? lastUser.substring(i + 12).trim() : 'heartbeat check'}';
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
      if (RegExp(r'allowance|done a lot today|refreshes tomorrow|resting until tomorrow', caseSensitive: false).hasMatch(e)) return 'credit';
      if (RegExp(r"you're offline|connection dropped|took too long|network error|socketexception|failed host lookup|connection (refused|reset|closed)|timed? ?out|no internet", caseSensitive: false).hasMatch(e)) return 'offline';
      if (RegExp(r"busy|couldn't reach its models|couldn't get an answer just now|lost the connection|short break|\b429\b|too many requests|\b50[234]\b|unavailable", caseSensitive: false).hasMatch(e)) return 'busy';
      return 'other';
    }
    return '';
  }

  /// One bot does one piece of office work in its own chat, with all its tools, and posts the result to the office.
  Future<void> _officeRun(Office o, Bot b, OfficeJob j) async {
    _officeBusy.add(b.id);
    _notify();
    var reserved = j.kind != 'reply';
    void unreserve() {
      if (!reserved) return;
      reserved = false;
      final n = (_officeStarting[o.id] ?? 1) - 1;
      if (n <= 0) {
        _officeStarting.remove(o.id);
      } else {
        _officeStarting[o.id] = n;
      }
    }
    OfficeTask? t;
    var begun = false;
    try {
      if (!await _ensureBotConv(b)) {
        // No chat yet (offline, not loaded): try again in 2 minutes, a few times, not three times a second.
        if (j.tries < 5) {
          Offices.I.enqueue(OfficeJob(officeId: j.officeId, botId: j.botId, kind: j.kind, taskId: j.taskId, instruction: j.instruction,
              at: j.at, after: DateTime.now().add(const Duration(minutes: 2)), tries: j.tries + 1));
        }
        return;
      }
      if (!b.active) await Bots.I.hire(b, b.convId);
      if (b.overBudget && j.kind != 'reply') {
        final now = DateTime.now();
        final tomorrow = DateTime(now.year, now.month, now.day + 1, 0, 5);
        if (!b.journal.any((e) => e.kind == 'budget' && now.difference(e.at).inHours < 20)) {
          b.log('budget', 'Paused team work: today\'s budget is used up');
          Offices.I.post(o, 'system', '${b.name} used today\'s token budget, so their work continues tomorrow. You can raise it in their settings.',
              kind: 'system');
        }
        Offices.I.enqueue(OfficeJob(officeId: o.id, botId: b.id, kind: j.kind, taskId: j.taskId, instruction: j.instruction, at: j.at, after: tomorrow));
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
      unreserve();
      // Small talk in the office gets an instant answer in character.
      if (j.kind == 'reply' && QuickLane.laneFor(j.instruction) == QuickLane.quick) {
        final text = await _officeQuick(o, b, j.instruction);
        if (text.isNotEmpty) Offices.I.post(o, b.id, text);
        return;
      }
      final convId = b.convId;
      final prompt = '$botWakeMark[Office: ${o.name}]\n${Offices.I.promptFor(o, b, j)}\n\n# Now\n${Offices.I.jobText(o, b, j)}';
      _officeCtx[convId] = o.id;
      _botWakeConvs[convId] = 'office';
      _officeJobKind[convId] = j.kind;
      await SystemBridge.I.keepAlive(true, text: '${o.name} is at work');
      final done = Completer<String>();
      final err = await startBackgroundTask(prompt, reuseConvId: convId, onDone: (r) {
        if (!done.isCompleted) done.complete(r);
      });
      if (err == null) begun = true;
      if (err != null) {
        if (_botWakeConvs[convId] == 'office') _botWakeConvs.remove(convId);
        if (t != null && t.status == 'doing') t.status = 'todo';
        if (t != null && j.kind == 'task') t.attempts = (t.attempts - 1).clamp(0, 99).toInt();
        o.runsToday = (o.runsToday - 1).clamp(0, 9999).toInt();
        if (err == 'busy') {
          Offices.I.enqueue(OfficeJob(officeId: o.id, botId: b.id, kind: j.kind, taskId: j.taskId, instruction: j.instruction, at: j.at,
              after: DateTime.now().add(const Duration(minutes: 1))));
        } else {
          Offices.I.post(o, 'system', 'Couldn\'t start ${b.name}\'s work: $err', kind: 'system');
        }
        return;
      }
      // Wait for the work to end (also when it is stopped, which never calls onDone).
      var idle = 0;
      final started = DateTime.now();
      while (!done.isCompleted) {
        await Future<void>.delayed(const Duration(seconds: 3));
        final running = runs.any((r) => r.convId == convId && !r.side);
        idle = running ? 0 : idle + 1;
        if (idle >= 3 || DateTime.now().difference(started) > const Duration(hours: 2)) break;
      }
      final finished = done.isCompleted; // onDone never fires for a stopped run (or the 2-hour cut-off)
      final reply = finished ? await done.future : '';
      // A failure that is not the bot's fault never burns a try: the work waits and runs again by itself.
      final failure = _wakeFailure(convId);
      if (failure == 'offline' || failure == 'busy' || failure == 'credit') {
        if (t != null && j.kind == 'task') {
          t.attempts = (t.attempts - 1).clamp(0, 99).toInt();
          if (t.status == 'doing') t.status = 'todo';
        }
        o.runsToday = (o.runsToday - 1).clamp(0, 9999).toInt();
        await _dropWakeTurn(convId);
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
        Offices.I.enqueue(OfficeJob(
            officeId: o.id, botId: b.id, kind: j.kind, taskId: j.taskId, instruction: j.instruction, at: j.at, after: DateTime.now().add(wait),
            tries: failure == 'credit' ? j.tries : j.tries + 1));
        return;
      }
      await _shrinkWake(convId, '$botWakeMark[Office ${o.name}: ${j.kind}${t == null ? '' : ' "${t.title}"'}]');
      final out = BotOutcome.parse(reply);
      // The owner spoke to this bot (or it was given a task): what it wrote is posted even with a stray silence tag on
      // it (that used to throw a real answer away). Elsewhere the bot may stay quiet, which is normal.
      final mustAnswer = j.kind == 'reply' || j.kind == 'task';
      if (out.text.trim().isEmpty || (out.kind == 'silent' && !mustAnswer)) {
        if (j.kind == 'chief' || j.kind == 'digest' || j.kind == 'mention') await _dropWakeTurn(convId);
      } else {
        final visible = BotOutcome.visible(reply);
        final list = _lists[convId];
        final last = list?.lastWhere((m) => m.role == 'assistant' && m.content.trim().isNotEmpty, orElse: () => ChatMessage(id: '', role: 'assistant'));
        if (last != null && last.id.isNotEmpty) await _rewrite(convId, last, visible);
        Offices.I.post(o, b.id, visible.isEmpty ? out.text : visible, kind: j.kind == 'digest' ? 'report' : 'chat', taskId: j.taskId);
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
      b.log('work', '${o.name}: ${j.kind}${t == null ? '' : ' "${t.title}"'}');
      unawaited(Bots.I.save());
    } catch (e) {
      // Nothing started: undo what this job claimed, so the task and the bot's chat aren't left mislabelled.
      if (!begun) {
        if (_botWakeConvs[b.convId] == 'office') _botWakeConvs.remove(b.convId);
        if (!reserved) o.runsToday = (o.runsToday - 1).clamp(0, 9999).toInt();
        final tt = t;
        if (tt != null && tt.status == 'doing') {
          tt.status = 'todo';
          if (j.kind == 'task') tt.attempts = (tt.attempts - 1).clamp(0, 99).toInt();
        }
      }
      Offices.I.post(o, 'system', '${b.name} hit a problem: $e', kind: 'system');
    } finally {
      unreserve();
      _officeCtx.remove(b.convId);
      _officeBusy.remove(b.id);
      Offices.I.saveSoon();
      _notify();
      Future<void>.delayed(const Duration(milliseconds: 300), _officePump);
    }
  }

  /// The office wake message is long (board, chat, brief): once the work is done only a short label stays in the bot's chat.
  Future<void> _shrinkWake(String convId, String label) async {
    final list = _lists[convId];
    if (list == null) return;
    final i = list.lastIndexWhere((m) => m.role == 'user' && m.content.startsWith(botWakeMark));
    if (i < 0) return;
    final m = list[i];
    if (m.content.length < 400) return;
    m.content = label;
    try {
      await repo.deleteMessages([m.id]);
      await repo.insertMessage(convId, m);
    } catch (_) {}
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
  Future<void> botOutcomeForTest(Bot b, String reply, String kind) => _botOutcome(b, reply, kind);
  @visibleForTesting
  Map<String, Set<String>> get wakeRowsForTest => _wakeRows;

  /// A one-line instant reply in the office chat, in the bot's own character.
  Future<String> _officeQuick(Office o, Bot b, String text) async {
    final route = submacRef;
    try {
      await RateLimiter.acquire(route.provider, 600, local, onWait: (_) {}, cancelled: () => false);
      final recent = o.posts.reversed.take(6).toList().reversed.map((x) =>
          '${x.from == 'you' ? 'Owner' : (Bots.I.byId(x.from)?.name ?? 'System')}: ${x.text.length > 200 ? '${x.text.substring(0, 200)}…' : x.text}');
      final t = await LlmClient().complete(source: 'office', maxTokens: 400, provider: route.provider, model: route.model, messages: [
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

  Future<void> _officeNotify(Office o, Bot b, String text) async {
    if (appVisible && viewingOffice == o.id) return;
    await SystemBridge.I.notifyBot(
        id: 9700 + (o.id.hashCode % 200).abs(), name: '${b.name} · ${o.name}', body: text, payload: 'office/${o.id}', reply: true);
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
    final ok = await Offices.I.ask(a);
    await SystemBridge.I.ringCancel(note);
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
    if (to.startsWith('office/')) {
      final o = Offices.I.byId(to.substring(7));
      // Same routing as typing in the team chat: only whoever is addressed (or picked) answers.
      if (o != null) TeamRun.I.send(o, text);
      return;
    }
    if (!to.startsWith('conv/')) return;
    final convId = to.substring(5);
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
      task.status = 'Reading your message';
      if (task.inModel) task.client?.cancelForSteer();
      _notify();
      return;
    }
    _notifyConvs.add(convId);
    await SystemBridge.I.keepAlive(true, text: 'Replying');
    _notify();
    unawaited(_runAgent(convId));
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

  /// Who is working in an office right now ("Nova: Competitor prices").
  /// Live lines for a team chat: who is working right now and on which step ("Nova · Searching the web · 0:42"),
  /// then who has a message from the owner waiting ("Idil read your message"). Never tool names.
  List<({Bot bot, String text, DateTime? since})> officeActivity(String officeId) {
    final out = <({Bot bot, String text, DateTime? since})>[];
    final seen = <String>{};
    for (final id in _officeBusy) {
      final b = Bots.I.byId(id);
      if (b == null || _officeCtx[b.convId] != officeId) continue;
      final r = runs.where((x) => x.convId == b.convId && !x.side).firstOrNull;
      seen.add(id);
      out.add((bot: b, text: r == null ? 'Getting started' : r.status, since: r?.started));
    }
    for (final j in Offices.I.queue) {
      if (j.officeId != officeId || j.kind != 'reply' || seen.contains(j.botId)) continue;
      final b = Bots.I.byId(j.botId);
      if (b == null) continue;
      seen.add(j.botId);
      out.add((bot: b, text: j.ready ? 'Read your message' : 'Will reply soon', since: null));
    }
    return out;
  }

  List<String> officeWorking(String officeId) {
    final o = Offices.I.byId(officeId);
    if (o == null) return const [];
    final out = <String>[];
    for (final id in _officeBusy) {
      final b = Bots.I.byId(id);
      if (b == null || _officeCtx[b.convId] != officeId) continue;
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
      final raw = await LlmClient().complete(source: 'agent', maxTokens: 1500, provider: route.provider, model: route.model, messages: [
        {
          'role': 'system',
          'content': 'You design AI colleagues ("bots") that live in a phone app, work on what the user asks and can call the user. '
              'From the user\'s description, reply with JSON only (no code fence): {"name": short human first name, "role": job title, '
              '"persona": 3-5 sentences: expertise, character, how they work and talk (a calm, professional, adult colleague: polite, '
              'plain and warm, no hype, no emoji, no exclamation marks, no cute or childish wording), "mission": one sentence, "icon": one of '
              'person, school, gavel, trending_up, travel_explore, fitness_center, payments, edit, code, work, favorite, campaign, '
              '"proactivity": quiet|balanced|active, "heartbeat_hours": 0 unless the user asked for regular checks (then 4-24), '
              '"routines": [] unless the user asked for scheduled work, else [{"time":"HH:MM","days":"daily|weekdays|mon,wed","kind":"work|message|call","do":"what to do"}]. '
              'A bot works only when the user asks unless they asked for a schedule, so its tokens are never spent on work nobody wanted. '
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
