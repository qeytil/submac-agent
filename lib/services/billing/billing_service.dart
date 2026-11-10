import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'billing_copy.dart';
import 'billing_api.dart';
import 'billing_models.dart';
import 'checkout_url.dart';
import 'pay_update.dart';

/// One payment attempt the app started, kept on the phone until it settles so a retry (even after the app was killed)
/// reuses the SAME idempotency key and the app can finish checking it on the next launch.
class PendingPurchase {
  final String key;
  final String userId;
  final String product; // billing.plans id (weekly, monthly, payg)
  final int? tokens; // pay as you go amount
  final String method; // wallet | checkout
  final String? wallet; // edahab | waafi | pbwallet
  final String? walletLabel; // EVC Plus, ZAAD... (display only)
  final String? account; // 2526XXXXXXXX, needed so a same-key retry matches the server's fingerprint
  final int createdMs;
  String? purchaseId;
  String? url;
  String lastPhase;

  PendingPurchase({
    required this.key,
    required this.userId,
    required this.product,
    this.tokens,
    required this.method,
    this.wallet,
    this.walletLabel,
    this.account,
    required this.createdMs,
    this.purchaseId,
    this.url,
    this.lastPhase = 'starting',
  });

  String get fingerprint => '$userId|$method|$product|${tokens ?? ''}|${wallet ?? ''}|${account ?? ''}';
  DateTime get createdAt => DateTime.fromMillisecondsSinceEpoch(createdMs);

  Map<String, dynamic> toJson() => {
        'key': key, 'uid': userId, 'product': product, 'tokens': tokens, 'method': method, 'wallet': wallet, 'wallet_label': walletLabel,
        'account': account, 'created': createdMs, 'purchase': purchaseId, 'url': url, 'phase': lastPhase,
      };

  static PendingPurchase? fromJson(Object? v) {
    if (v is! Map) return null;
    final key = v['key'], uid = v['uid'], product = v['product'];
    if (key is! String || uid is! String || product is! String) return null;
    return PendingPurchase(
      key: key,
      userId: uid,
      product: product,
      tokens: (v['tokens'] as num?)?.toInt(),
      method: v['method'] == 'wallet' ? 'wallet' : 'checkout',
      wallet: v['wallet'] as String?,
      walletLabel: v['wallet_label'] as String?,
      account: v['account'] as String?,
      createdMs: (v['created'] as num?)?.toInt() ?? 0,
      purchaseId: v['purchase'] as String?,
      url: v['url'] as String?,
      lastPhase: '${v['phase'] ?? 'starting'}',
    );
  }
}

/// "Done. 3M added." after a payment (the amount it added, when the server said).
String addedText(int tokens) => tokens > 0 ? tr('Done. {x} added.', {'x': tokensShort(tokens)}) : tr('Done. Payment received.');

/// Stops a poll loop (screen closed, user tapped something else).
class PollToken {
  bool cancelled = false;
  void cancel() => cancelled = true;
}

/// Wait before poll number [n] (0-based): starts at the server's hint (default 3 s), grows 1.5x, at most 20 s.
Duration pollDelay(int n, {int? hintSeconds}) {
  final base = (hintSeconds == null || hintSeconds <= 0 ? 3 : hintSeconds).clamp(2, 20).toDouble();
  final s = math.min(20.0, base * math.pow(1.5, n));
  return Duration(milliseconds: (s * 1000).round());
}

/// Plan & usage: usage cache (billing_usage + the x-telesia-* headers), payments with idempotency, polling and recovery.
/// Everything is inert until the server says billing is on (/status billing block, a usage header, or billing_usage.enabled).
class Billing with WidgetsBindingObserver {
  Billing({BillingApi? api, Future<void> Function(Duration)? sleep, DateTime Function()? now})
      : _apiOverride = api,
        _sleep = sleep ?? ((d) => Future<void>.delayed(d)),
        _now = now ?? DateTime.now;

  static final Billing I = Billing();

  final BillingApi? _apiOverride;
  BillingApi? _apiReal;
  BillingApi get api => _apiOverride ?? (_apiReal ??= SupabaseBillingApi());
  final Future<void> Function(Duration) _sleep;
  final DateTime Function() _now;

  static const _pendingKey = 'billing_pending_v1';
  static const _summaryKey = 'billing_usage_v2';
  static const pendingMaxAge = Duration(hours: 24);
  static const defaultPollWait = Duration(minutes: 3);
  static const defaultMaxPolls = 30;

  /// Billing is switched on for this user (server flag). Off = no Plan & usage entry, app as before.
  final enabled = ValueNotifier<bool>(false);
  final usage = ValueNotifier<UsageSummary?>(null);

  /// Tokens the user can still use today, from the last x-telesia-today-left header or usage read (null until seen).
  final balance = ValueNotifier<int?>(null);

  /// Unsettled payments kept on this phone for the signed-in user.
  final pending = ValueNotifier<List<PendingPurchase>>(const []);

  /// Bumps when the app comes back to the foreground or a telesia://pay link arrives: payment screens re-check.
  final resumeTick = ValueNotifier<int>(0);

  /// A short message for a snackbar (payment recovered after a restart...). Set by main.dart.
  void Function(String message)? onToast;

  SharedPreferences? _prefs;
  final List<PendingPurchase> _all = [];
  final Map<String, Future<PayUpdate>> _inFlight = {};
  final _notices = <String, BillingNotice>{};
  bool _observing = false;
  bool _recovering = false;
  final _uuid = const Uuid();

  Future<SharedPreferences> _p() async => _prefs ??= await SharedPreferences.getInstance();

  /// Call once at startup (cheap, no network unless there is an unsettled payment from earlier).
  Future<void> init() async {
    await _load();
    if (!_observing) {
      try {
        WidgetsBinding.instance.addObserver(this);
        _observing = true;
      } catch (_) {}
    }
    if (_mine().any((r) => r.purchaseId != null)) unawaited(recoverPending());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      resumeTick.value++;
      if (_mine().any((r) => r.purchaseId != null)) unawaited(recoverPending());
    }
  }

  // ------------------------------------------------------------------ server signals

  /// The /status answer's `billing` block (null / missing / enabled false = billing off). Same shape as billing_usage.
  void noteStatus(Object? block) {
    if (block is Map && block['enabled'] == true) {
      final s = UsageSummary.fromJson(block.map((k, v) => MapEntry('$k', v)), at: _now()).mergeCatalog(usage.value);
      usage.value = s;
      balance.value = s.todayLeft;
      enabled.value = true;
    } else {
      enabled.value = false;
    }
  }

  /// Contract A: every ai-chat answer carries x-telesia-today-left / total-left / resets-at / plan.
  void noteHeaders(Map<String, String> h) {
    final v = UsageSummary.headerValues(h);
    if (v == null) return;
    final now = _now();
    final cur = usage.value;
    usage.value = cur == null ? UsageSummary.fromJson({'enabled': true, ...v}, at: now) : cur.merged(v, at: now);
    if (v['today_left'] is int) balance.value = v['today_left'] as int;
    enabled.value = true;
  }

  /// A billing refusal seen by the cloud client. Kept by message so the chat's error card can find it.
  void noteNotice(BillingNotice n, {String? key}) {
    enabled.value = true;
    final k = key ?? n.message;
    _notices.remove(k);
    _notices[k] = n;
    while (_notices.length > 20) {
      _notices.remove(_notices.keys.first);
    }
    if (BillingNotice.limitCodes.contains(n.code)) balance.value = 0;
  }

  BillingNotice? noticeFor(String message) => _notices[message];

  // ------------------------------------------------------------------ usage

  Future<UsageSummary?> refreshUsage() async {
    try {
      final r = await api.rpc('billing_usage');
      if (r is! Map) return usage.value;
      final j = r.map((k, v) => MapEntry('$k', v));
      if (j['enabled'] != true) {
        enabled.value = false;
        return null;
      }
      final s = UsageSummary.fromJson(j, at: _now());
      usage.value = s;
      balance.value = s.todayLeft;
      enabled.value = true;
      unawaited(_saveSummary(j));
      return s;
    } catch (e) {
      debugPrint('billing: usage: $e');
      if (usage.value == null) await _loadSummary();
      return usage.value;
    }
  }

  /// Account deletion (Dev 3's dialog): one short line about paid balance the user would lose, or null when there is
  /// none (or billing is off / the check fails: never blocks the deletion).
  Future<String?> deletionWarning() async {
    try {
      final r = await api.rpc('billing_deletion_warning');
      if (r is! Map || r['has_paid'] != true) return null;
      final left = r['paid_left'] is num ? (r['paid_left'] as num).toInt() : 0;
      final per = r['tokens_per_reply'] is num ? (r['tokens_per_reply'] as num).toInt() : kDefaultTokensPerReply;
      if (left > 0) return tr('You still have {x} you paid for. Deleting your account loses it.', {'x': repliesText(left, perReply: per).toLowerCase()});
      return tr('A payment is still being confirmed.');
    } catch (e) {
      debugPrint('billing: deletion warning: $e');
      return null;
    }
  }

  /// Payments and what they added, newest first.
  Future<List<HistoryItem>> activity({int limit = 50}) async {
    final r = await api.rpc('billing_activity', params: {'p_limit': limit});
    if (r is Map && r['enabled'] == false) return const [];
    final u = usage.value;
    return parseActivity(r, catalog: u?.plans ?? const [], perReply: u?.tokensPerReply ?? kDefaultTokensPerReply);
  }

  // ------------------------------------------------------------------ payments

  List<PendingPurchase> _mine() {
    final uid = api.userId;
    return uid == null ? const [] : _all.where((r) => r.userId == uid).toList();
  }

  /// The attempt for this exact payment: an unsettled one from earlier (same product, method, wallet and number,
  /// under 24 h old) keeps its idempotency key, so retrying after a crash can never charge twice. Else a new key.
  Future<PendingPurchase> beginAttempt(
      {required String product, int? tokens, required String method, String? wallet, String? walletLabel, String? account}) async {
    await _load();
    final uid = api.userId ?? 'anon';
    final probe = PendingPurchase(key: '', userId: uid, product: product, tokens: tokens, method: method, wallet: wallet, account: account, createdMs: 0);
    final now = _now().millisecondsSinceEpoch;
    for (final r in _all) {
      if (r.fingerprint == probe.fingerprint && now - r.createdMs < pendingMaxAge.inMilliseconds) return r;
    }
    final a = PendingPurchase(
      key: 'app-${_uuid.v4()}',
      userId: uid,
      product: product,
      tokens: tokens,
      method: method,
      wallet: wallet,
      walletLabel: walletLabel,
      account: account,
      createdMs: now,
    );
    _all.add(a);
    await _save(); // persisted BEFORE the request goes out
    return a;
  }

  /// Drops [a]'s key so the next attempt for the same thing gets a fresh one (after a confirmed refusal).
  Future<void> forgetAttempt(PendingPurchase a) async {
    _all.removeWhere((r) => r.key == a.key);
    await _save();
  }

  /// Starts (or, with the same key, safely re-asks about) the payment. A second tap while one is in flight gets the
  /// same answer: one request per key at a time.
  Future<PayUpdate> submit(PendingPurchase a) {
    final running = _inFlight[a.key];
    if (running != null) return running;
    // (block body: returning the removed future from whenComplete would make it wait on itself)
    final f = _submit(a).whenComplete(() {
      _inFlight.remove(a.key);
    });
    _inFlight[a.key] = f;
    return f;
  }

  Future<PayUpdate> _submit(PendingPurchase a) async {
    final body = <String, dynamic>{
      'plan': a.product,
      if (a.tokens != null) 'tokens': a.tokens,
      if (a.method == 'wallet') ...{'method': 'wallet', 'wallet': a.wallet, 'account': a.account},
    };
    final dev = await api.deviceId();
    if (dev != null && dev.length >= 6) body['device_id'] = dev;
    PayUpdate u;
    try {
      final r = await api.postCheckout(body, idempotencyKey: a.key);
      u = PayUpdate.fromHttp(r.status, r.body, purchaseId: a.purchaseId, replay: r.headers['x-idempotent-replay'] == 'true');
    } on BillingNetworkError catch (e) {
      u = PayUpdate(PayPhase.offline, purchaseId: a.purchaseId, reason: e.kind, message: PayText.messageFor(PayPhase.offline, e.kind));
    } catch (e) {
      debugPrint('billing: checkout: $e');
      u = PayUpdate(PayPhase.offline, purchaseId: a.purchaseId, reason: 'offline', message: PayText.messageFor(PayPhase.offline, 'offline'));
    }
    await _record(a, u);
    return u;
  }

  /// One status check (GET billing-checkout?purchase=). The server re-verifies with the provider at most every 10 s.
  Future<PayUpdate> check(String purchaseId) async {
    PayUpdate u;
    try {
      final r = await api.getStatus(purchaseId);
      u = PayUpdate.fromHttp(r.status, r.body, purchaseId: purchaseId);
      if (r.status == 404) u = PayUpdate(PayPhase.error, purchaseId: purchaseId, reason: 'not_found', message: PayText.messageFor(PayPhase.error, 'not_found'), httpStatus: 404);
    } on BillingNetworkError catch (e) {
      u = PayUpdate(PayPhase.offline, purchaseId: purchaseId, reason: e.kind, message: PayText.messageFor(PayPhase.offline, e.kind));
    } catch (e) {
      u = PayUpdate(PayPhase.offline, purchaseId: purchaseId, reason: 'offline', message: PayText.messageFor(PayPhase.offline, 'offline'));
    }
    final a = _byPurchase(purchaseId);
    if (a != null) await _record(a, u);
    return u;
  }

  /// Polls until the payment settles, with backoff. Stops after [maxWait] / [maxPolls] and answers
  /// [PayPhase.stillWaiting] (the screen then offers "Check now"; foregrounding the app resumes polling).
  /// Being offline for a while does not end the loop early; it reports [PayPhase.offline] and keeps trying.
  Future<PayUpdate> poll(String purchaseId,
      {void Function(PayUpdate)? onUpdate, PollToken? token, Duration maxWait = defaultPollWait, int maxPolls = defaultMaxPolls, int? hintSeconds}) async {
    final start = _now();
    PayUpdate last = PayUpdate(PayPhase.processing, purchaseId: purchaseId, message: PayText.messageFor(PayPhase.processing, null));
    for (var n = 0; n < maxPolls; n++) {
      if (token?.cancelled == true) return last;
      await _sleep(pollDelay(n, hintSeconds: hintSeconds ?? last.pollAfterSeconds));
      if (token?.cancelled == true) return last;
      final u = await check(purchaseId);
      // A failed status read is not a failed payment: keep the last real phase, but say we are offline.
      last = u;
      onUpdate?.call(u);
      if (u.settled) return u;
      if (u.phase == PayPhase.error && u.reason == 'not_found') return u;
      if (u.phase == PayPhase.error && u.reason == 'auth_required') return u;
      if (_now().difference(start) >= maxWait) break;
    }
    final w = PayUpdate(PayPhase.stillWaiting,
        purchaseId: purchaseId, reason: last.reason, message: PayText.messageFor(PayPhase.stillWaiting, null), httpStatus: last.httpStatus);
    onUpdate?.call(w);
    return w;
  }

  /// The billing-return URL the payment page was sent to: let the server see it (binds the payment ref).
  Future<void> touchReturn(Uri u) => api.touchReturn(u);

  String get functionsHost => api.functionsHost;

  /// A telesia://pay link (the payment page was opened outside the app, or the in-app page missed the redirect).
  /// Never trusted: it only makes the app check that purchase now.
  Future<void> handlePayLink(Uri u) async {
    final d = parsePayDeepLink(u);
    if (d == null) return;
    resumeTick.value++;
    final id = d.purchaseId;
    if (id == null) return;
    final known = _byPurchase(id);
    final r = await check(id);
    if (known == null && r.phase == PayPhase.success) {
      onToast?.call(addedText(r.tokensAdded));
    }
  }

  /// Checks every unsettled payment of this user (after a restart, on foreground). Settled ones are dropped and,
  /// when the app had lost track of them, announced in a snackbar.
  Future<void> recoverPending({bool announce = true}) async {
    if (_recovering) return;
    _recovering = true;
    try {
      await _load();
      final now = _now().millisecondsSinceEpoch;
      for (final r in _mine()) {
        if (_inFlight.containsKey(r.key)) continue;
        final old = now - r.createdMs > pendingMaxAge.inMilliseconds;
        final pid = r.purchaseId;
        if (pid == null) {
          // Never got an answer before the app died. Only a tap re-sends it (re-sending on its own could start a
          // wallet prompt the user no longer expects). Forgotten after 24 h; the server expires it too.
          if (old) await forgetAttempt(r);
          continue;
        }
        final u = await check(pid);
        if (u.phase == PayPhase.success) {
          if (announce) onToast?.call(addedText(u.tokensAdded));
        } else if (u.phase == PayPhase.failed) {
          if (announce && r.lastPhase != 'failed') onToast?.call('A payment you started didn\'t go through. No money was taken.');
        } else if (old || (u.phase == PayPhase.error && u.reason == 'not_found')) {
          await forgetAttempt(r);
        }
      }
    } finally {
      _recovering = false;
    }
  }

  /// Unsettled payments to show in the wallet ("Payment being confirmed · Check now").
  List<PendingPurchase> get unsettled => _mine();

  PendingPurchase? _byPurchase(String id) {
    for (final r in _all) {
      if (r.purchaseId == id) return r;
    }
    return null;
  }

  Future<void> _record(PendingPurchase a, PayUpdate u) async {
    if (u.purchaseId != null) a.purchaseId = u.purchaseId;
    if (u.url != null) a.url = u.url;
    a.lastPhase = u.phase.name;
    if (u.settled || PayUpdate.freshKeyReasons.contains(u.reason) || (u.phase == PayPhase.error && a.purchaseId == null && u.httpStatus > 0 && u.httpStatus < 500)) {
      // Done (or refused before any purchase existed): the next attempt gets a fresh key.
      _all.removeWhere((r) => r.key == a.key);
    }
    await _save();
    if (u.phase == PayPhase.success) unawaited(refreshUsage());
  }

  Future<void> _load() async {
    if (_loaded) return;
    try {
      final p = await _p();
      final raw = p.getString(_pendingKey);
      if (raw != null) {
        final l = jsonDecode(raw);
        if (l is List) {
          for (final x in l) {
            final r = PendingPurchase.fromJson(x);
            if (r != null && !_all.any((e) => e.key == r.key)) _all.add(r);
          }
        }
      }
    } catch (e) {
      debugPrint('billing: load pending: $e');
    }
    _loaded = true;
    pending.value = List.unmodifiable(_mine());
  }

  bool _loaded = false;

  Future<void> _save() async {
    pending.value = List.unmodifiable(_mine());
    try {
      final p = await _p();
      await p.setString(_pendingKey, jsonEncode([for (final r in _all) r.toJson()]));
    } catch (e) {
      debugPrint('billing: save pending: $e');
    }
  }

  Future<void> _saveSummary(Map<String, dynamic> j) async {
    try {
      final uid = api.userId;
      if (uid == null) return;
      await (await _p()).setString(_summaryKey, jsonEncode({'uid': uid, 'at': _now().toIso8601String(), 'summary': j}));
    } catch (_) {}
  }

  Future<void> _loadSummary() async {
    try {
      final raw = (await _p()).getString(_summaryKey);
      if (raw == null) return;
      final j = jsonDecode(raw);
      if (j is! Map || j['uid'] != api.userId || j['summary'] is! Map) return;
      usage.value = UsageSummary.fromJson((j['summary'] as Map).map((k, v) => MapEntry('$k', v)),
          at: DateTime.tryParse('${j['at']}') ?? _now());
    } catch (_) {}
  }

  /// Signed out: forget the cached balance (pending purchases stay; they belong to that account and are only
  /// checked while it is signed in).
  void signedOut() {
    usage.value = null;
    balance.value = null;
    enabled.value = false;
    pending.value = const [];
  }
}
