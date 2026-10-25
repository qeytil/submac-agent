import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import 'bot_package.dart';

/// The shared Somali knowledge library: language, proverbs, dialects, names, religion in daily life, family and
/// weddings, clans (handled neutrally), history, geography, literature, food and modern life. It ships with the app
/// (assets/knowledge/somali/part*.json) and is read on demand by the agent, every bot and Live calls through one tool, so
/// it costs nothing until a question needs it.
class SomaliKnowledge {
  SomaliKnowledge._();

  /// The library in parts (each small enough to update on its own).
  static const assets = [
    'assets/knowledge/somali/part1.json',
    'assets/knowledge/somali/part2.json',
    'assets/knowledge/somali/part3.json',
    'assets/knowledge/somali/part4.json',
    'assets/knowledge/somali/part5.json',
  ];
  static const names = {'somali_knowledge', 'somali_knowledge_read'};

  static List<BotKnowledge>? _items;
  static String checked = '';

  static Future<List<BotKnowledge>> items() async {
    final have = _items;
    if (have != null) return have;
    final all = <BotKnowledge>[];
    for (final a in assets) {
      try {
        final j = jsonDecode(await rootBundle.loadString(a)) as Map<String, dynamic>;
        checked = '${j['checked'] ?? ''}';
        all.addAll(parse(j, start: all.length));
      } catch (_) {}
    }
    return _items = all;
  }

  /// Entries of a library file ({checked, knowledge: [{title, text, topic}]}).
  static List<BotKnowledge> parse(Map<String, dynamic> j, {int start = 0}) {
    var n = start;
    return [
      for (final k in (j['knowledge'] as List? ?? const []))
        if (k is Map && '${k['text'] ?? ''}'.trim().isNotEmpty)
          BotKnowledge(id: 'so${n++}', title: '${k['title'] ?? 'Note'}', text: '${k['text']}'),
    ];
  }

  static Map<String, dynamic> _fn(String name, String desc, Map<String, dynamic> props, [List<String> req = const []]) => {
        'type': 'function',
        'function': {
          'name': name,
          'description': desc,
          'parameters': {'type': 'object', 'properties': props, 'required': req},
        },
      };

  static final List<Map<String, dynamic>> definitions = [
    _fn(
        'somali_knowledge',
        'Search SubMac\'s Somali knowledge library before answering anything about Somali language (grammar, words, '
            'spelling, proverbs, idioms, dialects, names), Somali culture and etiquette, Islam in Somali daily life, '
            'weddings and family customs, clans (neutral facts only), history, regions and cities, poetry and music, '
            'food, holidays, mobile money and modern Somali life. Returns the best passages with their ids.',
        {
          'query': {'type': 'string', 'description': 'What to look up, in English or Somali, e.g. "proverbs about patience" or "aroos"'},
        },
        ['query']),
    _fn('somali_knowledge_read', 'Read a whole entry of the Somali knowledge library by its id (from somali_knowledge).', {
      'id': {'type': 'string'},
      'offset': {'type': 'integer', 'description': 'Where to continue reading, from a previous result'},
    }, ['id']),
  ];

  static Future<String> execute(String name, Map<String, dynamic> a) async => run(name, a, await items());

  /// The tools over a given library (also used by tests).
  static String run(String name, Map<String, dynamic> a, List<BotKnowledge> all) {
    if (all.isEmpty) return 'The Somali knowledge library is not available on this phone. Answer from what you know.';
    String s(String k) => '${a[k] ?? ''}'.trim();
    if (name == 'somali_knowledge') {
      final hits = BotPackage.search(all, s('query'), limit: 4);
      if (hits.isEmpty) return 'Nothing in the Somali library matches "${s('query')}". Answer from what you know, and never invent Somali words or proverbs.';
      return [
        for (final h in hits) '[${h.$1.id} @${h.$2}] ${h.$1.title}\n${h.$3.replaceAll(RegExp(r'\s+'), ' ').trim()}',
      ].join('\n\n');
    }
    final k = all.where((x) => x.id == s('id')).firstOrNull ??
        all.where((x) => x.title.toLowerCase() == s('id').toLowerCase()).firstOrNull;
    if (k == null) return 'Error: no entry "${s('id')}". Search with somali_knowledge first.';
    final off = (a['offset'] is num ? (a['offset'] as num).toInt() : int.tryParse(s('offset')) ?? 0).clamp(0, k.text.length).toInt();
    final end = (off + 4000).clamp(0, k.text.length).toInt();
    final more = end < k.text.length ? '\n…(more: somali_knowledge_read with offset $end)' : '';
    return '# ${k.title} ($off-$end of ${k.text.length})\n${k.text.substring(off, end)}$more';
  }
}
