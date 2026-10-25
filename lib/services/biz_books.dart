import 'dart:convert';
import 'dart:math' as math;

/// The business books behind SubMac's business tools: the profile, money accounts, stock items, customers and
/// suppliers, every transaction, business documents (invoices, quotes, receipts) and tasks. Pure Dart (no files, no
/// Flutter) so it can be tested; [BizTools] loads and saves it as Business/books.json in the workspace.
///
/// Money rules (one currency per business, the profile's):
/// - sale: revenue = amount; cash in = paid; the unpaid part is owed by the customer. Item lines take stock out and
///   carry their cost (cost of goods sold).
/// - purchase: stock in (item lines raise quantity and update cost); cash out = paid; the unpaid part is owed to the supplier.
///   A purchase without item lines counts as cost of goods in profit and loss.
/// - expense: cost in profit and loss; cash out = paid; unpaid part owed to the supplier.
/// - payment_in / payment_out: money received from a customer / paid to a supplier (settles debts), or other income.
/// - owner_in / owner_out: the owner puts money in or takes it out (not profit).
/// - transfer: moves money between accounts (Cash -> EVC Plus).
/// - owed_to_me / i_owe: a debt written down with no money moving (an old debt, a loan given or taken).
class BizBooks {
  BizBooks([Map<String, dynamic>? j]) {
    final m = j ?? const <String, dynamic>{};
    profile = Map<String, dynamic>.from((m['profile'] as Map?) ?? const {});
    accounts = [for (final a in (m['accounts'] as List? ?? const [])) '$a'];
    if (accounts.isEmpty) accounts = ['Cash'];
    items = _maps(m['items']);
    contacts = _maps(m['contacts']);
    tx = _maps(m['tx']);
    docs = _maps(m['docs']);
    tasks = _maps(m['tasks']);
    seq = {for (final e in ((m['seq'] as Map?) ?? const {}).entries) '${e.key}': (e.value as num).toInt()};
  }

  late Map<String, dynamic> profile;
  late List<String> accounts;
  late List<Map<String, dynamic>> items;
  late List<Map<String, dynamic>> contacts;
  late List<Map<String, dynamic>> tx;
  late List<Map<String, dynamic>> docs;
  late List<Map<String, dynamic>> tasks;
  late Map<String, int> seq;

  static List<Map<String, dynamic>> maps(dynamic v) => _maps(v);
  static List<Map<String, dynamic>> _maps(dynamic v) =>
      [for (final e in (v as List? ?? const [])) if (e is Map) Map<String, dynamic>.from(e)];

  Map<String, dynamic> toJson() => {
        'v': 1,
        'profile': profile,
        'accounts': accounts,
        'items': items,
        'contacts': contacts,
        'tx': tx,
        'docs': docs,
        'tasks': tasks,
        'seq': seq,
      };

  String encode() => jsonEncode(toJson());
  static BizBooks decode(String s) {
    try {
      return BizBooks(jsonDecode(s) as Map<String, dynamic>);
    } catch (_) {
      return BizBooks();
    }
  }

  // ------------------------------------------------------------------ helpers

  String get currency => '${profile['currency'] ?? 'USD'}'.toUpperCase();
  String get name => '${profile['name'] ?? ''}'.trim();

  String nextId(String prefix) {
    final n = (seq[prefix] ?? 0) + 1;
    seq[prefix] = n;
    return '$prefix$n';
  }

  /// Document numbers: INV-0001, QT-0001, RCP-0001...
  String nextDocNo(String kind) {
    const pre = {'invoice': 'INV', 'quote': 'QT', 'receipt': 'RCP', 'delivery_note': 'DN', 'purchase_order': 'PO'};
    final p = pre[kind] ?? 'DOC';
    final n = (seq['doc_$p'] ?? 0) + 1;
    seq['doc_$p'] = n;
    return '$p-${n.toString().padLeft(4, '0')}';
  }

  static double d(dynamic v) {
    if (v is num) return v.toDouble();
    if (v == null) return 0;
    return double.tryParse('$v'.replaceAll(',', '').replaceAll(RegExp(r'[^\d.\-]'), '')) ?? 0;
  }

  static String money(double v) {
    final neg = v < 0;
    final a = v.abs();
    final whole = a.truncate();
    final cents = ((a - whole) * 100).round();
    final w = '${cents == 100 ? whole + 1 : whole}';
    final b = StringBuffer();
    for (var i = 0; i < w.length; i++) {
      if (i > 0 && (w.length - i) % 3 == 0) b.write(',');
      b.write(w[i]);
    }
    final c = cents == 100 ? 0 : cents;
    return '${neg ? '-' : ''}$b${c == 0 ? '' : '.${c.toString().padLeft(2, '0')}'}';
  }

  String m(double v) => '${money(v)} $currency';

  static String today() => DateTime.now().toIso8601String().substring(0, 10);

  static String day(dynamic v) {
    final s = '${v ?? ''}'.trim();
    if (s.isEmpty) return today();
    final t = DateTime.tryParse(s);
    return t == null ? today() : t.toIso8601String().substring(0, 10);
  }

  static String norm(String s) => s.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

  Map<String, dynamic>? item(dynamic ref) {
    final r = '${ref ?? ''}'.trim();
    if (r.isEmpty) return null;
    for (final i in items) {
      if (i['id'] == r || (('${i['sku'] ?? ''}').isNotEmpty && norm('${i['sku']}') == norm(r))) return i;
    }
    for (final i in items) {
      if (norm('${i['name']}') == norm(r)) return i;
    }
    final hits = items.where((i) => norm('${i['name']}').contains(norm(r))).toList();
    return hits.length == 1 ? hits.first : null;
  }

  Map<String, dynamic>? contact(dynamic ref, {String? type}) {
    final r = '${ref ?? ''}'.trim();
    if (r.isEmpty) return null;
    final pool = contacts.where((c) => type == null || c['type'] == type || c['type'] == 'both').toList();
    for (final c in pool) {
      if (c['id'] == r) return c;
    }
    for (final c in pool) {
      if (norm('${c['name']}') == norm(r) || ('${c['phone'] ?? ''}'.isNotEmpty && '${c['phone']}'.replaceAll(' ', '') == r.replaceAll(' ', ''))) {
        return c;
      }
    }
    final hits = pool.where((c) => norm('${c['name']}').contains(norm(r))).toList();
    return hits.length == 1 ? hits.first : null;
  }

  /// Finds or creates a contact by name (so "sold to Ahmed on credit" just works).
  Map<String, dynamic> contactOrNew(String nameOrId, String type) {
    final c = contact(nameOrId, type: type) ?? contact(nameOrId);
    if (c != null) return c;
    final n = {'id': nextId(type == 'supplier' ? 'S' : 'C'), 'type': type, 'name': nameOrId.trim(), 'phone': '', 'address': '', 'note': ''};
    contacts.add(n);
    return n;
  }

  String account(dynamic a) {
    final s = '${a ?? ''}'.trim();
    if (s.isEmpty) return accounts.first;
    for (final x in accounts) {
      if (norm(x) == norm(s)) return x;
    }
    accounts.add(s);
    return s;
  }

  Map<String, dynamic>? txById(String id) {
    for (final t in tx) {
      if (t['id'] == id || (t['doc'] ?? '') == id) return t;
    }
    return null;
  }

  // ------------------------------------------------------------------ lines

  /// Turns tool lines ([{item, qty, price, cost}]) into stored lines, looking items up. Unknown items stay as free text.
  List<Map<String, dynamic>> lines(dynamic raw, {required bool selling}) {
    final out = <Map<String, dynamic>>[];
    for (final l in (raw as List? ?? const [])) {
      if (l is! Map) continue;
      final ref = l['item'] ?? l['item_id'] ?? l['name'] ?? l['description'];
      final it = item(ref);
      final qty = l['qty'] == null && l['quantity'] == null ? 1.0 : d(l['qty'] ?? l['quantity']);
      final price = l['price'] != null || l['unit_price'] != null
          ? d(l['price'] ?? l['unit_price'])
          : (it == null ? 0.0 : d(selling ? it['price'] : it['cost']));
      final cost = l['cost'] != null ? d(l['cost']) : (it == null ? 0.0 : d(it['cost']));
      out.add({
        if (it != null) 'item_id': it['id'],
        'name': it == null ? '${ref ?? 'Item'}' : '${it['name']}',
        'qty': qty,
        'price': price,
        'cost': selling ? cost : price,
        if ((l['note'] ?? '').toString().isNotEmpty) 'note': '${l['note']}',
      });
    }
    return out;
  }

  static double linesTotal(List<Map<String, dynamic>> ls) => ls.fold(0.0, (a, l) => a + d(l['qty']) * d(l['price']));
  static double linesCost(List<Map<String, dynamic>> ls) => ls.fold(0.0, (a, l) => a + d(l['qty']) * d(l['cost']));

  /// Applies a transaction's stock effect (+1 apply, -1 undo).
  void stockEffect(Map<String, dynamic> t, int sign) {
    final k = t['kind'];
    if (k != 'sale' && k != 'purchase' && k != 'adjust') return;
    for (final l in _maps(t['lines'])) {
      final it = item(l['item_id']);
      if (it == null) continue;
      final q = d(l['qty']);
      if (k == 'sale') it['qty'] = d(it['qty']) - sign * q;
      if (k == 'adjust') it['qty'] = d(it['qty']) + sign * q;
      if (k == 'purchase') {
        final before = d(it['qty']);
        it['qty'] = before + sign * q;
        // Weighted average cost on a new purchase.
        if (sign > 0 && q > 0) {
          final total = math.max(0.0, before) * d(it['cost']) + q * d(l['price']);
          final nq = math.max(0.0, before) + q;
          if (nq > 0) it['cost'] = double.parse((total / nq).toStringAsFixed(4));
        }
      }
    }
  }

  // ------------------------------------------------------------------ balances

  /// Cash effect of a transaction per account.
  Map<String, double> cashEffect(Map<String, dynamic> t) {
    final a = '${t['account'] ?? accounts.first}';
    final amt = d(t['amount']), paid = d(t['paid']);
    switch (t['kind']) {
      case 'sale':
        return {a: paid};
      case 'purchase':
      case 'expense':
        return {a: -paid};
      case 'payment_in':
      case 'owner_in':
        return {a: amt};
      case 'payment_out':
      case 'owner_out':
        return {a: -amt};
      case 'transfer':
        return {a: -amt, '${t['to_account'] ?? ''}': amt};
    }
    return const {};
  }

  Map<String, double> balances({String? upTo}) {
    final out = {for (final a in accounts) a: 0.0};
    for (final a in accounts) {
      out[a] = d((profile['opening'] as Map?)?[a]);
    }
    for (final t in tx) {
      if (upTo != null && '${t['date']}'.compareTo(upTo) > 0) continue;
      cashEffect(t).forEach((k, v) {
        if (k.isEmpty) return;
        out[k] = (out[k] ?? 0) + v;
      });
    }
    return out;
  }

  /// What a contact owes the business (positive) or the business owes them (negative).
  double contactBalance(String id) {
    var b = 0.0;
    for (final t in tx) {
      if (t['contact_id'] != id) continue;
      final amt = d(t['amount']), paid = d(t['paid']);
      switch (t['kind']) {
        case 'sale':
          b += amt - paid;
          break;
        case 'purchase':
        case 'expense':
          b -= amt - paid;
          break;
        case 'payment_in':
          b -= amt;
          break;
        case 'payment_out':
          b += amt;
          break;
        case 'owed_to_me':
          b += amt;
          break;
        case 'i_owe':
          b -= amt;
          break;
      }
    }
    return double.parse(b.toStringAsFixed(2));
  }

  /// Days since the oldest still-unpaid sale or bill of a contact (rough ageing, first in first out).
  int oldestUnpaidDays(String id) {
    final bal = contactBalance(id);
    if (bal == 0) return 0;
    final owesUs = bal > 0;
    var left = bal.abs();
    final rel = tx.where((t) => t['contact_id'] == id).toList()..sort((a, b) => '${b['date']}'.compareTo('${a['date']}'));
    String? oldest;
    for (final t in rel) {
      final k = t['kind'];
      final debit = owesUs ? (k == 'sale' ? d(t['amount']) - d(t['paid']) : (k == 'owed_to_me' ? d(t['amount']) : 0.0))
          : (k == 'purchase' || k == 'expense' ? d(t['amount']) - d(t['paid']) : (k == 'i_owe' ? d(t['amount']) : 0.0));
      if (debit <= 0) continue;
      oldest = '${t['date']}';
      left -= debit;
      if (left <= 0.005) break;
    }
    final dt = DateTime.tryParse(oldest ?? '');
    return dt == null ? 0 : DateTime.now().difference(dt).inDays;
  }

  // ------------------------------------------------------------------ periods

  /// [period]: today, yesterday, week (last 7 days), month, last_month, quarter, year, last_year, all. Or from/to.
  static (String, String, String) range(String? period, {String? from, String? to}) {
    final now = DateTime.now();
    String f(DateTime x) => x.toIso8601String().substring(0, 10);
    if ((from ?? '').isNotEmpty || (to ?? '').isNotEmpty) {
      final a = day(from?.isEmpty ?? true ? '2000-01-01' : from), b = day(to?.isEmpty ?? true ? null : to);
      return (a, b, '$a to $b');
    }
    switch (period ?? 'month') {
      case 'today':
        return (f(now), f(now), 'today ${f(now)}');
      case 'yesterday':
        final y = now.subtract(const Duration(days: 1));
        return (f(y), f(y), 'yesterday ${f(y)}');
      case 'week':
        return (f(now.subtract(const Duration(days: 6))), f(now), 'last 7 days');
      case 'last_month':
        final s = DateTime(now.year, now.month - 1, 1), e = DateTime(now.year, now.month, 0);
        return (f(s), f(e), _monthName(s));
      case 'quarter':
        final q = (now.month - 1) ~/ 3;
        final s = DateTime(now.year, q * 3 + 1, 1), e = DateTime(now.year, q * 3 + 4, 0);
        return (f(s), f(e), 'Q${q + 1} ${now.year}');
      case 'year':
        return ('${now.year}-01-01', '${now.year}-12-31', '${now.year}');
      case 'last_year':
        return ('${now.year - 1}-01-01', '${now.year - 1}-12-31', '${now.year - 1}');
      case 'all':
        return ('0000-01-01', '9999-12-31', 'all time');
      default:
        final s = DateTime(now.year, now.month, 1), e = DateTime(now.year, now.month + 1, 0);
        return (f(s), f(e), _monthName(s));
    }
  }

  static String _monthName(DateTime d) {
    const n = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
    return '${n[d.month - 1]} ${d.year}';
  }

  List<Map<String, dynamic>> txIn(String a, String b) =>
      tx.where((t) => '${t['date']}'.compareTo(a) >= 0 && '${t['date']}'.compareTo(b) <= 0).toList();

  // ------------------------------------------------------------------ numbers for reports

  /// Profit and loss for a date range.
  Map<String, dynamic> profitLoss(String a, String b) {
    var revenue = 0.0, cogs = 0.0, purchasesNoItems = 0.0, otherIncome = 0.0, taxCollected = 0.0;
    final expenses = <String, double>{};
    for (final t in txIn(a, b)) {
      switch (t['kind']) {
        case 'sale':
          revenue += d(t['amount']) - d(t['tax']);
          taxCollected += d(t['tax']);
          final ls = _maps(t['lines']);
          cogs += ls.isEmpty ? d(t['cost']) : linesCost(ls);
          break;
        case 'purchase':
          if (_maps(t['lines']).where((l) => l['item_id'] != null).isEmpty) purchasesNoItems += d(t['amount']);
          break;
        case 'expense':
          final c = '${t['category'] ?? ''}'.trim();
          expenses[c.isEmpty ? 'Other' : c] = (expenses[c.isEmpty ? 'Other' : c] ?? 0) + d(t['amount']);
          break;
        case 'payment_in':
          if ((t['contact_id'] ?? '').toString().isEmpty) otherIncome += d(t['amount']);
          break;
      }
    }
    final costOfGoods = cogs + purchasesNoItems;
    final gross = revenue - costOfGoods;
    final totalExp = expenses.values.fold(0.0, (x, y) => x + y);
    return {
      'revenue': revenue,
      'cost_of_goods': costOfGoods,
      'gross_profit': gross,
      'gross_margin': revenue == 0 ? 0.0 : gross / revenue * 100,
      'expenses': expenses,
      'total_expenses': totalExp,
      'other_income': otherIncome,
      'net_profit': gross - totalExp + otherIncome,
      'tax_collected': taxCollected,
    };
  }

  Map<String, double> salesByItem(String a, String b, {bool byQty = false}) {
    final out = <String, double>{};
    for (final t in txIn(a, b).where((t) => t['kind'] == 'sale')) {
      final ls = _maps(t['lines']);
      if (ls.isEmpty) {
        final k = '${t['note'] ?? ''}'.trim().isEmpty ? 'Other sales' : '${t['note']}';
        out[k] = (out[k] ?? 0) + (byQty ? 1 : d(t['amount']));
      }
      for (final l in ls) {
        out['${l['name']}'] = (out['${l['name']}'] ?? 0) + (byQty ? d(l['qty']) : d(l['qty']) * d(l['price']));
      }
    }
    return out;
  }

  Map<String, double> salesByDay(String a, String b) {
    final out = <String, double>{};
    for (final t in txIn(a, b).where((t) => t['kind'] == 'sale')) {
      out['${t['date']}'] = (out['${t['date']}'] ?? 0) + d(t['amount']);
    }
    return Map.fromEntries(out.entries.toList()..sort((x, y) => x.key.compareTo(y.key)));
  }

  Map<String, double> salesByMonth(String a, String b) {
    final out = <String, double>{};
    for (final t in txIn(a, b).where((t) => t['kind'] == 'sale')) {
      final k = '${t['date']}'.substring(0, 7);
      out[k] = (out[k] ?? 0) + d(t['amount']);
    }
    return Map.fromEntries(out.entries.toList()..sort((x, y) => x.key.compareTo(y.key)));
  }

  Map<String, double> salesByCustomer(String a, String b) {
    final out = <String, double>{};
    for (final t in txIn(a, b).where((t) => t['kind'] == 'sale')) {
      final c = contact(t['contact_id']);
      final k = c == null ? 'Walk-in' : '${c['name']}';
      out[k] = (out[k] ?? 0) + d(t['amount']);
    }
    return out;
  }

  double stockValue({bool atPrice = false}) =>
      items.fold(0.0, (a, i) => a + math.max(0.0, d(i['qty'])) * d(atPrice ? i['price'] : i['cost']));

  List<Map<String, dynamic>> lowStock() =>
      items.where((i) => i['reorder'] != null && d(i['qty']) <= d(i['reorder'])).toList();

  static List<MapEntry<String, double>> top(Map<String, double> m, [int n = 8]) =>
      (m.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).take(n).toList();

  /// A chart card the chat can show: ```diagram {"type":"bars"...}```.
  static String chart(String type, String title, List<MapEntry<String, double>> data, {String unit = ''}) {
    if (data.isEmpty) return '';
    final j = {
      'type': type,
      'title': title,
      if (unit.isNotEmpty) 'unit': unit,
      'items': [for (final e in data) {'label': e.key, 'value': double.parse(e.value.toStringAsFixed(2))}],
    };
    return '```diagram\n${jsonEncode(j)}\n```';
  }
}

/// Business maths with the working shown, so the bot never does arithmetic in its head.
class BizCalc {
  static double _d(dynamic v) => BizBooks.d(v);
  static String _f(double v) => BizBooks.money(v);
  static String _p(double v) => '${v.toStringAsFixed(v.abs() >= 10 ? 1 : 2)}%';

  static String run(Map<String, dynamic> a) {
    final mode = '${a['mode'] ?? 'profit'}';
    final cur = '${a['currency'] ?? ''}'.trim();
    String c(double v) => cur.isEmpty ? _f(v) : '${_f(v)} $cur';
    switch (mode) {
      case 'profit':
        final cost = _d(a['cost']), price = _d(a['price']), qty = a['qty'] == null ? 1.0 : _d(a['qty']);
        final unit = price - cost;
        return 'Profit per unit: ${c(price)} - ${c(cost)} = ${c(unit)}\n'
            'Margin: ${_p(price == 0 ? 0 : unit / price * 100)} of the price. Markup: ${_p(cost == 0 ? 0 : unit / cost * 100)} on cost.\n'
            '${qty != 1 ? 'For ${_f(qty)} units: sales ${c(price * qty)}, cost ${c(cost * qty)}, profit ${c(unit * qty)}.' : ''}'.trim();
      case 'cost_per_unit':
        final total = _d(a['buy_total']) + _d(a['shipping']) + _d(a['customs']) + _d(a['other_costs']);
        final qty = _d(a['qty']);
        if (qty <= 0) return 'Error: give qty (how many units the costs cover).';
        return 'Total landed cost ${c(total)} / ${_f(qty)} units = ${c(total / qty)} per unit.';
      case 'price_for_margin':
        final cost = _d(a['cost']), mg = _d(a['margin_pct']);
        if (mg >= 100) return 'Error: a margin must be below 100%.';
        final price = cost / (1 - mg / 100);
        return 'To keep a ${_p(mg)} margin on a cost of ${c(cost)}: price = cost / (1 - ${mg / 100}) = ${c(price)} '
            '(profit ${c(price - cost)} per unit, markup ${_p(cost == 0 ? 0 : (price - cost) / cost * 100)}).';
      case 'price_for_markup':
        final cost = _d(a['cost']), mk = _d(a['markup_pct']);
        final price = cost * (1 + mk / 100);
        return 'Cost ${c(cost)} + ${_p(mk)} markup = ${c(price)} (margin ${_p(price == 0 ? 0 : (price - cost) / price * 100)}).';
      case 'break_even':
        final fixed = _d(a['fixed_costs']), price = _d(a['price']), cost = _d(a['cost']);
        final unit = price - cost;
        if (unit <= 0) return 'There is no break-even: each unit loses ${c(-unit)}. Raise the price or cut the cost.';
        final n = (fixed / unit).ceil();
        return 'Profit per unit ${c(unit)}. Break-even = fixed costs ${c(fixed)} / ${c(unit)} = $n units '
            '(sales of ${c(n * price)}) per period. About ${(n / 30).ceil()} units a day over 30 days.';
      case 'discount':
        final price = _d(a['price']), cost = _d(a['cost']), disc = _d(a['discount_pct']);
        final unit = price - cost, np = price * (1 - disc / 100), nu = np - cost;
        if (nu <= 0) return 'At ${_p(disc)} off the price is ${c(np)}, below the cost: every sale loses ${c(-nu)}.';
        final need = unit / nu;
        return 'Price after ${_p(disc)} off: ${c(np)}. Profit per unit falls from ${c(unit)} to ${c(nu)}. '
            'You must sell ${need.toStringAsFixed(2)}x as many (${_p((need - 1) * 100)} more units) to earn the same profit.';
      case 'growth':
        final from = _d(a['from']), to = _d(a['to']);
        if (from == 0) return 'Error: the starting value is 0.';
        return 'Change: ${c(to - from)} (${_p((to - from) / from * 100)}).';
      case 'tax':
        final amount = _d(a['amount']), rate = _d(a['rate_pct']);
        final inclusive = a['inclusive'] == true;
        if (inclusive) {
          final net = amount / (1 + rate / 100);
          return 'Price ${c(amount)} includes ${_p(rate)} tax: net ${c(net)} + tax ${c(amount - net)}.';
        }
        return 'Tax at ${_p(rate)} on ${c(amount)} = ${c(amount * rate / 100)}; total ${c(amount * (1 + rate / 100))}.';
      case 'zakat':
        final assets = _d(a['cash']) + _d(a['stock_value']) + _d(a['receivables']);
        final net = assets - _d(a['debts_due']);
        final nisab = _d(a['nisab']);
        if (nisab <= 0) {
          return 'Zakatable business assets: ${c(net)} (cash + stock at market value + collectable debts - debts due now). '
              'Give the nisab (the current value of 85 g of gold or 595 g of silver, ask a local source) to check the threshold. '
              '2.5% of ${c(net)} = ${c(net * 0.025)}.';
        }
        if (net < nisab) return 'Net zakatable assets ${c(net)} are below the nisab ${c(nisab)}: no zakat due on them.';
        return 'Net zakatable assets ${c(net)} are above the nisab ${c(nisab)}. Zakat at 2.5% = ${c(net * 0.025)} '
            '(once a lunar year has passed). For a ruling on your case, ask a trusted scholar.';
      case 'loan':
        // Fixed instalments on a sale price (murabaha style): total / months.
        final total = _d(a['total']), months = _d(a['months']);
        if (months <= 0) return 'Error: give months.';
        return 'Instalment: ${c(total)} / ${_f(months)} months = ${c(total / months)} a month.';
    }
    return 'Error: unknown mode $mode. Use profit, cost_per_unit, price_for_margin, price_for_markup, break_even, discount, growth, tax, zakat or loan.';
  }
}
