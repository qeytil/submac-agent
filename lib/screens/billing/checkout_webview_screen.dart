import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/billing/billing_copy.dart';
import '../../services/billing/checkout_url.dart';
import '../../services/billing/pay_update.dart';
import '../../services/billing/payment_flow.dart';
import '../../theme.dart';
import '../../ui/tokens.dart';

/// What the payment page needs from whatever web view shows it (the real InAppWebView, or a fake in tests).
abstract class CheckoutWebController {
  Future<void> reload();
  Future<bool> canGoBack();
  Future<void> goBack();
  Future<void> stopLoading();
}

/// Callbacks the web view reports into the payment page.
class CheckoutWebHooks {
  CheckoutWebHooks({
    required this.url,
    required this.onCreated,
    required this.onNavigate,
    required this.onLoadStart,
    required this.onProgress,
    required this.onMainFrameError,
    required this.onLoadStop,
  });
  final String url;
  final void Function(CheckoutWebController c) onCreated;

  /// Every navigation (links, redirects, new windows). Returns true to let it load in the page.
  final Future<bool> Function(Uri uri, {bool mainFrame}) onNavigate;

  /// A page started loading (some redirects only show up here): returns true when the page is done.
  final bool Function(Uri uri) onLoadStart;
  final void Function(int progress) onProgress;
  final void Function(String description) onMainFrameError;
  final void Function() onLoadStop;
}

typedef CheckoutWebBuilder = Widget Function(BuildContext context, CheckoutWebHooks hooks);

/// Hosted card checkout INSIDE the app (owner rule 2026-10-21): app bar "Secure payment" with a lock, progress bar,
/// close asks "Cancel payment?" then checks the purchase before leaving, back goes back in the page first.
/// Only Sifalo's pay hosts and our functions host load here; anything else opens outside the app. When the page reaches
/// the billing-return URL or telesia://pay, it stops, lets the server see the return request, and closes. The caller
/// then asks the server about the purchase: the redirect itself is never trusted.
class CheckoutWebViewScreen extends StatefulWidget {
  const CheckoutWebViewScreen({
    super.key,
    required this.url,
    required this.purchaseId,
    required this.functionsHost,
    required this.onCheck,
    this.onReturnUrl,
    this.openExternal,
    this.webBuilder,
  });

  final String url;
  final String purchaseId;
  final String functionsHost;

  /// One status check of this purchase (GET billing-checkout?purchase=).
  final Future<PayUpdate> Function() onCheck;

  /// The billing-return URL the page was sent to (sent to the server in the background, without its redirect).
  final Future<void> Function(Uri url)? onReturnUrl;

  /// Opens a non-payment link outside the app (tests replace it).
  final Future<void> Function(Uri url)? openExternal;

  /// Tests replace the platform web view.
  final CheckoutWebBuilder? webBuilder;

  @override
  State<CheckoutWebViewScreen> createState() => _CheckoutWebViewScreenState();
}

class _CheckoutWebViewScreenState extends State<CheckoutWebViewScreen> {
  CheckoutWebController? _web;
  int _progress = 0;
  String? _error;
  bool _done = false;
  bool _checking = false;

  Future<bool> _navigate(Uri uri, {bool mainFrame = true}) async {
    if (_done) return false;
    final d = decideCheckoutNav(uri, functionsHost: widget.functionsHost, mainFrame: mainFrame);
    switch (d.kind) {
      case CheckoutNavKind.allow:
        return true;
      case CheckoutNavKind.finish:
        _finish(d);
        return false;
      case CheckoutNavKind.external:
        unawaited(_external(uri));
        return false;
      case CheckoutNavKind.block:
        return false;
    }
  }

  bool _loadStart(Uri uri) {
    if (_done) return true;
    if (_error != null) setState(() => _error = null);
    final d = decideCheckoutNav(uri, functionsHost: widget.functionsHost);
    if (d.kind == CheckoutNavKind.finish) {
      _finish(d);
      return true;
    }
    if (d.kind == CheckoutNavKind.external || d.kind == CheckoutNavKind.block) {
      // A redirect we would not have allowed slipped past the override hook: stop it here.
      unawaited(_web?.stopLoading());
      if (d.kind == CheckoutNavKind.external) unawaited(_external(uri));
    }
    return false;
  }

  void _finish(CheckoutNavDecision d) {
    if (_done) return;
    _done = true;
    unawaited(_web?.stopLoading());
    final ret = d.serverReturnUrl;
    if (ret != null && widget.onReturnUrl != null) unawaited(widget.onReturnUrl!(ret));
    if (mounted) Navigator.of(context).pop(const CheckoutExit(CheckoutExitKind.returned));
  }

  Future<void> _external(Uri uri) async {
    try {
      if (widget.openExternal != null) {
        await widget.openExternal!(uri);
      } else {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (_) {}
  }

  Future<void> _close() async {
    if (_done || _checking) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(tr('Cancel payment?')),
        content: Text(tr("If you already paid, it still counts. We'll check before you leave.")),
        actions: [
          TextButton(key: const ValueKey('checkout-keep'), onPressed: () => Navigator.pop(d, false), child: Text(tr('Keep paying'))),
          TextButton(key: const ValueKey('checkout-cancel'), onPressed: () => Navigator.pop(d, true), child: Text(tr('Cancel payment'))),
        ],
      ),
    );
    if (ok != true || !mounted || _done) return;
    setState(() => _checking = true);
    PayUpdate? u;
    try {
      u = await widget.onCheck().timeout(const Duration(seconds: 25));
    } catch (_) {
      u = null;
    }
    if (!mounted || _done) return;
    _done = true;
    Navigator.of(context).pop(CheckoutExit(CheckoutExitKind.cancelled, checked: u));
  }

  Future<void> _checkNow() async {
    if (_checking || _done) return;
    setState(() => _checking = true);
    PayUpdate? u;
    try {
      u = await widget.onCheck().timeout(const Duration(seconds: 25));
    } catch (_) {}
    if (!mounted || _done) return;
    setState(() => _checking = false);
    if (u != null && u.settled) {
      _done = true;
      Navigator.of(context).pop(CheckoutExit(CheckoutExitKind.returned, checked: u));
      return;
    }
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        content: Text(tr(u == null || u.phase == PayPhase.offline
            ? "You're offline. Check your connection and try again."
            : "We haven't received this payment yet. If you just paid, give it a minute."))));
  }

  Future<void> _back() async {
    final w = _web;
    if (_error == null && w != null && await w.canGoBack()) {
      await w.goBack();
      return;
    }
    await _close();
  }

  void _retry() {
    setState(() {
      _error = null;
      _progress = 0;
    });
    unawaited(_web?.reload());
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final hooks = CheckoutWebHooks(
      url: widget.url,
      onCreated: (c) => _web = c,
      onNavigate: _navigate,
      onLoadStart: _loadStart,
      onProgress: (v) {
        if (mounted) setState(() => _progress = v);
      },
      onMainFrameError: (desc) {
        if (mounted && !_done) setState(() => _error = desc);
      },
      onLoadStop: () {
        if (mounted) setState(() => _progress = 100);
      },
    );
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_back());
      },
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          leading: IconButton(key: const ValueKey('checkout-close'), tooltip: 'Close', icon: const Icon(Icons.close_rounded), onPressed: _close),
          titleSpacing: 0,
          title: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.lock_rounded, size: 18, color: p.text),
            const SizedBox(width: 8),
            Text(tr('Secure payment'), style: TextStyle(color: p.text, fontSize: AppText.lead, fontWeight: FontWeight.w600)),
          ]),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(2),
            child: _progress < 100 && _error == null
                ? LinearProgressIndicator(value: _progress <= 0 ? null : _progress / 100, minHeight: 2, backgroundColor: Colors.transparent, color: p.text)
                : const SizedBox(height: 2),
          ),
        ),
        body: Stack(children: [
          Positioned.fill(child: (widget.webBuilder ?? _inAppWebView)(context, hooks)),
          if (_error != null)
            Positioned.fill(
              child: ColoredBox(
                color: p.bg,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.wifi_off_rounded, size: 40, color: p.muted),
                      const SizedBox(height: 14),
                      Text(tr("Couldn't load the payment page"), textAlign: TextAlign.center, style: Brand.serif(size: AppText.display, color: p.text)),
                      const SizedBox(height: 8),
                      Text(tr('Check your connection, then try again. If you already paid, it still counts.'),
                          textAlign: TextAlign.center, style: TextStyle(color: p.muted, fontSize: AppText.body, height: 1.4)),
                      const SizedBox(height: 18),
                      FilledButton(
                        key: const ValueKey('checkout-retry'),
                        style: FilledButton.styleFrom(backgroundColor: p.text, foregroundColor: p.bg, minimumSize: const Size(200, 48)),
                        onPressed: _retry,
                        child: Text(tr('Try again')),
                      ),
                      TextButton(onPressed: _checkNow, child: Text(tr("I've paid, check now"))),
                    ]),
                  ),
                ),
              ),
            ),
          if (_checking)
            Positioned.fill(
              child: ColoredBox(
                color: p.bg.withValues(alpha: 0.92),
                child: Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 14),
                    Text(tr('Checking your payment…'), style: TextStyle(color: p.text, fontSize: AppText.body)),
                  ]),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}

class _InAppController implements CheckoutWebController {
  _InAppController(this.c);
  final InAppWebViewController c;
  @override
  Future<void> reload() => c.reload();
  @override
  Future<bool> canGoBack() => c.canGoBack();
  @override
  Future<void> goBack() => c.goBack();
  @override
  Future<void> stopLoading() => c.stopLoading();
}

Widget _inAppWebView(BuildContext context, CheckoutWebHooks h) {
  return InAppWebView(
    initialUrlRequest: URLRequest(url: WebUri(h.url)),
    initialSettings: InAppWebViewSettings(
      javaScriptEnabled: true,
      useShouldOverrideUrlLoading: true,
      supportMultipleWindows: true,
      javaScriptCanOpenWindowsAutomatically: true,
      allowFileAccess: false,
      allowContentAccess: false,
      allowFileAccessFromFileURLs: false,
      allowUniversalAccessFromFileURLs: false,
      thirdPartyCookiesEnabled: true,
      clearCache: false,
      cacheEnabled: true,
      transparentBackground: false,
      mediaPlaybackRequiresUserGesture: true,
      supportZoom: false,
    ),
    onWebViewCreated: (c) => h.onCreated(_InAppController(c)),
    shouldOverrideUrlLoading: (c, action) async {
      final u = action.request.url;
      if (u == null) return NavigationActionPolicy.ALLOW;
      final ok = await h.onNavigate(Uri.parse(u.toString()), mainFrame: action.isForMainFrame);
      return ok ? NavigationActionPolicy.ALLOW : NavigationActionPolicy.CANCEL;
    },
    onCreateWindow: (c, action) async {
      // target=_blank / window.open: same rules, but loaded in this page (no second window).
      final u = action.request.url;
      if (u == null) return false;
      final uri = Uri.parse(u.toString());
      if (await h.onNavigate(uri)) await c.loadUrl(urlRequest: URLRequest(url: u));
      return false;
    },
    onLoadStart: (c, u) {
      if (u != null) h.onLoadStart(Uri.parse(u.toString()));
    },
    onProgressChanged: (c, v) => h.onProgress(v),
    onLoadStop: (c, u) => h.onLoadStop(),
    onReceivedError: (c, req, err) {
      if (req.isForMainFrame == false) return;
      if (err.type == WebResourceErrorType.CANCELLED || err.type == WebResourceErrorType.UNSUPPORTED_SCHEME) return;
      final u = Uri.tryParse(req.url.toString());
      if (u != null && u.scheme == 'telesia') return;
      h.onMainFrameError(err.description);
    },
  );
}
