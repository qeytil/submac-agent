import 'dart:async';
import 'dart:convert';

import 'package:agent/services/billing/billing_api.dart';

/// Scriptable stand-in for Supabase + billing-checkout.
class FakeBillingApi implements BillingApi {
  FakeBillingApi({this.uid = 'user-1'});

  String? uid;
  final posts = <({Map<String, dynamic> body, String key})>[];
  final statusCalls = <String>[];
  final rpcCalls = <({String fn, Map<String, dynamic>? params})>[];
  final touched = <Uri>[];

  /// Answer for each POST (default: waiting_approval for purchase p-1).
  Object Function(Map<String, dynamic> body, String key)? onPost;

  /// Answers for GET ?purchase=, in order (BillingHttpResponse or BillingNetworkError). The last one repeats.
  final statusAnswers = <Object>[];

  /// Holds POSTs until completed (double-tap tests).
  Completer<void>? postGate;

  final rpcAnswers = <String, Object? Function(Map<String, dynamic>? p)>{};

  @override
  String get functionsHost => 'proj.supabase.co';

  @override
  String? get userId => uid;

  @override
  Future<String?> deviceId() async => 'device-abc123';

  @override
  Future<dynamic> rpc(String fn, {Map<String, dynamic>? params}) async {
    rpcCalls.add((fn: fn, params: params));
    final a = rpcAnswers[fn];
    if (a == null) return {'ok': true};
    final v = a(params);
    if (v is BillingNetworkError) throw v;
    return v;
  }

  @override
  Future<BillingHttpResponse> postCheckout(Map<String, dynamic> body, {required String idempotencyKey}) async {
    posts.add((body: body, key: idempotencyKey));
    if (postGate != null) await postGate!.future;
    final a = onPost?.call(body, idempotencyKey) ?? res(202, {'ok': true, 'purchase_id': 'p-1', 'status': 'pending', 'state': 'waiting_approval', 'poll_after_seconds': 5});
    if (a is BillingNetworkError) throw a;
    return a as BillingHttpResponse;
  }

  @override
  Future<BillingHttpResponse> getStatus(String purchaseId) async {
    statusCalls.add(purchaseId);
    if (statusAnswers.isEmpty) return res(200, {'ok': true, 'purchase_id': purchaseId, 'status': 'pending', 'state': 'waiting_approval'});
    final a = statusAnswers.length > 1 ? statusAnswers.removeAt(0) : statusAnswers.first;
    if (a is BillingNetworkError) throw a;
    return a as BillingHttpResponse;
  }

  @override
  Future<void> touchReturn(Uri url) async => touched.add(url);
}

BillingHttpResponse res(int status, Map<String, dynamic> body, [Map<String, String> headers = const {}]) =>
    BillingHttpResponse(status, jsonEncode(body), headers);

BillingHttpResponse paid(String pid, {int tokens = 700000}) =>
    res(200, {'ok': true, 'purchase_id': pid, 'status': 'paid', 'state': 'paid', 'tokens_added': tokens});

BillingHttpResponse waiting(String pid) =>
    res(200, {'ok': true, 'purchase_id': pid, 'status': 'pending', 'state': 'waiting_approval', 'poll_after_seconds': 5});

/// A billing_usage answer with the catalogue from 20261023_billing_v2.sql.
Map<String, dynamic> usageJson({int todayLeft = 60000, int totalLeft = 1000000, String plan = 'free', List<Map<String, dynamic>> packages = const []}) => {
      'enabled': true,
      'plan': plan,
      'today_left': todayLeft,
      'total_left': totalLeft,
      'paid_left': plan == 'free' ? 0 : totalLeft,
      'resets_at': '2026-10-21T21:00:00Z',
      'tokens_per_reply': 3700,
      'free': {'daily': 60000, 'monthly': 1000000, 'today_left': todayLeft},
      'packages': packages,
      'payg': {'left': 0},
      'balances': [],
      'queued': [],
      'plans': [
        {'id': 'free', 'kind': 'free', 'tier': 'free', 'name': 'Free', 'price_usd': 0, 'total_tokens': 1000000, 'daily_tokens': 60000, 'validity_days': 30},
        {'id': 'weekly', 'kind': 'package', 'tier': 'weekly', 'name': 'Weekly', 'price_usd': 1.25, 'total_tokens': 700000, 'daily_tokens': 200000, 'validity_days': 7},
        {'id': 'monthly', 'kind': 'package', 'tier': 'monthly', 'name': 'Monthly', 'price_usd': 4.99, 'total_tokens': 3000000, 'daily_tokens': 250000, 'validity_days': 30},
        {'id': 'payg', 'kind': 'payg', 'tier': 'payg', 'name': 'Pay as you go', 'price_usd': 2.0, 'validity_days': 365, 'unit_tokens': 1000000,
         'min_tokens': 1000000, 'max_tokens': 50000000, 'step_tokens': 100000, 'presets': [1000000, 3000000, 5000000, 10000000]},
      ],
    };
