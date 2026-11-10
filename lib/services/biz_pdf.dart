import 'dart:io';
import 'dart:ui' show Rect, Offset;

import 'package:syncfusion_flutter_pdf/pdf.dart';

import 'biz_books.dart';
import 'doc_maker.dart';

/// PDFs for the business tools: invoices, quotes, receipts, delivery notes, purchase orders, and reports with charts.
class BizPdf {
  static PdfColor get ink => PdfColor(23, 21, 15);
  static PdfColor get muted => PdfColor(110, 104, 92);
  static PdfColor get red => PdfColor(194, 54, 27);
  static PdfColor get wash => PdfColor(240, 235, 224);
  static PdfColor get line => PdfColor(220, 214, 200);

  static const _titles = {
    'invoice': 'INVOICE',
    'quote': 'QUOTATION',
    'receipt': 'RECEIPT',
    'delivery_note': 'DELIVERY NOTE',
    'purchase_order': 'PURCHASE ORDER',
  };

  /// A business document. [doc] is the stored document map (lines, totals, contact snapshot).
  static Future<List<int>> document(BizBooks bk, Map<String, dynamic> doc) async {
    final (serif, body, bold) = await DocMaker.fonts();
    final pdf = PdfDocument();
    pdf.pageSettings.margins.all = 44;
    final kind = '${doc['kind']}';
    pdf.documentInformation.title = '${_titles[kind] ?? 'Document'} ${doc['no']}';
    pdf.documentInformation.creator = 'Telesia';
    var page = pdf.pages.add();
    final w = page.getClientSize().width;
    final p = bk.profile;
    double y = 0;

    // Logo (optional, a PNG/JPG in the workspace).
    var left = 0.0;
    final logo = '${p['logo_path'] ?? ''}';
    if (logo.isNotEmpty && await File(logo).exists()) {
      try {
        final img = PdfBitmap(await File(logo).readAsBytes());
        page.graphics.drawImage(img, const Rect.fromLTWH(0, 0, 54, 54));
        left = 64;
      } catch (_) {}
    }
    page.graphics.drawString(bk.name.isEmpty ? 'My business' : bk.name, serif(24),
        brush: PdfSolidBrush(ink), bounds: Rect.fromLTWH(left, 0, w * 0.6 - left, 30));
    final info = [p['address'], p['phone'], p['email'], if ('${p['tax_id'] ?? ''}'.isNotEmpty) 'TIN: ${p['tax_id']}']
        .where((e) => '${e ?? ''}'.trim().isNotEmpty)
        .join('\n');
    page.graphics.drawString(info, body(9), brush: PdfSolidBrush(muted), bounds: Rect.fromLTWH(left, 32, w * 0.6 - left, 60));

    final right = PdfStringFormat(alignment: PdfTextAlignment.right);
    page.graphics.drawString(_titles[kind] ?? 'DOCUMENT', bold(17), brush: PdfSolidBrush(red), bounds: Rect.fromLTWH(w * 0.5, 0, w * 0.5, 24), format: right);
    final meta = [
      'No. ${doc['no']}',
      'Date: ${doc['date']}',
      if ('${doc['due'] ?? ''}'.isNotEmpty && kind == 'invoice') 'Due: ${doc['due']}',
      if ('${doc['valid_until'] ?? ''}'.isNotEmpty && kind == 'quote') 'Valid until: ${doc['valid_until']}',
    ].join('\n');
    page.graphics.drawString(meta, body(9.5), brush: PdfSolidBrush(ink), bounds: Rect.fromLTWH(w * 0.5, 26, w * 0.5, 50), format: right);
    y = 96;
    page.graphics.drawLine(PdfPen(red, width: 1.2), Offset(0, y), Offset(56, y));
    y += 12;

    // Who it is for.
    final who = (doc['contact'] as Map?) ?? const {};
    final label = kind == 'receipt' ? 'RECEIVED FROM' : (kind == 'purchase_order' ? 'SUPPLIER' : (kind == 'delivery_note' ? 'DELIVER TO' : 'BILL TO'));
    if ('${who['name'] ?? ''}'.isNotEmpty) {
      page.graphics.drawString(label, bold(8.5), brush: PdfSolidBrush(muted), bounds: Rect.fromLTWH(0, y, w / 2, 12));
      final lines = [who['name'], who['address'], who['phone']].where((e) => '${e ?? ''}'.trim().isNotEmpty).join('\n');
      page.graphics.drawString(lines, body(10.5), brush: PdfSolidBrush(ink), bounds: Rect.fromLTWH(0, y + 13, w / 2, 48));
      y += 66;
    }

    final cur = bk.currency;
    final ls = BizBooks.maps(doc['lines']);
    if (ls.isNotEmpty) {
      final grid = PdfGrid();
      final showPrice = kind != 'delivery_note';
      grid.columns.add(count: showPrice ? 5 : 3);
      grid.headers.add(1);
      final h = grid.headers[0];
      final heads = showPrice ? ['#', 'Description', 'Qty', 'Unit price', 'Amount ($cur)'] : ['#', 'Description', 'Qty'];
      for (var i = 0; i < heads.length; i++) {
        h.cells[i].value = heads[i];
      }
      h.style = PdfGridRowStyle(font: bold(9.5), textBrush: PdfSolidBrush(ink), backgroundBrush: PdfSolidBrush(wash));
      var n = 0;
      for (final l in ls) {
        final r = grid.rows.add();
        n++;
        r.cells[0].value = '$n';
        r.cells[1].value = '${l['name']}${'${l['note'] ?? ''}'.isEmpty ? '' : '\n${l['note']}'}';
        r.cells[2].value = BizBooks.money(BizBooks.d(l['qty']));
        if (showPrice) {
          r.cells[3].value = BizBooks.money(BizBooks.d(l['price']));
          r.cells[4].value = BizBooks.money(BizBooks.d(l['qty']) * BizBooks.d(l['price']));
        }
        r.style = PdfGridRowStyle(font: body(9.5), textBrush: PdfSolidBrush(ink));
      }
      grid.columns[0].width = 24;
      grid.columns[2].width = 48;
      if (showPrice) {
        grid.columns[3].width = 80;
        grid.columns[4].width = 92;
        for (final c in [2, 3, 4]) {
          grid.columns[c].format = PdfStringFormat(alignment: PdfTextAlignment.right);
        }
      }
      grid.style = PdfGridStyle(cellPadding: PdfPaddings(left: 6, right: 6, top: 5, bottom: 5));
      final res = grid.draw(page: page, bounds: Rect.fromLTWH(0, y, w, 0));
      if (res != null) {
        page = res.page;
        y = res.bounds.bottom + 10;
      }
    }

    // Totals.
    if (kind != 'delivery_note') {
      final rows = <(String, String, bool)>[];
      if (kind == 'receipt') {
        rows.add(('Amount received', bk.m(BizBooks.d(doc['paid'])), true));
        if ('${doc['method'] ?? ''}'.isNotEmpty) rows.add(('Paid by', '${doc['method']}', false));
        if (doc['balance'] != null) rows.add(('Balance still owed', bk.m(BizBooks.d(doc['balance'])), false));
      } else {
        rows.add(('Subtotal', bk.m(BizBooks.d(doc['subtotal'])), false));
        if (BizBooks.d(doc['discount']) > 0) rows.add(('Discount', '-${bk.m(BizBooks.d(doc['discount']))}', false));
        if (BizBooks.d(doc['tax']) > 0) {
          rows.add(('${p['tax_label'] ?? 'Tax'} (${BizBooks.money(BizBooks.d(doc['tax_rate']))}%)', bk.m(BizBooks.d(doc['tax'])), false));
        }
        rows.add(('Total', bk.m(BizBooks.d(doc['total'])), true));
        if (kind == 'invoice' && BizBooks.d(doc['paid']) > 0) {
          rows.add(('Paid', bk.m(BizBooks.d(doc['paid'])), false));
          rows.add(('Balance due', bk.m(BizBooks.d(doc['total']) - BizBooks.d(doc['paid'])), true));
        }
      }
      if (y + rows.length * 18 + 20 > page.getClientSize().height) {
        page = pdf.pages.add();
        y = 0;
      }
      for (final r in rows) {
        page.graphics.drawString(r.$1, r.$3 ? bold(11) : body(10), brush: PdfSolidBrush(r.$3 ? ink : muted), bounds: Rect.fromLTWH(w - 300, y, 160, 16));
        page.graphics.drawString(r.$2, r.$3 ? bold(11) : body(10), brush: PdfSolidBrush(ink), bounds: Rect.fromLTWH(w - 140, y, 140, 16), format: right);
        y += 18;
      }
      if (kind == 'invoice' || kind == 'receipt') {
        final paidUp = kind == 'invoice' && BizBooks.d(doc['total']) > 0 && BizBooks.d(doc['paid']) >= BizBooks.d(doc['total']) - 0.005;
        if (paidUp) {
          page.graphics.drawString('PAID', bold(22), brush: PdfSolidBrush(PdfColor(46, 125, 50)), bounds: Rect.fromLTWH(0, y - 44, 120, 30));
        }
      }
      y += 8;
    }

    // Notes, payment details, signature line.
    final notes = [
      if ('${doc['note'] ?? ''}'.isNotEmpty) '${doc['note']}',
      if (kind == 'invoice' && '${p['payment_info'] ?? ''}'.isNotEmpty) 'How to pay: ${p['payment_info']}',
      if ('${p['invoice_note'] ?? ''}'.isNotEmpty && kind != 'purchase_order') '${p['invoice_note']}',
    ];
    for (final t in notes) {
      final r = PdfTextElement(text: t, font: body(9.5), brush: PdfSolidBrush(muted))
          .draw(page: page, bounds: Rect.fromLTWH(0, y, w, 0), format: PdfLayoutFormat(layoutType: PdfLayoutType.paginate));
      if (r != null) {
        page = r.page;
        y = r.bounds.bottom + 6;
      }
    }
    if (kind == 'delivery_note' || kind == 'receipt' || kind == 'purchase_order') {
      if (y + 60 > page.getClientSize().height) {
        page = pdf.pages.add();
        y = 0;
      }
      y += 30;
      page.graphics.drawLine(PdfPen(line, width: 0.8), Offset(0, y), Offset(180, y));
      page.graphics.drawString(kind == 'delivery_note' ? 'Received by (name and signature)' : 'Signature', body(8.5),
          brush: PdfSolidBrush(muted), bounds: Rect.fromLTWH(0, y + 3, 220, 12));
    }
    final s = page.getClientSize();
    page.graphics.drawString('Thank you for your business.', body(8.5),
        brush: PdfSolidBrush(muted), bounds: Rect.fromLTWH(0, s.height - 12, s.width, 12), format: PdfStringFormat(alignment: PdfTextAlignment.center));
    final bytes = await pdf.save();
    pdf.dispose();
    return bytes;
  }

  /// A report: a title, then sections of text lines, key figures, tables and bar charts.
  static Future<List<int>> report(String title, String subtitle, List<ReportPart> parts) async {
    final (serif, body, bold) = await DocMaker.fonts();
    final pdf = PdfDocument();
    pdf.pageSettings.margins.all = 48;
    pdf.documentInformation.title = title;
    pdf.documentInformation.creator = 'Telesia';
    var page = pdf.pages.add();
    final w = page.getClientSize().width;
    var y = 0.0;
    void ensure(double h) {
      if (y + h > page.getClientSize().height) {
        page = pdf.pages.add();
        y = 0;
      }
    }

    void text(String t, PdfFont f, PdfColor c, {double after = 6}) {
      final r = PdfTextElement(text: t, font: f, brush: PdfSolidBrush(c))
          .draw(page: page, bounds: Rect.fromLTWH(0, y, w, 0), format: PdfLayoutFormat(layoutType: PdfLayoutType.paginate));
      if (r != null) {
        page = r.page;
        y = r.bounds.bottom + after;
      }
    }

    text(title, serif(26), ink, after: 2);
    if (subtitle.isNotEmpty) text(subtitle, body(10.5), muted, after: 4);
    page.graphics.drawLine(PdfPen(red, width: 1.2), Offset(0, y + 4), Offset(56, y + 4));
    y += 18;

    for (final part in parts) {
      switch (part.kind) {
        case 'heading':
          ensure(36);
          y += 6;
          text(part.title, bold(13), ink, after: 6);
          break;
        case 'text':
          ensure(16);
          text(part.title, body(10.5), ink, after: 6);
          break;
        case 'figures':
          // Key numbers in boxes, up to 3 per row.
          final per = 3;
          final bw = (w - (per - 1) * 10) / per;
          for (var i = 0; i < part.rows.length; i += per) {
            ensure(54);
            for (var j = 0; j < per && i + j < part.rows.length; j++) {
              final x = j * (bw + 10);
              final r = part.rows[i + j];
              page.graphics.drawRectangle(brush: PdfSolidBrush(wash), bounds: Rect.fromLTWH(x, y, bw, 46));
              page.graphics.drawString('${r[0]}'.toUpperCase(), bold(7.5), brush: PdfSolidBrush(muted), bounds: Rect.fromLTWH(x + 8, y + 6, bw - 16, 10));
              page.graphics.drawString('${r[1]}', bold(14), brush: PdfSolidBrush(ink), bounds: Rect.fromLTWH(x + 8, y + 19, bw - 16, 20));
            }
            y += 54;
          }
          y += 4;
          break;
        case 'table':
          if (part.rows.isEmpty) break;
          ensure(40);
          if (part.title.isNotEmpty) text(part.title, bold(10.5), ink, after: 4);
          final grid = PdfGrid();
          final n = part.columns.length;
          grid.columns.add(count: n);
          grid.headers.add(1);
          for (var i = 0; i < n; i++) {
            grid.headers[0].cells[i].value = part.columns[i];
          }
          grid.headers[0].style = PdfGridRowStyle(font: bold(9), textBrush: PdfSolidBrush(ink), backgroundBrush: PdfSolidBrush(wash));
          for (final r in part.rows) {
            final row = grid.rows.add();
            for (var i = 0; i < n; i++) {
              row.cells[i].value = i < r.length ? '${r[i] ?? ''}' : '';
            }
            row.style = PdfGridRowStyle(font: body(9), textBrush: PdfSolidBrush(ink));
          }
          grid.style = PdfGridStyle(cellPadding: PdfPaddings(left: 5, right: 5, top: 4, bottom: 4));
          final res = grid.draw(page: page, bounds: Rect.fromLTWH(0, y, w, 0));
          if (res != null) {
            page = res.page;
            y = res.bounds.bottom + 12;
          }
          break;
        case 'bars':
          final data = part.data;
          if (data.isEmpty) break;
          final rowH = 18.0;
          ensure(30 + rowH * data.length.clamp(1, 6));
          if (part.title.isNotEmpty) text(part.title, bold(10.5), ink, after: 6);
          final maxV = data.map((e) => e.value.abs()).fold<double>(0, (a, b) => b > a ? b : a);
          final labelW = w * 0.32, valueW = 80.0, barW = w - labelW - valueW - 12;
          for (final e in data) {
            ensure(rowH);
            page.graphics.drawString(e.key, body(9), brush: PdfSolidBrush(ink), bounds: Rect.fromLTWH(0, y + 2, labelW - 6, 12));
            final bw = maxV == 0 ? 0.0 : barW * e.value.abs() / maxV;
            page.graphics.drawRectangle(brush: PdfSolidBrush(e.value < 0 ? muted : red), bounds: Rect.fromLTWH(labelW, y + 3, bw < 1 ? 1 : bw, 10));
            page.graphics.drawString(BizBooks.money(e.value), body(9),
                brush: PdfSolidBrush(ink), bounds: Rect.fromLTWH(w - valueW, y + 2, valueW, 12), format: PdfStringFormat(alignment: PdfTextAlignment.right));
            y += rowH;
          }
          y += 10;
          break;
        case 'columns':
          final data = part.data;
          if (data.isEmpty) break;
          ensure(190);
          if (part.title.isNotEmpty) text(part.title, bold(10.5), ink, after: 6);
          const h = 140.0;
          final maxV = data.map((e) => e.value).fold<double>(0, (a, b) => b > a ? b : a);
          final n = data.length;
          final slot = w / n;
          final cw = (slot * 0.62).clamp(2.0, 40.0);
          page.graphics.drawLine(PdfPen(line, width: 0.6), Offset(0, y + h), Offset(w, y + h));
          final every = (n / 8).ceil().clamp(1, 1000);
          for (var i = 0; i < n; i++) {
            final v = data[i].value;
            final bh = maxV <= 0 ? 0.0 : h * v.clamp(0, double.infinity) / maxV;
            final x = i * slot + (slot - cw) / 2;
            page.graphics.drawRectangle(brush: PdfSolidBrush(red), bounds: Rect.fromLTWH(x, y + h - bh, cw, bh));
            if (i % every == 0) {
              final lb = data[i].key.length > 10 ? data[i].key.substring(data[i].key.length - 5) : data[i].key;
              page.graphics.drawString(lb, body(7), brush: PdfSolidBrush(muted), bounds: Rect.fromLTWH(i * slot - 10, y + h + 3, slot + 20, 10),
                  format: PdfStringFormat(alignment: PdfTextAlignment.center));
            }
          }
          page.graphics.drawString('max ${BizBooks.money(maxV)}', body(7.5), brush: PdfSolidBrush(muted), bounds: Rect.fromLTWH(0, y - 2, 120, 10));
          y += h + 22;
          break;
      }
    }
    for (var i = 0; i < pdf.pages.count; i++) {
      final pg = pdf.pages[i];
      final s = pg.getClientSize();
      pg.graphics.drawString('${i + 1} / ${pdf.pages.count}', body(8),
          brush: PdfSolidBrush(muted), bounds: Rect.fromLTWH(0, s.height - 4, s.width, 12), format: PdfStringFormat(alignment: PdfTextAlignment.right));
    }
    final bytes = await pdf.save();
    pdf.dispose();
    return bytes;
  }
}

/// One part of a PDF report.
class ReportPart {
  ReportPart.heading(this.title)
      : kind = 'heading',
        columns = const [],
        rows = const [],
        data = const [];
  ReportPart.text(this.title)
      : kind = 'text',
        columns = const [],
        rows = const [],
        data = const [];
  ReportPart.figures(this.rows)
      : kind = 'figures',
        title = '',
        columns = const [],
        data = const [];
  ReportPart.table(this.title, this.columns, this.rows)
      : kind = 'table',
        data = const [];
  ReportPart.bars(this.title, this.data)
      : kind = 'bars',
        columns = const [],
        rows = const [];
  ReportPart.columnsChart(this.title, this.data)
      : kind = 'columns',
        columns = const [],
        rows = const [];

  final String kind;
  final String title;
  final List<String> columns;
  final List<List<dynamic>> rows;
  final List<MapEntry<String, double>> data;
}
