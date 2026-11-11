import 'package:flutter/material.dart';
import '../theme.dart';
import '../ui/tokens.dart';
import '../widgets/motion.dart';
import 'person.dart';

/// A single bot row in the Digital Human feed — WhatsApp style but Telesia quality.
///
/// Shows avatar (with animated presence ring), name, last message preview,
/// timestamp, and unread badge. Tapping opens the chat.
class BotFeedCard extends StatelessWidget {
  const BotFeedCard({
    super.key,
    required this.person,
    required this.onTap,
    this.lastMessage = '',
    this.lastTime = '',
    this.unreadCount = 0,
    this.isPinned = false,
  });

  final DigitalPerson person;
  final VoidCallback onTap;
  final String lastMessage;
  final String lastTime;
  final int unreadCount;
  final bool isPinned;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final presenceColor = PresenceStateColors.colorOf(person.presence);
    return FadeSlideIn(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(Radii.row),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.x4, vertical: Space.x2),
            child: Row(
              children: [
                // Avatar with animated presence ring
                _PresenceAvatar(person: person, color: presenceColor),
                const SizedBox(width: Space.x3),
                // Content column
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Name + pinned indicator + time
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              person.name,
                              style: AppText.bodyStyle.copyWith(
                                fontWeight: FontWeight.w600,
                                color: p.text,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (isPinned) ...[
                            const SizedBox(width: Space.x1),
                            Icon(Icons.push_pin_rounded, size: 14, color: p.muted),
                          ],
                          const SizedBox(width: Space.x2),
                          Text(
                            lastTime,
                            style: AppText.captionStyle.copyWith(color: _timeColor(unreadCount > 0)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      // Last message preview
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              lastMessage.isNotEmpty ? lastMessage : 'Start a conversation...',
                              style: AppText.metaStyle.copyWith(
                                color: p.muted,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (person.presence == PresenceState.working || person.presence == PresenceState.thinking) ...[
                            const SizedBox(width: Space.x2),
                            _LiveIndicator(color: presenceColor),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: Space.x2),
                // Unread badge
                if (unreadCount > 0)
                  Container(
                    minWidth: 20,
                    height: 20,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    decoration: BoxDecoration(
                      color: presenceColor,
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: Text(
                        unreadCount > 99 ? '99+' : '$unreadCount',
                        style: AppText.captionStyle.copyWith(
                          color: p.bg,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  bool _timeColor(bool hasUnread) => hasUnread ? PresenceStateColors.accent : p.faint;
  Color get p => Palette.of(context);
}

/// Avatar circle with animated presence ring around it.
class _PresenceAvatar extends StatefulWidget {
  const _PresenceAvatar({required this.person, required this.color});
  final DigitalPerson person;
  final Color color;

  @override
  State<_PresenceAvatar> createState() => _PresenceAvatarState();
}

class _PresenceAvatarState extends State<_PresenceAvatar>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _pulse;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );
    _pulse = Tween<double>(begin: 1.0, end: 1.15).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
    if (widget.person.presence == PresenceState.working ||
        widget.person.presence == PresenceState.thinking) {
      _controller.repeat();
    }
  }

  @override
  void didUpdateWidget(_PresenceAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final wasActive = oldWidget.person.presence == PresenceState.working ||
        oldWidget.person.presence == PresenceState.thinking;
    final isActive = widget.person.presence == PresenceState.working ||
        widget.person.presence == PresenceState.thinking;
    if (wasActive != isActive) {
      if (isActive) _controller.repeat();
      else _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, child) {
        final scale = widget.person.isActive ? _pulse.value : 1.0;
        return Stack(
          children: [
            // Pulse ring (only when active)
            if (widget.person.isActive)
              Positioned.fill(
                child: Transform.scale(
                  scale: scale,
                  child: Container(
                    margin: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: widget.color.withValues(alpha: 0.4), width: 2),
                    ),
                  ),
                ),
              ),
            // Main avatar
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    widget.color.withValues(alpha: 0.3),
                    widget.color,
                  ],
                  stops: const [0.6, 1.0],
                ),
                boxShadow: [
                  BoxShadow(
                    color: widget.color.withValues(alpha: 0.2),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Center(
                child: Text(
                  widget.person.name.isNotEmpty
                      ? widget.person.name[0].toUpperCase()
                      : '?',
                  style: Brand.display(size: 24, color: p.bg),
                ),
              ),
            ),
            // Online dot
            if (widget.person.isActive)
              Positioned(
                right: 2,
                bottom: 2,
                child: Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    color: p.bg,
                    shape: BoxShape.circle,
                    border: Border.all(color: widget.color, width: 2),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Tiny animated dots shown when a bot is currently thinking/working.
class _LiveIndicator extends StatefulWidget {
  const _LiveIndicator({required this.color});
  final Color color;

  @override
  State<_LiveIndicator> createState() => _LiveIndicatorState();
}

class _LiveIndicatorState extends State<_LiveIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late List<Animation<double>> _dots;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));
    _dots = List.generate(3, (i) => Tween<double>(begin: 0.3, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: Interval(i * 0.2, 1.0, curve: Curves.easeInOut),
      ),
    ));
    _controller.repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(3, (i) => AnimatedBuilder(
              animation: _dots[i],
              builder: (context, _) => Container(
                margin: const EdgeInsets.symmetric(horizontal: 1.5),
                width: 4,
                height: 4,
                decoration: BoxDecoration(
                  color: widget.color.withValues(alpha: _dots[i].value),
                  shape: BoxShape.circle,
                ),
              ),
            )),
      );
}

/// Color mapping for presence states.
abstract class PresenceStateColors {
  static const Color offline = Color(0xFF9C978E);
  static const Color online = Color(0xFF5E7A4C); // Telesia sage-green
  static const Color thinking = Color(0xFF4A9BD9); // sea-blue
  static const Color working = Color(0xFF3F9A5B); // status working green
  static const Color accent = online;

  static Color colorOf(PresenceState state) => switch (state) {
        PresenceState.offline => offline,
        PresenceState.online => online,
        PresenceState.thinking => thinking,
        PresenceState.working => working,
      };
}
