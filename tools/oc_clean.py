#!/usr/bin/env python3
"""Postponed task, part 2: clear the remaining analyzer warnings/infos so `flutter analyze` is quiet."""
import io


def sub(path, old, new):
    with io.open(path, encoding='utf-8') as f:
        s = f.read()
    n = s.count(old)
    assert n == 1, path + ' :: expected 1, found ' + str(n) + ' :: ' + repr(old[:60])
    with io.open(path, 'w', encoding='utf-8') as f:
        f.write(s.replace(old, new))


# settings: the Plan & usage page is a placeholder for another dev; keep it, silence the unused-element
sub('lib/screens/settings_screen.dart',
    "class _PlanPage extends StatelessWidget {",
    "// ignore: unused_element\nclass _PlanPage extends StatelessWidget {")

# mood: heartbeat is only re-exported, never used here
sub('lib/services/digital_human/mood.dart',
    "import 'package:flutter/foundation.dart';\n\nimport 'heartbeat.dart';\nexport 'heartbeat.dart';",
    "import 'package:flutter/foundation.dart';\n\nexport 'heartbeat.dart';")

# person: Heartbeat is provided by awareness/memory/mood (they re-export it)
sub('lib/services/digital_human/person.dart',
    "import 'package:shared_preferences/shared_preferences.dart';\n\nimport 'heartbeat.dart';\nimport 'awareness.dart';",
    "import 'package:shared_preferences/shared_preferences.dart';\n\nimport 'awareness.dart';")

# model_picker: needless braces in the interpolation
sub('lib/widgets/model_picker.dart',
    "final id = m.label == m.id ? '' : '${m.id} · ';",
    "final id = m.label == m.id ? '' : '$m.id · ';")

# browser_speed_test: page_model is already provided by browser_agent
sub('test/browser_speed_test.dart',
    "import 'package:agent/services/browser/page_model.dart';\nimport 'package:agent/services/browser/read_page.dart';",
    "import 'package:agent/services/browser/read_page.dart';")

# digital_human_test: shared_preferences unused; Heartbeat comes with awareness
sub('test/digital_human_test.dart',
    "import 'package:flutter_test/flutter_test.dart';\nimport 'package:shared_preferences/shared_preferences.dart';\n\nimport 'package:agent/services/digital_human/heartbeat.dart';\nimport 'package:agent/services/digital_human/awareness.dart';",
    "import 'package:flutter_test/flutter_test.dart';\n\nimport 'package:agent/services/digital_human/awareness.dart';")

# agent_runner: lastUser is non-nullable here
sub('lib/state/agent_runner.dart',
    "if (!side && !bg && lastUser != null) {",
    "if (!side && !bg) {")

# composer: inside the compacting branch `live` is known non-null
sub('lib/widgets/composer.dart',
    "compacting: compacting ? (live?.summary ?? '') : null),",
    "compacting: compacting ? (live.summary ?? '') : null),")

print('cleanup applied')