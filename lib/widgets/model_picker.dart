import 'package:flutter/material.dart';

import '../services/byok.dart';
import '../services/byok_opencode.dart';
import '../services/context_window.dart';
import '../theme.dart';
import '../ui/i18n.dart';
import '../ui/tokens.dart';
import 'brand_logo.dart';
import 'chat/edge_fade.dart' show FrostedSurface;
import 'logo.dart';

/// Choosing a model (BYOK, owner 2026-11-03): Telesia first, then the user's own providers, each with its models
/// (strong models first). Returns the chosen setting (`telesia` or `byok-…|model`), or null when dismissed. Used by
/// Settings → Models, the composer's model pill and each bot's profile.
///
/// [forBot] (a bot's profile, owner 2026-11-05): a "Default (same as Telesia)" row comes first and returns `auto`;
/// the Telesia row then means Telesia's own model even when the owner's chats use another one.
Future<String?> showModelPicker(BuildContext context, {required String current, String title = 'Model', bool forBot = false}) {
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    sheetAnimationStyle: SubMotion.sheet,
    builder: (ctx) => _ModelSheet(current: current, title: title, forBot: forBot),
  );
}

/// The words for a bot's model setting in its profile: "Default (same as Telesia)", "Telesia", or the own model's name
/// with its provider. A chosen model that cannot be used here says so (the bot runs on the default meanwhile).
String botModelLabel(String setting, {ByokStore? store}) {
  final st = store ?? ByokStore.I;
  final s = setting.trim();
  if (s.isEmpty || s == 'auto') return BotModelWords.defaultLabel;
  if (ByokRef.parse(s) != null) {
    final pick = st.resolve(s);
    if (pick == null) return '${BotModelWords.defaultLabel} · ${ByokRef.parse(s)!.model} is not available';
    return '${pick.model.label} · ${pick.provider.label}';
  }
  return BotModelWords.defaultLabel;
}

/// The details of one model in the app's words (owner 2026-11-10): what opencode's own model list shows, so a
/// choice is never blind — how much the model can read at once, and the longest reply it can write.
class ModelInfo {
  ModelInfo._();

  /// "128k", "1M", "200k": never a raw number.
  static String size(int n) {
    if (n >= 1000000) {
      final m = n / 1000000;
      return '${m.toStringAsFixed(m == m.roundToDouble() ? 0 : 1)}M';
    }
    if (n >= 1000) return '${(n / 1000).round()}k';
    return '$n';
  }

  /// The quiet line under a model's name: its id when it differs, its window and its longest reply.
  static String rowOf(ByokModel m) {
    final window = m.context ?? ByokOpencode.defaultContext;
    final id = m.label == m.id ? '' : '${m.id} · ';
    return '${id}${size(window)} window · ${size(ByokOpencode.outputOf(m))} reply';
  }

  /// What this chat uses right now, as one line under the sheet's title.
  static String current(String setting, {ByokStore? store}) {
    final pick = (store ?? ByokStore.I).resolve(setting);
    if (pick == null) return 'Telesia · reads up to ${size(ContextWindow.tokens)} at once';
    return '${pick.provider.label} · ${pick.model.label} · reads up to ${size(pick.model.context ?? ByokOpencode.defaultContext)} at once';
  }
}

class BotModelWords {
  BotModelWords._();
  static const defaultLabel = 'Default';
  static const defaultValue = 'auto';
}

class _ModelSheet extends StatelessWidget {
  const _ModelSheet({required this.current, required this.title, this.forBot = false});
  final String current;
  final String title;
  final bool forBot;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final store = ByokStore.I;
    final picked = store.resolve(current)?.ref.toString();
    final cur = current.trim();
    // A bot on its default, or on an own model that is not usable here (it runs on the default meanwhile).
    final onDefault = forBot && (cur.isEmpty || cur == 'auto' || (ByokRef.parse(cur) != null && picked == null));
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
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(Space.x5, 0, Space.x5, Space.x2),
              child: Text(ModelInfo.current(current), style: AppText.microStyle.copyWith(color: p.muted)),
            ),
            if (forBot)
              ListTile(
                key: const ValueKey('model-default'),
                leading: const AppLogo(size: 32),
                title: Text(tr(BotModelWords.defaultLabel)),
                subtitle: Text('${tr('Now')}: ${store.labelOf(store.chatModel, withProvider: true)}',
                    style: AppText.microStyle.copyWith(color: p.muted)),
                trailing: check(onDefault),
                onTap: () => Navigator.pop(context, BotModelWords.defaultValue),
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
                  subtitle: Text(ModelInfo.rowOf(m), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.microStyle.copyWith(color: p.muted)),
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
                    // "Model", not the whole model id (owner 2026-11-10): the row under the composer keeps its room
                    // for the Thinking and permission pills; the sheet names the model itself.
                    child: Text(tr('Model'),
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
