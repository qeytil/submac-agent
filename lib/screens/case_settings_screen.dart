import 'package:flutter/material.dart';

import '../services/case_abilities.dart';
import '../services/case_ability_defaults.dart';
import '../theme.dart';
import '../ui/i18n.dart';
import '../ui/tokens.dart';

/// Settings → Investigation (docs/investigation.md §10): what the detective may use by default, in the owner's words.
class CaseSettingsScreen extends StatelessWidget {
  const CaseSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(tr('Investigation'))),
      body: AnimatedBuilder(
        animation: CaseAbilityDefaults.I,
        builder: (context, _) => ListView(
          padding: const EdgeInsetsDirectional.fromSTEB(Lux.gutter, Space.x3, Lux.gutter, Space.x8),
          children: [
            Text(tr('What the detective may use on a case by default.'), style: AppText.bodyStyle.copyWith(color: p.muted)),
            const SizedBox(height: Space.x1),
            Text(tr('Phone records are never on by default: turn them on for the case that needs them.'),
                style: AppText.microStyle.copyWith(color: p.muted)),
            const SizedBox(height: Space.x5),
            for (final a in CaseAbilityDefaults.I.editable) _AbilityDefault(ability: a),
          ],
        ),
      ),
    );
  }
}

class _AbilityDefault extends StatelessWidget {
  const _AbilityDefault({required this.ability});
  final Ability ability;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final level = CaseAbilityDefaults.I.levelOf(ability.id);
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.x4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(ability.name, style: AppText.bodyStyle.copyWith(color: p.text, fontWeight: FontWeight.w600)),
        const SizedBox(height: 2),
        Text(ability.blurb, style: AppText.microStyle.copyWith(color: p.muted)),
        const SizedBox(height: Space.x1),
        Wrap(
          spacing: Space.x3,
          runSpacing: Space.x1,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final l in const [CaseAbilities.off, CaseAbilities.ask, CaseAbilities.on])
              InkWell(
                borderRadius: Radii.fieldAll,
                onTap: () => CaseAbilityDefaults.I.setLevel(ability.id, l),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Space.x1, vertical: Space.x1),
                  child: Text(_word(l),
                      style: AppText.metaStyle.copyWith(color: l == level ? p.text : p.muted, fontWeight: l == level ? FontWeight.w600 : FontWeight.w400)),
                ),
              ),
          ],
        ),
      ]),
    );
  }

  static String _word(String level) => switch (level) {
        CaseAbilities.off => tr('Off'),
        CaseAbilities.ask => tr('Ask'),
        _ => tr('On'),
      };
}
