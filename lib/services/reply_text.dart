import 'dart:convert';

import 'package:flutter/painting.dart' show TextDirection;

/// Plain-text forms of a reply (PR-7 fix/cards-render): what Copy, Share, Select text and Read aloud get, the glyph
/// clean-up the app's fonts need, and the per-paragraph text direction.

/// Characters the bundled Geist fonts have no glyph for, which drew as "_" (CB-43): U+2010 hyphen and U+2011
/// non-breaking hyphen become "-", U+202F narrow no-break space becomes a plain space.
String cleanGlyphs(String s) {
  if (!_badGlyph.hasMatch(s)) return s;
  return s.replaceAll('\u2010', '-').replaceAll('\u2011', '-').replaceAll('\u202F', ' ');
}

final _badGlyph = RegExp('[\u2010\u2011\u202F]');

/// Card languages whose body is prose and is copied as it is.
const _proseCards = {'summary', 'draft', 'template'};

/// Every card language that is never copied as raw JSON.
const _cards = {
  'links', 'table', 'grid', 'images', 'photos', 'order', 'order_summary', 'plan', 'choices', 'receipt', 'confirm',
  'page', 'file', 'video', 'graph', 'list', 'sections', 'math', 'diagram', 'roadmap', 'timeline', 'flow', 'chart',
  'event', 'browser', 'qr',
};

/// The reply as a person would copy it: prose and the words of each card, no card JSON or markup (CB-8: list, links,
/// plan, sections, math, file and page cards were blanked, so Copy, Share and Read aloud lost them).
String replyPlain(String t) {
  var s = t.replaceAll(RegExp(r'<think(ing)?>[\s\S]*?(</think(ing)?>|$)', caseSensitive: false), '');
  s = s.replaceAllMapped(RegExp(r'```([^\s`]*)[^\n`]*\n([\s\S]*?)```'), (m) {
    final lang = (m.group(1) ?? '').toLowerCase();
    if (_proseCards.contains(lang)) return m.group(2)!.trim();
    if (!_cards.contains(lang)) return m.group(0)!; // a code block stays a code block
    return cardPlainText(lang, m.group(2)!);
  });
  s = s.replaceAll(RegExp(r'^\s*---\s*$', multiLine: true), '').replaceAll('**', '');
  return cleanGlyphs(s.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim());
}

/// One card as plain text: list, plan and sections one item per line; links "title — url"; math the TeX; file and
/// page the file's name; table and grid as rows; choices (and other action cards) dropped.
String cardPlainText(String lang, String body) {
  final b = body.trim();
  switch (lang) {
    case 'choices':
    case 'confirm':
    case 'browser':
      return '';
    case 'math':
      return b;
    case 'file':
    case 'video':
      final first = b.split('\n').first.trim();
      return first.split('/').last;
    case 'page':
      // A page card holds a path or the page's HTML: the name, or the page's <title>.
      if (b.startsWith('<')) {
        final title = RegExp(r'<title[^>]*>([\s\S]*?)</title>', caseSensitive: false).firstMatch(b)?.group(1)?.trim();
        return title ?? '';
      }
      return b.split('\n').first.trim().split('/').last;
    case 'table':
    case 'grid':
      return _tableText(b);
  }
  final j = _json(b);
  if (j == null) return '';
  switch (lang) {
    case 'links':
      var list = j;
      if (list is Map) list = list['links'] ?? list['items'] ?? [list];
      if (list is! List) return '';
      return [
        for (final e in list)
          if (e is Map)
            [_s(e['title'] ?? e['name']), _s(e['url'] ?? e['href'] ?? e['link'])].where((x) => x.isNotEmpty).join(' — ')
          else if (e != null)
            '$e'
      ].where((l) => l.isNotEmpty).join('\n');
    case 'plan':
      final steps = j is Map ? j['steps'] : j;
      final title = j is Map ? _s(j['title']) : '';
      return [if (title.isNotEmpty) title, if (steps is List) for (final s in steps) _item(s)].where((l) => l.isNotEmpty).join('\n');
    case 'list':
      final items = j is Map ? (j['items'] ?? j['rows'] ?? j['list']) : j;
      final title = j is Map ? _s(j['title']) : '';
      return [if (title.isNotEmpty) title, if (items is List) for (final e in items) _item(e)].where((l) => l.isNotEmpty).join('\n');
    case 'sections':
      final secs = j is Map ? (j['sections'] ?? j['items']) : j;
      final title = j is Map ? _s(j['title']) : '';
      final out = <String>[if (title.isNotEmpty) title];
      if (secs is List) {
        for (final e in secs) {
          if (e is Map) {
            final head = _s(e['title'] ?? e['heading'] ?? e['name']);
            final text = _s(e['body'] ?? e['text'] ?? e['summary'] ?? e['content']);
            if (head.isNotEmpty) out.add(head);
            if (text.isNotEmpty) out.add(text);
            final bullets = e['items'] ?? e['bullets'] ?? e['points'];
            if (bullets is List) out.addAll([for (final x in bullets) _item(x)].where((l) => l.isNotEmpty));
          } else if (e != null) {
            out.add('$e');
          }
        }
      }
      return out.join('\n');
    case 'receipt':
      return j is Map ? [_s(j['title']), _s(j['detail'])].where((x) => x.isNotEmpty).join('\n') : '';
    case 'event':
      return j is Map ? [_s(j['title']), _s(j['when'] ?? j['start']), _s(j['where'] ?? j['location'])].where((x) => x.isNotEmpty).join('\n') : '';
    case 'diagram':
    case 'roadmap':
    case 'timeline':
    case 'flow':
    case 'chart':
    case 'graph':
      final items = j is Map ? (j['items'] ?? j['steps'] ?? j['nodes'] ?? j['stages']) : j;
      final title = j is Map ? _s(j['title']) : '';
      return [if (title.isNotEmpty) title, if (items is List) for (final e in items) _item(e)].where((l) => l.isNotEmpty).join('\n');
  }
  return '';
}

Object? _json(String b) {
  try {
    return jsonDecode(b);
  } catch (_) {
    final s = b.indexOf(RegExp(r'[\[{]'));
    final e = b.lastIndexOf(RegExp(r'[\]}]'));
    if (s >= 0 && e > s) {
      try {
        return jsonDecode(b.substring(s, e + 1));
      } catch (_) {}
    }
  }
  return null;
}

String _s(Object? v) => v == null ? '' : '$v'.trim();

/// One list item as a line: a string as it is, an object as its title (and its subtitle or detail after a dash).
String _item(Object? e) {
  if (e == null) return '';
  if (e is Map) {
    final title = _s(e['title'] ?? e['name'] ?? e['label'] ?? e['text'] ?? e['step']);
    final more = _s(e['subtitle'] ?? e['detail'] ?? e['description'] ?? e['body'] ?? e['when']);
    return [title, more].where((x) => x.isNotEmpty).join(' — ');
  }
  return '$e'.trim();
}

/// A table card copied as plain rows, so Copy and Share never lose the numbers.
String _tableText(String json) {
  final d = _json(json);
  if (d is! Map) return '';
  final out = <String>[];
  if (d['title'] != null && '${d['title']}'.trim().isNotEmpty) out.add('${d['title']}');
  final cols = d['columns'];
  if (cols is List) out.add(cols.join(' | '));
  final rows = d['rows'];
  if (rows is List) {
    for (final r in rows) {
      out.add(r is List ? r.join(' | ') : r is Map ? r.values.join(' | ') : '$r');
    }
  }
  if (d['ornament'] != null && '${d['ornament']}'.trim().isNotEmpty) out.add('${d['ornament']}');
  return out.join('\n');
}

bool _rtlRune(int r) => (r >= 0x0590 && r <= 0x08FF) || (r >= 0xFB1D && r <= 0xFDFF) || (r >= 0xFE70 && r <= 0xFEFF);
bool _ltrRune(int r) => (r >= 0x41 && r <= 0x5A) || (r >= 0x61 && r <= 0x7A) || (r >= 0xC0 && r <= 0x24F);

/// Right-to-left for text that is mostly Arabic script (Arabic, Persian, Urdu), left-to-right otherwise (Somali,
/// English...). The majority of strong letters decides, so a Somali reply that opens with "السلام عليكم" stays
/// left-to-right and an Arabic reply that opens with a brand name ("iPhone 16 …") stays right-to-left (CB-9). A tie goes
/// to the first strong letter.
TextDirection majorityDir(String t) {
  // Launch hardening M-1: code, links and paths are not the reply's language. An Arabic answer with a code block or a
  // long link counted every Latin letter in them and turned the whole bubble left-to-right.
  if (t.contains('`') || t.contains('http') || t.contains('www.')) {
    final prose = t
        .replaceAll(RegExp(r'```[\s\S]*?(```|$)'), ' ')
        .replaceAll(RegExp(r'`[^`\n]*`'), ' ')
        .replaceAll(RegExp(r'\]\([^)\s]*\)'), ']')
        .replaceAll(RegExp(r'https?://\S+|www\.\S+'), ' ');
    if (prose.runes.any((r) => _rtlRune(r) || _ltrRune(r))) return _majority(prose);
  }
  return _majority(t);
}

TextDirection _majority(String t) {
  var rtl = 0, ltr = 0;
  TextDirection? first;
  for (final r in t.runes) {
    if (_rtlRune(r)) {
      rtl++;
      first ??= TextDirection.rtl;
    } else if (_ltrRune(r)) {
      ltr++;
      first ??= TextDirection.ltr;
    }
  }
  if (rtl == ltr) return first ?? TextDirection.ltr;
  return rtl > ltr ? TextDirection.rtl : TextDirection.ltr;
}

/// The language of a piece of text for the phone's voice: 'ar' for mostly Arabic script, 'so' for Somali, else 'en'.
String speechLang(String t) {
  if (majorityDir(t) == TextDirection.rtl) return 'ar';
  final words = RegExp(r"[a-zA-Z']+").allMatches(t.toLowerCase()).map((m) => m[0]!).toList();
  if (words.isEmpty) return 'en';
  var so = 0;
  for (final w in words) {
    if (_somaliWords.contains(w)) so++;
  }
  // Somali's double vowels (aa, ee, oo, uu) and "dh"/"kh" are common; a few marker words are enough.
  final doubled = RegExp(r'(aa|ee|ii|oo|uu)').allMatches(t.toLowerCase()).length;
  return (so >= 2 || (so >= 1 && doubled >= 3) || (words.length >= 6 && doubled * 3 >= words.length)) ? 'so' : 'en';
}

const _somaliWords = {
  'waa', 'oo', 'iyo', 'ka', 'ku', 'u', 'la', 'ee', 'aan', 'ayaa', 'ayuu', 'ayay', 'waxaa', 'waxay', 'wuxuu', 'maxaa',
  'maanta', 'haa', 'maya', 'mahadsanid', 'fadlan', 'sidee', 'halkan', 'kuu', 'kale', 'badan', 'waan', 'inaan', 'ah',
};

/// Read-aloud text in pieces the phone's voice accepts (Android's limit is about 4,000 characters), split at a
/// paragraph, then a sentence, then a space, never inside a word. Each piece carries its language (CB-28).
List<(String, String)> speechChunks(String text, {int max = 3900}) {
  final out = <(String, String)>[];
  void add(String s) {
    final t = s.trim();
    if (t.isNotEmpty) out.add((t, speechLang(t)));
  }

  for (final para in text.split(RegExp(r'\n\s*\n'))) {
    var p = para.trim();
    while (p.length > max) {
      var cut = p.lastIndexOf(RegExp(r'[.!?؟。]\s'), max);
      if (cut < max ~/ 2) cut = p.lastIndexOf(' ', max);
      if (cut <= 0) cut = max - 1;
      add(p.substring(0, cut + 1));
      p = p.substring(cut + 1).trim();
    }
    add(p);
  }
  // Join neighbours of the same language back up to the limit, so the voice doesn't pause at every paragraph.
  final merged = <(String, String)>[];
  for (final c in out) {
    if (merged.isNotEmpty && merged.last.$2 == c.$2 && merged.last.$1.length + c.$1.length + 2 <= max) {
      merged[merged.length - 1] = ('${merged.last.$1}\n\n${c.$1}', c.$2);
    } else {
      merged.add(c);
    }
  }
  return merged;
}
