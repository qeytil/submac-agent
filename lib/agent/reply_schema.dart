// The final reply as typed Hark-style blocks, checked against a schema before it is shown.
//
// The model writes its reply as markdown with fenced cards (```table JSON, ```summary, ```choices …), which streams well
// and which the app's widgets already draw (parseReply + buildOutputCard). Before a final reply counts, it is parsed into
// typed blocks and each block is checked: valid JSON where the card needs it, the right shape (a table's rows match its
// columns, 2–5 choices, an event with a real start time, an absolute file path…), closed fences, and no markdown table.
// A reply that fails goes back to the model once with the exact problems (a finish gate); after that it is shown as is.
import 'dart:convert';

import '../widgets/output_cards.dart' show buildOutputCard;
import '../widgets/hark_cards.dart' show looseJson;
import '../widgets/reply_blocks.dart' show parseReply;
import '../services/choices.dart';

/// One typed block of a reply.
class HarkBlock {
  HarkBlock(this.type, this.data, {this.complete = true});

  /// text | summary | table | grid | links | choices | confirm | event | images | photos | file | page | template | draft |
  /// plan | chart | diagram | … (any card the app draws).
  final String type;
  final Map<String, Object?> data;
  final bool complete;

  Map<String, Object?> toJson() => {'type': type, ...data};

  /// The block back as the markdown the app renders.
  String toMarkdown() {
    switch (type) {
      case 'text':
        return '${data['text'] ?? ''}';
      case 'summary':
        final t = '${data['title'] ?? ''}'.trim();
        return '```summary\n${t.isEmpty ? '' : '# $t\n'}${data['markdown'] ?? ''}\n```';
      case 'file':
      case 'page':
        return '```$type\n${data['path'] ?? data['body'] ?? ''}\n```';
      default:
        final body = data.containsKey('body') ? '${data['body']}' : jsonEncode(Map.of(data)..remove('body'));
        return '```$type\n${body.trim()}\n```';
    }
  }
}

class ReplySchema {
  ReplySchema._();

  /// Cards whose body is JSON.
  static const jsonCards = {'table', 'grid', 'choices', 'confirm', 'event', 'links', 'plan', 'receipt', 'order', 'order_summary'};

  /// The JSON Schema of a reply (for docs, tests and a structured reply path).
  static const Map<String, Object?> jsonSchema = {
    'type': 'object',
    'required': ['blocks'],
    'properties': {
      'blocks': {
        'type': 'array',
        'items': {
          'oneOf': [
            {
              'type': 'object',
              'required': ['type', 'text'],
              'properties': {'type': {'const': 'text'}, 'text': {'type': 'string'}},
            },
            {
              'type': 'object',
              'required': ['type', 'title', 'markdown'],
              'properties': {'type': {'const': 'summary'}, 'title': {'type': 'string'}, 'markdown': {'type': 'string'}},
            },
            {
              'type': 'object',
              'required': ['type', 'columns', 'rows'],
              'properties': {
                'type': {'enum': ['table', 'grid']},
                'title': {'type': 'string'},
                'columns': {'type': 'array', 'minItems': 1, 'items': {'type': 'string'}},
                'rows': {'type': 'array', 'items': {'type': 'array', 'items': {'type': 'string'}}},
                'ornament': {'type': 'string'},
              },
            },
            {
              'type': 'object',
              'required': ['type', 'items'],
              'properties': {
                'type': {'const': 'links'},
                'items': {
                  'type': 'array',
                  'minItems': 1,
                  'items': {'type': 'object', 'required': ['url'], 'properties': {'title': {'type': 'string'}, 'url': {'type': 'string'}}},
                },
              },
            },
            {
              'type': 'object',
              'required': ['type', 'options'],
              'properties': {
                'type': {'const': 'choices'},
                'question': {'type': 'string'},
                'options': {'type': 'array', 'minItems': 1, 'maxItems': 6, 'items': {'type': 'string'}},
              },
            },
            {
              'type': 'object',
              'required': ['type', 'title', 'start'],
              'properties': {'type': {'const': 'event'}, 'title': {'type': 'string'}, 'start': {'type': 'string'}, 'end': {'type': 'string'}, 'place': {'type': 'string'}},
            },
            {
              'type': 'object',
              'required': ['type', 'path'],
              'properties': {'type': {'enum': ['file', 'page']}, 'path': {'type': 'string', 'pattern': '^/'}},
            },
            {
              'type': 'object',
              'required': ['type', 'body'],
              'properties': {'type': {'type': 'string'}, 'body': {'type': 'string'}},
            },
          ],
        },
      },
    },
  };

  static final _mdTable = RegExp(r'^\s*\|.*\|\s*$\n^\s*\|?\s*:?-{3,}', multiLine: true);
  static final _isoStart = RegExp(r'^\d{4}-\d{2}-\d{2}([T ]\d{2}:\d{2})?');

  /// Parses a reply into typed blocks.
  static List<HarkBlock> parse(String reply) {
    final out = <HarkBlock>[];
    for (final b in parseReply(reply)) {
      if (b.lang == null) {
        out.add(HarkBlock('text', {'text': b.text}));
        continue;
      }
      final body = b.text.trimRight();
      Map<String, Object?> data;
      switch (b.lang!) {
        case 'summary':
          final lines = body.trim().split('\n');
          final head = lines.isNotEmpty && lines.first.trim().startsWith('#') ? lines.first.replaceFirst(RegExp(r'^#+\s*'), '').trim() : '';
          data = {'title': head, 'markdown': (head.isEmpty ? lines : lines.skip(1)).join('\n').trim()};
        case 'file':
        case 'page':
          data = b.lang == 'file' ? {'path': body.trim().split('\n').first.trim()} : {'body': body};
        case 'table':
        case 'grid':
          data = _json(body, (j) => j is Map ? {'title': j['title'], 'columns': j['columns'], 'rows': j['rows'], 'ornament': j['ornament']} : null, body);
        case 'choices':
          // Every shape the card draws (Choices.parse): a list, {"question","options"}, labelled objects, plain lines.
          Object? j;
          try {
            j = looseJson(body);
          } catch (_) {
            j = body;
          }
          final opts = Choices.parse(j);
          data = opts.isEmpty ? {'body': body, '_invalid': true} : {'options': opts, if (Choices.question(j) != null) 'question': Choices.question(j)};
        case 'links':
          data = _json(body, (j) {
            final l = j is Map ? (j['links'] ?? j['items'] ?? [j]) : j;
            return l is List ? {'items': l} : null;
          }, body);
        case 'event':
          data = _json(body, (j) => j is Map ? {'title': j['title'], 'start': j['start'], 'end': j['end'], 'place': j['place']} : null, body);
        default:
          data = {'body': body};
      }
      out.add(HarkBlock(b.lang!, data, complete: b.complete));
    }
    return out;
  }

  static Map<String, Object?> _json(String body, Map<String, Object?>? Function(Object? j) shape, String raw) {
    try {
      return shape(looseJson(body)) ?? {'body': raw, '_invalid': true};
    } catch (_) {
      return {'body': raw, '_invalid': true};
    }
  }

  /// The problems in a reply, in plain words the model can act on. Empty = valid.
  static List<String> problems(String reply) {
    final out = <String>[];
    if (_mdTable.hasMatch(_outsideFences(reply))) {
      out.add('It has a markdown table (| a | b |). Use a ```table card with JSON {"title","columns":[...],"rows":[[...]]} instead.');
    }
    for (final b in parse(reply)) {
      if (b.type == 'text') continue;
      final name = '```${b.type} card';
      if (!b.complete) {
        out.add('The $name is not closed: end it with ``` on its own line.');
        continue;
      }
      if (b.data['_invalid'] == true) {
        out.add('The $name is not valid JSON${jsonCards.contains(b.type) ? '' : ' in the shape the card needs'}. Write valid JSON (double quotes, no comments, no trailing commas).');
        continue;
      }
      switch (b.type) {
        case 'table':
        case 'grid':
          final cols = b.data['columns'];
          final rows = b.data['rows'];
          if (cols is! List || cols.isEmpty) {
            out.add('The $name has no "columns".');
          } else if (rows is! List || rows.isEmpty) {
            out.add('The $name has no "rows".');
          } else {
            final bad = [for (var i = 0; i < rows.length; i++) if (rows[i] is List && (rows[i] as List).length != cols.length) i + 1];
            if (bad.isNotEmpty) out.add('In the $name, row${bad.length == 1 ? '' : 's'} ${bad.take(5).join(', ')} ha${bad.length == 1 ? 's' : 've'} a different number of cells than the ${cols.length} columns.');
          }
        case 'choices':
          final o = b.data['options'] as List? ?? const [];
          // More than Choices.max are trimmed when drawn (no second model call for that); fewer than two is no choice.
          if (o.length < Choices.min) out.add('The $name needs ${Choices.askFor} short answers (it has ${o.length}).');
          if (o.any((e) => '$e'.trim().isEmpty)) out.add('The $name has an empty answer.');
        case 'links':
          final l = b.data['items'] as List? ?? const [];
          final bad = l.where((e) => e is! Map || !'${e['url'] ?? ''}'.startsWith(RegExp(r'https?://'))).length;
          if (l.isEmpty) out.add('The $name has no links.');
          if (bad > 0) out.add('The $name has ${bad == 1 ? 'a link' : '$bad links'} without a full http(s) "url".');
        case 'event':
          if ('${b.data['title'] ?? ''}'.trim().isEmpty) out.add('The $name has no "title".');
          if (!_isoStart.hasMatch('${b.data['start'] ?? ''}')) out.add('The $name needs "start" as local time like 2026-10-30T19:00.');
        case 'file':
          final p = '${b.data['path'] ?? ''}';
          if (!p.startsWith('/')) out.add('The $name must hold the full path the tool returned (starting with /), not "$p".');
        case 'summary':
          if ('${b.data['title'] ?? ''}'.isEmpty) out.add('The $name should start with a "# Title" line.');
          if ('${b.data['markdown'] ?? ''}'.trim().isEmpty) out.add('The $name is empty.');
      }
      // Whatever the rules above say, the card must be drawable by the app's own widget.
      if (b.type != 'summary' && b.type != 'file' && b.type != 'page' && !_drawable(b)) {
        out.add('The app cannot draw the $name as written; check its shape against the card format.');
      }
    }
    return out.toSet().toList();
  }

  static bool _drawable(HarkBlock b) {
    try {
      final raw = b.data['body'];
      final body = raw is String ? raw : jsonEncode(Map.of(b.data)..remove('_invalid'));
      // For JSON cards rebuilt from data, give the widget the original shape.
      final src = switch (b.type) {
        'choices' => jsonEncode(b.data['options']),
        'links' => jsonEncode(b.data['items']),
        _ => body,
      };
      return buildOutputCard(b.type, src) != null;
    } catch (_) {
      return false;
    }
  }

  static String _outsideFences(String s) {
    final out = StringBuffer();
    var inside = false;
    for (final l in s.split('\n')) {
      if (RegExp(r'^\s{0,3}(```|~~~)').hasMatch(l)) {
        inside = !inside;
        continue;
      }
      if (!inside) out.writeln(l);
    }
    return out.toString();
  }

  /// Fixes what the app can fix by itself, so it never costs another model call (v1.13.101): a markdown table becomes
  /// a ```table card, and a card left open at the very end is closed. Everything else is left as written.
  static String repair(String reply) {
    var out = reply;
    if (_mdTable.hasMatch(_outsideFences(out))) out = _tablesToCards(out);
    final fences = RegExp(r'^\s{0,3}```', multiLine: true).allMatches(out).length;
    if (fences.isOdd) out = '${out.trimRight()}\n```';
    return out;
  }

  static final _row = RegExp(r'^\s*\|(.*)\|\s*$');
  static final _sep = RegExp(r'^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)*\|?\s*$');

  static String _tablesToCards(String text) {
    final lines = text.split('\n');
    final out = <String>[];
    var inside = false;
    for (var i = 0; i < lines.length; i++) {
      final l = lines[i];
      if (RegExp(r'^\s{0,3}(```|~~~)').hasMatch(l)) inside = !inside;
      if (!inside && _row.hasMatch(l) && i + 1 < lines.length && _sep.hasMatch(lines[i + 1])) {
        List<String> cells(String row) => _row.firstMatch(row)!.group(1)!.split('|').map((c) => c.trim().replaceAll(RegExp(r'\*\*'), '')).toList();
        final cols = cells(l);
        final rows = <List<String>>[];
        var k = i + 2;
        while (k < lines.length && _row.hasMatch(lines[k])) {
          final c = cells(lines[k]);
          while (c.length < cols.length) {
            c.add('');
          }
          rows.add(c.take(cols.length).toList());
          k++;
        }
        out
          ..add('```table')
          ..add(jsonEncode({'columns': cols, 'rows': rows}))
          ..add('```');
        i = k - 1;
        continue;
      }
      out.add(l);
    }
    return out.join('\n');
  }

  /// The note that sends an invalid reply back.
  static String fixNote(List<String> problems) => '# Your reply has formatting problems\n'
      '${problems.map((p) => '- $p').join('\n')}\n'
      'Write the same final reply again with these fixed (same content, valid cards). Do not mention this check.';

  /// The blocks as JSON (what the schema describes).
  static Map<String, Object?> toJson(String reply) => {'blocks': [for (final b in parse(reply)) b.toJson()]};

  /// Blocks (from JSON) back to the markdown the app renders.
  static String toMarkdown(Map<String, Object?> json) {
    final blocks = json['blocks'];
    if (blocks is! List) return '';
    return [
      for (final b in blocks)
        if (b is Map) HarkBlock('${b['type']}', Map<String, Object?>.from(b)..remove('type')).toMarkdown()
    ].join('\n\n');
  }
}
