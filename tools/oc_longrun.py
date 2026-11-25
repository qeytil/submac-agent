import io


def sub(path, old, new):
    s = io.open(path, encoding='utf-8').read()
    n = s.count(old)
    assert n == 1, "expected 1 match in %s, got %d for %r" % (path, n, old[:70])
    io.open(path, 'w', encoding='utf-8').write(s.replace(old, new))


CFG = 'lib/bot_agent/bot_agent_config.dart'
ENG = 'lib/bot_agent/bot_agent_engine.dart'
AR = 'lib/state/agent_runner.dart'

# 1) A bot's own turn had a 24-step ceiling: a real build never fits in 24 steps, so it stopped mid-task. 40, the
#    same default a team part gets, and the checkpoint below hands the work over cleanly instead of being cut.
sub(CFG, "    this.maxSteps = 24,", "    this.maxSteps = 40,")

# 2) Near the cap the model books its own handoff (what is done, what is left, the exact next step) instead of being
#    cut off in the middle of a file or a plan.
sub(ENG,
    "    var stopped = '';\n    var nudged = false;",
    "    var stopped = '';\n    var nudged = false;\n    var checkpointed = false;")

sub(ENG,
    "      if (stop?.call() ?? false) {\n        stopped = 'stopped';\n        break;\n      }\n      final r = await step(messages, tools);",
    "      if (stop?.call() ?? false) {\n        stopped = 'stopped';\n        break;\n      }\n"
    "      // A long task would otherwise be cut at the step cap mid-flight (the bot just stops). Close to the cap the\n"
    "      // model is told to book its handoff: what is done, what is left, the exact next step, so the next run\n"
    "      // continues from there instead of starting blind (owner 2026-11-25: long-horizon tasks stopped).\n"
    "      if (!checkpointed && i >= config.maxSteps - 4) {\n"
    "        checkpointed = true;\n"
    "        messages.add({\n"
    "          'role': 'user',\n"
    "          'content': 'You are close to the step limit for this run. If the task is not finished: write a short '\n"
    "              'progress note (what is done, what is left) and the exact next step, then end this run cleanly. Do '\n"
    "              'not start anything new that you cannot finish in the few steps you have left.',\n"
    "        });\n"
    "      }\n"
    "      final r = await step(messages, tools);")

# 3) The step cap used to be ignored by the app: the turn just ended, silently, and the long task stopped. Now the
#    run books its own continuation: a mission wakes again in minutes, a plain chat task gets a follow-up wake.
sub(AR,
    "    final result = await engine.run(system: system, history: history, tools: tools);\n"
    "    if (result.stopped == 'stopped') {\n"
    "      final note = ChatMessage(\n"
    "        id: _uuid.v4(),\n"
    "        role: 'assistant',\n"
    "        error: \"Today's allowance for me is used up, so I'll pick this up again tomorrow.\",\n"
    "      )..animateIn = true;\n"
    "      list.add(note);\n"
    "      run.wrote.add(note.id);\n"
    "      await _save(convId, note);\n"
    "    }\n"
    "  }",
    "    final result = await engine.run(system: system, history: history, tools: tools);\n"
    "    if (result.stopped == 'steps' || result.stopped == 'continues') {\n"
    "      // It hit the step cap (or kept being cut): it used to end right there, silently, and the long task just\n"
    "      // stopped. Now the task books its own handoff: the next run picks up where this one left off.\n"
    "      await _continueTask(convId, b, run, list, result.stopped);\n"
    "    } else if (result.stopped == 'stopped') {\n"
    "      final note = ChatMessage(\n"
    "        id: _uuid.v4(),\n"
    "        role: 'assistant',\n"
    "        error: \"Today's allowance for me is used up, so I'll pick this up again tomorrow.\",\n"
    "      )..animateIn = true;\n"
    "      list.add(note);\n"
    "      run.wrote.add(note.id);\n"
    "      await _save(convId, note);\n"
    "    } else {\n"
    "      // Finished on its own: the next task starts its own continuation count.\n"
    "      _contRuns.remove(convId);\n"
    "    }\n"
    "  }")

# 4) The continuation counter (bounded, so a task that never finishes stops waking).
sub(AR,
    "  /// The lead of a team job hands parts to members with team_assign: its handler, by the lead's route key.\n"
    "  static final Map<String, Future<String> Function(String member, String ask)> _teamAssign = {};",
    "  /// The lead of a team job hands parts to members with team_assign: its handler, by the lead's route key.\n"
    "  static final Map<String, Future<String> Function(String member, String ask)> _teamAssign = {};\n\n"
    "  /// Continuations of a chat whose run hit its step limit, by conversation: bounded, so a task that never\n"
    "  /// finishes stops continuing instead of waking for ever.\n"
    "  static final Map<String, int> _contRuns = {};")

# 5) What a run does when it stops at the cap.
sub(AR,
    "  /// The conversation as model messages (OpenAI shape) for a bot turn:",
    "  /// A run stopped at its step limit (or kept being cut): say so in the chat and arrange the next run, so a long\n"
    "  /// task continues instead of stopping mid-flight. A mission continues by itself within minutes (its plan and\n"
    "  /// log are on disk); a plain chat task gets one follow-up wake, a few at most per task.\n"
    "  Future<void> _continueTask(String convId, Bot b, AgentRun run, List<ChatMessage> list, String why) async {\n"
    "    final m = Missions.I.liveOf('bot', b.id);\n"
    "    if (m != null && m.on && !m.finished) {\n"
    "      m.add('schedule', 'This run hit the step limit; continuing shortly from where it stopped.', who: b.name);\n"
    "      await Missions.I.setNext(m, DateTime.now().add(const Duration(minutes: 2)), 'continuing after the step limit', by: 'app');\n"
    "      await Missions.I.save(m);\n"
    "      return;\n"
    "    }\n"
    "    final note = ChatMessage(\n"
    "      id: _uuid.v4(),\n"
    "      role: 'assistant',\n"
    "      error: why == 'continues'\n"
    "          ? 'My reply hit its length limit. I will go on from where it stopped.'\n"
    "          : 'I hit the step limit for this run. I will pick this task up where I left off.',\n"
    "    )..animateIn = true;\n"
    "    list.add(note);\n"
    "    run.wrote.add(note.id);\n"
    "    await _save(convId, note);\n"
    "    _notify();\n"
    "    final n = (_contRuns[convId] ?? 0) + 1;\n"
    "    _contRuns[convId] = n;\n"
    "    if (n > 3) return;\n"
    "    const next = 'Continue the task you were working on in this chat: read your own last messages, then go on from "
    "the exact point you stopped. Do not restart it from the beginning.';\n"
    "    if (Bots.hasPendingFollowup(b, next, 'work')) return;\n"
    "    b.followups.add(BotFollowup('f${DateTime.now().millisecondsSinceEpoch % 1000000}',\n"
    "        DateTime.now().add(const Duration(minutes: 3)), next, 'work', local: true));\n"
    "    await Bots.I.save();\n"
    "    await Bots.I.arm(b);\n"
    "  }\n\n"
    "  /// The conversation as model messages (OpenAI shape) for a bot turn:")

# 6) A team part died at a 30-mintte wall clock before its step cap ever mattered (a build alone takes longer).
sub(AR,
    "    final until = DateTime.now().add(const Duration(minutes: 30));",
    "    // Long work (a build, a research pass) needs room: an hour, and a mission's own 90-minute window bounds it.\n"
    "    final until = DateTime.now().add(const Duration(minutes: 60));")

sub(AR,
    "        if (timedOut) throw OpenCodeError('${b.name} ran out of time (30 min).');",
    "        if (timedOut) throw OpenCodeError('${b.name} ran out of time (60 min).');")

# A part that hit the step limit says so to the lead and the owner, instead of looking like a finished answer.
sub(AR,
    "        var answer = result.reply;\n        if (lastCut && answer.isNotEmpty) answer = '$answer\\n\\n_(${ReplyContinuation.cutNote})_';",
    "        var answer = result.reply;\n"
    "        if (lastCut && answer.isNotEmpty) answer = '$answer\\n\\n_(${ReplyContinuation.cutNote})_';\n"
    "        if (result.stopped == 'steps' && answer.isNotEmpty) answer = '$answer\\n\\n_(Stopped at this run step limit: the next run continues from here.)_';")

print('long horizon: 40-step bot runs, a handoff checkpoint, automatic continuations, 60-min team parts')
