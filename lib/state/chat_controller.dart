// Chat: conversations, send/regenerate/edit, stop/steer, titles, saving messages.
// Split out of app_state.dart (no behaviour change). Fields stay on AppState.
part of '../app_state.dart';

extension AppStateChat on AppState {
  /// True while a task (not a quick side reply) runs in the open chat.
  bool get busy => runs.any((r) => r.convId == currentId && !r.side);

  bool get anyRunHere => runs.any((r) => r.convId == currentId);

  List<AgentRun> get runsHere => runs.where((r) => r.convId == currentId).toList();

  bool _hasRun(String convId) => runs.any((r) => r.convId == convId);

  /// How often streamed words reach the screen (v1.13.101). The reply lets out its words in batches every 90 ms
  /// (revealEvery), so the old 40 ms notify rebuilt the chat twice for every batch it could show: pure jank.
  static const streamNotifyEvery = Duration(milliseconds: 80);

  void _throttledNotify() {
    if (_notifyTimer?.isActive ?? false) return;
    _notifyTimer = Timer(AppStateChat.streamNotifyEvery, _notify);
  }

  void newChat({String? projectId}) {
    currentId = null;
    messages = [];
    newChatProject = projectId;
    // A first message still saving belongs to the draft it was typed in, never to this new one.
    _sendGate.forgetNewChat();
    _notify();
  }

  Project? get currentProject => currentId == null ? Projects.I.byId(newChatProject) : Projects.I.forChat(currentId);

  Future<void> openConversation(String id) async {
    currentId = id;
    _sendGate.forgetNewChat();
    if (_hasRun(id) && _lists[id] != null) {
      messages = _lists[id]!;
      _notify();
      return;
    }
    // A bot's chat already in memory (the bot service keeps it current, and opening the bot just loaded it): show it
    // at once, then refresh quietly. Swapping bots in the Bots workspace never flashes an empty chat or "Opening".
    final warm = _lists[id];
    if (warm != null && Bots.I.byConv(id) != null) {
      messages = warm;
      loadingMessages = false;
      _notify();
      unawaited(_refreshWarm(id, warm));
      return;
    }
    messages = [];
    loadingMessages = true;
    _notify();
    try {
      final loaded = await repo.listMessages(id);
      if (currentId == id) {
        messages = loaded;
        _lists[id] = loaded;
      }
      for (final c in conversations) {
        if (c.id == id) c.onPhone = true;
      }
    } catch (e) {
      banner = Calm.offline('$e') ? 'You\'re offline. This chat will open when you\'re back online.' : 'This chat didn\'t load. Open it again in a moment.';
    }
    loadingMessages = false;
    _notify();
    // Pictures in history: from this phone's copy first, else from the account. A file whose upload never finished
    // (offline when it was sent) is sent again now, so the user's other phones can show it too.
    final opened = messages;
    for (final m in opened) {
      var resend = false;
      for (final a in m.attachments) {
        final lp = a.localPath;
        final here = lp != null && lp.isNotEmpty && File(lp).existsSync() ? File(lp) : null;
        if (a.isImage && a.bytes == null && here != null) {
          here.readAsBytes().then((b) {
            a.bytes = b;
            _notify();
          }).catchError((_) {});
        } else if (a.isImage && a.bytes == null && a.path != null) {
          repo.downloadAttachment(a.path!).then((b) {
            a.bytes = b;
            _notify();
          }).catchError((_) {});
        }
        if (a.path == null && (a.bytes != null || here != null)) resend = true;
      }
      if (resend && m.role == 'user') unawaited(_resendAttachments(id, m));
    }
  }

  /// Reloads a bot chat shown from memory. Replaces it only while it is still on screen, nothing runs in it, and the
  /// saved copy is at least as long (a message still being saved is never dropped).
  Future<void> _refreshWarm(String id, List<ChatMessage> shown) async {
    try {
      final loaded = await repo.listMessages(id);
      if (currentId != id || _hasRun(id) || !identical(messages, shown) || loaded.length < shown.length) return;
      if (loaded.length == shown.length && (loaded.isEmpty || loaded.last.id == shown.last.id)) return;
      messages = loaded;
      _lists[id] = loaded;
      _notify();
    } catch (_) {}
  }

  Future<void> renameConversation(String id, String title) async {
    final c = conversations.firstWhere((e) => e.id == id);
    c.title = title;
    _notify();
    await repo.updateConversation(id, {'title': title}, touch: false);
  }

  Future<void> togglePin(String id) async {
    final c = conversations.firstWhere((e) => e.id == id);
    c.pinned = !c.pinned;
    _notify();
    await repo.updateConversation(id, {'pinned': c.pinned}, touch: false);
  }

  Future<void> setArchived(String id, bool archived) async {
    final c = conversations.firstWhere((e) => e.id == id);
    c.archived = archived;
    if (archived && currentId == id) newChat();
    _notify();
    await repo.updateConversation(id, {'archived': archived}, touch: false);
  }

  Future<void> deleteConversation(String id) async {
    for (final r in runs.where((r) => r.convId == id)) {
      r.stop();
    }
    _lists.remove(id);
    conversations.removeWhere((e) => e.id == id);
    if (currentId == id) newChat();
    _notify();
    await repo.deleteConversation(id);
  }

  Future<void> deleteAllConversations() async {
    newChat();
    conversations = [];
    _notify();
    await repo.deleteAllConversations();
  }

  /// Deletes the account on the server and everything SubMac kept on this phone. Returns an error, or null when done.
  Future<String?> deleteAccount() async {
    try {
      final r = await http
          .post(Uri.parse('${AppConfig.supabaseUrl}/functions/v1/account-delete'),
              headers: await Cloud.headers(source: 'account'), body: jsonEncode({'confirm': 'DELETE'}))
          .timeout(const Duration(seconds: 90));
      if (r.statusCode != 200) {
        try {
          return '${(jsonDecode(r.body) as Map)['error'] ?? 'Your account couldn\'t be deleted right now. Please try again.'}';
        } catch (_) {
          return 'Your account couldn\'t be deleted right now. Please try again.';
        }
      }
    } catch (_) {
      return 'SubMac couldn\'t reach the server. Check your connection and try again.';
    }
    for (final r in List.of(runs)) {
      r.stop();
    }
    newChat();
    conversations = [];
    await clearAccountState();
    await Scheduler.I.dropAccount();
    try {
      await repo.store.wipe();
    } catch (_) {}
    // The account is gone on the server: nothing of it stays on this phone.
    await BotSync.I.leave(send: false);
    await local.wipeAll();
    try {
      await Supabase.instance.client.auth.signOut();
    } catch (_) {}
    _notify();
    return null;
  }

  Future<void> signOut() async {
    for (final r in List.of(runs)) {
      r.stop();
    }
    newChat();
    conversations = [];
    // Nothing of this account may reach the next one that signs in on this phone (memory, custom instructions,
    // loaded chats, open questions, team messages, a picked skill).
    await clearAccountState();
    await Push.I.forget();
    // Scheduled tasks belong to the account: stop and unarm them so none runs under the next account.
    await Scheduler.I.useAccount('');
    // Bots belong to the account, not to this phone: send what is waiting, then take them off it.
    await BotSync.I.leave();
    await repo.signOut();
    _notify();
  }

  /// Forgets, on this phone, everything that belongs to the signed-in account and is kept in memory or device
  /// settings outside the per-account chat store. Nothing is deleted on the server.
  Future<void> clearAccountState() async {
    for (final a in List.of(asks)) {
      answerAsk(a, null);
    }
    asks.clear();
    _lists.clear();
    _skillNotes.clear();
    _bgStarting.clear();
    pickedSkill = null;
    awaitingReply = null;
    banner = null;
    workedFor.clear();
    aboutYou = '';
    howToRespond = '';
    memory.forgetDevice();
    try {
      await Inbox.I.clear();
    } catch (_) {}
    _notify();
  }

  // ---------- the floating task bubble ----------
  /// The messages of [convId] as loaded on this phone (empty when not loaded).
  List<ChatMessage> messagesOf(String convId) => _lists[convId] ?? const <ChatMessage>[];

  /// A message typed in the floating bubble while a task drives the screen: the task hears it at its next step,
  /// exactly like a message sent in its chat. Anything the task was waiting on (a question) is released.
  Future<void> steerTask(String convId, String text) async {
    final t = AiKeys.redact(text.trim()).text;
    if (t.isEmpty) return;
    if (convId == currentId) return send(t, const []);
    final task = runs.where((r) => r.convId == convId && !r.side && !r.cancelled).firstOrNull;
    if (task == null) return;
    final list = _lists[convId];
    final userMsg = ChatMessage(id: _uuid.v4(), role: 'user', content: t);
    if (list != null) list.add(userMsg);
    try {
      await repo.insertMessage(convId, userMsg);
    } catch (_) {}
    _bumpConversation(convId);
    Bots.I.userReplied(convId);
    task.inbox.add(t);
    BrowserJobs.I.userSaid(convId, t);
    task.status = 'Reading your message';
    for (final a in asks.where((a) => a.convId == convId).toList()) {
      answerAsk(a, null);
    }
    if (task.inModel) task.client?.cancelForSteer();
    _notify();
  }

  /// "Open" in the bubble: SubMac comes up on the chat that is working.
  Future<void> openFromBubble(String convId) async {
    await SystemBridge.I.bringToFront();
    if (convId.isNotEmpty && convId != 'live' && conversations.any((c) => c.id == convId)) {
      await openConversation(convId);
    }
  }

  // ---------- chatting ----------
  /// Stops every run in the open chat.
  void stop() {
    for (final r in runsHere) {
      r.stop();
      if (!r.side) _dropApprovalsFor(r.convId);
    }
    _notify();
  }

  /// A stopped task's approval asks go with it: its card leaves Today / the job page / the team chat, its sheet closes,
  /// and an ask still queued is never shown. They used to stay up for hours, and approving one did nothing.
  void _dropApprovalsFor(String convId) {
    unawaited(Offices.I.expireFor(convId));
    confirmQueue.stopped(convId);
  }

  void stopRun(AgentRun r) {
    r.stop();
    if (!r.side) _dropApprovalsFor(r.convId);
    if (!r.side) BrowserJobs.I.stopAllFor(r.convId);
    // Off the screen at once, even if a step (a page load, a phone action) is still finishing underneath.
    runs.remove(r);
    if (r.phone && !runs.any((x) => x.phone)) unawaited(SystemBridge.I.phoneBadge(false));
    TaskBubble.I.runEnded(r.convId);
    if (r.browsing) BrowserAgent.I.onStopTask = null;
    for (final m in (_lists[r.convId] ?? const <ChatMessage>[])) {
      if (m.streaming) m.streaming = false;
    }
    for (final a in asks.where((a) => a.convId == r.convId).toList()) {
      answerAsk(a, null);
    }
    if (r.browsing) BrowserAgent.I.handBack();
    // The ongoing "Working on your task" notification goes now, not when the stopped step finally returns.
    if (SessionRules.keepAliveOffAfterStop(
        tasksLeft: runs.where((x) => !x.side).length, telegramWaiting: TelegramBridge.I.on && TelegramBridge.I.paired && !appVisible)) {
      unawaited(SystemBridge.I.keepAlive(false));
    }
    _notify();
  }

  /// Set when the user tried to chat before connecting a model.

  Future<void> send(String text, List<Attachment> attachments) async {
    if (text.trim().isEmpty && attachments.isEmpty) return;
    // An API key pasted in chat is moved to the phone's encrypted storage before the message is saved or synced.
    text = AiKeys.redact(text).text;
    // PLAN 1.4: claim this chat's run before anything is awaited. A message sent while the first one is still saving
    // or uploading its photo joins the same task instead of starting a second agent (double answers, double charges).
    final claimed = _sendGate.openOn(currentId);
    // A task is already working in this chat: the task itself hears the message at its next step,
    // answers it with `say`, and changes course. Anything it was waiting on (a login, a question) is released.
    var task = runs.where((r) => r.convId == currentId && !r.side).firstOrNull;
    final claim = (task == null && claimed == null) ? _sendGate.claim(currentId) : null;
    final sk = pickedSkill;
    pickedSkill = null;
    // The project picked for this new-chat draft (the user may tap "+" for another one while this saves).
    final draftProject = newChatProject;

    // Our own list: callers may pass a const list, and big photos are swapped for smaller copies below.
    final files = [...attachments];
    // A reply (swipe or hold a message, then Reply): the quote rides at the top of the message, so the model reads which
    // message the user means and the bubble shows it. Only a reply drafted in this chat is used.
    final reply = replyDraft.value;
    replyDraft.value = null;
    final content = reply != null && reply.convId == (currentId ?? '') && text.trim().isNotEmpty ? ReplyCodec.encode(reply, text) : text.trim();
    final userMsg = ChatMessage(id: _uuid.v4(), role: 'user', content: content, attachments: files)..animateIn = true;
    messages.add(userMsg);
    final list = messages;
    if (claim != null) awaitingReply = userMsg.id;
    _notify();

    String convId;
    final isFirst = currentId == null && claim != null;
    try {
      if (claimed != null) {
        // Wait for the first message of this send to be saved, so the chat keeps its order.
        final id = await claimed.ready;
        if (id == null) throw StateError('first message not saved');
        convId = id;
      } else if (currentId == null) {
        final fallback = text.trim().isEmpty ? 'New chat' : _shortTitle(text);
        final c = await repo.createConversation(title: fallback, model: model);
        conversations.insert(0, c);
        // Still on this draft: it becomes the open chat. Moved on ("+", another chat): it is saved, the screen stays.
        if (SessionRules.adoptNewChat(currentId: currentId, onScreen: messages, draft: list)) {
          currentId = c.id;
          newChatProject = null;
        }
        claim?.alias(c.id);
        _lists[c.id] = list;
        if (draftProject != null) await Projects.I.assign(c.id, draftProject);
        convId = c.id;
      } else {
        convId = currentId!;
      }
      _lists[convId] = list;
      // Big gallery photos are shrunk to 2048 px first (camera shots already are), in the background.
      await _shrinkPhotos(files);
      // The workspace copy is local and quick (the agent reads it by path); the upload is not, so it runs in parallel
      // with the model call below and the message is saved again with its storage paths when it finishes.
      await Future.wait([for (final a in files) _copyToWorkspace(a)]);
      await repo.insertMessage(convId, userMsg);
    } catch (e) {
      userMsg.error = 'This message didn\'t save. Check your connection and send it again.';
      if (awaitingReply == userMsg.id) awaitingReply = null;
      claim?.open(null);
      // The skill chip comes back for the retry instead of riding along on some other chat's next task.
      if (sk != null && pickedSkill == null) pickedSkill = sk;
      _notify();
      return;
    }
    if (sk != null) _skillNotes[convId] = '# Skill for this message: ${sk.name}\n${sk.instruction}';
    if (files.isNotEmpty) unawaited(_uploadAttachments(convId, userMsg));
    // The first message is saved: release the claim. The task registers itself synchronously in _runAgent below,
    // before any message that waited on the claim runs again.
    claim?.open(convId);
    _bumpConversation(convId);
    Bots.I.userReplied(convId);
    if (isFirst && !Bots.I.isBotConv(convId)) unawaited(_generateTitle(convId, text));
    if (claim == null) {
      task = runs.where((r) => r.convId == convId && !r.side).firstOrNull;
      // The task this message waited on has not built its first step yet: the message is already in the chat it
      // reads, so it simply answers both. Nothing more to do here.
      if (task != null && !task.cancelled && !task.payloadBuilt) {
        _notify();
        return;
      }
    }
    if (task != null && !task.cancelled && runs.contains(task)) {
      task.inbox.add(text.trim().isEmpty ? '(sent an attachment)' : content);
      if (text.trim().isNotEmpty) BrowserJobs.I.userSaid(convId, text.trim());
      task.status = 'Reading your message';
      for (final a in asks.where((a) => a.convId == convId).toList()) {
        answerAsk(a, null);
      }
      if (task.inModel) {
        // Waiting on the model with nothing streamed yet: restart this step so it hears the user now.
        task.client?.cancelForSteer();
      } else if (!runs.any((r) => r.convId == convId && r.side)) {
        // A tool is busy (a page loading, the phone working): answer the user right away in a quick
        // side reply, and the task acts on their words as soon as the tool returns.
        task.inboxAcked = true;
        unawaited(_runAgent(convId, side: true));
      }
      if (awaitingReply == userMsg.id) awaitingReply = null;
      _notify();
      return;
    }
    if (claim == null) awaitingReply = userMsg.id;
    try {
      await _runAgent(convId);
    } finally {
      _clearAwaiting(userMsg.id);
    }
  }

  /// Shrinks big gallery photos to [PhotoPrep.maxSide] px (JPEG) before they are sent. Never fails the send.
  Future<void> _shrinkPhotos(List<Attachment> attachments) async {
    await Future.wait([
      for (var i = 0; i < attachments.length; i++)
        if (attachments[i].isImage && attachments[i].bytes != null && PhotoPrep.canShrink(attachments[i].mime))
          () async {
            final a = attachments[i];
            try {
              final small = await PhotoPrep.shrinkInBackground(a.bytes!);
              if (small == null) return;
              attachments[i] = Attachment(name: PhotoPrep.jpgName(a.name), mime: 'image/jpeg', bytes: small, path: a.path, localPath: a.localPath);
            } catch (_) {}
          }(),
    ]);
  }

  /// Uploads a message's files in parallel (after the model call has started), then saves the message again with
  /// their storage paths.
  Future<void> _uploadAttachments(String convId, ChatMessage m) async {
    var any = false;
    await Future.wait([
      for (final a in m.attachments)
        if (a.path == null)
          () async {
            try {
              a.path = await repo.uploadAttachment(convId, a);
              if (a.path != null) any = true;
            } catch (_) {}
          }(),
    ]);
    if (any) await _save(convId, m);
  }

  /// Uploads the files of an older message that never reached the account (read from this phone's copy).
  Future<void> _resendAttachments(String convId, ChatMessage m) async {
    for (final a in m.attachments) {
      final lp = a.localPath;
      if (a.path == null && a.bytes == null && lp != null && File(lp).existsSync()) {
        try {
          a.bytes = await File(lp).readAsBytes();
        } catch (_) {}
      }
    }
    await _uploadAttachments(convId, m);
  }

  Future<void> regenerate() async {
    // Any run here, the quick side reply too: its late reply would land under the new one (ISSUES T-17).
    if (busy || anyRunHere || currentId == null) return;
    final lastUser = messages.lastIndexWhere((m) => m.role == 'user');
    if (lastUser < 0) return;
    final removed = messages.sublist(lastUser + 1);
    messages.removeRange(lastUser + 1, messages.length);
    final awaitId = messages[lastUser].id;
    _imagesOnce.unsend(currentId!, awaitId);
    awaitingReply = awaitId;
    _notify();
    try {
      await repo.deleteMessages(removed.map((e) => e.id).toList());
    } catch (_) {}
    try {
      await _runAgent(currentId!);
    } finally {
      _clearAwaiting(awaitId);
    }
  }

  Future<void> editAndResend(ChatMessage msg, String newText) async {
    newText = AiKeys.redact(newText).text;
    if (busy || anyRunHere || currentId == null) return;
    final idx = messages.indexOf(msg);
    if (idx < 0) return;
    final removed = messages.sublist(idx);
    messages.removeRange(idx, messages.length);
    _notify();
    try {
      await repo.deleteMessages(removed.map((e) => e.id).toList());
    } catch (_) {}
    final convId = currentId!;
    final m = ChatMessage(id: _uuid.v4(), role: 'user', content: newText.trim(), attachments: msg.attachments);
    messages.add(m);
    awaitingReply = m.id;
    _notify();
    try {
      await repo.insertMessage(convId, m);
    } catch (_) {}
    try {
      await _runAgent(convId);
    } finally {
      _clearAwaiting(m.id);
    }
  }

  Future<void> _copyToWorkspace(Attachment a) async {
    if (a.bytes == null) return;
    try {
      final ws = await AgentTools.workspaceDir();
      final dir = Directory('$ws/uploads');
      await dir.create(recursive: true);
      final f = File('${dir.path}/${a.name}');
      await f.writeAsBytes(a.bytes!);
      a.localPath = f.path;
    } catch (_) {}
  }

  void _bumpConversation(String id) {
    final i = conversations.indexWhere((c) => c.id == id);
    if (i < 0) return;
    final c = conversations.removeAt(i);
    c.updatedAt = DateTime.now();
    conversations.insert(0, c);
  }

  String _shortTitle(String text) {
    final t = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    return t.length > 40 ? '${t.substring(0, 40)}…' : t;
  }

  Future<void> _generateTitle(String convId, String firstText) async {
    final p0 = activeProvider;
    if (p0 == null || firstText.trim().isEmpty) return;
    final ref = submacRef;
    final p = ref.provider;
    try {
      await RateLimiter.acquire(p, 300, local, onWait: (_) {}, cancelled: () => false);
      final t = await LlmClient().complete(source: 'title', maxTokens: 200, provider: p, model: ref.model, messages: [
        {
          'role': 'system',
          'content': 'Write a short title (max 6 words) for a chat that starts with the user message below. '
              'Reply with the title only, no quotes or punctuation at the end.'
        },
        {'role': 'user', 'content': firstText},
      ]);
      var title = t.trim().split('\n').first.replaceAll('"', '').trim();
      if (title.isEmpty) return;
      if (title.length > 60) title = title.substring(0, 60);
      await renameConversation(convId, title);
    } catch (_) {}
  }

  /// After a bot's task: when it hit tool errors, was corrected by the owner, or was nudged by its Chief (and now and
  /// then after a longer task that went well), a cheap model call turns what happened into at most two short, general
  /// lessons. They pass the same personal-detail scrub as everything that travels with the bot.
  Future<void> _learnFrom(Bot b, String request) async {
    final runsNow = BotTraces.I.of(b.id);
    if (runsNow.isEmpty) return;
    final r = runsNow.first;
    final failed = r.steps.where((s) => s.failed).toList();
    final req = request.replaceAll(botWakeMark, '').trim();
    final corrected = AppState._correction.hasMatch(req);
    final nudged = req.contains('checked in: you have been quiet');
    final mistake = failed.isNotEmpty || corrected || nudged || r.failed;
    final now = DateTime.now();
    final last = _lessonAt[b.id];
    // Mistakes teach at most every 10 minutes; tasks that went well (4+ steps) at most every 6 hours.
    if (mistake) {
      if (last != null && now.difference(last).inMinutes < 10) return;
    } else {
      if (r.steps.length < 4 || (last != null && now.difference(last).inHours < 6)) return;
    }
    if (b.overBudget) return;
    final p0 = activeProvider;
    if (p0 == null) return;
    _lessonAt[b.id] = now;
    String cut(String t, int n) {
      final x = t.replaceAll(RegExp(r'\s+'), ' ').trim();
      return x.length > n ? '${x.substring(0, n)}…' : x;
    }

    final steps = [
      for (final s in r.steps.take(30)) '- ${s.tool}${s.failed ? ' FAILED: ${cut(s.output, 160)}' : ''}',
    ].join('\n');
    final why = nudged
        ? 'Its Chief had to nudge it for going quiet on a task.'
        : corrected
            ? 'The owner corrected it.'
            : failed.isNotEmpty || r.failed
                ? 'Some steps failed.'
                : 'The task went well.';
    final have = b.lessons.map((l) => '- ${l.text}').take(30).join('\n');
    final ref = submacRef;
    try {
      await RateLimiter.acquire(ref.provider, 900, local, onWait: (_) {}, cancelled: () => false);
      final raw = await (LlmClient()..background = true).complete(source: 'bot', maxTokens: 800, provider: ref.provider, model: ref.model, messages: [
        {
          'role': 'system',
          'content': 'You help an AI colleague (a "${b.role}") get better at its job. From what happened in its last task, write 0 to 2 '
              'lessons it should follow next time. Each lesson: one line under 160 characters, general know-how about HOW to do this '
              'kind of work (method, tools, websites, checking work, when to ask). Never include names, emails, phone numbers, '
              'addresses, amounts, dates or any fact about the person it works for. Skip lessons it already has. '
              'Reply with a JSON array of strings only, e.g. ["…"]. Reply [] when there is nothing worth keeping.',
        },
        {
          'role': 'user',
          'content': 'What happened: $why\nRequest: ${cut(req, 400)}\nSteps:\n$steps\nResult: ${cut(r.result, 300)}\n'
              'Lessons it already has:\n${have.isEmpty ? '(none)' : have}',
        },
      ]);
      final m = RegExp(r'\[[\s\S]*\]').firstMatch(raw);
      if (m == null) return;
      final list = jsonDecode(m.group(0)!);
      if (list is! List) return;
      for (final l in list.take(2)) {
        final t = '$l'.trim();
        if (t.isNotEmpty) await Bots.I.addLesson(b, t, source: nudged ? 'nudge' : corrected ? 'correction' : mistake ? 'mistake' : 'task');
      }
    } catch (_) {}
  }

  Future<void> _save(String convId, ChatMessage m) async {
    try {
      await repo.insertMessage(convId, m);
    } catch (e) {
      banner = Calm.offline('$e') ? 'You\'re offline. Messages will sync when you\'re back online.' : 'A message didn\'t sync.';
    }
  }
}
