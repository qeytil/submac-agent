import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agent/services/calc.dart';
import 'package:agent/services/doc_text.dart';
import 'package:agent/services/doc_tools.dart';
import 'package:agent/services/mcp_oauth.dart';
import 'package:agent/services/readable.dart';
import 'package:agent/services/tool_scope.dart';

List<int> zip(Map<String, String> files) {
  final a = Archive();
  for (final e in files.entries) {
    final b = utf8.encode(e.value);
    a.addFile(ArchiveFile(e.key, b.length, b));
  }
  return ZipEncoder().encode(a);
}

void main() {
  group('calculate: arithmetic and percentages', () {
    test('plain maths', () {
      expect(Calc.eval('2 + 3 * 4'), 14);
      expect(Calc.eval('(2+3)*4'), 20);
      expect(Calc.eval('2^10'), 1024);
      expect(Calc.eval('sqrt(144)'), 12);
      expect(Calc.eval('3 x 4'), 12);
      expect(Calc.eval('10 divided by 4'), 2.5);
      expect(Calc.eval('17 mod 5'), 2);
      expect(Calc.eval('2e3 + 1'), 2001);
    });
    test('money style input', () {
      expect(Calc.eval(r'$1,250 * 12'), 15000);
      expect(Calc.eval('15% of 2,400'), closeTo(360, 1e-9));
      expect(Calc.eval('2400 + 5%'), closeTo(2520, 1e-9));
      expect(Calc.eval('2400 - 10%'), closeTo(2160, 1e-9));
      expect(Calc.eval('1250*12 - 15% of 3000'), closeTo(14550, 1e-9));
    });
    test('clean formatting', () {
      expect(Calc.fmt(15000), '15,000');
      expect(Calc.fmt(1234.5), '1234.5');
      expect(Calc.fmt(12345.678), '12,345.678');
      expect(Calc.fmt(1 / 3), '0.3333333333');
      expect(Calc.fmt(-2500000), '-2,500,000');
    });
    test('words that are not numbers give a clear error', () {
      expect(Calc.run('apples + 2'), contains('Error'));
      expect(Calc.run('1/0'), contains('Error'));
    });
  });

  group('calculate: units', () {
    test('length, mass, area, volume, temperature', () {
      expect(Calc.convert('5 km to miles'), startsWith('3.106855961'));
      expect(Calc.convert('10 kg in lb'), startsWith('22.04622622'));
      expect(Calc.convert('2 acres to m2'), '8093.712845 m2');
      expect(Calc.convert('1 hectare to acres'), startsWith('2.471053815'));
      expect(Calc.convert('20 litres to gallons'), startsWith('5.283441'));
      expect(Calc.convert('30 c to f'), '86 °F');
      expect(Calc.convert('98.6 °F to C'), '37 °C');
      expect(Calc.convert('100 km/h to mph'), startsWith('62.13711922'));
      expect(Calc.convert('5 sq ft to m2'), startsWith('0.4645152'));
    });
    test('mismatched or unknown units say so; other lines are not conversions', () {
      expect(() => Calc.convert('5 kg to km'), throwsFormatException);
      expect(Calc.convert('2 + 2'), isNull);
    });
  });

  group('calculate: dates', () {
    final now = DateTime(2026, 10, 20, 15);
    test('between, until, plus, weekday, age', () {
      expect(Calc.dateMath('days from 2026-01-01 to 2026-03-15', now), startsWith('73 days'));
      expect(Calc.dateMath('days until 2026-12-25', now), startsWith('66 days'));
      expect(Calc.dateMath('2026-10-20 + 90 days', now), contains('2027-01-18'));
      expect(Calc.dateMath('2026-01-31 + 1 month', now), contains('2026-02-28'));
      expect(Calc.dateMath('today + 2 weeks', now), contains('2026-11-03'));
      expect(Calc.dateMath('weekday 2026-12-25', now), startsWith('Friday'));
      expect(Calc.dateMath('age 1983-11-12', now), startsWith('42 years, 11 months'));
      expect(Calc.dateMath('5 * 3', now), isNull);
    });
    test('impossible dates are refused', () {
      expect(() => Calc.dateMath('weekday 2026-02-30', now), throwsFormatException);
    });
    test('several lines at once', () {
      final r = Calc.run('2+2\n5 km to m', now: now);
      expect(r, contains('2+2 = 4'));
      expect(r, contains('5000 m'));
    });
  });

  group('read_document: office files as text', () {
    test('Word: headings, paragraphs, lists and tables', () {
      final b = zip({
        'word/document.xml': '<?xml version="1.0"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>'
            '<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Invoice 12</w:t></w:r></w:p>'
            '<w:p><w:r><w:t xml:space="preserve">Hello </w:t></w:r><w:r><w:t>Amina</w:t></w:r></w:p>'
            '<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/></w:numPr></w:pPr><w:r><w:t>Rice</w:t></w:r></w:p>'
            '<w:tbl><w:tr><w:tc><w:p><w:r><w:t>Item</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>Price</w:t></w:r></w:p></w:tc></w:tr></w:tbl>'
            '</w:body></w:document>',
      });
      final t = DocText.extract('a.docx', b)!;
      expect(t, contains('# Invoice 12'));
      expect(t, contains('Hello Amina'));
      expect(t, contains('- Rice'));
      expect(t, contains('| Item | Price |'));
    });
    test('Excel: shared strings, numbers, gaps and sheet names', () {
      final b = zip({
        'xl/workbook.xml': '<workbook xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>'
            '<sheet name="Sales" sheetId="1" r:id="rId1"/></sheets></workbook>',
        'xl/_rels/workbook.xml.rels': '<Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml"/></Relationships>',
        'xl/sharedStrings.xml': '<sst><si><t>Item</t></si><si><t>Qty</t></si><si><t>Sugar</t></si></sst>',
        'xl/worksheets/sheet1.xml': '<worksheet><sheetData>'
            '<row r="1"><c r="A1" t="s"><v>0</v></c><c r="C1" t="s"><v>1</v></c></row>'
            '<row r="2"><c r="A2" t="s"><v>2</v></c><c r="C2"><v>40</v></c></row>'
            '</sheetData></worksheet>',
      });
      final t = DocText.extract('book.xlsx', b)!;
      expect(t, contains('## Sheet: Sales'));
      expect(t, contains('Item |  | Qty'));
      expect(t, contains('Sugar |  | 40'));
      expect(DocText.colIndex('AB12'), 27);
    });
    test('PowerPoint: slides in order with notes', () {
      String slide(String s) => '<p:sld xmlns:a="a" xmlns:p="p"><a:p><a:r><a:t>$s</a:t></a:r></a:p></p:sld>';
      final b = zip({
        'ppt/slides/slide10.xml': slide('Ten'),
        'ppt/slides/slide2.xml': slide('Two'),
        'ppt/notesSlides/notesSlide2.xml': '<n xmlns:a="a"><a:p><a:r><a:t>Say hello</a:t></a:r></a:p></n>',
      });
      final t = DocText.extract('deck.pptx', b)!;
      expect(t.indexOf('Two'), lessThan(t.indexOf('Ten')));
      expect(t, contains('Notes: Say hello'));
    });
    test('OpenDocument text and EPUB', () {
      final odt = zip({
        'content.xml': '<office:document-content xmlns:office="o" xmlns:text="t"><office:body><office:text>'
            '<text:h text:outline-level="2">Plan</text:h><text:p>One<text:s text:c="2"/>two</text:p></office:text></office:body></office:document-content>',
      });
      final t = DocText.extract('a.odt', odt)!;
      expect(t, contains('## Plan'));
      expect(t, contains('One  two'));
      final ep = zip({
        'META-INF/container.xml': '<container><rootfiles><rootfile full-path="OEBPS/book.opf"/></rootfiles></container>',
        'OEBPS/book.opf': '<package xmlns:dc="dc"><metadata><dc:title>Sheeko</dc:title></metadata><manifest>'
            '<item id="c1" href="c1.xhtml"/></manifest><spine><itemref idref="c1"/></spine></package>',
        'OEBPS/c1.xhtml': '<html><body><h1>Chapter 1</h1><p>Waa sheeko.</p></body></html>',
      });
      final e = DocText.extract('b.epub', ep)!;
      expect(e, contains('Book: Sheeko'));
      expect(e, contains('# Chapter 1'));
      expect(e, contains('Waa sheeko.'));
    });
    test('RTF, plain text, and damaged files', () {
      expect(DocText.extract('a.rtf', utf8.encode(r'{\rtf1\ansi{\fonttbl{\f0 Arial;}}\f0 Hello\par World \{ok\}}')), 'Hello\nWorld {ok}');
      expect(DocText.extract('a.csv', utf8.encode('a,b\n1,2')), 'a,b\n1,2');
      expect(() => DocText.extract('a.docx', [1, 2, 3, 4]), throwsFormatException);
      expect(DocText.extract('a.bin', [1, 2]), isNull);
    });
    test('long documents come in parts', () {
      final s = 'x' * 25000;
      final p1 = DocTools.partOf(s, 0, 12000);
      expect(p1, contains('call again with offset 12000'));
      expect(DocTools.partOf(s, 24000, 12000), startsWith('(characters 24000 to 25000'));
    });
  });

  group('readable web pages', () {
    test('keeps the article, drops menus, cookie banners and footers', () {
      final body = List.filled(8, 'Mogadishu port handled more containers this year than last year, officials said.').join(' ');
      final html = '<html><head><title>Port news</title><style>p{}</style></head><body>'
          '<nav><a>Home</a><a>Sports</a></nav><div class="cookie-banner">We use cookies</div>'
          '<article><h1>Port grows</h1><p>$body</p><ul><li>Point one</li><li>Point two</li></ul>'
          '<table><tr><th>Year</th><th>Boxes</th></tr><tr><td>2026</td><td>1,200</td></tr></table></article>'
          '<footer>Copyright</footer><script>var x=1</script></body></html>';
      final t = Readable.text(html);
      expect(t, startsWith('Title: Port news'));
      expect(t, contains('# Port grows'));
      expect(t, contains('- Point one'));
      expect(t, contains('| 2026 | 1,200 |'));
      expect(t, isNot(contains('We use cookies')));
      expect(t, isNot(contains('Copyright')));
      expect(t, isNot(contains('Sports')));
      expect(t, isNot(contains('var x')));
    });
  });

  group('wiring', () {
    test('new tools sit in the right groups', () {
      expect(ToolScope.groupOf('calculate'), '');
      expect(ToolScope.groupOf('read_document'), ToolScope.files);
      final names = [for (final d in CalcTools.definitions) (d['function'] as Map)['name']];
      expect(names, ['calculate']);
      expect(jsonEncode(CalcTools.definitions).length ~/ 4, lessThan(220));
    });
    test('new one-tap apps are present and unique', () {
      final ids = [for (final p in McpOAuth.presets) p.id];
      expect(ids.toSet().length, ids.length);
      for (final id in ['dropbox', 'buffer', 'typeform', 'invideo', 'godaddy', 'coingecko', 'peek', 'mslearn']) {
        expect(ids, contains(id));
      }
      expect(McpOAuth.presets.firstWhere((p) => p.id == 'coingecko').signIn, isFalse);
    });
  });
}
