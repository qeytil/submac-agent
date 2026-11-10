import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Rect, Offset, Size;

import 'package:archive/archive.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:syncfusion_flutter_pdf/pdf.dart';

import 'tools.dart';

/// Makes real files people can send: PDF, Word (.docx), Excel (.xlsx), CSV and slide decks (landscape PDF).
/// Written in the Telesia look: serif headings, calm body text, a thin red rule.
class DocMaker {
  static const names = {'make_document', 'images_to_pdf'};

  static final List<Map<String, dynamic>> definitions = [
    {
      'type': 'function',
      'function': {
        'name': 'make_document',
        'description': 'Create a real, nicely formatted file: a PDF, Word document, Excel spreadsheet, CSV, or a slide deck '
            '(landscape PDF). Only when the user asks for a file or document (a CV, invoice, sheet, slides, "as a PDF"...). '
            'Otherwise write the answer in the chat, however long: never a file instead of an answer. '
            'Show the result with a ```file card holding the returned path.',
        'parameters': {
          'type': 'object',
          'properties': {
            'kind': {
              'type': 'string',
              'enum': ['pdf', 'docx', 'xlsx', 'csv', 'slides'],
              'description': 'pdf or docx for documents, xlsx or csv for sheets, slides for a presentation.'
            },
            'title': {'type': 'string', 'description': 'Document title, also used for the file name.'},
            'content': {
              'type': 'string',
              'description': 'For pdf, docx and slides: the body in simple markdown (# heading, ## subheading, '
                  'paragraphs, - bullets, 1. numbered, | tables |). For slides, each "# " heading starts a new slide.'
            },
            'columns': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': 'For xlsx or csv: the header row.'
            },
            'rows': {
              'type': 'array',
              'items': {'type': 'array', 'items': {}},
              'description': 'For xlsx or csv: the data rows. Numbers stay numbers so totals work in Excel.'
            },
            'subtitle': {'type': 'string', 'description': 'Optional line under the title (date, company, name).'},
          },
          'required': ['kind', 'title'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'images_to_pdf',
        'description': 'Turn one or more photos (scanned pages, receipts, ID copies) into a single PDF, one page per photo.',
        'parameters': {
          'type': 'object',
          'properties': {
            'paths': {'type': 'array', 'items': {'type': 'string'}},
            'title': {'type': 'string'},
          },
          'required': ['paths'],
        },
      },
    },
  ];

  static Future<String> execute(String name, Map<String, dynamic> a) async {
    try {
      final ws = await AgentTools.workspaceDir();
      final dir = Directory('$ws/Documents');
      await dir.create(recursive: true);
      final title = (a['title'] ?? 'Document').toString().trim();
      final base = _fileName(title.isEmpty ? 'Document' : title);
      if (name == 'images_to_pdf') {
        final paths = [for (final p in (a['paths'] as List? ?? const [])) p.toString()];
        if (paths.isEmpty) return 'Error: give at least one photo path.';
        final f = File(await _unique(dir.path, base, 'pdf'));
        await f.writeAsBytes(await _imagesPdf(ws, paths));
        return 'FILE_SAVED ${f.path}\nA ${paths.length}-page PDF. Show it with a ```file card.';
      }
      final kind = (a['kind'] ?? 'pdf').toString().toLowerCase();
      final content = (a['content'] ?? '').toString();
      final subtitle = (a['subtitle'] ?? '').toString();
      final cols = [for (final c in (a['columns'] as List? ?? const [])) c?.toString() ?? ''];
      final rows = [
        for (final r in (a['rows'] as List? ?? const []))
          if (r is List) [for (final c in r) c] else if (r is Map) [for (final v in r.values) v]
      ];
      late File f;
      switch (kind) {
        case 'docx':
        case 'word':
          f = File(await _unique(dir.path, base, 'docx'));
          await f.writeAsBytes(_docx(title, subtitle, _parse(content)));
          break;
        case 'xlsx':
        case 'excel':
          final t = _tableFrom(cols, rows, content);
          f = File(await _unique(dir.path, base, 'xlsx'));
          await f.writeAsBytes(_xlsx(title, t.$1, t.$2));
          break;
        case 'csv':
          final t = _tableFrom(cols, rows, content);
          f = File(await _unique(dir.path, base, 'csv'));
          await f.writeAsString([
            if (t.$1.isNotEmpty) t.$1.map(_csvCell).join(','),
            for (final r in t.$2) r.map((c) => _csvCell('${c ?? ''}')).join(','),
          ].join('\r\n'));
          break;
        case 'slides':
          f = File(await _unique(dir.path, base, 'pdf'));
          await f.writeAsBytes(await _slides(title, subtitle, content));
          break;
        default:
          f = File(await _unique(dir.path, base, 'pdf'));
          await f.writeAsBytes(await _pdf(title, subtitle, _parse(content)));
      }
      return 'FILE_SAVED ${f.path}\nShow it with a ```file card. Do not print the path in text.';
    } catch (e) {
      return 'Error: could not make the file: $e';
    }
  }

  // ---------------------------------------------------------------- shared

  /// For other makers (business documents, data sheets): the same fonts, names and Excel writer.
  static Future<(PdfFont Function(double), PdfFont Function(double), PdfFont Function(double))> fonts() => _fonts();
  static String fileName(String t) => _fileName(t);
  static Future<String> uniquePath(String dir, String base, String ext) => _unique(dir, base, ext);
  static List<int> xlsxBytes(String title, List<String> cols, List<List<dynamic>> rows) => _xlsx(title, cols, rows);
  static String csvText(List<String> cols, List<List<dynamic>> rows) => [
        if (cols.isNotEmpty) cols.map(_csvCell).join(','),
        for (final r in rows) r.map((c) => _csvCell('${c ?? ''}')).join(','),
      ].join('\r\n');


  static String _fileName(String t) {
    final s = t.replaceAll(RegExp(r'[^\w\- ]+', unicode: true), '').trim().replaceAll(RegExp(r'\s+'), ' ');
    return s.isEmpty ? 'Document' : (s.length > 60 ? s.substring(0, 60) : s);
  }

  static Future<String> _unique(String dir, String base, String ext) async {
    var p = '$dir/$base.$ext';
    var i = 2;
    while (await File(p).exists()) {
      p = '$dir/$base ($i).$ext';
      i++;
    }
    return p;
  }

  static String _csvCell(String s) =>
      s.contains(RegExp(r'[",\n\r]')) ? '"${s.replaceAll('"', '""')}"' : s;

  static String _clean(String s) => s.replaceAll('**', '').replaceAll('__', '').replaceAll('`', '');

  /// Simple markdown blocks.
  static List<_Block> _parse(String md) {
    final out = <_Block>[];
    final para = <String>[];
    List<List<String>>? table;
    void flushPara() {
      if (para.isNotEmpty) out.add(_Block('p', _clean(para.join(' '))));
      para.clear();
    }

    void flushTable() {
      if (table != null && table!.isNotEmpty) out.add(_Block('table', '', table));
      table = null;
    }

    for (final raw in md.replaceAll('\r', '').split('\n')) {
      final l = raw.trim();
      if (l.startsWith('|')) {
        flushPara();
        final cells = l.replaceAll(RegExp(r'^\||\|$'), '').split('|').map((c) => _clean(c.trim())).toList();
        if (cells.every((c) => RegExp(r'^:?-{2,}:?$').hasMatch(c))) continue;
        (table ??= []).add(cells);
        continue;
      }
      flushTable();
      if (l.isEmpty) {
        flushPara();
        continue;
      }
      final h = RegExp(r'^(#{1,3})\s+(.*)$').firstMatch(l);
      if (h != null) {
        flushPara();
        out.add(_Block('h${h.group(1)!.length}', _clean(h.group(2)!)));
        continue;
      }
      final b = RegExp(r'^([-*•])\s+(.*)$').firstMatch(l);
      if (b != null) {
        flushPara();
        out.add(_Block('li', _clean(b.group(2)!)));
        continue;
      }
      final n = RegExp(r'^(\d+)[.)]\s+(.*)$').firstMatch(l);
      if (n != null) {
        flushPara();
        out.add(_Block('ol', _clean(n.group(2)!), null, n.group(1)));
        continue;
      }
      if (RegExp(r'^(-{3,}|\*{3,})$').hasMatch(l)) {
        flushPara();
        out.add(_Block('hr', ''));
        continue;
      }
      para.add(l);
    }
    flushPara();
    flushTable();
    return out;
  }

  static (List<String>, List<List<dynamic>>) _tableFrom(List<String> cols, List<List<dynamic>> rows, String content) {
    if (cols.isNotEmpty || rows.isNotEmpty) return (cols, rows);
    for (final b in _parse(content)) {
      if (b.kind == 'table' && b.rows!.isNotEmpty) {
        return (b.rows!.first, [for (final r in b.rows!.skip(1)) r.map(_num).toList()]);
      }
    }
    return (const [], const []);
  }

  static dynamic _num(String s) {
    final t = s.replaceAll(',', '').trim();
    return num.tryParse(t) ?? s;
  }

  // ---------------------------------------------------------------- PDF

  static PdfColor get _ink => PdfColor(23, 21, 15);
  static PdfColor get _muted => PdfColor(110, 104, 92);
  static PdfColor get _red => PdfColor(194, 54, 27);

  static Future<(PdfFont Function(double), PdfFont Function(double), PdfFont Function(double))> _fonts() async {
    try {
      final serif = (await rootBundle.load('assets/fonts/InstrumentSerif-Regular.ttf')).buffer.asUint8List();
      final body = (await rootBundle.load('assets/fonts/Geist-Regular.ttf')).buffer.asUint8List();
      final bold = (await rootBundle.load('assets/fonts/Geist-SemiBold.ttf')).buffer.asUint8List();
      return (
        (double s) => PdfTrueTypeFont(serif, s) as PdfFont,
        (double s) => PdfTrueTypeFont(body, s) as PdfFont,
        (double s) => PdfTrueTypeFont(bold, s) as PdfFont,
      );
    } catch (_) {
      return (
        (double s) => PdfStandardFont(PdfFontFamily.timesRoman, s) as PdfFont,
        (double s) => PdfStandardFont(PdfFontFamily.helvetica, s) as PdfFont,
        (double s) => PdfStandardFont(PdfFontFamily.helvetica, s, style: PdfFontStyle.bold) as PdfFont,
      );
    }
  }

  static Future<List<int>> _pdf(String title, String subtitle, List<_Block> blocks) async {
    final (serif, body, bold) = await _fonts();
    final doc = PdfDocument();
    doc.pageSettings.margins.all = 54;
    doc.documentInformation.title = title;
    doc.documentInformation.creator = 'Telesia';
    var page = doc.pages.add();
    final w = page.getClientSize().width;
    var y = 0.0;

    PdfLayoutResult? draw(String text, PdfFont font, PdfColor color, {double indent = 0, double after = 6}) {
      final r = PdfTextElement(text: text, font: font, brush: PdfSolidBrush(color)).draw(
        page: page,
        bounds: Rect.fromLTWH(indent, y, w - indent, 0),
        format: PdfLayoutFormat(layoutType: PdfLayoutType.paginate),
      );
      if (r != null) {
        page = r.page;
        y = r.bounds.bottom + after;
      }
      return r;
    }

    void ensure(double h) {
      if (y + h > page.getClientSize().height) {
        page = doc.pages.add();
        y = 0;
      }
    }

    draw(title, serif(30), _ink, after: 4);
    if (subtitle.isNotEmpty) draw(subtitle, body(11), _muted, after: 4);
    page.graphics.drawLine(PdfPen(_red, width: 1.2), Offset(0, y + 4), Offset(56, y + 4));
    y += 20;

    for (final b in blocks) {
      switch (b.kind) {
        case 'h1':
          ensure(40);
          y += 8;
          draw(b.text, serif(22), _ink, after: 6);
          break;
        case 'h2':
          ensure(34);
          y += 6;
          draw(b.text, bold(13.5), _ink, after: 5);
          break;
        case 'h3':
          ensure(28);
          y += 4;
          draw(b.text.toUpperCase(), bold(10), _muted, after: 4);
          break;
        case 'li':
        case 'ol':
          ensure(18);
          final mark = b.kind == 'li' ? '•' : '${b.num}.';
          page.graphics.drawString(mark, body(11), brush: PdfSolidBrush(b.kind == 'li' ? _red : _muted), bounds: Rect.fromLTWH(6, y, 20, 16));
          draw(b.text, body(11), _ink, indent: 22, after: 4);
          break;
        case 'hr':
          ensure(16);
          page.graphics.drawLine(PdfPen(PdfColor(220, 214, 200), width: 0.6), Offset(0, y + 6), Offset(w, y + 6));
          y += 16;
          break;
        case 'table':
          ensure(40);
          final grid = PdfGrid();
          final n = b.rows!.map((r) => r.length).fold<int>(0, (a, c) => c > a ? c : a);
          grid.columns.add(count: n);
          grid.headers.add(1);
          final head = grid.headers[0];
          for (var i = 0; i < n; i++) {
            head.cells[i].value = i < b.rows!.first.length ? b.rows!.first[i] : '';
          }
          head.style = PdfGridRowStyle(font: bold(10), textBrush: PdfSolidBrush(_ink), backgroundBrush: PdfSolidBrush(PdfColor(240, 235, 224)));
          for (final r in b.rows!.skip(1)) {
            final row = grid.rows.add();
            for (var i = 0; i < n; i++) {
              row.cells[i].value = i < r.length ? r[i] : '';
            }
            row.style = PdfGridRowStyle(font: body(10), textBrush: PdfSolidBrush(_ink));
          }
          grid.style = PdfGridStyle(cellPadding: PdfPaddings(left: 6, right: 6, top: 5, bottom: 5));
          final r = grid.draw(page: page, bounds: Rect.fromLTWH(0, y, w, 0));
          if (r != null) {
            page = r.page;
            y = r.bounds.bottom + 12;
          }
          break;
        default:
          ensure(18);
          draw(b.text, body(11), _ink, after: 9);
      }
    }
    // Quiet footer with page numbers.
    for (var i = 0; i < doc.pages.count; i++) {
      final p = doc.pages[i];
      final s = p.getClientSize();
      p.graphics.drawString('${i + 1} / ${doc.pages.count}', body(8.5),
          brush: PdfSolidBrush(_muted), bounds: Rect.fromLTWH(0, s.height - 4, s.width, 12),
          format: PdfStringFormat(alignment: PdfTextAlignment.right));
    }
    final bytes = await doc.save();
    doc.dispose();
    return bytes;
  }

  static Future<List<int>> _slides(String title, String subtitle, String md) async {
    final (serif, body, bold) = await _fonts();
    final doc = PdfDocument();
    doc.pageSettings.size = const Size(960, 540);
    doc.pageSettings.margins.all = 0;
    doc.documentInformation.title = title;
    final paper = PdfSolidBrush(PdfColor(244, 240, 231));

    // Split into slides on "# ".
    final slides = <(String, List<_Block>)>[];
    String? head;
    var buf = <String>[];
    for (final l in md.replaceAll('\r', '').split('\n')) {
      final m = RegExp(r'^#\s+(.*)$').firstMatch(l.trim());
      if (m != null) {
        if (head != null || buf.any((x) => x.trim().isNotEmpty)) slides.add((head ?? '', _parse(buf.join('\n'))));
        head = _clean(m.group(1)!);
        buf = [];
      } else {
        buf.add(l);
      }
    }
    if (head != null || buf.any((x) => x.trim().isNotEmpty)) slides.add((head ?? '', _parse(buf.join('\n'))));

    // Cover.
    var page = doc.pages.add();
    page.graphics.drawRectangle(brush: paper, bounds: const Rect.fromLTWH(0, 0, 960, 540));
    page.graphics.drawEllipse(const Rect.fromLTWH(72, 150, 16, 16), brush: PdfSolidBrush(_red));
    PdfTextElement(text: title, font: serif(54), brush: PdfSolidBrush(_ink))
        .draw(page: page, bounds: const Rect.fromLTWH(72, 190, 816, 200));
    if (subtitle.isNotEmpty) {
      page.graphics.drawString(subtitle, body(18), brush: PdfSolidBrush(_muted), bounds: const Rect.fromLTWH(72, 420, 816, 30));
    }

    var n = 1;
    for (final (h, blocks) in slides) {
      n++;
      page = doc.pages.add();
      page.graphics.drawRectangle(brush: paper, bounds: const Rect.fromLTWH(0, 0, 960, 540));
      page.graphics.drawLine(PdfPen(_red, width: 2), const Offset(72, 66), const Offset(120, 66));
      PdfTextElement(text: h, font: serif(38), brush: PdfSolidBrush(_ink)).draw(page: page, bounds: const Rect.fromLTWH(72, 80, 816, 100));
      var y = 160.0;
      for (final b in blocks) {
        if (y > 480) break;
        if (b.kind == 'li' || b.kind == 'ol') {
          page.graphics.drawEllipse(Rect.fromLTWH(76, y + 9, 7, 7), brush: PdfSolidBrush(_red));
          final r = PdfTextElement(text: b.text, font: body(20), brush: PdfSolidBrush(_ink))
              .draw(page: page, bounds: Rect.fromLTWH(100, y, 788, 0));
          y = (r?.bounds.bottom ?? y + 26) + 12;
        } else if (b.kind == 'table') {
          final grid = PdfGrid();
          final cols = b.rows!.map((r) => r.length).fold<int>(0, (a, c) => c > a ? c : a);
          grid.columns.add(count: cols);
          for (final r in b.rows!) {
            final row = grid.rows.add();
            for (var i = 0; i < cols; i++) {
              row.cells[i].value = i < r.length ? r[i] : '';
            }
            row.style = PdfGridRowStyle(font: body(15), textBrush: PdfSolidBrush(_ink));
          }
          grid.rows[0].style = PdfGridRowStyle(font: bold(15), textBrush: PdfSolidBrush(_ink));
          grid.style = PdfGridStyle(cellPadding: PdfPaddings(left: 8, right: 8, top: 6, bottom: 6));
          final r = grid.draw(page: page, bounds: Rect.fromLTWH(72, y, 816, 0));
          y = (r?.bounds.bottom ?? y) + 12;
        } else if (b.kind.startsWith('h')) {
          final r = PdfTextElement(text: b.text, font: bold(20), brush: PdfSolidBrush(_ink))
              .draw(page: page, bounds: Rect.fromLTWH(72, y, 816, 0));
          y = (r?.bounds.bottom ?? y + 26) + 10;
        } else if (b.kind == 'p') {
          final r = PdfTextElement(text: b.text, font: body(20), brush: PdfSolidBrush(_muted))
              .draw(page: page, bounds: Rect.fromLTWH(72, y, 816, 0));
          y = (r?.bounds.bottom ?? y + 26) + 14;
        }
      }
      page.graphics.drawString('$n', body(11), brush: PdfSolidBrush(_muted), bounds: const Rect.fromLTWH(860, 500, 28, 16),
          format: PdfStringFormat(alignment: PdfTextAlignment.right));
    }
    final bytes = await doc.save();
    doc.dispose();
    return bytes;
  }

  static Future<List<int>> _imagesPdf(String ws, List<String> paths) async {
    final doc = PdfDocument();
    doc.pageSettings.margins.all = 0;
    for (var p in paths) {
      if (!p.startsWith('/')) p = '$ws/$p';
      final f = File(p);
      if (!await f.exists()) continue;
      final img = PdfBitmap(await f.readAsBytes());
      final page = doc.pages.add();
      final s = page.getClientSize();
      final scale = (s.width / img.width) < (s.height / img.height) ? s.width / img.width : s.height / img.height;
      final w = img.width * scale, h = img.height * scale;
      page.graphics.drawImage(img, Rect.fromLTWH((s.width - w) / 2, (s.height - h) / 2, w, h));
    }
    if (doc.pages.count == 0) {
      doc.dispose();
      throw 'none of those photos were found';
    }
    final bytes = await doc.save();
    doc.dispose();
    return bytes;
  }

  // ---------------------------------------------------------------- Word

  static String _x(String s) =>
      s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

  static String _run(String t, {bool b = false, int size = 22, String color = '17150F', String font = 'Calibri'}) =>
      '<w:r><w:rPr><w:rFonts w:ascii="$font" w:hAnsi="$font" w:cs="$font"/>${b ? '<w:b/>' : ''}'
      '<w:color w:val="$color"/><w:sz w:val="$size"/></w:rPr><w:t xml:space="preserve">${_x(t)}</w:t></w:r>';

  static String _par(String runs, {int after = 120, int indent = 0}) =>
      '<w:p><w:pPr><w:spacing w:after="$after"/>${indent > 0 ? '<w:ind w:left="$indent" w:hanging="260"/>' : ''}</w:pPr>$runs</w:p>';

  static List<int> _docx(String title, String subtitle, List<_Block> blocks) {
    final body = StringBuffer()
      ..write(_par(_run(title, size: 52, font: 'Georgia'), after: 60));
    if (subtitle.isNotEmpty) body.write(_par(_run(subtitle, size: 20, color: '6E685C'), after: 60));
    body.write('<w:p><w:pPr><w:pBdr><w:bottom w:val="single" w:sz="8" w:space="4" w:color="C2361B"/></w:pBdr>'
        '<w:spacing w:after="240"/></w:pPr></w:p>');
    for (final b in blocks) {
      switch (b.kind) {
        case 'h1':
          body.write(_par(_run(b.text, size: 36, font: 'Georgia'), after: 120));
          break;
        case 'h2':
          body.write(_par(_run(b.text, b: true, size: 26), after: 100));
          break;
        case 'h3':
          body.write(_par(_run(b.text.toUpperCase(), b: true, size: 19, color: '6E685C'), after: 80));
          break;
        case 'li':
          body.write(_par('${_run('•\t', color: 'C2361B')}${_run(b.text)}', after: 60, indent: 360));
          break;
        case 'ol':
          body.write(_par('${_run('${b.num}.\t', color: '6E685C')}${_run(b.text)}', after: 60, indent: 360));
          break;
        case 'hr':
          body.write('<w:p><w:pPr><w:pBdr><w:bottom w:val="single" w:sz="4" w:space="4" w:color="DCD6C8"/></w:pBdr></w:pPr></w:p>');
          break;
        case 'table':
          body.write('<w:tbl><w:tblPr><w:tblW w:w="5000" w:type="pct"/><w:tblBorders>'
              '<w:top w:val="single" w:sz="4" w:color="DCD6C8"/><w:bottom w:val="single" w:sz="4" w:color="DCD6C8"/>'
              '<w:insideH w:val="single" w:sz="4" w:color="DCD6C8"/></w:tblBorders>'
              '<w:tblCellMar><w:left w:w="100" w:type="dxa"/><w:right w:w="100" w:type="dxa"/></w:tblCellMar></w:tblPr>');
          var first = true;
          for (final r in b.rows!) {
            body.write('<w:tr>');
            for (final c in r) {
              body.write('<w:tc><w:tcPr>${first ? '<w:shd w:val="clear" w:color="auto" w:fill="F0EBE0"/>' : ''}</w:tcPr>'
                  '${_par(_run(c, b: first, size: 20), after: 40)}</w:tc>');
            }
            body.write('</w:tr>');
            first = false;
          }
          body.write('</w:tbl>${_par('', after: 120)}');
          break;
        default:
          body.write(_par(_run(b.text), after: 160));
      }
    }
    final docXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>$body'
        '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1200" w:right="1200" w:bottom="1200" w:left="1200" '
        'w:header="600" w:footer="600" w:gutter="0"/></w:sectPr></w:body></w:document>';
    final a = Archive();
    void add(String n, String s) {
      final bytes = utf8.encode(s);
      a.addFile(ArchiveFile(n, bytes.length, bytes));
    }

    add('[Content_Types].xml',
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>');
    add('_rels/.rels',
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>');
    add('word/document.xml', docXml);
    return ZipEncoder().encode(a);
  }

  // ---------------------------------------------------------------- Excel

  static String _col(int i) {
    var s = '';
    i++;
    while (i > 0) {
      final m = (i - 1) % 26;
      s = String.fromCharCode(65 + m) + s;
      i = (i - 1) ~/ 26;
    }
    return s;
  }

  static List<int> _xlsx(String title, List<String> cols, List<List<dynamic>> rows) {
    final sheet = StringBuffer();
    var r = 0;
    String cell(int c, dynamic v, {bool head = false}) {
      final ref = '${_col(c)}${r + 1}';
      if (v is num && !head) return '<c r="$ref"><v>$v</v></c>';
      final s = v?.toString() ?? '';
      if (!head && s.startsWith('=')) return '<c r="$ref"><f>${_x(s.substring(1))}</f></c>';
      final n = num.tryParse(s.replaceAll(',', ''));
      if (!head && n != null && s.trim().isNotEmpty) return '<c r="$ref"><v>$n</v></c>';
      return '<c r="$ref" t="inlineStr"${head ? ' s="1"' : ''}><is><t xml:space="preserve">${_x(s)}</t></is></c>';
    }

    final n = [cols.length, ...rows.map((e) => e.length)].fold<int>(0, (a, c) => c > a ? c : a);
    if (cols.isNotEmpty) {
      sheet.write('<row r="1">${[for (var i = 0; i < cols.length; i++) cell(i, cols[i], head: true)].join()}</row>');
      r++;
    }
    for (final row in rows) {
      sheet.write('<row r="${r + 1}">${[for (var i = 0; i < row.length; i++) cell(i, row[i])].join()}</row>');
      r++;
    }
    final widths = [
      for (var i = 0; i < n; i++)
        [if (i < cols.length) cols[i].length, for (final row in rows) if (i < row.length) '${row[i] ?? ''}'.length]
            .fold<int>(8, (a, c) => c > a ? c : a)
            .clamp(8, 48)
    ];
    final colsXml = n == 0
        ? ''
        : '<cols>${[for (var i = 0; i < n; i++) '<col min="${i + 1}" max="${i + 1}" width="${widths[i] + 2}" customWidth="1"/>'].join()}</cols>';
    final sheetName = _x(title.length > 31 ? title.substring(0, 31) : (title.isEmpty ? 'Sheet1' : title))
        .replaceAll(RegExp(r'[\\/?*\[\]:]'), ' ');
    final a = Archive();
    void add(String nm, String s) {
      final bytes = utf8.encode(s);
      a.addFile(ArchiveFile(nm, bytes.length, bytes));
    }

    const head = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>';
    add('[Content_Types].xml',
        '$head<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
        '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
        '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>');
    add('_rels/.rels',
        '$head<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>');
    add('xl/workbook.xml',
        '$head<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
        '<sheets><sheet name="$sheetName" sheetId="1" r:id="rId1"/></sheets></workbook>');
    add('xl/_rels/workbook.xml.rels',
        '$head<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>'
        '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>');
    add('xl/styles.xml',
        '$head<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        '<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>'
        '<fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill>'
        '<fill><patternFill patternType="solid"><fgColor rgb="FFF0EBE0"/><bgColor indexed="64"/></patternFill></fill></fills>'
        '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
        '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
        '<cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
        '<xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/></cellXfs></styleSheet>');
    add('xl/worksheets/sheet1.xml',
        '$head<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        '${cols.isNotEmpty ? '<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>' : ''}'
        '$colsXml<sheetData>$sheet</sheetData></worksheet>');
    return ZipEncoder().encode(a);
  }
}

class _Block {
  final String kind;
  final String text;
  final List<List<String>>? rows;
  final String? num;
  _Block(this.kind, this.text, [this.rows, this.num]);
}
