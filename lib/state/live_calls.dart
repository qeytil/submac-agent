// Live voice calls: prompts, live task tools, background tasks, saving call transcripts.
// Split out of app_state.dart (no behaviour change). Fields stay on AppState.
part of '../app_state.dart';

extension AppStateLive on AppState {
  bool get liveAvailable => Cloud.features.value.live;

  void setLiveVoice(String voice) {
    liveVoice = voice;
    local.liveVoice = voice;
    _notify();
  }

  /// [convId] is the chat this call continues (a bot's chat, or the current chat), used for the "Last time" recap.
  String liveSystemPrompt({String? convId}) {
    final mode = liveMode;
    liveMode = '';
    final base = _liveBasePrompt(convId ?? currentId);
    if (mode != 'translate') return base;
    return '$base\n\n# Interpreter mode (on now)\n'
        'You are a live interpreter between two people. First ask in one short sentence which two languages '
        '(suggest Somali and English). Then, for everything you hear, say it again in the other language, faithfully, '
        'in the first person, with no comments of your own. Keep names, numbers and dates exact. '
        'If the user says "stop translating", go back to normal.';
  }

  /// A short prompt made for voice (plan 3): what the model knows comes first, then the voice rules.
  /// The full chat prompt (cards, deep research, shell...) is left out: voice models lose facts buried deep
  /// in a long prompt, and Live re-reads the whole context every turn.
  String _liveBasePrompt(String? convId) {
    final sb = StringBuffer()
      ..writeln('You are ${AppConfig.appName}, a capable AI agent on the user\'s Android phone. You get real things done for them '
          'and talk like a sharp, warm friend. Plain words, no jargon. The user\'s own words always come first.')
      ..writeln()
      ..writeln(HouseRules.core);
    final know = _liveKnowBlock();
    if (know.isNotEmpty) sb..writeln()..writeln(know);
    final recap = _liveRecap(convId);
    if (recap.isNotEmpty) sb..writeln()..writeln(recap);
    sb
      ..writeln()
      ..writeln('# Right now')
      ..writeln(AppState._nowLine())
      ..writeln(replyLanguage == 'auto'
          ? 'Speak the language the user speaks (Somali in natural everyday Somali).'
          : 'Always speak $replyLanguage.')
      ..writeln(!agentEnabled
          ? 'Phone: actions are off in Settings ("Let it take action"), so you cannot open apps or control the phone. Say so plainly.'
          : SystemTools.phoneControl
              ? 'Phone: phone control is on. You can open apps, read the screen, tap, type and use WhatsApp yourself.'
              : 'Phone: phone control is off. You can still open apps, set alarms and draft messages; to tap, type or press Send '
                  'in other apps, ask the user to turn on Phone control in Telesia settings.')
      ..writeln()
      ..writeln(AppState._liveRules)
      ..writeln()
      ..writeln(speaksSomali(convId) ? Somali.voiceGuide : Somali.voiceHint);
    return sb.toString().trim();
  }

  /// "What you know": the user's profile and up to 20 saved facts (the oldest few, usually who they are,
  /// plus the newest), capped at about 600 tokens.
  String _liveKnowBlock() {
    final sb = StringBuffer();
    if (aboutYou.trim().isNotEmpty) sb.writeln('About the user: ${AppState._clip(aboutYou.trim(), 600)}');
    if (howToRespond.trim().isNotEmpty) sb.writeln('How they want replies: ${AppState._clip(howToRespond.trim(), 300)}');
    if (memoryEnabled) {
      final all = memory.facts.where((f) => f.fact.trim().isNotEmpty).toList();
      final pick = all.length <= 20 ? all : [...all.take(8), ...all.skip(all.length - 12)];
      var chars = 0;
      final lines = <String>[];
      for (final f in pick) {
        final t = AppState._clip(f.fact.trim(), 200);
        if (chars + t.length > 1600) break;
        chars += t.length;
        lines.add('- $t');
      }
      if (lines.isNotEmpty) sb..writeln('Facts you remember about them:')..writeln(lines.join('\n'));
      sb.writeln('When they tell you something worth keeping, save it with remember (one short sentence). Never save passwords or card numbers.');
    }
    final body = sb.toString().trim();
    return body.isEmpty ? '' : '# What you know\n$body';
  }

  /// "Last time": the chat's compaction summary plus its last few spoken or written turns, about 800 tokens.
  String _liveRecap(String? convId) {
    final list = convId == null ? null : _lists[convId];
    if (list == null || list.isEmpty) return '';
    final cut = _compactCut(list);
    final active = cut?.$2 ?? [for (final m in list) if (!AppState.isCompactMark(m)) m];
    final turns = <String>[];
    var chars = 0;
    for (final m in active.reversed) {
      if (turns.length >= 6) break;
      if (m.streaming || m.content.trim().isEmpty) continue;
      if (m.role == 'user' && !m.content.startsWith(botWakeMark)) {
        final t = AppState._clip(m.content.trim(), 300);
        chars += t.length;
        turns.add('User: $t');
      } else if (m.role == 'assistant' && (m.toolCalls == null || m.toolCalls!.isEmpty)) {
        final t = AppState._clip(m.content.trim(), 300);
        chars += t.length;
        turns.add('You: $t');
      }
      if (chars > 2000) break;
    }
    final summary = cut == null || cut.$1.trim().isEmpty ? '' : AppState._clip(cut.$1.trim(), 1200);
    if (summary.isEmpty && turns.isEmpty) return '';
    final sb = StringBuffer('# Last time\nThe chat this call continues. Use it as background; do not read it back unless asked.\n');
    if (summary.isNotEmpty) sb.writeln('Earlier: $summary');
    if (turns.isNotEmpty) sb.writeln(turns.reversed.join('\n'));
    return sb.toString().trim();
  }

  Future<String> _liveTaskTool(String name, Map<String, dynamic> a) async {
    final mine = runs.where((r) => !r.side && _liveTaskConvs.contains(r.convId)).toList();
    switch (name) {
      case 'live_task':
        final task = (a['task'] ?? '').toString().trim();
        if (task.isEmpty) return 'Error: no task given. Nothing was started; do not say anything is running.';
        if (!agentEnabled) {
          return 'Not started: actions are off in Settings ("Let it take action"). Nothing is running. Tell the user plainly.';
        }
        _lastLiveTaskConv = null;
        final r = await startBackgroundTask(task, fromLive: true);
        final conv = _lastLiveTaskConv;
        if (r != null || conv == null || !runs.any((x) => x.convId == conv && !x.side)) {
          return 'Not started${r == null ? '' : ': $r'}. Nothing is running in the background, so do not say it is. '
              'Do it now with your tools, or tell the user it could not start.';
        }
        final t = liveTasks.start(task, conv);
        return a['in_chat'] == true
            ? 'Started task ${t.id} in the chat. Tell the user to tap End to see it there; it keeps running either way.'
            : 'Started task ${t.id}. It is really running now, and keeps going after the call. Tell the user its id in a few words '
                'and keep talking; the result arrives as a [Task update] and in the chat.';
      case 'task_status':
        final b = BrowserAgent.I;
        final live = [
          for (final t in liveTasks.running)
            for (final r in mine.where((r) => r.convId == t.convId))
              '${t.id}: now ${r.status} (step ${r.step})${r.browsing && b.active ? ' on ${b.host}' : ''}',
        ];
        return [
          liveTasks.statusText(id: '${a['id'] ?? ''}'),
          ...live,
          if (asks.isNotEmpty) 'Waiting on the user: ${asks.first.title}',
        ].join('\n');
      case 'stop_task':
        if (mine.isEmpty) return 'No task is running.';
        for (final r in mine) {
          stopRun(r);
        }
        return 'Stopped.';
      case 'answer_task':
        final q = asks.where((x) => x.kind != 'login' && !x.secret).toList();
        if (q.isEmpty) return 'No task is waiting for an answer.';
        answerAsk(q.first, {'answer': (a['answer'] ?? '').toString()});
        return 'Passed on. The task continues.';
      case 'browser_show':
        if (!BrowserAgent.I.active) {
          return 'The browser is not open yet. It will show as soon as the task opens a page.';
        }
        BrowserAgent.I.openWindow(big: a['full_screen'] == true);
        return 'Showing the browser.';
      case 'browser_hide':
        BrowserAgent.I.hideWindow();
        return 'Hidden. The task keeps working.';
    }
    return 'Error: unknown task tool.';
  }

  /// A message from the linked Telegram chat: run it like a task and hand back the reply.
  Future<String> _telegramAsk(String text, String from) async {
    final c = Completer<String>();
    final reuse = DateTime.now().difference(_tgLast) < const Duration(hours: 2) ? _tgConv : null;
    _tgLast = DateTime.now();
    final err = await startBackgroundTask('[From Telegram] $text',
        ownChatTitle: 'Telegram: ${_shortTitle(text)}', reuseConvId: reuse, onDone: (r) {
      if (!c.isCompleted) c.complete(r);
    });
    if (err != null) return err;
    _tgConv = reuse ?? lastOwnConvId;
    return c.future.timeout(const Duration(minutes: 20), onTimeout: () => 'Still working on it. Check the Telesia app for the result.');
  }

  Future<String?> startBackgroundTask(String task,
      {bool fromLive = false, String? ownChatTitle, void Function(String reply)? onDone, String? reuseConvId, bool scheduled = false}) async {
    bool busyIn(String? id) => id != null && (_bgStarting.contains(id) || runs.any((r) => r.convId == id && !r.side));
    // A call's own chat (a bot's call is saved in that bot's chat) takes the call's tasks.
    if (fromLive && liveConvId != null && !busyIn(liveConvId)) currentId = liveConvId;
    final target = SessionRules.backgroundTarget(
      reuseConvId: reuseConvId,
      reuseLoaded: reuseConvId != null && _lists[reuseConvId] != null,
      reuseBusy: busyIn(reuseConvId),
      reuseIsBot: reuseConvId != null && Bots.I.isBotConv(reuseConvId),
      hasOwnTitle: ownChatTitle != null,
      currentId: currentId,
      currentBusy: busyIn(currentId),
      // A bot's chat that is merely open on screen is never borrowed for SubMac's own work.
      currentIsForeignBot: currentId != null && currentId != liveConvId && Bots.I.isBotConv(currentId),
    );
    // A bot's chat answers 'busy' (teams retry it); any other chat says it plainly (shown in the scheduled-task notice).
    if (target == BgTarget.busy) return Bots.I.isBotConv(reuseConvId) ? 'busy' : 'its last run is still going';
    if (target == BgTarget.reuse) {
      // Keep talking in the same chat (Telegram), so it remembers what was said.
      final id = reuseConvId!;
      final list = _lists[id]!;
      // Claimed before the first await: a second start for this chat (two scheduled runs, two Telegram messages)
      // now sees it as busy instead of starting a second agent (two answers).
      _bgStarting.add(id);
      try {
        final m = ChatMessage(id: _uuid.v4(), role: 'user', content: task);
        list.add(m);
        await repo.insertMessage(id, m);
        _notifyConvs.add(id);
        if (scheduled) _scheduledConvs.add(id);
        if (onDone != null) _doneCbs[id] = onDone;
        _notify();
        unawaited(_runAgent(id));
      } finally {
        _bgStarting.remove(id);
      }
      return null;
    }
    if (target == BgTarget.ownChat) {
      // A chat of its own, without switching what the user is looking at.
      try {
        final c = await repo.createConversation(title: ownChatTitle ?? _shortTitle(task), model: model);
        conversations.insert(0, c);
        final list = <ChatMessage>[];
        _lists[c.id] = list;
        final m = ChatMessage(id: _uuid.v4(), role: 'user', content: task);
        list.add(m);
        await repo.insertMessage(c.id, m);
        _notifyConvs.add(c.id);
        if (scheduled) _scheduledConvs.add(c.id);
        lastOwnConvId = c.id;
        if (onDone != null) _doneCbs[c.id] = onDone;
        _notify();
        unawaited(_runAgent(c.id));
        return null;
      } catch (e) {
        return 'Error: could not start the task ($e).';
      }
    }
    try {
      if (target == BgTarget.newChat) {
        final c = await repo.createConversation(title: (fromLive ? 'Live: ' : '') + _shortTitle(task), model: model);
        conversations.insert(0, c);
        currentId = c.id;
        messages = [];
        _lists[c.id] = messages;
      }
      final convId = currentId!;
      final list = _lists[convId] ?? messages;
      _lists[convId] = list;
      final m = ChatMessage(id: _uuid.v4(), role: 'user', content: task);
      list.add(m);
      await repo.insertMessage(convId, m);
      if (fromLive) {
        _liveTaskConvs.add(convId);
        _lastLiveTaskConv = convId;
        // The result also comes as a notification, and the task keeps running after the call (foreground service).
        _notifyConvs.add(convId);
        unawaited(SystemBridge.I.keepAlive(true, text: 'Working on: ${_shortTitle(task)}'));
      }
      _notify();
      unawaited(_runAgent(convId));
      return null;
    } catch (e) {
      return 'Error: could not start the task ($e).';
    }
  }


  /// Saves Live turns as the call goes, so ending the call never waits.
  /// Writes the turns before index [upTo] that are not saved yet.
  Future<void> saveLiveTurns(List<LiveTurn> turns, int upTo) async {
    if (_liveSaving || _liveSaved >= upTo) return;
    _liveSaving = true;
    final from = _liveSaved;
    var saved = from;
    try {
      var convId = liveConvId;
      if (convId == null) {
        // A SubMac call saves into the chat on screen, never into a bot's chat that happens to be open.
        final into = SessionRules.liveSaveTarget(currentId: currentId, currentIsBot: Bots.I.isBotConv(currentId));
        if (into == null) {
          final first = turns.firstWhere((t) => t.role == 'user', orElse: () => turns.first).text;
          final c = await repo.createConversation(title: 'Live: ${_shortTitle(first)}', model: 'live');
          conversations.insert(0, c);
          if (currentId == null) {
            currentId = c.id;
            messages = [];
            _lists[c.id] = messages;
          } else {
            _lists[c.id] = <ChatMessage>[];
          }
          convId = liveConvId = c.id;
        } else {
          convId = liveConvId = into;
        }
      }
      final list = _lists[convId] ?? (currentId == convId ? messages : <ChatMessage>[]);
      _lists[convId] = list;
      for (var i = from; i < upTo && i < turns.length; i++) {
        final t = turns[i];
        if (t.text.trim().isEmpty) {
          saved = i + 1;
          continue;
        }
        final m = ChatMessage(id: _uuid.v4(), role: t.role, content: t.text.trim());
        list.add(m);
        saved = i + 1;
        _liveSaved = saved;
        await repo.insertMessage(convId, m);
      }
      _bumpConversation(convId);
      _notify();
    } catch (e) {
      banner = Calm.offline('$e') ? 'You\'re offline. The rest of the call will save when you\'re back online.' : 'Part of the Live call didn\'t save.';
      _notify();
    } finally {
      _liveSaving = false;
    }
  }

  /// Called when a Live call starts.
  void beginLiveCall() {
    liveConvId = null;
    _liveSaved = 0;
  }

  /// Called when a Live call ends: saves whatever is left in the background.
  /// Returns the chat the call was saved in.
  Future<String?> saveLiveTranscript(List<LiveTurn> turns) async {
    for (var tries = 0; tries < 20 && _liveSaved < turns.length; tries++) {
      while (_liveSaving) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await saveLiveTurns(turns, turns.length);
    }
    final id = liveConvId;
    liveConvId = null;
    return id;
  }

  /// After a SubMac call (plan 3, step 5): one small fast-model pass turns the transcript into a short recap
  /// posted in the chat (so chat and the next call know what was said) and saves new facts to memory.
  /// Bot calls do their own wrap-up in [botCallEnded].
  Future<void> liveCallEnded(List<LiveTurn> turns, String? convId) async {
    final real = turns.where((t) => t.text.trim().isNotEmpty).toList();
    if (convId == null || real.where((t) => t.role == 'user').length < 2) return;
    final ref = submacRef;
    final sb = StringBuffer();
    for (final t in real) {
      final line = '${t.role == 'user' ? 'User' : 'Telesia'}: ${AppState._clip(t.text.trim(), 400)}\n';
      if (sb.length + line.length > 6000) break;
      sb.write(line);
    }
    final known = memory.facts.map((f) => '- ${f.fact}').toList();
    final have = known.length > 40 ? known.sublist(known.length - 40) : known;
    try {
      final raw = await LlmClient().complete(source: 'live', maxTokens: 400, provider: ref.provider, model: ref.model, messages: [
        {
          'role': 'system',
          'content': 'You read the transcript of a voice call between the user and their assistant Telesia. Reply with JSON only: '
              '{"recap":"...","facts":["..."]}. recap: at most 3 short lines in the language of the call: what was discussed, '
              'what was decided or done, and any next step. facts: 0 to 3 lasting facts about the user worth remembering '
              '(who they are, preferences, people, goals, important dates), each one short sentence in the third person. '
              'Never include passwords, card numbers, one-off details, or facts already known. Use [] when there are none.',
        },
        {'role': 'user', 'content': 'Already known:\n${have.isEmpty ? '(nothing)' : have.join('\n')}\n\nTranscript:\n$sb'},
      ]);
      final m = RegExp(r'\{[\s\S]*\}').firstMatch(raw);
      if (m == null) return;
      final j = jsonDecode(m.group(0)!);
      if (j is! Map) return;
      final recap = '${j['recap'] ?? ''}'.trim();
      if (recap.isNotEmpty) {
        final list = _lists[convId];
        final msg = ChatMessage(id: _uuid.v4(), role: 'assistant', content: 'Call recap\n${AppState._clip(recap, 600)}');
        list?.add(msg);
        await repo.insertMessage(convId, msg);
        _bumpConversation(convId);
      }
      final facts = j['facts'];
      if (memoryEnabled && facts is List) {
        for (final f in facts.take(3)) {
          final t = '$f'.trim();
          if (t.isNotEmpty) await memory.execute('remember', {'fact': t});
        }
      }
      _notify();
    } catch (_) {}
  }
}
