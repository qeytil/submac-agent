import 'dart:async';

import 'package:flutter/foundation.dart';

import 'billing_service.dart';
import 'pay_update.dart';

/// What the user chose to pay for, and how.
@immutable
class PaymentRequest {
  /// billing.plans id: a package ("weekly", "monthly") or "payg".
  final String planId;

  /// Pay as you go: how many tokens (null for packages).
  final int? tokens;

  /// What the screen calls it ("Weekly", "3M").
  final String title;
  final double amountUsd;

  /// 'wallet' (EVC Plus / ZAAD / SAHAL / eDahab / Premier, charged natively) or 'checkout' (card, hosted page).
  final String method;
  final String? gateway; // edahab | waafi | pbwallet
  final String? walletLabel;
  final String? account; // 2526XXXXXXXX
  const PaymentRequest({
    required this.planId,
    this.tokens,
    required this.title,
    required this.amountUsd,
    required this.method,
    this.gateway,
    this.walletLabel,
    this.account,
  });
  bool get isWallet => method == 'wallet';
}

/// How the in-app payment page was left.
enum CheckoutExitKind { returned, cancelled, failedToLoad }

@immutable
class CheckoutExit {
  final CheckoutExitKind kind;

  /// When the page itself already checked the purchase (close button: "Cancel payment?" then a status check).
  final PayUpdate? checked;
  const CheckoutExit(this.kind, {this.checked});
}

/// Opens the hosted payment page (in-app WebView) and resolves when it closes.
typedef OpenCheckout = Future<CheckoutExit> Function(String url, String purchaseId);

/// Drives one payment from tap to result: start, approve-on-phone countdown, polling with backoff, retry with the same
/// idempotency key, in-app card page, foreground resume. UI-free so it can be unit tested.
class PaymentFlow extends ChangeNotifier {
  PaymentFlow(this.billing, this.request, {this.openCheckout, this.approveWindow = const Duration(seconds: 120), DateTime Function()? now})
      : _now = now ?? DateTime.now {
    billing.resumeTick.addListener(_onResume);
  }

  final Billing billing;
  final PaymentRequest request;
  final OpenCheckout? openCheckout;
  final Duration approveWindow;
  final DateTime Function() _now;

  PayUpdate state = const PayUpdate(PayPhase.idle);

  /// A request or poll is running: buttons that would start another one are disabled.
  bool busy = false;

  /// The last status read failed for lack of connection (the payment itself may be fine).
  bool offlineNow = false;

  /// When the "approve on your phone" window ends (wallet payments).
  DateTime? approveDeadline;

  PendingPurchase? _attempt;
  PollToken? _poll;
  bool _disposed = false;
  bool _pageOpen = false;

  String? get purchaseId => state.purchaseId ?? _attempt?.purchaseId;
  String? get attemptKey => _attempt?.key;
  bool get polling => _poll != null && !_poll!.cancelled;

  Duration get approveLeft {
    final d = approveDeadline;
    if (d == null) return Duration.zero;
    final left = d.difference(_now());
    return left.isNegative ? Duration.zero : left;
  }

  void _set(PayUpdate u) {
    if (_disposed) return;
    if (u.phase == PayPhase.offline && state.purchaseId != null && state.pending) {
      // Lost the connection while checking: keep showing where the payment stood.
      offlineNow = true;
    } else {
      offlineNow = u.phase == PayPhase.offline;
      state = u;
    }
    if (u.phase == PayPhase.approve && approveDeadline == null) approveDeadline = _now().add(approveWindow);
    notifyListeners();
  }

  /// Starts the payment. A second call while one is running does nothing (double-tap protection).
  Future<void> start() async {
    if (busy || _disposed) return;
    busy = true;
    _set(PayUpdate(PayPhase.starting, message: PayText.messageFor(PayPhase.starting, null)));
    try {
      _attempt ??= await billing.beginAttempt(
        product: request.planId,
        tokens: request.tokens,
        method: request.method,
        wallet: request.gateway,
        walletLabel: request.walletLabel,
        account: request.account,
      );
      final known = _attempt!.purchaseId;
      // Already have a purchase for this attempt (started before a crash / from the wallet): ask, don't re-send.
      final u = known != null ? await billing.check(known) : await billing.submit(_attempt!);
      await _handle(u);
    } finally {
      busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// The single retry button. Same idempotency key while the outcome is unknown (offline, timeout, provider down,
  /// still waiting): the server returns the same purchase and never charges twice. After a confirmed refusal
  /// (declined, not enough money, expired) a fresh attempt is started, since the old key would only replay the refusal.
  Future<void> retry() async {
    if (busy || _disposed) return;
    final a = _attempt;
    if (a != null && !state.retryKeepsKey) {
      await billing.forgetAttempt(a);
      _attempt = null;
      approveDeadline = null;
    } else if (a != null && a.purchaseId != null && state.pending) {
      // Known purchase still open: checking is the retry (re-sending would only replay it).
      if (request.method == 'checkout' && (a.url ?? state.url) != null && openCheckout != null) {
        busy = true;
        try {
          await _openPage(a.url ?? state.url!, a.purchaseId!);
        } finally {
          busy = false;
          if (!_disposed) notifyListeners();
        }
        return;
      }
      return checkNow();
    }
    return start();
  }

  /// "I've approved, check now" / "I've paid, check now".
  Future<void> checkNow() async {
    final pid = purchaseId;
    if (pid == null || busy || _disposed) return;
    _poll?.cancel();
    busy = true;
    notifyListeners();
    try {
      final u = await billing.check(pid);
      _set(u);
      if (!u.settled && (u.pending || u.phase == PayPhase.offline)) unawaited(_startPolling(pid));
    } finally {
      busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _handle(PayUpdate u) async {
    _set(u);
    final pid = u.purchaseId;
    if (u.phase == PayPhase.checkout && u.url != null && pid != null) {
      await _openPage(u.url!, pid);
      return;
    }
    if ((u.phase == PayPhase.approve || u.phase == PayPhase.processing) && pid != null) {
      unawaited(_startPolling(pid, hint: u.pollAfterSeconds));
    }
  }

  Future<void> _openPage(String url, String pid) async {
    final open = openCheckout;
    if (open == null || _pageOpen) return;
    _pageOpen = true;
    CheckoutExit exit;
    try {
      exit = await open(url, pid);
    } catch (_) {
      exit = const CheckoutExit(CheckoutExitKind.failedToLoad);
    } finally {
      _pageOpen = false;
    }
    if (_disposed) return;
    // Never trust the redirect: ask the server what happened to OUR purchase.
    final u = exit.checked ?? await billing.check(pid);
    if (u.settled) {
      _set(u);
      return;
    }
    if (exit.kind == CheckoutExitKind.cancelled) {
      _set(PayUpdate(PayPhase.stillWaiting,
          purchaseId: pid,
          url: url,
          message: 'Payment not finished. If you already paid, tap Check now. Otherwise you can try again.'));
      return;
    }
    _set(u.phase == PayPhase.offline ? u : PayUpdate(PayPhase.processing, purchaseId: pid, url: url, message: PayText.messageFor(PayPhase.processing, null)));
    unawaited(_startPolling(pid, hint: 2));
  }

  Future<void> _startPolling(String pid, {int? hint}) async {
    _poll?.cancel();
    final t = PollToken();
    _poll = t;
    if (!_disposed) notifyListeners();
    await billing.poll(pid, token: t, hintSeconds: hint, onUpdate: (u) {
      if (!t.cancelled) _set(u);
    });
    if (identical(_poll, t)) _poll = null;
    if (!_disposed) notifyListeners();
  }

  void _onResume() {
    // Back from the wallet app / USSD prompt: look again right away, then keep polling.
    final pid = purchaseId;
    if (pid == null || _disposed || busy || _pageOpen) return;
    if (state.pending || state.phase == PayPhase.offline || offlineNow) unawaited(checkNow());
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    billing.resumeTick.removeListener(_onResume);
    super.dispose();
  }
}
