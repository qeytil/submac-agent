#!/usr/bin/env python3
"""Investigation phase 5: Solo + milestones + case notifications. New files are committed separately; this script only
edits existing files."""
import io


def sub(path, old, new):
    with io.open(path, encoding='utf-8') as f:
        s = f.read()
    n = s.count(old)
    assert n == 1, path + ' :: expected 1, found ' + str(n) + ' :: ' + repr(old[:60])
    with io.open(path, 'w', encoding='utf-8') as f:
        f.write(s.replace(old, new))


# notif_text.dart: the Investigation channel
sub('lib/services/notif_text.dart',
    "  static const work = 'telesia_work_v2';\n",
    "  static const work = 'telesia_work_v2';\n\n  /// The Investigation section's own channel (docs/investigation.md §20): its own sound and importance.\n  static const cases = 'telesia_cases_v2';\n")

# app_state.dart: import the case notification helper (parts share these imports)
sub('lib/app_state.dart',
    "import 'services/case_abilities.dart';\nimport 'services/case_ability_defaults.dart';",
    "import 'services/case_abilities.dart';\nimport 'services/case_ability_defaults.dart';\nimport 'services/case_notify.dart';")

# notifications.dart: a case run reports through its own channel
sub('lib/state/notifications.dart',
    "  void _notifyRunEnd(String convId, List<ChatMessage> list, AgentRun run, {required bool scheduled, required bool fromNote}) {\n    if (run.cancelled) return;",
    """  void _notifyRunEnd(String convId, List<ChatMessage> list, AgentRun run, {required bool scheduled, required bool fromNote}) {
    if (run.cancelled) return;
    // The Investigation section reports through its own channel (docs/investigation.md §20): a Solo pass that ends
    // away from the screen leaves a milestone alert that opens the case room, never an ordinary "Telesia" result.
    final caseFor = Cases.I.byConv(convId);
    if (caseFor != null) {
      if (appVisible && currentId == convId) return;
      final caseReply = OcRunEnd.replyOf(list, run.wrote);
      if (caseReply.trim().isNotEmpty) unawaited(CaseNotify.milestone(caseFor, caseReply));
      return;
    }""")

# cases_controller.dart: start a Solo pass and take the case back
sub('lib/state/cases_controller.dart',
    """  /// Creates a case and opens it.
  Future<Case?> createCase({required String title, String brief = '', String reportedTo = ''}) async {
    final c = await Cases.I.create(title: title, brief: brief, reportedTo: reportedTo);
    await openCase(c.id);
    return c;
  }
}""",
    """  /// Creates a case and opens it.
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
}""")

# case_screen.dart: the Solo strip above the composer
sub('lib/screens/case_screen.dart',
    """                footer: const Column(mainAxisSize: MainAxisSize.min, children: [
                  AskBar(),
                  TaskBar(),
                  Composer(perChatDrafts: true),
                ]),""",
    """                footer: Column(mainAxisSize: MainAxisSize.min, children: [
                  _SoloStrip(item: c, onStart: () => state.startSolo(c.id), onTakeOver: () => state.takeOver(c.id)),
                  const AskBar(),
                  const TaskBar(),
                  const Composer(perChatDrafts: true),
                ]),""")
sub('lib/screens/case_screen.dart',
    """              const SizedBox(height: Lux.turnGap * 2),
            ],
          ),
        ),
      ),
    );
  }
}""",
    """              const SizedBox(height: Lux.turnGap * 2),
            ],
          ),
        ),
      ),
    );
  }
}

/// A quiet line above the composer while a case is Solo or a run is going: what the detective is doing now, and the
/// way to take the case back (docs/investigation.md §9, §20). Hidden in Partner mode when nothing is running.
class _SoloStrip extends StatelessWidget {
  const _SoloStrip({required this.item, required this.onStart, required this.onTakeOver});
  final Case item;
  final VoidCallback onStart;
  final VoidCallback onTakeOver;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final state = context.watch<AppState>();
    AgentRun? run;
    for (final r in state.runs) {
      if (r.convId == item.convId && !r.side) {
        run = r;
        break;
      }
    }
    final solo = item.mode == CaseMode.solo;
    if (!solo && run == null) return const SizedBox.shrink();
    final line = run != null ? run.statusText : tr('Solo — ready when you are');
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(Lux.gutter, 0, Lux.gutter, Space.x1),
      child: Row(children: [
        Expanded(
          child: Text(line, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.microStyle.copyWith(color: p.muted)),
        ),
        TextButton(
          style: TextButton.styleFrom(minimumSize: const Size(0, 30), padding: const EdgeInsets.symmetric(horizontal: Space.x2)),
          onPressed: run != null ? onTakeOver : onStart,
          child: Text(run != null ? tr('Take over') : tr('Work it'),
              style: AppText.microStyle.copyWith(color: p.text, fontWeight: FontWeight.w600)),
        ),
      ]),
    );
  }
}""")

# system_phone.dart: an Investigation milestone opens the case room
sub('lib/state/system_phone.dart',
    """    if (payload.startsWith('botring/')) {
      final b = Bots.I.byId(payload.substring(8));
      if (b != null && _ringing == b.id) incomingCall.value = b;
      return;
    }""",
    """    if (payload.startsWith('botring/')) {
      final b = Bots.I.byId(payload.substring(8));
      if (b != null && _ringing == b.id) incomingCall.value = b;
      return;
    }
    // An Investigation milestone opens the case room (docs/investigation.md §20).
    if (payload.startsWith('case/')) {
      openRequest.value = null;
      openRequest.value = payload;
      return;
    }""")

# home_screen.dart: route 'case/<id>' to the case room
sub('lib/screens/home_screen.dart',
    "import 'inbox_screen.dart';\nimport 'live_screen.dart';",
    "import 'case_screen.dart' show CaseScreen;\nimport 'inbox_screen.dart';\nimport 'live_screen.dart';")
sub('lib/screens/home_screen.dart',
    """    } else if (r.startsWith('botchat/')) {
      // CB-16: a bot's notification opens the Bots workspace on that bot (what you see is where you type).
      final b = Bots.I.byId(r.substring(8));
      if (b != null) unawaited(openBotChat(context, b));
    }
  }""",
    """    } else if (r.startsWith('botchat/')) {
      // CB-16: a bot's notification opens the Bots workspace on that bot (what you see is where you type).
      final b = Bots.I.byId(r.substring(8));
      if (b != null) unawaited(openBotChat(context, b));
    } else if (r.startsWith('case/')) {
      // An Investigation milestone opens the case room (docs/investigation.md §20).
      final id = r.substring(5);
      if (Cases.I.byId(id) != null) {
        Navigator.push(context, MaterialPageRoute(builder: (_) => CaseScreen(caseId: id)));
      }
    }
  }""")

print('phase 5 applied')
