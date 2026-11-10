import 'dart:convert';
import 'dart:io';

import 'biz_books.dart';
import 'biz_pdf.dart';
import 'data_sheet.dart';
import 'doc_maker.dart';
import 'tools.dart';

/// Telesia's business toolkit: real books kept on the phone (Business/books.json in the workspace) and the tools that
/// work on them: sales, expenses and purchases, payments and the cashbook, stock, customers and suppliers, debts,
/// tasks, invoices, quotes, receipts and other documents as PDFs, reports with charts (chat, PDF, Excel), business maths,
/// and a data analyst for any CSV or Excel file. The Business adviser bot always has them; the main agent gets them
/// when a message is about a business.
class BizTools {
  static const names = {
    'biz_setup', 'biz_sale', 'biz_expense', 'biz_payment', 'biz_stock', 'biz_contacts', 'biz_debts', 'biz_tasks',
    'biz_document', 'biz_report', 'biz_records', 'biz_calc', 'data_sheet',
  };

  /// Tests point this at a temp folder.
  static String? dirOverride;

  static Map<String, dynamic> _fn(String name, String desc, Map<String, dynamic> props, [List<String> req = const []]) => {
        'type': 'function',
        'function': {
          'name': name,
          'description': desc,
          'parameters': {'type': 'object', 'properties': props, 'required': req},
        },
      };

  static const _period = {
    'type': 'string',
    'enum': ['today', 'yesterday', 'week', 'month', 'last_month', 'quarter', 'year', 'last_year', 'all'],
  };
  static const _lines = {
    'type': 'array',
    'description': 'Items: [{item (stock name, code or id; or free text), qty, price (unit price; default the stock price), note}]',
    'items': {'type': 'object'},
  };

  static final List<Map<String, dynamic>> definitions = [
    _fn('biz_setup', 'The business profile used on invoices and reports, and the money accounts (Cash, EVC Plus, ZAAD, bank...). '
        'show it, or set fields. One currency per business.', {
      'action': {'type': 'string', 'enum': ['show', 'set']},
      'name': {'type': 'string'}, 'phone': {'type': 'string'}, 'email': {'type': 'string'}, 'address': {'type': 'string'},
      'tax_id': {'type': 'string', 'description': 'TIN'},
      'currency': {'type': 'string', 'description': 'USD, SOS, SLSH, KES, ETB...'},
      'tax_label': {'type': 'string', 'description': 'e.g. Sales tax, GST'},
      'tax_rate': {'type': 'number', 'description': 'Default % added to invoices; 0 = none. Only a rate the user confirmed.'},
      'payment_info': {'type': 'string', 'description': 'How customers pay, printed on invoices (e.g. "EVC Plus 61..., Sifalo Pay link")'},
      'invoice_note': {'type': 'string'},
      'logo_path': {'type': 'string', 'description': 'Image file in the workspace for the document header'},
      'accounts': {'type': 'array', 'items': {'type': 'string'}, 'description': 'Money accounts, first is the default'},
      'opening': {'type': 'object', 'description': 'Opening balance per account, e.g. {"Cash": 120, "EVC Plus": 300}'},
    }),
    _fn('biz_sale', 'Record a sale (sales recorder). Takes stock out, adds to the cashbook, and puts any unpaid part on the customer\'s debt. '
        'Give lines, or just amount (+ cost if known). Paid defaults to the full total; on credit = paid 0. '
        'Set document to make a receipt or invoice PDF at once.', {
      'lines': _lines,
      'amount': {'type': 'number', 'description': 'Total when there are no lines'},
      'cost': {'type': 'number', 'description': 'Cost of what was sold, when there are no lines'},
      'customer': {'type': 'string', 'description': 'Name or id; new names are added as customers'},
      'paid': {'type': 'number'},
      'on_credit': {'type': 'boolean'},
      'account': {'type': 'string', 'description': 'Where the money went: Cash, EVC Plus, ZAAD, Sifalo Pay, bank...'},
      'discount': {'type': 'number', 'description': 'Amount off the total'},
      'tax_rate': {'type': 'number', 'description': '% tax added; default the profile rate (0 if none)'},
      'date': {'type': 'string', 'description': 'YYYY-MM-DD, default today'},
      'note': {'type': 'string'},
      'document': {'type': 'string', 'enum': ['none', 'receipt', 'invoice']},
    }),
    _fn('biz_expense', 'Record an expense (rent, salary, transport, electricity, ads...) or a stock purchase (lines raise stock and update cost). '
        'Unpaid part goes on the supplier\'s balance.', {
      'kind': {'type': 'string', 'enum': ['expense', 'purchase']},
      'amount': {'type': 'number'},
      'lines': _lines,
      'category': {'type': 'string', 'description': 'Rent, Salaries, Transport, Utilities, Marketing, Stock, Fees...'},
      'supplier': {'type': 'string'},
      'paid': {'type': 'number', 'description': 'Default: the full amount'},
      'on_credit': {'type': 'boolean'},
      'account': {'type': 'string'},
      'date': {'type': 'string'},
      'note': {'type': 'string'},
    }, ['kind']),
    _fn('biz_payment', 'Money moving that is not a sale or expense: a customer paying their debt (payment_in), paying a supplier (payment_out), '
        'the owner putting money in or taking it out, a transfer between accounts, other income (payment_in with no contact), '
        'or writing down a debt with no money moving (owed_to_me, i_owe). receipt=true makes a receipt PDF.', {
      'kind': {'type': 'string', 'enum': ['payment_in', 'payment_out', 'owner_in', 'owner_out', 'transfer', 'owed_to_me', 'i_owe']},
      'amount': {'type': 'number'},
      'contact': {'type': 'string', 'description': 'Customer or supplier name or id'},
      'account': {'type': 'string', 'description': 'From/into which account'},
      'to_account': {'type': 'string', 'description': 'For transfer'},
      'against': {'type': 'string', 'description': 'Invoice number it pays, e.g. INV-0003'},
      'date': {'type': 'string'},
      'note': {'type': 'string'},
      'receipt': {'type': 'boolean'},
    }, ['kind', 'amount']),
    _fn('biz_stock', 'Inventory manager: add or update items (cost, price, qty, reorder level), adjust counts (damaged, stock take), list stock '
        'with value, show low stock, an item\'s history, or delete an item.', {
      'action': {'type': 'string', 'enum': ['add', 'update', 'adjust', 'list', 'low', 'history', 'delete']},
      'item': {'type': 'string', 'description': 'Name, code or id of an existing item'},
      'name': {'type': 'string'}, 'sku': {'type': 'string', 'description': 'Code/barcode'}, 'unit': {'type': 'string'},
      'category': {'type': 'string'},
      'cost': {'type': 'number'}, 'price': {'type': 'number'},
      'qty': {'type': 'number', 'description': 'add: opening quantity; adjust: + or - change; update: the counted quantity'},
      'reorder': {'type': 'number', 'description': 'Warn when quantity falls to this'},
      'reason': {'type': 'string'},
      'query': {'type': 'string', 'description': 'list: filter by name or category'},
    }, ['action']),
    _fn('biz_contacts', 'Customers and suppliers: add, update, list (with balances), statement (every sale, bill and payment with a running balance), delete.', {
      'action': {'type': 'string', 'enum': ['add', 'update', 'list', 'statement', 'delete']},
      'type': {'type': 'string', 'enum': ['customer', 'supplier', 'both']},
      'contact': {'type': 'string', 'description': 'Name or id of an existing contact'},
      'name': {'type': 'string'}, 'phone': {'type': 'string'}, 'address': {'type': 'string'}, 'note': {'type': 'string'},
      'format': {'type': 'string', 'enum': ['chat', 'pdf', 'xlsx']},
    }, ['action']),
    _fn('biz_debts', 'Debt tracker: who owes the business and whom it owes, with how old the debt is; or a polite reminder message for one '
        'customer (the user sends it themselves).', {
      'action': {'type': 'string', 'enum': ['list', 'reminder']},
      'direction': {'type': 'string', 'enum': ['owed_to_me', 'i_owe', 'both']},
      'contact': {'type': 'string'},
      'language': {'type': 'string', 'enum': ['so', 'en']},
    }),
    _fn('biz_tasks', 'Business task manager: add, list, update, mark done or delete tasks (who, due date, priority).', {
      'action': {'type': 'string', 'enum': ['add', 'list', 'update', 'done', 'delete']},
      'id': {'type': 'string'},
      'text': {'type': 'string'},
      'due': {'type': 'string', 'description': 'YYYY-MM-DD'},
      'who': {'type': 'string'},
      'priority': {'type': 'string', 'enum': ['low', 'normal', 'high']},
      'show': {'type': 'string', 'enum': ['open', 'done', 'all', 'overdue']},
    }, ['action']),
    _fn('biz_document', 'Make a business PDF: invoice, quote, receipt, delivery note or purchase order, numbered (INV-0001...). '
        'From a recorded sale (sale_id) or from lines. A new invoice not from a sale is also recorded as a sale on credit unless record=false. '
        'Also list documents, show one, mark an invoice paid (records the payment) or void it.', {
      'action': {'type': 'string', 'enum': ['create', 'list', 'show', 'mark_paid', 'void']},
      'kind': {'type': 'string', 'enum': ['invoice', 'quote', 'receipt', 'delivery_note', 'purchase_order']},
      'sale_id': {'type': 'string', 'description': 'Sale id (T12) to base it on'},
      'no': {'type': 'string', 'description': 'Document number for show, mark_paid, void'},
      'lines': _lines,
      'customer': {'type': 'string', 'description': 'Customer (or supplier for a purchase order)'},
      'date': {'type': 'string'}, 'due': {'type': 'string'}, 'valid_until': {'type': 'string'},
      'discount': {'type': 'number'}, 'tax_rate': {'type': 'number'},
      'paid': {'type': 'number'}, 'account': {'type': 'string'},
      'note': {'type': 'string'},
      'record': {'type': 'boolean'},
    }, ['action']),
    _fn('biz_report', 'Business reports from the books, with charts: summary (dashboard), profit_loss, cashbook, sales (by item, day, customer), '
        'expenses (by category), stock (value, low), debts, tasks. format chat returns text plus ```diagram chart cards to paste in your reply; '
        'pdf makes a report with charts; xlsx or csv a spreadsheet.', {
      'type': {'type': 'string', 'enum': ['summary', 'profit_loss', 'cashbook', 'sales', 'expenses', 'stock', 'debts', 'tasks']},
      'period': _period,
      'from': {'type': 'string'}, 'to': {'type': 'string'},
      'account': {'type': 'string', 'description': 'cashbook: one account only'},
      'format': {'type': 'string', 'enum': ['chat', 'pdf', 'xlsx', 'csv']},
    }, ['type']),
    _fn('biz_records', 'Find or fix entries in the books: list or search transactions, delete a wrong one (undoes its stock and cash effect; '
        'record it again to correct it), or export everything to Excel as a backup.', {
      'action': {'type': 'string', 'enum': ['list', 'search', 'delete', 'export']},
      'kind': {'type': 'string', 'description': 'sale, purchase, expense, payment_in, payment_out, owner_in, owner_out, transfer, owed_to_me, i_owe, adjust'},
      'period': _period,
      'query': {'type': 'string'},
      'id': {'type': 'string'},
      'limit': {'type': 'integer'},
    }, ['action']),
    _fn('biz_calc', 'Business calculator with the working shown. Never do business maths in your head. Modes: profit {cost, price, qty}, '
        'cost_per_unit {buy_total, shipping, customs, other_costs, qty}, price_for_margin {cost, margin_pct}, price_for_markup {cost, markup_pct}, '
        'break_even {fixed_costs, price, cost}, discount {price, cost, discount_pct}, growth {from, to}, tax {amount, rate_pct, inclusive}, '
        'zakat {cash, stock_value, receivables, debts_due, nisab}, loan {total, months}.', {
      'mode': {'type': 'string'},
      'currency': {'type': 'string'},
      'cost': {'type': 'number'}, 'price': {'type': 'number'}, 'qty': {'type': 'number'},
      'buy_total': {'type': 'number'}, 'shipping': {'type': 'number'}, 'customs': {'type': 'number'}, 'other_costs': {'type': 'number'},
      'margin_pct': {'type': 'number'}, 'markup_pct': {'type': 'number'}, 'fixed_costs': {'type': 'number'}, 'discount_pct': {'type': 'number'},
      'from': {'type': 'number'}, 'to': {'type': 'number'}, 'amount': {'type': 'number'}, 'rate_pct': {'type': 'number'}, 'inclusive': {'type': 'boolean'},
      'cash': {'type': 'number'}, 'stock_value': {'type': 'number'}, 'receivables': {'type': 'number'}, 'debts_due': {'type': 'number'},
      'nisab': {'type': 'number'}, 'total': {'type': 'number'}, 'months': {'type': 'number'},
    }, ['mode']),
    _fn('data_sheet', 'Data analyst for spreadsheets: open a CSV, Excel (.xlsx) or JSON file (attachments are in uploads/) and describe it, '
        'or run a query: filters, computed columns, group by with sum/avg/count/min/max/median/distinct, sort, limit, pivot. '
        'Add chart to get a ```diagram card (bars, line, donut) to paste in your reply, and save_as to write the result as xlsx or csv. '
        'To create a new spreadsheet from scratch use make_document (xlsx supports formulas like "=SUM(B2:B9)").', {
      'action': {'type': 'string', 'enum': ['describe', 'query', 'sheets']},
      'path': {'type': 'string'},
      'sheet': {'type': 'string', 'description': 'Sheet name in an xlsx (default the first)'},
      'filters': {'type': 'array', 'items': {'type': 'object'}, 'description': '[{column, op (= != > >= < <= contains starts_with in between empty not_empty), value}]'},
      'compute': {'type': 'array', 'items': {'type': 'object'}, 'description': '[{name, formula}] e.g. {"name":"Total","formula":"[Unit price] * Qty"}'},
      'group_by': {'type': 'array', 'items': {'type': 'string'}},
      'aggregate': {'type': 'array', 'items': {'type': 'object'}, 'description': '[{column, fn, as}]'},
      'pivot': {'type': 'object', 'description': '{rows, cols, value, fn}'},
      'columns': {'type': 'array', 'items': {'type': 'string'}, 'description': 'Keep only these columns'},
      'sort': {'type': 'string'}, 'desc': {'type': 'boolean'}, 'limit': {'type': 'integer'},
      'chart': {'type': 'object', 'description': '{type: bars|line|donut, label: column, value: column, title}'},
      'save_as': {'type': 'string', 'enum': ['xlsx', 'csv']},
      'title': {'type': 'string', 'description': 'Name for a saved file'},
    }, ['action', 'path']),
  ];

  // ------------------------------------------------------------------ storage

  static Future<Directory> _dir() async {
    final ws = dirOverride ?? await AgentTools.workspaceDir();
    final d = Directory('$ws/Business');
    await d.create(recursive: true);
    return d;
  }

  static Future<BizBooks> load() async {
    final f = File('${(await _dir()).path}/books.json');
    if (!await f.exists()) return BizBooks();
    return BizBooks.decode(await f.readAsString());
  }

  static Future<void> _save(BizBooks b) async {
    final d = await _dir();
    final f = File('${d.path}/books.json');
    if (await f.exists()) await f.copy('${d.path}/books.prev.json');
    final tmp = File('${d.path}/books.tmp');
    await tmp.writeAsString(b.encode(), flush: true);
    await tmp.rename(f.path);
  }

  static Future<void> _lock = Future.value();
  static Future<T> _serial<T>(Future<T> Function() f) {
    final run = _lock.then((_) => f());
    _lock = run.then((_) {}, onError: (_) {});
    return run;
  }

  static Future<String> _out(String base, String ext, List<int> bytes) async {
    final ws = dirOverride ?? await AgentTools.workspaceDir();
    final dir = Directory('$ws/Documents');
    await dir.create(recursive: true);
    final path = await DocMaker.uniquePath(dir.path, DocMaker.fileName(base), ext);
    await File(path).writeAsBytes(bytes);
    return path;
  }

  static String _saved(String path) => 'FILE_SAVED $path\nShow it with a ```file card. Do not print the path in text.';

  // ------------------------------------------------------------------ dispatch

  static Future<String> execute(String name, Map<String, dynamic> a) async {
    try {
      if (name == 'biz_calc') return BizCalc.run(a);
      if (name == 'data_sheet') return await _data(a);
      return await _serial(() async {
        final b = await load();
        final before = b.encode();
        final r = await _run(name, a, b);
        if (b.encode() != before) await _save(b);
        return r;
      });
    } catch (e) {
      return 'Error: $e';
    }
  }

  static Future<String> _run(String name, Map<String, dynamic> a, BizBooks b) async {
    switch (name) {
      case 'biz_setup':
        return _setup(a, b);
      case 'biz_sale':
        return _sale(a, b);
      case 'biz_expense':
        return _expense(a, b);
      case 'biz_payment':
        return _payment(a, b);
      case 'biz_stock':
        return _stock(a, b);
      case 'biz_contacts':
        return _contacts(a, b);
      case 'biz_debts':
        return _debts(a, b);
      case 'biz_tasks':
        return _tasks(a, b);
      case 'biz_document':
        return _document(a, b);
      case 'biz_report':
        return _report(a, b);
      case 'biz_records':
        return _records(a, b);
    }
    return 'Error: unknown tool $name';
  }

  static double _d(dynamic v) => BizBooks.d(v);
  static String _s(dynamic v) => '${v ?? ''}'.trim();
  static bool _has(Map a, String k) => a[k] != null && _s(a[k]).isNotEmpty;

  // ------------------------------------------------------------------ setup

  static String _setup(Map<String, dynamic> a, BizBooks b) {
    if (_s(a['action']) == 'set' || a.keys.any((k) => k != 'action')) {
      for (final k in ['name', 'phone', 'email', 'address', 'tax_id', 'currency', 'tax_label', 'payment_info', 'invoice_note', 'logo_path']) {
        if (a[k] != null) b.profile[k] = k == 'currency' ? _s(a[k]).toUpperCase() : _s(a[k]);
      }
      if (a['tax_rate'] != null) b.profile['tax_rate'] = _d(a['tax_rate']);
      if (a['accounts'] is List) {
        final acc = [for (final x in a['accounts'] as List) if (_s(x).isNotEmpty) _s(x)];
        if (acc.isNotEmpty) {
          for (final x in b.accounts) {
            if (!acc.contains(x) && b.tx.any((t) => t['account'] == x || t['to_account'] == x)) acc.add(x);
          }
          b.accounts = acc;
        }
      }
      if (a['opening'] is Map) {
        final o = Map<String, dynamic>.from((b.profile['opening'] as Map?) ?? const {});
        (a['opening'] as Map).forEach((k, v) => o[b.account(k)] = _d(v));
        b.profile['opening'] = o;
      }
    }
    final p = b.profile;
    return 'Business profile:\n'
        'Name: ${b.name.isEmpty ? '(not set)' : b.name}\nPhone: ${p['phone'] ?? ''}\nEmail: ${p['email'] ?? ''}\nAddress: ${p['address'] ?? ''}\n'
        'TIN: ${p['tax_id'] ?? ''}\nCurrency: ${b.currency}\nTax on invoices: ${_d(p['tax_rate']) == 0 ? 'none' : '${p['tax_label'] ?? 'Tax'} ${_d(p['tax_rate'])}%'}\n'
        'Payment info on invoices: ${p['payment_info'] ?? ''}\nAccounts: ${b.accounts.join(', ')}\n'
        'Balances now: ${b.balances().entries.map((e) => '${e.key} ${b.m(e.value)}').join(', ')}';
  }

  // ------------------------------------------------------------------ sales, expenses, payments

  static (double, double, double) _totals(BizBooks b, double subtotal, Map<String, dynamic> a) {
    final disc = _d(a['discount']);
    final rate = a['tax_rate'] != null ? _d(a['tax_rate']) : _d(b.profile['tax_rate']);
    final tax = double.parse(((subtotal - disc) * rate / 100).toStringAsFixed(2));
    return (disc, tax, double.parse((subtotal - disc + tax).toStringAsFixed(2)));
  }

  static Future<String> _sale(Map<String, dynamic> a, BizBooks b) async {
    final ls = b.lines(a['lines'], selling: true);
    if (ls.isEmpty && _d(a['amount']) <= 0) return 'Error: give lines or an amount.';
    final subtotal = ls.isEmpty ? _d(a['amount']) : BizBooks.linesTotal(ls);
    final (disc, tax, total) = _totals(b, subtotal, a);
    final paid = a['on_credit'] == true ? 0.0 : (a['paid'] != null ? _d(a['paid']) : total);
    final c = _has(a, 'customer') ? b.contactOrNew(_s(a['customer']), 'customer') : null;
    if (c == null && paid < total - 0.005) return 'Error: a sale on credit needs the customer\'s name.';
    final t = <String, dynamic>{
      'id': b.nextId('T'),
      'date': BizBooks.day(a['date']),
      'kind': 'sale',
      'lines': ls,
      'amount': total,
      'subtotal': subtotal,
      'discount': disc,
      'tax': tax,
      if (ls.isEmpty && a['cost'] != null) 'cost': _d(a['cost']),
      'paid': paid,
      'account': b.account(a['account']),
      if (c != null) 'contact_id': c['id'],
      'note': _s(a['note']),
    };
    b.tx.add(t);
    b.stockEffect(t, 1);
    final cost = ls.isEmpty ? _d(a['cost']) : BizBooks.linesCost(ls);
    final sb = StringBuffer('Sale ${t['id']} recorded: ${b.m(total)}');
    if (ls.isNotEmpty) sb.write(' (${ls.map((l) => '${BizBooks.money(_d(l['qty']))} x ${l['name']}').join(', ')})');
    if (c != null) sb.write(' to ${c['name']}');
    sb.write('. Paid ${b.m(paid)} into ${t['account']}');
    if (paid < total - 0.005 && c != null) sb.write('; ${b.m(total - paid)} on credit (${c['name']} now owes ${b.m(b.contactBalance('${c['id']}'))})');
    sb.write('.');
    if (cost > 0) sb.write(' Profit on this sale about ${b.m(total - tax - cost)}.');
    final unknown = ls.where((l) => l['item_id'] == null).map((l) => l['name']).toList();
    if (unknown.isNotEmpty && b.items.isNotEmpty) sb.write(' Not in stock list (no stock change): ${unknown.join(', ')}.');
    for (final l in ls) {
      final it = b.item(l['item_id']);
      if (it == null) continue;
      if (_d(it['qty']) < 0) sb.write(' Warning: ${it['name']} stock is now ${BizBooks.money(_d(it['qty']))} (check the count).');
      if (it['reorder'] != null && _d(it['qty']) <= _d(it['reorder'])) sb.write(' ${it['name']} is low (${BizBooks.money(_d(it['qty']))} left).');
    }
    final doc = _s(a['document']);
    if (doc == 'receipt' || doc == 'invoice') {
      sb.write('\n${await _makeDoc(b, doc, t, a)}');
    }
    return sb.toString();
  }

  static String _expense(Map<String, dynamic> a, BizBooks b) {
    final kind = _s(a['kind']) == 'purchase' ? 'purchase' : 'expense';
    final ls = b.lines(a['lines'], selling: false);
    final total = ls.isEmpty ? _d(a['amount']) : BizBooks.linesTotal(ls);
    if (total <= 0) return 'Error: give an amount or lines.';
    final paid = a['on_credit'] == true ? 0.0 : (a['paid'] != null ? _d(a['paid']) : total);
    final s = _has(a, 'supplier') ? b.contactOrNew(_s(a['supplier']), 'supplier') : null;
    if (s == null && paid < total - 0.005) return 'Error: an unpaid bill needs the supplier\'s name.';
    // New stock names in a purchase become items.
    if (kind == 'purchase') {
      for (final l in ls) {
        if (l['item_id'] != null) continue;
        final it = <String, dynamic>{'id': b.nextId('I'), 'name': l['name'], 'sku': '', 'unit': '', 'category': '', 'cost': l['price'], 'price': 0.0, 'qty': 0.0};
        b.items.add(it);
        l['item_id'] = it['id'];
      }
    }
    final t = <String, dynamic>{
      'id': b.nextId('T'),
      'date': BizBooks.day(a['date']),
      'kind': kind,
      'lines': ls,
      'amount': total,
      'paid': paid,
      'account': b.account(a['account']),
      'category': _s(a['category']).isEmpty ? (kind == 'purchase' ? 'Stock' : 'Other') : _s(a['category']),
      if (s != null) 'contact_id': s['id'],
      'note': _s(a['note']),
    };
    b.tx.add(t);
    b.stockEffect(t, 1);
    final sb = StringBuffer('${kind == 'purchase' ? 'Purchase' : 'Expense'} ${t['id']} recorded: ${b.m(total)} · ${t['category']}');
    if (s != null) sb.write(' · ${s['name']}');
    sb.write('. Paid ${b.m(paid)} from ${t['account']}');
    if (paid < total - 0.005 && s != null) sb.write('; ${b.m(total - paid)} still owed to ${s['name']}');
    sb.write('.');
    if (kind == 'purchase' && ls.isNotEmpty) {
      sb.write(' Stock now: ${ls.map((l) => '${l['name']} ${BizBooks.money(_d(b.item(l['item_id'])?['qty']))}').join(', ')}.');
      final noPrice = ls.where((l) => _d(b.item(l['item_id'])?['price']) == 0).map((l) => l['name']).toList();
      if (noPrice.isNotEmpty) sb.write(' No selling price yet for: ${noPrice.join(', ')} (set it with biz_stock update).');
    }
    return sb.toString();
  }

  static Future<String> _payment(Map<String, dynamic> a, BizBooks b) async {
    final kind = _s(a['kind']);
    final amt = _d(a['amount']);
    if (amt <= 0) return 'Error: give a positive amount.';
    Map<String, dynamic>? c;
    if (_has(a, 'contact')) {
      final type = kind == 'payment_out' || kind == 'i_owe' ? 'supplier' : 'customer';
      c = b.contactOrNew(_s(a['contact']), type);
    }
    if ((kind == 'owed_to_me' || kind == 'i_owe' || kind == 'payment_out') && c == null) return 'Error: say who (contact).';
    if (kind == 'transfer' && !_has(a, 'to_account')) return 'Error: a transfer needs to_account.';
    final t = <String, dynamic>{
      'id': b.nextId('T'),
      'date': BizBooks.day(a['date']),
      'kind': kind,
      'amount': amt,
      'paid': 0.0,
      'account': b.account(a['account']),
      if (kind == 'transfer') 'to_account': b.account(a['to_account']),
      if (c != null) 'contact_id': c['id'],
      if (_has(a, 'against')) 'against': _s(a['against']).toUpperCase(),
      'note': _s(a['note']),
    };
    b.tx.add(t);
    if (_has(a, 'against')) {
      for (final d in b.docs) {
        if (d['no'] == t['against']) d['paid'] = _d(d['paid']) + amt;
      }
    }
    const words = {
      'payment_in': 'Money received',
      'payment_out': 'Payment made',
      'owner_in': 'Owner put in',
      'owner_out': 'Owner took out',
      'transfer': 'Transfer',
      'owed_to_me': 'Debt written down (they owe you)',
      'i_owe': 'Debt written down (you owe)',
    };
    final sb = StringBuffer('${words[kind] ?? kind} ${t['id']}: ${b.m(amt)}');
    if (c != null) sb.write(' · ${c['name']}');
    if (kind == 'transfer') sb.write(' from ${t['account']} to ${t['to_account']}');
    if (kind != 'transfer' && kind != 'owed_to_me' && kind != 'i_owe') sb.write(' · ${t['account']}');
    sb.write('.');
    if (c != null) {
      final bal = b.contactBalance('${c['id']}');
      sb.write(bal > 0 ? ' ${c['name']} now owes ${b.m(bal)}.' : (bal < 0 ? ' You now owe ${c['name']} ${b.m(-bal)}.' : ' ${c['name']} is settled (balance 0).'));
    }
    if (a['receipt'] == true && (kind == 'payment_in' || kind == 'owner_in')) sb.write('\n${await _makeDoc(b, 'receipt', t, a)}');
    return sb.toString();
  }

  // ------------------------------------------------------------------ stock

  static String _stock(Map<String, dynamic> a, BizBooks b) {
    final action = _s(a['action']);
    String line(Map<String, dynamic> i) => '${i['id']} · ${i['name']}${_s(i['sku']).isEmpty ? '' : ' [${i['sku']}]'} · qty ${BizBooks.money(_d(i['qty']))}'
        '${_s(i['unit']).isEmpty ? '' : ' ${i['unit']}'} · cost ${BizBooks.money(_d(i['cost']))} · price ${BizBooks.money(_d(i['price']))}'
        '${i['reorder'] == null ? '' : ' · reorder at ${BizBooks.money(_d(i['reorder']))}'}';
    switch (action) {
      case 'add':
        if (!_has(a, 'name')) return 'Error: give the item name.';
        if (b.item(a['name']) != null && BizBooks.norm('${b.item(a['name'])!['name']}') == BizBooks.norm(_s(a['name']))) {
          return 'Already in stock: ${line(b.item(a['name'])!)}. Use update or adjust.';
        }
        final it = <String, dynamic>{
          'id': b.nextId('I'),
          'name': _s(a['name']),
          'sku': _s(a['sku']),
          'unit': _s(a['unit']),
          'category': _s(a['category']),
          'cost': _d(a['cost']),
          'price': _d(a['price']),
          'qty': _d(a['qty']),
          if (a['reorder'] != null) 'reorder': _d(a['reorder']),
        };
        b.items.add(it);
        return 'Added ${line(it)}.';
      case 'update':
        final it = b.item(a['item'] ?? a['name']);
        if (it == null) return 'Error: no item matches "${a['item'] ?? a['name']}". ${_itemHint(b)}';
        for (final k in ['sku', 'unit', 'category']) {
          if (a[k] != null) it[k] = _s(a[k]);
        }
        if (_has(a, 'name') && _has(a, 'item')) it['name'] = _s(a['name']);
        for (final k in ['cost', 'price', 'reorder']) {
          if (a[k] != null) it[k] = _d(a[k]);
        }
        if (a['qty'] != null) {
          final diff = _d(a['qty']) - _d(it['qty']);
          if (diff != 0) {
            final t = <String, dynamic>{
              'id': b.nextId('T'), 'date': BizBooks.today(), 'kind': 'adjust', 'amount': 0.0, 'paid': 0.0,
              'lines': [{'item_id': it['id'], 'name': it['name'], 'qty': diff, 'price': 0.0, 'cost': _d(it['cost'])}],
              'note': _s(a['reason']).isEmpty ? 'Stock count' : _s(a['reason']),
            };
            b.tx.add(t);
            b.stockEffect(t, 1);
          }
        }
        return 'Updated ${line(it)}.';
      case 'adjust':
        final it = b.item(a['item'] ?? a['name']);
        if (it == null) return 'Error: no item matches "${a['item'] ?? a['name']}". ${_itemHint(b)}';
        final q = _d(a['qty']);
        if (q == 0) return 'Error: give qty as the change (+5 or -2).';
        final t = <String, dynamic>{
          'id': b.nextId('T'), 'date': BizBooks.day(a['date']), 'kind': 'adjust', 'amount': 0.0, 'paid': 0.0,
          'lines': [{'item_id': it['id'], 'name': it['name'], 'qty': q, 'price': 0.0, 'cost': _d(it['cost'])}],
          'note': _s(a['reason']),
        };
        b.tx.add(t);
        b.stockEffect(t, 1);
        return 'Adjusted ${it['name']} by ${BizBooks.money(q)}${_s(a['reason']).isEmpty ? '' : ' (${a['reason']})'}. ${line(it)}.'
            '${q < 0 ? ' Value lost about ${b.m(-q * _d(it['cost']))}.' : ''}';
      case 'low':
        final low = b.lowStock();
        final zero = b.items.where((i) => _d(i['qty']) <= 0 && i['reorder'] == null).toList();
        if (low.isEmpty && zero.isEmpty) return 'Nothing is low. (Items without a reorder level are only flagged at 0.)';
        return 'Low or out of stock:\n${[...low, ...zero].map(line).join('\n')}';
      case 'history':
        final it = b.item(a['item'] ?? a['name']);
        if (it == null) return 'Error: no item matches. ${_itemHint(b)}';
        final rows = <String>[];
        for (final t in b.tx) {
          for (final l in BizBooks.maps(t['lines'])) {
            if (l['item_id'] != it['id']) continue;
            final q = _d(l['qty']);
            final sign = t['kind'] == 'sale' ? -q : q;
            rows.add('${t['date']} · ${t['id']} · ${t['kind']} · ${sign >= 0 ? '+' : ''}${BizBooks.money(sign)}${_s(t['note']).isEmpty ? '' : ' · ${t['note']}'}');
          }
        }
        return '${it['name']}: ${BizBooks.money(_d(it['qty']))} in stock.\n${rows.isEmpty ? 'No movements yet.' : rows.reversed.take(40).join('\n')}';
      case 'delete':
        final it = b.item(a['item'] ?? a['name']);
        if (it == null) return 'Error: no item matches. ${_itemHint(b)}';
        b.items.remove(it);
        return 'Deleted ${it['name']} from the stock list (past sales keep their lines).';
      default:
        final q = BizBooks.norm(_s(a['query']));
        final list = b.items.where((i) => q.isEmpty || BizBooks.norm('${i['name']} ${i['category']} ${i['sku']}').contains(q)).toList()
          ..sort((x, y) => '${x['name']}'.compareTo('${y['name']}'));
        if (list.isEmpty) return b.items.isEmpty ? 'The stock list is empty. Add items with biz_stock add.' : 'No item matches.';
        return 'Stock (${list.length} items). Value at cost ${b.m(b.stockValue())}, at selling price ${b.m(b.stockValue(atPrice: true))}.\n'
            '${list.take(80).map(line).join('\n')}${list.length > 80 ? '\n(${list.length - 80} more: export with biz_report stock xlsx)' : ''}';
    }
  }

  static String _itemHint(BizBooks b) =>
      b.items.isEmpty ? 'The stock list is empty.' : 'Items: ${b.items.take(15).map((i) => i['name']).join(', ')}${b.items.length > 15 ? '...' : ''}';

  // ------------------------------------------------------------------ contacts and debts

  static Future<String> _contacts(Map<String, dynamic> a, BizBooks b) async {
    final action = _s(a['action']);
    final type = _s(a['type']).isEmpty ? null : _s(a['type']);
    String line(Map<String, dynamic> c) {
      final bal = b.contactBalance('${c['id']}');
      return '${c['id']} · ${c['name']} (${c['type']})${_s(c['phone']).isEmpty ? '' : ' · ${c['phone']}'}'
          '${bal > 0 ? ' · owes you ${b.m(bal)}' : (bal < 0 ? ' · you owe ${b.m(-bal)}' : '')}';
    }

    switch (action) {
      case 'add':
        if (!_has(a, 'name')) return 'Error: give a name.';
        final ex = b.contact(a['name'], type: type);
        if (ex != null && BizBooks.norm('${ex['name']}') == BizBooks.norm(_s(a['name']))) return 'Already saved: ${line(ex)}.';
        final c = <String, dynamic>{
          'id': b.nextId(type == 'supplier' ? 'S' : 'C'),
          'type': type ?? 'customer',
          'name': _s(a['name']),
          'phone': _s(a['phone']),
          'address': _s(a['address']),
          'note': _s(a['note']),
        };
        b.contacts.add(c);
        return 'Saved ${line(c)}.';
      case 'update':
        final c = b.contact(a['contact'] ?? a['name']);
        if (c == null) return 'Error: no contact matches.';
        for (final k in ['phone', 'address', 'note', 'type']) {
          if (a[k] != null) c[k] = _s(a[k]);
        }
        if (_has(a, 'name') && _has(a, 'contact')) c['name'] = _s(a['name']);
        return 'Updated ${line(c)}.';
      case 'delete':
        final c = b.contact(a['contact'] ?? a['name']);
        if (c == null) return 'Error: no contact matches.';
        if (b.contactBalance('${c['id']}') != 0) return 'Not deleted: ${c['name']} still has a balance. Settle it first.';
        b.contacts.remove(c);
        return 'Deleted ${c['name']}.';
      case 'statement':
        final c = b.contact(a['contact'] ?? a['name']);
        if (c == null) return 'Error: no contact matches.';
        var run = 0.0;
        final rows = <List<dynamic>>[];
        final list = b.tx.where((t) => t['contact_id'] == c['id']).toList()..sort((x, y) => '${x['date']}'.compareTo('${y['date']}'));
        for (final t in list) {
          final amt = _d(t['amount']), paid = _d(t['paid']);
          double owe = 0, pay = 0;
          switch (t['kind']) {
            case 'sale':
              owe = amt;
              pay = paid;
              break;
            case 'owed_to_me':
            case 'payment_out':
              owe = amt;
              break;
            case 'payment_in':
            case 'i_owe':
              pay = amt;
              break;
            case 'purchase':
            case 'expense':
              owe = paid;
              pay = amt;
              break;
          }
          run += owe - pay;
          rows.add([t['date'], t['id'], t['kind'], _s(t['note']), owe == 0 ? '' : BizBooks.money(owe), pay == 0 ? '' : BizBooks.money(pay), BizBooks.money(run)]);
        }
        final cols = ['Date', 'Ref', 'Type', 'Note', 'Charged', 'Paid/credited', 'Balance'];
        final head = 'Statement for ${c['name']}: ${run > 0 ? 'owes you ${b.m(run)}' : (run < 0 ? 'you owe ${b.m(-run)}' : 'settled')}.';
        final fmt = _s(a['format']);
        if (fmt == 'pdf') {
          return _saved(await _out('Statement ${c['name']}', 'pdf',
              await BizPdf.report('Statement: ${c['name']}', '${b.name} · ${BizBooks.today()} · ${b.currency}', [ReportPart.text(head), ReportPart.table('', cols, rows)])));
        }
        if (fmt == 'xlsx') return _saved(await _out('Statement ${c['name']}', 'xlsx', DocMaker.xlsxBytes('Statement', cols, rows)));
        return '$head\n${rows.isEmpty ? 'No entries.' : rows.reversed.take(30).toList().reversed.map((r) => r.where((e) => '$e'.isNotEmpty).join(' · ')).join('\n')}';
      default:
        final list = b.contacts.where((c) => type == null || c['type'] == type || c['type'] == 'both').toList()
          ..sort((x, y) => '${x['name']}'.compareTo('${y['name']}'));
        if (list.isEmpty) return 'No ${type ?? 'contact'}s saved yet.';
        return '${list.length} ${type ?? 'contact'}s:\n${list.take(100).map(line).join('\n')}';
    }
  }

  static String _debts(Map<String, dynamic> a, BizBooks b) {
    if (_s(a['action']) == 'reminder') {
      final c = b.contact(a['contact']);
      if (c == null) return 'Error: say which customer.';
      final bal = b.contactBalance('${c['id']}');
      if (bal <= 0) return '${c['name']} owes nothing.';
      final biz = b.name.isEmpty ? '' : b.name;
      final pay = _s(b.profile['payment_info']);
      final so = _s(a['language']) != 'en';
      final msg = so
          ? 'Asalaamu calaykum ${c['name']}, waxaan ku xasuusinayaa in haraaga lagugu leeyahay uu yahay ${b.m(bal)}${biz.isEmpty ? '' : ' ($biz)'}. '
              '${pay.isEmpty ? '' : 'Waxaad ku bixin kartaa: $pay. '}Fadlan noo sheeg goorta aad bixin karto. Mahadsanid.'
          : 'Hello ${c['name']}, a friendly reminder that your balance${biz.isEmpty ? '' : ' with $biz'} is ${b.m(bal)}. '
              '${pay.isEmpty ? '' : 'You can pay by $pay. '}Please let us know when you can pay. Thank you.';
      return 'Draft reminder for ${c['name']}${_s(c['phone']).isEmpty ? '' : ' (${c['phone']})'}. Show it to the user; they send it:\n$msg';
    }
    final dir = _s(a['direction']).isEmpty ? 'both' : _s(a['direction']);
    final owed = <String>[], owe = <String>[];
    var tOwed = 0.0, tOwe = 0.0;
    for (final c in b.contacts) {
      final bal = b.contactBalance('${c['id']}');
      if (bal == 0) continue;
      final age = b.oldestUnpaidDays('${c['id']}');
      final l = '${c['name']}: ${b.m(bal.abs())}${age > 0 ? ' (oldest $age days)' : ''}${_s(c['phone']).isEmpty ? '' : ' · ${c['phone']}'}';
      if (bal > 0) {
        owed.add(l);
        tOwed += bal;
      } else {
        owe.add(l);
        tOwe -= bal;
      }
    }
    final sb = StringBuffer();
    if (dir != 'i_owe') sb.writeln('Owed to you: ${b.m(tOwed)}${owed.isEmpty ? ' (nobody)' : '\n${owed.join('\n')}'}');
    if (dir != 'owed_to_me') sb.writeln('You owe: ${b.m(tOwe)}${owe.isEmpty ? ' (nobody)' : '\n${owe.join('\n')}'}');
    return sb.toString().trim();
  }

  // ------------------------------------------------------------------ tasks

  static String _tasks(Map<String, dynamic> a, BizBooks b) {
    final action = _s(a['action']);
    Map<String, dynamic>? find() {
      final id = _s(a['id']);
      for (final t in b.tasks) {
        if (t['id'] == id) return t;
      }
      final q = BizBooks.norm(_s(a['text']));
      final hits = b.tasks.where((t) => q.isNotEmpty && BizBooks.norm('${t['text']}').contains(q)).toList();
      return hits.length == 1 ? hits.first : null;
    }

    String line(Map<String, dynamic> t) => '${t['id']} · ${t['status'] == 'done' ? '[done] ' : ''}${t['text']}'
        '${_s(t['who']).isEmpty ? '' : ' · ${t['who']}'}${_s(t['due']).isEmpty ? '' : ' · due ${t['due']}'}${t['priority'] == 'high' ? ' · HIGH' : ''}';
    switch (action) {
      case 'add':
        if (!_has(a, 'text')) return 'Error: give the task text.';
        final t = <String, dynamic>{
          'id': b.nextId('K'),
          'text': _s(a['text']),
          'who': _s(a['who']),
          'due': _has(a, 'due') ? BizBooks.day(a['due']) : '',
          'priority': _s(a['priority']).isEmpty ? 'normal' : _s(a['priority']),
          'status': 'open',
          'created': BizBooks.today(),
        };
        b.tasks.add(t);
        return 'Task added: ${line(t)}.';
      case 'update':
      case 'done':
      case 'delete':
        final t = find();
        if (t == null) return 'Error: no single task matches. Give its id.';
        if (action == 'delete') {
          b.tasks.remove(t);
          return 'Deleted: ${t['text']}.';
        }
        if (action == 'done') {
          t['status'] = 'done';
          t['done'] = BizBooks.today();
          return 'Done: ${t['text']}.';
        }
        for (final k in ['who', 'priority']) {
          if (a[k] != null) t[k] = _s(a[k]);
        }
        if (a['due'] != null) t['due'] = BizBooks.day(a['due']);
        if (_has(a, 'text') && _has(a, 'id')) t['text'] = _s(a['text']);
        return 'Updated: ${line(t)}.';
      default:
        final show = _s(a['show']).isEmpty ? 'open' : _s(a['show']);
        final today = BizBooks.today();
        final list = b.tasks.where((t) {
          if (show == 'all') return true;
          if (show == 'done') return t['status'] == 'done';
          if (show == 'overdue') return t['status'] != 'done' && _s(t['due']).isNotEmpty && _s(t['due']).compareTo(today) < 0;
          return t['status'] != 'done';
        }).toList()
          ..sort((x, y) {
            final p = (y['priority'] == 'high' ? 1 : 0) - (x['priority'] == 'high' ? 1 : 0);
            if (p != 0) return p;
            return (_s(x['due']).isEmpty ? '9999' : _s(x['due'])).compareTo(_s(y['due']).isEmpty ? '9999' : _s(y['due']));
          });
        if (list.isEmpty) return 'No $show tasks.';
        return '${list.length} $show tasks:\n${list.map((t) => '${line(t)}${t['status'] != 'done' && _s(t['due']).isNotEmpty && _s(t['due']).compareTo(today) < 0 ? ' · OVERDUE' : ''}').join('\n')}';
    }
  }

  // ------------------------------------------------------------------ documents

  /// Makes and stores a document for a transaction (a sale -> invoice/receipt, a payment -> receipt).
  static Future<String> _makeDoc(BizBooks b, String kind, Map<String, dynamic> t, Map<String, dynamic> a) async {
    final c = b.contact(t['contact_id']);
    final isPay = t['kind'] != 'sale';
    final doc = <String, dynamic>{
      'no': b.nextDocNo(kind),
      'kind': kind,
      'date': t['date'],
      if (kind == 'invoice') 'due': _has(a, 'due') ? BizBooks.day(a['due']) : '',
      'tx_id': t['id'],
      'contact': c == null ? <String, dynamic>{} : {'name': c['name'], 'phone': c['phone'], 'address': c['address']},
      'lines': isPay
          ? [
              {'name': _s(t['note']).isEmpty ? (_has(t, 'against') ? 'Payment for ${t['against']}' : 'Payment') : _s(t['note']), 'qty': 1, 'price': t['amount']}
            ]
          : t['lines'] is List && (t['lines'] as List).isNotEmpty
              ? t['lines']
              : [
                  {'name': _s(t['note']).isEmpty ? 'Goods/services' : _s(t['note']), 'qty': 1, 'price': t['subtotal'] ?? t['amount']}
                ],
      'subtotal': isPay ? t['amount'] : (t['subtotal'] ?? t['amount']),
      'discount': isPay ? 0 : (t['discount'] ?? 0),
      'tax': isPay ? 0 : (t['tax'] ?? 0),
      'tax_rate': isPay ? 0 : (a['tax_rate'] ?? b.profile['tax_rate'] ?? 0),
      'total': t['amount'],
      'paid': isPay ? t['amount'] : t['paid'],
      'method': t['account'],
      if (kind == 'receipt' && c != null) 'balance': b.contactBalance('${c['id']}'),
      'note': _s(a['note']),
      'status': 'issued',
    };
    final path = await _out('${doc['no']}${c == null ? '' : ' ${c['name']}'}', 'pdf', await BizPdf.document(b, doc));
    doc['file'] = path;
    b.docs.add(doc);
    t['doc'] = doc['no'];
    return '${kind == 'invoice' ? 'Invoice' : 'Receipt'} ${doc['no']} made.\n${_saved(path)}';
  }

  static Future<String> _document(Map<String, dynamic> a, BizBooks b) async {
    final action = _s(a['action']);
    Map<String, dynamic>? byNo() {
      final no = _s(a['no']).toUpperCase();
      for (final d in b.docs) {
        if (d['no'] == no) return d;
      }
      return null;
    }

    switch (action) {
      case 'list':
        if (b.docs.isEmpty) return 'No documents yet.';
        return b.docs.reversed.take(40).map((d) {
          final open = d['kind'] == 'invoice' && d['status'] != 'void' ? _d(d['total']) - _d(d['paid']) : 0.0;
          return '${d['no']} · ${d['kind']} · ${d['date']} · ${(d['contact'] as Map?)?['name'] ?? ''} · ${b.m(_d(d['total']))}'
              '${d['status'] == 'void' ? ' · VOID' : (open > 0.005 ? ' · unpaid ${b.m(open)}' : (d['kind'] == 'invoice' ? ' · paid' : ''))}';
        }).join('\n');
      case 'show':
        final d = byNo();
        if (d == null) return 'Error: no document ${a['no']}.';
        if (_s(d['file']).isNotEmpty && await File('${d['file']}').exists()) return '${d['no']} (${d['kind']}).\n${_saved('${d['file']}')}';
        final path = await _out('${d['no']}', 'pdf', await BizPdf.document(b, d));
        d['file'] = path;
        return _saved(path);
      case 'void':
        final d = byNo();
        if (d == null) return 'Error: no document ${a['no']}.';
        d['status'] = 'void';
        final t = b.txById('${d['tx_id'] ?? ''}');
        return '${d['no']} marked void.${t != null && t['kind'] == 'sale' ? ' Its sale ${t['id']} is still in the books: delete it with biz_records if the sale did not happen.' : ''}';
      case 'mark_paid':
        final d = byNo();
        if (d == null || d['kind'] != 'invoice') return 'Error: no invoice ${a['no']}.';
        final open = _d(d['total']) - _d(d['paid']);
        if (open <= 0.005) return '${d['no']} is already paid.';
        final amt = a['paid'] != null ? _d(a['paid']) : open;
        final t = b.txById('${d['tx_id'] ?? ''}');
        final pay = <String, dynamic>{
          'id': b.nextId('T'), 'date': BizBooks.day(a['date']), 'kind': 'payment_in', 'amount': amt, 'paid': 0.0,
          'account': b.account(a['account']), if (t?['contact_id'] != null) 'contact_id': t!['contact_id'], 'against': d['no'],
          'note': 'Payment for ${d['no']}',
        };
        b.tx.add(pay);
        d['paid'] = _d(d['paid']) + amt;
        final left = _d(d['total']) - _d(d['paid']);
        return 'Recorded ${b.m(amt)} for ${d['no']} into ${pay['account']}. ${left > 0.005 ? 'Still unpaid: ${b.m(left)}.' : 'Fully paid.'}';
    }

    // create
    final kind = _s(a['kind']).isEmpty ? 'invoice' : _s(a['kind']);
    if (_has(a, 'sale_id')) {
      final t = b.txById(_s(a['sale_id']));
      if (t == null || t['kind'] != 'sale') return 'Error: no sale ${a['sale_id']}.';
      if (kind == 'invoice' || kind == 'receipt') return _makeDoc(b, kind, t, a);
      if (kind == 'delivery_note') {
        final c = b.contact(t['contact_id']);
        final d = <String, dynamic>{
          'no': b.nextDocNo(kind), 'kind': kind, 'date': BizBooks.day(a['date']), 'tx_id': t['id'],
          'contact': c == null ? <String, dynamic>{} : {'name': c['name'], 'phone': c['phone'], 'address': c['address']},
          'lines': t['lines'], 'note': _s(a['note']), 'status': 'issued',
        };
        final path = await _out('${d['no']}', 'pdf', await BizPdf.document(b, d));
        d['file'] = path;
        b.docs.add(d);
        return 'Delivery note ${d['no']} made.\n${_saved(path)}';
      }
    }
    final selling = kind != 'purchase_order';
    final ls = b.lines(a['lines'], selling: selling);
    if (ls.isEmpty) return 'Error: give lines (or sale_id).';
    final subtotal = BizBooks.linesTotal(ls);
    final (disc, tax, total) = _totals(b, subtotal, a);
    final who = _has(a, 'customer') ? b.contactOrNew(_s(a['customer']), selling ? 'customer' : 'supplier') : null;
    if (kind == 'invoice' && a['record'] != false) {
      if (who == null) return 'Error: an invoice needs the customer\'s name.';
      final paid = _d(a['paid']);
      final t = <String, dynamic>{
        'id': b.nextId('T'), 'date': BizBooks.day(a['date']), 'kind': 'sale', 'lines': ls, 'amount': total, 'subtotal': subtotal,
        'discount': disc, 'tax': tax, 'paid': paid, 'account': b.account(a['account']), 'contact_id': who['id'], 'note': _s(a['note']),
      };
      b.tx.add(t);
      b.stockEffect(t, 1);
      final r = await _makeDoc(b, 'invoice', t, a);
      return 'Recorded as sale ${t['id']} (${b.m(total)}, ${paid >= total ? 'paid' : '${b.m(total - paid)} owed by ${who['name']}'}).\n$r';
    }
    final d = <String, dynamic>{
      'no': b.nextDocNo(kind),
      'kind': kind,
      'date': BizBooks.day(a['date']),
      if (kind == 'invoice') 'due': _has(a, 'due') ? BizBooks.day(a['due']) : '',
      if (kind == 'quote') 'valid_until': _has(a, 'valid_until') ? BizBooks.day(a['valid_until']) : '',
      'contact': who == null ? <String, dynamic>{} : {'name': who['name'], 'phone': who['phone'], 'address': who['address']},
      'lines': ls, 'subtotal': subtotal, 'discount': disc, 'tax': tax,
      'tax_rate': a['tax_rate'] ?? b.profile['tax_rate'] ?? 0, 'total': total, 'paid': _d(a['paid']), 'method': _s(a['account']),
      'note': _s(a['note']), 'status': 'issued',
    };
    final path = await _out('${d['no']}${who == null ? '' : ' ${who['name']}'}', 'pdf', await BizPdf.document(b, d));
    d['file'] = path;
    b.docs.add(d);
    return '${kind.replaceAll('_', ' ')} ${d['no']} made for ${b.m(total)}${kind == 'quote' ? ' (not recorded as a sale)' : ''}.\n${_saved(path)}';
  }

  // ------------------------------------------------------------------ reports

  static Future<String> _report(Map<String, dynamic> a, BizBooks b) async {
    final type = _s(a['type']);
    final (from, to, label) = BizBooks.range(_s(a['period']).isEmpty ? null : _s(a['period']), from: _s(a['from']), to: _s(a['to']));
    final fmt = _s(a['format']).isEmpty ? 'chat' : _s(a['format']);
    final cur = b.currency;
    final title = const {
          'summary': 'Business summary',
          'profit_loss': 'Profit and loss',
          'cashbook': 'Cashbook',
          'sales': 'Sales report',
          'expenses': 'Expenses report',
          'stock': 'Stock report',
          'debts': 'Debts report',
          'tasks': 'Tasks',
        }[type] ?? 'Report';
    final sub = '${b.name.isEmpty ? '' : '${b.name} · '}$label · $cur';
    final text = StringBuffer('$title, $label ($cur)\n');
    final charts = <String>[];
    final parts = <ReportPart>[];
    var cols = <String>[];
    var rows = <List<dynamic>>[];
    String m(double v) => BizBooks.money(v);

    switch (type) {
      case 'summary':
      case 'profit_loss':
        final pl = b.profitLoss(from, to);
        final exp = Map<String, double>.from(pl['expenses'] as Map);
        final figures = [
          ['Sales', m(pl['revenue'] as double)],
          ['Gross profit', m(pl['gross_profit'] as double)],
          ['Net profit', m(pl['net_profit'] as double)],
        ];
        text.writeln('Sales ${m(pl['revenue'] as double)} - cost of goods ${m(pl['cost_of_goods'] as double)} = gross profit '
            '${m(pl['gross_profit'] as double)} (${(pl['gross_margin'] as double).toStringAsFixed(1)}% margin).');
        text.writeln('Expenses ${m(pl['total_expenses'] as double)}${exp.isEmpty ? '' : ': ${BizBooks.top(exp, 6).map((e) => '${e.key} ${m(e.value)}').join(', ')}'}.');
        if ((pl['other_income'] as double) != 0) text.writeln('Other income ${m(pl['other_income'] as double)}.');
        text.writeln('Net profit ${m(pl['net_profit'] as double)}.${(pl['tax_collected'] as double) > 0 ? ' Tax collected on sales (not income): ${m(pl['tax_collected'] as double)}.' : ''}');
        if ((pl['cost_of_goods'] as double) == 0 && (pl['revenue'] as double) > 0) {
          text.writeln('Note: no cost of goods is recorded, so gross profit equals sales. Add item costs (biz_stock) for a true profit.');
        }
        cols = ['Line', 'Amount ($cur)'];
        rows = [
          ['Sales', pl['revenue']],
          ['Cost of goods sold', -(pl['cost_of_goods'] as double)],
          ['Gross profit', pl['gross_profit']],
          for (final e in exp.entries) ['Expense: ${e.key}', -e.value],
          if ((pl['other_income'] as double) != 0) ['Other income', pl['other_income']],
          ['Net profit', pl['net_profit']],
        ];
        parts.add(ReportPart.figures(figures));
        if (type == 'summary') {
          final bal = b.balances(upTo: to);
          final owed = b.contacts.fold(0.0, (s, c) => s + (b.contactBalance('${c['id']}') > 0 ? b.contactBalance('${c['id']}') : 0));
          final owe = b.contacts.fold(0.0, (s, c) => s + (b.contactBalance('${c['id']}') < 0 ? -b.contactBalance('${c['id']}') : 0));
          text.writeln('Money now: ${bal.entries.map((e) => '${e.key} ${m(e.value)}').join(', ')} (total ${m(bal.values.fold(0.0, (x, y) => x + y))}).');
          text.writeln('Customers owe you ${m(owed)}; you owe suppliers ${m(owe)}. Stock value at cost ${m(b.stockValue())}.');
          final low = b.lowStock();
          if (low.isNotEmpty) text.writeln('Low stock: ${low.map((i) => '${i['name']} (${m(BizBooks.d(i['qty']))})').join(', ')}.');
          final topItems = BizBooks.top(b.salesByItem(from, to), 5);
          if (topItems.isNotEmpty) text.writeln('Best sellers: ${topItems.map((e) => '${e.key} ${m(e.value)}').join(', ')}.');
          final overdue = b.tasks.where((t) => t['status'] != 'done' && _s(t['due']).isNotEmpty && _s(t['due']).compareTo(BizBooks.today()) < 0).length;
          if (overdue > 0) text.writeln('$overdue overdue task(s).');
          parts.add(ReportPart.figures([
            ['Money now', m(bal.values.fold(0.0, (x, y) => x + y))],
            ['Owed to you', m(owed)],
            ['Stock value', m(b.stockValue())],
          ]));
          final byDay = b.salesByDay(from, to);
          if (byDay.length > 1) {
            charts.add(BizBooks.chart('line', 'Sales by day', byDay.entries.toList(), unit: cur));
            parts.add(ReportPart.columnsChart('Sales by day', byDay.entries.toList()));
          }
          if (topItems.isNotEmpty) {
            charts.add(BizBooks.chart('bars', 'Best sellers', topItems, unit: cur));
            parts.add(ReportPart.bars('Best sellers', topItems));
          }
        }
        if (exp.isNotEmpty) {
          charts.add(BizBooks.chart('donut', 'Expenses', BizBooks.top(exp, 8), unit: cur));
          parts.add(ReportPart.bars('Expenses by category', BizBooks.top(exp, 10)));
        }
        parts.add(ReportPart.table('Profit and loss', cols, [for (final r in rows) [r[0], m(BizBooks.d(r[1]))]]));
        break;
      case 'cashbook':
        final only = _has(a, 'account') ? b.account(a['account']) : null;
        final opening = b.balances(upTo: _dayBefore(from));
        var run = only == null ? opening.values.fold(0.0, (x, y) => x + y) : (opening[only] ?? 0);
        final startBal = run;
        double tin = 0, tout = 0;
        cols = ['Date', 'Ref', 'Type', 'Account', 'Details', 'In', 'Out', 'Balance'];
        final list = b.txIn(from, to)..sort((x, y) => '${x['date']}${x['id']}'.compareTo('${y['date']}${y['id']}'));
        for (final t in list) {
          b.cashEffect(t).forEach((acc, v) {
            if (acc.isEmpty || v == 0) return;
            if (only != null && acc != only) return;
            if (only == null && t['kind'] == 'transfer') return; // nets to zero overall
            run += v;
            if (v > 0) {
              tin += v;
            } else {
              tout -= v;
            }
            final who = b.contact(t['contact_id']);
            rows.add([t['date'], t['id'], t['kind'], acc, [if (who != null) who['name'], if (_s(t['note']).isNotEmpty) t['note'], if (_s(t['category']).isNotEmpty) t['category']].join(' · '),
              v > 0 ? double.parse(v.toStringAsFixed(2)) : '', v < 0 ? double.parse((-v).toStringAsFixed(2)) : '', double.parse(run.toStringAsFixed(2))]);
          });
        }
        text.writeln('${only ?? 'All accounts'}: opening ${m(startBal)}, money in ${m(tin)}, money out ${m(tout)}, closing ${m(run)}.');
        for (final r in rows.reversed.take(25).toList().reversed) {
          text.writeln('${r[0]} · ${r[2]} · ${r[4]} · ${r[5] == '' ? '-${m(BizBooks.d(r[6]))}' : '+${m(BizBooks.d(r[5]))}'} → ${m(BizBooks.d(r[7]))}');
        }
        if (rows.length > 25) text.writeln('(${rows.length - 25} earlier lines: use format pdf or xlsx for all)');
        parts.add(ReportPart.figures([['Opening', m(startBal)], ['In', m(tin)], ['Out', m(tout)], ['Closing', m(run)]]));
        parts.add(ReportPart.table('', cols, [for (final r in rows) [r[0], r[1], r[2], r[3], r[4], r[5] == '' ? '' : m(BizBooks.d(r[5])), r[6] == '' ? '' : m(BizBooks.d(r[6])), m(BizBooks.d(r[7]))]]));
        break;
      case 'sales':
        final byItem = b.salesByItem(from, to);
        final qty = b.salesByItem(from, to, byQty: true);
        final byCust = b.salesByCustomer(from, to);
        final byDay = b.salesByDay(from, to);
        final total = byDay.values.fold(0.0, (x, y) => x + y);
        final n = b.txIn(from, to).where((t) => t['kind'] == 'sale').length;
        text.writeln('$n sales, total ${m(total)}${n == 0 ? '' : ', average ${m(total / n)} per sale'}.');
        final ti = BizBooks.top(byItem, 10);
        if (ti.isNotEmpty) text.writeln('By item: ${ti.map((e) => '${e.key} ${m(e.value)} (${m(qty[e.key] ?? 0)} sold)').join(', ')}.');
        final tc = BizBooks.top(byCust, 8);
        if (tc.isNotEmpty) text.writeln('By customer: ${tc.map((e) => '${e.key} ${m(e.value)}').join(', ')}.');
        if (byDay.length > 1) {
          final best = BizBooks.top(byDay, 1).first;
          text.writeln('Best day ${best.key} (${m(best.value)}).');
          final monthly = byDay.length > 62 ? b.salesByMonth(from, to) : byDay;
          charts.add(BizBooks.chart('line', byDay.length > 62 ? 'Sales by month' : 'Sales by day', monthly.entries.toList(), unit: cur));
          parts.add(ReportPart.columnsChart(byDay.length > 62 ? 'Sales by month' : 'Sales by day', monthly.entries.toList()));
        }
        if (ti.isNotEmpty) {
          charts.add(BizBooks.chart('bars', 'Sales by item', ti, unit: cur));
          parts.add(ReportPart.bars('Sales by item', ti));
        }
        if (tc.isNotEmpty) parts.add(ReportPart.bars('Sales by customer', tc));
        parts.insert(0, ReportPart.figures([['Sales', m(total)], ['Number of sales', '$n'], ['Average sale', n == 0 ? '0' : m(total / n)]]));
        cols = ['Item', 'Quantity', 'Sales ($cur)'];
        rows = [for (final e in BizBooks.top(byItem, 1000)) [e.key, qty[e.key] ?? 0, double.parse(e.value.toStringAsFixed(2))]];
        parts.add(ReportPart.table('All items', cols, [for (final r in rows) [r[0], m(BizBooks.d(r[1])), m(BizBooks.d(r[2]))]]));
        break;
      case 'expenses':
        final pl = b.profitLoss(from, to);
        final exp = Map<String, double>.from(pl['expenses'] as Map);
        final total = pl['total_expenses'] as double;
        text.writeln('Expenses ${m(total)}${exp.isEmpty ? '' : ': ${BizBooks.top(exp, 10).map((e) => '${e.key} ${m(e.value)} (${total == 0 ? 0 : (e.value / total * 100).round()}%)').join(', ')}'}.');
        if (exp.isNotEmpty) {
          charts.add(BizBooks.chart('donut', 'Expenses by category', BizBooks.top(exp, 8), unit: cur));
          parts.add(ReportPart.bars('Expenses by category', BizBooks.top(exp, 12)));
        }
        cols = ['Date', 'Ref', 'Category', 'Supplier', 'Note', 'Amount ($cur)', 'Paid'];
        rows = [
          for (final t in b.txIn(from, to).where((t) => t['kind'] == 'expense'))
            [t['date'], t['id'], t['category'], b.contact(t['contact_id'])?['name'] ?? '', t['note'], BizBooks.d(t['amount']), BizBooks.d(t['paid'])]
        ];
        parts.add(ReportPart.table('All expenses', cols, [for (final r in rows) [r[0], r[1], r[2], r[3], r[4], m(BizBooks.d(r[5])), m(BizBooks.d(r[6]))]]));
        break;
      case 'stock':
        final list = [...b.items]..sort((x, y) => (BizBooks.d(y['qty']) * BizBooks.d(y['cost'])).compareTo(BizBooks.d(x['qty']) * BizBooks.d(x['cost'])));
        final sold = b.salesByItem(from, to, byQty: true);
        text.writeln('${list.length} items. Value at cost ${m(b.stockValue())}, at selling price ${m(b.stockValue(atPrice: true))}.');
        final low = b.lowStock();
        if (low.isNotEmpty) text.writeln('Low: ${low.map((i) => '${i['name']} (${m(BizBooks.d(i['qty']))})').join(', ')}.');
        final slow = list.where((i) => BizBooks.d(i['qty']) > 0 && (sold[i['name']] ?? 0) == 0).take(8).toList();
        if (slow.isNotEmpty) text.writeln('Did not sell in $label: ${slow.map((i) => i['name']).join(', ')}.');
        cols = ['Item', 'Code', 'Qty', 'Unit cost', 'Price', 'Value at cost', 'Sold ($label)', 'Reorder at'];
        rows = [
          for (final i in list)
            [i['name'], i['sku'] ?? '', BizBooks.d(i['qty']), BizBooks.d(i['cost']), BizBooks.d(i['price']),
              double.parse((BizBooks.d(i['qty']) * BizBooks.d(i['cost'])).toStringAsFixed(2)), sold[i['name']] ?? 0, i['reorder'] ?? '']
        ];
        final byValue = [for (final i in list.take(10)) MapEntry('${i['name']}', BizBooks.d(i['qty']) * BizBooks.d(i['cost']))];
        if (byValue.isNotEmpty) {
          charts.add(BizBooks.chart('bars', 'Stock value by item', byValue, unit: cur));
          parts.add(ReportPart.bars('Stock value by item (top 10)', byValue));
        }
        parts.insert(0, ReportPart.figures([['Items', '${list.length}'], ['Value at cost', m(b.stockValue())], ['Low stock', '${low.length}']]));
        parts.add(ReportPart.table('All items', cols, [for (final r in rows) [r[0], r[1], m(BizBooks.d(r[2])), m(BizBooks.d(r[3])), m(BizBooks.d(r[4])), m(BizBooks.d(r[5])), m(BizBooks.d(r[6])), '${r[7]}']]));
        break;
      case 'debts':
        cols = ['Name', 'Type', 'Phone', 'Owes you', 'You owe', 'Oldest (days)'];
        for (final c in b.contacts) {
          final bal = b.contactBalance('${c['id']}');
          if (bal == 0) continue;
          rows.add([c['name'], c['type'], c['phone'] ?? '', bal > 0 ? bal : 0, bal < 0 ? -bal : 0, b.oldestUnpaidDays('${c['id']}')]);
        }
        rows.sort((x, y) => (BizBooks.d(y[3]) + BizBooks.d(y[4])).compareTo(BizBooks.d(x[3]) + BizBooks.d(x[4])));
        final owed = rows.fold(0.0, (s, r) => s + BizBooks.d(r[3])), owe = rows.fold(0.0, (s, r) => s + BizBooks.d(r[4]));
        text.writeln(_debts({'direction': 'both'}, b));
        final top = [for (final r in rows.where((r) => BizBooks.d(r[3]) > 0).take(10)) MapEntry('${r[0]}', BizBooks.d(r[3]))];
        if (top.isNotEmpty) {
          charts.add(BizBooks.chart('bars', 'Who owes you', top, unit: cur));
          parts.add(ReportPart.bars('Who owes you', top));
        }
        parts.insert(0, ReportPart.figures([['Owed to you', m(owed)], ['You owe', m(owe)], ['People', '${rows.length}']]));
        parts.add(ReportPart.table('', cols, [for (final r in rows) [r[0], r[1], r[2], m(BizBooks.d(r[3])), m(BizBooks.d(r[4])), '${r[5]}']]));
        break;
      case 'tasks':
        cols = ['Id', 'Task', 'Who', 'Due', 'Priority', 'Status'];
        rows = [for (final t in b.tasks) [t['id'], t['text'], t['who'], t['due'], t['priority'], t['status']]];
        text.writeln(_tasks({'action': 'list', 'show': 'open'}, b));
        parts.add(ReportPart.table('', cols, rows));
        break;
      default:
        return 'Error: unknown report type $type.';
    }

    if (fmt == 'pdf') {
      return '${text.toString().trim()}\n${_saved(await _out('$title $label', 'pdf', await BizPdf.report(title, sub, parts)))}';
    }
    if (fmt == 'xlsx' || fmt == 'csv') {
      if (cols.isEmpty) return 'Nothing to put in a sheet for this report.';
      final bytes = fmt == 'xlsx' ? DocMaker.xlsxBytes(title, cols, rows) : utf8.encode(DocMaker.csvText(cols, rows));
      return '${text.toString().trim()}\n${_saved(await _out('$title $label', fmt, bytes))}';
    }
    final cards = charts.where((c) => c.isNotEmpty).toList();
    return '${text.toString().trim()}${cards.isEmpty ? '' : '\n\nChart cards (paste the ones that help into your reply as they are):\n${cards.join('\n')}'}';
  }

  static String _dayBefore(String iso) {
    final t = DateTime.tryParse(iso);
    if (t == null) return '0000-01-01';
    return t.subtract(const Duration(days: 1)).toIso8601String().substring(0, 10);
  }

  // ------------------------------------------------------------------ records

  static Future<String> _records(Map<String, dynamic> a, BizBooks b) async {
    final action = _s(a['action']);
    if (action == 'delete') {
      final t = b.txById(_s(a['id']));
      if (t == null) return 'Error: no entry ${a['id']}.';
      b.stockEffect(t, -1);
      b.tx.remove(t);
      if (_has(t, 'against')) {
        for (final d in b.docs) {
          if (d['no'] == t['against']) d['paid'] = _d(d['paid']) - _d(t['amount']);
        }
      }
      for (final d in b.docs) {
        if (d['tx_id'] == t['id'] && d['status'] != 'void') d['status'] = 'void';
      }
      return 'Deleted ${t['id']} (${t['kind']} ${b.m(_d(t['amount']))} on ${t['date']}); its stock and money effects are undone'
          '${_has(t, 'doc') ? ' and ${t['doc']} is void' : ''}.';
    }
    if (action == 'export') {
      final cols = ['Id', 'Date', 'Type', 'Amount', 'Paid', 'Account', 'To account', 'Contact', 'Category', 'Items', 'Note', 'Document'];
      final rows = [
        for (final t in b.tx)
          [t['id'], t['date'], t['kind'], _d(t['amount']), _d(t['paid']), t['account'] ?? '', t['to_account'] ?? '', b.contact(t['contact_id'])?['name'] ?? '',
            t['category'] ?? '', BizBooks.maps(t['lines']).map((l) => '${BizBooks.money(_d(l['qty']))} x ${l['name']} @ ${BizBooks.money(_d(l['price']))}').join('; '),
            t['note'] ?? '', t['doc'] ?? '']
      ];
      return '${rows.length} entries exported (${b.items.length} stock items and ${b.contacts.length} contacts are in the stock and debts reports).\n'
          '${_saved(await _out('Business books ${BizBooks.today()}', 'xlsx', DocMaker.xlsxBytes('Books', cols, rows)))}';
    }
    final (from, to, label) = BizBooks.range(_s(a['period']).isEmpty ? 'all' : _s(a['period']));
    final kind = _s(a['kind']);
    final q = BizBooks.norm(_s(a['query']));
    final list = b.txIn(from, to).where((t) {
      if (kind.isNotEmpty && t['kind'] != kind) return false;
      if (q.isEmpty) return true;
      final who = b.contact(t['contact_id']);
      final hay = BizBooks.norm('${t['id']} ${t['note']} ${t['category']} ${t['doc'] ?? ''} ${who?['name'] ?? ''} '
          '${BizBooks.maps(t['lines']).map((l) => l['name']).join(' ')} ${t['amount']}');
      return hay.contains(q);
    }).toList();
    if (list.isEmpty) return 'No entries found ($label).';
    final n = (a['limit'] as num?)?.toInt() ?? 30;
    return '${list.length} entries ($label), newest first:\n${list.reversed.take(n).map((t) {
      final who = b.contact(t['contact_id']);
      final ls = BizBooks.maps(t['lines']);
      return '${t['id']} · ${t['date']} · ${t['kind']} · ${b.m(_d(t['amount']))}'
          '${t['kind'] == 'sale' || t['kind'] == 'purchase' || t['kind'] == 'expense' ? ' (paid ${BizBooks.money(_d(t['paid']))})' : ''}'
          '${who == null ? '' : ' · ${who['name']}'}${_s(t['category']).isEmpty ? '' : ' · ${t['category']}'}'
          '${ls.isEmpty ? '' : ' · ${ls.map((l) => '${BizBooks.money(_d(l['qty']))} ${l['name']}').join(', ')}'}${_s(t['note']).isEmpty ? '' : ' · ${t['note']}'}'
          '${_has(t, 'doc') ? ' · ${t['doc']}' : ''}';
    }).join('\n')}';
  }

  // ------------------------------------------------------------------ data analyst

  static Future<String> _data(Map<String, dynamic> a) async {
    var path = _s(a['path']);
    if (path.isEmpty) return 'Error: give the file path.';
    if (!path.startsWith('/')) path = '${dirOverride ?? await AgentTools.workspaceDir()}/$path';
    final f = File(path);
    if (!await f.exists()) return 'Error: file not found: ${a['path']}';
    final low = path.toLowerCase();
    SheetTable t;
    if (low.endsWith('.xlsx') || low.endsWith('.xlsm')) {
      final sheets = SheetTable.fromXlsx(await f.readAsBytes());
      if (sheets.isEmpty) return 'Error: no sheets found in that file.';
      if (_s(a['action']) == 'sheets') {
        return sheets.entries.map((e) => '${e.key}: ${e.value.rows.length} rows, columns ${e.value.columns.join(', ')}').join('\n');
      }
      final want = _s(a['sheet']);
      final key = want.isEmpty ? sheets.keys.first : sheets.keys.firstWhere((k) => k.toLowerCase() == want.toLowerCase(), orElse: () => '');
      if (key.isEmpty) return 'Error: no sheet "$want". Sheets: ${sheets.keys.join(', ')}';
      t = sheets[key]!;
    } else if (low.endsWith('.json')) {
      t = SheetTable.fromJson(await f.readAsString());
    } else if (low.endsWith('.xls')) {
      return 'Error: old .xls files are not supported. Ask the user to save it as .xlsx or CSV.';
    } else {
      t = SheetTable.fromCsv(await f.readAsString());
    }
    if (t.columns.isEmpty) return 'The file has no table data.';
    final action = _s(a['action']);
    if (action == 'describe' || action == 'sheets') return t.describe();

    // query
    if (a['filters'] is List) t = t.filter([for (final x in a['filters'] as List) if (x is Map) Map<String, dynamic>.from(x)]);
    if (a['compute'] is List) {
      for (final c in a['compute'] as List) {
        if (c is Map && _s(c['name']).isNotEmpty && _s(c['formula']).isNotEmpty) t = t.compute(_s(c['name']), _s(c['formula']));
      }
    }
    if (a['pivot'] is Map) {
      final p = a['pivot'] as Map;
      t = t.pivot(_s(p['rows']), _s(p['cols']), _s(p['value']), fn: _s(p['fn']).isEmpty ? 'sum' : _s(p['fn']));
    } else if (a['group_by'] is List && (a['group_by'] as List).isNotEmpty) {
      t = t.group([for (final g in a['group_by'] as List) '$g'], [for (final x in (a['aggregate'] as List? ?? const [])) if (x is Map) Map<String, dynamic>.from(x)]);
    }
    if (a['columns'] is List && (a['columns'] as List).isNotEmpty) t = t.select([for (final c in a['columns'] as List) '$c']);
    if (_has(a, 'sort')) t = t.sort(_s(a['sort']), desc: a['desc'] == true);
    if (a['limit'] is num) t = t.limit((a['limit'] as num).toInt());
    final sb = StringBuffer('${t.rows.length} rows:\n${t.markdown(limit: 40)}');
    if (a['chart'] is Map) {
      final c = a['chart'] as Map;
      final label = _s(c['label']).isEmpty ? t.columns.first : _s(c['label']);
      final value = _s(c['value']).isEmpty ? t.columns.last : _s(c['value']);
      sb.write('\nChart card (paste it into your reply as it is):\n${t.chart(label, value, type: _s(c['type']).isEmpty ? 'bars' : _s(c['type']), title: _s(c['title']))}');
    }
    final save = _s(a['save_as']);
    if (save == 'xlsx' || save == 'csv') {
      final name = _s(a['title']).isEmpty ? 'Analysis ${BizBooks.today()}' : _s(a['title']);
      final bytes = save == 'xlsx' ? DocMaker.xlsxBytes(name, t.columns, t.rows) : utf8.encode(DocMaker.csvText(t.columns, t.rows));
      sb.write('\n${_saved(await _out(name, save, bytes))}');
    }
    return sb.toString();
  }
}
