import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../services/case_abilities.dart';
import '../services/cases.dart';
import '../theme.dart';
import '../ui/i18n.dart';
import '../ui/tokens.dart';
import 'chat/activity_panel.dart';
import 'chat/edge_fade.dart';

/// The Investigation pills under the composer: the case's Mode (Solo / Partner) and its Abilities.
///
/// They sit beside the model and thinking pills and only appear in a case's chat. Both read the case bound to the
/// open conversation, so nothing needs threading through the Composer (docs/investigation.md §8).

/// A quiet pill: a word and a small chevron, like the model/thinking pills under the composer.
class _Pill extends StatelessWidget {
  const _Pill({required this.keyName, required this.label, required this.onTap});
  final String keyName;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return FrostedSurface(
      radius: Radii.pill,
      child: InkWell(
        key: ValueKey(keyName),
        borderRadius: const BorderRadius.all(Radius.circular(Radii.pill)),
        onTap: onTap,
        child: Container(
          height: 28,
          constraints: const BoxConstraints(maxWidth: 200),
          padding: const EdgeInsetsDirectional.fromSTEB(Space.x3, 0, Space.x2, 0),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Flexible(
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.microStyle.copyWith(color: p.text, fontWeight: FontWeight.w600)),
            ),
            const ActivityChevron(open: false),
          ]),
        ),
      ),
    );
  }
}

/// Solo / Partner for the open case. Always shows; the choice is asked for in a small sheet.
class ModePill extends StatelessWidget {
  const ModePill({super.key});

  @override
  Widget build(BuildContext context) {
    final convId = context.select<AppState, String?>((s) => s.currentId);
    return AnimatedBuilder(
      animation: Cases.I,
      builder: (context, _) {
        final c = Cases.I.byConv(convId);
        if (c == null) return const SizedBox.shrink();
        return _Pill(
          keyName: 'case-mode-pill',
          label: c.mode == CaseMode.solo ? tr('Solo') : tr('Partner'),
          onTap: () => _pickMode(context, c),
        );
      },
    );
  }
}

Future<void> _pickMode(BuildContext context, Case c) async {
  final pick = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    sheetAnimationStyle: SubMotion.sheet,
    builder: (ctx) {
      final p = Palette.of(ctx);
      Widget row(String mode, String word, String hint) => ListTile(
            key: ValueKey('case-mode-$mode'),
            title: Text(tr(word)),
            subtitle: Text(tr(hint), style: AppText.microStyle.copyWith(color: p.muted)),
            trailing: c.mode == mode ? Text(tr('Now'), style: AppText.microStyle.copyWith(color: p.muted)) : null,
            onTap: () => Navigator.pop(ctx, mode),
          );
      return SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(Space.x5, 0, Space.x5, Space.x2),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(tr('How we work this case'), style: AppText.titleStyle.copyWith(color: p.text)),
            ),
          ),
          row(CaseMode.partner, 'Partner', 'You steer; Telesia proposes leads and asks focused questions.'),
          row(CaseMode.solo, 'Solo', 'Telesia works the case on its own and reports at milestones.'),
          const SizedBox(height: Space.x4),
        ]),
      );
    },
  );
  if (pick != null) await Cases.I.update(c, mode: pick);
}

/// Abilities · N for the open case: the plain vocabulary that gates the many tools. Opens a sheet of Off · Ask · On.
class AbilitiesPill extends StatelessWidget {
  const AbilitiesPill({super.key});

  @override
  Widget build(BuildContext context) {
    final convId = context.select<AppState, String?>((s) => s.currentId);
    return AnimatedBuilder(
      animation: Cases.I,
      builder: (context, _) {
        final c = Cases.I.byConv(convId);
        if (c == null) return const SizedBox.shrink();
        final on = CaseAbilities.all.where((a) => CaseAbilities.levelOf(c.abilities, a.id) == CaseAbilities.on).length;
        return _Pill(
          keyName: 'case-abilities-pill',
          label: '${tr('Abilities')} · $on',
          onTap: () => _pickAbilities(context, c),
        );
      },
    );
  }
}

Future<void> _pickAbilities(BuildContext context, Case c) async {
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    sheetAnimationStyle: SubMotion.sheet,
    builder: (ctx) {
      final p = Palette.of(ctx);
      return StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(Space.x5, 0, Space.x5, Space.x3),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('Abilities'), style: AppText.titleStyle.copyWith(color: p.text)),
              const SizedBox(height: Space.x1),
              Text(tr('What the detective may use while working this case.'), style: AppText.microStyle.copyWith(color: p.muted)),
              const SizedBox(height: Space.x3),
              for (final a in CaseAbilities.all)
                _AbilityRow(
                  ability: a,
                  level: CaseAbilities.levelOf(c.abilities, a.id),
                  onPick: (level) async {
                    await Cases.I.setAbilities(c, {a.id: level});
                    setSheet(() {});
                  },
                ),
              const SizedBox(height: Space.x2),
            ]),
          ),
        ),
      );
    },
  );
}

class _AbilityRow extends StatelessWidget {
  const _AbilityRow({required this.ability, required this.level, required this.onPick});
  final Ability ability;
  final String level;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    const levels = [CaseAbilities.off, CaseAbilities.ask, CaseAbilities.on];
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.x3),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(ability.name, style: AppText.bodyStyle.copyWith(color: p.text, fontWeight: FontWeight.w600)),
        const SizedBox(height: 2),
        Text(ability.blurb, style: AppText.microStyle.copyWith(color: p.muted)),
        const SizedBox(height: Space.x1),
        Row(children: [
          for (final l in levels)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: Space.x3),
              child: InkWell(
                key: ValueKey('ability-${ability.id}-$l'),
                borderRadius: Radii.fieldAll,
                onTap: () => onPick(l),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Space.x1, vertical: Space.x1),
                  child: Text(_word(l),
                      style: AppText.metaStyle.copyWith(color: l == level ? p.text : p.muted, fontWeight: l == level ? FontWeight.w600 : FontWeight.w400)),
                ),
              ),
            ),
        ]),
      ]),
    );
  }

  static String _word(String level) => switch (level) {
        CaseAbilities.off => tr('Off'),
        CaseAbilities.ask => tr('Ask'),
        _ => tr('On'),
      };
}
