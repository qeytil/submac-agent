import 'package:agent/services/billing/billing_api.dart';
import 'package:agent/services/billing/billing_service.dart';
import 'package:agent/services/billing/pay_update.dart';
import 'package:agent/services/billing/payment_flow.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_billing_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeBillingApi api;
  late Billing b;
  const wallet = PaymentRequest(planId: 'payg', tokens: 2500000, title: '2.5M', amountUsd: 5, method: 'wallet', gateway: 'waafi', walletLabel: 'EVC Plus', account: '252612345678');
  const card = PaymentRequest(planId: 'payg', tokens: 2500000, title: '2.5M', amountUsd: 5, method: 'checkout', walletLabel: 'Card');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    api = FakeBillingApi();
    b = Billing(api: api, sleep: (_) async {});
  });

  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('wallet: approve -> poll -> paid', () async {
    api.statusAnswers.addAll([waiting('p-1'), paid('p-1', tokens: 2500000)]);
    final f = PaymentFlow(b, wallet);
    final phases = <PayPhase>[];
    f.addListener(() => phases.add(f.state.phase));
    await f.start();
    expect(f.state.phase, PayPhase.approve);
    expect(f.approveDeadline, isNotNull);
    expect(f.approveLeft.inSeconds, greaterThan(100));
    await settle();
    expect(f.state.phase, PayPhase.success);
    expect(f.state.tokensAdded, 2500000);
    expect(phases.first, PayPhase.starting);
    expect(api.posts.single.body, containsPair('method', 'wallet'));
    expect(api.posts.single.body, containsPair('wallet', 'waafi'));
    f.dispose();
  });

  test('start is ignored while busy (double tap)', () async {
    final f = PaymentFlow(b, wallet);
    final a = f.start();
    final c = f.start();
    await Future.wait([a, c]);
    expect(api.posts.length, 1);
    f.dispose();
  });

  test('offline -> retry reuses the same idempotency key', () async {
    api.onPost = (_, __) => const BillingNetworkError('offline');
    final f = PaymentFlow(b, wallet);
    await f.start();
    expect(f.state.phase, PayPhase.offline);
    final key = f.attemptKey;
    api.onPost = (_, __) => waiting('p-1');
    api.statusAnswers.add(paid('p-1'));
    await f.retry();
    await settle();
    expect(api.posts.map((p) => p.key).toList(), [key, key]);
    expect(f.state.phase, PayPhase.success);
    f.dispose();
  });

  test('declined -> retry starts a fresh attempt', () async {
    api.onPost = (_, __) => res(402, {'ok': false, 'purchase_id': 'p-1', 'status': 'failed', 'state': 'failed', 'reason': 'insufficient_funds'});
    final f = PaymentFlow(b, wallet);
    await f.start();
    expect(f.state.phase, PayPhase.failed);
    expect(f.state.message, contains('enough money'));
    api.onPost = (_, __) => waiting('p-2');
    await f.retry();
    expect(api.posts.length, 2);
    expect(api.posts[0].key, isNot(api.posts[1].key));
    f.dispose();
  });

  test('still waiting -> retry checks the open purchase instead of re-sending', () async {
    final f = PaymentFlow(b, wallet);
    await f.start();
    await settle(); // polls with the default (always waiting) answer until the limit
    expect(f.state.phase, PayPhase.stillWaiting);
    final before = api.statusCalls.length;
    api.statusAnswers.add(paid('p-1'));
    await f.retry();
    await settle();
    expect(api.posts.length, 1);
    expect(api.statusCalls.length, greaterThan(before));
    expect(f.state.phase, PayPhase.success);
    f.dispose();
  });

  test('foreground resume re-checks a pending payment', () async {
    final f = PaymentFlow(b, wallet);
    await f.start();
    await settle();
    expect(f.state.phase, PayPhase.stillWaiting);
    api.statusAnswers.add(paid('p-1'));
    b.resumeTick.value++;
    await settle();
    expect(f.state.phase, PayPhase.success);
    f.dispose();
  });

  test('a lost connection while polling keeps the payment state and flags offline', () async {
    api.statusAnswers.addAll([const BillingNetworkError('offline'), paid('p-1')]);
    final f = PaymentFlow(b, wallet);
    var sawOffline = false;
    f.addListener(() {
      if (f.offlineNow) {
        sawOffline = true;
        expect(f.state.phase, PayPhase.approve);
      }
    });
    await f.start();
    await settle();
    expect(sawOffline, isTrue);
    expect(f.state.phase, PayPhase.success);
    expect(f.offlineNow, isFalse);
    f.dispose();
  });

  test('card: opens the in-app page, then asks the server (never trusts the redirect)', () async {
    api.onPost = (_, __) => res(200, {'ok': true, 'purchase_id': 'p-7', 'status': 'pending', 'state': 'checkout_opened', 'url': 'https://pay.sifalo.net/checkout/?key=k'});
    api.statusAnswers.add(paid('p-7', tokens: 2500000));
    final opened = <(String, String)>[];
    final f = PaymentFlow(b, card, openCheckout: (url, pid) async {
      opened.add((url, pid));
      return const CheckoutExit(CheckoutExitKind.returned);
    });
    await f.start();
    await settle();
    expect(opened.single, ('https://pay.sifalo.net/checkout/?key=k', 'p-7'));
    expect(api.statusCalls, contains('p-7'));
    expect(f.state.phase, PayPhase.success);
    expect(api.posts.single.body.containsKey('method'), isFalse);
    f.dispose();
  });

  test('card: cancelled page with nothing paid -> not finished; retry reopens the same page', () async {
    api.onPost = (_, __) => res(200, {'ok': true, 'purchase_id': 'p-7', 'status': 'pending', 'state': 'checkout_opened', 'url': 'https://pay.sifalo.net/checkout/?key=k'});
    var opens = 0;
    final f = PaymentFlow(b, card, openCheckout: (url, pid) async {
      opens++;
      return CheckoutExit(CheckoutExitKind.cancelled,
          checked: PayUpdate(PayPhase.processing, purchaseId: pid, message: PayText.messageFor(PayPhase.processing, null)));
    });
    await f.start();
    expect(f.state.phase, PayPhase.stillWaiting);
    expect(f.state.message, contains('not finished'));
    await f.retry();
    expect(opens, 2);
    expect(api.posts.length, 1);
    f.dispose();
  });

  test('resume from the wallet: known purchase id is checked, not re-sent', () async {
    final a = await b.beginAttempt(product: 'payg', tokens: 2500000, method: 'wallet', wallet: 'waafi', walletLabel: 'EVC Plus', account: '252612345678');
    await b.submit(a); // p-1, waiting
    expect(api.posts.length, 1);
    api.statusAnswers.add(paid('p-1'));
    final f = PaymentFlow(b, wallet);
    await f.start();
    await settle();
    expect(api.posts.length, 1);
    expect(f.state.phase, PayPhase.success);
    f.dispose();
  });
}
