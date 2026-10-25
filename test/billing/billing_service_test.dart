import 'dart:async';
import 'dart:convert';

import 'package:agent/services/billing/billing_api.dart';
import 'package:agent/services/billing/billing_models.dart';
import 'package:agent/services/billing/billing_service.dart';
import 'package:agent/services/billing/pay_update.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_billing_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeBillingApi api;
  late List<Duration> slept;
  late DateTime clock;

  Billing make({FakeBillingApi? a}) => Billing(
        api: a ?? api,
        sleep: (d) async {
          slept.add(d);
          clock = clock.add(d);
        },
        now: () => clock,
      );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    api = FakeBillingApi();
    slept = [];
    clock = DateTime(2026, 10, 21, 12);
  });

  group('idempotency key', () {
    test('is persisted before the request and reused after an app kill', () async {
      final b1 = make();
      final a = await b1.beginAttempt(product: 'weekly', method: 'wallet', wallet: 'edahab', account: '252621111111');
      // Persisted before any request went out.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('billing_pending_v1'), contains(a.key));
      expect(api.posts, isEmpty);

      // The request never got an answer (app killed / offline).
      api.onPost = (_, __) => const BillingNetworkError('offline');
      final u = await b1.submit(a);
      expect(u.phase, PayPhase.offline);
      expect(u.retryKeepsKey, isTrue);

      // "App restart": a fresh service on the same storage finds the same attempt and key.
      final b2 = make();
      final again = await b2.beginAttempt(product: 'weekly', method: 'wallet', wallet: 'edahab', account: '252621111111');
      expect(again.key, a.key);
      api.onPost = (_, __) => waiting('p-9');
      await b2.submit(again);
      expect(api.posts.map((p) => p.key).toSet(), {a.key});
      expect(api.posts.last.body, containsPair('account', '252621111111'));
      expect(api.posts.last.body, containsPair('device_id', 'device-abc123'));
    });

    test('a different number, wallet or product gets its own key', () async {
      final b = make();
      final a = await b.beginAttempt(product: 'weekly', method: 'wallet', wallet: 'edahab', account: '252621111111');
      final c = await b.beginAttempt(product: 'weekly', method: 'wallet', wallet: 'waafi', account: '252611111111');
      final d = await b.beginAttempt(product: 'monthly', method: 'wallet', wallet: 'edahab', account: '252621111111');
      expect({a.key, c.key, d.key}.length, 3);
      expect(a.key, startsWith('app-'));
    });

    test('settled attempts free the key; a refusal before any purchase does too', () async {
      final b = make();
      final a = await b.beginAttempt(product: 'payg', method: 'wallet', wallet: 'edahab', account: '252621111111');
      api.onPost = (_, __) => paid('p-1');
      expect((await b.submit(a)).phase, PayPhase.success);
      final next = await b.beginAttempt(product: 'payg', method: 'wallet', wallet: 'edahab', account: '252621111111');
      expect(next.key, isNot(a.key));

      api.onPost = (_, __) => res(429, {'ok': false, 'error': 'rate_limited', 'message': 'x'});
      final u = await b.submit(next);
      expect(u.phase, PayPhase.error);
      expect(u.reason, 'rate_limited');
      final third = await b.beginAttempt(product: 'payg', method: 'wallet', wallet: 'edahab', account: '252621111111');
      expect(third.key, isNot(next.key));
    });

    test('declined: the old key is dropped (it would only replay the decline)', () async {
      final b = make();
      final a = await b.beginAttempt(product: 'payg', method: 'wallet', wallet: 'edahab', account: '252622222222');
      api.onPost = (_, __) => res(402, {'ok': false, 'purchase_id': 'p-2', 'status': 'failed', 'state': 'failed', 'error': 'declined', 'reason': 'declined'});
      final u = await b.submit(a);
      expect(u.phase, PayPhase.failed);
      expect(u.retryKeepsKey, isFalse);
      expect(b.unsettled, isEmpty);
    });

    test('5xx without a purchase id keeps the key (server may have it)', () async {
      final b = make();
      final a = await b.beginAttempt(product: 'payg', method: 'wallet', wallet: 'edahab', account: '252621111111');
      api.onPost = (_, __) => const BillingHttpResponse(500, 'oops');
      final u = await b.submit(a);
      expect(u.retryKeepsKey, isTrue);
      expect(b.unsettled.single.key, a.key);
    });

    test('double tap: one request per key at a time', () async {
      final b = make();
      final a = await b.beginAttempt(product: 'payg', method: 'wallet', wallet: 'edahab', account: '252621111111');
      api.postGate = Completer<void>();
      final f1 = b.submit(a);
      final f2 = b.submit(a);
      final f3 = b.submit(a);
      await Future<void>.delayed(Duration.zero);
      api.postGate!.complete();
      final r = await Future.wait([f1, f2, f3]);
      expect(api.posts.length, 1);
      expect(r.map((u) => u.purchaseId).toSet(), {'p-1'});
    });
  });

  group('poll backoff', () {
    test('delays start at the hint, grow 1.5x and cap at 20 s', () {
      expect(pollDelay(0, hintSeconds: 5), const Duration(seconds: 5));
      expect(pollDelay(1, hintSeconds: 5), const Duration(milliseconds: 7500));
      expect(pollDelay(2, hintSeconds: 5), const Duration(milliseconds: 11250));
      expect(pollDelay(10, hintSeconds: 5), const Duration(seconds: 20));
      expect(pollDelay(0), const Duration(seconds: 3));
      expect(pollDelay(0, hintSeconds: 1), const Duration(seconds: 2)); // floor
    });

    test('stops as soon as the payment is paid', () async {
      final b = make();
      api.statusAnswers.addAll([waiting('p-1'), waiting('p-1'), paid('p-1', tokens: 3000000)]);
      final seen = <PayPhase>[];
      final u = await b.poll('p-1', hintSeconds: 5, onUpdate: (x) => seen.add(x.phase));
      expect(u.phase, PayPhase.success);
      expect(u.tokensAdded, 3000000);
      expect(api.statusCalls.length, 3);
      expect(slept, [const Duration(seconds: 5), const Duration(milliseconds: 7500), const Duration(milliseconds: 11250)]);
      expect(seen, [PayPhase.approve, PayPhase.approve, PayPhase.success]);
    });

    test('gives up after the limit with stillWaiting', () async {
      final b = make();
      final u = await b.poll('p-1', maxPolls: 4, maxWait: const Duration(hours: 1));
      expect(u.phase, PayPhase.stillWaiting);
      expect(api.statusCalls.length, 4);
    });

    test('gives up after maxWait (clock)', () async {
      final b = make();
      final u = await b.poll('p-1', hintSeconds: 5, maxWait: const Duration(seconds: 30), maxPolls: 100);
      expect(u.phase, PayPhase.stillWaiting);
      // 5 + 7.5 + 11.25 + 16.875 = 40.6 s > 30 s -> 4 polls
      expect(api.statusCalls.length, 4);
    });

    test('being offline does not end polling early', () async {
      final b = make();
      api.statusAnswers.addAll([const BillingNetworkError('offline'), const BillingNetworkError('timeout'), paid('p-1')]);
      final seen = <PayPhase>[];
      final u = await b.poll('p-1', onUpdate: (x) => seen.add(x.phase));
      expect(seen, [PayPhase.offline, PayPhase.offline, PayPhase.success]);
      expect(u.phase, PayPhase.success);
    });

    test('a cancelled token stops the loop', () async {
      final b = make();
      final t = PollToken()..cancel();
      await b.poll('p-1', token: t);
      expect(api.statusCalls, isEmpty);
    });

    test('a declined payment ends polling', () async {
      final b = make();
      api.statusAnswers.addAll([waiting('p-1'), res(200, {'ok': true, 'purchase_id': 'p-1', 'status': 'failed', 'state': 'failed', 'reason': 'insufficient_funds'})]);
      final u = await b.poll('p-1');
      expect(u.phase, PayPhase.failed);
      expect(u.reason, 'insufficient_funds');
      expect(u.message, contains('enough money'));
    });
  });

  group('error mapping', () {
    PayUpdate m(int s, Map<String, dynamic> j) => PayUpdate.fromHttp(s, jsonEncode(j));

    test('every documented checkout answer', () {
      expect(m(200, {'purchase_id': 'p', 'state': 'paid', 'status': 'paid'}).phase, PayPhase.success);
      expect(m(202, {'purchase_id': 'p', 'state': 'waiting_approval'}).phase, PayPhase.approve);
      final hosted = m(200, {'purchase_id': 'p', 'state': 'checkout_opened', 'url': 'https://pay.sifalo.net/checkout/?key=1'});
      expect(hosted.phase, PayPhase.checkout);
      expect(hosted.url, startsWith('https://pay.sifalo.net'));
      final slow = m(202, {'purchase_id': 'p', 'state': 'processing', 'reason': 'provider_timeout'});
      expect(slow.phase, PayPhase.processing);
      expect(slow.message, contains('slow'));
      expect(m(402, {'purchase_id': 'p', 'state': 'failed', 'reason': 'insufficient_funds'}).message, contains('enough money'));
      expect(m(402, {'purchase_id': 'p', 'state': 'failed', 'reason': 'declined'}).message, contains('declined'));
      expect(m(200, {'purchase_id': 'p', 'state': 'expired', 'status': 'expired'}).reason, 'expired');
      expect(m(200, {'purchase_id': 'p', 'state': 'reversed'}).phase, PayPhase.failed);
      final page = m(502, {'ok': false, 'purchase_id': 'p', 'status': 'pending', 'state': 'processing', 'error': 'provider_unavailable'});
      expect(page.phase, PayPhase.processing);
      expect(page.retryKeepsKey, isTrue);
      final reused = m(409, {'ok': false, 'error': 'idempotency_key_reused'});
      expect(reused.phase, PayPhase.error);
      expect(reused.retryKeepsKey, isFalse);
      expect(m(429, {'ok': false, 'error': 'rate_limited'}).message, contains('Too many'));
      expect(m(503, {'ok': false, 'error': 'billing_disabled'}).message, contains('aren\'t available'));
      expect(m(503, {'ok': false, 'error': 'payments_not_configured'}).phase, PayPhase.error);
      expect(m(400, {'ok': false, 'error': 'bad_wallet_account'}).message, contains('number'));
      expect(m(401, {'ok': false, 'error': 'auth_required'}).reason, 'auth_required');
      expect(m(409, {'ok': false, 'purchase_id': 'p', 'status': 'error', 'state': 'error', 'error': 'payment_mismatch'}).message, contains('support'));
    });

    test('garbage never throws', () {
      expect(PayUpdate.fromHttp(500, '<html>').phase, PayPhase.error);
      expect(PayUpdate.fromHttp(502, 'nope', purchaseId: 'p').phase, PayPhase.processing);
      expect(PayUpdate.fromHttp(200, '[]').phase, PayPhase.error);
      expect(PayUpdate.fromHttp(202, '').phase, PayPhase.processing);
      expect(PayUpdate.fromHttp(200, jsonEncode({'state': 'brand_new_state'})).phase, PayPhase.error);
    });

    test('usage refusals from ai-chat (Contract A codes, older codes, garbage)', () {
      final at = DateTime.utc(2026, 10, 21, 21); // 00:00 EAT
      for (final c in BillingNotice.limitCodes) {
        final n = BillingNotice.tryParse(429, {'error': {'code': c, 'message': 'm'}, 'resets_at': at.toIso8601String()})!;
        expect(n.code, c);
        expect(n.known, isTrue);
        expect(n.title, isNotEmpty);
        expect(n.title, isNot(contains('token')));
      }
      final d = BillingNotice.tryParse(429, {'error': {'code': 'limit_daily'}, 'resets_at': at.toIso8601String()})!;
      expect(d.title, 'You\'ve used today\'s replies.');
      expect(d.resetLine(now: DateTime.utc(2026, 10, 21, 16)), contains('(in 5 h)'));
      expect(BillingNotice.tryParse(429, {'error': {'code': 'limit_daily'}})!.resetLine(), 'Resets at midnight.');
      final bot = BillingNotice.tryParse(429, {'error': {'code': 'limit_daily', 'reason': 'bot_share'}})!;
      expect(bot.title, contains('Bots'));
      // busy with a billing block: info only, keeps Retry-After
      final busy = BillingNotice.tryParse(429, {'error': {'code': 'busy'}, 'billing': {'reason': 'x'}, 'retry_after_seconds': 30})!;
      expect(busy.retryAfterSeconds, 30);
      expect(busy.isInfo, isTrue);
      // coin-era codes are not billing notices any more
      expect(BillingNotice.tryParse(429, {'error': {'code': 'daily_limit'}, 'billing': {'reason': 'x'}})!.known, isFalse);
      // a plain busy without a billing block stays a normal error; garbage never throws
      expect(BillingNotice.tryParse(503, {'error': {'code': 'busy'}}), isNull);
      expect(BillingNotice.tryParse(429, {'error': {'code': 'too_long'}}), isNull);
      expect(BillingNotice.tryParse(500, 'nope'), isNull);
      expect(BillingNotice.tryParse(429, {'billing': 'x'}), isNull);
      expect(BillingNotice.tryParse(429, {'billing': {}, 'error': 5}), isNull);
    });
  });

  group('server signals', () {
    test('/status billing block switches billing on and off', () {
      final b = make();
      expect(b.enabled.value, isFalse);
      b.noteStatus(null);
      expect(b.enabled.value, isFalse);
      b.noteStatus({'enabled': true, 'plan': 'weekly', 'today_left': 37000, 'total_left': 500000, 'tokens_per_reply': 3700});
      expect(b.enabled.value, isTrue);
      expect(b.usage.value!.plan, 'weekly');
      expect(b.balance.value, 37000);
      b.noteStatus({'enabled': false});
      expect(b.enabled.value, isFalse);
    });

    test('Contract A headers: today/total left, resets at, plan', () {
      final b = make();
      b.noteHeaders({'x-submac-usage': '0.1'});
      expect(b.balance.value, isNull);
      expect(b.enabled.value, isFalse);
      b.noteHeaders({
        'x-submac-today-left': '120000', 'x-submac-total-left': '2500000', 'x-submac-resets-at': '2026-10-21T21:00:00Z', 'x-submac-plan': 'monthly',
      });
      expect(b.enabled.value, isTrue);
      expect(b.balance.value, 120000);
      final u = b.usage.value!;
      expect(u.todayLeft, 120000);
      expect(u.totalLeft, 2500000);
      expect(u.plan, 'monthly');
      expect(u.planLabel, 'Monthly');
      expect(u.resetsAt, DateTime.utc(2026, 10, 21, 21));
      b.noteHeaders({'x-submac-today-left': '100'});
      expect(b.usage.value!.totalLeft, 2500000); // kept
      expect(b.balance.value, 100);
      final c = make();
      c.noteHeaders({'x-submac-balance': '4200'}); // coin-era header: ignored
      expect(c.balance.value, isNull);
    });

    test('usage: disabled answer hides billing; catalogue survives a /status refresh', () async {
      final b = make();
      api.rpcAnswers['billing_usage'] = (_) => usageJson(todayLeft: 300000);
      final s = await b.refreshUsage();
      expect(s!.todayLeft, 300000);
      expect(s.plans, isNotEmpty);
      expect(s.packagePlans.map((p) => p.id), ['weekly', 'monthly']);
      expect(s.paygPlan!.priceFor(3000000), 6.0);
      b.noteStatus({'enabled': true, 'today_left': 1});
      expect(b.usage.value!.todayLeft, 1);
      expect(b.usage.value!.plans.length, s.plans.length);
      api.rpcAnswers['billing_usage'] = (_) => {'enabled': false};
      await b.refreshUsage();
      expect(b.enabled.value, isFalse);
    });

    test('usage offline: keeps the cached copy', () async {
      final b = make();
      api.rpcAnswers['billing_usage'] = (_) => usageJson(todayLeft: 77);
      await b.refreshUsage();
      final b2 = make();
      api.rpcAnswers['billing_usage'] = (_) => const BillingNetworkError('offline');
      final s = await b2.refreshUsage();
      expect(s?.todayLeft, 77);
    });

    test('pay as you go: the amount goes to the server with the plan; same plan, other amount = other key', () async {
      final b = make();
      final a = await b.beginAttempt(product: 'payg', tokens: 3000000, method: 'wallet', wallet: 'edahab', account: '252621111111');
      final c = await b.beginAttempt(product: 'payg', tokens: 5000000, method: 'wallet', wallet: 'edahab', account: '252621111111');
      expect(a.key, isNot(c.key));
      await b.submit(a);
      expect(api.posts.last.body, containsPair('plan', 'payg'));
      expect(api.posts.last.body, containsPair('tokens', 3000000));
      expect(api.posts.last.body.containsKey('product'), isFalse);
      expect(api.posts.last.body.containsKey('coins'), isFalse);
    });
  });

  group('recovery after app kill', () {
    test('stored purchase ids are checked on the next launch', () async {
      final b1 = make();
      final a = await b1.beginAttempt(product: 'weekly', method: 'wallet', wallet: 'waafi', account: '252611234567');
      await b1.submit(a); // waiting_approval p-1, then the app dies
      expect(b1.unsettled.single.purchaseId, 'p-1');

      final b2 = make();
      final toasts = <String>[];
      b2.onToast = toasts.add;
      api.statusAnswers.add(paid('p-1', tokens: 3000000));
      await b2.recoverPending();
      expect(api.statusCalls, ['p-1']);
      expect(toasts.single, 'Done. 3M added.');
      expect(b2.unsettled, isEmpty);
    });

    test('attempts without an answer are never re-sent on their own; forgotten after 24 h', () async {
      final b1 = make();
      final a = await b1.beginAttempt(product: 'weekly', method: 'wallet', wallet: 'waafi', account: '252611234567');
      api.onPost = (_, __) => const BillingNetworkError('timeout');
      await b1.submit(a);
      final b2 = make();
      await b2.recoverPending();
      expect(api.posts.length, 1);
      expect(b2.unsettled.single.key, a.key);
      clock = clock.add(const Duration(hours: 25));
      final b3 = make();
      await b3.recoverPending();
      expect(b3.unsettled, isEmpty);
    });

    test('another user\'s pending payments are left alone', () async {
      final b1 = make();
      final a = await b1.beginAttempt(product: 'payg', method: 'wallet', wallet: 'edahab', account: '252621111111');
      await b1.submit(a);
      final other = FakeBillingApi(uid: 'user-2');
      final b2 = make(a: other);
      await b2.recoverPending();
      expect(other.statusCalls, isEmpty);
      expect(b2.unsettled, isEmpty);
    });

    test('submac://pay link: checks that purchase, announces an unknown success', () async {
      final b = make();
      final toasts = <String>[];
      b.onToast = toasts.add;
      api.statusAnswers.add(paid('11111111-2222-3333-4444-555555555555', tokens: 700000));
      final tick = b.resumeTick.value;
      await b.handlePayLink(Uri.parse('submac://pay?status=paid&purchase=11111111-2222-3333-4444-555555555555'));
      expect(b.resumeTick.value, tick + 1);
      expect(api.statusCalls.single, '11111111-2222-3333-4444-555555555555');
      expect(toasts.single, 'Done. 700k added.');
      await b.handlePayLink(Uri.parse('submac://hire?bot=x'));
      expect(api.statusCalls.length, 1);
    });
  });

  test('replies wording never says unlimited or tokens', () {
    expect(repliesText(1000000), 'About 270 replies');
    expect(repliesText(3700), 'About 1 reply');
    expect(repliesText(0), 'About 0 replies');
    expect(repliesText(-5), 'About 0 replies');
    expect(repliesText(3000000, perReply: 3700), 'About 810 replies');
    expect(tokensShort(120000), '120k');
    expect(tokensShort(2500000), '2.5M');
    expect(groupDigits(1100), '1,100');
    expect(addedText(3000000), 'Done. 3M added.');
    const payg = PlanInfo(id: 'payg', kind: 'payg', name: 'Pay as you go', priceUsd: 2, unitTokens: 1000000, minTokens: 1000000,
        maxTokens: 50000000, stepTokens: 100000);
    expect(payg.clampTokens(1234567), 1200000);
    expect(payg.clampTokens(1), 1000000);
    expect(payg.clampTokens(999999999), 50000000);
    expect(payg.priceFor(1500000), 3.0);
  });
}
