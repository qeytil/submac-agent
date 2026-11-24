// The Investigation section: opening a case's chat and creating cases.
// Split out of app_state.dart (like bots_controller.dart). Fields stay on AppState.
part of '../app_state.dart';

extension AppStateCases on AppState {
  /// The case conversations, so the drawer, search and chat list can leave them out (like bot chats).
  Set<String> get caseConvIds => Cases.I.convIds;

  /// Opens a case: makes its conversation the first time, loads its messages, and shows it. The chat is the
  /// normal chat pipeline; the case context rides along through Cases.promptFor.
  Future<void> openCase(String caseId) async {
    final c = Cases.I.byId(caseId);
    if (c == null) return;
    if (c.convId.isEmpty || !conversations.any((x) => x.id == c.convId)) {
      try {
        final conv = await repo.createConversation(title: c.title, model: model);
        conversations.insert(0, conv);
        _lists[conv.id] = <ChatMessage>[];
        await Cases.I.setConv(c, conv.id);
      } catch (_) {
        return;
      }
    }
    if (_lists[c.convId] == null) {
      try {
        _lists[c.convId] = await repo.listMessages(c.convId);
      } catch (_) {}
    }
    await openConversation(c.convId);
  }

  /// Creates a case and opens it.
  Future<Case?> createCase({required String title, String brief = '', String reportedTo = ''}) async {
    final c = await Cases.I.create(title: title, brief: brief, reportedTo: reportedTo);
    await openCase(c.id);
    return c;
  }

  /// Starts a Solo pass: the case works on its own inside this session. The kickoff goes through the normal chat
  /// pipeline (the mode is already in the case prompt), so the agent plans with a todo, works what it can and reports
  /// at milestones. Nothing new is forked: it is the same run, steered by this message.
  Future<void> startSolo(String caseId) async {
    final c = Cases.I.byId(caseId);
    if (c == null) return;
    if (c.mode != CaseMode.solo) await Cases.I.update(c, mode: CaseMode.solo);
    if (currentId != c.convId) await openCase(caseId);
    await send(_soloKickoff, const []);
  }

  /// The user takes the case back mid-run: Partner again, no thread lost.
  Future<void> takeOver(String caseId) async {
    final c = Cases.I.byId(caseId);
    if (c == null) return;
    if (c.mode != CaseMode.partner) await Cases.I.update(c, mode: CaseMode.partner);
  }

  static const _soloKickoff =
      'Work this case now in Solo. Plan the next steps with a todo, use the evidence and the abilities you have, and '
      'advance what you can on your own; save anything you find into the case. Report only at milestones — a strong '
      'lead, a finished job, or a decision you need from me. Pause for money, danger or a real fork.';
}
