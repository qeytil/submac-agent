import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../theme.dart';
import 'graph_card.dart';
import 'hark_cards.dart' show openLink;
import 'logo.dart';
import 'markdown_view.dart';
import 'motion.dart';
import '../ui/tokens.dart';

const _ua = 'SubMacAgent/1.7 (com.submac.agent; Android)';

/// Free, instant pictures from Wikipedia and Wikimedia Commons (public, no key, no image generation).
/// Order: the article's own lead picture, then a Wikipedia search, then a Commons file search.
class WikiImages {
  static final Map<String, Future<String?>> _cache = {};

  static Future<String?> find(String query, {String lang = 'en'}) {
    final q = query.trim();
    if (q.isEmpty) return Future.value(null);
    return _cache.putIfAbsent('$lang|${q.toLowerCase()}', () => _find(q, lang));
  }

  static Future<Map<String, dynamic>?> _json(String url) async {
    try {
      final r = await http.get(Uri.parse(url), headers: {'User-Agent': _ua, 'Accept': 'application/json'}).timeout(const Duration(seconds: 8));
      if (r.statusCode != 200) return null;
      final j = jsonDecode(r.body);
      return j is Map<String, dynamic> ? j : null;
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _find(String q, String lang) async {
    // 1. The article itself (follows redirects).
    final s = await _json('https://$lang.wikipedia.org/api/rest_v1/page/summary/${Uri.encodeComponent(q.replaceAll(' ', '_'))}');
    final thumb = (s?['thumbnail'] as Map?)?['source'];
    if (thumb is String && thumb.isNotEmpty) return _sized(thumb);
    // 2. Best Wikipedia search hits that have a picture.
    final w = await _json('https://$lang.wikipedia.org/w/api.php?action=query&format=json&generator=search'
        '&gsrsearch=${Uri.encodeQueryComponent(q)}&gsrlimit=5&prop=pageimages&piprop=thumbnail&pithumbsize=400');
    final pages = ((w?['query'] as Map?)?['pages'] as Map?)?.values.whereType<Map>().toList() ?? [];
    pages.sort((a, b) => ((a['index'] ?? 99) as num).compareTo((b['index'] ?? 99) as num));
    for (final pg in pages) {
      final src = (pg['thumbnail'] as Map?)?['source'];
      if (src is String && src.isNotEmpty) return src;
    }
    // 3. Wikimedia Commons files.
    final c = await _json('https://commons.wikimedia.org/w/api.php?action=query&format=json&generator=search&gsrnamespace=6'
        '&gsrsearch=${Uri.encodeQueryComponent(q)}&gsrlimit=4&prop=imageinfo&iiprop=url&iiurlwidth=400');
    final files = ((c?['query'] as Map?)?['pages'] as Map?)?.values.whereType<Map>().toList() ?? [];
    files.sort((a, b) => ((a['index'] ?? 99) as num).compareTo((b['index'] ?? 99) as num));
    for (final f in files) {
      final info = (f['imageinfo'] as List?)?.whereType<Map>().firstOrNull;
      final u = info?['thumburl'] ?? info?['url'];
      if (u is String && RegExp(r'\.(png|jpe?g|webp|gif|svg)', caseSensitive: false).hasMatch(u)) return u;
    }
    return null;
  }

  /// Ask for a crisper 400px render of the same thumbnail.
  static String _sized(String u) => u.replaceFirstMapped(RegExp(r'/(\d+)px-'), (m) => '/400px-');
}

/// A rounded picture tile for a row: a given picture, else Wikipedia's, else a calm serif initial.
class SmartThumb extends StatelessWidget {
  const SmartThumb({super.key, required this.title, this.image = '', this.wiki = '', this.size = 76});
  final String title;
  final String image;
  final String wiki;
  final double size;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    Widget frame(Widget child, {Color? bg}) => Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: bg ?? p.bubble,
            borderRadius: BorderRadius.circular(16),
          ),
          clipBehavior: Clip.antiAlias,
          child: child,
        );
    Widget initial() => frame(
          Stack(children: [
            Center(
              child: Text(title.isEmpty ? '·' : title.characters.first.toUpperCase(),
                  style: Brand.serif(size: size * 0.46, color: p.text)),
            ),
            const Positioned(right: 9, bottom: 9, child: RedDot(size: 6)),
          ]),
        );
    Widget net(String url) => frame(
          Image.network(
            url,
            headers: const {'User-Agent': _ua},
            fit: BoxFit.cover,
            width: size,
            height: size,
            frameBuilder: (_, child, frame, sync) => sync
                ? child
                : AnimatedOpacity(opacity: frame == null ? 0 : 1, duration: SubMotion.base, curve: SubMotion.settle, child: child),
            errorBuilder: (_, __, ___) => Center(child: Text(title.isEmpty ? '·' : title.characters.first.toUpperCase(), style: Brand.serif(size: size * 0.46, color: p.text))),
          ),
          bg: Colors.white,
        );
    if (image.startsWith('http')) return net(image);
    return FutureBuilder<String?>(
      future: WikiImages.find(wiki.isNotEmpty ? wiki : title),
      builder: (c, snap) {
        if (snap.connectionState != ConnectionState.done) return frame(const SizedBox.shrink());
        final u = snap.data;
        return u == null ? initial() : net(u);
      },
    );
  }
}

/// ```list {"title":"More things you can explore","items":[{"title","text","wiki","image","url","ask"}]}
/// Picture, bold title, two quiet lines, hairlines between. Tap opens the link or asks SubMac about it.
class ExploreListCard extends StatelessWidget {
  const ExploreListCard({super.key, required this.title, required this.items});
  final String title;
  final List<Map<String, dynamic>> items;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final state = context.read<AppState>();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (title.isNotEmpty)
          Padding(
            padding: const EdgeInsetsDirectional.only(bottom: 12, start: 2),
            child: Text(title, style: Brand.serif(size: 22, color: p.text, height: 1.2)),
          ),
        for (var i = 0; i < items.length && i < 12; i++) ...[
          if (i > 0) const SizedBox(height: Space.x1),
          FadeSlideIn(
            delay: SubMotion.staggerFor(i),
            child: Pressable(
              onTap: () {
                final it = items[i];
                final url = (it['url'] ?? it['link'] ?? '').toString();
                if (url.startsWith('http')) {
                  openLink(url);
                } else if (!state.busy) {
                  final ask = (it['ask'] ?? '').toString();
                  state.send(ask.isNotEmpty ? ask : 'Tell me more about ${it['title']}', []);
                }
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                  SmartThumb(
                    title: (items[i]['title'] ?? '').toString(),
                    image: (items[i]['image'] ?? '').toString(),
                    wiki: (items[i]['wiki'] ?? items[i]['wikipedia'] ?? '').toString(),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text((items[i]['title'] ?? '').toString(),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: p.text, fontSize: AppText.body, fontWeight: FontWeight.w700, height: 1.25)),
                      if ((items[i]['text'] ?? items[i]['note'] ?? '').toString().isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Text((items[i]['text'] ?? items[i]['note']).toString(),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: p.text.withValues(alpha: 0.78), fontSize: AppText.body, height: 1.4)),
                        ),
                    ]),
                  ),
                ]),
              ),
            ),
          ),
        ],
      ]),
    );
  }
}

/// ```sections {"title":"Different mathematical curves","sections":[{"title","text","graph":{...},"image","wiki"}]}
/// Lettered sub-cards (A, B, C...), each with an optional live graph tile or picture and a short note.
class SectionsCard extends StatelessWidget {
  const SectionsCard({super.key, required this.title, required this.sections});
  final String title;
  final List<Map<String, dynamic>> sections;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (title.isNotEmpty)
          Padding(
            padding: const EdgeInsetsDirectional.only(bottom: 10, start: 2),
            child: Text(title, style: Brand.serif(size: 22, color: p.text, height: 1.2)),
          ),
        Expandable(
          height: 470,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (var i = 0; i < sections.length && i < 26; i++)
              FadeSlideIn(
                delay: SubMotion.staggerFor(i),
                child: _Section(letter: String.fromCharCode(65 + i), data: sections[i]),
              ),
          ]),
        ),
      ]),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.letter, required this.data});
  final String letter;
  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final g = data['graph'] ?? data['plot'] ?? data['equation'] ?? data['plots'];
    GraphSpec? spec;
    if (g != null) {
      final gj = g is Map ? {...g, 'title': g['title'] ?? data['title']} : {'title': data['title'], 'plots': g is List ? g : [g]};
      spec = GraphSpec.fromJson(gj);
    }
    final text = (data['text'] ?? data['caption'] ?? data['note'] ?? '').toString();
    final img = (data['image'] ?? '').toString();
    final wiki = (data['wiki'] ?? '').toString();
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsetsDirectional.fromSTEB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: p.sheet,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
          Text(letter, style: Brand.serif(size: 20, color: p.accent)),
          const SizedBox(width: 10),
          Expanded(
            child: Text((data['title'] ?? '').toString(),
                style: TextStyle(color: p.text, fontSize: AppText.lead, fontWeight: FontWeight.w700, height: 1.3)),
          ),
        ]),
        if (spec != null) ...[
          const SizedBox(height: 12),
          GraphTile(spec),
        ] else if (img.isNotEmpty || wiki.isNotEmpty) ...[
          const SizedBox(height: 12),
          SmartThumb(title: (data['title'] ?? '').toString(), image: img, wiki: wiki, size: 120),
        ],
        if (text.isNotEmpty) ...[
          const SizedBox(height: 10),
          MarkdownView(text),
        ],
      ]),
    );
  }
}

/// Used by buildOutputCard for ```graph.
Widget? graphCardFrom(dynamic j) {
  final s = GraphSpec.fromJson(j);
  return s == null ? null : GraphCard(s);
}
