#!/usr/bin/env python3
"""Investigation phase 2: the Case Room. New files are committed separately; this script only edits existing files."""
import io


def sub(path, old, new):
    with io.open(path, encoding='utf-8') as f:
        s = f.read()
    n = s.count(old)
    assert n == 1, path + ' :: expected 1, found ' + str(n) + ' :: ' + repr(old[:60])
    with io.open(path, 'w', encoding='utf-8') as f:
        f.write(s.replace(old, new))


# composer.dart: import the service + pills, then show the case pills in a case's chat
sub('lib/widgets/composer.dart',
    "import '../services/bots.dart';\nimport '../services/byok.dart';",
    "import '../services/bots.dart';\nimport '../services/cases.dart';\nimport '../services/byok.dart';")
sub('lib/widgets/composer.dart',
    "import 'browser_card.dart';\nimport '../models.dart';",
    "import 'browser_card.dart';\nimport 'case_pills.dart';\nimport '../models.dart';")
sub('lib/widgets/composer.dart',
    """              if (!needsModel && Bots.I.byConv(state.currentId) == null)
                const Padding(
                  padding: EdgeInsetsDirectional.only(top: Space.x2),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Wrap(spacing: Space.x2, runSpacing: Space.x1, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      ModelPill(),
                      ThinkingPill(),
                      PermissionPill(),
                    ]),
                  ),
                ),""",
    """              if (!needsModel && Bots.I.byConv(state.currentId) == null)
                Padding(
                  padding: const EdgeInsetsDirectional.only(top: Space.x2),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Wrap(spacing: Space.x2, runSpacing: Space.x1, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      const ModelPill(),
                      const ThinkingPill(),
                      const PermissionPill(),
                      // In a case's chat: how we work this case and what the detective may use (§8).
                      if (Cases.I.byConv(state.currentId) != null) ...[
                        const ModePill(),
                        const AbilitiesPill(),
                      ],
                    ]),
                  ),
                ),""")

# caseboard_screen.dart: open the case room, for a row and for a new case
sub('lib/screens/caseboard_screen.dart',
    "import '../ui/tokens.dart';\n",
    "import '../ui/tokens.dart';\nimport 'case_screen.dart';\n")
sub('lib/screens/caseboard_screen.dart',
    """    if (ok != true || t.isEmpty || !context.mounted) return;
    final nav = Navigator.of(context);
    await context.read<AppState>().createCase(title: t, brief: b, reportedTo: r);
    if (nav.canPop()) nav.pop();""",
    """    if (ok != true || t.isEmpty || !context.mounted) return;
    final c = await context.read<AppState>().createCase(title: t, brief: b, reportedTo: r);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => CaseScreen(caseId: c.id)));""")
sub('lib/screens/caseboard_screen.dart',
    """    final p = Palette.of(context);
    final state = context.read<AppState>();
    final bits = [""",
    """    final p = Palette.of(context);
    final bits = [""")
sub('lib/screens/caseboard_screen.dart',
    """      onTap: () async {
        final nav = Navigator.of(context);
        await state.openCase(item.id);
        if (nav.canPop()) nav.pop();
      },""",
    """      onTap: () {
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => CaseScreen(caseId: item.id)));
      },""")

# sidebar.dart: a case row opens the case room
sub('lib/widgets/sidebar.dart',
    "import '../screens/caseboard_screen.dart';\n",
    "import '../screens/caseboard_screen.dart';\nimport '../screens/case_screen.dart';\n")
sub('lib/widgets/sidebar.dart',
    """    final p = Palette.of(context);
    final state = context.read<AppState>();
    return Material(
      color: selected ? p.bubble : Colors.transparent,
      borderRadius: Radii.fieldAll,
      child: InkWell(
        borderRadius: Radii.fieldAll,
        onTap: () {
          state.openCase(item.id);
          Navigator.pop(context);
        },""",
    """    final p = Palette.of(context);
    return Material(
      color: selected ? p.bubble : Colors.transparent,
      borderRadius: Radii.fieldAll,
      child: InkWell(
        borderRadius: Radii.fieldAll,
        onTap: () {
          Navigator.pop(context);
          Navigator.push(context, MaterialPageRoute(builder: (_) => CaseScreen(caseId: item.id)));
        },""")

print('phase 2 applied')
