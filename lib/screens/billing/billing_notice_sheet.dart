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
    // Raise the banner above the composer once, right when it happens (not when scrolling back to an old refusal).
    // CB-40: never a modal sheet on its own: that covered the composer, so the user could not type.
    final n = widget.notice;
    final fresh = DateTime.now().difference(n.seenAt) < const Duration(seconds: 20);
    if (widget.isLast && fresh && n.code != 'busy' && b.claimAutoShow(n)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => b.banner.value = n);
    }
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

/// CB-40: the refusal, as a small banner just above the composer: what happened, when it resets, Get more, and a
/// close. It never covers the composer, so the user can keep typing (a reply that needs no allowance, or later).
class BillingNoticeBanner extends StatelessWidget {
  const BillingNoticeBanner({super.key, this.billing});
  final Billing? billing;

  @override
  Widget build(BuildContext context) {
    final b = billing ?? Billing.I;
    return ValueListenableBuilder<BillingNotice?>(
      valueListenable: b.banner,
      builder: (context, n, _) {
        if (n == null) return const SizedBox(width: double.infinity);
        final p = Palette.of(context);
        final reset = n.resetLine();
        return Container(
          key: const ValueKey('billing-notice-banner'),
          margin: const EdgeInsets.only(bottom: Space.x2),
          padding: const EdgeInsetsDirectional.fromSTEB(12, 6, 2, 6),
          decoration: BoxDecoration(color: p.sheet, border: Border.all(color: p.border), borderRadius: BorderRadius.circular(Radii.field)),
          child: Row(children: [
            Icon(n.isInfo ? Icons.hourglass_top_rounded : Icons.data_usage_rounded, size: IconSize.sm, color: p.muted),
            const SizedBox(width: 8),
            Expanded(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(n.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.text, fontSize: AppText.meta, fontWeight: FontWeight.w600)),
                if (reset.isNotEmpty) Text(reset, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.muted, fontSize: AppText.micro)),
              ]),
            ),
            if (!n.isInfo)
              TextButton(
                key: const ValueKey('billing-banner-get-more'),
                onPressed: () {
                  b.banner.value = null;
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => GetMoreScreen(billing: billing)));
                },
                child: Text(tr('Get more')),
              ),
            IconButton(
              key: const ValueKey('billing-banner-close'),
              tooltip: tr('Not now'),
              icon: Icon(Icons.close_rounded, size: IconSize.sm, color: p.muted),
              onPressed: () => b.banner.value = null,
            ),
          ]),
        );
      },
    );
  }
}
