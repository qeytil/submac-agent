import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../screens/bots_screen.dart' show BotAvatar;
import '../services/bots.dart';
import '../services/offices.dart';
import '../theme.dart';
import '../ui/tokens.dart';

/// A team's head (owner, 2026-10-24, like Grok's group heads): ONE circle exactly the size of a single bot's head,
/// with the members' tiny faces clustered inside it. 1 member: its face fills the circle. 2: side by side, overlapping.
/// 3: a small triangle. 4 or more: a 2×2 cluster (the lead first, then the others in team order). The status ring goes
/// around it the same way it goes around a bot's head, so a team never looks bigger than a bot.
///
/// Placement follows the reading direction: in RTL the first face sits on the right.
class TeamFace extends StatelessWidget {
  const TeamFace({super.key, required this.office, required this.size});
  final Office office;

  /// The diameter: the same value a bot's head uses in the same place.
  final double size;

  /// At most this many faces show.
  static const int maxFaces = 4;

  /// The members shown: the lead first, then the others, up to [maxFaces].
  static List<Bot> facesOf(Office o) {
    final ids = [if (o.chiefId.isNotEmpty) o.chiefId, ...o.members.where((id) => id != o.chiefId)];
    return [for (final id in ids) Bots.I.byId(id)].whereType<Bot>().take(maxFaces).toList();
  }

  /// Where each mini face sits (its centre, as a fraction of the circle, LTR) and its diameter (fraction of the circle).
  static List<({Offset c, double d})> layout(int n) => switch (n) {
        <= 1 => const [(c: Offset(0.5, 0.5), d: 1.0)],
        2 => const [(c: Offset(0.34, 0.42), d: 0.58), (c: Offset(0.66, 0.58), d: 0.58)],
        3 => const [(c: Offset(0.5, 0.3), d: 0.5), (c: Offset(0.29, 0.66), d: 0.5), (c: Offset(0.71, 0.66), d: 0.5)],
        _ => const [(c: Offset(0.3, 0.3), d: 0.46), (c: Offset(0.7, 0.3), d: 0.46), (c: Offset(0.3, 0.7), d: 0.46), (c: Offset(0.7, 0.7), d: 0.46)],
      };

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final faces = facesOf(office);
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final Widget inside;
    if (faces.isEmpty) {
      final t = office.name.trim();
      inside = ColoredBox(
        color: p.bubble,
        child: Center(
          child: t.isEmpty ? const SizedBox.shrink() : Text(t.characters.first.toUpperCase(), style: AppText.leadStyle.copyWith(color: p.muted, fontWeight: FontWeight.w600)),
        ),
      );
    } else if (faces.length == 1) {
      inside = BotAvatar(bot: faces.first, size: size);
    } else {
      final spots = layout(faces.length);
      inside = ColoredBox(
        color: p.bubble,
        child: Stack(children: [
          for (final (i, b) in faces.indexed)
            Positioned(
              key: ValueKey('team-face-mini-$i'),
              left: ((rtl ? 1 - spots[i].c.dx : spots[i].c.dx) - spots[i].d / 2) * size,
              top: (spots[i].c.dy - spots[i].d / 2) * size,
              width: spots[i].d * size,
              height: spots[i].d * size,
              // A thin cut of the background around each mini face keeps overlapping faces apart.
              child: DecoratedBox(
                decoration: BoxDecoration(shape: BoxShape.circle, color: p.bubble),
                child: Padding(
                  padding: EdgeInsets.all(math.max(0.6, size * 0.018)),
                  child: ClipOval(child: FittedBox(child: BotAvatar(bot: b, size: spots[i].d * size))),
                ),
              ),
            ),
        ]),
      );
    }
    return Semantics(
      label: office.name,
      excludeSemantics: true,
      child: SizedBox.square(
        key: ValueKey('team-face-${office.id}'),
        dimension: size,
        child: ClipOval(child: inside),
      ),
    );
  }
}
