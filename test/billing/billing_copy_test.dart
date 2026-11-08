import 'dart:io';

import 'package:agent/screens/billing/billing_notice_sheet.dart';
import 'package:agent/services/billing/billing_copy.dart';
import 'package:agent/services/billing/billing_models.dart';
import 'package:agent/services/billing/billing_service.dart';
import 'package:agent/services/billing/pay_update.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_billing_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => BillingCopy.somaliOverride = null);

  test('every billing string the code shows has a Somali line', () {
    final keys = <String>{};
    final lit = RegExp(r'''tr\(\s*(?:'((?:[^'\\]|\\.)*)'|"((?:[^"\\]|\\.)*)")''');
    for (final dir in ['lib/services/billing', 'lib/screens/billing']) {
      for (final f in Directory(dir).listSync().whereType<File>().where((f) => f.path.endsWith('.dart'))) {
        for (final m in lit.allMatches(f.readAsStringSync())) {
          keys.add((m.group(1) ?? m.group(2)!).replaceAll("\\'", "'"));
        }
      }
    }
    // ternaries inside tr(...) and the PayText tables
    keys.addAll(const [
      'About {n} reply', 'Taken back', 'Payment being confirmed', 'Payment not completed', 'Payment refunded', 'Payment',
      'Bots have used their share for today.', 'Still being confirmed.', 'Details', 'Payment timed out', "Payment didn't go through",
      "You're offline", '{n} day', "You're offline. Check your connection and try again.",
      "We haven't received this payment yet. If you just paid, give it a minute.",
    ]);
    expect(keys.length, greaterThan(60));
    final missing = keys.where((k) => !BillingCopy.so.containsKey(k)).toList();
    expect(missing, isEmpty, reason: 'no Somali for: $missing');
    expect(BillingCopy.so.values.where((v) => v.trim().isEmpty), isEmpty);
  });

  test('every PayText reason and phase reads in Somali', () {
    BillingCopy.somaliOverride = true;
    for (final r in ['insufficient_funds', 'declined', 'expired', 'reversed', 'provider_timeout', 'provider_unavailable',
      'provider_config', 'provider_rejected', 'payments_not_configured', 'billing_disabled', 'rate_limited', 'idempotency_key_reused',
      'payment_mismatch', 'sid_not_for_order', 'bad_wallet_account', 'unknown_wallet', 'bad_product', 'unknown_product',
      'auth_required', 'offline', 'timeout', 'service_unavailable', 'not_found']) {
      final m = PayText.messageFor(PayPhase.failed, r);
      expect(BillingCopy.so.containsValue(m), isTrue, reason: '$r -> $m');
    }
    for (final ph in PayPhase.values) {
      final m = PayText.messageFor(ph, null);
      expect(BillingCopy.so.containsValue(m), isTrue, reason: '$ph -> $m');
    }
  });

  test('replies, plans and times in Somali; English by default', () {
    BillingCopy.somaliOverride = false;
    expect(repliesText(1000000), 'About 270 replies');
    expect(planName('weekly'), 'Weekly');
    BillingCopy.somaliOverride = true;
    expect(repliesText(1000000), 'Qiyaastii 270 jawaab');
    expect(planName('payg'), 'Bixi inta aad rabto');
    expect(durationWords(const Duration(hours: 5, minutes: 4)), '5 saac 4 daqiiqo');
    expect(addedText(3000000), 'Waa la dhammeeyay. 3M ayaa lagu daray.');
  });

  testWidgets('limit sheet in Somali: one line, reset line, Get more', (t) async {
    BillingCopy.somaliOverride = true;
    final n = BillingNotice(code: 'limit_daily', resetsAt: DateTime.now().toUtc().add(const Duration(hours: 3)), seenAt: DateTime.now());
    await t.pumpWidget(MaterialApp(home: Scaffold(body: BillingNoticeSheet(notice: n, billing: Billing(api: FakeBillingApi())))));
    await t.pump();
    expect(find.text('Jawaabaha maanta waad dhammaysay.'), findsOneWidget);
    expect(find.textContaining('Dib u bilaabanaya'), findsOneWidget);
    expect(find.text('Iibso dheeraad'), findsOneWidget);
  });

  group('account deletion warning', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('paid balance left -> one short line; none -> null; errors never block', () async {
      BillingCopy.somaliOverride = false;
      final api = FakeBillingApi();
      final b = Billing(api: api);
      api.rpcAnswers['billing_deletion_warning'] = (_) => {'has_paid': true, 'paid_left': 1000000, 'tokens_per_reply': 3700};
      expect(await b.deletionWarning(), 'You still have about 270 replies you paid for. Deleting your account loses it.');
      api.rpcAnswers['billing_deletion_warning'] = (_) => {'has_paid': true, 'paid_left': 0, 'pending_payments': 1};
      expect(await b.deletionWarning(), 'A payment is still being confirmed.');
      api.rpcAnswers['billing_deletion_warning'] = (_) => {'has_paid': false};
      expect(await b.deletionWarning(), isNull);
      api.rpcAnswers['billing_deletion_warning'] = (_) => throw StateError('offline');
      expect(await b.deletionWarning(), isNull);
      BillingCopy.somaliOverride = true;
      api.rpcAnswers['billing_deletion_warning'] = (_) => {'has_paid': true, 'paid_left': 1000000};
      expect(await b.deletionWarning(), contains('qiyaastii 270 jawaab'));
    });
  });

  test('billing words are English only', () async {
    SharedPreferences.setMockInitialValues({'replyLanguage': 'Somali', 'speaks_somali': true});
    await Billing(api: FakeBillingApi()).init();
    expect(BillingCopy.somali, isFalse);
    expect(BillingCopy.tr('Plan & usage'), 'Plan & usage');
  });
}
