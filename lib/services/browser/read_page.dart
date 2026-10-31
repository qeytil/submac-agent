/// The readability pass of HTTP-first triage (P4, browser-godmode): an HTML document becomes the text a
/// reader needs, with no render and no packages. Pure functions, so the stripping is testable on its own.
library;

/// The document's text: scripts, styles and markup gone, block elements on their own lines, entities decoded.
String htmlToText(String html, {int max = 6000}) {
  var s = html;
  s = s.replaceAll(RegExp(r'<!--[\s\S]*?-->'), ' ');
  s = s.replaceAll(RegExp(r'<(script|style|noscript|template|svg|iframe)\b[^>]*>[\s\S]*?</\1>', caseSensitive: false), ' ');
  s = s.replaceAll(RegExp(r'<(br|/p|/div|/li|/h[1-6]|/tr|/section|/article|/header|/footer|/blockquote)\b[^>]*>', caseSensitive: false), '\n');
  s = s.replaceAll(RegExp(r'<[^>]+>'), ' ');
  s = _entities(s);
  s = s.replaceAll(RegExp(r'[ \t\r\f\v]+'), ' ');
  s = s.replaceAll(RegExp(r' *\n *'), '\n');
  s = s.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  return s.length > max ? '${s.substring(0, max)}…' : s;
}

const _named = {
  'amp': '&', 'lt': '<', 'gt': '>', 'quot': '"', 'apos': "'", 'nbsp': ' ', 'mdash': '—', 'ndash': '–',
  'hellip': '…', 'rsquo': '’', 'lsquo': '‘', 'ldquo': '“', 'rdquo': '”', 'euro': '€', 'pound': '£', 'copy': '©',
  'reg': '®', 'times': '×', 'bull': '•', 'middot': '·', 'deg': '°', 'laquo': '«', 'raquo': '»',
};

String _entities(String s) => s.replaceAllMapped(RegExp(r'&(#x?[0-9a-fA-F]+|[a-zA-Z]+);'), (m) {
      final whole = m.group(0)!;
      final name = m.group(1)!;
      final named = _named[name.toLowerCase()];
      if (named != null) return named;
      int? code;
      if (name.startsWith('#x') || name.startsWith('#X')) code = int.tryParse(name.substring(2), radix: 16);
      if (name.startsWith('#') && !name.startsWith('#x') && !name.startsWith('#X')) code = int.tryParse(name.substring(1));
      if (code != null && code > 0 && code < 0x110000) return String.fromCharCode(code);
      return whole;
    });

/// The page's <title>, as text.
String htmlTitle(String html) {
  final m = RegExp(r'<title[^>]*>([\s\S]*?)</title>', caseSensitive: false).firstMatch(html);
  return m == null ? '' : htmlToText(m.group(1)!, max: 200).replaceAll('\n', ' ').trim();
}
