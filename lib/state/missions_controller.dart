// Mission mode (owner 2026-11-07): bots and teams that work toward a goal on their own across many background runs.
// Wiring of Missions (lib/services/missions.dart) into wakes, team jobs, tools, notifications and the stop switch.
part of '../app_state.dart';

extension AppStateMissions on AppState {
  void _wireMissions() {
    final ms = Missions.I;
    ms.nameOf = (m) => m.kind == 'team' ? (Offices.I.byId(m.ownerId)?.name ?? 'Team') : (Bots.I.byId(m.ownerId)?.name ?? 'Bot');
    ms.wakeBot = _missionWakeBot;
    ms.wakeTeam = _missionWakeTeam;
    ms.notify = _missionNotify;
    ms.onStop = _missionStopRun;
    ms.idle = () async {
      if (!runs.any((r) => !r.side) && _officeBusy.isEmpty) await SystemBridge.I.keepAlive(false);
    };
    Bots.I.missionOf = (b) {
      final m = ms.of('bot', b.id);
      return m == null || m.finished ? '' : ms.brief(m);
    };
    Offices.I.missionOf = (o, b) {
      final m = ms.liveOf('team', o.id);
      if (m == null) return '';
      // The lead runs the mission; the members see its goal so their part fits it.
      return b.id == o.chiefId ? ms.brief(m) : '# The team\'s mission\n${m.goal}';
    };
  }

  /// A bot's mission wake: only when the bot can really start now (else the mission retries by itself).
  Future<bool> _missionWakeBot(Mission m, String instruction) async {
    final b = Bots.I.byId(m.ownerId);
    if (b == null || !b.active) return false;
    if (!await _awaitWakeReady()) return false;
    if (!_wakeMayClaim(b)) return false;
    if (b.overBudget) return false;
    // Owner 2026-11-07: a mission wake is governed by the bot's own allowance (above), not by a hardcoded
    // account-wide guard. SubMac's server refusal is the backstop.
    await _botWake(b, 'your mission', instruction, 'mission');
    // _botWake marks the chat while its run goes on; no mark means it did not start.
    return b.convId.isNotEmpty && (_botWakeConvs[b.convId] == 'mission' || runs.any((r) => r.convId == b.convId && !r.side));
  }

  /// A team's mission wake: the lead gets a 'mission' job (it hands work to teammates with team-turns assignments).
  Future<bool> _missionWakeTeam(Mission m, String instruction) async {
    final o = Offices.I.byId(m.ownerId);
    if (o == null || o.paused) return false;
    final lead = Bots.I.byId(o.chiefId) ?? (o.members.isEmpty ? null : Bots.I.byId(o.members.first));
    if (lead == null) return false;
    Offices.I.enqueue(OfficeJob(officeId: o.id, botId: lead.id, kind: 'mission', instruction: instruction));
    _officePump();
    return true;
  }

  /// The end of a bot's mission run: its reply stays in its chat as a quiet note; the mission notifies a summary.
  Future<void> _missionBotOutcome(Bot b, List<ChatMessage> list, String reply, String failure) async {
    final m = Missions.I.liveOf('bot', b.id) ?? Missions.I.of('bot', b.id);
    if (failure == 'offline' || failure == 'busy' || failure == 'credit') {
      await _dropWakeTurn(b.convId);
      if (m != null) await Missions.I.runFailed(m, failure);
      return;
    }
    final last = list.lastWhere((x) => x.role == 'assistant' && x.content.trim().isNotEmpty, orElse: () => ChatMessage(id: '', role: 'assistant'));
    final visible = BotOutcome.visible(last.id.isEmpty ? reply : last.content);
    if (last.id.isNotEmpty && visible.trim().isNotEmpty) await _rewrite(b.convId, last, visible);
    if (visible.trim().isNotEmpty) b.log('note', 'Mission: ${visible.split('\n').first}');
    await Bots.I.save();
    if (m != null) await Missions.I.runEnded(m, reply: visible);
  }

  Future<void> _missionTeamEnded(Office o, String reply) async {
    final m = Missions.I.liveOf('team', o.id);
    if (m == null) return;
    await Missions.I.runEnded(m, reply: BotOutcome.visible(reply));
  }

  /// A mission's progress or [needs you] notification: the bot's (or the team's) own notification, summary only.
  Future<void> _missionNotify(Mission m, String text, {bool needs = false}) async {
    if (m.kind == 'team') {
      final o = Offices.I.byId(m.ownerId);
      final lead = o == null ? null : Bots.I.byId(o.chiefId);
      if (o == null || lead == null) return;
      if (!needs && lead.quietNow()) return;
      await _officeNotify(o, lead, text, needs: needs);
      return;
    }
    final b = Bots.I.byId(m.ownerId);
    if (b == null) return;
    if (!needs && b.quietNow()) return;
    if (appVisible && currentId == b.convId) return;
    await _notifyBot(b, text, high: needs);
  }

  /// The stop switch reaches a run going on now.
  void _missionStopRun(Mission m) {
    if (m.kind == 'team') {
      // Only the mission's own lead job: a queued one is dropped; one running now finds the mission stopped at its next
      // mission tool call and ends. The team's other work and chats go on.
      Offices.I.queue.removeWhere((j) => j.officeId == m.ownerId && j.kind == 'mission');
      Offices.I.saveSoon();
      return;
    }
    final b = Bots.I.byId(m.ownerId);
    if (b == null || b.convId.isEmpty || _botWakeConvs[b.convId] != 'mission') return;
    for (final r in runs.where((r) => r.convId == b.convId && !r.side).toList()) {
      stopRun(r);
    }
  }

  /// A mission tool call from a bot's chat or a team turn.
  Future<String> _missionTool(String name, Map<String, dynamic> args, String? convId) async {
    await Missions.I.init();
    final b = Bots.I.byConv(convId);
    if (b == null) return 'Error: mission tools are for bots and teams.';
    final officeId = convId == null ? null : _officeCtx[convId];
    final o = officeId == null ? null : Offices.I.byId(officeId);
    if (o != null) {
      // A team turn: the team's mission. Only the lead schedules or closes it; anyone may log progress.
      final m = Missions.I.liveOf('team', o.id);
      if ((name == 'mission_schedule_next' || name == 'mission_done') && m != null && b.id != o.chiefId) {
        return 'Error: ${Bots.I.byId(o.chiefId)?.name ?? 'the lead'} runs the team\'s mission; log your progress with mission_update.';
      }
      final ownerHere = AppStateAgentRunner.ocOfficeJob[convId] == 'reply';
      final goalArg = '${args['goal'] ?? ''}'.trim();
      // Owner 2026-11-08 (self-direction): the lead may propose a team mission while nobody is watching. It is saved
      // on the lead; the owner's yes in the team chat starts it (see _officeRun).
      if (!ownerHere && name == 'mission_plan' && goalArg.isNotEmpty && (m == null || m.finished || goalArg != m.goal)) {
        if (b.id != o.chiefId) {
          return 'Only ${Bots.I.byId(o.chiefId)?.name ?? 'the lead'} proposes a team mission. Tell them what you would take on.';
        }
        Bots.I.propose(b, goalArg, [for (final x in (args['steps'] is List ? args['steps'] as List : const [])) '$x'], team: o.id);
        return 'Saved your proposal for the team mission "$goalArg". You cannot start it while the owner is away. Ask the '
            'owner in one short message to take it on (office_ask_owner reaches their phone); when they say yes in the '
            'team chat the mission starts by itself.';
      }
      return Missions.I.execute(name, args,
          m: m,
          who: b.name,
          start: ownerHere ? (goal) => Missions.I.start('team', o.id, goal, by: b.name, firstIn: const Duration(minutes: 5)) : null,
          assign: (who, text) async => _missionAssign(o, b, who, text));
    }
    // The bot's own chat: the owner is present unless this is a wake (nobody watching).
    final k = convId == null ? null : _botWakeConvs[convId];
    final ownerHere = k == null || k == 'chat';
    final goalArg = '${args['goal'] ?? ''}'.trim();
    final m = Missions.I.liveOf('bot', b.id);
    // Owner 2026-11-08 (self-direction): nobody is watching, but the bot may still propose a mission. It is saved and
    // shown; the owner's yes in this chat starts it (Bots.approvedProposal, applied at the top of the bot's next turn).
    if (!ownerHere && name == 'mission_plan' && goalArg.isNotEmpty && (m == null || m.finished || goalArg != m.goal)) {
      Bots.I.propose(b, goalArg, [for (final x in (args['steps'] is List ? args['steps'] as List : const [])) '$x']);
      return 'Saved your proposal to take on "$goalArg". You cannot start it while the owner is away. Write the owner ONE '
          'short message asking to take it on (the goal and the first step), end it with @message, and stop here. When '
          'they say yes in this chat the mission starts by itself and you begin.';
    }
    return Missions.I.execute(name, args,
        m: m,
        who: b.name,
        // A mission the owner asked for in chat: its first own wake follows this conversation shortly.
        start: ownerHere ? (goal) => Missions.I.start('bot', b.id, goal, by: b.name, firstIn: const Duration(minutes: 5)) : null);
  }

  /// A team mission step handed to teammate [who]: posted as "Name: …", which starts their turn (TeamReact assign).
  String? _missionAssign(Office o, Bot from, String who, String text) {
    final k = who.trim().toLowerCase().replaceFirst('@', '');
    final to = [for (final id in o.members) Bots.I.byId(id)].whereType<Bot>().where((x) => x.name.toLowerCase() == k || x.role.toLowerCase() == k).firstOrNull;
    if (to == null) {
      return 'no teammate "$who" in ${o.name} (${[for (final id in o.members) Bots.I.byId(id)?.name].whereType<String>().join(', ')}).';
    }
    if (to.id == from.id) return 'that is you: do it yourself.';
    Offices.I.post(o, from.id, '${to.name}: $text', dedupe: false);
    return null;
  }
}

/// Test seams of mission mode.
extension AppStateMissionsTest on AppState {
  @visibleForTesting
  void wireMissionsForTest() => _wireMissions();

  @visibleForTesting
  Future<String> missionToolForTest(String name, Map<String, dynamic> args, String convId) => _missionTool(name, args, convId);

  @visibleForTesting
  Future<void> missionBotOutcomeForTest(Bot b, String reply, {String failure = ''}) =>
      _missionBotOutcome(b, listsForTest[b.convId] ?? <ChatMessage>[], reply, failure);

  @visibleForTesting
  Map<String, String> get officeCtxForTest => _officeCtx;
}
