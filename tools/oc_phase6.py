#!/usr/bin/env python3
"""Investigation phase 6: the job queue + phone/cloud engine. New files are committed separately; this script only
edits existing files."""
import io


def sub(path, old, new):
    with io.open(path, encoding='utf-8') as f:
        s = f.read()
    n = s.count(old)
    assert n == 1, path + ' :: expected 1, found ' + str(n) + ' :: ' + repr(old[:60])
    with io.open(path, 'w', encoding='utf-8') as f:
        f.write(s.replace(old, new))


# cases.dart: the engine + job line in the case prompt
sub('lib/services/cases.dart',
    "import 'case_abilities.dart';\nimport 'tools.dart';",
    "import 'case_abilities.dart';\nimport 'case_engine.dart';\nimport 'tools.dart';")
sub('lib/services/cases.dart',
    "    sb.writeln('Case folder: $dir. Save exhibits and reports there. Public sources only; rate every finding and give sources.');",
    "    sb.writeln(CaseEngine.note());\n"
    "    sb.writeln('Long jobs: record them with case_job (add, then update to running/done/failed) so they survive restarts.');\n"
    "    sb.writeln('Case folder: $dir. Save exhibits and reports there. Public sources only; rate every finding and give sources.');")

# app_state.dart: import the engine, queue and tool (parts share these imports)
sub('lib/app_state.dart',
    "import 'services/case_ability_defaults.dart';\nimport 'services/case_notify.dart';",
    "import 'services/case_ability_defaults.dart';\nimport 'services/case_notify.dart';\n"
    "import 'services/case_engine.dart';\nimport 'services/case_jobs.dart';\nimport 'services/case_tools.dart';")

# system_phone.dart: initialise the queue and engine
sub('lib/state/system_phone.dart',
    "    try {\n      await CaseAbilityDefaults.I.init();\n    } catch (_) {}\n",
    "    try {\n      await CaseAbilityDefaults.I.init();\n    } catch (_) {}\n"
    "    try {\n      await CaseJobs.I.init();\n      await CaseEngine.init();\n    } catch (_) {}\n")

# tool_catalog.dart + agent_runner.dart: offer the case_job tool
sub('lib/state/tool_catalog.dart',
    "        ...CodeTools.definitions,\n        // Core loop v3: the agent's own tools (tool_make) and the door to make more.",
    "        ...CodeTools.definitions,\n        ...CaseTools.definitions,\n        // Core loop v3: the agent's own tools (tool_make) and the door to make more.")
sub('lib/state/agent_runner.dart',
    "        ...DocMaker.definitions,\n        ...MediaCoder.definitions,",
    "        ...DocMaker.definitions,\n        ...CaseTools.definitions,\n        ...MediaCoder.definitions,")

# tool_router.dart: run case_job
sub('lib/state/tool_router.dart',
    "    if (AppState.liveTaskToolNames.contains(name)) return _liveTaskTool(name, args);",
    "    if (AppState.liveTaskToolNames.contains(name)) return _liveTaskTool(name, args);\n"
    "    if (CaseTools.names.contains(name)) return CaseTools.execute(name, args, convId);")

# case_file_screen.dart: the Work section (engine line + the job queue)
sub('lib/screens/case_file_screen.dart',
    "import '../services/case_report.dart';\nimport '../services/cases.dart';",
    "import '../services/case_report.dart';\nimport '../services/cases.dart';\nimport '../services/case_engine.dart';\nimport '../services/case_jobs.dart';")
sub('lib/screens/case_file_screen.dart',
    "        animation: Cases.I,",
    "        animation: Listenable.merge([Cases.I, CaseJobs.I]),")
sub('lib/screens/case_file_screen.dart',
    "              _findings(c),\n              _report(c),",
    "              _findings(c),\n              _work(c),\n              _report(c),")
sub('lib/screens/case_file_screen.dart',
    "  Widget _report(Case c) {",
    """  Widget _work(Case c) {
    final p = Palette.of(context);
    final jobs = CaseJobs.I.of(c.id);
    return _Section(title: tr('Work'), children: [
      Text(CaseEngine.note(), style: AppText.microStyle.copyWith(color: p.muted)),
      if (jobs.isEmpty) Text(tr('No jobs yet.'), style: AppText.bodyStyle.copyWith(color: p.muted)),
      for (final j in jobs)
        _Line(
          title: j.title,
          subtitle: '${j.status} · ${CaseEngine.word(j.lane)}${j.output.isNotEmpty ? ' · ${j.output}' : ''}',
        ),
      _action(tr('Clear finished'), () => CaseJobs.I.clearFinished(c.id)),
    ]);
  }

  Widget _report(Case c) {""")

print('phase 6 applied')