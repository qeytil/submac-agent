import 'dart:convert';

/// One data call the page made (its own API traffic, caught by the page script's ear).
/// This is what the site's own code receives — often the exact data, no scraping.
class NetCall {
  NetCall({required this.id, required this.url, required this.method, required this.status, this.ct = '', this.ms = 0, this.size = 0, this.body = ''});

  final int id;
  final String method;
  final String url;
  final int status;
  final String ct;
  final int ms;
  final int size;

  /// The response body (only for data calls, capped at 20000 chars by the page script).
  final String body;

  static NetCall fromJson(Map j) => NetCall(
        id: (j['id'] as num?)?.toInt() ?? 0,
        method: '${j['m'] ?? 'GET'}',
        url: '${j['url'] ?? ''}',
        status: (j['st'] as num?)?.toInt() ?? 0,
        ct: '${j['ct'] ?? ''}',
        ms: (j['ms'] as num?)?.toInt() ?? 0,
        size: (j['size'] as num?)?.toInt() ?? 0,
        body: '${j['body'] ?? ''}',
      );

  String get kind {
    final c = ct.toLowerCase();
    if (c.contains('json')) return 'json';
    if (c.contains('xml')) return 'xml';
    if (c.contains('csv')) return 'csv';
    return 'text';
  }

  String get kb => size >= 1024 ? '${(size / 1024).toStringAsFixed(1)}KB' : '${size}B';
}

/// The observe line: one cheap hint that the site's data layer is there to be read.
String dataLine(int calls) =>
    '$calls data calls on this page — browser_net lists them; browser_fetch re-calls one with this page\'s own session.';

/// The numbered list browser_net returns (no bodies; body comes one id at a time).
String formatNetList(List<NetCall> calls) {
  if (calls.isEmpty) return 'No data calls recorded on this page yet (the ear only hears calls made while this page is open).';
  final sb = StringBuffer();
  sb.writeln('${calls.length} data calls (newest last). browser_net with an id reads its body:');
  for (final c in calls) {
    final u = c.url.length > 120 ? '${c.url.substring(0, 120)}…' : c.url;
    sb.writeln('[${c.id}] ${c.method} $u → ${c.status} ${c.kind} ${c.kb}${c.body.isEmpty ? '' : ' (body ready)'}');
  }
  return sb.toString().trimRight();
}

/// What browser_net returns for one id: the call's body, capped for the model.
String formatNetBody(NetCall c) {
  final head = '${c.method} ${c.url} → ${c.status} (${c.kind}, ${c.kb}, ${c.ms}ms)';
  if (c.body.isEmpty) return '$head\n\nNo body was kept for this call (non-data response or too large).';
  final b = c.body.length > 14000 ? '${c.body.substring(0, 14000)}\n…(truncated at 14000 of ${c.body.length} chars)' : c.body;
  // Pretty-print JSON when it is one: the model reads structure far better than one long line.
  var out = b;
  if (c.kind == 'json') {
    try {
      final v = jsonDecode(b);
      const enc = JsonEncoder.withIndent('  ');
      final pretty = enc.convert(v);
      if (pretty.length <= 16000) out = pretty;
    } catch (_) {}
  }
  return '$head\n\n$out';
}

/// The response browser_fetch returns for the model.
String formatFetch({required String method, required String url, required int status, required String ct, required String body}) {
  final c = NetCall(id: 0, url: url, method: method, status: status, ct: ct, size: body.length, body: body);
  if (status == 0) return '$method $url → no answer (network error or blocked). Try the page itself instead.';
  final kind = c.kb;
  if (RegExp(r'image|video|audio|font|octet-stream|pdf|zip|gzip|compressed|msword|spreadsheet|presentation', caseSensitive: false).hasMatch(ct)) {
    return '$method $url → $status binary response ($kind, ${c.kb}). browser_download saves files like this.';
  }
  final b = body.length > 14000 ? '${body.substring(0, 14000)}\n…(truncated at 14000 of ${body.length} chars)' : body;
  return '$method $url → $status ($kind, ${c.kb})\n\n$b';
}
