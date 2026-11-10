import 'dart:math';

import 'package:flutter/material.dart';

import '../services/bots.dart';
import '../theme.dart';
import '../ui/i18n.dart';
import '../ui/tokens.dart';
import 'sub_avatar.dart';
import 'sub_icon.dart';

/// Choose how a bot looks: shape, colour and eyes from Telesia's avatar set, with a live preview.
/// Opened from the bot's profile (tap its face) and from the hold sheet ("Look").
Future<void> pickAvatar(BuildContext context, Bot bot) async {
  final start = AvatarSpec.parse(bot.look) ?? AvatarSpec.seeded(bot.id);
  final picked = await showModalBottomSheet<AvatarSpec>(
    context: context,
    isScrollControlled: true,
    sheetAnimationStyle: SubMotion.sheet,
    builder: (_) => _AvatarSheet(bot: bot, start: start),
  );
  if (picked == null) return;
  // Back to its own face: store nothing, so the seeded avatar shows.
  await Bots.I.setLook(bot, picked == AvatarSpec.seeded(bot.id) ? null : picked.look);
}

class _AvatarSheet extends StatefulWidget {
  const _AvatarSheet({required this.bot, required this.start});
  final Bot bot;
  final AvatarSpec start;

  @override
  State<_AvatarSheet> createState() => _AvatarSheetState();
}

class _AvatarSheetState extends State<_AvatarSheet> {
  late AvatarSpec _s = widget.start;
  final _rnd = Random();

  void _shuffle() {
    T any<T>(List<T> l) => l[_rnd.nextInt(l.length)];
    setState(() => _s = AvatarSpec(any(AvatarSpec.shapes), any(AvatarSpec.colors), any(AvatarSpec.eyeKinds)));
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    Widget label(String t) => Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(0, Space.x5, 0, Space.x2),
          child: Text(tr(t), style: AppText.metaStyle.copyWith(color: p.muted, fontWeight: FontWeight.w600)),
        );
    // The chosen one carries a small ink dot under it; nothing is boxed or ringed.
    Widget option({required Widget child, required bool on, required String tip, required VoidCallback tap}) => Tooltip(
          message: tip,
          child: InkWell(
            borderRadius: Radii.fieldAll,
            onTap: tap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 2),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                child,
                const SizedBox(height: 5),
                AnimatedOpacity(
                  duration: SubMotion.quick,
                  opacity: on ? 1 : 0,
                  child: SubIcon('check', size: 12, color: p.text),
                ),
              ]),
            ),
          ),
        );
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(Space.x5, Space.x4, Space.x5, Space.x4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(tr('Look'), style: AppText.titleStyle.copyWith(color: p.text, fontWeight: FontWeight.w600))),
              TextButton(onPressed: _shuffle, child: Text(tr('Shuffle'), style: AppText.metaStyle.copyWith(color: p.text, fontWeight: FontWeight.w600))),
            ]),
            const SizedBox(height: Space.x3),
            Center(
              child: AnimatedSwitcher(
                duration: SubMotion.base,
                switchInCurve: SubMotion.settle,
                transitionBuilder: (c, a) => ScaleTransition(scale: Tween(begin: 0.92, end: 1.0).animate(a), child: FadeTransition(opacity: a, child: c)),
                child: SubAvatar(key: ValueKey(_s.look), spec: _s, size: 112),
              ),
            ),
            const SizedBox(height: Space.x2),
            Center(child: Text(widget.bot.name, style: AppText.leadStyle.copyWith(color: p.text, fontWeight: FontWeight.w600))),
            label('Shape'),
            Wrap(spacing: Space.x1, runSpacing: Space.x1, children: [
              for (final sh in AvatarSpec.shapes)
                option(
                  tip: sh,
                  on: _s.shape == sh,
                  tap: () => setState(() => _s = _s.copyWith(shape: sh)),
                  child: SubAvatar(spec: _s.copyWith(shape: sh), size: 44),
                ),
            ]),
            label('Colour'),
            Wrap(spacing: Space.x1, runSpacing: Space.x1, children: [
              for (final c in AvatarSpec.colors)
                option(
                  tip: tr(AvatarSpec.colorNames[c]!),
                  on: _s.color == c,
                  tap: () => setState(() => _s = _s.copyWith(color: c)),
                  child: Container(width: 30, height: 30, margin: const EdgeInsets.all(7), decoration: BoxDecoration(color: AvatarSpec.colorOf(c), shape: BoxShape.circle)),
                ),
            ]),
            label('Eyes'),
            Wrap(spacing: Space.x1, runSpacing: Space.x1, children: [
              for (final e in AvatarSpec.eyeKinds)
                option(
                  tip: e,
                  on: _s.eyes == e,
                  tap: () => setState(() => _s = _s.copyWith(eyes: e)),
                  child: SubAvatar(spec: _s.copyWith(eyes: e), size: 44),
                ),
            ]),
            const SizedBox(height: Space.x5),
            Row(children: [
              TextButton(
                onPressed: () => Navigator.pop(context, AvatarSpec.seeded(widget.bot.id)),
                child: Text(tr('Default'), style: AppText.bodyStyle.copyWith(color: p.muted)),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => Navigator.pop(context, _s),
                child: Text(tr('Use this look'), style: AppText.bodyStyle.copyWith(color: p.text, fontWeight: FontWeight.w700)),
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}
