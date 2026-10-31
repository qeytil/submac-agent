import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../theme.dart';
import 'motion.dart';
import 'hark_cards.dart';
import 'chat_extras.dart' show ChoiceRows;
import '../screens/preview_screen.dart';
import 'sub_icon.dart';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../services/media_store.dart';
import '../services/choices.dart';
import '../models.dart' show ChatMessage;
import '../services/bots.dart' show botWakeMark;
import '../services/tools.dart';
import '../services/system_bridge.dart';
import 'audio_card.dart';
import 'save_sheet.dart';
import 'diagram_card.dart';
import 'math_text.dart';
import 'rich_cards.dart';
import 'package:path_provider/path_provider.dart';
import '../ui/tokens.dart';
import 'chat/blocks.dart';
import 'chat/document_tile.dart';
import 'chat/entrance.dart';
import 'chat/message_actions.dart';
import 'media_view.dart';
import 'media_lightbox.dart';
import 'hark_style.dart';
import 'browser_card.dart' show BrowserResultCard;
import 'visual_card.dart';
import '../ui/i18n.dart';
import '../services/reply_text.dart' show cleanGlyphs;
export 'hark_style.dart';

const cardLanguages = {
  'summary', 'draft', 'links', 'plan', 'choices', 'file',
  'table', 'photos', 'images', 'receipt', 'confirm',
  'template', 'order', 'order_summary', 'page', 'video', 'grid', 'qr',
  'graph', 'list', 'sections', 'math',
  'diagram', 'roadmap', 'timeline', 'flow', 'chart', 'event', 'browser',
  'visual',
  'data',
};

/// The card frame, for cards defined in other files.
Widget cardShell(BuildContext context,
        {String? kicker, required Widget child, List<Widget> actions = const [], bool collapse = true}) =>
    _Card(kicker: kicker, actions: actions, collapse: collapse, child: child);

Widget cardAction(BuildContext context, String label, VoidCallback onTap) => _CardAction(label, onTap);

/// Plain label for the placeholder while a card is being written.
String cardKicker(String lang) {
  switch (lang) {
    case 'summary':
      return 'Summary';
    case 'draft':
      return 'Draft';
    case 'links':
      return 'Links';
    case 'plan':
      return 'Plan';
    case 'table':
      return 'Table';
    case 'photos':
    case 'images':
      return 'Pictures';
    case 'receipt':
      return 'Done';
    case 'confirm':
      return 'Needs your OK';
    case 'template':
      return 'Draft';
    case 'order':
    case 'order_summary':
      return 'Order';
    case 'page':
      return 'Page';
    case 'event':
      return 'Event';
    case 'video':
      return 'Video';
    case 'grid':
      return 'Options';
    case 'qr':
      return 'QR code';
    case 'choices':
      return 'Options';
    case 'graph':
      return 'Graph';
    case 'list':
      return 'Explore';
    case 'sections':
      return 'Overview';
    case 'math':
      return 'Formula';
    case 'diagram':
    case 'flow':
    case 'chart':
      return 'Diagram';
    case 'roadmap':
    case 'timeline':
      return 'Roadmap';
    case 'visual':
      return 'Visual';
    case 'data':
      return 'Data';
  }
  return 'Preparing';
}

/// Builds a structured card for a special fenced block, or null to fall back to a code block. [owner] is the id of the
/// message the card sits in (a choices card works out its own status from that message on, CB-5).
Widget? buildOutputCard(String language, String body, {String? owner}) {
  body = cleanGlyphs(body); // titles and items drew U+2011 / U+202F as "_" (CB-43)
  try {
    switch (language) {
      case 'summary':
        return SummaryCard(body);
      case 'graph':
        final t = body.trim();
        return graphCardFrom(t.startsWith('{') || t.startsWith('[') ? looseJson(t) : t.split('\n').where((l) => l.trim().isNotEmpty).toList());
      case 'diagram':
      case 'roadmap':
      case 'timeline':
      case 'flow':
      case 'chart':
        final j = looseJson(body);
        if (j is Map) return diagramCardFrom(language == 'diagram' || j['type'] != null ? j : {...j, 'type': language});
        if (j is List) return diagramCardFrom({'type': language == 'diagram' ? 'steps' : language, 'items': j});
        return null;
      case 'visual':
        return VisualCard.isSvg(body) ? VisualCard(body) : null;
      case 'math':
        return Builder(
          builder: (c) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Center(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: MathText(body.trim(), size: 20, display: true),
              ),
            ),
          ),
        );
      case 'list':
        final j = looseJson(body);
        final items = j is Map ? (j['items'] ?? j['rows'] ?? j['list']) : j;
        if (items is! List) return null;
        return ExploreListCard(
          title: j is Map ? (j['title'] ?? '').toString() : '',
          items: [for (final e in items) if (e is Map) Map<String, dynamic>.from(e) else if (e != null) {'title': e.toString()}],
        );
      case 'sections':
        final j = looseJson(body);
        final secs = j is Map ? (j['sections'] ?? j['items']) : j;
        if (secs is! List) return null;
        return SectionsCard(
          title: j is Map ? (j['title'] ?? '').toString() : '',
          sections: [for (final e in secs) if (e is Map) Map<String, dynamic>.from(e)],
        );
      case 'draft':
      case 'template':
        return DraftCard(body);
      case 'order':
      case 'order_summary':
        final j = looseJson(body);
        if (j is! Map) return null;
        return OrderCard(Map<String, dynamic>.from(j));
      case 'page':
        return PageCard(body);
      case 'browser':
        return BrowserResultCard.fromBody(body);
      case 'event':
        final j = looseJson(body);
        final e = j is Map ? CalendarEvent.fromJson(j) : null;
        return e == null ? null : CalendarCard(event: e);
      case 'video':
        return MediaCard(body.trim().split('\n').first.trim());
      case 'links':
        var list = looseJson(body);
        if (list is Map) list = list['links'] ?? list['items'] ?? [list];
        if (list is! List) return null;
        return LinksCard([for (final e in list) if (e is Map) Map<String, dynamic>.from(e)]);
      case 'plan':
        final j = looseJson(body);
        if (j is Map) {
          return PlanCard(
            title: (j['title'] ?? 'Plan').toString(),
            steps: [for (final s in (j['steps'] as List? ?? const [])) s.toString()],
          );
        }
        if (j is List) return PlanCard(title: 'Plan', steps: [for (final s in j) s.toString()]);
        return null;
      case 'choices':
        // Any shape a model writes (a list, {"question","options"}, objects with labels, plain lines): see Choices.
        Object? j;
        try {
          j = looseJson(body);
        } catch (_) {
          j = body;
        }
        final opts = Choices.parse(j);
        if (opts.length < Choices.min) return null;
        return ChoicesCard(opts, question: Choices.question(j), owner: owner);
      case 'file':
        final path = AgentTools.cardPath(body.trim().split('\n').first.trim());
        if (RegExp(r'\.wav$', caseSensitive: false).hasMatch(path)) return AudioCard(path);
        if (RegExp(r'\.(mp4|webm|mov|m4v|3gp)$', caseSensitive: false).hasMatch(path)) return MediaCard(path);
        if (RegExp(r'\.html?$', caseSensitive: false).hasMatch(path)) return PageCard(path);
        return FileCard(path);
      case 'table':
      case 'grid':
        final j = looseJson(body);
        if (j is! Map) return null;
        final cols = [for (final c in (j['columns'] as List? ?? const [])) c.toString()];
        final rws = fixRowLinks([
          for (final r in (j['rows'] as List? ?? const []))
            if (r is List) [for (final c in r) c?.toString() ?? ''] else if (r is Map) [for (final v in r.values) v?.toString() ?? '']
        ]);
        if (language == 'grid' || cols.any((c) => const {'photo', 'image', 'picture'}.contains(c.toLowerCase().trim()))) {
          return ProductGridCard(
              title: (j['title'] ?? '').toString(), columns: cols, rows: rws, ornament: (j['ornament'] ?? '').toString());
        }
        return TableCard(
          ornament: (j['ornament'] ?? '').toString(),
          title: (j['title'] ?? '').toString(),
          columns: cols,
          rows: rws,
          pick: j['pick'] == true,
        );
      case 'data':
        return dataCardFrom(body);
      case 'photos':
      case 'images':
        dynamic j;
        try {
          j = looseJson(body);
        } catch (_) {}
        // Accept a list, {"items":[...]}, one {"url":...} or plain URL lines.
        dynamic list = j is Map ? (j['items'] ?? j['images'] ?? j['photos'] ?? (j['url'] != null ? [j] : null)) : j;
        if (j == null || j is String) {
          list = [for (final l in body.split('\n')) if (l.trim().startsWith('http') || l.trim().startsWith('/')) l.trim()];
        }
        if (list is! List || list.isEmpty) return null;
        final items = <PictureItem>[
          for (final e in list)
            if (e is String)
              PictureItem(e, '')
            else if (e is Map)
              PictureItem((e['url'] ?? e['path'] ?? e['src'] ?? '').toString(), (e['caption'] ?? e['title'] ?? '').toString())
        ].where((e) => e.src.isNotEmpty).toList();
        if (items.isEmpty) return null;
        return language == 'photos' ? PhotoGridCard(items) : ImageStackCard(items);
      case 'qr':
        final t = body.trim();
        dynamic j;
        try {
          j = looseJson(t);
        } catch (_) {}
        final data = j is Map ? (j['data'] ?? j['url'] ?? j['text'] ?? '').toString() : t.split('\n').first.trim();
        if (data.isEmpty) return null;
        return QrCard(data: data, title: j is Map ? (j['title'] ?? '').toString() : '');
      case 'receipt':
        final j = looseJson(body);
        if (j is! Map) return null;
        return ReceiptCard(
          title: (j['title'] ?? 'Done').toString(),
          detail: (j['detail'] ?? '').toString(),
          undo: (j['undo'] ?? '').toString(),
        );
      case 'confirm':
        final j = looseJson(body);
        if (j is! Map) return null;
        return ConfirmCard(
          title: (j['title'] ?? j['question'] ?? 'Shall I go ahead?').toString(),
          body: (j['body'] ?? '').toString(),
          confirm: (j['confirm'] ?? 'Yes, go ahead').toString(),
          cancel: (j['cancel'] ?? 'Not now').toString(),
        );
    }
  } catch (_) {
    return null; // Still streaming or malformed: show as plain code until it's complete.
  }
  return null;
}

/// A ```data fence: extracted rows as the SubMac table card. Accepts what browser_extract returns
/// (a JSON array of objects — columns from the first row's keys), a table-shaped map
/// ({"columns": [...], "rows": [[...]]}), or plain CSV. Null falls back to a code block.
TableCard? dataCardFrom(String body) {
  final t = body.trim();
  if (t.isEmpty) return null;
  dynamic j;
  try {
    j = looseJson(t);
  } catch (_) {}
  List<String> cols;
  List<List<String>> rows;
  if (j is List && j.isNotEmpty && j.first is Map) {
    cols = [for (final k in (j.first as Map).keys) k.toString()];
    rows = [for (final r in j) if (r is Map) [for (final c in cols) cellOf(r[c])]];
  } else if (j is Map && j['columns'] is List && j['rows'] is List) {
    cols = [for (final c in (j['columns'] as List)) c.toString()];
    rows = [for (final r in (j['rows'] as List)) if (r is List) [for (final c in r) cellOf(c)]];
  } else {
    // Plain CSV: a header line with commas, then rows.
    final lines = t.split('\n').where((l) => l.trim().isNotEmpty).toList();
    if (lines.length < 2 || !lines.first.contains(',')) return null;
    cols = [for (final c in lines.first.split(',')) c.trim()];
    rows = [for (final l in lines.skip(1)) [for (final c in l.split(',')) c.trim()]];
  }
  if (cols.isEmpty || rows.isEmpty) return null;
  return TableCard(ornament: '', title: '', columns: cols, rows: fixRowLinks(rows), pick: false);
}

String cellOf(Object? v) => v == null ? '' : v.toString();

/// The frame every output shares, now without a frame: a quiet label, the content, and its actions
/// (Copy, Open, Share...) kept out of sight until you hold the output. No fill, no border, no shadow; air
/// around it (see BlockSpacing) is what sets it apart.
class _Card extends StatefulWidget {
  final String? kicker;
  final Widget child;
  final List<Widget> actions;
  /// Long content stays folded under "Show more" until the user opens it.
  final bool collapse;
  final double foldHeight;
  const _Card({this.kicker, required this.child, this.actions = const [], this.collapse = true, this.foldHeight = 210});

  @override
  State<_Card> createState() => _CardState();
}

class _CardState extends State<_Card> {
  bool _actions = false;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final hasActions = widget.actions.isNotEmpty;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onLongPress: hasActions
          ? () {
              setState(() => _actions = !_actions);
            }
          : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Space.x1),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.kicker != null) BlockLabel(widget.kicker!),
            widget.collapse ? Expandable(height: widget.foldHeight, fadeColor: p.bg, child: widget.child) : widget.child,
            if (hasActions)
              AnimatedSize(
                duration: LuxMotion.base,
                curve: LuxMotion.ease,
                alignment: AlignmentDirectional.topStart,
                child: _actions
                    ? Entrance(
                        child: Padding(
                          padding: const EdgeInsets.only(top: Space.x1),
                          child: Wrap(children: widget.actions),
                        ),
                      )
                    : const SizedBox(width: double.infinity),
              ),
          ],
        ),
      ),
    );
  }
}

class _CardAction extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _CardAction(this.label, this.onTap);

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return TextButton(
      style: TextButton.styleFrom(
        foregroundColor: p.muted,
        textStyle: const TextStyle(fontSize: AppText.meta, fontWeight: FontWeight.w500),
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: Space.x3),
      ),
      onPressed: () {
        onTap();
      },
      child: Text(label),
    );
  }
}

void _copy(BuildContext context, String text) {
  Clipboard.setData(ClipboardData(text: text));
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Copied'))));
}

/// Links. Two or three become Hark's fanned deck (small cards with the page's picture, title and source, slightly
/// turned and overlapping, the middle one on top); more become quiet rows on the card fill. A tap opens the page.
class LinksCard extends StatelessWidget {
  final List<Map<String, dynamic>> links;
  final String? kicker;
  const LinksCard(this.links, {super.key, this.kicker});

  @override
  Widget build(BuildContext context) {
    if (links.length >= 2 && links.length <= 3 && links.every((l) => '${l['url'] ?? ''}'.startsWith('http'))) {
      return LinkDeck(links: links);
    }
    return HarkSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (kicker != null) ...[HarkTitleRow(title: kicker!), const HarkHairline()],
          for (var i = 0; i < links.length; i++) ...[
            if (i > 0) const SizedBox(height: Space.x3),
            _LinkRow(link: links[i], richImage: i < 5),
          ],
        ],
      ),
    );
  }
}

/// Hark's fanned deck of 2-3 link cards.
class LinkDeck extends StatelessWidget {
  const LinkDeck({super.key, required this.links});
  final List<Map<String, dynamic>> links;

  static const _turns = [-4.0, 0.0, 5.0];

  @override
  Widget build(BuildContext context) {
    final n = links.length;
    // Draw order: the sides first, the middle (index 1) last so it sits on top.
    final order = n == 3 ? [0, 2, 1] : [0, 1];
    return LayoutBuilder(builder: (context, c) {
      final col = c.maxWidth.isFinite ? c.maxWidth : 360.0;
      final w = (col * 0.52).clamp(150.0, 210.0);
      final h = w * 1.05;
      final step = n <= 1 ? 0.0 : (col - w - Space.x2) / (n - 1);
      return SizedBox(
        height: h + Space.x8 + Space.x4,
        width: col,
        child: Stack(clipBehavior: Clip.none, children: [
          for (final i in order)
            PositionedDirectional(
              start: Space.x1 + step * i,
              top: (n == 3 && i == 1) ? 0 : Space.x8,
              width: w,
              height: h,
              child: Entrance(
                delay: Entrance.staggerFor(i),
                child: Transform.rotate(
                  angle: _turns[n == 2 ? (i == 0 ? 0 : 2) : i] * 3.14159265 / 180,
                  child: _DeckCard(link: links[i]),
                ),
              ),
            ),
        ]),
      );
    });
  }
}

class _DeckCard extends StatelessWidget {
  const _DeckCard({required this.link});
  final Map<String, dynamic> link;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final url = '${link['url'] ?? ''}';
    final host = (Uri.tryParse(url)?.host ?? '').replaceFirst('www.', '');
    final title = '${link['title'] ?? host}';
    final source = '${link['source'] ?? ''}'.trim();
    return Semantics(
      container: true,
      link: true,
      label: '$title, ${source.isEmpty ? host : source}',
      excludeSemantics: true,
      child: GestureDetector(
        onTap: () {
          final u = Uri.tryParse(url);
          if (u != null) launchUrl(u, mode: LaunchMode.externalApplication);
        },
        child: Container(
          decoration: BoxDecoration(
            color: p.sheet,
            borderRadius: Radii.rowAll,
            border: Border.all(color: p.hairline),
            boxShadow: [BoxShadow(color: p.bg.withValues(alpha: 0.5), blurRadius: 18, offset: const Offset(0, 6))],
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(
              flex: 6,
              child: Padding(
                padding: const EdgeInsets.all(Space.x1),
                child: ClipRRect(
                  borderRadius: Radii.fieldAll,
                  child: ColoredBox(color: p.bubble, child: _OgThumb(url: url, given: '${link['image'] ?? ''}', fill: true)),
                ),
              ),
            ),
            Expanded(
              flex: 4,
              child: Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(Space.x3, Space.x1, Space.x3, Space.x2),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: AppText.microStyle.copyWith(color: p.text, fontWeight: FontWeight.w500)),
                  const Spacer(),
                  Text(source.isEmpty ? host : '$source · $host', maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: AppText.captionStyle.copyWith(color: p.muted)),
                ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class _LinkRow extends StatelessWidget {
  final Map<String, dynamic> link;
  final bool richImage;
  const _LinkRow({required this.link, this.richImage = true});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final url = (link['url'] ?? '').toString();
    final host = (Uri.tryParse(url)?.host ?? '').replaceFirst('www.', '');
    final note = (link['note'] ?? link['snippet'] ?? '').toString();
    final given = (link['image'] ?? '').toString();
    return Pressable(
      onTap: () {
        final u = Uri.tryParse(url);
        if (u != null) launchUrl(u, mode: LaunchMode.externalApplication);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    if (host.isNotEmpty) ...[Favicon(host: host), const SizedBox(width: 6)],
                    Flexible(
                      child: Text(host, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.muted, fontSize: AppText.micro)),
                    ),
                  ]),
                  const SizedBox(height: 3),
                  Text((link['title'] ?? url).toString(),
                      maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: p.text, fontSize: AppText.body, fontWeight: FontWeight.w600, height: 1.3)),
                  if (note.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(note, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.muted, fontSize: AppText.meta, height: 1.35)),
                  ],
                ],
              ),
            ),
            if (richImage && url.startsWith('http')) ...[
              const SizedBox(width: 10),
              _OgThumb(url: url, given: given),
            ],
          ],
        ),
      ),
    );
  }
}

class Favicon extends StatelessWidget {
  final String host;
  final double size;
  const Favicon({super.key, required this.host, this.size = 14});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: Image.network(
        'https://www.google.com/s2/favicons?domain=$host&sz=64',
        width: size,
        height: size,
        frameBuilder: subImageFade,
        errorBuilder: (_, __, ___) => Container(width: size, height: size, color: p.bubble),
      ),
    );
  }
}

/// Preview image from the page's og:image, fetched once and cached.
class _OgThumb extends StatefulWidget {
  final String url;
  final String given;
  /// Fill the space it is given (deck cards) instead of a 64px square.
  final bool fill;
  const _OgThumb({required this.url, this.given = '', this.fill = false});

  static final Map<String, String?> cache = {};

  @override
  State<_OgThumb> createState() => _OgThumbState();
}

class _OgThumbState extends State<_OgThumb> {
  String? _img;

  @override
  void initState() {
    super.initState();
    if (widget.given.startsWith('http')) {
      _img = widget.given;
    } else if (_OgThumb.cache.containsKey(widget.url)) {
      _img = _OgThumb.cache[widget.url];
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    String? found;
    try {
      final r = await http.get(Uri.parse(widget.url), headers: {
        'User-Agent': 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126 Mobile Safari/537.36',
        'Range': 'bytes=0-120000',
      }).timeout(const Duration(seconds: 6));
      final head = utf8.decode(r.bodyBytes.length > 120000 ? r.bodyBytes.sublist(0, 120000) : r.bodyBytes, allowMalformed: true);
      final m = RegExp('<meta[^>]+(?:property|name)=["\'](?:og:image|twitter:image)["\'][^>]*content=["\']([^"\']+)["\']', caseSensitive: false)
              .firstMatch(head) ??
          RegExp('<meta[^>]+content=["\']([^"\']+)["\'][^>]*(?:property|name)=["\'](?:og:image|twitter:image)["\']', caseSensitive: false)
              .firstMatch(head);
      if (m != null) {
        var v = m.group(1)!.replaceAll('&amp;', '&');
        if (v.startsWith('//')) v = 'https:$v';
        if (v.startsWith('/')) v = Uri.parse(widget.url).resolve(v).toString();
        if (v.startsWith('http')) found = v;
      }
    } catch (_) {}
    _OgThumb.cache[widget.url] = found;
    if (mounted && found != null) setState(() => _img = found);
  }

  @override
  Widget build(BuildContext context) {
    final img = _img;
    if (widget.fill) {
      if (img == null) return const SizedBox.expand();
      return Image.network(img, fit: BoxFit.cover, width: double.infinity, height: double.infinity, frameBuilder: subImageFade,
          errorBuilder: (_, __, ___) => const SizedBox.expand());
    }
    if (img == null) return const SizedBox.shrink();
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.network(img, width: 64, height: 64, fit: BoxFit.cover, frameBuilder: subImageFade,
          errorBuilder: (_, __, ___) => const SizedBox.shrink()),
    );
  }
}

class PlanCard extends StatefulWidget {
  final String title;
  final List<String> steps;
  const PlanCard({super.key, required this.title, required this.steps});

  @override
  State<PlanCard> createState() => _PlanCardState();
}

class _PlanCardState extends State<PlanCard> {
  final Set<int> _done = {};

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return _Card(
      kicker: 'Plan · ${widget.steps.length} steps',
      actions: [_CardAction('Copy', () => _copy(context, widget.steps.map((e) => '• $e').join('\n')))],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.title, style: Brand.serif(size: 21, color: p.text, height: 1.15)),
          const SizedBox(height: 10),
          for (var i = 0; i < widget.steps.length; i++)
            InkWell(
              onTap: () {
                setState(() => _done.contains(i) ? _done.remove(i) : _done.add(i));
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 26,
                      child: Text('${i + 1}',
                          style: Brand.serif(size: 20, color: _done.contains(i) ? p.faint : p.muted, height: 1.1)),
                    ),
                    Expanded(
                      child: Text(
                        widget.steps[i],
                        style: TextStyle(
                          color: _done.contains(i) ? p.muted : p.text,
                          fontSize: AppText.body,
                          height: 1.4,
                          decoration: _done.contains(i) ? TextDecoration.lineThrough : null,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class ChoicesCard extends StatelessWidget {
  final List<String> choices;

  /// The question the card itself carries ({"question": …}); most cards ask it in the reply's text instead.
  final String? question;

  /// The id of the message this card sits in, when known (CB-5).
  final String? owner;
  const ChoicesCard(this.choices, {super.key, this.question, this.owner});

  /// Where this card stands in the open chat: (live, picked). A card is live only until the user answers after it;
  /// then it shows what they picked (ticked) or their own words, and nothing can be tapped again. Before v1.13.101
  /// every old card stayed tappable (a tap re-sent an old answer) and lost its tick when it scrolled away.
  ///
  /// With [owner] (the id of the message the card sits in) the status is worked out from that message on, so an older
  /// card keeps its answer when the same options are offered again later (CB-5: it came back live and unticked, and a
  /// tap sent the old answer to the new question). Without it, the newest card with these options is meant.
  static (bool, String?) statusIn(List<ChatMessage> messages, List<String> choices, {required bool busy, String? owner}) {
    if (owner != null) {
      final i = messages.indexWhere((m) => m.id == owner);
      // Not in the open chat (a team or bot list shows it): it can be answered while nothing runs here.
      if (i < 0) return (!busy, null);
      return _from(messages, i, choices, busy);
    }
    for (var i = messages.length - 1; i >= 0; i--) {
      final m = messages[i];
      if (m.role != 'assistant' || !m.content.contains('```choices')) continue;
      if (!Choices.blocksIn(m.content).any((b) => Choices.same(b, choices))) continue;
      return _from(messages, i, choices, busy);
    }
    // Not in the open chat (a team or bot list shows it): it can be answered while nothing runs here.
    return (!busy, null);
  }

  /// The status of the card in messages[i]: answered by the first real user message after it, else live while idle.
  static (bool, String?) _from(List<ChatMessage> messages, int i, List<String> choices, bool busy) {
    for (var k = i + 1; k < messages.length; k++) {
      final u = messages[k];
      if (u.role != 'user' || u.content.startsWith(botWakeMark)) continue;
      return (false, Choices.pickedIn(u.content, choices) ?? u.content.trim());
    }
    return (!busy, null);
  }

  @override
  Widget build(BuildContext context) {
    // Only this card's own status (it watched the whole state and rebuilt on every streamed word).
    final (live, picked) = context.select<AppState, (bool, String?)>((s) => statusIn(s.messages, choices, busy: s.busy, owner: owner));
    final state = context.read<AppState>();
    final q = question;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        if (q != null) ...[
          Text(q, style: AppText.bodyStyle.copyWith(color: Palette.of(context).text, fontWeight: FontWeight.w600)),
          const SizedBox(height: Space.x2),
        ],
        ChoiceRows(
          // Keyed by its answers and its status, so a card that was answered elsewhere shows it at once.
          key: ValueKey('choices-${choices.join('|')}-${picked ?? ''}'),
          options: choices,
          enabled: live,
          picked: picked,
          onPick: (c) => state.send(c, []),
          // Your own words, like every question in the app (the card had no "Something else" row).
          onOther: (t) => state.send(t, []),
        ),
      ]),
    );
  }
}

class FileCard extends StatelessWidget {
  final String path;
  const FileCard(this.path, {super.key});

  static final _imageName = RegExp(r'\.(png|jpe?g|webp|gif|bmp)$', caseSensitive: false);
  static final _svgName = RegExp(r'\.svg$', caseSensitive: false);
  bool get _isImage => _imageName.hasMatch(path);
  bool get _isSvg => _svgName.hasMatch(path);

  @override
  Widget build(BuildContext context) {
    final name = path.split('/').last;
    if (_isImage) return ImageResultCard(path: path);
    // The agent's own drawings render in chat too (owner, 2026-10-31).
    if (_isSvg) return SvgFileCard(path);
    // The file on this phone, or fetched back from the account (another phone, a reinstall). Only a file that is in
    // neither place says so, with Try again.
    return MediaResolve(
      path: path,
      ready: (c, f) => _ready(c, f, name),
      loading: (c) => _Card(collapse: false, child: DocumentTile(name: name, meta: '${kindLabel(name)} · Getting it from your account')),
      gone: (c, retry) => _Card(
        collapse: false,
        child: DocumentTile(name: name, meta: '${kindLabel(name)} · Not available any more. Tap to try again', onTap: retry),
      ),
    );
  }

  Widget _ready(BuildContext context, File f, String name) {
    final local = f.path;
    var size = '';
    try {
      size = sizeLabel(f.lengthSync());
    } catch (_) {}
    void open() => canPreview(local) ? openPreview(context, local) : SharePlus.instance.share(ShareParams(files: [XFile(local)]));
    return _Card(
      collapse: false,
      actions: [
        _CardAction(canPreview(local) ? 'Open' : 'Open with', open),
        _CardAction('Save', () => showSaveSheet(context, local)),
        _CardAction('Share', () => SharePlus.instance.share(ShareParams(files: [XFile(local)]))),
      ],
      child: DocumentTile(name: name, meta: [kindLabel(name), if (size.isNotEmpty) size].join(' · '), onTap: open),
    );
  }

}

/// A generated, saved or sent picture: shown inline in its real shape; tap for the full-screen viewer (pinch,
/// double-tap zoom, swipe), hold for View / Save / Share. A picture made on another phone is fetched from the account.
class ImageResultCard extends StatelessWidget {
  final String path;
  const ImageResultCard({super.key, required this.path});

  @override
  Widget build(BuildContext context) {
    final name = path.split('/').last;
    return MediaResolve(
      path: path,
      loading: (c) => const MediaPlaceholder(),
      gone: (c, retry) => DocumentTile(name: name, meta: 'Picture · Not available any more. Tap to try again', onTap: retry),
      ready: (c, f) => Semantics(
        image: true,
        label: 'Picture. Tap to view, hold for options',
        child: GestureDetector(
          onTap: () => openImageViewer(c, f.path),
          onLongPress: () => showMessageActions(c, actions: [
            MessageAction('View', 'eye', () => openImageViewer(c, f.path)),
            MessageAction('Save', 'folder', () => showSaveSheet(c, f.path)),
            MessageAction('Share', 'share', () => SharePlus.instance.share(ShareParams(files: [XFile(f.path)]))),
          ]),
          child: ClipRRect(borderRadius: Radii.rowAll, child: TrueShapeImage(FileImage(f))),
        ),
      ),
    );
  }
}

bool _isRemote(String src) => src.startsWith('http://') || src.startsWith('https://');

String mediaMime(String name) {
  final ext = name.contains('.') ? name.split('.').last.toLowerCase().split('?').first : '';
  const m = {
    'png': 'image/png', 'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'gif': 'image/gif', 'webp': 'image/webp', 'heic': 'image/heic',
    'mp4': 'video/mp4', 'webm': 'video/webm', 'mov': 'video/quicktime', 'mkv': 'video/x-matroska', '3gp': 'video/3gpp',
    'mp3': 'audio/mpeg', 'wav': 'audio/wav', 'm4a': 'audio/mp4', 'aac': 'audio/aac', 'ogg': 'audio/ogg', 'opus': 'audio/ogg', 'flac': 'audio/flac',
    'pdf': 'application/pdf', 'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation', 'zip': 'application/zip',
  };
  return m[ext] ?? 'application/octet-stream';
}

/// Saves a picture, video, sound or file to the phone (Pictures / Movies / Music / Download › SubMac).
/// Works for files SubMac made and for pictures on the web.
Future<void> saveToPhone(BuildContext context, String src) async {
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(const SnackBar(content: Text('Saving…'), duration: Duration(seconds: 1)));
  try {
    var path = src;
    var name = src.split('/').last.split('?').first;
    if (_isRemote(src)) {
      final r = await http.get(Uri.parse(src)).timeout(const Duration(seconds: 40));
      if (r.statusCode >= 400) throw Exception('download failed');
      final type = (r.headers['content-type'] ?? '').split(';').first.trim();
      if (!name.contains('.') || mediaMime(name) == 'application/octet-stream') {
        final ext = type.startsWith('image/') ? type.substring(6).replaceAll('jpeg', 'jpg').replaceAll('svg+xml', 'svg')
            : type.startsWith('video/') ? 'mp4'
            : type.startsWith('audio/') ? 'mp3'
            : 'jpg';
        name = 'submac_${DateTime.now().millisecondsSinceEpoch}.$ext';
      }
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/$name');
      await f.writeAsBytes(r.bodyBytes);
      path = f.path;
    } else {
      // A picture made on another phone: fetch it from the account first.
      final local = MediaStore.I.localNow(src) ?? await MediaStore.I.resolve(src, retry: true);
      if (local == null) throw const FileSystemException('gone');
      path = local.path;
    }
    final where = await SystemBridge.I.saveMedia(path, mime: mediaMime(name), name: name);
    messenger.hideCurrentSnackBar();
    if (where.startsWith('error')) {
      messenger.showSnackBar(const SnackBar(content: Text('It didn\'t save this time. Share it, then pick Save to device.')));
    } else {
      messenger.showSnackBar(SnackBar(content: Text('Saved to ${where.split('/').take(2).join(' › ')}')));
    }
  } catch (_) {
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(const SnackBar(content: Text('The download didn\'t finish. Try again once your connection is steady.')));
  }
}

Widget pictureFor(String src, {BoxFit fit = BoxFit.cover, double? width, double? height}) {
  Widget broken(BuildContext c) => Container(
        width: width,
        height: height,
        color: Palette.of(c).bubble,
        alignment: Alignment.center,
        child: SubIcon('image_broken', color: Palette.of(c).muted, size: 20),
      );
  if (_isRemote(src)) {
    return Image.network(src, fit: fit, width: width, height: height, frameBuilder: subImageFade, errorBuilder: (c, _, __) => broken(c));
  }
  return MediaResolve(
    path: src,
    ready: (c, f) => Image.file(f, fit: fit, width: width, height: height, frameBuilder: subImageFade, errorBuilder: (c, _, __) => broken(c)),
    loading: (c) => MediaPlaceholder(width: width, height: height ?? 200),
    gone: (c, _) => broken(c),
  );
}

/// Opens pictures full screen in the shared lightbox. [gallery] (with [path] in it) lets the user swipe between the
/// pictures of one card.
void openImageViewer(BuildContext context, String path, {List<String>? gallery}) {
  final list = (gallery == null || gallery.isEmpty) ? [path] : gallery;
  final at = list.indexOf(path);
  openMediaLightbox(context, list, initial: at < 0 ? 0 : at);
}

// ---------------- v1.4 cards ----------------

/// A comparison table that scrolls sideways. With "pick", tapping a row answers.
class TableCard extends StatelessWidget {
  final String title;
  final List<String> columns;
  final List<List<String>> rows;
  final bool pick;
  final String ornament;
  const TableCard(
      {super.key, required this.title, required this.columns, required this.rows, this.pick = false, this.ornament = ''});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final state = context.read<AppState>();
    final ncol = [columns.length, ...rows.map((r) => r.length)].fold<int>(0, (a, b) => a > b ? a : b);
    Widget cell(String t, {bool head = false, double? w}) {
      final l = head ? null : linkFromCell(t);
      if (l != null) {
        return Container(
          width: w,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          alignment: AlignmentDirectional.centerStart,
          child: TextButton(
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              foregroundColor: p.text,
              padding: EdgeInsets.zero,
            ),
            onPressed: () => openLink(l[1]),
            child: Text(l[0], style: const TextStyle(fontSize: AppText.meta, fontWeight: FontWeight.w600)),
          ),
        );
      }
      return cellText(t, head: head, w: w);
    }
    return _table(context, p, state, ncol, cell);
  }

  Widget cellText(String t, {bool head = false, double? w}) => Builder(builder: (context) {
        final p = Palette.of(context);
        return Container(
          width: w,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Text(t,
              maxLines: head ? 2 : 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: head ? p.muted : p.text,
                fontSize: head ? 12 : 14.5,
                fontWeight: head ? FontWeight.w600 : FontWeight.w400,
                letterSpacing: head ? 0.4 : 0,
                height: 1.35,
              )),
        );
      });

  Widget _table(BuildContext context, Palette p, AppState state, int ncol, Widget Function(String, {bool head, double? w}) cell) {
    final colW = ncol <= 2 ? 150.0 : 132.0;
    return _Card(
      foldHeight: 250,
      kicker: title.isEmpty ? 'Table' : title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (columns.isNotEmpty)
                  Row(children: [for (var c = 0; c < ncol; c++) cell(c < columns.length ? columns[c] : '', head: true, w: colW)]),
                for (final r in rows) ...[
                  // No row lines (UI rules): the row air separates.
                  Pressable(
                    onTap: pick && !state.busy ? () => state.send('I pick: ${r.isEmpty ? '' : r.first}', []) : null,
                    child: Row(children: [
                      for (var c = 0; c < ncol; c++) cell(c < r.length ? r[c] : '', w: colW),
                      if (pick) SubIcon('chevron_right', color: p.muted, size: 18),
                    ]),
                  ),
                ],
              ],
            ),
          ),
          if (pick)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('Tap a row to choose it', style: TextStyle(color: p.muted, fontSize: AppText.micro)),
            ),
          if (ornament.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(ornament, style: TextStyle(color: p.muted, fontSize: AppText.meta, height: 1.35)),
            ),
        ],
      ),
    );
  }
}

class PictureItem {
  final String src;
  final String caption;
  const PictureItem(this.src, this.caption);
}

class PhotoGridCard extends StatelessWidget {
  final List<PictureItem> items;
  const PhotoGridCard(this.items, {super.key});

  @override
  Widget build(BuildContext context) {
    final cols = items.length == 1 ? 1 : (items.length == 2 || items.length == 4 ? 2 : 3);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Expandable(
        height: 230,
        child: GridView.count(
        crossAxisCount: cols,
        childAspectRatio: cols == 1 ? 1.6 : 1,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
        children: [
          for (final it in items.take(12))
            Pressable(
              onTap: () => openImageViewer(context, it.src, gallery: [for (final e in items) e.src]),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: pictureFor(it.src),
              ),
            ),
        ],
      ),
      ),
    );
  }
}

/// Swipeable stack of pictures; tap opens full screen.
class ImageStackCard extends StatefulWidget {
  final List<PictureItem> items;
  const ImageStackCard(this.items, {super.key});

  @override
  State<ImageStackCard> createState() => _ImageStackCardState();
}

class _ImageStackCardState extends State<ImageStackCard> {
  final _ctrl = PageController(viewportFraction: 0.88);
  int _page = 0;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final items = widget.items;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 200,
            child: PageView.builder(
              controller: _ctrl,
              padEnds: false,
              itemCount: items.length,
              onPageChanged: (i) {
                setState(() => _page = i);
              },
              itemBuilder: (c, i) => Padding(
                padding: const EdgeInsetsDirectional.only(end: 8),
                child: Pressable(
                  onTap: () => openImageViewer(context, items[i].src, gallery: [for (final e in items) e.src]),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: pictureFor(items[i].src, width: double.infinity, height: 200),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(children: [
            if (items.length > 1)
              for (var i = 0; i < items.length && i < 12; i++)
                AnimatedContainer(
                  duration: SubMotion.of(context, SubMotion.quick),
                  curve: SubMotion.settle,
                  margin: const EdgeInsetsDirectional.only(end: 5),
                  width: i == _page ? 14 : 5,
                  height: 5,
                  decoration: BoxDecoration(
                    color: i == _page ? p.accent : p.border,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(items[_page].caption,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.muted, fontSize: AppText.meta)),
            ),
          ]),
        ],
      ),
    );
  }
}

/// "Done" note for an action SubMac took, with Undo.
class ReceiptCard extends StatefulWidget {
  final String title;
  final String detail;
  final String undo;
  const ReceiptCard({super.key, required this.title, required this.detail, required this.undo});

  @override
  State<ReceiptCard> createState() => _ReceiptCardState();
}

class _ReceiptCardState extends State<ReceiptCard> {
  bool _undone = false;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final state = context.read<AppState>();
    return _Card(
      collapse: false,
      kicker: _undone ? 'Undo requested' : 'Done',
      actions: [
        if (widget.undo.isNotEmpty && !_undone)
          _CardAction('Undo', () {
            if (state.busy) return;
            setState(() => _undone = true);
            state.send('Please undo that: ${widget.undo}', []);
          }),
      ],
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22,
            height: 22,
            margin: const EdgeInsetsDirectional.only(top: 1, end: 10),
            child: SubIcon('check', size: 15, color: p.text),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.title, style: TextStyle(color: p.text, fontSize: AppText.body, fontWeight: FontWeight.w600, height: 1.35)),
                if (widget.detail.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(widget.detail, style: TextStyle(color: p.muted, fontSize: AppText.meta, height: 1.4)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Asks the user to approve a step before SubMac does it (used in Ask mode).
class ConfirmCard extends StatefulWidget {
  final String title;
  final String body;
  final String confirm;
  final String cancel;
  const ConfirmCard({super.key, required this.title, required this.body, required this.confirm, required this.cancel});

  @override
  State<ConfirmCard> createState() => _ConfirmCardState();
}

class _ConfirmCardState extends State<ConfirmCard> {
  String? _answer;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final state = context.read<AppState>();
    void answer(String a) {
      if (_answer != null || state.busy) return;
      setState(() => _answer = a);
      state.send(a, []);
    }

    return _Card(
      collapse: false,
      kicker: _answer == null ? 'Needs your OK' : 'You said: $_answer',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.title, style: Brand.serif(size: 20, color: p.text, height: 1.15)),
          if (widget.body.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(widget.body, style: TextStyle(color: p.muted, fontSize: AppText.body, height: 1.4)),
          ],
          if (_answer == null) ...[
            const SizedBox(height: 14),
            FilledButton(onPressed: () => answer(widget.confirm), child: Text(widget.confirm)),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: () => answer(widget.cancel), child: Text(widget.cancel)),
          ],
        ],
      ),
    );
  }
}


/// A QR code people can print or share (shop order link, page link, Wi-Fi, contact).
class QrCard extends StatefulWidget {
  final String data;
  final String title;
  const QrCard({super.key, required this.data, this.title = ''});

  @override
  State<QrCard> createState() => _QrCardState();
}

class _QrCardState extends State<QrCard> {
  final _key = GlobalKey();

  Future<void> _share() async {
    try {
      final b = _key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final img = await b.toImage(pixelRatio: 4);
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      final dir = await AgentToolsDir.media();
      final f = File('$dir/qr_${DateTime.now().millisecondsSinceEpoch}.png');
      await f.writeAsBytes(png!.buffer.asUint8List());
      await SharePlus.instance.share(ShareParams(files: [XFile(f.path)], text: widget.title.isEmpty ? null : widget.title));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return cardShell(
      context,
      kicker: widget.title.isEmpty ? 'QR code' : widget.title,
      actions: [
        cardAction(context, 'Share', _share),
        cardAction(context, 'Copy link', () {
          Clipboard.setData(ClipboardData(text: widget.data));
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Copied'))));
        }),
      ],
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 16, 8),
        child: Column(children: [
          RepaintBoundary(
            key: _key,
            child: Container(
              color: const Color(0xFFF4F0E7),
              padding: const EdgeInsets.all(16),
              child: QrImageView(
                data: widget.data,
                size: 200,
                backgroundColor: const Color(0xFFF4F0E7),
                eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Color(0xFF17150F)),
                dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: Color(0xFF17150F)),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(widget.data, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center,
              style: TextStyle(color: p.muted, fontSize: AppText.micro)),
        ]),
      ),
    );
  }
}

class AgentToolsDir {
  static Future<String> media() async {
    final ws = await AgentTools.workspaceDir();
    final d = Directory('$ws/media');
    await d.create(recursive: true);
    return d.path;
  }
}


/// Shows a picture in its real shape: a 9:16 wallpaper stays tall, a banner stays wide.
/// Nothing is cropped; very tall pictures are capped so the chat stays readable.
class TrueShapeImage extends StatefulWidget {
  const TrueShapeImage(this.image, {super.key, this.maxHeight = 460});
  final ImageProvider image;
  final double maxHeight;

  @override
  State<TrueShapeImage> createState() => _TrueShapeImageState();
}

class _TrueShapeImageState extends State<TrueShapeImage> {
  double? _ratio; // width / height
  ImageStream? _stream;
  ImageStreamListener? _listener;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(TrueShapeImage old) {
    super.didUpdateWidget(old);
    if (old.image != widget.image) _resolve();
  }

  void _resolve() {
    final st = widget.image.resolve(createLocalImageConfiguration(context));
    if (_stream?.key == st.key) return;
    _stop();
    _stream = st;
    _listener = ImageStreamListener((info, _) {
      final w = info.image.width.toDouble(), h = info.image.height.toDouble();
      if (mounted && h > 0) setState(() => _ratio = w / h);
    }, onError: (_, __) {});
    st.addListener(_listener!);
  }

  void _stop() {
    if (_stream != null && _listener != null) _stream!.removeListener(_listener!);
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final maxW = c.maxWidth.isFinite ? c.maxWidth : 360.0;
      final r = _ratio ?? 1.0;
      var w = maxW;
      var h = w / r;
      if (h > widget.maxHeight) {
        h = widget.maxHeight;
        w = h * r;
      }
      return AnimatedContainer(
        duration: SubMotion.of(context, SubMotion.quick),
        curve: SubMotion.settle,
        width: w,
        height: h,
        child: Image(image: widget.image, fit: BoxFit.cover, width: w, height: h, gaplessPlayback: true),
      );
    });
  }
}
