import 'dart:convert';

import 'package:agent/services/office_reader.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

List<int> zip(Map<String, String> files) {
  final a = Archive();
  files.forEach((k, v) {
    final b = utf8.encode(v);
    a.addFile(ArchiveFile(k, b.length, b));
  });
  return ZipEncoder().encode(a);
}

void main() {
  test('reads a Word file: heading, bullet, bold text and a table in order', () {
    const doc = '<?xml version="1.0"?><w:document xmlns:w="x"><w:body>'
        '<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Warbixin &amp; Iib</w:t></w:r></w:p>'
        '<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/></w:numPr></w:pPr><w:r><w:t>Bariis</w:t></w:r></w:p>'
        '<w:p><w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">Total: </w:t></w:r><w:r><w:t>192 USD</w:t></w:r></w:p>'
        '<w:tbl><w:tr><w:tc><w:p><w:r><w:t>Item</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>Qty</w:t></w:r></w:p></w:tc></w:tr>'
        '<w:tr><w:tc><w:p><w:r><w:t>Rice</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>8</w:t></w:r></w:p></w:tc></w:tr></w:tbl>'
        '<w:p/><w:p><w:r><w:t>End</w:t></w:r></w:p>'
        '</w:body></w:document>';
    final blocks = OfficeReader.docx(zip({'word/document.xml': doc}));
    expect(blocks.first.text, 'Warbixin & Iib');
    expect(blocks.first.level, 1);
    expect(blocks[1].bullet, isTrue);
    expect(blocks[2].text, 'Total: 192 USD');
    expect(blocks[2].bold, isTrue);
    final table = blocks.firstWhere((b) => b.isTable);
    expect(table.rows, [
      ['Item', 'Qty'],
      ['Rice', '8'],
    ]);
    expect(blocks.last.text, 'End');
  });

  test('reads PowerPoint slides in presentation order', () {
    String slide(String title, String body) => '<p:sld><p:cSld><p:spTree>'
        '<p:sp><p:nvSpPr><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr><p:txBody><a:p><a:r><a:t>$title</a:t></a:r></a:p></p:txBody></p:sp>'
        '<p:sp><p:txBody><a:p><a:pPr><a:buChar char="•"/></a:pPr><a:r><a:t>$body</a:t></a:r></a:p></p:txBody></p:sp>'
        '</p:spTree></p:cSld></p:sld>';
    final bytes = zip({
      'ppt/slides/slide1.xml': slide('Second', 'b'),
      'ppt/slides/slide2.xml': slide('First', 'a'),
      'ppt/presentation.xml': '<p:presentation><p:sldIdLst><p:sldId id="256" r:id="rId9"/><p:sldId id="257" r:id="rId8"/></p:sldIdLst></p:presentation>',
      'ppt/_rels/presentation.xml.rels':
          '<Relationships><Relationship Id="rId8" Target="slides/slide1.xml"/><Relationship Id="rId9" Target="slides/slide2.xml"/></Relationships>',
    });
    final slides = OfficeReader.pptx(bytes);
    expect(slides.length, 2);
    expect(slides[0].blocks.first.text, 'First');
    expect(slides[0].blocks.first.level, 2);
    expect(slides[0].blocks[1].bullet, isTrue);
    expect(slides[1].blocks.first.text, 'Second');
  });

  test('a file that is not Office says so', () {
    expect(() => OfficeReader.docx(zip({'a.txt': 'x'})), throwsFormatException);
  });
}
