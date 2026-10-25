import 'dart:convert';
import 'dart:io';

import 'package:agent/services/somali.dart';
import 'package:agent/services/somali_knowledge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final lib = [
    for (final a in SomaliKnowledge.assets)
      ...SomaliKnowledge.parse(jsonDecode(File(a).readAsStringSync()) as Map<String, dynamic>),
  ];

  test('the library ships with language and culture entries', () {
    expect(lib.length, greaterThanOrEqualTo(100));
    expect(lib.every((k) => k.text.length > 300), isTrue);
    // Ids are unique across the parts once loaded in order.
    var n = 0;
    final ids = <String>{};
    for (final a in SomaliKnowledge.assets) {
      final part = SomaliKnowledge.parse(jsonDecode(File(a).readAsStringSync()) as Map<String, dynamic>, start: n);
      n += part.length;
      ids.addAll(part.map((k) => k.id));
    }
    expect(ids.length, lib.length);
  });

  test('search finds the right entries', () {
    final proverbs = SomaliKnowledge.run('somali_knowledge', {'query': 'maahmaah proverbs about speech'}, lib);
    expect(proverbs.toLowerCase(), contains('proverb'));
    final wedding = SomaliKnowledge.run('somali_knowledge', {'query': 'wedding meher aroos'}, lib);
    expect(wedding.toLowerCase(), contains('aroos'));
    final id = RegExp(r'\[(so\d+) @').firstMatch(wedding)!.group(1)!;
    expect(SomaliKnowledge.run('somali_knowledge_read', {'id': id}, lib), startsWith('# '));
    expect(SomaliKnowledge.run('somali_knowledge', {'query': 'x'}, const []), contains('not available'));
  });

  test('the culture core is sent with Somali chats and calls', () {
    expect(Somali.cultureCore, contains('Never ask a user\'s clan'));
    expect(Somali.cultureCore, contains('somali_knowledge'));
    expect(Somali.cultureCore.length, lessThan(7000));
  });
}
