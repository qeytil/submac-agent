import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/billing/billing_copy.dart';
import '../../services/billing/billing_models.dart';
import '../../services/billing/billing_service.dart';
import '../../services/billing/payment_flow.dart';
import '../../theme.dart';
import '../../ui/tokens.dart';
import 'billing_widgets.dart';
import 'payment_screen.dart';

/// One Sifalo step: pay for a package or a pay-as-you-go amount on Sifalo's own checkout page (opened inside the
/// app). Sifalo's page offers every way to pay it supports, so the app offers no payment methods of its own.
/// Pops with true when paid.
class PayScreen extends StatefulWidget {
  const PayScreen({super.key, required this.plan, this.tokens, this.billing});
  final PlanInfo plan;
  final int? tokens;
  final Billing? billing;
  @override
  State<PayScreen> createState() => _PayScreenState();
}

class _PayScreenState extends State<PayScreen> {
  bool _opening = false;

  PlanInfo get plan => widget.plan;
  int? get _tokens => plan.isPayg ? widget.tokens : null;
  double get _price => plan.priceFor(_tokens ?? 0);
  String get _title => plan.isPayg ? tokensShort(_tokens ?? 0) : plan.name;

  Future<void> _pay() async {
    if (_opening) return;
    setState(() => _opening = true);
    HapticFeedback.selectionClick();
    final req = PaymentRequest(
      planId: plan.id,
      tokens: _tokens,
      title: _title,
      amountUsd: _price,
      method: 'checkout',
      walletLabel: 'Sifalo',
    );
    final paid = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => PaymentScreen(request: req, billing: widget.billing)));
    if (!mounted) return;
    setState(() => _opening = false);
    if (paid == true) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(tr('Pay'), style: Brand.serif(size: AppText.display, color: p.text))),
      body: Column(children: [
        Expanded(
          child: ListView(padding: const EdgeInsets.only(bottom: Space.x4), children: [
            BillingSection('', [
              ListTile(
                key: const ValueKey('billing-pay-item'),
                title: Text(_title, style: TextStyle(color: p.text, fontWeight: FontWeight.w600)),
                subtitle: Text(plan.isPayg ? tr('Valid {x}', {'x': plan.validityText}) : plan.validityText),
                trailing: Text(usdText(_price), style: TextStyle(color: p.text, fontSize: AppText.body, fontWeight: FontWeight.w600)),
              ),
            ]),
            Padding(
              key: const ValueKey('billing-pay-sifalo-note'),
              padding: const EdgeInsets.fromLTRB(Space.x4, Space.x2, Space.x4, 0),
              child: Text(tr("You'll finish paying on Sifalo's secure page."), style: TextStyle(color: p.muted, fontSize: AppText.micro)),
            ),
          ]),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Space.x4, Space.x2, Space.x4, Space.x3),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const ValueKey('billing-pay-button'),
                style: FilledButton.styleFrom(backgroundColor: p.text, foregroundColor: p.bg, minimumSize: const Size(0, 52)),
                onPressed: _opening ? null : _pay,
                child: Text(tr('Pay {usd}', {'usd': usdText(_price)})),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}
