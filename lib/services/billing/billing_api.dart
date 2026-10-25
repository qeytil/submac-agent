import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../config.dart';
import '../cloud.dart';
import '../rewards.dart';

/// One HTTP answer from a billing function.
class BillingHttpResponse {
  final int status;
  final String body;
  final Map<String, String> headers;
  const BillingHttpResponse(this.status, this.body, [this.headers = const {}]);
}

/// The request never got an answer: [kind] is 'offline' (no connection) or 'timeout' (sent, no answer in time).
class BillingNetworkError implements Exception {
  final String kind;
  const BillingNetworkError(this.kind);
  @override
  String toString() => 'BillingNetworkError($kind)';
}

/// Everything the billing service needs from the outside world, so tests can replace it.
abstract class BillingApi {
  /// A user RPC (billing_summary, billing_history, billing_exchange, billing_buy_pass, billing_set_auto_exchange).
  Future<dynamic> rpc(String fn, {Map<String, dynamic>? params});

  /// POST billing-checkout with the attempt's idempotency key. Throws [BillingNetworkError] when there is no answer.
  Future<BillingHttpResponse> postCheckout(Map<String, dynamic> body, {required String idempotencyKey});

  /// GET billing-checkout?purchase=<id>. Throws [BillingNetworkError] when there is no answer.
  Future<BillingHttpResponse> getStatus(String purchaseId);

  /// Sends the billing-return request the payment page was redirected to (without following its redirect), so the
  /// server still binds the payment ref in that URL even though the in-app page stopped loading it.
  Future<void> touchReturn(Uri url);

  /// The Supabase project host (xyz.supabase.co): the only non-Sifalo host the payment page may load.
  String get functionsHost;

  /// The signed-in user (pending purchases are kept per user), or null.
  String? get userId;

  /// This install's id (first top-up bonus is once per device too).
  Future<String?> deviceId();
}

/// The real thing: Supabase RPCs + the billing-checkout edge function, signed with the user's session.
class SupabaseBillingApi implements BillingApi {
  SupabaseBillingApi({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;

  static const postTimeout = Duration(seconds: 150); // the server waits up to 120 s on Sifalo
  static const getTimeout = Duration(seconds: 30);

  String get _checkout => '${AppConfig.supabaseUrl}/functions/v1/billing-checkout';

  @override
  String get functionsHost => Uri.parse(AppConfig.supabaseUrl).host;

  @override
  String? get userId {
    try {
      return Supabase.instance.client.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String?> deviceId() async {
    try {
      return await Rewards.I.deviceId();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<dynamic> rpc(String fn, {Map<String, dynamic>? params}) async {
    try {
      return await Supabase.instance.client.rpc(fn, params: params).timeout(getTimeout);
    } on TimeoutException {
      throw const BillingNetworkError('timeout');
    } on SocketException {
      throw const BillingNetworkError('offline');
    } on http.ClientException {
      throw const BillingNetworkError('offline');
    }
  }

  Future<Map<String, String>> _headers({String? idem}) async => {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${await Cloud.token()}',
        'apikey': AppConfig.supabaseAnonKey,
        if (idem != null) 'x-idempotency-key': idem,
      };

  Future<BillingHttpResponse> _send(Future<http.Response> Function() call, Duration timeout) async {
    try {
      final r = await call().timeout(timeout);
      return BillingHttpResponse(r.statusCode, r.body, r.headers);
    } on TimeoutException {
      throw const BillingNetworkError('timeout');
    } on SocketException {
      throw const BillingNetworkError('offline');
    } on http.ClientException {
      throw const BillingNetworkError('offline');
    } on HandshakeException {
      throw const BillingNetworkError('offline');
    }
  }

  @override
  Future<BillingHttpResponse> postCheckout(Map<String, dynamic> body, {required String idempotencyKey}) async {
    final h = await _headers(idem: idempotencyKey);
    return _send(() => _client.post(Uri.parse(_checkout), headers: h, body: jsonEncode(body)), postTimeout);
  }

  @override
  Future<BillingHttpResponse> getStatus(String purchaseId) async {
    final h = await _headers();
    return _send(() => _client.get(Uri.parse('$_checkout?purchase=${Uri.encodeQueryComponent(purchaseId)}'), headers: h), getTimeout);
  }

  @override
  Future<void> touchReturn(Uri url) async {
    try {
      final req = http.Request('GET', url)..followRedirects = false;
      final r = await _client.send(req).timeout(const Duration(seconds: 25));
      await r.stream.drain<void>().timeout(const Duration(seconds: 5));
    } catch (_) {
      // Best effort: Sifalo's webhook and the status poll confirm the payment too.
    }
  }
}
