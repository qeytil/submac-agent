#!/usr/bin/env python3
"""Browser handover: opencode drives the in-app browser directly (the browser-use subagent is retired from the model's
tools, which also removes its old-usage fleet/step/time budgets), and a duplicate message never shows the same files
twice. New files are committed separately; this script only edits existing files."""
import io


def sub(path, old, new):
    with io.open(path, encoding='utf-8') as f:
        s = f.read()
    n = s.count(old)
    assert n == 1, path + ' :: expected 1, found ' + str(n) + ' :: ' + repr(old[:70])
    with io.open(path, 'w', encoding='utf-8') as f:
        f.write(s.replace(old, new))


# opencode: drive the browser itself (direct page actions), not through the browser-use subagent
sub('lib/state/agent_runner.dart',
    "        if (agentEnabled) ...[\n          ...BrowserJobs.definitions,",
    "        if (agentEnabled) ...[\n          // opencode drives the in-app browser directly (owner 2026-11): it owns browser use.\n          ...BrowserAgent.definitions,")

# the owner's tool catalog: same handover
sub('lib/state/tool_catalog.dart',
    "        if (agentEnabled) ...[\n"
    "          // The browser is driven by its own subagent; the chat agent manages it. Early, so caps never drop it.\n"
    "          ...BrowserJobs.definitions,",
    "        if (agentEnabled) ...[\n"
    "          // opencode drives the in-app browser directly (owner 2026-11): it owns browser use. Early, so caps never drop it.\n"
    "          ...BrowserAgent.definitions,")

# A duplicate of a message that carried files never shows twice (a repeated send showed the photo again).
sub('lib/screens/home_screen.dart',
    "    final visible = all\n"
    "        .where((m) =>\n"
    "            (m.role == 'user' && !m.content.startsWith(botWakeMark)) || m.role == 'assistant' || AppState.isCompactMark(m))\n"
    "        .toList();",
    "    var visible = all\n"
    "        .where((m) =>\n"
    "            (m.role == 'user' && !m.content.startsWith(botWakeMark)) || m.role == 'assistant' || AppState.isCompactMark(m))\n"
    "        .toList();\n"
    "    // Never show the same file message twice (a repeated send used to show the same photo as a second bubble).\n"
    "    {\n"
    "      final seenFiles = <String>{};\n"
    "      visible = visible.where((m) {\n"
    "        if (m.role != 'user' || m.attachments.isEmpty) return true;\n"
    "        final sig = '${m.content}|${m.attachments.map((a) => a.name).join(',')}';\n"
    "        return seenFiles.add(sig);\n"
    "      }).toList();\n"
    "    }")

print('browser handover + dedupe applied')