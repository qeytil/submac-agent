import 'dart:convert';

import 'package:archive/archive.dart';

/// Reads Word (.docx) and PowerPoint (.pptx) files so they can be shown inside the app.
/// Text, headings, lists and tables are kept. Pictures and exact layout are not.
class OfficeBlock {
  OfficeBlock.paragraph(this.text, {this.level = 0, this.bold = false, this.bullet = false}) : rows = const [];
  OfficeBlock.table(this.rows)
      : text = '',
        level = 0,
        bold = false,
        bullet = false;

  final String text;

  /// 1-6 for headings and titles, 0 for normal text.
  final int level;
  final bool bold;
  final bool bullet;
  final List<List<String>> rows;
  bool get isTable => rows.isNotEmpty;
}

class OfficeSlide {
  OfficeSlide(this.number, this.blocks);
  final int number;
  final List<OfficeBlock> blocks;
}

class OfficeReader {
  static String _xml(Archive a, String name) {
    final f = a.findFile(name);
    if (f == null) return '';
    return utf8.decode(f.content as List<int>, allowMalformed: true);
  }

  static String unxml(String s) => s
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAllMapped(RegExp(r'&#(x?)([0-9a-fA-F]+);'), (m) {
        final code = int.tryParse(m[2]!, radix: m[1]!.isEmpty ? 10 : 16);
        return code == null ? '' : String.fromCharCode(code);
      })
      .replaceAll('&amp;', '&');

  /// Text runs of one Word paragraph: <w:t>, tabs and breaks.
  static String _wText(String p) {
    final b = StringBuffer();
    for (final m in RegExp(r'<w:t(?:\s[^>]*)?>([^<]*)</w:t>|<w:tab/>|<w:br/>|<w:cr/>').allMatches(p)) {
      final s = m[0]!;
      if (s.startsWith('<w:tab')) {
        b.write('\t');
      } else if (s.startsWith('<w:br') || s.startsWith('<w:cr')) {
        b.write('\n');
      } else {
        b.write(unxml(m[1] ?? ''));
      }
    }
    return b.toString();
  }

  static OfficeBlock _wPara(String p) {
    final style = RegExp(r'<w:pStyle w:val="([^"]*)"').firstMatch(p)?[1]?.toLowerCase() ?? '';
    var level = 0;
    final h = RegExp(r'heading\s*([1-6])').firstMatch(style);
    if (h != null) level = int.parse(h[1]!);
    if (style == 'title') level = 1;
    if (style == 'subtitle') level = 3;
    final bullet = p.contains('<w:numPr>') || style.contains('list');
    final bold = RegExp(r'<w:b/>|<w:b w:val="(1|true)"/>').hasMatch(p);
    return OfficeBlock.paragraph(_wText(p), level: level, bold: bold, bullet: bullet);
  }

  static List<OfficeBlock> docx(List<int> bytes) {
    final a = ZipDecoder().decodeBytes(bytes);
    var xml = _xml(a, 'word/document.xml');
    if (xml.isEmpty) throw const FormatException('Not a Word file');
    final body = RegExp(r'<w:body>([\s\S]*)</w:body>').firstMatch(xml)?[1] ?? xml;
    final out = <OfficeBlock>[];
    // Walk top-level paragraphs and tables in order.
    final re = RegExp(r'<w:tbl>[\s\S]*?</w:tbl>|<w:p[ >][\s\S]*?</w:p>|<w:p/>');
    for (final m in re.allMatches(body)) {
      final s = m[0]!;
      if (s.startsWith('<w:tbl>')) {
        final rows = <List<String>>[];
        for (final r in RegExp(r'<w:tr[ >][\s\S]*?</w:tr>').allMatches(s)) {
          rows.add([
            for (final c in RegExp(r'<w:tc>[\s\S]*?</w:tc>').allMatches(r[0]!))
              [for (final p in RegExp(r'<w:p[ >][\s\S]*?</w:p>').allMatches(c[0]!)) _wText(p[0]!)].join('\n').trim(),
          ]);
        }
        if (rows.isNotEmpty) out.add(OfficeBlock.table(rows));
      } else if (s != '<w:p/>') {
        out.add(_wPara(s));
      }
    }
    // Drop runs of empty paragraphs.
    final clean = <OfficeBlock>[];
    for (final b in out) {
      if (!b.isTable && b.text.trim().isEmpty && (clean.isEmpty || (!clean.last.isTable && clean.last.text.trim().isEmpty))) continue;
      clean.add(b);
    }
    return clean;
  }

  static List<OfficeSlide> pptx(List<int> bytes) {
    final a = ZipDecoder().decodeBytes(bytes);
    final names = <int, String>{};
    for (final f in a.files) {
      final m = RegExp(r'^ppt/slides/slide(\d+)\.xml$').firstMatch(f.name);
      if (m != null) names[int.parse(m[1]!)] = f.name;
    }
    if (names.isEmpty) throw const FormatException('Not a PowerPoint file');
    // Slide order from presentation.xml when it is there, file numbers otherwise.
    var order = (names.keys.toList()..sort());
    final pres = _xml(a, 'ppt/presentation.xml');
    final rels = _xml(a, 'ppt/_rels/presentation.xml.rels');
    if (pres.isNotEmpty && rels.isNotEmpty) {
      final target = <String, int>{};
      for (final r in RegExp(r'<Relationship [^>]*>').allMatches(rels)) {
        final id = RegExp(r'Id="([^"]+)"').firstMatch(r[0]!)?[1];
        final t = RegExp(r'Target="(?:/ppt/)?slides/slide(\d+)\.xml"').firstMatch(r[0]!)?[1];
        if (id != null && t != null) target[id] = int.parse(t);
      }
      final ids = [
        for (final m in RegExp(r'<p:sldId [^>]*r:id="([^"]+)"').allMatches(pres))
          if (target[m[1]] != null && names.containsKey(target[m[1]])) target[m[1]]!,
      ];
      if (ids.length == names.length) order = ids;
    }
    final out = <OfficeSlide>[];
    var n = 0;
    for (final i in order) {
      n++;
      final xml = _xml(a, names[i]!);
      final blocks = <OfficeBlock>[];
      for (final sp in RegExp(r'<p:sp>[\s\S]*?</p:sp>|<a:tbl>[\s\S]*?</a:tbl>').allMatches(xml)) {
        final s = sp[0]!;
        if (s.startsWith('<a:tbl>')) {
          final rows = [
            for (final r in RegExp(r'<a:tr[ >][\s\S]*?</a:tr>').allMatches(s))
              [for (final c in RegExp(r'<a:tc[ >][\s\S]*?</a:tc>').allMatches(r[0]!)) _aText(c[0]!).trim()],
          ];
          if (rows.isNotEmpty) blocks.add(OfficeBlock.table(rows));
          continue;
        }
        final isTitle = RegExp(r'<p:ph type="(title|ctrTitle)"').hasMatch(s);
        final isSub = s.contains('<p:ph type="subTitle"');
        for (final p in RegExp(r'<a:p>[\s\S]*?</a:p>').allMatches(s)) {
          final t = _aText(p[0]!);
          if (t.trim().isEmpty) continue;
          blocks.add(OfficeBlock.paragraph(t,
              level: isTitle ? 2 : (isSub ? 4 : 0), bullet: !isTitle && !isSub && p[0]!.contains('<a:buChar')));
        }
      }
      out.add(OfficeSlide(n, blocks));
    }
    return out;
  }

  static String _aText(String p) => [
        for (final m in RegExp(r'<a:t>([^<]*)</a:t>|<a:br/>').allMatches(p)) m[0] == '<a:br/>' ? '\n' : unxml(m[1] ?? ''),
      ].join();
}
