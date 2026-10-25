import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/billing/billing_copy.dart';
import '../../services/billing/billing_models.dart';
import '../../services/billing/billing_service.dart';
import '../../theme.dart';
import '../../ui/tokens.dart';
import 'billing_widgets.dart';
import 'pay_screen.dart';

/// Get more: two tabs. Packages (Weekly / Monthly: price, replies a day, replies in total) and Pay as you go (amount
/// picker with the live price). Prices and amounts come from billing.plans. Pops with true after a payment.
class GetMoreScreen extends StatefulWidget {
  const GetMoreScreen({super.key, this.billing, this.startOnPayg = false});
  final Billing? billing;
  final bool startOnPayg;
  @override
  State<GetMoreScreen> createState() => _GetMoreScreenState();
}

class _GetMoreScreenState extends State<GetMoreScreen> {
  Billing get b => widget.billing ?? Billing.I;
  int? _tokens;

  @override
  void initState() {
    super.initState();
    if (b.usage.value == null || b.usage.value!.plans.isEmpty) unawaited(b.refreshUsage());
  }

  Future<void> _buy(PlanInfo plan, {int? tokens}) async {
    HapticFeedback.selectionClick();
    final paid = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => PayScreen(plan: plan, tokens: tokens, billing: widget.billing)),
    );
    if (paid == true && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return DefaultTabController(
      length: 2,
      initialIndex: widget.startOnPayg ? 1 : 0,
      child: Scaffold(
        appBar: AppBar(
          title: Text(tr('Get more'), style: Brand.serif(size: AppText.display, color: p.text)),
          bottom: TabBar(tabs: [Tab(text: tr('Packages')), Tab(text: tr('Pay as you go'))]),
        ),
        body: ValueListenableBuilder<UsageSummary?>(
          valueListenable: b.usage,
          builder: (context, s, _) {
            if (s == null || s.plans.isEmpty) {
              return Center(child: TextButton(onPressed: () => b.refreshUsage(), child: Text(tr('Try again'))));
            }
            return TabBarView(children: [_packages(s, p), _payg(s, p)]);
          },
        ),
      ),
    );
  }

  Widget _packages(UsageSummary s, Palette p) {
    final per = s.tokensPerReply;
    final plans = s.packagePlans;
    if (plans.isEmpty) return Center(child: Text(tr('Nothing here yet.'), style: TextStyle(color: p.muted, fontSize: AppText.body)));
    return ListView(padding: const EdgeInsets.only(top: Space.x2, bottom: Space.x6), children: [
      for (final x in plans)
        BillingSection('', [
          ListTile(
            key: ValueKey('billing-plan-${x.id}'),
            contentPadding: const EdgeInsets.symmetric(horizontal: Space.x4, vertical: Space.x2),
            title: Text(x.label, style: TextStyle(color: p.text, fontSize: AppText.lead, fontWeight: FontWeight.w600)),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: Space.x1),
              child: Text(
                '${tr('{x} a day', {'x': repliesText(x.dailyTokens, perReply: per)})}\n'
                '${tr('{x} in total', {'x': repliesText(x.totalTokens, perReply: per)})} · ${x.validityText}',
                style: TextStyle(color: p.muted, fontSize: AppText.meta, height: 1.4),
              ),
            ),
            trailing: Text(usdText(x.priceUsd), style: TextStyle(color: p.text, fontSize: AppText.lead, fontWeight: FontWeight.w600)),
            onTap: () => _buy(x),
          ),
        ]),
    ]);
  }

  Widget _payg(UsageSummary s, Palette p) {
    final plan = s.paygPlan;
    if (plan == null || plan.maxTokens <= 0) {
      return Center(child: Text(tr('Nothing here yet.'), style: TextStyle(color: p.muted, fontSize: AppText.body)));
    }
    final n = plan.clampTokens(_tokens ?? (plan.presets.isNotEmpty ? plan.presets.first : plan.minTokens));
    final steps = plan.stepTokens > 0 ? ((plan.maxTokens - plan.minTokens) ~/ plan.stepTokens) : 0;
    return ListView(padding: const EdgeInsets.fromLTRB(Space.x4, Space.x5, Space.x4, Space.x6), children: [
      Center(
        child: Text(tokensShort(n), key: const ValueKey('billing-payg-amount'), style: Brand.serif(size: AppText.displayLarge, color: p.text)),
      ),
      const SizedBox(height: Space.x1),
      Center(child: Text(repliesText(n, perReply: s.tokensPerReply), style: TextStyle(color: p.muted, fontSize: AppText.body))),
      const SizedBox(height: Space.x4),
      if (steps > 0)
        Slider(
          key: const ValueKey('billing-payg-slider'),
          value: n.toDouble(),
          min: plan.minTokens.toDouble(),
          max: plan.maxTokens.toDouble(),
          divisions: steps,
          onChanged: (v) => setState(() => _tokens = plan.clampTokens(v.round())),
        ),
      Wrap(alignment: WrapAlignment.center, spacing: Space.x2, runSpacing: Space.x2, children: [
        for (final x in plan.presets)
          ChoiceChip(
            key: ValueKey('billing-payg-preset-$x'),
            label: Text(tokensShort(x)),
            selected: n == x,
            onSelected: (_) => setState(() => _tokens = x),
          ),
      ]),
      const SizedBox(height: Space.x5),
      Center(
        child: Text(tr('Valid {x}', {'x': plan.validityText}), style: TextStyle(color: p.muted, fontSize: AppText.meta)),
      ),
      const SizedBox(height: Space.x4),
      FilledButton(
        key: const ValueKey('billing-payg-buy'),
        style: FilledButton.styleFrom(backgroundColor: p.text, foregroundColor: p.bg, minimumSize: const Size(double.infinity, 52)),
        onPressed: () => _buy(plan, tokens: n),
        child: Text(tr('Pay {usd}', {'usd': usdText(plan.priceFor(n))})),
      ),
    ]);
  }
}
