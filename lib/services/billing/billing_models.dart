import 'package:flutter/foundation.dart';

import 'billing_copy.dart';

/// Plans, usage and payments as the app sees them (billing v2: no coins, one price per token).
/// Every value comes from the server (`billing_usage`, the x-telesia-* headers, error payloads); nothing here is a price list.

int _int(Object? v, [int d = 0]) => v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? d;
int? _intOrNull(Object? v) => v == null ? null : (v is num ? v.toInt() : int.tryParse('$v'));
double _dbl(Object? v, [double d = 0]) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? d;
DateTime? _time(Object? v) => v == null ? null : DateTime.tryParse('$v')?.toUtc();
String? _str(Object? v) => v == null || '$v'.isEmpty ? null : '$v';
Map<String, dynamic> _map(Object? v) => v is Map ? v.map((k, x) => MapEntry('$k', x)) : const {};
List<Map<String, dynamic>> _maps(Object? v) => v is List ? [for (final x in v) if (x is Map) _map(x)] : const [];

/// Default tokens per reply (1M ≈ 270 replies) until the server says otherwise.
const kDefaultTokensPerReply = 3700;

/// How many replies [tokens] buys (rounded down, never negative).
int repliesFor(int tokens, {int perReply = kDefaultTokensPerReply}) {
  final per = perReply <= 0 ? kDefaultTokensPerReply : perReply;
  return tokens <= 0 ? 0 : (tokens / per).floor();
}

/// "About 270 replies". Main screens count replies, never "tokens" and never "unlimited".
String repliesText(int tokens, {int perReply = kDefaultTokensPerReply}) {
  final n = repliesFor(tokens, perReply: perReply);
  return tr(n == 1 ? 'About {n} reply' : 'About {n} replies', {'n': groupDigits(n)});
}

/// 1000000 -> "1,000,000".
String groupDigits(int n) {
  final s = n.abs().toString();
  final b = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

/// 1000000 -> "1M", 120000 -> "120k", 2500000 -> "2.5M". Used on pay-as-you-go only.
String tokensShort(int n) {
  String trim(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
  if (n >= 1000000) return '${trim(n / 1000000)}M';
  if (n >= 1000) return '${trim(n / 1000)}k';
  return '$n';
}

/// "$4.99"
String usdText(double v) => '\$${v.toStringAsFixed(2)}';

/// "5 h 4 min", "12 min", "3 days".
String durationWords(Duration d) {
  final m = (d.inSeconds / 60).ceil().clamp(1, 1 << 30);
  if (m >= 48 * 60) return tr('{n} days', {'n': '${(m / 1440).round()}'});
  final h = m ~/ 60, mm = m % 60;
  if (h == 0) return tr('{n} min', {'n': '$mm'});
  return mm == 0 ? tr('{n} h', {'n': '$h'}) : tr('{h} h {m} min', {'h': '$h', 'm': '$mm'});
}

/// "00:00" on the phone's clock for the server's reset instant (midnight EAT). The app never assumes UTC.
String clockText(DateTime at) {
  final l = at.toLocal();
  return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
}

/// Known plan names in the app's language; [fallback] (the catalogue name) for anything else.
String planName(String id, [String? fallback]) {
  switch (id) {
    case 'free':
      return tr('Free');
    case 'weekly':
      return tr('Weekly');
    case 'monthly':
      return tr('Monthly');
    case 'monthly_plus':
      return tr('Monthly Plus');
    case 'payg':
      return tr('Pay as you go');
  }
  return fallback ?? id;
}

/// "3/11" (day/month) on the phone's clock.
String dayText(DateTime at) {
  final l = at.toLocal();
  return '${l.day}/${l.month}';
}

/// One row of the catalogue (billing.plans).
@immutable
class PlanInfo {
  final String id;
  final String kind; // free | package | payg
  final String tier; // free | weekly | monthly | payg
  final String name;
  final double priceUsd; // package: the price; payg: price per [unitTokens]
  final int totalTokens;
  final int dailyTokens;
  final double validityDays;
  final int unitTokens;
  final int minTokens;
  final int maxTokens;
  final int stepTokens;
  final List<int> presets;
  const PlanInfo({
    required this.id,
    required this.kind,
    this.tier = '',
    required this.name,
    this.priceUsd = 0,
    this.totalTokens = 0,
    this.dailyTokens = 0,
    this.validityDays = 0,
    this.unitTokens = 0,
    this.minTokens = 0,
    this.maxTokens = 0,
    this.stepTokens = 0,
    this.presets = const [],
  });

  factory PlanInfo.fromJson(Map<String, dynamic> j) => PlanInfo(
        id: '${j['id']}',
        kind: '${j['kind'] ?? ''}',
        tier: '${j['tier'] ?? ''}',
        name: '${j['name'] ?? j['id']}',
        priceUsd: _dbl(j['price_usd']),
        totalTokens: _int(j['total_tokens']),
        dailyTokens: _int(j['daily_tokens']),
        validityDays: _dbl(j['validity_days']),
        unitTokens: _int(j['unit_tokens']),
        minTokens: _int(j['min_tokens']),
        maxTokens: _int(j['max_tokens']),
        stepTokens: _int(j['step_tokens']),
        presets: [for (final x in (j['presets'] is List ? j['presets'] as List : const [])) _int(x)].where((x) => x > 0).toList(),
      );

  Map<String, dynamic> toJson() => {
        'id': id, 'kind': kind, 'tier': tier, 'name': name, 'price_usd': priceUsd, 'total_tokens': totalTokens,
        'daily_tokens': dailyTokens, 'validity_days': validityDays, 'unit_tokens': unitTokens, 'min_tokens': minTokens,
        'max_tokens': maxTokens, 'step_tokens': stepTokens, 'presets': presets,
      };

  bool get isPackage => kind == 'package';
  bool get isPayg => kind == 'payg';

  /// Pay as you go: the amount snapped to the plan's steps and limits.
  int clampTokens(int n) {
    if (!isPayg || stepTokens <= 0) return n;
    final snapped = (n / stepTokens).round() * stepTokens;
    return snapped.clamp(minTokens, maxTokens);
  }

  /// What [tokens] costs (packages: the fixed price). Same rounding as the server's billing.quote.
  double priceFor(int tokens) {
    if (!isPayg || unitTokens <= 0) return priceUsd;
    return (tokens / unitTokens * priceUsd * 100).round() / 100;
  }

  /// "7 days", "30 days", "12 months".
  String get validityText {
    if (validityDays <= 0) return '';
    if (validityDays >= 360) return tr('{n} months', {'n': '${(validityDays / 30.4).round()}'});
    final d = validityDays.round();
    return tr(d == 1 ? '{n} day' : '{n} days', {'n': '$d'});
  }

  /// The plan's name in the app's language (the catalogue's own name for anything new).
  String get label => planName(id, name);
}

/// A package the user holds (running or queued).
@immutable
class PackageInfo {
  final String id;
  final String plan;
  final String tier;
  final DateTime? startsAt;
  final DateTime? endsAt;
  final int dailyAmount;
  final int todayUsed;
  final int todayLeft;
  final int totalAmount;
  final int totalLeft;
  const PackageInfo({
    required this.id,
    required this.plan,
    this.tier = '',
    this.startsAt,
    this.endsAt,
    this.dailyAmount = 0,
    this.todayUsed = 0,
    this.todayLeft = 0,
    this.totalAmount = 0,
    this.totalLeft = 0,
  });
  factory PackageInfo.fromJson(Map<String, dynamic> j) => PackageInfo(
        id: '${j['id'] ?? ''}',
        plan: '${j['plan'] ?? ''}',
        tier: '${j['tier'] ?? ''}',
        startsAt: _time(j['starts_at']),
        endsAt: _time(j['ends_at']),
        dailyAmount: _int(j['daily_amount']),
        todayUsed: _int(j['today_used']),
        todayLeft: _int(j['today_left']),
        totalAmount: _int(j['total_amount']),
        totalLeft: _int(j['total_left'], _int(j['total_amount'])),
      );
}

/// Pay-as-you-go tokens with their own expiry.
@immutable
class PaygBalance {
  final String id;
  final int left;
  final int amount;
  final DateTime? expiresAt;
  const PaygBalance({required this.id, this.left = 0, this.amount = 0, this.expiresAt});
  factory PaygBalance.fromJson(Map<String, dynamic> j) =>
      PaygBalance(id: '${j['id'] ?? ''}', left: _int(j['left']), amount: _int(j['amount']), expiresAt: _time(j['expires_at']));
}

/// `billing_usage()` and the x-telesia-* headers: what the user can spend now.
@immutable
class UsageSummary {
  final bool enabled;
  final String plan; // free | weekly | monthly | payg
  final int todayLeft;
  final int totalLeft;
  final int paidLeft;
  final DateTime? resetsAt;
  final int tokensPerReply;
  final int freeDaily;
  final int freeTodayLeft;
  final List<PackageInfo> packages;
  final List<PackageInfo> queued;
  final int paygLeft;
  final List<PaygBalance> balances;
  final List<PlanInfo> plans;
  final DateTime fetchedAt;
  final Map<String, dynamic> raw;

  const UsageSummary({
    this.enabled = false,
    this.plan = 'free',
    this.todayLeft = 0,
    this.totalLeft = 0,
    this.paidLeft = 0,
    this.resetsAt,
    this.tokensPerReply = kDefaultTokensPerReply,
    this.freeDaily = 0,
    this.freeTodayLeft = 0,
    this.packages = const [],
    this.queued = const [],
    this.paygLeft = 0,
    this.balances = const [],
    this.plans = const [],
    required this.fetchedAt,
    this.raw = const {},
  });

  factory UsageSummary.fromJson(Map<String, dynamic> j, {DateTime? at}) {
    final free = _map(j['free']);
    final payg = _map(j['payg']);
    return UsageSummary(
      enabled: j['enabled'] == true,
      plan: _str(j['plan']) ?? 'free',
      todayLeft: _int(j['today_left']),
      totalLeft: _int(j['total_left']),
      paidLeft: _int(j['paid_left']),
      resetsAt: _time(j['resets_at']),
      tokensPerReply: _int(j['tokens_per_reply'], kDefaultTokensPerReply),
      freeDaily: _int(free['daily']),
      freeTodayLeft: _int(free['today_left']),
      packages: [for (final p in _maps(j['packages'])) PackageInfo.fromJson(p)],
      queued: [for (final p in _maps(j['queued'])) PackageInfo.fromJson(p)],
      paygLeft: _int(payg['left']),
      balances: [for (final b in _maps(j['balances'])) PaygBalance.fromJson(b)],
      plans: [for (final p in _maps(j['plans'])) PlanInfo.fromJson(p)],
      fetchedAt: at ?? DateTime.now(),
      raw: j,
    );
  }

  /// The four Contract A headers on a chat answer (x-telesia-today-left / total-left / resets-at / plan). Null when the
  /// answer carried none of them.
  static Map<String, dynamic>? headerValues(Map<String, String> h) {
    String? g(String k) {
      final v = h[k] ?? h[k.toLowerCase()];
      return v == null || v.trim().isEmpty ? null : v.trim();
    }

    final today = g('x-telesia-today-left'), total = g('x-telesia-total-left'), resets = g('x-telesia-resets-at'), plan = g('x-telesia-plan');
    if (today == null && total == null && resets == null && plan == null) return null;
    return {
      if (today != null && int.tryParse(today) != null) 'today_left': int.parse(today),
      if (total != null && int.tryParse(total) != null) 'total_left': int.parse(total),
      if (resets != null && DateTime.tryParse(resets) != null) 'resets_at': resets,
      if (plan != null) 'plan': plan,
    };
  }

  /// Same summary with fresher balance values (headers, /status), keeping what they do not carry (catalogue...).
  UsageSummary merged(Map<String, dynamic> fresh, {DateTime? at}) =>
      UsageSummary.fromJson({...raw, 'enabled': true, ...fresh}, at: at ?? fetchedAt);

  /// Same balances, but keep the catalogue we already have (a /status block has none).
  UsageSummary mergeCatalog(UsageSummary? old) => old == null || plans.isNotEmpty
      ? this
      : UsageSummary.fromJson({...raw, 'plans': [for (final p in old.plans) p.toJson()]}, at: fetchedAt);

  PlanInfo? planById(String id) {
    for (final p in plans) {
      if (p.id == id) return p;
    }
    return null;
  }

  List<PlanInfo> get packagePlans => plans.where((p) => p.isPackage).toList();
  PlanInfo? get paygPlan {
    for (final p in plans) {
      if (p.isPayg) return p;
    }
    return null;
  }

  /// "Free", "Weekly", "Monthly", "Pay as you go".
  String get planLabel {
    switch (plan) {
      case 'weekly':
        return tr('Weekly');
      case 'monthly':
        return tr('Monthly');
      case 'payg':
        return tr('Pay as you go');
    }
    return tr('Free');
  }

  /// When the running package ends (the last one when several are running; queued ones not counted).
  DateTime? get packageEndsAt {
    DateTime? out;
    for (final p in [...packages, ...queued]) {
      final e = p.endsAt;
      if (e != null && (out == null || e.isAfter(out))) out = e;
    }
    return out;
  }

  int get todayReplies => repliesFor(todayLeft, perReply: tokensPerReply);
  int get totalReplies => repliesFor(totalLeft, perReply: tokensPerReply);
}

@immutable
class HistoryItem {
  final String id;
  final String kind;
  final String title;
  final String detail;
  final DateTime? at;
  const HistoryItem({required this.id, required this.kind, required this.title, this.detail = '', this.at});
}

/// `billing_activity()` (payments + what was added or taken back), newest first.
List<HistoryItem> parseActivity(Object? v, {List<PlanInfo> catalog = const [], int perReply = kDefaultTokensPerReply}) {
  final j = _map(v);
  String nameOf(Object? id) {
    for (final p in catalog) {
      if (p.id == id) return p.label;
    }
    return id == null ? '' : planName('$id');
  }

  final out = <HistoryItem>[];
  for (final p in _maps(j['payments'])) {
    final st = '${p['status'] ?? ''}';
    final title = tr(st == 'paid'
        ? 'Paid'
        : st == 'pending'
            ? 'Payment being confirmed'
            : st == 'failed'
                ? 'Payment not completed'
                : st == 'reversed'
                    ? 'Payment refunded'
                    : 'Payment');
    out.add(HistoryItem(
      id: 'p${p['id']}',
      kind: 'payment_$st',
      title: title,
      detail: [nameOf(p['plan_id']), if (p['amount_usd'] != null) usdText(_dbl(p['amount_usd']))].where((s) => s.isNotEmpty).join(' · '),
      at: _time(p['created_at']),
    ));
  }
  for (final g in _maps(j['grants'])) {
    final kind = '${g['kind'] ?? ''}';
    if (kind == 'grant') continue; // the payment row already shows it
    final n = _int(g['tokens']);
    out.add(HistoryItem(
      id: 'g${g['id']}',
      kind: 'ledger_$kind',
      title: tr(n < 0 ? 'Taken back' : 'Added'),
      detail: repliesText(n.abs(), perReply: perReply),
      at: _time(g['created_at']),
    ));
  }
  out.sort((a, b) => (b.at ?? DateTime(0)).compareTo(a.at ?? DateTime(0)));
  return out;
}

/// A usage refusal from ai-chat (Contract A): limit_daily, limit_total, no_plan, plus busy (too_long, blocked and
/// server are not billing). Shapes: {error:{code,message}, billing?:{reason, resets_at, ...}} or {code, message, resets_at}.
@immutable
class BillingNotice {
  static const knownCodes = {'limit_daily', 'limit_total', 'no_plan', 'busy'};
  static const limitCodes = {'limit_daily', 'limit_total', 'no_plan'};

  final String code;
  final String reason;
  final String message;
  final int status;
  final DateTime? resetsAt;
  final int? retryAfterSeconds;
  final DateTime seenAt;

  const BillingNotice({
    required this.code,
    this.reason = '',
    this.message = '',
    this.status = 0,
    this.resetsAt,
    this.retryAfterSeconds,
    required this.seenAt,
  });

  /// null when [body] is not a usage refusal. Never throws, whatever the body.
  static BillingNotice? tryParse(int status, Object? body, {DateTime? now}) {
    try {
      final j = _map(body);
      final e = _map(j['error']);
      final bm = _map(j['billing']);
      final code = '${e['code'] ?? j['code'] ?? ''}';
      if (code.isEmpty) return null;
      // Without a billing block only the three limit codes count (a plain `busy` stays a normal error).
      if (bm.isEmpty && !limitCodes.contains(code)) return null;
      return BillingNotice(
        code: code,
        reason: '${bm['reason'] ?? e['reason'] ?? j['reason'] ?? ''}',
        message: '${e['message'] ?? j['message'] ?? ''}',
        status: status,
        resetsAt: _time(bm['resets_at'] ?? j['resets_at'] ?? e['resets_at']),
        retryAfterSeconds: _intOrNull(j['retry_after_seconds'] ?? e['retry_after']),
        seenAt: now ?? DateTime.now(),
      );
    } catch (_) {
      return null;
    }
  }

  bool get known => knownCodes.contains(code);

  /// Info only (waiting helps), versus a limit (getting more helps).
  bool get isInfo => code == 'busy';

  /// One short line, the sheet's title.
  String get title {
    switch (code) {
      case 'limit_daily':
        return tr(reason == 'bot_share' ? 'Bots have used their share for today.' : "You've used today's replies.");
      case 'limit_total':
        return tr("You've used all your replies.");
      case 'no_plan':
        return tr('You need a plan for this.');
      case 'busy':
        return tr('Telesia is busy. Try again soon.');
    }
    return tr("This reply couldn't be sent.");
  }

  /// "Resets at midnight." / "Resets at 00:00 (in 5 h 4 min)." from the time the server sent.
  String resetLine({DateTime? now}) {
    if (code != 'limit_daily') return '';
    final at = resetsAt;
    if (at == null) return tr('Resets at midnight.');
    final secs = at.difference((now ?? DateTime.now()).toUtc()).inSeconds;
    if (secs <= 0) return tr('Resets at midnight.');
    return tr('Resets at {t} (in {d}).', {'t': clockText(at), 'd': durationWords(Duration(seconds: secs))});
  }
}
