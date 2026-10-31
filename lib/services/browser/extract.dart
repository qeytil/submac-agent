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

/// One page's answer in a browser_extract_many run.
class ExtractPage {
  const ExtractPage(this.url, {this.rows = const <Map<String, dynamic>>[], this.error});
  final String url;
  final List<Map<String, dynamic>> rows;
  final String? error;

  bool get ok => error == null;
}

/// Reads one page's raw answer; a failure is kept as a page, never thrown away silently.
ExtractPage parseExtractPage(String url, String raw) {
  dynamic j;
  try {
    j = jsonDecode(raw);
  } catch (_) {
    return ExtractPage(url, error: 'no readable answer');
  }
  if (j is! Map) return ExtractPage(url, error: 'no readable answer');
  if (j['err'] != null) return ExtractPage(url, error: '${j['err']}');
  final rows = j['rows'];
  if (rows is! List) return ExtractPage(url, error: 'no rows in the answer');
  return ExtractPage(url, rows: [
    for (final r in rows)
      if (r is Map) Map<String, dynamic>.from(r),
  ]);
}

/// A page name short enough for a table column: host and a little of the path.
String shortSource(String url) {
  var s = url.trim();
  s = s.replaceFirst(RegExp(r'^https?://'), '');
  if (s.startsWith('www.')) s = s.substring(4);
  if (s.endsWith('/')) s = s.substring(0, s.length - 1);
  return s.length > 48 ? '${s.substring(0, 48)}…' : s;
}

/// What browser_extract_many returns: every page's rows in ONE table, each row carrying the page it came from.
/// The same `source` value twice is dropped, and the table is capped, so eight pages cannot flood the chat.
String formatManyExtract(List<ExtractPage> pages, {int maxChars = 16000, int maxRows = 400}) {
  final good = pages.where((p) => p.ok).toList();
  final bad = pages.where((p) => !p.ok).toList();
  final merged = <Map<String, dynamic>>[];
  final seen = <String>{};
  for (final p in good) {
    final src = shortSource(p.url);
    for (final r in p.rows) {
      final row = <String, dynamic>{'source': src};
      for (final e in r.entries) {
        if (e.key == 'source') continue; // the page always wins, so a field cannot fake it
        row[e.key] = e.value;
      }
      if (!seen.add(jsonEncode(row))) continue;
      merged.add(row);
      if (merged.length >= maxRows) break;
    }
    if (merged.length >= maxRows) break;
  }
  if (merged.isEmpty) {
    final why = bad.isEmpty ? 'No items matched those selectors on any of the ${pages.length} pages.'
        : 'Nothing came back: ${bad.map((p) => '${shortSource(p.url)} (${p.error})').join('; ')}.';
    return '$why The pages that need scripts can be opened one by one with browser_open and read with browser_extract.';
  }
  var out = const JsonEncoder.withIndent('  ').convert(merged);
  if (out.length > maxChars) {
    out = '${out.substring(0, maxChars)}\n…(truncated at $maxChars of ${out.length} chars)';
  }
  final sb = StringBuffer()
    ..writeln('${merged.length} rows from ${good.length} page${good.length == 1 ? '' : 's'}. '
        'Show this to the user as a ```data card when it answers the task.');
  if (bad.isNotEmpty) {
    sb.writeln('Not read (${bad.length}): ${bad.map((p) => '${shortSource(p.url)} — ${p.error}').join('; ')}. '
        'Those pages build their content with scripts: open them with browser_open and extract one by one.');
  }
  sb.writeln();
  sb.write(out);
  return sb.toString();
}
