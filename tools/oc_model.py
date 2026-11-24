#!/usr/bin/env python3
"""Borrow another model: register ask_model/list_models and install the built-in skill. New files are committed
separately; this script only edits existing files."""
import io


def sub(path, old, new):
    with io.open(path, encoding='utf-8') as f:
        s = f.read()
    n = s.count(old)
    assert n == 1, path + ' :: expected 1, found ' + str(n) + ' :: ' + repr(old[:70])
    with io.open(path, 'w', encoding='utf-8') as f:
        f.write(s.replace(old, new))


# app_state: import the bridge (parts share imports)
sub('lib/app_state.dart',
    "import 'services/bot_assign.dart';",
    "import 'services/bot_assign.dart';\nimport 'services/model_bridge.dart';")

# opencode app tools: offer ask_model / list_models
sub('lib/state/agent_runner.dart',
    "        ...BotAssign.definitions,\n        ...MediaCoder.definitions,",
    "        ...BotAssign.definitions,\n        ...ModelBridge.definitions,\n        ...MediaCoder.definitions,")

# owner's tool catalog: same
sub('lib/state/tool_catalog.dart',
    "        ...BotAssign.definitions,\n        // Core loop v3: the agent's own tools (tool_make) and the door to make more.",
    "        ...BotAssign.definitions,\n        ...ModelBridge.definitions,\n        // Core loop v3: the agent's own tools (tool_make) and the door to make more.")

# tool router: run it
sub('lib/state/tool_router.dart',
    "    if (BotAssign.names.contains(name)) return _assignBot(args, convId);",
    "    if (BotAssign.names.contains(name)) return _assignBot(args, convId);\n"
    "    if (ModelBridge.names.contains(name)) return ModelBridge.execute(name, args);")

# skill library: import, list and read the built-in skill
sub('lib/services/skill_library.dart',
    "import 'case_skills.dart';",
    "import 'case_skills.dart';\nimport 'model_skills.dart';")
sub('lib/services/skill_library.dart',
    "  static final List<LibSkill> builtIn = [for (final m in [...ApkBuild.skills, ...DesignSkills.skills, ...CaseSkills.skills]) LibSkill.fromJson(m)];",
    "  static final List<LibSkill> builtIn = [for (final m in [...ApkBuild.skills, ...DesignSkills.skills, ...CaseSkills.skills, ...ModelSkills.skills]) LibSkill.fromJson(m)];")
sub('lib/services/skill_library.dart',
    "  static String? builtInBody(String id) => ApkBuild.bodyOf(id) ?? DesignSkills.bodyOf(id);",
    "  static String? builtInBody(String id) => ApkBuild.bodyOf(id) ?? DesignSkills.bodyOf(id) ?? ModelSkills.bodyOf(id);")

print('model bridge wired')