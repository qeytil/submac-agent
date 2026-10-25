import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

export 'bot_job_screen.dart' show BotProfileScreen;
import 'bots_workspace.dart';
import '../app_state.dart';
import '../services/bots.dart';

import '../theme.dart';
import '../ui/tokens.dart';
import '../widgets/bot_face.dart';
import '../widgets/sub_icon.dart';
import '../widgets/sub_avatar.dart';

IconData botIcon(String name) => switch (name) {
      'school' => Icons.school_outlined,
      'gavel' => Icons.gavel_outlined,
      'trending_up' => Icons.trending_up_rounded,
      'travel_explore' => Icons.travel_explore_rounded,
      'fitness_center' => Icons.fitness_center_rounded,
      'payments' => Icons.payments_outlined,
      'edit' => Icons.edit_outlined,
      'code' => Icons.code_rounded,
      'work' => Icons.work_outline_rounded,
      'favorite' => Icons.favorite_border_rounded,
      'campaign' => Icons.campaign_outlined,
      'storefront' => Icons.storefront_outlined,
      'health' => Icons.health_and_safety_outlined,
      _ => Icons.person_outline_rounded,
    };

/// The bot's face: a calm monochrome disc with its icon, and (with [presence]) a small dot for Working · Free · Off.
/// A bot with a look gets [BotFace] — the same disc, alive. A bot without one keeps the classic disc (invariant 7).
class BotAvatar extends StatelessWidget {
  const BotAvatar({super.key, required this.bot, this.size = 44, this.presence = false, this.mood = BotMood.idle});
  final Bot bot;
  final double size;
  final bool presence;
  final BotMood mood;

  @override
  Widget build(BuildContext context) {
    final look = bot.look ?? '';
    // SubMac's avatar set: the one the owner chose, or the bot's own seeded one. An older animated look still shows.
    final spec = AvatarSpec.parse(look);
    final dim = !bot.active && !Bots.I.isChief(bot);
    final Widget face = spec != null || look.isEmpty
        ? SubAvatar(spec: spec ?? AvatarSpec.seeded(bot.id), size: size, dim: dim)
        : BotFace(mood: mood, seed: bot.id, size: size, dim: !bot.active);
    // Presence is said in words on the row; no status dot on the face.
    return face;
  }
}

/// Bots, Grok-style (owner 2026-10-24): one place for bots and teams, the Bots workspace. It opens on the Chief's chat
/// with a thin rail of heads on the side. The old roster page is gone; this name stays so every way in keeps working.
class BotsScreen extends StatelessWidget {
  const BotsScreen({super.key});

  @override
  Widget build(BuildContext context) => const BotsWorkspace();
}

/// A bot calling while the app is open: a card slides down at the top, like an incoming call.
class IncomingCallLayer extends StatelessWidget {
  const IncomingCallLayer({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    return ValueListenableBuilder<Bot?>(
      valueListenable: state.incomingCall,
      builder: (context, b, _) {
        final p = Palette.of(context);
        final full = b != null && Bots.I.fullScreenCalls;
        return Stack(children: [
          Positioned.fill(child: child),
          if (b != null && full)
            Positioned.fill(
              child: Material(
                color: p.bg,
                child: SafeArea(
                  child: Column(children: [
                    const Spacer(),
                    BotAvatar(bot: b, size: 110, mood: BotMood.listening),
                    const SizedBox(height: 18),
                    Text(b.name, style: Brand.display(size: 34, color: p.text)),
                    const SizedBox(height: 6),
                    InkText('Calling', style: AppText.bodyStyle.copyWith(color: p.muted)),
                    const Spacer(),
                    Padding(
                      padding: const EdgeInsetsDirectional.fromSTEB(40, 0, 40, 40),
                      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                        _CallWord(icon: 'close', label: 'Decline', color: p.muted, onTap: () => state.declineBotCall(b.id)),
                        _CallWord(icon: 'phone', label: 'Answer', color: p.text, onTap: () => state.answerBotCall(b.id)),
                      ]),
                    ),
                  ]),
                ),
              ),
            ),
          AnimatedPositioned(
            duration: SubMotion.of(context, SubMotion.base),
            curve: SubMotion.settle,
            left: 10,
            right: 10,
            top: b != null && !full ? MediaQuery.of(context).padding.top + 8 : -160,
            child: b == null || full
                ? const SizedBox.shrink()
                : Material(
                    // A quiet strip of paper over the top, no card, no shadow.
                    color: p.bg,
                    child: Padding(
                      padding: const EdgeInsetsDirectional.fromSTEB(14, 12, 12, 12),
                      child: Row(children: [
                        BotAvatar(bot: b, size: 42),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                            Text(b.name, style: AppText.bodyStyle.copyWith(color: p.text, fontWeight: FontWeight.w600)),
                            InkText('Calling', style: AppText.metaStyle.copyWith(color: p.muted)),
                          ]),
                        ),
                        _CallWord(icon: 'close', label: 'Decline', color: p.muted, small: true, onTap: () => state.declineBotCall(b.id)),
                        const SizedBox(width: 6),
                        _CallWord(icon: 'phone', label: 'Answer', color: p.text, small: true, onTap: () => state.answerBotCall(b.id)),
                      ]),
                    ),
                  ),
          ),
        ]);
      },
    );
  }
}

/// A call answer: SubMac's own icon over one short word. No filled circle, no ring.
class _CallWord extends StatelessWidget {
  const _CallWord({required this.icon, required this.label, required this.color, required this.onTap, this.small = false});
  final String icon;
  final String label;
  final Color color;
  final bool small;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: label,
        excludeSemantics: true,
        child: InkResponse(
          radius: small ? 28 : 44,
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.all(small ? 6 : 12),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              SubIcon(icon, size: small ? 22 : 30, color: color),
              SizedBox(height: small ? 2 : 8),
              Text(label, style: TextStyle(color: color, fontSize: small ? AppText.micro : AppText.meta, fontWeight: FontWeight.w600)),
            ]),
          ),
        ),
      );
}
