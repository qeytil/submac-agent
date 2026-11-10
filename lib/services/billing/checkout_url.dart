import 'package:flutter/foundation.dart';

/// What the in-app payment page does with a navigation (hosted card checkout on pay.sifalo.net).
enum CheckoutNavKind {
  /// Load it in the payment page.
  allow,

  /// The payment page is done (billing-return URL or telesia://pay): stop loading, close, and check the purchase.
  finish,

  /// Not a payment page: open it outside the app (browser, phone, mail).
  external,

  /// Never load it, never open it (javascript:, file:, plain http to a payment host...).
  block,
}

@immutable
class CheckoutNavDecision {
  final CheckoutNavKind kind;

  /// From the return URL (purchase= or order_id=). Informational only: the app always checks ITS OWN purchase id.
  final String? purchaseId;

  /// What the redirect claimed (paid | pending | failed | error). Never trusted: the app polls billing-checkout.
  final String? status;
  final String? reason;

  /// For [CheckoutNavKind.finish] on the billing-return URL: the server must still see this request (it binds the
  /// payment ref Sifalo put in the URL), so the app sends it itself in the background.
  final Uri? serverReturnUrl;
  const CheckoutNavDecision(this.kind, {this.purchaseId, this.status, this.reason, this.serverReturnUrl});

  @override
  String toString() => 'CheckoutNavDecision($kind, purchase: $purchaseId, status: $status)';
}

/// Hosts the payment page may load. Owner rule (2026-10-21): only Sifalo's pay hosts and our own functions host.
const kCheckoutPayHosts = {'pay.sifalo.net', 'pay.sifalo.com'};

/// Extra hosts allowed inside the payment page (e.g. a card network's 3-D Secure page, if staging shows the hosted
/// checkout redirects the whole page there). Empty on purpose until seen on staging.
const Set<String> kCheckoutExtraHosts = {};

/// Decides what happens when the payment page wants to go to [u].
/// [functionsHost] is the Supabase project host (xyz.supabase.co). [mainFrame] = false for iframes: those may load any
/// https page (card 3-D Secure challenges live in iframes) but never leave the app or finish the flow.
CheckoutNavDecision decideCheckoutNav(Uri u, {required String functionsHost, bool mainFrame = true}) {
  final scheme = u.scheme.toLowerCase();
  final host = u.host.toLowerCase();
  if (scheme == 'telesia') {
    if (host == 'pay') return _finish(u);
    return const CheckoutNavDecision(CheckoutNavKind.block);
  }
  if (scheme == 'about') return const CheckoutNavDecision(CheckoutNavKind.allow); // about:blank / about:srcdoc frames
  if (scheme == 'https') {
    if (host == functionsHost.toLowerCase() && isBillingReturnPath(u.path)) {
      return mainFrame ? _finish(u, server: u) : const CheckoutNavDecision(CheckoutNavKind.block);
    }
    if (kCheckoutPayHosts.contains(host) || kCheckoutExtraHosts.contains(host) || host == functionsHost.toLowerCase()) {
      return const CheckoutNavDecision(CheckoutNavKind.allow);
    }
    return CheckoutNavDecision(mainFrame ? CheckoutNavKind.external : CheckoutNavKind.allow);
  }
  if (scheme == 'http') {
    // Never load a payment page without TLS; other plain links leave the app.
    if (kCheckoutPayHosts.contains(host) || host == functionsHost.toLowerCase()) return const CheckoutNavDecision(CheckoutNavKind.block);
    return CheckoutNavDecision(mainFrame ? CheckoutNavKind.external : CheckoutNavKind.block);
  }
  if (!mainFrame) {
    // Frames may use data:/blob: for their own content.
    if (scheme == 'data' || scheme == 'blob') return const CheckoutNavDecision(CheckoutNavKind.allow);
    return const CheckoutNavDecision(CheckoutNavKind.block);
  }
  if (const {'tel', 'mailto', 'sms', 'whatsapp', 'intent', 'market'}.contains(scheme)) {
    return const CheckoutNavDecision(CheckoutNavKind.external);
  }
  return const CheckoutNavDecision(CheckoutNavKind.block); // javascript:, file:, data: top-level, unknown schemes
}

/// `/functions/v1/billing-return` (optionally `/functions/v1/billing-return/<provider>`).
bool isBillingReturnPath(String path) {
  final p = path.toLowerCase();
  return p == '/functions/v1/billing-return' || p.startsWith('/functions/v1/billing-return/') || p == '/functions/v1/billing-return/';
}

CheckoutNavDecision _finish(Uri u, {Uri? server}) {
  final q = u.queryParameters;
  final id = q['purchase'] ?? q['order_id'];
  return CheckoutNavDecision(
    CheckoutNavKind.finish,
    purchaseId: id != null && _uuid.hasMatch(id) ? id.toLowerCase() : null,
    status: q['status'],
    reason: q['reason'],
    serverReturnUrl: server,
  );
}

final _uuid = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

/// A telesia://pay deep link (fallback when the page was opened outside the app): the purchase it is about.
CheckoutNavDecision? parsePayDeepLink(Uri u) {
  if (u.scheme.toLowerCase() != 'telesia' || u.host.toLowerCase() != 'pay') return null;
  return _finish(u);
}
