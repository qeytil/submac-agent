// Tool scoping, the resilient model stream, step rows and labels.
// Split out of app_state.dart (no behaviour change). Fields stay on AppState.
part of '../app_state.dart';

extension AppStateAgentStream on AppState {
  /// Opens the tool groups the newest message points at. For a wake, only the job part counts (the team snapshot
  /// above it mentions everything).
  void _scopeFor(String convId, List<ChatMessage> list, String text) {
    var t = text;
    if (t.startsWith(botWakeMark)) {
      final now = t.indexOf('\n# Now\n');
      if (now >= 0) t = t.substring(now + 7);
      final doIt = t.indexOf('Do this now:');
      if (doIt >= 0) t = t.substring(doIt);
      final cut = t.indexOf('You are working in the background');
      if (cut > 0) t = t.substring(0, cut);
    }
    ChatMessage? lu;
    for (final m in list.reversed) {
      if (m.role == 'user') {
        lu = m;
        break;
      }
    }
    final appNames = <String>[
      for (final e in ConnectorCatalog.connected.keys) ConnectorCatalog.byId(e)?.name ?? e,
      for (final s in mcpServers.where((e) => e.enabled)) s.name,
    ];
    final g = _convGroups[convId] ??= <String>{};
    g.addAll(ToolScope.hinted(t, attachments: lu?.attachments.isNotEmpty ?? false, appNames: appNames));
    if (deepResearch) g.add(ToolScope.browser);
    if (_skillNoteUsed || _liveTaskConvs.contains(convId)) g.addAll(ToolScope.groups);
    // The Business adviser always has its books, documents and charts at hand.
    final bot = Bots.I.byConv(convId);
    if (bot != null && BotTemplates.isBusiness(bot)) g.addAll(const {ToolScope.business, ToolScope.files, ToolScope.media});
    // The Health adviser always has the family health book, reminders and files at hand.
    if (bot != null && BotTemplates.isHealth(bot)) g.addAll(const {ToolScope.health, ToolScope.schedule, ToolScope.files, ToolScope.media});
    // The Coder always has its whole workbench: code, files, connected apps (GitHub) and the browser to test sites.
    if (bot != null && BotTemplates.isCoder(bot)) g.addAll(const {ToolScope.code, ToolScope.files, ToolScope.apps, ToolScope.browser});
  }

  /// The tools for this chat: the core set, the groups it opened, and more_tools for the rest.
  List<Map<String, dynamic>> _scopedTools(String convId) {
    final all = _toolsFor(convId);
    if (_allToolsNow.contains(convId)) return all;
    final g = _convGroups[convId] ?? const <String>{};
    final scoped = ToolScope.filter(all, g);
    if (scoped.length == all.length) return all;
    return [...scoped, AppState._moreToolsDef];
  }

  /// The core tools for a short everyday message, plus a door to everything else.
  List<Map<String, dynamic>> _lightTools(String convId) => [
        for (final t in _toolsFor(convId))
          if (AppState._lightNames.contains('${(t['function'] as Map?)?['name']}') || Bots.names.contains('${(t['function'] as Map?)?['name']}') ||
              ('${(t['function'] as Map?)?['name']}' == WhatsAppTools.tool && _waTalk(convId)))
            t,
        AppState._moreToolsDef,
      ];

  /// The last [n] or so messages, starting at a user message so tool calls keep their results.
  List<ChatMessage> _tail(List<ChatMessage> list, int n) {
    if (list.length <= n) return list;
    var i = list.length - n;
    while (i > 0 && list[i].role != 'user') {
      i--;
    }
    return list.sublist(i);
  }

  /// One model call with the app's time limits (PLAN 1.3): 10 s for headers and 30 s of silence (in [LlmClient]),
  /// one quiet retry before any output, and at 45 s with no word a clear "SubMac is busy. Tap to try again." (the
  /// user's message stays). The server already moves to another model or key when one fails, so the phone never
  /// sends a second copy to anything else.
  Future<LlmResult> _streamResilient({
    required AgentRun run,
    required ModelRef route,
    required List<Map<String, dynamic>> payload,
    required List<Map<String, dynamic>>? tools,
    required ChatMessage asst,
    String lane = QuickLane.full,
    String? effort,
    /// CB-24: [asst] still shows a dropped call's words; the first new word replaces them (this text stays before it).
    String? redoFrom,
  }) async {
    final baseStatus = run.status;
    final useTools = AppState._capTools(tools);
    final watch = FirstWordWatch(() => run.client?.cancel());
    var redo = redoFrom;
    LlmException late() => LlmException(StreamPolicy.busyText, status: 503, code: 'busy_wait');
    var retries = 0;
    watch.start();
    try {
      while (true) {
        if (run.cancelled) return LlmResult('', <ToolCall>[], 'cancelled');
        try {
          await RateLimiter.acquire(route.provider, RateLimiter.estimateTokens(payload, useTools), local,
              onWait: (sec) {
                run.status = 'Just a moment';
                _throttledNotify();
              },
              cancelled: () => run.cancelled || watch.fired);
          if (run.cancelled) return LlmResult('', <ToolCall>[], 'cancelled');
          if (watch.fired) throw late();
          run.status = baseStatus;
          _notify();
          final client = LlmClient()
            ..chatId = run.convId
            ..background = _backgroundLane(run.convId);
          run.client = client;
          final r = await client.streamChat(
            provider: route.provider,
            model: route.model,
            messages: payload,
            tools: useTools,
            effort: effort,
            source: _officeCtx.containsKey(run.convId) ? 'office' : (Bots.I.byConv(run.convId) != null ? 'bot' : (run.side ? 'side' : 'agent')),
            onDelta: (d) {
              watch.heard();
              final before = redo;
              if (before != null) {
                asst.content = before + d;
                redo = null;
              } else {
                asst.content += d;
              }
              _throttledNotify();
            },
            // A thinking model is working before its first word: say so, so the line never looks frozen.
            onReasoning: (_) {
              watch.heard();
              if (asst.content.isEmpty && run.status == 'Thinking') {
                run.status = 'Thinking it through';
                _throttledNotify();
              }
            },
            // The model has chosen its next step while still writing it (a long document can take a while):
            // show that step now instead of "Thinking".
            onToolStart: (name) {
              watch.heard();
              final early = AppState._earlyLabels[name];
              if (early == null) return;
              run.status = early;
              _throttledNotify();
            },
          );
          // Stopped by the 45 s first-word limit (not by the user, not to hear a new message).
          if (watch.fired && !run.cancelled && !client.steered) throw late();
          return r;
        } on LlmException catch (e) {
          if (e.code == 'busy_wait') rethrow;
          if (watch.fired && !run.cancelled && run.client?.steered != true) throw late();
          // Something was already shown, the user stopped it, or it restarts to hear them: never start over here.
          if (run.cancelled || asst.content.isNotEmpty || watch.gotWord || run.client?.steered == true) rethrow;
          if (!StreamPolicy.retryBeforeOutput(retriesDone: retries, gotOutput: watch.gotWord, retryable: e.isRetryable)) rethrow;
          final wait = StreamPolicy.retryWait(retryAfter: e.retryAfter, elapsed: watch.elapsed);
          if (wait == null) rethrow;
          retries++;
          for (var left = wait.inSeconds < 1 ? 1 : wait.inSeconds; left > 0; left--) {
            if (run.cancelled || watch.fired) break;
            run.status = 'Trying again in ${left}s';
            _notify();
            await Future<void>.delayed(const Duration(seconds: 1));
          }
          if (watch.fired && !run.cancelled) throw late();
          run.status = baseStatus;
        }
      }
    } finally {
      watch.stop();
    }
  }

  /// With SubMac in the background, the ongoing notification follows the task ("Searching the web") instead of a
  /// fixed line, at most every 4 seconds (silent channel, no sound or vibration).
  void _bgLine(AgentRun run) {
    if (appVisible || run.side || _botWakeConvs.containsKey(run.convId)) return;
    final now = DateTime.now();
    if (now.difference(_bgLineAt) < const Duration(seconds: 4)) return;
    _bgLineAt = now;
    unawaited(SystemBridge.I.keepAlive(true, text: run.status));
  }

  void _addStep(AgentRun run, RunStep row) {
    run.trail.add(row);
    if (run.trail.length > 80) run.trail.removeAt(0);
  }

  /// The plain label for a step (used by the folded step list under a finished task).
  String stepLabel(String name, Map<String, dynamic> args) => _toolLabel(name, args);

  String _toolLabel(String name, [Map<String, dynamic> args = const {}]) {
    if (BrowserAgent.names.contains(name)) return BrowserAgent.I.label(name, args);
    if (BrowserJobs.names.contains(name)) return BrowserJobs.I.label(name, args);
    switch (name) {
      case 'bot_remember':
        return 'Taking a note';
      case 'bot_desk':
        return 'Updating my desk';
      case 'bot_followup':
      case 'bot_routine':
        return 'Planning ahead';
      case 'bot_watch':
        return 'Setting a watch';
      case 'bot_call':
        return 'Calling you';
      case 'bot_ask':
        return 'Asking ${args['bot'] ?? 'a colleague'}';
      case 'docs_share':
        return 'Sharing to the Docs';
      case 'docs_list':
      case 'docs_read':
        return 'Checking the Docs';
    }
    if (name == 'ask_user') return 'Waiting for you';
    if (name == 'email_send') return 'Sending the email';
    if (name == 'email_read') return 'Reading an email';
    if (ConnectorCatalog.emailTools.contains(name)) return 'Checking your email';
    if (name == 'api_call') return 'Calling ${Uri.tryParse('${args['url']}')?.host ?? 'an API'}';
    if (name.startsWith('app_')) return 'Working in ${ConnectorCatalog.appNameFor(name)}';
    switch (name) {
      case 'make_document':
        return switch ('${args['kind']}') {
          'xlsx' || 'csv' => 'Making your spreadsheet',
          'slides' => 'Making your slides',
          'docx' => 'Writing your document',
          _ => 'Making your PDF',
        };
      case 'images_to_pdf':
        return 'Making your PDF';
      case 'prayer_times':
        return 'Checking prayer times';
      case 'hijri_date':
        return 'Checking the Hijri date';
      case 'quran':
        return 'Opening the Quran';
      case 'qibla':
        return 'Finding the Qibla';
      case 'money_add':
        return 'Writing it in your notebook';
      case 'money_report':
      case 'money_delete':
        return 'Checking your notebook';
      case 'read_notifications':
        return 'Checking your notifications';
      case 'run_shell':
        return 'Running a command';
      case 'read_file':
        return 'Reading a file';
      case 'write_file':
      case 'append_file':
        return 'Writing a file';
      case 'edit_file':
        return 'Editing a file';
      case 'list_dir':
        return 'Looking through files';
      case 'fetch_url':
        return 'Reading a web page';
      case 'delete_file':
        return 'Moving to Trash';
      case 'generate_image':
        return 'Creating an image';
      case 'generate_video':
        return 'Making a video';
      case 'generate_media':
        return args['kind'] == 'video' ? 'Making a video' : 'Creating an image';
      case 'code_media':
        return switch ((args['kind'] ?? '').toString()) { 'audio' => 'Composing a sound', 'video' => 'Animating', _ => 'Drawing' };
      case 'add_provider':
        return 'Saving your provider';
      case 'connect_mcp':
        return 'Connecting ${args['name'] ?? 'the server'}';
      case 'projects':
        return 'Updating your projects';
      case 'sites':
        return args['action'] == 'unpublish' ? 'Taking your site offline' : 'Checking your sites';
      case 'connect_app':
        return 'Waiting for you to connect ${args['app'] ?? 'the app'}';
      case 'open_app':
        return 'Opening ${args['name'] ?? 'the app'}';
      case 'phone_screen':
      case 'phone_wait':
        return 'Looking at the screen';
      case 'phone_tap':
      case 'phone_long_press':
      case 'phone_gesture':
        return 'Tapping';
      case 'phone_type':
        return 'Typing';
      case 'phone_scroll':
        return 'Scrolling';
      case 'phone_nav':
        return 'Using the phone';
      case 'phone_settings':
        return 'Adjusting your phone';
      case 'set_alarm':
        return 'Setting the alarm';
      default:
        return AgentTools.describe(name, args, done: false);
    }
  }
}
