import 'package:flutter/material.dart';

import '../services/byok.dart';
import '../theme.dart';
import '../ui/i18n.dart';
import '../ui/tokens.dart';
import 'brand_logo.dart';
import 'chat/edge_fade.dart' show FrostedSurface;
import 'logo.dart';

/// Choosing a model (BYOK, owner 2026-11-03): SubMac first, then the user's own providers, each with its models.
/// Returns the chosen setting (`submac` or `byok-…|model`), or null when dismissed. Used by Settings → Models, the
/// composer's model pill and a bot's settings.
Future<String?> showModelPicker(BuildContext context, {required String current, String title = 'Model'}) {
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    sheetAnimationStyle: SubMotion.sheet,
    builder: (ctx) => _ModelSheet(current: current, title: title),
  );
}

class _ModelSheet extends StatelessWidget {
  const _ModelSheet({required this.current, required this.title});
  final String current;
  final String title;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final store = ByokStore.I;
    final picked = store.resolve(current)?.ref.toString();
    final groups = <ByokProvider, List<ByokModel>>{};
    for (final c in store.choices) {
      (groups[c.provider] ??= []).add(c.model);
    }
    Widget check(bool on) => on ? Icon(Icons.check_rounded, color: p.text, size: IconSize.lg) : const SizedBox(width: IconSize.lg);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.only(bottom: Space.x4),
          children: [
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(Space.x5, 0, Space.x5, Space.x2),
              child: Text(tr(title), style: AppText.titleStyle.copyWith(color: p.text)),
            ),
            ListTile(
              key: const ValueKey('model-submac'),
              leading: const AppLogo(size: 32),
              title: const Text('SubMac'),
              subtitle: Text(tr('Included in your plan'), style: AppText.microStyle.copyWith(color: p.muted)),
              trailing: check(picked == null),
              onTap: () => Navigator.pop(context, ByokRef.submac),
            ),
            for (final e in groups.entries) ...[
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(Space.x5, Space.x4, Space.x5, Space.x1),
                child: Row(children: [
                  BrandLogo(e.key.logo, e.key.label, size: 20),
                  const SizedBox(width: Space.x2),
                  Expanded(child: Text(e.key.label, style: AppText.sectionStyle.copyWith(color: p.muted))),
                ]),
              ),
              for (final m in e.value)
                ListTile(
                  key: ValueKey('model-${e.key.id}|${m.id}'),
                  title: Text(m.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: m.label == m.id ? null : Text(m.id, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.microStyle.copyWith(color: p.muted)),
                  trailing: check(picked == '${e.key.id}|${m.id}'),
                  onTap: () => Navigator.pop(context, '${e.key.id}|${m.id}'),
                ),
            ],
            if (groups.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(Space.x5, Space.x3, Space.x5, 0),
                child: Text(tr('Add your own providers in Settings → Models to choose their models here.'),
                    style: AppText.metaStyle.copyWith(color: p.muted)),
              ),
          ],
        ),
      ),
    );
  }
}

/// The chat's model under the composer, next to Ask · Autopilot: shown only when the user has models of their own
/// to choose from, so the composer stays as quiet as before for everyone else.
class ModelPill extends StatelessWidget {
  const ModelPill({super.key});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return ListenableBuilder(
      listenable: ByokStore.I,
      builder: (context, _) {
        final store = ByokStore.I;
        if (!store.hasChoices) return const SizedBox.shrink();
        final label = store.labelOf(store.chatModel);
        return Semantics(
          button: true,
          label: '${tr('Model')}: $label',
          child: FrostedSurface(
            radius: Radii.pill,
            child: InkWell(
              key: const ValueKey('model-pill'),
              borderRadius: const BorderRadius.all(Radius.circular(Radii.pill)),
              onTap: () async {
                final v = await showModelPicker(context, current: store.chatModel, title: 'Model for your chats');
                if (v != null) await store.setChatModel(v);
              },
              child: Container(
                height: 28,
                constraints: const BoxConstraints(maxWidth: 200),
                padding: const EdgeInsetsDirectional.fromSTEB(Space.x3, 0, Space.x2, 0),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Flexible(
                    child: Text(label,
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.microStyle.copyWith(color: p.text, fontWeight: FontWeight.w600)),
                  ),
                  Icon(Icons.expand_more_rounded, size: IconSize.sm, color: p.muted),
                ]),
              ),
            ),
          ),
        );
      },
    );
  }
}
