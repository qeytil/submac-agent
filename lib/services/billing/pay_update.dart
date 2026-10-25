import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'billing_copy.dart';

/// Where one payment attempt stands, as the payment screen shows it.
enum PayPhase {
  idle,

  /// Asking the server to start the payment.
  starting,

  /// Wallet push sent: "approve on your phone".
  approve,

  /// Hosted card page is open (in the in-app payment page).
  checkout,

  /// The server / provider is confirming (slow or briefly down). Money may already be on its way.
  processing,

  /// Polling stopped after its limit without an answer: "I've approved, check now".
  stillWaiting,

  /// Paid and added to the user's plan.
  success,

  /// Definitely not paid (declined, insufficient funds, expired, reversed, refused).
  failed,

  /// Could not reach SubMac at all. Safe to retry with the same key.
  offline,

  /// Something to fix before paying (bad number, rate limit, payments off...). Nothing was charged.
  error,
}

/// One answer from billing-checkout (POST start or GET ?purchase= poll), or a network failure, in app terms.
@immutable
class PayUpdate {
  final PayPhase phase;
  final String? purchaseId;
  final String? reason;
  final String message;
  final String? url;
  /// Tokens this payment added (0 until paid).
  final int tokensAdded;
  final int? pollAfterSeconds;
  final int httpStatus;

  /// The server's own answer was a replay of an earlier request with the same idempotency key.
  final bool replay;
  const PayUpdate(this.phase,
      {this.purchaseId,
      this.reason,
      this.message = '',
      this.url,
      this.tokensAdded = 0,
      this.pollAfterSeconds,
      this.httpStatus = 0,
      this.replay = false});

  bool get settled => phase == PayPhase.success || phase == PayPhase.failed;
  bool get pending => phase == PayPhase.approve || phase == PayPhase.processing || phase == PayPhase.checkout || phase == PayPhase.stillWaiting;

  /// Retrying with the SAME idempotency key is right whenever the outcome is unknown or the request never got an answer:
  /// the server returns the same purchase and never charges twice. After a confirmed refusal (declined, not enough
  /// money, expired...) the same key would only replay that refusal, so a retry needs a fresh attempt.
  bool get retryKeepsKey => !(phase == PayPhase.failed || freshKeyReasons.contains(reason));

  static const freshKeyReasons = {'idempotency_key_reused', 'payment_mismatch', 'bad_idempotency_key'};

  PayUpdate copyWith({PayPhase? phase, String? message, String? purchaseId, String? reason}) => PayUpdate(phase ?? this.phase,
      purchaseId: purchaseId ?? this.purchaseId,
      reason: reason ?? this.reason,
      message: message ?? this.message,
      url: url,
      tokensAdded: tokensAdded,
      pollAfterSeconds: pollAfterSeconds,
      httpStatus: httpStatus,
      replay: replay);

  @override
  String toString() => 'PayUpdate($phase, purchase: $purchaseId, reason: $reason, http: $httpStatus)';

  /// Parses any billing-checkout answer. Never throws: an unreadable body becomes [PayPhase.processing] when the
  /// server may have taken the payment (5xx / 202), else [PayPhase.error].
  static PayUpdate fromHttp(int status, String body, {String? purchaseId, bool replay = false}) {
    Map<String, dynamic> j = const {};
    try {
      final d = jsonDecode(body);
      if (d is Map) j = d.map((k, v) => MapEntry('$k', v));
    } catch (_) {}
    final pid = _s(j['purchase_id']) ?? purchaseId;
    final state = _s(j['state']);
    final reason = _s(j['reason']) ?? _s(j['error']) ?? _s(j['result']);
    final serverMsg = _s(j['message']) ?? '';
    final added = j['tokens_added'] is num ? (j['tokens_added'] as num).toInt() : 0;
    final poll = j['poll_after_seconds'] is num ? (j['poll_after_seconds'] as num).toInt() : null;
    final rp = replay || j['replay'] == true;
    PayUpdate mk(PayPhase p, {String? r}) => PayUpdate(p,
        purchaseId: pid,
        reason: r ?? reason,
        message: PayText.messageFor(p, r ?? reason, serverMsg),
        url: _s(j['url']),
        tokensAdded: added,
        pollAfterSeconds: poll,
        httpStatus: status,
        replay: rp);
    switch (state) {
      case 'paid':
        return mk(PayPhase.success);
      case 'waiting_approval':
        return mk(PayPhase.approve);
      case 'checkout_opened':
        return _s(j['url']) != null ? mk(PayPhase.checkout) : mk(PayPhase.processing);
      case 'processing':
        return mk(PayPhase.processing);
      case 'failed':
        return mk(PayPhase.failed, r: reason ?? 'declined');
      case 'expired':
        return mk(PayPhase.failed, r: 'expired');
      case 'reversed':
        return mk(PayPhase.failed, r: 'reversed');
      case 'error':
        return mk(PayPhase.error, r: reason ?? 'payment_mismatch');
    }
    // No state: a refusal before any purchase existed, or a body we can't read.
    if (status == 202) return mk(PayPhase.processing);
    if (status >= 200 && status < 300 && j['ok'] == true && j['status'] == 'paid') return mk(PayPhase.success);
    if (status == 0) return mk(PayPhase.offline, r: reason ?? 'offline');
    if (status >= 500 && pid != null) return mk(PayPhase.processing, r: reason ?? 'provider_unavailable');
    if (status == 401) return mk(PayPhase.error, r: 'auth_required');
    return mk(PayPhase.error, r: reason ?? (status >= 500 ? 'service_unavailable' : 'error'));
  }

  static String? _s(Object? v) => v == null || '$v'.isEmpty ? null : '$v';
}

/// Every payment message the user can see, in one place (short, calm, no provider jargon; English + Somali).
class PayText {
  static const _byReason = <String, String>{
    'insufficient_funds': 'Not enough money in your wallet. Nothing was taken.',
    'declined': 'Payment declined or cancelled. Nothing was taken.',
    'expired': 'Payment timed out. Nothing was taken.',
    'reversed': 'This payment was refunded.',
    'provider_timeout': "Payments are slow right now. If you approved, it's added in a few minutes.",
    'provider_unavailable': "Payments are slow right now. If you approved, it's added in a few minutes.",
    'provider_config': "Payments aren't available right now. Nothing was taken.",
    'provider_rejected': "Couldn't start this payment. Nothing was taken.",
    'payments_not_configured': "Payments aren't available right now. Nothing was taken.",
    'billing_disabled': "Payments aren't available right now. Nothing was taken.",
    'rate_limited': 'Too many tries. Wait a minute.',
    'idempotency_key_reused': 'Tap Try again to start a new payment.',
    'payment_mismatch': "We couldn't match this payment. If money was taken, contact support.",
    'sid_not_for_order': "We couldn't match this payment. If money was taken, contact support.",
    'bad_wallet_account': "That number doesn't look right.",
    'unknown_wallet': 'Choose EVC Plus, ZAAD, SAHAL, eDahab or Premier Wallet.',
    'bad_product': "That isn't available any more.",
    'unknown_product': "That isn't available any more.",
    'auth_required': 'Please sign in again.',
    'offline': "You're offline. Try again: you won't be charged twice.",
    'timeout': 'No answer in time. If you approved, it still counts.',
    'service_unavailable': 'Payments are busy. Try again shortly.',
    'not_found': "We couldn't find this payment.",
  };

  static const _byPhase = <PayPhase, String>{
    PayPhase.starting: 'Starting your payment…',
    PayPhase.approve: 'Approve with your PIN on your phone.',
    PayPhase.checkout: 'Finish on the secure page.',
    PayPhase.processing: 'Confirming your payment…',
    PayPhase.stillWaiting: 'Not heard back yet. If you approved, tap Check now.',
    PayPhase.success: 'Payment received.',
    PayPhase.failed: "Payment didn't go through. Nothing was taken.",
    PayPhase.offline: "You're offline. Try again when you're back.",
    PayPhase.error: 'Something went wrong. Nothing was charged.',
  };

  /// Our own wording (consistent, translated) for every known state and reason; a generic line otherwise. The
  /// server's English text is never shown (it is not translated).
  static String messageFor(PayPhase phase, String? reason, [String serverMessage = '']) {
    if (phase == PayPhase.success || phase == PayPhase.approve) return tr(_byPhase[phase]!);
    if (reason != null && _byReason.containsKey(reason)) return tr(_byReason[reason]!);
    return tr(_byPhase[phase] ?? _byPhase[PayPhase.error]!);
  }
}
