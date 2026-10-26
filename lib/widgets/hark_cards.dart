import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../screens/preview_screen.dart';
import '../screens/site_screens.dart' show showPublishSheet;
import '../services/media_store.dart';
import '../services/tools.dart';
import '../theme.dart';
import 'media_view.dart';
import 'media_lightbox.dart';
import 'video_inline.dart';
import 'page_cards.dart' show OpenPageButton, pageTitleOf;
import 'chat/document_tile.dart';
import 'chat/message_actions.dart';
import 'motion.dart';
import 'output_cards.dart';
import 'sub_icon.dart';
import '../ui/tokens.dart';

final _mdImage = RegExp(r'!\[[^\]]*\]\(([^)\s]+)');
final _mdLink = RegExp(r'^\[([^\]]*)\]\(([^)\s]+)\)$');

/// Pulls a picture address out of a cell ("![alt](https://...)" or a bare link).
String imageFromCell(String c) {
  final m = _mdImage.firstMatch(c);
  if (m != null) return m.group(1)!;
  final t = c.trim();
  if (t.startsWith('http') || t.startsWith('/')) return t;
  return '';
}

final _anyMdLink = RegExp(r'\[((?:[^\[\]]|\[[^\]]*\])*)\]\((https?://[^)\s]+)\)');

/// A link in a cell: "https://...", "[Book](https://...)", "[![photo](img)](https://...)" or a link inside text.
/// Returns [label, url] or null. Picture addresses are never treated as the link.
List<String>? linkFromCell(String c) {
  final t = c.trim();
  final m = _mdLink.firstMatch(t);
  if (m != null && !m.group(1)!.startsWith('!')) return [m.group(1)!.isEmpty ? 'Open' : m.group(1)!, m.group(2)!];
  for (final x in _anyMdLink.allMatches(t)) {
    final label = x.group(1)!;
    if (x.start > 0 && t[x.start - 1] == '!') continue; // that is an image, not a link
    return [label.startsWith('![') || label.isEmpty ? 'Open' : label, x.group(2)!];
  }
  if (_mdImage.hasMatch(t)) return null;
  if (t.startsWith('http://') || t.startsWith('https://')) return ['Open', t];
  return null;
}

const _searchParams = {'q', 'k', 'query', 'keyword', 'keywords', 'search', 'search_query', '_nkw', 'text', 'st', 'term', 'searchterm'};

/// True for a results page (Google, a shop's search) rather than the item's own page.
bool isSearchUrl(String url) {
  final u = Uri.tryParse(url);
  if (u == null) return false;
  final host = u.host.toLowerCase();
  final path = u.path.toLowerCase();
  if ((host.contains('google.') || host.contains('bing.com') || host.contains('duckduckgo.') || host.contains('yahoo.')) &&
      (path.startsWith('/search') || path == '/' || path.isEmpty || path.startsWith('/shopping'))) {
    return true;
  }
  if (path.contains('/search') || path == '/s' || path.startsWith('/s/') || path.contains('/catalog')) {
    if (u.queryParameters.keys.any((k) => _searchParams.contains(k.toLowerCase()))) return true;
  }
  return u.queryParameters.keys.any((k) => _searchParams.contains(k.toLowerCase())) && (path == '/' || path.isEmpty || path.endsWith('/search'));
}

/// When all we have is a results page, at least search for THIS item on the same site.
String refineSearch(String url, String name) {
  final u = Uri.tryParse(url);
  final n = name.replaceAll(RegExp(r'[*_`\[\]]'), '').trim();
  if (u == null || n.isEmpty) return url;
  final qp = Map<String, String>.from(u.queryParameters);
  final key = qp.keys.firstWhere((k) => _searchParams.contains(k.toLowerCase()), orElse: () => '');
  if (key.isEmpty) return url;
  qp[key] = n;
  return u.replace(queryParameters: qp).toString();
}

/// Every row opens its own item: a real item link from any cell wins over a results page,
/// and a results-page-only row is narrowed to that row's item name.
List<List<String>> fixRowLinks(List<List<String>> rows) {
  return [
    for (final r in rows)
      () {
        final name = r.isEmpty ? '' : r.first.replaceAll(_mdImage, '').trim();
        String? best;
        for (final c in r) {
          final l = linkFromCell(c);
          if (l != null && !isSearchUrl(l[1])) {
            best = l[1];
            break;
          }
        }
        return [
          for (final c in r)
            () {
              final l = linkFromCell(c);
              if (l == null || !isSearchUrl(l[1])) return c;
              final to = best ?? refineSearch(l[1], name);
              return '[${best != null ? l[0] : 'Search'}]($to)';
            }()
        ];
      }()
  ];
}

Future<void> openLink(String url) async {
  final u = Uri.tryParse(url.trim());
  if (u == null || !u.hasScheme) return;
  if (!await launchUrl(u, mode: LaunchMode.externalApplication)) {
    await launchUrl(u, mode: LaunchMode.platformDefault);
  }
}

/// Things to buy or book, shown as tiles: picture, name, price, tap to open.
class ProductGridCard extends StatelessWidget {
  const ProductGridCard({super.key, required this.title, required this.columns, required this.rows, this.ornament = ''});
  final String title;
  final List<String> columns;
  final List<List<String>> rows;
  final String ornament;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final lower = columns.map((c) => c.toLowerCase().trim()).toList();
    final photo = lower.indexWhere((c) => c == 'photo' || c == 'image' || c == 'picture');
    var price = lower.indexWhere((c) => c.contains('price') || c.contains('cost') || c.contains('fare'));
    int link = -1;
    for (var c = 0; c < columns.length && link < 0; c++) {
      if (rows.any((r) => c < r.length && c != photo && linkFromCell(r[c]) != null)) link = c;
    }
    if (price < 0) {
      price = List.generate(columns.length, (i) => i).firstWhere(
          (c) => c != photo && rows.any((r) => c < r.length && RegExp(r'^[\$€£]|\d+ ?(USD|SOS|KES)').hasMatch(r[c].trim())),
          orElse: () => -1);
    }
    final details = [
      for (var c = 1; c < columns.length; c++)
        if (c != photo && c != price && c != link) c
    ];
    String plain(String cell) => cell.replaceAllMapped(RegExp(r'!?\[([^\]]*)\]\([^)]*\)'), (m) => m.group(1) ?? '').replaceAll(RegExp(r'[*_`]'), '').trim();
    // Hark's product card: one dark card, the title over a faint line, then rows of a 76px rounded thumbnail, the
    // name, a muted spec line and the price at the end. A row opens the item; its thumbnail opens the photo.
    final list = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (var i = 0; i < rows.length; i++)
        Builder(builder: (context) {
          final r = rows[i];
          String cell(int k) => k >= 0 && k < r.length ? r[k] : '';
          final img = imageFromCell(cell(photo));
          List<String>? l = linkFromCell(cell(link));
          if (l == null) {
            for (final c in r) {
              l = linkFromCell(c);
              if (l != null) break;
            }
          }
          final name = plain(cell(photo == 0 ? 1 : 0));
          final specs = [for (final d in details) plain(cell(d))].where((t) => t.isNotEmpty && t != name).join(' · ');
          final cost = price >= 0 ? plain(cell(price)) : '';
          return Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : Space.x3),
            child: Pressable(
              onTap: l == null ? null : () => openLink(l![1]),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Semantics(
                  button: img.isNotEmpty,
                  label: img.isEmpty ? null : 'Open the photo of $name',
                  child: GestureDetector(
                    onTap: img.isEmpty ? null : () => openImageViewer(context, img),
                    child: Container(
                      width: 76,
                      height: 76,
                      decoration: BoxDecoration(color: p.sheet, borderRadius: Radii.fieldAll),
                      clipBehavior: Clip.antiAlias,
                      padding: const EdgeInsets.all(Space.x1),
                      child: img.isEmpty
                          ? Center(child: Text(name.isEmpty ? '' : name.characters.first.toUpperCase(), style: AppText.leadStyle.copyWith(color: p.muted)))
                          : ClipRRect(borderRadius: Radii.smAll, child: pictureFor(img, fit: BoxFit.contain, width: 68, height: 68)),
                    ),
                  ),
                ),
                const SizedBox(width: Space.x3),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.bodyStyle.copyWith(color: p.text, height: 1.3)),
                    if (specs.isNotEmpty)
                      Text(specs, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.metaStyle.copyWith(color: p.muted, height: 1.3)),
                  ]),
                ),
                if (cost.isNotEmpty) ...[
                  const SizedBox(width: Space.x3),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 110),
                    child: Text(cost, textAlign: TextAlign.end, style: AppText.metaStyle.copyWith(color: p.text, fontWeight: FontWeight.w500)),
                  ),
                ],
              ]),
            ),
          );
        }),
    ]);
    return HarkSurface(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (title.isNotEmpty) ...[
          Text(title, style: AppText.bodyStyle.copyWith(color: p.text, fontWeight: FontWeight.w500)),
          const HarkHairline(gap: Space.x4),
        ],
        rows.length > 4 ? Expandable(height: 360, fadeColor: p.bubble, child: list) : list,
        if (ornament.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: Space.x3),
            child: Text(ornament, style: AppText.metaStyle.copyWith(color: p.muted)),
          ),
      ]),
    );
  }
}

/// An order, booking or bill: items, fees, total, card, and one button.
class OrderCard extends StatefulWidget {
  const OrderCard(this.j, {super.key});
  final Map<String, dynamic> j;

  @override
  State<OrderCard> createState() => _OrderCardState();
}

class _OrderCardState extends State<OrderCard> {
  bool _sent = false;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final j = widget.j;
    final items = [for (final e in (j['items'] ?? j['line_items'] ?? const []) as List) if (e is Map) e];
    final fees = [for (final e in (j['breakdown'] ?? j['fees'] ?? const []) as List) if (e is Map) e];
    final action = '${j['action'] ?? ''}'.trim();
    Widget row(String a, String b, {bool strong = false, Color? color}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            Expanded(
              child: Text(a,
                  style: TextStyle(color: color ?? p.text, fontSize: strong ? 15.5 : 14, fontWeight: strong ? FontWeight.w600 : FontWeight.w400)),
            ),
            Text(b, style: TextStyle(color: color ?? p.text, fontSize: strong ? 15.5 : 14, fontWeight: strong ? FontWeight.w600 : FontWeight.w400)),
          ]),
        );
    return cardShell(
      context,
      collapse: false,
      kicker: '${j['merchant'] ?? 'Order'}',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if ('${j['destination'] ?? ''}'.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('${j['destination']}', style: TextStyle(color: p.muted, fontSize: AppText.meta)),
          ),
        for (final it in items)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(children: [
              if ('${it['image'] ?? it['image_url'] ?? ''}'.isNotEmpty)
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 10),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: pictureFor('${it['image'] ?? it['image_url']}', width: 44, height: 44),
                  ),
                ),
              Expanded(
                child: Text('${(it['qty'] ?? '').toString().isEmpty ? '' : '${it['qty']} × '}${it['name'] ?? ''}',
                    style: TextStyle(color: p.text, fontSize: AppText.meta)),
              ),
              Text('${it['price'] ?? ''}', style: TextStyle(color: p.text, fontSize: AppText.meta)),
            ]),
          ),
        if (fees.isNotEmpty) const SizedBox(height: Space.x3),
        for (final f in fees) row('${f['label'] ?? ''}', '${f['amount'] ?? ''}', color: p.muted),
        if ('${j['total'] ?? ''}'.isNotEmpty) ...[
          const SizedBox(height: Space.x3),
          row('Total', '${j['total']}', strong: true),
        ],
        if ('${j['payment'] ?? ''}'.isNotEmpty)
          Text('${j['payment']}', style: TextStyle(color: p.muted, fontSize: AppText.meta)),
        if ('${j['order_number'] ?? ''}'.isNotEmpty)
          Text('Confirmation ${j['order_number']}', style: TextStyle(color: p.muted, fontSize: AppText.meta)),
        if ('${j['ornament'] ?? ''}'.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text('${j['ornament']}', style: TextStyle(color: p.muted, fontSize: AppText.meta, height: 1.35)),
          ),
        if (action.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: FilledButton(
              onPressed: _sent
                  ? null
                  : () {
                      setState(() => _sent = true);
                      context.read<AppState>().send('Yes, go ahead: $action', []);
                    },
              child: Text(_sent ? 'Sent' : action),
            ),
          ),
      ]),
    );
  }
}

/// A web page SubMac made (HTML) shown as a live preview; tap to open full screen.
class PageCard extends StatefulWidget {
  const PageCard(this.body, {super.key});
  final String body;

  @override
  State<PageCard> createState() => _PageCardState();
}

class _PageCardState extends State<PageCard> {
  String? _path;

  String get _html => widget.body.trim();
  bool get _isFile => !_html.startsWith('<') && _html.startsWith('/');

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    if (_isFile) {
      final raw = _html.split('\n').first.trim();
      setState(() => _path = raw);
      // A page made on another phone is fetched from the account; one made here is kept there.
      final f = MediaStore.I.localNow(raw) ?? await MediaStore.I.resolve(raw);
      if (f != null) {
        unawaited(MediaStore.I.keep(f.path).catchError((_) => null));
        if (mounted && f.path != raw) setState(() => _path = f.path);
      }
      return;
    }
    try {
      final ws = await AgentTools.workspaceDir();
      final dir = Directory('$ws/pages');
      await dir.create(recursive: true);
      final f = File('${dir.path}/page_${_html.hashCode.toUnsigned(32)}.html');
      if (!f.existsSync()) await f.writeAsString(_html);
      if (mounted) setState(() => _path = f.path);
    } catch (_) {}
  }

  String get _title {
    final src = _isFile ? '' : _html;
    final m = RegExp(r'<title>([^<]*)</title>', caseSensitive: false).firstMatch(src);
    if (m != null && m.group(1)!.trim().isNotEmpty) return m.group(1)!.trim();
    if (_isFile) {
      final path = _path;
      var head = '';
      try {
        if (path != null && File(path).existsSync()) head = File(path).readAsStringSync();
      } catch (_) {}
      return pageTitleOf(head.length > 4000 ? head.substring(0, 4000) : head, _html.split('\n').first.trim());
    }
    return 'Page';
  }

  /// Hold: Publish and Share (the file, or the live link once published, from the preview).
  void _more(BuildContext context, String path) => showMessageActions(context, actions: [
        MessageAction('Open page', 'expand', () => openPreview(context, path)),
        MessageAction('Publish', 'send', () => showPublishSheet(context, path)),
        MessageAction('Share', 'share', () => SharePlus.instance.share(ShareParams(files: [XFile(path)]))),
      ]);

  /// Hark's website card: the page as a thumbnail, its title, "Page built by SubMac", and Open page (the in-app
  /// preview with sizes, Share and Publish). No border, no shadow; the card fill only.
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final path = _path;
    final ready = path != null && File(path).existsSync();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.x1),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Semantics(
            container: true,
            label: 'Page: $_title',
            child: GestureDetector(
              onTap: ready ? () => openPreview(context, path) : null,
              onLongPress: ready ? () => _more(context, path) : null,
              child: DecoratedBox(
                decoration: BoxDecoration(color: p.bubble, borderRadius: Radii.sheetAll),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                  Padding(
                    padding: const EdgeInsets.all(Space.x1),
                    child: ClipRRect(
                      borderRadius: Radii.rowAll,
                      child: SizedBox(
                        height: 180,
                        child: ready
                            ? AbsorbPointer(child: WebPageView(fileUrl: 'file://$path', interactive: false))
                            : ColoredBox(color: p.sheet),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(Space.x4, Space.x3, Space.x4, Space.x4),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                      Text(_title, maxLines: 2, overflow: TextOverflow.ellipsis, style: Brand.serif(size: AppText.title, color: p.text, height: 1.2)),
                      const SizedBox(height: Space.x1),
                      Text(ready ? 'Page built by SubMac' : 'Getting the page from your account',
                          style: AppText.metaStyle.copyWith(color: p.muted)),
                      if (ready) ...[
                        const SizedBox(height: Space.x3),
                        OpenPageButton(onTap: () => openPreview(context, path)),
                      ],
                    ]),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A video or sound SubMac made. A video plays right in the chat (tap to play, corner for full screen, hold for
/// Save / Share); a sound is a light chip that opens the full-screen player. Files made on another phone are fetched
/// from the account first.
class MediaCard extends StatelessWidget {
  const MediaCard(this.path, {super.key});
  final String path;

  bool get _sound => mediaMime(path.split('/').last).startsWith('audio/');

  void _actions(BuildContext context) => showMessageActions(context, actions: [
        MessageAction(_sound ? 'Play' : 'Full screen', 'play', () => openMediaLightbox(context, [path])),
        MessageAction('Save', 'folder', () => saveToPhone(context, path)),
        MessageAction('Share', 'share', () => shareMedia(context, path)),
      ]);

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final name = path.split('/').last;
    if (!_sound) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Space.x1),
        child: GestureDetector(
          onLongPress: () => _actions(context),
          child: path.startsWith('http')
              ? InlineVideo(path: path, onExpand: () => openMediaLightbox(context, [path]))
              : MediaResolve(
                  path: path,
                  loading: (c) => const MediaPlaceholder(height: 180),
                  gone: (c, retry) => DocumentTile(name: name, meta: 'Video · Not available any more. Tap to try again', onTap: retry),
                  ready: (c, f) => InlineVideo(path: f.path, onExpand: () => openMediaLightbox(context, [f.path])),
                ),
        ),
      );
    }
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Semantics(
        container: true,
        button: true,
        label: 'Open preview for $name',
        child: GestureDetector(
          onTap: () => openMediaLightbox(context, [path]),
          onLongPress: () => _actions(context),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 260),
            child: DecoratedBox(
              decoration: BoxDecoration(color: p.text, borderRadius: BorderRadius.circular(Radii.pill)),
              child: Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(Space.x4, Space.x3, Space.x5, Space.x3),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  SubIcon('speaker', size: IconSize.md, color: p.bg),
                  const SizedBox(width: Space.x3),
                  Flexible(
                    child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: AppText.metaStyle.copyWith(color: p.bg, fontWeight: FontWeight.w500)),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Decodes JSON loosely (cards are written by a model): text around the JSON is ignored, and a body with trailing
/// commas or missing closers (a cut-off or sloppy card, CB-7) is repaired before it is given up on.
dynamic looseJson(String body) {
  final t = body.trim();
  try {
    return jsonDecode(t);
  } catch (_) {
    final s = t.indexOf(RegExp(r'[\[{]'));
    final e = t.lastIndexOf(RegExp(r'[\]}]'));
    if (s >= 0 && e > s) {
      try {
        return jsonDecode(t.substring(s, e + 1));
      } catch (_) {}
    }
    final fixed = repairJson(t);
    if (fixed != null) return jsonDecode(fixed);
    rethrow;
  }
}

/// Mends the usual slips in model-written JSON: trailing commas, a string, array or object left open at the end, a
/// dangling key or comma. Returns null when there is no JSON to mend. The result may still be invalid.
String? repairJson(String text) {
  final start = text.indexOf(RegExp(r'[\[{]'));
  if (start < 0) return null;
  final out = StringBuffer();
  final stack = <String>[];
  var inStr = false, esc = false;
  void dropTrailingComma() {
    final cur = out.toString().replaceFirst(RegExp(r',\s*$'), '');
    out
      ..clear()
      ..write(cur);
  }

  for (var i = start; i < text.length; i++) {
    final c = text[i];
    if (inStr) {
      if (c == '\n') {
        out.write(r'\n');
        continue;
      }
      out.write(c);
      if (esc) {
        esc = false;
      } else if (c == '\\') {
        esc = true;
      } else if (c == '"') {
        inStr = false;
      }
      continue;
    }
    if (c == '"') {
      inStr = true;
      out.write(c);
    } else if (c == '{' || c == '[') {
      stack.add(c == '{' ? '}' : ']');
      out.write(c);
    } else if (c == '}' || c == ']') {
      if (!stack.contains(c)) continue; // a stray closer
      while (stack.isNotEmpty && stack.last != c) {
        dropTrailingComma();
        out.write(stack.removeLast());
      }
      dropTrailingComma();
      out.write(stack.removeLast());
      if (stack.isEmpty) break; // the JSON value is complete; anything after it is not JSON
    } else {
      out.write(c);
    }
  }
  if (inStr) out.write(esc ? '\\"' : '"');
  var r = out.toString().trimRight();
  // A dangling key ("rows":) or a trailing comma or colon at the cut.
  r = r.replaceFirst(RegExp(r'(,\s*"(?:[^"\\]|\\.)*"\s*:\s*|[,:]\s*)$'), '');
  final buf = StringBuffer(r);
  for (final closer in stack.reversed) {
    buf.write(closer);
  }
  return buf.toString();
}
