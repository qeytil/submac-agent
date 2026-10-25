import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/billing/billing_copy.dart';
import '../../services/billing/billing_models.dart';
import '../../services/billing/billing_service.dart';
import '../../services/billing/payment_flow.dart';
import '../../services/billing/somali_wallet.dart';
import '../../theme.dart';
import '../../ui/tokens.dart';
import 'billing_widgets.dart';
import 'payment_screen.dart';

/// Plan & usage: today left, total left, when it resets, the current plan, and one Get more button.
/// Counts replies, never tokens. Payments still being confirmed are listed with "Check now".
class PlanUsageScreen extends StatefulWidget {
  const PlanUsageScreen({super.key, this.billing});
  final Billing? billing;
  @override
  State<PlanUsageScreen> createState() => _PlanUsageScreenState();
}

class _PlanUsageScreenState extends State<PlanUsageScreen> {
  Billing get b => widget.billing ?? Billing.I;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    if (_loading) return;
    setState(() => _loading = true);
    await b.refreshUsage();
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _getMore() async {
    final paid = await openGetMore(context, billing: widget.billing);
    if (paid == true) unawaited(_refresh());
  }

  void _checkPending(PendingPurchase a) {
    final w = MobileWallet.all.where((x) => x.gateway == a.wallet && x.label == a.walletLabel).firstOrNull;
    final plan = b.usage.value?.planById(a.product);
    final req = PaymentRequest(
      planId: a.product,
      tokens: a.tokens,
      title: a.tokens != null ? tokensShort(a.tokens!) : (plan?.label ?? tr('Payment')),
      amountUsd: plan == null ? 0 : plan.priceFor(a.tokens ?? 0),
      method: a.method,
      gateway: a.wallet,
      walletLabel: w?.label ?? a.walletLabel,
      account: a.account,
    );
    Navigator.push(context, MaterialPageRoute(builder: (_) => PaymentScreen(request: req, billing: widget.billing)))
        .then((_) => _refresh());
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(tr('Plan & usage'), style: Brand.serif(size: AppText.display, color: p.text))),
      body: ValueListenableBuilder<UsageSummary?>(
        valueListenable: b.usage,
        builder: (context, s, _) {
          if (s == null) {
            return Center(
              child: _loading
                  ? const CircularProgressIndicator()
                  : TextButton(key: const ValueKey('billing-usage-retry'), onPressed: _refresh, child: Text(tr('Try again'))),
            );
          }
          final per = s.tokensPerReply;
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(padding: const EdgeInsets.only(bottom: Space.x6), children: [
              BillingSection('', [
                _row(tr('Today left'), repliesText(s.todayLeft, perReply: per), p, key: 'billing-today-left'),
                _row(tr('Total left'), repliesText(s.totalLeft, perReply: per), p, key: 'billing-total-left'),
                if (s.resetsAt != null) _row(tr('Resets at'), clockText(s.resetsAt!), p, key: 'billing-resets-at'),
                _row(tr('Plan'), s.planLabel, p, key: 'billing-plan'),
                if (s.packageEndsAt != null) _row(tr('Ends'), dayText(s.packageEndsAt!), p, key: 'billing-ends'),
              ]),
              ValueListenableBuilder<List<PendingPurchase>>(
                valueListenable: b.pending,
                builder: (context, list, _) {
                  final open = list.where((a) => a.purchaseId != null).toList();
                  if (open.isEmpty) return const SizedBox.shrink();
                  return BillingSection(tr('Being confirmed'), [
                    for (final a in open)
                      ListTile(
                        key: ValueKey('billing-pending-${a.purchaseId}'),
                        title: Text(a.tokens != null ? tokensShort(a.tokens!) : (s.planById(a.product)?.label ?? planName(a.product))),
                        trailing: TextButton(onPressed: () => _checkPending(a), child: Text(tr('Check now'))),
                      ),
                  ]);
                },
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(Space.x4, Space.x4, Space.x4, 0),
                child: FilledButton(
                  key: const ValueKey('billing-get-more'),
                  style: FilledButton.styleFrom(backgroundColor: p.text, foregroundColor: p.bg, minimumSize: const Size(double.infinity, 52)),
                  onPressed: _getMore,
                  child: Text(tr('Get more')),
                ),
              ),
            ]),
          );
        },
      ),
    );
  }

  Widget _row(String label, String value, Palette p, {required String key}) => ListTile(
        key: ValueKey(key),
        title: Text(label, style: TextStyle(color: p.muted, fontSize: AppText.body)),
        trailing: Text(value, style: TextStyle(color: p.text, fontSize: AppText.body, fontWeight: FontWeight.w600)),
      );
}
