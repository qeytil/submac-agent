#!/usr/bin/env python3
"""opencode can assign a task to a bot: register the assign_bot tool, wire it, and report the bot's result back in the
assigning chat. New files are committed separately; this script only edits existing files."""
import io


def sub(path, old, new):
    with io.open(path, encoding='utf-8') as f:
        s = f.read()
    n = s.count(old)
    assert n == 1, path + ' :: expected 1, found ' + str(n) + ' :: ' + repr(old[:60])
    with io.open(path, 'w', encoding='utf-8') as f:
        f.write(s.replace(old, new))


sub('lib/app_state.dart',
    "import 'services/digital_human/bot_minds.dart';",
    "import 'services/digital_human/bot_minds.dart';\nimport 'services/bot_assign.dart';")

sub('lib/state/agent_runner.dart',
    "        ...DocMaker.definitions,\n        ...CaseTools.definitions,\n        ...MediaCoder.definitions,",
    "        ...DocMaker.definitions,\n        ...CaseTools.definitions,\n        ...BotAssign.definitions,\n        ...MediaCoder.definitions,")

sub('lib/state/agent_runner.dart',
    "    final scheduled = _scheduledConvs.remove(convId);\n"
    "    final fromNote = _notifReplyConvs.remove(convId);\n"
    "    _notifyConvs.remove(convId);",
    "    final scheduled = _scheduledConvs.remove(convId);\n"
    "    final fromNote = _notifReplyConvs.remove(convId);\n"
    "    _notifyConvs.remove(convId);\n"
    "    // A task the agent handed to a bot reports back in the chat that asked (BotAssign): \"<Bot> finished: ...\".\n"
    "    final assignedBotId = Bots.I.byConv(convId)?.id;\n"
    "    final assigned = assignedBotId == null ? null : BotAssign.back.remove(assignedBotId);\n"
    "    if (assigned != null && !run.cancelled) {\n"
    "      final botReply = OcRunEnd.replyOf(list, run.wrote).trim();\n"
    "      unawaited(_sayIn(assigned.owner, '${assigned.name} finished: ${botReply.isEmpty ? 'done.' : botReply}'));\n"
    "    }")

sub('lib/state/tool_catalog.dart',
    "        ...CaseTools.definitions,\n        // Core loop v3: the agent's own tools (tool_make) and the door to make more.",
    "        ...CaseTools.definitions,\n        ...BotAssign.definitions,\n        // Core loop v3: the agent's own tools (tool_make) and the door to make more.")

sub('lib/state/tool_router.dart',
    "    if (CaseTools.names.contains(name)) return CaseTools.execute(name, args, convId);",
    "    if (CaseTools.names.contains(name)) return CaseTools.execute(name, args, convId);\n"
    "    if (BotAssign.names.contains(name)) return _assignBot(args, convId);")

sub('lib/state/tool_router.dart',
    "  Future<ActionRequest?> _riskFor(String name, Map<String, dynamic> args) async {",
    "  /// assign_bot: hand a task to one of the owner's bots and show it in this chat (like spinning off a teammate).\n"
    "  /// The bot works it in its own chat; when its turn ends, _ocRunEnded reports the result back here.\n"
    "  Future<String> _assignBot(Map<String, dynamic> a, String? convId) async {\n"
    "    final who = '${a['bot'] ?? ''}'.trim();\n"
    "    final task = '${a['task'] ?? ''}'.trim();\n"
    "    if (who.isEmpty || task.isEmpty) return 'Error: give both \"bot\" (the name) and \"task\".';\n"
    "    final b = Bots.I.byName(who) ?? Bots.I.byId(who);\n"
    "    if (b == null) {\n"
    "      final names = Bots.I.bots.map((x) => x.name).where((n) => n.trim().isNotEmpty).join(', ');\n"
    "      return names.isEmpty ? 'The owner has no bots yet.' : 'No bot named \"$who\". Their bots: $names.';\n"
    "    }\n"
    "    if (!b.active) return '${b.name} is not active yet; ask the owner to start it, or do the task yourself.';\n"
    "    final owner = convId ?? currentId ?? '';\n"
    "    if (owner.isNotEmpty) {\n"
    "      BotAssign.back[b.id] = (owner: owner, name: b.name);\n"
    "      unawaited(_sayIn(owner, 'Assigned to ${b.name}: $task'));\n"
    "    }\n"
    "    await _botWake(b, 'a task from the owner through the agent', task, 'work');\n"
    "    return 'Assigned to ${b.name}. It works the task in its own chat and reports back here when done. Do not do the task '\n"
    "        'yourself; tell the owner it is in ${b.name}\\'s hands.';\n"
    "  }\n\n"
    "  Future<ActionRequest?> _riskFor(String name, Map<String, dynamic> args) async {")

print('assign_bot wired')