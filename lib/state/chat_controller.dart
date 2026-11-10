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
    // A bot keeps its chat id, so its next wake may write there again; any other deleted chat stays deleted (CB-18).
    await repo.deleteConversation(id, keepWritable: Bots.I.isBotConv(id));
  }

  /// CB-18: every run is stopped and waited for first (side replies and bot wakes too), so none of them writes a
  /// row afterwards and brings a deleted chat back as a ghost that syncs to the backup again.
  Future<void> deleteAllConversations() async {
    final ids = {for (final c in conversations) c.id, ..._lists.keys, for (final r in runs) r.convId};
    newChat();
    conversations = [];
    final live = runs.toList();
    for (final r in live) {
      stopRun(r);
    }
    for (final id in ids) {
      _dropApprovalsFor(id);
    }
    for (final a in asks.toList()) {
      answerAsk(a, null);
    }
    _notify();
    try {
      await Future.wait([for (final r in live) r.whenFinished]).timeout(const Duration(seconds: 8));
    } catch (_) {
      // A step that never returns: the repo guard below still ignores its late writes.
    }
    _imagesOnce.clear();
    _regenerating.clear();
    _skillNotes.clear();
    _resumeNotes.clear();
    _lists.clear();
    Composer.drafts.clear();
    Bots.I.forgetDrafts();
    await repo.deleteAllConversations(keepWritable: botConvIds);
  }

  /// Deletes the account on the server and everything Telesia kept on this phone. Returns an error, or null when done.
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
      return 'Telesia couldn\'t reach the server. Check your connection and try again.';
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
    SkillSync.I.stop();
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
    // Saved browser flows are the account's too: send what is waiting, then stop (the folder is set aside the
    // moment another account signs in here, so it is never uploaded as theirs).
    await SkillSync.I.flush();
    SkillSync.I.stop();
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
    // R2 item 1: only a step that restarts to hear it is "reading"; a tool still running keeps its own line.
    if (task.inModel) task.show(RunPhase.waiting, RunStatus.reading);
    for (final a in asks.where((a) => a.convId == convId).toList()) {
      answerAsk(a, null);
    }
    if (task.inModel) task.client?.cancelForSteer();
    _notify();
  }

  /// "Open" in the bubble: Telesia comes up on the chat that is working.
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

  /// A stopped task's approval asks go with it: its card leaves Today / the job page / the team chat, its inline
  /// ask folds away, and an ask still queued is never shown. They used to stay up for hours, and approving one
  /// did nothing.
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
    // CB-30: a paste too long for one model call never goes out as it is (it was uploaded four times and then lost).
    if (PasteGuard.tooBig(text)) return _sendTooLong(text, attachments);
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
      // R2 item 1: only a step that restarts to hear it is "reading"; a tool still running keeps its own line.
    if (task.inModel) task.show(RunPhase.waiting, RunStatus.reading);
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
    // CB-22: also a "Try again" still removing the old reply (a second tap in the same frame).
    final convId = currentId;
    if (busy || anyRunHere || convId == null || _regenerating.contains(convId)) return;
    final lastUser = messages.lastIndexWhere((m) => m.role == 'user');
    if (lastUser < 0) return;
    // Claimed before the first await; released once the run has registered itself (synchronously in _runAgent).
    _regenerating.add(convId);
    // R2 item 2: only the failed (or last) answer goes. Finished steps and their results stay, and the task resumes
    // after them; the user's message is never sent again as a new request (RetryPlan).
    final list = messages;
    final plan = RetryPlan.of(list.sublist(lastUser + 1));
    final removed = plan.remove;
    list.removeWhere((m) => removed.contains(m));
    for (final m in removed) {
      workedFor.remove(m.id);
    }
    final awaitId = list[lastUser].id;
    if (plan.resume) {
      // A cut-off call gets its result first (the model needs one for every call); nothing is run again here.
      for (final e in plan.settle.entries) {
        final tm = ChatMessage(id: _uuid.v4(), role: 'tool', content: e.value, toolCallId: e.key.id, name: e.key.name);
        list.add(tm);
        await _save(convId, tm);
      }
      _resumeNotes[convId] = RetryPlan.note(settled: plan.settle.length);
    } else {
      // Nothing was done yet: the answer is made again from the same message (its pictures go along once more).
      _imagesOnce.unsend(convId, awaitId);
    }
    awaitingReply = awaitId;
    _notify();
    try {
      if (removed.isNotEmpty) await repo.deleteMessages(removed.map((e) => e.id).toList());
    } catch (_) {}
    Future<void> run;
    try {
      run = _runAgent(convId);
    } finally {
      _regenerating.remove(convId);
    }
    try {
      await run;
    } finally {
      _clearAwaiting(awaitId);
    }
  }

  /// CB-13: an edit can start here now: no run in this chat (the quick side reply too), no "Try again" or edit still
  /// removing the old turn, and no message still saving. The screen asks this before it opens the edit box.
  bool get canEditHere {
    final convId = currentId;
    return convId != null && !anyRunHere && !_regenerating.contains(convId) && _sendGate.openOn(convId) == null;
  }

  /// Replaces [msg] (and everything after it) with [newText] and answers it again. Returns false when nothing was sent,
  /// so the screen can say why instead of the tap doing nothing (CB-13).
  Future<bool> editAndResend(ChatMessage msg, String newText) async {
    newText = AiKeys.redact(newText).text;
    // CB-13/CB-22: checked and claimed before the first await, like regenerate(): two quick Send taps on the edit box
    // (or an edit racing "Try again") used to pass this check twice and send the message twice.
    if (!canEditHere || newText.trim().isEmpty) return false;
    final convId = currentId!;
    final idx = messages.indexOf(msg);
    if (idx < 0) return false;
    _regenerating.add(convId);
    // A message typed while this edit saves waits on the claim and then joins this edit's task (as in send()).
    final claim = _sendGate.claim(convId);
    final removed = messages.sublist(idx);
    messages.removeRange(idx, messages.length);
    // CB-13: a reply keeps its quote. The edit box shows only the user's own words (ReplyCodec.bodyOf), so the
    // original link goes back on top of the new words.
    final ref = ReplyCodec.decode(msg.content).ref;
    final content = ref != null ? ReplyCodec.encode(ref, newText) : newText.trim();
    final m = ChatMessage(id: _uuid.v4(), role: 'user', content: content, attachments: msg.attachments);
    // Added before anything is awaited, so it stays above a message sent while this edit saves.
    messages.add(m);
    awaitingReply = m.id;
    _notify();
    Future<void> run;
    try {
      try {
        await repo.deleteMessages(removed.map((e) => e.id).toList());
      } catch (_) {}
      try {
        await repo.insertMessage(convId, m);
      } catch (_) {}
      // The task registers itself synchronously in _runAgent, before a message that waited on the claim goes on.
      claim.open(convId);
      run = _runAgent(convId);
    } finally {
      claim.open(convId);
      _regenerating.remove(convId);
    }
    try {
      await run;
    } finally {
      _clearAwaiting(m.id);
    }
    return true;
  }

  /// CB-30: the user picks how a too-long paste goes: as a file (its first words stay the message), or as a file to be
  /// summarised a part at a time. Either way the model reads it from the workspace in parts. Nothing goes out unasked.
  Future<void> _sendTooLong(String text, List<Attachment> attachments) async {
    final name = PasteGuard.fileName();
    final file = Attachment(name: name, mime: 'text/plain', bytes: utf8.encode(text));
    final attach = PasteGuard.attachOption(), parts = PasteGuard.partsOption();
    final got = await askUser(UserAsk(
      kind: 'text',
      convId: currentId ?? '',
      title: PasteGuard.title(),
      prompt: PasteGuard.prompt(PasteGuard.kbOf(text)),
      options: [attach, parts],
    ));
    final answer = (got?['answer'] ?? '').trim();
    if (answer == attach) return send(PasteGuard.head(text), [...attachments, file]);
    if (answer == parts) return send(PasteGuard.partsAsk(), [...attachments, file]);
    // Their own words instead of a button: those words go with the file.
    if (answer.isNotEmpty && !PasteGuard.tooBig(answer)) return send(answer, [...attachments, file]);
    // Dismissed: nothing is sent, and the text is not lost.
    await _copyToWorkspace(file);
    banner = PasteGuard.notSent(name);
    bannerArgs = const {};
    _notify();
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
    final ref = telesiaRef;
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


  Future<void> _save(String convId, ChatMessage m) async {
    try {
      await repo.insertMessage(convId, m);
    } catch (e) {
      banner = Calm.offline('$e') ? 'You\'re offline. Messages will sync when you\'re back online.' : 'A message didn\'t sync.';
    }
  }
}
