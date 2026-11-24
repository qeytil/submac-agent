#!/usr/bin/env python3
"""Steer & queue: a message sent while opencode works is delivered to the running turn (opencode queues it), the
follow-up chain is uncapped, steered messages are never answered twice, and the chat shows a quiet "Queued" cue."""
import io


def sub(path, old, new):
    with io.open(path, encoding='utf-8') as f:
        s = f.read()
    n = s.count(old)
    assert n == 1, path + ' :: expected 1, found ' + str(n) + ' :: ' + repr(old[:70])
    with io.open(path, 'w', encoding='utf-8') as f:
        f.write(s.replace(old, new))


# AgentRun: remember which user messages were steered into the running turn, so the chain never answers them twice.
sub('lib/app_state.dart',
    "  final List<String> inbox = [];\n"
    "  /// True while waiting on the model (false while a tool runs).\n"
    "  bool inModel = false;",
    "  final List<String> inbox = [];\n"
    "  /// Ids of user messages already steered into the running turn (the follow-up chain skips them).\n"
    "  final Set<String> steered = {};\n"
    "  /// True while waiting on the model (false while a tool runs).\n"
    "  bool inModel = false;")

# opencode loop: forward the owner's mid-turn message to the running turn (opencode queues it), and keep waiting.
sub('lib/state/agent_runner.dart',
    "              if (await oc.recover(turn, since: began)) {\n"
    "                sync();\n"
    "                if (!done.isCompleted) done.complete();\n"
    "              }\n"
    "            }\n"
    "          }",
    "              if (await oc.recover(turn, since: began)) {\n"
    "                sync();\n"
    "                if (!done.isCompleted) done.complete();\n"
    "              }\n"
    "            }\n"
    "            // A message the owner sends while this turn works steers it: opencode queues it and the reply\n"
    "            // carries on with it (owner 2026-11). Without this it only ran as a whole separate turn afterwards.\n"
    "            if (run.inbox.isNotEmpty) {\n"
    "              final queued = List<String>.of(run.inbox);\n"
    "              run.inbox.clear();\n"
    "              var sentQ = false;\n"
    "              for (final q in queued) {\n"
    "                if (q.trim().isEmpty) continue;\n"
    "                await oc.prompt(session, [{'type': 'text', 'text': q}], system: layer, model: laneModel);\n"
    "                sentQ = true;\n"
    "              }\n"
    "              if (sentQ) {\n"
    "                done = Completer<void>();\n"
    "                seen = DateTime.now();\n"
    "              }\n"
    "            }\n"
    "          }")

# The follow-up chain: uncap it and skip messages already steered into the running turn.
sub('lib/state/agent_runner.dart',
    "    if (!run.cancelled && sentId != null && chain < 3) {\n"
    "      final newest = list.lastWhere((m) => m.role == 'user', orElse: () => list.first);\n"
    "      if (newest.role == 'user' && newest.id != sentId) unawaited(_runAgent(convId, chain: chain + 1));\n"
    "    }",
    "    if (!run.cancelled && sentId != null && chain < 12) {\n"
    "      final newest = list.lastWhere((m) => m.role == 'user', orElse: () => list.first);\n"
    "      if (newest.role == 'user' && newest.id != sentId && !run.steered.contains(newest.id)) {\n"
    "        unawaited(_runAgent(convId, chain: chain + 1));\n"
    "      }\n"
    "    }")

# A message sent to a working task is remembered as steered (so the chain skips it).
sub('lib/state/chat_controller.dart',
    "    if (task != null && !task.cancelled && runs.contains(task)) {\n"
    "      task.inbox.add(text.trim().isEmpty ? '(sent an attachment)' : content);",
    "    if (task != null && !task.cancelled && runs.contains(task)) {\n"
    "      task.steered.add(userMsg.id);\n"
    "      task.inbox.add(text.trim().isEmpty ? '(sent an attachment)' : content);")

# Chat UI: a quiet cue while a message the owner just sent waits to be read.
sub('lib/screens/home_screen.dart',
    "                        : assistant(k, inTurn: true),\n"
    "              ),\n"
    "          ],\n"
    "        ),",
    "                        : assistant(k, inTurn: true),\n"
    "              ),\n"
    "            if (live && turn.isNotEmpty && turn.last.role == 'user')\n"
    "              Padding(\n"
    "                padding: const EdgeInsetsDirectional.only(end: Lux.gutter, bottom: Space.x1),\n"
    "                child: Text(tr('Queued · it will read this next'),\n"
    "                    textAlign: TextAlign.end, style: AppText.microStyle.copyWith(color: Palette.of(context).muted)),\n"
    "              ),\n"
    "          ],\n"
    "        ),")

print('steer & queue applied')