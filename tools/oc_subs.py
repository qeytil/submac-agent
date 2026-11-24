import io


def sub(path, old, new):
    s = io.open(path, encoding='utf-8').read()
    n = s.count(old)
    assert n == 1, "expected 1 match in %s, got %d for %r" % (path, n, old[:70])
    io.open(path, 'w', encoding='utf-8').write(s.replace(old, new))


OC = 'lib/services/opencode.dart'
AR = 'lib/state/agent_runner.dart'

# opencode runs its own subagents (the task tool) in child sessions. Their events carry the child sessionID and were
# dropped, so a subagent's work was invisible in the chat (owner 2026-11-24). A turn now folds in the sessions it
# started, marks their parts, and keeps the subagent's words out of the reply (the parent task step carries its answer).
sub(OC,
    "  /// Parts in the order they first appeared: id -> part.\n  final parts = <String, OcPart>{};\n  bool done = false;",
    "  /// Parts in the order they first appeared: id -> part.\n  final parts = <String, OcPart>{};\n\n"
    "  /// Child sessions this turn started (opencode's own subagents, the `task` tool): their tool steps are folded\n"
    "  /// in too, so a subagent's work is not hidden (owner 2026-11-24). id -> the subagent's name.\n"
    "  final children = <String, String>{};\n\n"
    "  /// True for this turn's own session and for any subagent session it started.\n"
    "  bool _mine(Object? sid) => sid == session || children.containsKey('$sid');\n\n"
    "  /// The name of the subagent a part came from, or '' for the turn's own parts.\n"
    "  String childName(OcPart p) => p.child == null ? '' : (children[p.child!] ?? 'subagent');\n\n"
    "  bool done = false;")

sub(OC,
    "    _glueTo = last != null && last.kind == 'text' ? last.id : null;",
    "    _glueTo = last != null && last.kind == 'text' && last.child == null ? last.id : null;")

sub(OC,
    "    bool head(OcPart p) => p.kind == 'text' && p.continues == null && textOf(p).isNotEmpty;",
    "    bool head(OcPart p) => p.kind == 'text' && p.child == null && p.continues == null && textOf(p).isNotEmpty;")

sub(OC,
    "    switch (j['type']) {\n      case 'message.updated':",
    "    switch (j['type']) {\n"
    "      case 'session.created':\n"
    "      case 'session.updated':\n"
    "        // A subagent's own session: remember it (and its name) so its steps fold into this turn.\n"
    "        final sinfo = props['info'];\n"
    "        if (sinfo is Map && sinfo['id'] != null) {\n"
    "          final sid = '${sinfo['id']}';\n"
    "          final pid = '${sinfo['parentID'] ?? ''}';\n"
    "          if (sid != session && (pid == session || children.containsKey(pid))) {\n"
    "            final name = '${sinfo['title'] ?? ''}'.trim();\n"
    "            if (!children.containsKey(sid) || (name.isNotEmpty && children[sid] != name)) {\n"
    "              children[sid] = name.isEmpty ? 'subagent' : name;\n"
    "              return true;\n"
    "            }\n"
    "          }\n"
    "        }\n"
    "        return false;\n"
    "      case 'message.updated':")

sub(OC,
    "        final info = props['info'];\n"
    "        if (info is Map && info['sessionID'] == session) {\n"
    "          if (info['role'] == 'user') _userMsgs.add('${info['id']}');\n"
    "          if (info['role'] == 'assistant') {",
    "        final info = props['info'];\n"
    "        if (info is Map && _mine(info['sessionID'])) {\n"
    "          if (info['role'] == 'user') _userMsgs.add('${info['id']}');\n"
    "          // A subagent's messages only mark their own user prompts; the finish and tokens counted are this turn's.\n"
    "          if (info['sessionID'] != session) return false;\n"
    "          if (info['role'] == 'assistant') {")

sub(OC,
    "        final p = props['part'];\n"
    "        if (p is! Map || p['sessionID'] != session) return false;\n"
    "        final id = '${p['id']}';\n"
    "        final type = '${p['type']}';",
    "        final p = props['part'];\n"
    "        if (p is! Map || !_mine(p['sessionID'])) return false;\n"
    "        final id = '${p['id']}';\n"
    "        final type = '${p['type']}';\n"
    "        final child = p['sessionID'] == session ? null : '${p['sessionID']}';")

sub(OC,
    "          final part = parts[id] ??= OcPart(id, 'reasoning');",
    "          final part = parts[id] ??= (OcPart(id, 'reasoning')..child = child);")

sub(OC,
    "          final part = parts[id] ??= _newText(id);",
    "          final part = parts[id] ??= (child == null ? _newText(id) : (OcPart(id, 'text')..child = child));")

sub(OC,
    "          final part = parts[id] ??= OcPart(id, 'tool');",
    "          final part = parts[id] ??= (OcPart(id, 'tool')..child = child);")

sub(OC,
    "      case 'message.part.delta':\n"
    "        if (props['sessionID'] != session || props['field'] != 'text' || _userMsgs.contains('${props['messageID']}')) return false;\n"
    "        final id = '${props['partID']}';\n"
    "        final part = parts[id] ??= (reasoning ? OcPart(id, 'reasoning') : _newText(id));",
    "      case 'message.part.delta':\n"
    "        if (!_mine(props['sessionID']) || props['field'] != 'text' || _userMsgs.contains('${props['messageID']}')) return false;\n"
    "        final id = '${props['partID']}';\n"
    "        final child = props['sessionID'] == session ? null : '${props['sessionID']}';\n"
    "        final part = parts[id] ??= (child != null\n"
    "            ? (OcPart(id, 'text')..child = child)\n"
    "            : (reasoning ? OcPart(id, 'reasoning') : _newText(id)));")

sub(OC,
    "  String status = '';\n  String? title;\n  Map<String, dynamic> input = const {};\n  String? output;",
    "  String status = '';\n  String? title;\n  Map<String, dynamic> input = const {};\n  String? output;\n\n"
    "  /// The subagent session this part came from (null for the turn's own parts).\n  String? child;")

# agent_runner: draw the folded-in subagent steps (skip its prose) and name it in the trail and the live line.
sub(AR,
    "        for (final p in turn.parts.values) {\n          if (p.kind == 'text' || p.kind == 'reasoning') {",
    "        for (final p in turn.parts.values) {\n"
    "          // A subagent's words are not the reply: only its steps fold in (the parent `task` step carries its answer).\n"
    "          if (p.child != null && p.kind != 'tool') continue;\n"
    "          if (p.kind == 'text' || p.kind == 'reasoning') {")

sub(AR,
    "              run.trail.add(RunStep(p.title ?? stepLabel(tool, input)));",
    "              final who = turn.childName(p);\n"
    "              final what = p.title ?? stepLabel(tool, input);\n"
    "              run.trail.add(RunStep(who.isEmpty ? what : '$who: $what'));")

sub(AR,
    "        // The live line: what opencode is doing now.\n"
    "        final last = turn.parts.values.isEmpty ? null : turn.parts.values.last;\n"
    "        if (turn.retry != null && turn.retry!.isNotEmpty) {\n"
    "          run.show(RunPhase.retrying, turn.retry!);\n"
    "        } else if (last != null && last.kind == 'tool' && !last.finished) {\n"
    "          run.show(RunPhase.tool, last.title ?? stepLabel(last.tool.replaceFirst('telesia_', ''), last.input));",
    "        // The live line: what opencode is doing now (a subagent's step counts as doing).\n"
    "        OcPart? last;\n"
    "        for (final p in turn.parts.values) {\n"
    "          if (p.child == null || p.kind == 'tool') last = p;\n"
    "        }\n"
    "        if (turn.retry != null && turn.retry!.isNotEmpty) {\n"
    "          run.show(RunPhase.retrying, turn.retry!);\n"
    "        } else if (last != null && last.kind == 'tool' && !last.finished) {\n"
    "          final who = turn.childName(last);\n"
    "          final what = last.title ?? stepLabel(last.tool.replaceFirst('telesia_', ''), last.input);\n"
    "          run.show(RunPhase.tool, who.isEmpty ? what : '$who: $what');")

print('subagents: child sessions folded in; steps shown, words kept out')
