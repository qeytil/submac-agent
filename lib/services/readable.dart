import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

/// Turns a web page into clean, readable text: the main article (not menus, cookie banners or footers),
/// with headings, lists and tables kept as simple markdown. Pure Dart, so it runs on the phone and in tests.
class Readable {
  static const _drop = 'script, style, noscript, svg, iframe, template, dialog, nav, footer, aside, form, button, select, '
      'input, textarea, canvas, video, audio, picture source, [role=navigation], [role=banner], [role=contentinfo], '
      '[role=dialog], [aria-hidden=true], [hidden]';

  static final _junk = RegExp(
      r'(^|[\s_-])(cookie|consent|gdpr|newsletter|subscribe|share|social|related|comment|advert|popup|modal|sidebar|breadcrumb|menu|footer|header-nav|skip-link)([\s_-]|$)',
      caseSensitive: false);

  /// The readable text of [html]. Starts with "Title: ..." when the page has a title.
  static String text(String html) {
    final doc = html_parser.parse(html);
    final title = doc.querySelector('title')?.text.trim() ?? '';
    final desc = doc.querySelector('meta[name=description]')?.attributes['content']?.trim() ?? '';
    for (final e in doc.querySelectorAll(_drop)) {
      e.remove();
    }
    for (final e in doc.querySelectorAll('[class], [id]').toList()) {
      final key = '${e.attributes['class'] ?? ''} ${e.attributes['id'] ?? ''}';
      if (_junk.hasMatch(key) && e.localName != 'body' && e.localName != 'html' && e.localName != 'main' && e.localName != 'article') {
        // Never drop a block that holds most of the page's text (some sites put "content sidebar" on the wrapper).
        if (e.text.length < 2000) e.remove();
      }
    }
    final body = doc.body;
    if (body == null) return title.isEmpty ? '' : 'Title: $title';
    final root = _mainBlock(body);
    final sb = StringBuffer();
    _render(root, sb);
    var out = sb
        .toString()
        .replaceAll(RegExp(r'[ \t\u00a0]+'), ' ')
        .replaceAll(RegExp(r' *\n *'), '\n')
        .replaceAll(RegExp(r'^-\s*$', multiLine: true), '')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
    if (out.length < 200 && desc.isNotEmpty && !out.contains(desc)) out = '$desc\n\n$out'.trim();
    return title.isEmpty ? out : 'Title: $title\n\n$out';
  }

  /// The element that holds the article: <article>/<main> when they carry most of the text, else the body.
  static dom.Element _mainBlock(dom.Element body) {
    final total = body.text.trim().length;
    dom.Element? best;
    var bestLen = 0;
    for (final e in body.querySelectorAll('article, main, [role=main], #content, #main, .content, .post, .entry-content, .article-body, .post-content')) {
      final l = e.text.trim().length;
      if (l > bestLen) {
        best = e;
        bestLen = l;
      }
    }
    if (best != null && bestLen >= 300 && bestLen >= total * 0.25) return best;
    return body;
  }

  static const _blocks = {
    'p', 'div', 'section', 'article', 'main', 'header', 'blockquote', 'figure', 'figcaption', 'address', 'dl', 'dt', 'dd', 'ul', 'ol', 'table', 'hr',
  };

  static void _render(dom.Node n, StringBuffer sb) {
    if (n is dom.Text) {
      sb.write(n.text.replaceAll(RegExp(r'\s+'), ' '));
      return;
    }
    if (n is! dom.Element) {
      for (final c in n.nodes) {
        _render(c, sb);
      }
      return;
    }
    final tag = n.localName ?? '';
    switch (tag) {
      case 'br':
        sb.write('\n');
        return;
      case 'h1':
      case 'h2':
      case 'h3':
      case 'h4':
      case 'h5':
      case 'h6':
        final t = n.text.replaceAll(RegExp(r'\s+'), ' ').trim();
        if (t.isNotEmpty) sb.write('\n\n${'#' * int.parse(tag.substring(1))} $t\n');
        return;
      case 'li':
        sb.write('\n- ');
        for (final c in n.nodes) {
          _render(c, sb);
        }
        return;
      case 'pre':
        sb.write('\n```\n${n.text.trimRight()}\n```\n');
        return;
      case 'tr':
        final cells = [
          for (final c in n.children)
            if (c.localName == 'td' || c.localName == 'th') c.text.replaceAll(RegExp(r'\s+'), ' ').trim(),
        ];
        if (cells.any((c) => c.isNotEmpty)) sb.write('\n| ${cells.join(' | ')} |');
        return;
      case 'img':
        final alt = n.attributes['alt']?.trim() ?? '';
        if (alt.length > 3) sb.write(' [image: $alt] ');
        return;
    }
    final block = _blocks.contains(tag);
    if (block) sb.write('\n');
    for (final c in n.nodes) {
      _render(c, sb);
    }
    if (block) sb.write('\n');
  }
}
