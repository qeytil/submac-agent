import 'dart:convert';

/// Formatters for the schema ear (browser_schema) and the extract walker (browser_extract):
/// the site's own structured data — JSON-LD, app state, OpenGraph — and one-call row extraction.

/// What browser_schema returns with no arguments: the small index of what the page carries.
String formatSchemaIndex(String raw) {
  Map j;
  try {
    final v = jsonDecode(raw);
    if (v is! Map) return 'Error: could not read the page\'s structured data.';
    j = v;
  } catch (_) {
    return 'Error: could not read the page\'s structured data.';
  }
  final items = j['items'];
  if (items is! List || items.isEmpty) {
    return 'No structured data on this page (no JSON-LD, no app state). '
        'browser_extract can still walk the visible items with CSS selectors.';
  }
  final sb = StringBuffer();
  sb.writeln('${items.length} structured data blocks (browser_schema with an index reads one in full):');
  for (final e in items) {
    if (e is! Map) continue;
    sb.writeln('[${e['i']}] ${e['kind'] == 'state' ? 'app state' : 'JSON-LD'} ${e['name']} (${e['kb']})');
  }
  final og = (j['og'] as num?)?.toInt() ?? 0;
  if (og > 0) sb.writeln('OpenGraph/Twitter metas: $og');
  return sb.toString().trimRight();
}

/// What browser_schema returns with an index: one block in full, JSON pretty-printed when it parses.
String formatSchemaOpen(String raw) {
  Map j;
  try {
    final v = jsonDecode(raw);
    if (v is! Map) return 'Error: could not read that block.';
    j = v;
  } catch (_) {
    return 'Error: could not read that block.';
  }
  if (j['err'] == 'gone') return 'That index is gone (the page changed). List again with browser_schema.';
  final text = '${j['text'] ?? ''}';
  var out = text;
  if (text.isNotEmpty) {
    try {
      final pretty = const JsonEncoder.withIndent('  ').convert(jsonDecode(text));
      if (pretty.length <= 16000) out = pretty;
    } catch (_) {}
  }
  final head = '[${j['i']}] ${j['kind'] == 'state' ? 'app state' : 'JSON-LD'} ${j['name']} (${j['kb']})';
  return out.isEmpty ? '$head\n\n(empty block)' : '$head\n\n$out';
}

/// What browser_extract returns: every matching row as JSON — show it to the user as a ```data card.
String formatExtract(String raw, {int maxChars = 14000}) {
  dynamic j;
  try {
    j = jsonDecode(raw);
  } catch (_) {
    return 'Error: could not read the extracted rows.';
  }
  if (j is Map && j['err'] != null) return 'Error: ${j['err']}.';
  if (j is! Map || j['rows'] is! List) return 'Error: could not read the extracted rows.';
  final rows = j['rows'] as List;
  if (rows.isEmpty) return 'No items matched those selectors. Re-check the page structure (browser_read or a screenshot helps).';
  var out = const JsonEncoder.withIndent('  ').convert(j);
  if (out.length > maxChars) {
    out = '${out.substring(0, maxChars)}\n…(truncated at $maxChars of ${out.length} chars)';
  }
  return '${rows.length} rows${(j['n'] as num?)?.toInt() != rows.length ? ' (of ${(j['n'] as num?)?.toInt() ?? rows.length} on the page)' : ''}. '
      'Show this to the user as a ```data card when it answers the task.\n\n$out';
}
