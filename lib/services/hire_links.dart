import 'dart:async';

// app_links comes with supabase_flutter (same version the sign-in links use); pinning it again here could split them.
// ignore: depend_on_referenced_packages
import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

import 'billing/billing_service.dart';
import 'rewards.dart';

/// A "Hire in SubMac" link from a public bot page (submac.site/b/<code>):
///   submac://hire?bot=<code>&ref=<ref>   or   https://submac.site/b/<code>?ref=<ref>
/// <code> is a share code (ABCD-2345), a Bot Store listing id (uuid) or a bot name slug.
@immutable
class HireLink {
  const HireLink(this.code, {this.ref});
  final String code;
  final String? ref;

  static final _ref = RegExp(r'^[A-Za-z0-9_-]{1,40}$');
  static final _code = RegExp(r'^[A-Za-z0-9-]{1,80}$');

  /// The invite code of an invite link (submac://invite?ref=CODE or https://submac.site/download?ref=CODE), else null.
  static String? inviteRef(Uri u) {
    final isInvite = (u.scheme == 'submac' && u.host == 'invite') ||
        ((u.scheme == 'https' || u.scheme == 'http') && (u.host == 'submac.site' || u.host == 'www.submac.site') &&
            u.pathSegments.isNotEmpty && u.pathSegments.first == 'download');
    final ref = u.queryParameters['ref']?.trim();
    return isInvite && ref != null && _ref.hasMatch(ref) ? ref : null;
  }

  /// null when [u] is not a hire link.
  static HireLink? parse(Uri u) {
    String? code;
    if (u.scheme == 'submac' && u.host == 'hire') {
      // bot= (not code=: Supabase treats code= as a login callback); code= kept for old links.
      code = u.queryParameters['bot'] ?? u.queryParameters['code'];
    } else if ((u.scheme == 'https' || u.scheme == 'http') && (u.host == 'submac.site' || u.host == 'www.submac.site') &&
        u.pathSegments.length >= 2 && u.pathSegments.first == 'b') {
      code = u.pathSegments[1];
    }
    code = code?.trim();
    if (code == null || !_code.hasMatch(code)) return null;
    final ref = u.queryParameters['ref']?.trim();
    return HireLink(code, ref: ref != null && _ref.hasMatch(ref) ? ref : null);
  }
}

/// Listens for hire links (cold start and while running) and keeps the newest one until the signed-in home screen takes it.
class HireLinks {
  HireLinks._();
  static final HireLinks I = HireLinks._();

  final pending = ValueNotifier<HireLink?>(null);

  /// The referrer code of the last hire link (plan 2.4). Also handed to [Rewards], which claims it once after sign-up.
  String? lastRef;

  // Lives as long as the app (a singleton listening for links), so it is never cancelled.
  // ignore: cancel_subscriptions
  StreamSubscription<Uri>? _sub;

  /// Call once at startup. app_links 6.x also emits the link that launched the app.
  void listen() {
    if (_sub != null) return;
    try {
      _sub = AppLinks().uriLinkStream.listen((u) {
        // Back from a payment page opened outside the app (fallback; normally it opens in-app): check that purchase.
        if (u.scheme == 'submac' && u.host == 'pay') {
          unawaited(Billing.I.handlePayLink(u));
          return;
        }
        final inv = HireLink.inviteRef(u);
        if (inv != null) {
          unawaited(Rewards.I.setRef(inv, source: 'link'));
          return;
        }
        final l = HireLink.parse(u);
        if (l == null) return;
        if (l.ref != null) {
          lastRef = l.ref;
          unawaited(Rewards.I.setRef(l.ref!, source: 'hire_link'));
        }
        pending.value = l;
      }, onError: (_) {});
    } catch (e) {
      debugPrint('hire links unavailable: $e');
    }
  }

  /// Takes the pending link (once).
  HireLink? take() {
    final l = pending.value;
    pending.value = null;
    return l;
  }
}
