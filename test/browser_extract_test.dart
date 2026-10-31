// The schema ear + the extract walker (P2, browser-godmode): the site's own structured data,
// and every matching item pulled in one call.
import 'dart:convert';

import 'package:agent/services/browser/extract.dart';
import 'package:agent/services/browser/page_model.dart';
import 'package:agent/services/browser/page_script.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('formatSchemaIndex lists the blocks with sizes, or says the page carries none', () {
    final idx = formatSchemaIndex(jsonEncode({
      'n': 2,
      'og': 8,
      'items': [
        {'i': 0, 'kind': 'ld', 'name': 'Product', 'kb': '1.2KB'},
        {'i': 1, 'kind': 'state', 'name': '__NEXT_DATA__', 'kb': '84.3KB'},
      ],
    }));
    expect(idx, contains('[0] JSON-LD Product (1.2KB)'));
    expect(idx, contains('[1] app state __NEXT_DATA__ (84.3KB)'));
    expect(idx, contains('OpenGraph/Twitter metas: 8'));
    expect(formatSchemaIndex(jsonEncode({'n': 0, 'og': 0, 'items': []})), contains('No structured data'));
    expect(formatSchemaIndex('not json'), contains('Error'));
  });

  test('formatSchemaOpen pretty-prints the block and says when the index moved on', () {
    final one = formatSchemaOpen(jsonEncode({
      'i': 0,
      'kind': 'ld',
      'name': 'Product',
      'kb': '28B',
      'text': '{"@type":"Product","name":"Red shoes","price":"19.99"}',
    }));
    expect(one, startsWith('[0] JSON-LD Product (28B)'));
    expect(one, contains('"name": "Red shoes"'));
    expect(formatSchemaOpen(jsonEncode({'err': 'gone'})), contains('gone'));
    expect(formatSchemaOpen('x'), contains('Error'));
  });

  test('formatExtract carries the rows as JSON and points at the data card', () {
    final ok = formatExtract(jsonEncode({
      'n': 2,
      'rows': [
        {'name': 'Red shoes', 'price': '\$19.99', 'link': '/p/red'},
        {'name': 'Blue hat', 'price': '\$9.99', 'link': '/p/blue'},
      ],
    }));
    expect(ok, startsWith('2 rows'));
    expect(ok, contains('```data card'));
    expect(ok, contains('"Red shoes"'));
    final part = formatExtract(jsonEncode({'n': 5, 'rows': [Map.fromEntries(List.generate(60, (i) => MapEntry('k$i', 'v$i')))]}));
    expect(part, contains('of 5 on the page'));
    expect(formatExtract(jsonEncode({'n': 0, 'rows': []})), contains('No items matched'));
    expect(formatExtract(jsonEncode({'err': 'bad rows selector: x'})), contains('Error: bad rows selector'));
    expect(formatExtract('nope'), contains('Error'));
  });

  test('the page script ships the schema ear: v11 with schema/schemaOpen/extract/extractHtml and a summary in the snapshot', () {
    final src = PageScript.source;
    expect(src, contains('var VERSION = 11;'));
    expect(src, contains('S.schema'), reason: 'the index API browser_schema calls');
    expect(src, contains('S.schemaOpen'), reason: 'the one-block API');
    expect(src, contains('S.extract'), reason: 'the walker browser_extract calls');
    expect(src, contains('sch: schLine()'), reason: 'the snapshot summary line');
    expect(src, contains('NEXT_DATA'), reason: 'app state blocks are found');
    expect(src, contains('application/ld+json'), reason: 'JSON-LD is collected');
  });

  test('PageSnapshot carries the schema summary from the snapshot JSON', () {
    final snap = PageSnapshot.parse(jsonEncode({
      'url': 'https://shop.test/search',
      'title': 'Shoes',
      'els': [],
      'text': 'hello',
      'sch': 'JSON-LD Product, state 84.3KB, og:8',
    }));
    expect(snap.schema, 'JSON-LD Product, state 84.3KB, og:8');
    expect(PageSnapshot.parse(jsonEncode({'url': 'u', 'els': []})).schema, '', reason: 'pages with no schema parse fine');
  });
}
