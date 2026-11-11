import 'package:flutter/material.dart';
import '../../services/digital_human/person.dart';
import '../../theme.dart';
import '../../ui/tokens.dart';

import 'bot_feed_card.dart';

/// Bottom sheet showing a person's current state: mood, energy, recent activity.
class BotProfileSheet extends StatelessWidget {
  const BotProfileSheet({super.key, required this.person});
  final DigitalPerson person;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
      decoration: BoxDecoration(
        color: p.sheet,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(Radii.sheet)),
      ),
      child: SingleChildScrollView(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom + Space.x4),
        child: Padding(
          padding: const EdgeInsets.all(Space.x4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Handle
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.symmetric(horizontal: Space.x4),
                decoration: BoxDecoration(
                  color: p.border,
                  borderRadius: BorderRadius.circular(Radii.pill),
                ),
              ),
              const SizedBox(height: Space.x4),
              // Avatar + name
              Row(
                children: [
                  _MiniAvatar(person: person),
                  const SizedBox(width: Space.x3),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(person.name, style: Brand.display(size: 22, color: p.text)),
                        if (person.role.isNotEmpty)
                          InkText(person.role.capitalize(), style: AppText.metaStyle.copyWith(color: p.muted)),
                      ],
                    ),
                  ),
                  _PresenceBadge(state: person.presence),
                ],
              ),
              const Divider(height: Space.x4),
              // Mood & Energy rows
              _StatRow(
                icon: Icons.sentiment_satisfied_alt_rounded,
                label: 'Mood',
                value: person.mood.moodLabel,
                color: MoodEngine.moodColor(person.mood.mood),
              ),
              _StatRow(
                icon: Icons.battery_charging_full_rounded,
                label: 'Energy',
                value: '${(person.energy.level * 100).toInt()}%',
                color: person.energy.isLow ? const Color(0xFFC2361B) : PresenceStateColors.online,
                bar: true,
                level: person.energy.level,
              ),
              _StatRow(
                icon: Icons.access_time,
                label: 'Idle',
                value: '${person.heartbeat.idleTime.inMinutes}m',
                color: p.muted,
              ),
              _StatRow(
                icon: Icons.memory_rounded,
                label: 'Memories',
                value: '${person.memory.episodeCount}',
                color: p.muted,
              ),
              const SizedBox(height: Space.x3),
              // Recent memories
              if (person.memory.recentEpisodes(3).isNotEmpty) ...[
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text('Recent', style: AppText.sectionStyle.copyWith(color: p.muted)),
                ),
                const SizedBox(height: Space.x2),
                ...person.memory.recentEpisodes(3).map((e) => _MemoryChip(content: e['content'] as String)),
                const SizedBox(height: Space.x3),
              ],
              // Actions
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: p.text,
                        side: BorderSide(color: p.border),
                        padding: const EdgeInsets.symmetric(vertical: Space.x3),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.field)),
                      ),
                      child: const Text('Close'),
                    ),
                  ),
                  const SizedBox(width: Space.x3),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () {},
                      style: ElevatedButton.styleFrom(
                        backgroundColor: p.text,
                        foregroundColor: p.bg,
                        padding: const EdgeInsets.symmetric(vertical: Space.x3),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.field)),
                      ),
                      child: const Text('Chat'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniAvatar extends StatelessWidget {
  const _MiniAvatar({required this.person});
  final DigitalPerson person;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final color = PresenceStateColors.colorOf(person.presence);
    return Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [color.withValues(alpha: 0.3), color],
          stops: const [0.5, 1.0],
        ),
      ),
      child: Center(
        child: Text(
          person.name.isNotEmpty ? person.name[0].toUpperCase() : '?',
          style: Brand.display(size: 26, color: p.bg),
        ),
      ),
    );
  }
}

class _PresenceBadge extends StatelessWidget {
  const _PresenceBadge({required this.state});
  final PresenceState state;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Space.x3, vertical: Space.x1),
      decoration: BoxDecoration(
        color: PresenceStateColors.colorOf(state).withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: PresenceStateColors.colorOf(state),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: Space.x1),
          Text(
            switch (state) {
              PresenceState.offline => 'Offline',
              PresenceState.online => 'Online',
              PresenceState.thinking => 'Thinking',
              PresenceState.working => 'Working',
            },
            style: AppText.metaStyle.copyWith(color: PresenceStateColors.colorOf(state)),
          ),
        ],
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  const _StatRow({required this.icon, required this.label, required this.value, required this.color, this.bar = false, this.level = 0.0});
  final IconData icon;
  final String label;
  final String value;
  final Color color;
  final bool bar;
  final double level;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.x2),
      child: Row(
        children: [
          Icon(icon, size: 18, color: p.muted),
          const SizedBox(width: Space.x3),
          Text(label, style: AppText.metaStyle.copyWith(color: p.muted)),
          const Spacer(),
          if (bar)
            Expanded(
              flex: 3,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(Radii.sm),
                child: LinearProgressIndicator(
                  value: level,
                  minHeight: 6,
                  backgroundColor: p.border,
                  valueColor: AlwaysStoppedAnimation(color),
                ),
              ),
            )
          else
            Flexible(
              child: Text(value, style: AppText.bodyStyle.copyWith(color: color, fontWeight: FontWeight.w600)),
            ),
        ],
      ),
    );
  }
}

class _MemoryChip extends StatelessWidget {
  const _MemoryChip({required this.content});
  final String content;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: Space.x2),
      padding: const EdgeInsets.symmetric(horizontal: Space.x3, vertical: Space.x2),
      decoration: BoxDecoration(
        color: p.bubble,
        borderRadius: BorderRadius.circular(Radii.row),
      ),
      child: Text(content.length > 80 ? '${content.substring(0, 80)}...' : content,
          style: AppText.metaStyle.copyWith(color: p.text)),
    );
  }
}

// Helper extensions
extension on String {
  String capitalize() => isEmpty ? this : '${this[0].toUpperCase()}${substring(1)}';
}
