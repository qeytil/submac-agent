import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/billing/billing_copy.dart';
import '../../services/billing/billing_models.dart';
import '../../services/billing/billing_service.dart';
import '../../services/billing/pay_update.dart';
import '../../services/billing/payment_flow.dart';
import '../../services/billing/somali_wallet.dart';
import '../../theme.dart';
import '../../ui/tokens.dart';
import 'billing_widgets.dart';
import 'checkout_webview_screen.dart';

/// One payment, from "starting" to "added": approve-on-phone countdown, polling, retry, in-app card page.
/// Pops with true when paid.
class PaymentScreen extends StatefulWidget {
  const PaymentScreen({super.key, required this.request, this.billing, this.resumePurchaseId, this.openCheckout});
  final PaymentRequest request;
  final Billing? billing;

  /// Continue a payment started earlier (wallet "Check now"): check it instead of starting a new one.
  final String? resumePurchaseId;

  /// Tests replace the in-app payment page.
  final OpenCheckout? openCheckout;

  @override
  State<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends State<PaymentScreen> {
  late final Billing b = widget.billing ?? Billing.I;
  late final PaymentFlow flow;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    flow = PaymentFlow(b, widget.request, openCheckout: widget.openCheckout ?? _openCheckout);
    flow.addListener(_changed);
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && flow.state.phase == PayPhase.approve) setState(() {});
    });
    // An unsettled attempt for the same product, wallet and number (e.g. "Check now" in the wallet, or a retry
    // after the app was killed) is picked up with its idempotency key and purchase id: never a second charge.
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(flow.start()));
  }

  PayPhase? _lastPhase;
  void _changed() {
    if (!mounted) return;
    final ph = flow.state.phase;
    if (ph != _lastPhase) {
      if (ph == PayPhase.success) HapticFeedback.mediumImpact();
      if (ph == PayPhase.failed) HapticFeedback.heavyImpact();
      _lastPhase = ph;
    }
    setState(() {});
  }

  Future<CheckoutExit> _openCheckout(String url, String purchaseId) async {
    if (!mounted) return const CheckoutExit(CheckoutExitKind.cancelled);
    final r = await Navigator.push<CheckoutExit>(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => CheckoutWebViewScreen(
          url: url,
          purchaseId: purchaseId,
          functionsHost: b.functionsHost,
          onCheck: () => b.check(purchaseId),
          onReturnUrl: b.touchReturn,
        ),
      ),
    );
    return r ?? const CheckoutExit(CheckoutExitKind.cancelled);
  }

  @override
  void dispose() {
    _tick?.cancel();
    flow.removeListener(_changed);
    flow.dispose();
    super.dispose();
  }

  String get _who {
    final r = widget.request;
    if (!r.isWallet) return 'Sifalo';
    return '${r.walletLabel ?? tr('wallet')} ${r.account == null ? '' : formatSomaliMobile(r.account!)}'.trim();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final s = flow.state;
    final pending = s.pending || s.phase == PayPhase.starting;
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop && pending && flow.purchaseId != null) {
          final m = ScaffoldMessenger.maybeOf(context);
          m?.showSnackBar(SnackBar(content: Text(tr('Confirming…'))));
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.request.title, style: Brand.serif(size: AppText.display, color: p.text)),
          leading: IconButton(
            tooltip: tr('Close'),
            icon: const Icon(Icons.close_rounded),
            onPressed: () => Navigator.maybePop(context, s.phase == PayPhase.success),
          ),
        ),
        body: SafeArea(
          child: Column(children: [
            if (flow.offlineNow)
              BillingMessage(tr("You're offline. We'll check again when you're back."), icon: Icons.wifi_off_rounded, warn: true),
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    child: KeyedSubtree(key: ValueKey(s.phase), child: _body(s, p)),
                  ),
                ),
              ),
            ),
            Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 16), child: _actions(s, p)),
          ]),
        ),
      ),
    );
  }

  Widget _icon(IconData i, Palette p, {Color? color}) => Container(
        width: 72,
        height: 72,
        decoration: BoxDecoration(color: p.bubble, shape: BoxShape.circle),
        child: Icon(i, size: 34, color: color ?? p.text),
      );

  Widget _title(String t, Palette p) =>
      Text(t, textAlign: TextAlign.center, style: Brand.serif(size: AppText.displayLarge, color: p.text, height: 1.15));

  Widget _text(String t, Palette p) => Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Text(t, textAlign: TextAlign.center, style: TextStyle(color: p.muted, fontSize: AppText.body, height: 1.4)),
      );

  Widget _body(PayUpdate s, Palette p) {
    final amount = usdText(widget.request.amountUsd);
    switch (s.phase) {
      case PayPhase.idle:
      case PayPhase.starting:
        return Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox.square(dimension: 44, child: CircularProgressIndicator(strokeWidth: 3)),
          const SizedBox(height: 20),
          _title(tr('Starting your payment'), p),
          _text('$amount with $_who', p),
        ]);
      case PayPhase.approve:
        final left = flow.approveLeft;
        final mm = left.inMinutes, ss = left.inSeconds % 60;
        final frac = flow.approveWindow.inSeconds == 0 ? 0.0 : left.inSeconds / flow.approveWindow.inSeconds;
        return Column(mainAxisSize: MainAxisSize.min, children: [
          _icon(Icons.phone_iphone_rounded, p),
          const SizedBox(height: 18),
          _title(tr('Approve on your phone'), p),
          _text(tr('We sent {amount} to {who}. Enter your PIN to pay.', {'amount': amount, 'who': _who}), p),
          const SizedBox(height: 18),
          if (left > Duration.zero) ...[
            Text('$mm:${ss.toString().padLeft(2, '0')}', key: const ValueKey('billing-countdown'), style: Brand.mono(size: 22, color: p.text)),
            const SizedBox(height: 8),
            SizedBox(
              width: 180,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(Radii.sm),
                child: LinearProgressIndicator(value: frac.clamp(0.0, 1.0), minHeight: 5, backgroundColor: p.border, color: p.text),
              ),
            ),
          ] else
            Text(tr('Still waiting for your approval…'), style: TextStyle(color: p.text, fontSize: AppText.meta)),
          const SizedBox(height: 12),
          Text(tr('No prompt? Check your number.'), textAlign: TextAlign.center, style: TextStyle(color: p.muted, fontSize: AppText.micro)),
        ]);
      case PayPhase.checkout:
        return Column(mainAxisSize: MainAxisSize.min, children: [
          _icon(Icons.lock_outline_rounded, p),
          const SizedBox(height: 18),
          _title(tr('Secure payment'), p),
          _text(s.message, p),
        ]);
      case PayPhase.processing:
        return Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox.square(dimension: 44, child: CircularProgressIndicator(strokeWidth: 3)),
          const SizedBox(height: 20),
          _title(tr('Confirming your payment'), p),
          _text(s.message, p),
        ]);
      case PayPhase.stillWaiting:
        return Column(mainAxisSize: MainAxisSize.min, children: [
          _icon(Icons.hourglass_top_rounded, p),
          const SizedBox(height: 18),
          _title(tr('Not confirmed yet'), p),
          _text(s.message, p),
          _text(tr('You can leave this screen.'), p),
        ]);
      case PayPhase.success:
        final added = s.tokensAdded > 0 ? s.tokensAdded : (widget.request.tokens ?? 0);
        return Column(mainAxisSize: MainAxisSize.min, children: [
          Stack(alignment: Alignment.center, children: [
            const ConfettiLite(),
            _icon(Icons.check_rounded, p),
          ]),
          _title(added > 0 && widget.request.tokens != null ? addedText(added) : tr('Done. {x} is ready.', {'x': widget.request.title}), p),
        ]);
      case PayPhase.failed:
        return Column(mainAxisSize: MainAxisSize.min, children: [
          _icon(s.reason == 'insufficient_funds' ? Icons.account_balance_wallet_outlined : Icons.block_rounded, p, color: p.accent),
          const SizedBox(height: 18),
          _title(tr(s.reason == 'insufficient_funds' ? 'Not enough money' : s.reason == 'expired' ? 'Payment timed out' : "Payment didn't go through"), p),
          _text(s.message, p),
        ]);
      case PayPhase.offline:
        return Column(mainAxisSize: MainAxisSize.min, children: [
          _icon(Icons.wifi_off_rounded, p),
          const SizedBox(height: 18),
          _title(tr(s.reason == 'timeout' ? 'No answer yet' : "You're offline"), p),
          _text(s.message, p),
        ]);
      case PayPhase.error:
        return Column(mainAxisSize: MainAxisSize.min, children: [
          _icon(Icons.error_outline_rounded, p),
          const SizedBox(height: 18),
          _title(tr("Couldn't start the payment"), p),
          _text(s.message, p),
        ]);
    }
  }

  Widget _actions(PayUpdate s, Palette p) {
    final busy = flow.busy;
    Widget primary(String label, VoidCallback? onTap, {Key? key}) => SizedBox(
          width: double.infinity,
          child: FilledButton(
            key: key,
            style: FilledButton.styleFrom(backgroundColor: p.text, foregroundColor: p.bg, minimumSize: const Size(0, 52)),
            onPressed: busy ? null : onTap,
            child: busy ? SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2, color: p.bg)) : Text(label),
          ),
        );
    Widget secondary(String label, VoidCallback? onTap, {Key? key}) =>
        TextButton(key: key, onPressed: busy ? null : onTap, child: Text(label));
    final isCard = widget.request.method == 'checkout';
    switch (s.phase) {
      case PayPhase.idle:
      case PayPhase.starting:
        return const SizedBox(height: 52);
      case PayPhase.approve:
      case PayPhase.processing:
        return secondary(isCard ? 'I\'ve paid, check now' : 'I\'ve approved, check now', flow.checkNow, key: const ValueKey('billing-check-now'));
      case PayPhase.checkout:
      case PayPhase.stillWaiting:
        return Column(mainAxisSize: MainAxisSize.min, children: [
          primary(isCard ? 'I\'ve paid, check now' : 'Check now', flow.checkNow, key: const ValueKey('billing-check-now')),
          if (isCard) secondary(tr('Open the payment page again'), flow.retry),
        ]);
      case PayPhase.success:
        return primary('Done', () => Navigator.pop(context, true), key: const ValueKey('billing-done'));
      case PayPhase.failed:
      case PayPhase.offline:
      case PayPhase.error:
        return Column(mainAxisSize: MainAxisSize.min, children: [
          primary('Try again', flow.retry, key: const ValueKey('billing-retry')),
          if (s.phase != PayPhase.offline) secondary(tr('Choose another way to pay'), () => Navigator.pop(context, false)),
        ]);
    }
  }
}
