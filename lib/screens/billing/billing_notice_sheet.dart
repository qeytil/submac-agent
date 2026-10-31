import 'package:flutter/material.dart';

import '../../services/billing/billing_copy.dart';
import '../../services/billing/billing_models.dart';
import '../../services/billing/billing_service.dart';
import '../../theme.dart';
import '../../ui/tokens.dart';
import 'get_more_screen.dart';

/// The short sheet shown when a chat reply is refused for a usage reason: one line, when it resets (midnight EAT, shown
/// on the phone's clock), and Get more. Info-only for busy.
Future<void> showBillingNoticeSheet(BuildContext context, BillingNotice n, {Billing? billing, VoidCallback? onRetry}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => BillingNoticeSheet(notice: n, billing: billing, onRetry: onRetry),
  );
}

class BillingNoticeSheet extends StatefulWidget {
  const BillingNoticeSheet({super.key, required this.notice, this.billing, this.onRetry});
  final BillingNotice notice;
  final Billing? billing;
  final VoidCallback? onRetry;
  @override
  State<BillingNoticeSheet> createState() => _BillingNoticeSheetState();
}

class _BillingNoticeSheetState extends State<BillingNoticeSheet> {
  Billing get b => widget.billing ?? Billing.I;

  void _getMore() {
    final nav = Navigator.of(context);
    nav.pop();
    nav.push(MaterialPageRoute(builder: (_) => GetMoreScreen(billing: widget.billing)));
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final n = widget.notice;
    final reset = n.resetLine();
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Space.x5, 0, Space.x5, Space.x4),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(n.title, key: const ValueKey('billing-notice-title'), style: Brand.serif(size: AppText.title, color: p.text)),
          if (reset.isNotEmpty) ...[
            const SizedBox(height: Space.x2),
            Text(reset, key: const ValueKey('billing-reset-line'), style: TextStyle(color: p.muted, fontSize: AppText.body)),
          ],
          const SizedBox(height: Space.x4),
          ..._buttons(n, p),
        ]),
      ),
    );
  }

  List<Widget> _buttons(BillingNotice n, Palette p) {
    final style = FilledButton.styleFrom(backgroundColor: p.text, foregroundColor: p.bg, minimumSize: const Size(double.infinity, 50));
    switch (n.code) {
      case 'busy':
        return [
          FilledButton(
            style: style,
            onPressed: () {
              Navigator.of(context).pop();
              widget.onRetry?.call();
            },
            child: Text(tr('Try again')),
          ),
        ];
      default:
        return [
          FilledButton(key: const ValueKey('billing-notice-get-more'), style: style, onPressed: _getMore, child: Text(tr('Get more'))),
          TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(tr('Not now'))),
        ];
    }
  }
}

/// The calm card a refused chat reply shows instead of the generic error card.
class BillingNoticeCard extends StatefulWidget {
  const BillingNoticeCard({super.key, required this.notice, this.isLast = false, this.onRetry, this.billing});
  final BillingNotice notice;
  final bool isLast;
  final VoidCallback? onRetry;
  final Billing? billing;
  @override
  State<BillingNoticeCard> createState() => _BillingNoticeCardState();
}

class _BillingNoticeCardState extends State<BillingNoticeCard> {
  Billing get b => widget.billing ?? Billing.I;

  @override
  void initState() {
    super.initState();
    // One message rule (owner, 2026-10-31): the refusal is the card in the chat — nothing pops up,
    // nothing extra sits above the composer. The card carries Get more / Details itself.
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final n = widget.notice;
    final reset = n.resetLine();
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 4),
      decoration: BoxDecoration(color: p.sheet, border: Border.all(color: p.border), borderRadius: BorderRadius.circular(Radii.field)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(n.isInfo ? Icons.hourglass_top_rounded : Icons.data_usage_rounded, size: IconSize.sm, color: p.muted),
          const SizedBox(width: 8),
          Expanded(child: Text(n.title, style: TextStyle(color: p.text, fontSize: AppText.meta, fontWeight: FontWeight.w600))),
        ]),
        if (reset.isNotEmpty)
          Padding(padding: const EdgeInsets.only(left: 24, top: 3, right: 6), child: Text(reset, style: TextStyle(color: p.muted, fontSize: AppText.micro))),
        Padding(
          padding: const EdgeInsets.only(left: 14),
          child: Wrap(children: [
            TextButton(
              onPressed: () => showBillingNoticeSheet(context, n, billing: widget.billing, onRetry: widget.onRetry),
              child: Text(tr(n.isInfo ? 'Details' : 'Get more')),
            ),
            if (widget.isLast && widget.onRetry != null && n.code == 'busy')
              TextButton(onPressed: widget.onRetry, child: Text(tr('Try again'))),
          ]),
        ),
      ]),
    );
  }
}

