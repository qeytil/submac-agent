import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../services/billing/billing_copy.dart';
import '../../services/billing/billing_models.dart';
import '../../services/billing/billing_service.dart';
import '../../theme.dart';
import '../../ui/tokens.dart';
import 'get_more_screen.dart';
import 'plan_usage_screen.dart';

/// Section title + rounded card, grouped by spacing (no divider lines, sentence case).
class BillingSection extends StatelessWidget {
  const BillingSection(this.title, this.children, {super.key, this.trailing});
  final String title;
  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.x4, Space.x3, Space.x4, Space.x2),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (title.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: Space.x1, bottom: Space.x2),
            child: Row(children: [
              Expanded(child: Text(title, style: TextStyle(color: p.muted, fontSize: AppText.meta, fontWeight: FontWeight.w600))),
              if (trailing != null) trailing!,
            ]),
          ),
        Container(
          decoration: BoxDecoration(color: p.sheet, borderRadius: BorderRadius.circular(Radii.field)),
          clipBehavior: Clip.antiAlias,
          child: Material(color: Colors.transparent, child: Column(children: children)),
        ),
      ]),
    );
  }
}

/// A small pill: "Best value".
class BillingBadge extends StatelessWidget {
  const BillingBadge(this.text, {super.key, this.strong = false});
  final String text;
  final bool strong;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Space.x2, vertical: 3),
      decoration: BoxDecoration(color: strong ? p.text : p.bubble, borderRadius: BorderRadius.circular(Radii.sheet)),
      child: Text(text, style: TextStyle(color: strong ? p.bg : p.text, fontSize: AppText.caption, fontWeight: FontWeight.w600)),
    );
  }
}

/// The old coin chip in the chat header. Coins are gone (PLAN 2.1), so this renders nothing. Kept only so
/// lib/screens/home_screen.dart (Dev 3) still compiles; Dev 3 removes the `const WalletChip()` line, then this class.
@Deprecated('Coins are gone. Remove the chip from the chat header.')
class WalletChip extends StatelessWidget {
  const WalletChip({super.key, this.billing});
  final Billing? billing;
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// Settings: the "Plan & usage" row. Only exists while billing is on (renders nothing at all otherwise).
class BillingSettingsEntry extends StatelessWidget {
  const BillingSettingsEntry({super.key, this.billing});
  final Billing? billing;

  @override
  Widget build(BuildContext context) {
    final b = billing ?? Billing.I;
    return ValueListenableBuilder<bool>(
      valueListenable: b.enabled,
      builder: (context, on, _) {
        if (!on) return const SizedBox.shrink();
        return ValueListenableBuilder<UsageSummary?>(
          valueListenable: b.usage,
          builder: (context, s, _) {
            final p = Palette.of(context);
            return BillingSection('', [
              ListTile(
                key: const ValueKey('billing-settings-entry'),
                leading: Icon(Icons.data_usage_rounded, color: p.text),
                title: Text(tr('Plan & usage')),
                subtitle: s == null ? null : Text(s.planLabel),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => openPlanUsage(context, billing: billing),
              ),
            ]);
          },
        );
      },
    );
  }
}

/// A short, light burst of dots for a successful payment (no package, ~1 s, respects reduced motion).
class ConfettiLite extends StatefulWidget {
  const ConfettiLite({super.key, this.size = 160});
  final double size;
  @override
  State<ConfettiLite> createState() => _ConfettiLiteState();
}

class _ConfettiLiteState extends State<ConfettiLite> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (MediaQuery.maybeOf(context)?.disableAnimations == true) {
        _c.value = 1;
      } else {
        _c.forward();
      }
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return IgnorePointer(
      child: SizedBox.square(
        dimension: widget.size,
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) => CustomPaint(painter: _BurstPainter(_c.value, [p.text, Palette.red, p.accent, p.muted])),
        ),
      ),
    );
  }
}

class _BurstPainter extends CustomPainter {
  _BurstPainter(this.t, this.colors);
  final double t;
  final List<Color> colors;
  @override
  void paint(Canvas canvas, Size size) {
    if (t <= 0 || t >= 1) return;
    final c = size.center(Offset.zero);
    final ease = Curves.easeOutCubic.transform(t);
    for (var i = 0; i < 18; i++) {
      final a = i * (math.pi * 2 / 18) + (i.isEven ? 0.12 : -0.08);
      final r = size.width * 0.12 + size.width * 0.36 * ease * (0.75 + (i % 3) * 0.12);
      final o = c + Offset(math.cos(a) * r, math.sin(a) * r + 18 * t * t);
      final paint = Paint()..color = colors[i % colors.length].withValues(alpha: (1 - t).clamp(0.0, 1.0));
      canvas.drawCircle(o, 3.2 - 1.6 * t, paint);
    }
  }

  @override
  bool shouldRepaint(_BurstPainter old) => old.t != t;
}

/// Plain one-line error + action, used across the billing screens.
class BillingMessage extends StatelessWidget {
  const BillingMessage(this.text, {super.key, this.icon = Icons.info_outline_rounded, this.action, this.onAction, this.warn = false});
  final String text;
  final IconData icon;
  final String? action;
  final VoidCallback? onAction;
  final bool warn;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: BoxDecoration(
        color: warn ? p.accentWash : p.bubble,
        borderRadius: BorderRadius.circular(Radii.field),
      ),
      child: Row(children: [
        Icon(icon, size: 18, color: warn ? p.accent : p.muted),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: TextStyle(color: p.text, fontSize: AppText.meta, height: 1.35))),
        if (action != null) TextButton(onPressed: onAction, child: Text(action!)),
      ]),
    );
  }
}

/// Plan & usage (today left, total left, resets at, plan, Get more).
void openPlanUsage(BuildContext context, {Billing? billing}) =>
    Navigator.push(context, MaterialPageRoute(builder: (_) => PlanUsageScreen(billing: billing)));

/// Get more: Packages and Pay as you go.
Future<bool?> openGetMore(BuildContext context, {Billing? billing, bool payg = false}) =>
    Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => GetMoreScreen(billing: billing, startOnPayg: payg)));
