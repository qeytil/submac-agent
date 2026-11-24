#!/usr/bin/env python3
"""Investigation phase 1: apply the edits that wire the Cases section into the app.
New files are committed separately; this script only edits existing files."""
import io


def sub(path, old, new):
    with io.open(path, encoding='utf-8') as f:
        s = f.read()
    n = s.count(old)
    assert n == 1, path + ' :: expected 1, found ' + str(n) + ' :: ' + repr(old[:60])
    with io.open(path, 'w', encoding='utf-8') as f:
        f.write(s.replace(old, new))


# app_state.dart: import the service and add the controller part
sub('lib/app_state.dart',
    "import 'services/offices.dart';\nimport 'services/missions.dart';",
    "import 'services/offices.dart';\nimport 'services/cases.dart';\nimport 'services/missions.dart';")
sub('lib/app_state.dart',
    "part 'state/bots_controller.dart';\npart 'state/missions_controller.dart';",
    "part 'state/bots_controller.dart';\npart 'state/cases_controller.dart';\npart 'state/missions_controller.dart';")

# agent_runner.dart: inject the case context into the opencode system layer
sub('lib/state/agent_runner.dart',
    "        final layer = TelesiaStyle.identity;",
    r"""        final layer = [TelesiaStyle.identity, Cases.I.promptFor(convId)].where((s) => s.trim().isNotEmpty).join('\n\n');""")

# system_phone.dart: initialise the service
sub('lib/state/system_phone.dart',
    "    try {\n      await Projects.I.init();\n    } catch (_) {}\n",
    "    try {\n      await Projects.I.init();\n    } catch (_) {}\n    try {\n      await Cases.I.init();\n    } catch (_) {}\n")

# skill_library.dart: list CaseSkills built-ins and load their asset bodies
sub('lib/services/skill_library.dart',
    "import 'package:flutter/foundation.dart';\nimport 'package:http/http.dart' as http;",
    "import 'package:flutter/foundation.dart';\nimport 'package:flutter/services.dart' show rootBundle;\nimport 'package:http/http.dart' as http;")
sub('lib/services/skill_library.dart',
    "import 'apk_build.dart';\nimport 'design_skills.dart';",
    "import 'apk_build.dart';\nimport 'case_skills.dart';\nimport 'design_skills.dart';")
sub('lib/services/skill_library.dart',
    "[...ApkBuild.skills, ...DesignSkills.skills]",
    "[...ApkBuild.skills, ...DesignSkills.skills, ...CaseSkills.skills]")
sub('lib/services/skill_library.dart',
    "    'somalia': 'Somalia',\n    'mine': 'Your own skills',",
    "    'somalia': 'Somalia',\n    'investigation': 'Investigation',\n    'mine': 'Your own skills',")
sub('lib/services/skill_library.dart',
    "    final own = builtInBody(id);\n    if (own != null) return own;\n    final f = _file(id);",
    "    final own = builtInBody(id);\n    if (own != null) return own;\n    final asset = CaseSkills.assetOf(id);\n    if (asset != null) {\n      try {\n        final text = await rootBundle.loadString(asset);\n        if (text.trim().isNotEmpty) return text;\n      } catch (_) {}\n    }\n    final f = _file(id);")

# sidebar.dart: imports
sub('lib/widgets/sidebar.dart',
    "import '../services/bots.dart';\nimport '../services/offices.dart';\nimport '../services/inbox.dart';\nimport '../screens/inbox_screen.dart';\nimport 'chat/entrance.dart';",
    "import '../services/bots.dart';\nimport '../services/offices.dart';\nimport '../services/cases.dart';\nimport '../services/inbox.dart';\nimport '../screens/inbox_screen.dart';\nimport '../screens/caseboard_screen.dart';\nimport 'chat/entrance.dart';")

# sidebar.dart: search excludes case chats
sub('lib/widgets/sidebar.dart',
    "!c.packedAway && !botChats.contains(c.id)).toList()",
    "!c.packedAway && !botChats.contains(c.id) && !state.caseConvIds.contains(c.id)).toList()")

# sidebar.dart: rebuild key
sub('lib/widgets/sidebar.dart',
    "        s.botConvIds.length,\n        for (final c in s.conversations) Object.hash(c.id, c.title, c.pinned, c.archived, c.packedAway, c.updatedAt),",
    "        s.botConvIds.length,\n        s.caseConvIds.length,\n        Cases.I.list.length,\n        for (final c in s.conversations) Object.hash(c.id, c.title, c.pinned, c.archived, c.packedAway, c.updatedAt),")

# sidebar.dart: chat list excludes case chats
sub('lib/widgets/sidebar.dart',
    "    final botChats = state.botConvIds;\n    final visible = state.conversations\n        .where((c) => !c.archived && !botChats.contains(c.id) && (q.isEmpty",
    "    final botChats = state.botConvIds;\n    final caseChats = state.caseConvIds;\n    final visible = state.conversations\n        .where((c) => !c.archived && !botChats.contains(c.id) && !caseChats.contains(c.id) && (q.isEmpty")

# sidebar.dart: the Investigation nav tile
sub('lib/widgets/sidebar.dart',
    "            _NavTile(\n              title: 'Apps',",
    "            _NavTile(\n              title: 'Investigation',\n              onTap: () {\n                Navigator.pop(context);\n                Navigator.push(context, MaterialPageRoute(builder: (_) => const CaseboardScreen()));\n              },\n            ),\n            _NavTile(\n              title: 'Apps',")

# sidebar.dart: the Cases drawer section
sub('lib/widgets/sidebar.dart',
    "                          AnimatedBuilder(\n                            animation: Listenable.merge([Bots.I, Offices.I]),\n                            builder: (context, _) => DrawerBots(\n                              query: q,\n                              selectedConv: state.currentId,\n                              onOpen: () => Navigator.pop(context),\n                            ),\n                          ),",
    "                          AnimatedBuilder(\n                            animation: Listenable.merge([Bots.I, Offices.I]),\n                            builder: (context, _) => DrawerBots(\n                              query: q,\n                              selectedConv: state.currentId,\n                              onOpen: () => Navigator.pop(context),\n                            ),\n                          ),\n                          AnimatedBuilder(\n                            animation: Cases.I,\n                            builder: (context, _) => q.isNotEmpty || Cases.I.list.isEmpty\n                                ? const SizedBox.shrink()\n                                : DrawerSection(\n                                    id: 'drawer-cases',\n                                    title: 'Cases',\n                                    count: Cases.I.openCount,\n                                    children: [\n                                      for (final c in Cases.I.list.take(8)) _CaseTile(item: c, selected: state.currentId == c.convId),\n                                    ],\n                                  ),\n                          ),")

# sidebar.dart: the case row widget
sub('lib/widgets/sidebar.dart',
    "class _NavTile extends StatelessWidget {\n  final String title;",
    "class _CaseTile extends StatelessWidget {\n  final Case item;\n  final bool selected;\n  const _CaseTile({required this.item, required this.selected});\n\n  @override\n  Widget build(BuildContext context) {\n    final p = Palette.of(context);\n    final state = context.read<AppState>();\n    return Material(\n      color: selected ? p.bubble : Colors.transparent,\n      borderRadius: Radii.fieldAll,\n      child: InkWell(\n        borderRadius: Radii.fieldAll,\n        onTap: () {\n          state.openCase(item.id);\n          Navigator.pop(context);\n        },\n        child: Padding(\n          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),\n          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [\n            Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.bodyStyle.copyWith(color: p.text)),\n            const SizedBox(height: 2),\n            Text('${item.numberLabel} \u00b7 ${item.statusWord}',\n                maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.captionStyle.copyWith(color: p.muted)),\n          ]),\n        ),\n      ),\n    );\n  }\n}\n\nclass _NavTile extends StatelessWidget {\n  final String title;")

print('investigation edits applied')
