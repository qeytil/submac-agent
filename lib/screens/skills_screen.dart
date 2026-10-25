import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../services/skills_catalog.dart';
import '../theme.dart';
import '../widgets/logo.dart';
import '../widgets/meeting_sheet.dart';
import '../widgets/pill_kit.dart';
import 'live_screen.dart';
import '../ui/tokens.dart';
import '../ui/i18n.dart';

/// Start a skill: tools open right away; everything else becomes a chip in the composer.
void useSkill(BuildContext context, Skill s, {bool popToChat = false}) {
  final state = context.read<AppState>();
  if (popToChat) Navigator.of(context).popUntil((r) => r.isFirst);
  switch (s.kind) {
    case 'scan':
      state.widgetAction.value = null;
      state.widgetAction.value = 'scan';
      return;
    case 'translate':
      openLive(context, mode: 'translate');
      return;
    case 'meeting':
      showMeetingRecorder(context);
      return;
    case 'research':
      state.setDeepResearch(true);
      return;
    default:
      state.pickSkill(s);
  }
}

class SkillsScreen extends StatefulWidget {
  const SkillsScreen({super.key});

  @override
  State<SkillsScreen> createState() => _SkillsScreenState();
}

class _SkillsScreenState extends State<SkillsScreen> {
  String _q = '';
  String _cat = 'Featured';

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final q = _q.toLowerCase();
    final list = q.isEmpty
        ? SkillsCatalog.inCategory(_cat)
        : SkillsCatalog.all
            .where((s) => '${s.name} ${s.blurb} ${s.category}'.toLowerCase().contains(q))
            .toList();
    const hero = 'research';
    final heroSkill = SkillsCatalog.byId(hero)!;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 48,
        centerTitle: true,
        title: Text(tr('Skills')),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 4, 16, 14),
            child: PillSearch(hint: 'Search skills', onChanged: (v) => setState(() => _q = v)),
          ),
          if (q.isEmpty) ...[
            // One featured skill, presented like a small poster.
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(16, 0, 16, 16),
              child: Container(
                padding: const EdgeInsetsDirectional.fromSTEB(20, 26, 20, 20),
                decoration: BoxDecoration(
                  color: p.sheet,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: p.border, width: 0.8),
                ),
                child: Column(children: [
                  const RedDot(size: 14, animate: true),
                  const SizedBox(height: 14),
                  Text(heroSkill.name, style: Brand.serif(size: 24, color: p.text)),
                  const SizedBox(height: 6),
                  Text('One clear report, with sources.',
                      textAlign: TextAlign.center, style: TextStyle(color: p.muted, fontSize: AppText.meta, height: 1.4)),
                  const SizedBox(height: 14),
                  PillButton('Try now', strong: true, onTap: () => useSkill(context, heroSkill, popToChat: true)),
                ]),
              ),
            ),
            // Skill library hidden for launch (PLAN.md 3.3).
            const SizedBox(height: 8),
            CategoryTabs(
              tabs: SkillsCatalog.categories,
              selected: _cat,
              onSelect: (c) => setState(() => _cat = c),
            ),
            const SizedBox(height: 10),
          ],
          for (final s in list)
            CardRow(
              title: s.name,
              subtitle: s.blurb,
              leading: Monogram(s.name, accent: s.featured),
              action: 'Use',
              onAction: () => useSkill(context, s, popToChat: true),
            ),
          if (list.isEmpty)
            Padding(
              padding: const EdgeInsets.all(32),
              child: Text('No match. Just ask in chat.',
                  textAlign: TextAlign.center, style: TextStyle(color: p.muted, fontSize: AppText.meta, height: 1.4)),
            ),
        ],
      ),
    );
  }
}
