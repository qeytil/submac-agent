import 'dart:io';

import 'package:agent/services/biz_books.dart';
import 'package:agent/services/biz_tools.dart';
import 'package:agent/services/data_sheet.dart';
import 'package:agent/services/doc_maker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('biz');
    BizTools.dirOverride = tmp.path;
  });
  tearDown(() async {
    BizTools.dirOverride = null;
    await tmp.delete(recursive: true);
  });

  Future<String> run(String name, Map<String, dynamic> a) => BizTools.execute(name, a);

  group('Business books', () {
    test('stock, a sale on credit, a payment and the profit add up', () async {
      await run('biz_setup', {'action': 'set', 'name': 'Hodan Shop', 'currency': 'usd', 'accounts': ['Cash', 'EVC Plus']});
      expect(await run('biz_stock', {'action': 'add', 'name': 'Rice 25kg', 'cost': 18, 'price': 24, 'qty': 10, 'reorder': 3}), contains('Added'));
      final sale = await run('biz_sale', {
        'lines': [
          {'item': 'rice', 'qty': 8}
        ],
        'customer': 'Ahmed',
        'paid': 100,
        'account': 'EVC Plus',
      });
      expect(sale, contains('192 USD'));
      expect(sale, contains('Ahmed now owes 92 USD'));
      expect(sale, contains('low'));
      final b = await BizTools.load();
      expect(BizBooks.d(b.item('Rice 25kg')!['qty']), 2);
      expect(b.balances()['EVC Plus'], 100);

      await run('biz_payment', {'kind': 'payment_in', 'amount': 50, 'contact': 'Ahmed', 'account': 'Cash'});
      await run('biz_expense', {'kind': 'expense', 'amount': 20, 'category': 'Transport'});
      final b2 = await BizTools.load();
      final c = b2.contact('Ahmed')!;
      expect(b2.contactBalance('${c['id']}'), 42);
      expect(b2.balances()['Cash'], 30);
      final (from, to, _) = BizBooks.range('all');
      final pl = b2.profitLoss(from, to);
      expect(pl['revenue'], 192);
      expect(pl['cost_of_goods'], 144);
      expect(pl['net_profit'], 28);

      final rep = await run('biz_report', {'type': 'summary', 'period': 'all'});
      expect(rep, contains('Net profit 28'));
      expect(rep, contains('```diagram'));
      expect(await run('biz_debts', {'action': 'list'}), contains('Ahmed: 42 USD'));
      expect(await run('biz_debts', {'action': 'reminder', 'contact': 'Ahmed'}), contains('42 USD'));
    });

    test('purchases raise stock with an average cost; deleting a sale undoes it', () async {
      await run('biz_stock', {'action': 'add', 'name': 'Sugar', 'cost': 10, 'price': 14, 'qty': 10});
      await run('biz_expense', {'kind': 'purchase', 'lines': [{'item': 'Sugar', 'qty': 10, 'price': 12}], 'supplier': 'Bakaaro wholesale'});
      var b = await BizTools.load();
      expect(BizBooks.d(b.item('Sugar')!['qty']), 20);
      expect(BizBooks.d(b.item('Sugar')!['cost']), 11);
      final r = await run('biz_sale', {'lines': [{'item': 'Sugar', 'qty': 5}]});
      final id = RegExp(r'Sale (T\d+)').firstMatch(r)!.group(1)!;
      await run('biz_records', {'action': 'delete', 'id': id});
      b = await BizTools.load();
      expect(BizBooks.d(b.item('Sugar')!['qty']), 20);
    });

    test('tasks and the xlsx report', () async {
      await run('biz_tasks', {'action': 'add', 'text': 'Pay rent', 'due': '2020-01-01', 'priority': 'high'});
      expect(await run('biz_tasks', {'action': 'list', 'show': 'overdue'}), contains('Pay rent'));
      await run('biz_sale', {'amount': 40, 'note': 'Phone repair'});
      final x = await run('biz_report', {'type': 'sales', 'period': 'all', 'format': 'xlsx'});
      expect(x, contains('FILE_SAVED'));
    });

    test('an invoice PDF is made and recorded', () async {
      await run('biz_setup', {'action': 'set', 'name': 'Hodan Shop'});
      final r = await run('biz_document', {
        'action': 'create',
        'kind': 'invoice',
        'customer': 'Faadumo',
        'lines': [
          {'item': 'Abaya', 'qty': 2, 'price': 35}
        ],
      });
      expect(r, contains('INV-0001'));
      final path = RegExp(r'FILE_SAVED (.+)').firstMatch(r)!.group(1)!.trim();
      expect(await File(path).exists(), isTrue);
      final m = await run('biz_document', {'action': 'mark_paid', 'no': 'INV-0001'});
      expect(m, contains('Fully paid'));
    });
  });

  group('Business maths', () {
    test('margin, break-even and discount', () {
      expect(BizCalc.run({'mode': 'price_for_margin', 'cost': 6, 'margin_pct': 40}), contains('= 10'));
      expect(BizCalc.run({'mode': 'break_even', 'fixed_costs': 400, 'price': 10, 'cost': 6}), contains('100 units'));
      expect(BizCalc.run({'mode': 'discount', 'price': 10, 'cost': 7, 'discount_pct': 20}), contains('3.00x'));
    });
  });

  group('Data sheets', () {
    const csv = 'Date,Item,Qty,Price\n2026-10-01,Rice,2,24\n2026-10-01,Sugar,1,14\n2026-10-02,Rice,3,24\n';
    test('csv: group, compute, sort and chart', () {
      var t = SheetTable.fromCsv(csv);
      expect(t.columns, ['Date', 'Item', 'Qty', 'Price']);
      t = t.compute('Total', 'Qty * Price').group(['Item'], [
        {'column': 'Total', 'fn': 'sum'}
      ]).sort('sum of Total', desc: true);
      expect(t.rows.first, ['Rice', 120.0]);
      expect(t.chart('Item', 'sum of Total'), contains('"type":"bars"'));
    });

    test('pivot with totals and filters', () {
      final t = SheetTable.fromCsv(csv).filter([
        {'column': 'Qty', 'op': '>=', 'value': 2}
      ]).pivot('Item', 'Date', 'Qty');
      expect(t.columns, ['Item', '2026-10-01', '2026-10-02', 'Total']);
      expect(t.rows.last.last, 5);
    });

    test('xlsx written by DocMaker reads back', () {
      final bytes = DocMaker.xlsxBytes('Sales', ['Item', 'Qty'], [
        ['Rice', 2],
        ['Sugar', 5],
      ]);
      final sheets = SheetTable.fromXlsx(bytes);
      final t = sheets.values.first;
      expect(t.columns, ['Item', 'Qty']);
      expect(t.rows[1], ['Sugar', 5]);
    });
  });
}
