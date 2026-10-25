import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import 'readable.dart';

/// Text out of everyday office files, on the phone and offline: Word (.docx), Excel (.xlsx), PowerPoint (.pptx),
/// OpenDocument (.odt/.ods/.odp), EPUB books, web pages, RTF and plain text formats.
/// PDFs and photos are read by DocTools (PDF engine and on-device OCR).
class DocText {
  static const office = {'docx', 'docm', 'xlsx', 'xlsm', 'pptx', 'pptm', 'odt', 'ods', 'odp', 'epub'};
  static const plain = {'txt', 'md', 'markdown', 'csv', 'tsv', 'json', 'xml', 'log', 'srt', 'vtt', 'yaml', 'yml', 'ini', 'tex'};
  static const web = {'html', 'htm', 'xhtml'};

  static String ext(String name) {
    final n = name.toLowerCase().split('?').first;
    final i = n.lastIndexOf('.');
    return i < 0 ? '' : n.substring(i + 1);
  }

  static bool supports(String name) {
    final e = ext(name);
    return office.contains(e) || plain.contains(e) || web.contains(e) || e == 'rtf';
  }

  /// The text of a file, or null when the format is not one of ours.
  /// Throws a [FormatException] with a plain message when the file is damaged or protected.
  static String? extract(String name, List<int> bytes) {
    final e = ext(name);
    if (plain.contains(e)) return utf8.decode(bytes, allowMalformed: true);
    if (web.contains(e)) return Readable.text(utf8.decode(bytes, allowMalformed: true));
    if (e == 'rtf') return rtf(latin1.decode(bytes, allowInvalid: true));
    if (!office.contains(e)) return null;
    final Archive zip;
    try {
      zip = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw const FormatException('This file is damaged or password-protected, so its text cannot be read.');
    }
    switch (e) {
      case 'docx':
      case 'docm':
        return docx(zip);
      case 'xlsx':
      case 'xlsm':
        return xlsx(zip);
      case 'pptx':
      case 'pptm':
        return pptx(zip);
      case 'odt':
      case 'odp':
        return odf(zip);
      case 'ods':
        return ods(zip);
      case 'epub':
        return epub(zip);
    }
    return null;
  }

  static String? _file(Archive zip, String path) {
    final f = zip.findFile(path);
    if (f == null) return null;
    return utf8.decode(f.content as List<int>, allowMalformed: true);
  }

  static XmlDocument _xml(Archive zip, String path) {
    final s = _file(zip, path);
    if (s == null) throw FormatException('This file is missing its $path part, so it may be damaged.');
    return XmlDocument.parse(s);
  }

  // ------------------------------------------------------------------ Word

  static String docx(Archive zip) {
    final doc = _xml(zip, 'word/document.xml');
    final body = doc.findAllElements('w:body').firstOrNull ?? doc.rootElement;
    final sb = StringBuffer();
    for (final n in body.childElements) {
      _docxBlock(n, sb);
    }
    return _tidy(sb.toString());
  }

  static void _docxBlock(XmlElement n, StringBuffer sb) {
    switch (n.name.qualified) {
      case 'w:p':
        final t = _docxPara(n);
        final style = n.findAllElements('w:pStyle').firstOrNull?.getAttribute('w:val') ?? '';
        final h = RegExp(r'^(?:Heading|heading)\s?(\d)$').firstMatch(style);
        if (h != null && t.trim().isNotEmpty) {
          sb.writeln('\n${'#' * int.parse(h[1]!).clamp(1, 6)} ${t.trim()}');
        } else if (style == 'Title' && t.trim().isNotEmpty) {
          sb.writeln('# ${t.trim()}');
        } else if (n.findAllElements('w:numPr').isNotEmpty && t.trim().isNotEmpty) {
          sb.writeln('- ${t.trim()}');
        } else {
          sb.writeln(t);
        }
      case 'w:tbl':
        for (final tr in n.findElements('w:tr')) {
          final cells = [
            for (final tc in tr.findElements('w:tc')) [for (final p in tc.findAllElements('w:p')) _docxPara(p).trim()].where((x) => x.isNotEmpty).join(' '),
          ];
          sb.writeln('| ${cells.join(' | ')} |');
        }
        sb.writeln();
      case 'w:sdt':
        for (final c in n.findAllElements('w:sdtContent')) {
          for (final x in c.childElements) {
            _docxBlock(x, sb);
          }
        }
    }
  }

  static String _docxPara(XmlElement p) {
    final sb = StringBuffer();
    for (final e in p.descendantElements) {
      switch (e.name.qualified) {
        case 'w:t':
          sb.write(e.innerText);
        case 'w:tab':
          sb.write('\t');
        case 'w:br':
        case 'w:cr':
          sb.write('\n');
      }
    }
    return sb.toString();
  }

  // ------------------------------------------------------------------ Excel

  static String xlsx(Archive zip, {int maxRows = 5000}) {
    final shared = <String>[];
    final ss = _file(zip, 'xl/sharedStrings.xml');
    if (ss != null) {
      for (final si in XmlDocument.parse(ss).findAllElements('si')) {
        shared.add(si.findAllElements('t').map((t) => t.innerText).join());
      }
    }
    final wb = _xml(zip, 'xl/workbook.xml');
    final rels = <String, String>{};
    final relsXml = _file(zip, 'xl/_rels/workbook.xml.rels');
    if (relsXml != null) {
      for (final r in XmlDocument.parse(relsXml).findAllElements('Relationship')) {
        var t = r.getAttribute('Target') ?? '';
        t = t.startsWith('/') ? t.substring(1) : 'xl/$t';
        rels[r.getAttribute('Id') ?? ''] = t;
      }
    }
    final sheets = wb.findAllElements('sheet').toList();
    final sb = StringBuffer();
    var i = 0;
    for (final s in sheets) {
      i++;
      final name = s.getAttribute('name') ?? 'Sheet $i';
      final rid = s.getAttribute('r:id') ?? s.attributes.where((a) => a.name.local == 'id').firstOrNull?.value ?? '';
      final path = rels[rid] ?? 'xl/worksheets/sheet$i.xml';
      final xml = _file(zip, path);
      if (xml == null) continue;
      sb.writeln('## Sheet: $name');
      var rows = 0;
      for (final row in XmlDocument.parse(xml).findAllElements('row')) {
        final vals = <int, String>{};
        var next = 0;
        for (final c in row.findElements('c')) {
          final ref = c.getAttribute('r');
          final col = ref == null ? next : colIndex(ref);
          next = col + 1;
          vals[col] = _cell(c, shared);
        }
        if (vals.values.every((v) => v.isEmpty)) continue;
        final last = vals.keys.reduce((a, b) => a > b ? a : b);
        sb.writeln([for (var k = 0; k <= last; k++) vals[k] ?? ''].join(' | '));
        if (++rows >= maxRows) {
          sb.writeln('…(more rows not shown)');
          break;
        }
      }
      sb.writeln();
    }
    return _tidy(sb.toString());
  }

  static String _cell(XmlElement c, List<String> shared) {
    final t = c.getAttribute('t') ?? '';
    final v = c.findElements('v').firstOrNull?.innerText ?? '';
    switch (t) {
      case 's':
        final k = int.tryParse(v);
        return k != null && k < shared.length ? shared[k] : '';
      case 'inlineStr':
        return c.findAllElements('t').map((x) => x.innerText).join();
      case 'b':
        return v == '1' ? 'TRUE' : 'FALSE';
      default:
        return v;
    }
  }

  /// "A1" -> 0, "AB12" -> 27.
  static int colIndex(String ref) {
    var n = 0;
    for (final ch in ref.toUpperCase().codeUnits) {
      if (ch < 65 || ch > 90) break;
      n = n * 26 + (ch - 64);
    }
    return n - 1;
  }

  // ------------------------------------------------------------------ PowerPoint

  static String pptx(Archive zip) {
    final slideRe = RegExp(r'^ppt/slides/slide(\d+)\.xml$');
    final slides = <int, ArchiveFile>{};
    for (final f in zip.files) {
      final mm = slideRe.firstMatch(f.name);
      if (mm != null) slides[int.parse(mm[1]!)] = f;
    }
    final sb = StringBuffer();
    for (final k in slides.keys.toList()..sort()) {
      sb.writeln('--- Slide $k ---');
      final x = XmlDocument.parse(utf8.decode(slides[k]!.content as List<int>, allowMalformed: true));
      for (final p in x.findAllElements('a:p')) {
        final t = p.findAllElements('a:t').map((e) => e.innerText).join();
        if (t.trim().isNotEmpty) sb.writeln(t.trim());
      }
      final notes = _file(zip, 'ppt/notesSlides/notesSlide$k.xml');
      if (notes != null) {
        final n = [
          for (final p in XmlDocument.parse(notes).findAllElements('a:p')) p.findAllElements('a:t').map((e) => e.innerText).join().trim(),
        ].where((t) => t.isNotEmpty && !RegExp(r'^\d+$').hasMatch(t)).join(' ');
        if (n.isNotEmpty) sb.writeln('Notes: $n');
      }
      sb.writeln();
    }
    return _tidy(sb.toString());
  }

  // ------------------------------------------------------------------ OpenDocument

  static String odf(Archive zip) {
    final x = _xml(zip, 'content.xml');
    final sb = StringBuffer();
    for (final e in x.descendantElements) {
      final q = e.name.qualified;
      if (q == 'text:h') {
        final lvl = int.tryParse(e.getAttribute('text:outline-level') ?? '') ?? 1;
        sb.writeln('\n${'#' * lvl.clamp(1, 6)} ${_odfText(e).trim()}');
      } else if (q == 'text:p' && e.parentElement?.name.qualified != 'text:p') {
        sb.writeln(_odfText(e));
      }
    }
    return _tidy(sb.toString());
  }

  static String _odfText(XmlElement e) {
    final sb = StringBuffer();
    for (final n in e.children) {
      if (n is XmlText) {
        sb.write(n.value);
      } else if (n is XmlElement) {
        switch (n.name.qualified) {
          case 'text:s':
            sb.write(' ' * (int.tryParse(n.getAttribute('text:c') ?? '') ?? 1));
          case 'text:tab':
            sb.write('\t');
          case 'text:line-break':
            sb.write('\n');
          default:
            sb.write(_odfText(n));
        }
      }
    }
    return sb.toString();
  }

  static String ods(Archive zip) {
    final x = _xml(zip, 'content.xml');
    final sb = StringBuffer();
    for (final t in x.findAllElements('table:table')) {
      sb.writeln('## Sheet: ${t.getAttribute('table:name') ?? ''}');
      for (final r in t.findAllElements('table:table-row')) {
        final cells = <String>[];
        for (final c in r.findElements('table:table-cell')) {
          final rep = (int.tryParse(c.getAttribute('table:number-columns-repeated') ?? '') ?? 1).clamp(1, 50);
          final v = c.findElements('text:p').map(_odfText).join(' ');
          for (var i = 0; i < rep; i++) {
            cells.add(v);
          }
        }
        while (cells.isNotEmpty && cells.last.isEmpty) {
          cells.removeLast();
        }
        if (cells.isNotEmpty) sb.writeln(cells.join(' | '));
      }
      sb.writeln();
    }
    return _tidy(sb.toString());
  }

  // ------------------------------------------------------------------ EPUB

  static String epub(Archive zip) {
    final container = _xml(zip, 'META-INF/container.xml');
    final opfPath = container.findAllElements('rootfile').firstOrNull?.getAttribute('full-path');
    if (opfPath == null) throw const FormatException('This book has no table of contents file, so it may be damaged.');
    final dir = opfPath.contains('/') ? opfPath.substring(0, opfPath.lastIndexOf('/') + 1) : '';
    final opf = _xml(zip, opfPath);
    final manifest = <String, String>{
      for (final i in opf.findAllElements('item')) i.getAttribute('id') ?? '': i.getAttribute('href') ?? '',
    };
    final title = opf.findAllElements('dc:title').firstOrNull?.innerText.trim() ?? '';
    final sb = StringBuffer(title.isEmpty ? '' : 'Book: $title\n\n');
    for (final ref in opf.findAllElements('itemref')) {
      final href = manifest[ref.getAttribute('idref') ?? ''];
      if (href == null || href.isEmpty) continue;
      final html = _file(zip, Uri.decodeFull('$dir$href'));
      if (html == null) continue;
      sb.writeln(Readable.text(html).replaceFirst(RegExp(r'^Title: .*\n+'), ''));
      sb.writeln();
    }
    return _tidy(sb.toString());
  }

  // ------------------------------------------------------------------ RTF

  /// Plain text from simple RTF (enough for letters and notes saved as .rtf).
  static String rtf(String s) {
    // Escaped braces and backslashes are text: park them while the groups are stripped.
    var t = s.replaceAll(r'\\', '\u0003').replaceAll(r'\{', '\u0001').replaceAll(r'\}', '\u0002');
    // Drop destinations that hold no visible text ({\*\...}, font and colour tables, pictures).
    for (final g in [r'\*', r'fonttbl', r'colortbl', r'stylesheet', r'info', r'pict']) {
      while (true) {
        final i = t.indexOf('{\\$g');
        if (i < 0) break;
        var depth = 0, j = i;
        for (; j < t.length; j++) {
          if (t[j] == '{') depth++;
          if (t[j] == '}' && --depth == 0) break;
        }
        t = t.substring(0, i) + (j + 1 < t.length ? t.substring(j + 1) : '');
      }
    }
    t = t
        .replaceAllMapped(RegExp(r"\\'([0-9a-fA-F]{2})"), (m) => String.fromCharCode(int.parse(m[1]!, radix: 16)))
        .replaceAllMapped(RegExp(r'\\u(-?\d+)\??'), (m) {
          var c = int.parse(m[1]!);
          if (c < 0) c += 65536;
          return String.fromCharCode(c);
        })
        .replaceAll(RegExp(r'\\(par|line)\b ?'), '\n')
        .replaceAll(RegExp(r'\\tab\b ?'), '\t')
        .replaceAll(RegExp(r'\\[a-zA-Z]+-?\d* ?'), '')
        .replaceAll(RegExp(r'[{}]'), '')
        .replaceAll('\u0001', '{')
        .replaceAll('\u0002', '}')
        .replaceAll('\u0003', '\\');
    return _tidy(t);
  }

  static String _tidy(String s) => s.replaceAll('\r', '').replaceAll(RegExp(r'[ \t]+\n'), '\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
}
