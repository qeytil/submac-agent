import 'dart:async';

import 'package:agent/screens/billing/billing_notice_sheet.dart';
import 'package:agent/screens/billing/billing_widgets.dart';
import 'package:agent/screens/billing/checkout_webview_screen.dart';
import 'package:agent/screens/billing/payment_screen.dart';
import 'package:agent/screens/billing/get_more_screen.dart';
import 'package:agent/screens/billing/pay_screen.dart';
import 'package:agent/screens/billing/plan_usage_screen.dart';
import 'package:agent/services/billing/billing_models.dart';
import 'package:agent/services/billing/billing_service.dart';
import 'package:agent/services/billing/pay_update.dart';
import 'package:agent/services/billing/payment_flow.dart';
import 'package:agent/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_billing_api.dart';

/// Stand-in for the platform web view: the test drives navigations through [hooks].
class FakeWeb implements CheckoutWebController {
  CheckoutWebHooks? hooks;
  int reloads = 0, stops = 0, backs = 0;
  bool canBack = false;
  @override
  Future<void> reload() async => reloads++;
  @override
  Future<bool> canGoBack() async => canBack;
  @override
  Future<void> goBack() async => backs++;
  @override
  Future<void> stopLoading() async => stops++;
}

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 12; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Widget app(Widget child) => MaterialApp(theme: buildTheme(Brightness.light), home: child);

void main() {
  late FakeBillingApi api;
  late Billing b;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    api = FakeBillingApi();
    b = Billing(api: api, sleep: (_) async {});
  });

  group('flag off = nothing', () {
    testWidgets('coin chip is gone; Plan & usage entry only while billing is on', (t) async {
      await t.pumpWidget(app(Scaffold(
        // ignore: deprecated_member_use_from_same_package
        appBar: AppBar(actions: [WalletChip(billing: b)]),
        body: ListView(children: [BillingSettingsEntry(billing: b)]),
      )));
      expect(find.text('Plan & usage'), findsNothing);
      // ignore: deprecated_member_use_from_same_package
      expect(t.getSize(find.byType(WalletChip)), Size.zero);
      expect(t.getSize(find.byType(BillingSettingsEntry, skipOffstage: false)).height, 0);

      b.noteStatus({'enabled': true, 'plan': 'monthly', 'today_left': 1000000, 'tokens_per_reply': 3700});
      await t.pump();
      expect(find.text('Plan & usage'), findsOneWidget);
      expect(find.text('Monthly'), findsOneWidget);
      // ignore: deprecated_member_use_from_same_package
      expect(t.getSize(find.byType(WalletChip)), Size.zero); // still nothing in the chat header

      b.noteStatus(null); // flag flipped back off
      await t.pump();
      expect(find.text('Plan & usage'), findsNothing);
    });
  });

  group('checkout page interception', () {
    late FakeWeb web;
    late List<Uri> external;
    late int checks;
    PayUpdate checkAnswer = const PayUpdate(PayPhase.processing, purchaseId: 'p-7');

    Future<CheckoutExit?> open(WidgetTester t) async {
      CheckoutExit? exit;
      web = FakeWeb();
      external = [];
      checks = 0;
      await t.pumpWidget(app(Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async {
                exit = await Navigator.push<CheckoutExit>(
                  ctx,
                  MaterialPageRoute(
                    builder: (_) => CheckoutWebViewScreen(
                      url: 'https://pay.sifalo.net/checkout/?key=k',
                      purchaseId: 'p-7',
                      functionsHost: 'proj.supabase.co',
                      onCheck: () async {
                        checks++;
                        return checkAnswer;
                      },
                      onReturnUrl: (u) async => api.touched.add(u),
                      openExternal: (u) async => external.add(u),
                      webBuilder: (context, hooks) {
                        web.hooks = hooks;
                        hooks.onCreated(web);
                        return const ColoredBox(color: Colors.white, child: Text('PAGE'));
                      },
                    ),
                  ),
                );
              },
              child: const Text('go'),
            ),
          ),
        ),
      )));
      await t.tap(find.text('go'));
      await settle(t);
      expect(find.text('Secure payment'), findsOneWidget);
      expect(find.byIcon(Icons.lock_rounded), findsOneWidget);
      return exit;
    }

    testWidgets('return URL: stops, closes, sends the return request to the server', (t) async {
      await open(t);
      final h = web.hooks!;
      expect(await h.onNavigate(Uri.parse('https://pay.sifalo.net/next')), isTrue);
      final ret = Uri.parse('https://proj.supabase.co/functions/v1/billing-return?provider=sifalo&purchase=p-7&sid=SID_1');
      final allowed = await h.onNavigate(ret);
      expect(allowed, isFalse);
      await settle(t);
      expect(find.text('Secure payment'), findsNothing);
      expect(web.stops, 1);
      expect(api.touched.single, ret);
      // Further navigations after finishing are ignored.
      expect(await h.onNavigate(Uri.parse('https://pay.sifalo.net/')), isFalse);
    });

    testWidgets('redirect seen only at load start (submac://pay) also finishes', (t) async {
      await open(t);
      expect(web.hooks!.onLoadStart(Uri.parse('submac://pay?status=paid&purchase=11111111-2222-3333-4444-555555555555')), isTrue);
      await settle(t);
      expect(find.text('Secure payment'), findsNothing);
      expect(api.touched, isEmpty); // nothing to send for the app scheme
    });

    testWidgets('outside links open externally, page stays', (t) async {
      await open(t);
      expect(await web.hooks!.onNavigate(Uri.parse('https://www.example.com/help')), isFalse);
      expect(await web.hooks!.onNavigate(Uri.parse('javascript:alert(1)')), isFalse);
      await t.pump();
      expect(external.single.host, 'www.example.com');
      expect(find.text('Secure payment'), findsOneWidget);
    });

    testWidgets('close asks "Cancel payment?" and checks the purchase before leaving', (t) async {
      await open(t);
      await t.tap(find.byKey(const ValueKey('checkout-close')));
      await settle(t);
      expect(find.text('Cancel payment?'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('checkout-keep')));
      await settle(t);
      expect(find.text('Secure payment'), findsOneWidget);
      expect(checks, 0);
      await t.tap(find.byKey(const ValueKey('checkout-close')));
      await settle(t);
      await t.tap(find.byKey(const ValueKey('checkout-cancel')));
      await settle(t);
      expect(checks, 1);
      expect(find.text('Secure payment'), findsNothing);
    });

    testWidgets('back goes back inside the page first', (t) async {
      await open(t);
      web.canBack = true;
      await t.binding.handlePopRoute();
      await settle(t);
      expect(web.backs, 1);
      expect(find.text('Cancel payment?'), findsNothing);
      web.canBack = false;
      await t.binding.handlePopRoute();
      await settle(t);
      expect(find.text('Cancel payment?'), findsOneWidget);
    });

    testWidgets('load error shows retry inside the page', (t) async {
      await open(t);
      web.hooks!.onMainFrameError('net::ERR_INTERNET_DISCONNECTED');
      await t.pump();
      expect(find.text('Couldn\'t load the payment page'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('checkout-retry')));
      await t.pump();
      expect(web.reloads, 1);
      expect(find.text('Couldn\'t load the payment page'), findsNothing);
    });

    testWidgets('"I\'ve paid, check now" from the error view closes when paid', (t) async {
      checkAnswer = const PayUpdate(PayPhase.success, purchaseId: 'p-7', tokensAdded: 2500000);
      await open(t);
      web.hooks!.onMainFrameError('offline');
      await t.pump();
      await t.tap(find.text('I\'ve paid, check now'));
      await settle(t);
      expect(checks, 1);
      expect(find.text('Secure payment'), findsNothing);
      checkAnswer = const PayUpdate(PayPhase.processing, purchaseId: 'p-7');
    });
  });

  group('payment screen', () {
    testWidgets('wallet: countdown, then money added; leaves with true', (t) async {
      api.statusAnswers.addAll([waiting('p-1'), paid('p-1', tokens: 3000000)]);
      final completer = Completer<void>();
      // Hold the second status answer until we have seen the approve screen.
      b = Billing(api: api, sleep: (_) => completer.future);
      const req = PaymentRequest(planId: 'payg', tokens: 3000000, title: '3M', amountUsd: 6, method: 'wallet', gateway: 'waafi', walletLabel: 'EVC Plus', account: '252612345678');
      await t.pumpWidget(app(PaymentScreen(request: req, billing: b)));
      await t.pump();
      await t.pump();
      expect(find.text('Approve on your phone'), findsOneWidget);
      expect(find.textContaining('+252 61 234 5678'), findsWidgets);
      expect(find.byKey(const ValueKey('billing-countdown')), findsOneWidget);
      completer.complete();
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));
      await t.pump(const Duration(seconds: 2));
      expect(find.text('Done. 3M added.'), findsOneWidget);
      expect(find.byType(ConfettiLite), findsOneWidget);
      await t.pump(const Duration(seconds: 2));
    });

    testWidgets('declined shows a friendly message and a single retry', (t) async {
      api.onPost = (_, __) => res(402, {'ok': false, 'purchase_id': 'p-1', 'status': 'failed', 'state': 'failed', 'reason': 'declined'});
      const req = PaymentRequest(planId: 'weekly', title: 'Weekly', amountUsd: 1.25, method: 'wallet', gateway: 'edahab', walletLabel: 'eDahab', account: '252622222222');
      await t.pumpWidget(app(PaymentScreen(request: req, billing: b)));
      await t.pump();
      await t.pump();
      expect(find.text('Payment didn\'t go through'), findsOneWidget);
      expect(find.textContaining('Nothing was taken'), findsOneWidget);
      expect(find.byKey(const ValueKey('billing-retry')), findsOneWidget);
      await t.pump(const Duration(seconds: 2));
    });

    testWidgets('offline start shows offline + retry', (t) async {
      api.onPost = (_, __) => res(0, {});
      const req = PaymentRequest(planId: 'weekly', title: 'Weekly', amountUsd: 1.25, method: 'wallet', gateway: 'edahab', walletLabel: 'eDahab', account: '252622222222');
      await t.pumpWidget(app(PaymentScreen(request: req, billing: b)));
      await t.pump();
      await t.pump();
      expect(find.text('You\'re offline'), findsOneWidget);
      expect(find.byKey(const ValueKey('billing-retry')), findsOneWidget);
      await t.pump(const Duration(seconds: 2));
    });
  });

  group('get more + pay', () {
    testWidgets('packages: price, replies a day and in total; never "unlimited" or "tokens"', (t) async {
      api.rpcAnswers['billing_usage'] = (_) => usageJson();
      await b.refreshUsage();
      await t.pumpWidget(app(GetMoreScreen(billing: b)));
      await t.pump();
      await t.pump();
      expect(find.text('Packages'), findsOneWidget);
      expect(find.text('Pay as you go'), findsOneWidget);
      expect(find.text('Weekly'), findsOneWidget);
      expect(find.text('\$1.25'), findsOneWidget);
      expect(find.text('\$4.99'), findsOneWidget);
      expect(find.textContaining('About 54 replies a day'), findsOneWidget); // 200k / 3700
      expect(find.textContaining('About 810 replies in total'), findsOneWidget); // Monthly 3M
      expect(find.textContaining('nlimited'), findsNothing);
      expect(find.textContaining('token'), findsNothing);
    });

    testWidgets('pay as you go: presets and live price', (t) async {
      api.rpcAnswers['billing_usage'] = (_) => usageJson();
      await b.refreshUsage();
      await t.pumpWidget(app(GetMoreScreen(billing: b, startOnPayg: true)));
      await t.pump();
      await t.pump();
      expect(find.byKey(const ValueKey('billing-payg-amount')), findsOneWidget);
      expect(find.text('Pay \$2.00'), findsOneWidget); // 1M preset
      await t.tap(find.byKey(const ValueKey('billing-payg-preset-5000000')));
      await t.pump();
      expect(find.text('5M'), findsWidgets);
      expect(find.text('Pay \$10.00'), findsOneWidget);
      expect(find.text('About 1,351 replies'), findsOneWidget);
    });

    testWidgets('pay: Sifalo page only, no payment methods of our own', (t) async {
      const plan = PlanInfo(id: 'monthly', kind: 'package', name: 'Monthly', priceUsd: 4.99, totalTokens: 3000000, dailyTokens: 250000, validityDays: 30);
      await t.pumpWidget(app(PayScreen(plan: plan, billing: b)));
      await t.pump();
      FilledButton pay() => t.widget<FilledButton>(find.byKey(const ValueKey('billing-pay-button')));
      expect(find.text('Pay \$4.99'), findsOneWidget);
      expect(find.text('Pay with'), findsNothing);
      expect(find.byKey(const ValueKey('billing-wallet-number')), findsNothing);
      expect(find.byKey(const ValueKey('billing-method-card')), findsNothing);
      expect(find.byType(ChoiceChip), findsNothing);
      expect(pay().onPressed, isNotNull);
    });

    testWidgets('plan & usage: today left, total left, resets at, plan, Get more', (t) async {
      api.rpcAnswers['billing_usage'] = (_) => usageJson(todayLeft: 250000, totalLeft: 2750000, plan: 'monthly');
      await t.pumpWidget(app(PlanUsageScreen(billing: b)));
      await t.pump();
      await t.pump();
      expect(find.text('About 67 replies'), findsOneWidget);
      expect(find.text('About 743 replies'), findsOneWidget);
      expect(find.byKey(const ValueKey('billing-resets-at')), findsOneWidget);
      expect(find.text('Monthly'), findsOneWidget);
      expect(find.byKey(const ValueKey('billing-get-more')), findsOneWidget);
      expect(find.textContaining('coin'), findsNothing);
    });
  });

  group('chat notices', () {
    BillingNotice notice(String code, {String reason = ''}) => BillingNotice.tryParse(429, {
          'error': {'code': code, 'message': 'Server says $code', 'reason': reason},
          'billing': {'reason': reason, 'resets_at': DateTime.now().toUtc().add(const Duration(hours: 5, minutes: 4)).toIso8601String()},
        })!;

    for (final code in [...BillingNotice.knownCodes, 'some_future_code']) {
      testWidgets('sheet for $code renders without crashing', (t) async {
        final n = notice(code);
        await t.pumpWidget(app(Scaffold(body: BillingNoticeSheet(notice: n, billing: b))));
        await t.pump();
        expect(find.byKey(const ValueKey('billing-notice-title')), findsOneWidget);
        if (code == 'limit_daily') {
          expect(find.text('You\'ve used today\'s replies.'), findsOneWidget);
          expect(find.byKey(const ValueKey('billing-reset-line')), findsOneWidget);
          expect(find.textContaining('(in 5 h'), findsOneWidget);
          expect(find.byKey(const ValueKey('billing-notice-get-more')), findsOneWidget);
        }
        if (code == 'busy') expect(find.byKey(const ValueKey('billing-notice-get-more')), findsNothing);
      });
    }

    testWidgets('error card opens the sheet once for a fresh notice', (t) async {
      final n = notice('limit_daily');
      b.noteNotice(n);
      await t.pumpWidget(app(Scaffold(body: BillingNoticeCard(notice: n, isLast: true, billing: b))));
      await t.pumpAndSettle();
      expect(find.byType(BillingNoticeSheet), findsOneWidget);
      Navigator.of(t.element(find.byType(BillingNoticeSheet))).pop();
      await t.pumpAndSettle();
      // Rebuilt card (scrolling back): no second auto-open.
      await t.pumpWidget(app(Scaffold(body: BillingNoticeCard(key: UniqueKey(), notice: n, isLast: true, billing: b))));
      await t.pumpAndSettle();
      expect(find.byType(BillingNoticeSheet), findsNothing);
      expect(find.text('Get more'), findsOneWidget);
    });
  });
}
