// Notifications that say who it is from and what came of the work (owner 2026-11-05, docs/notifications.md).
// Agent (SubMac's own chats and scheduled tasks), Bots (a bot's private chat) and Teams (a team chat) each have their
// own channel, title and look; the line while work runs is on the silent Background work channel (TaskService).
part of '../app_state.dart';

extension AppStateNotifications on AppState {
  /// The notification slot of a bot's messages (one per bot: a new message replaces the last).
  static int botNoteId(Bot b) => 9200 + (b.id.hashCode % 500).abs();

  /// The slot of a team's conversation (one per team).
  static int teamNoteId(Office o) => 9700 + (o.id.hashCode % 200).abs();

  /// The slot of SubMac's own result for a chat.
  static int agentNoteId(String convId) => 9400 + (convId.hashCode % 190).abs();

  /// A bot's message: its name, its face, a 1-3 line summary of [text] and an inline Reply into its private chat.
  /// [summarize] false: [text] is already one plain line (a missed call, a pause note).
  Future<void> _notifyBot(Bot b, String text, {bool reply = true, bool summarize = true, int? id, bool high = false}) async {
    final body = summarize ? NotifText.summary(text, fallback: text.trim().split('\n').first) : text.trim();
    if (body.isEmpty) return;
    final face = NotifFace.ofBot(b.id, b.name, b.look);
    await SystemBridge.I.notifyFrom(
        id: id ?? botNoteId(b),
        channel: NotifChannels.bots,
        title: NotifText.title(NotifFrom.bot, bot: b.name),
        body: body,
        payload: b.convId.isEmpty ? 'botchat/${b.id}' : 'conv/${b.convId}',
        reply: reply && b.convId.isNotEmpty,
        initial: face.initial,
        color: face.color,
        high: high);
  }

  /// SubMac's own result for [convId] ("SubMac", red), with a Reply into that chat. Nothing when the reply says
  /// nothing (a watcher's NO_CHANGE, an empty run).
  Future<void> _notifyAgent(String convId, String reply, {String task = '', bool failed = false}) async {
    final body = failed ? 'Couldn’t finish${task.isEmpty ? ' your task' : ' “${BgRun.title(task, fallback: '')}”'}. Open SubMac to see why.' : NotifText.result(reply, task: task);
    if (body.isEmpty) return;
    await SystemBridge.I.notifyFrom(
        id: agentNoteId(convId),
        channel: NotifChannels.agent,
        title: NotifText.title(NotifFrom.agent),
        body: body,
        payload: 'conv/$convId',
        reply: true,
        initial: '',
        color: NotifFace.agentAccent);
  }

  /// A team post for the owner: "<Team>" with "<Bot>: message" in the team's conversation. [needs]: a "[needs you]"
  /// post or a question for the owner (pops up). Nothing while the owner looks at that team.
  Future<void> _officeNotify(Office o, Bot b, String text, {bool needs = false}) async {
    if (appVisible && viewingOffice == o.id) return;
    final body = NotifText.summary(text, max: 200, lines: 2, fallback: text.trim());
    if (body.isEmpty) return;
    final face = NotifFace.ofBot(b.id, b.name, b.look);
    await SystemBridge.I.notifyTeam(
        id: teamNoteId(o),
        teamId: o.id,
        team: NotifText.title(NotifFrom.team, team: o.name),
        sender: b.name,
        text: body,
        initial: face.initial,
        color: face.color,
        needs: needs);
  }

  /// A run ended that someone away from the screen is waiting on: SubMac's own scheduled task, or an answer to a
  /// reply typed in a notification (to SubMac or to a bot). Bot wakes report through their own outcome.
  void _notifyRunEnd(String convId, List<ChatMessage> list, AgentRun run, {required bool scheduled, required bool fromNote}) {
    if (run.cancelled || (!scheduled && !fromNote)) return;
    if (appVisible && currentId == convId) return;
    final reply = OcRunEnd.replyOf(list, run.wrote);
    final failed = reply.isEmpty && list.any((m) => run.wrote.contains(m.id) && (m.error?.isNotEmpty ?? false));
    final bot = Bots.I.byConv(convId);
    if (bot != null) {
      if (!fromNote) return;
      final text = BotOutcome.visible(reply);
      if (text.isEmpty) return;
      unawaited(_notifyBot(bot, text));
      return;
    }
    final title = conversations.where((c) => c.id == convId).firstOrNull?.title ?? '';
    unawaited(_notifyAgent(convId, reply, task: title.replaceFirst(RegExp(r'^(Scheduled|Watching):\s*'), ''), failed: failed));
  }

  @visibleForTesting
  void notifyRunEndForTest(String convId, List<ChatMessage> list, AgentRun run, {bool scheduled = false, bool fromNote = false}) =>
      _notifyRunEnd(convId, list, run, scheduled: scheduled, fromNote: fromNote);

  @visibleForTesting
  Future<void> officeNotifyForTest(Office o, Bot b, String text, {bool needs = false}) => _officeNotify(o, b, text, needs: needs);

  @visibleForTesting
  void ocRunEndedForTest(String convId, List<ChatMessage> list, AgentRun run) => _ocRunEnded(convId, list, run);

  @visibleForTesting
  Set<String> get scheduledConvsForTest => _scheduledConvs;

  @visibleForTesting
  Future<void> notificationReplyForTest(String to, String text) => _notificationReply(to, text);
}
