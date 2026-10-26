import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:share_plus/share_plus.dart';

import '../widgets/lux_kit.dart';
import '../services/data_sheet.dart';
import '../services/office_reader.dart';
import '../services/phone_tools.dart';
import '../theme.dart';
import '../widgets/save_sheet.dart';
import '../widgets/media_view.dart';
import '../widgets/media_lightbox.dart';
import '../services/media_store.dart';
import '../widgets/logo.dart';
import '../widgets/markdown_view.dart';
import 'site_screens.dart' show SitePreviewScreen;
import '../ui/tokens.dart';
import '../ui/i18n.dart';

const _imageExt = {'png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp'};
const _mediaExt = {'mp4', 'webm', 'mov', 'm4v', '3gp', 'mp3', 'm4a', 'wav', 'ogg', 'aac'};
const _textExt = {
  'txt', 'md', 'markdown', 'csv', 'tsv', 'json', 'xml', 'yaml', 'yml', 'log', 'sh', 'dart', 'py', 'js', 'ts',
  'css', 'kt', 'java', 'c', 'cpp', 'h', 'sql', 'ini', 'toml', 'env', 'srt', 'vtt'
};

const _officeExt = {'xlsx', 'xlsm', 'docx', 'pptx'};

String _ext(String path) => path.contains('.') ? path.split('.').last.toLowerCase() : '';

bool canPreview(String path) {
  final e = _ext(path);
  return _imageExt.contains(e) ||
      _mediaExt.contains(e) ||
      _textExt.contains(e) ||
      _officeExt.contains(e) ||
      e == 'pdf' ||
      e == 'html' ||
      e == 'htm';
}

/// Opens a file full screen. Pages (.html) open in the site preview, with phone/tablet/computer sizes and Publish;
/// pictures open in the zoomable viewer. A file made on another phone is fetched from the account first.
Future<void> openPreview(BuildContext context, String path) async {
  final local = MediaStore.I.localNow(path);
  final e = _ext(path);
  if (_imageExt.contains(e) || (_mediaExt.contains(e) && !const {'mp3', 'm4a', 'wav', 'ogg', 'aac'}.contains(e))) {
    // Pictures and video open in the one full-screen view (it fetches a file made on another phone itself).
    await openMediaLightbox(context, [local?.path ?? path]);
    return;
  }
  await Navigator.push(
    context,
    MaterialPageRoute(
        builder: (_) => (e == 'html' || e == 'htm') && local != null
            ? SitePreviewScreen(path: local.path)
            : FilePreviewScreen(path: local?.path ?? path)),
  );
}

/// Opens any file SubMac made or found: pictures, PDFs, pages, videos, text and tables.
/// When the file is not on this phone it is fetched from the account; only a file gone from both says so.
class FilePreviewScreen extends StatelessWidget {
  const FilePreviewScreen({super.key, required this.path});
  final String path;

  @override
  Widget build(BuildContext context) {
    if (File(path).existsSync()) return _FilePreview(path: path);
    final p = Palette.of(context);
    final name = path.split('/').last;
    Widget page(Widget body) => Scaffold(
          appBar: AppBar(title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: AppText.lead))),
          body: body,
        );
    return MediaResolve(
      path: path,
      ready: (c, f) => _FilePreview(path: f.path),
      // Hark's status pill: one faded line, no spinner.
      loading: (c) => page(Center(
        child: DecoratedBox(
          decoration: BoxDecoration(color: p.bubble.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(Radii.pill)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.x4, vertical: Space.x2),
            child: Text('Getting it from your account', style: AppText.metaStyle.copyWith(color: p.muted)),
          ),
        ),
      )),
      gone: (c, retry) => page(Center(
        child: Padding(
          padding: const EdgeInsets.all(Space.x8),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('This file isn\'t on this phone or in your account any more.',
                textAlign: TextAlign.center, style: TextStyle(color: p.muted)),
            const SizedBox(height: Space.x3),
            TextButton(onPressed: retry, child: Text(tr('Try again'), style: TextStyle(color: p.text))),
          ]),
        ),
      )),
    );
  }
}

class _FilePreview extends StatelessWidget {
  const _FilePreview({required this.path});
  final String path;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final name = path.split('/').last;
    final e = _ext(path);
    final f = File(path);
    Widget body;
    if (!f.existsSync()) {
      body = Center(child: Text('This file isn\'t on this phone or in your account any more.', style: TextStyle(color: p.muted)));
    } else if (_imageExt.contains(e)) {
      body = ZoomablePicture(child: Image.file(f));
    } else if (e == 'pdf') {
      body = PdfPages(path: path);
    } else if (e == 'html' || e == 'htm') {
      body = WebPageView(fileUrl: 'file://$path');
    } else if (_mediaExt.contains(e)) {
      body = MediaView(path: path);
    } else if (e == 'xlsx' || e == 'xlsm') {
      body = _XlsxView(path: path);
    } else if (e == 'docx') {
      body = _DocxView(path: path);
    } else if (e == 'pptx') {
      body = _PptxView(path: path);
    } else if (e == 'csv') {
      body = _CsvView(path: path);
    } else if (_textExt.contains(e)) {
      body = _TextView(path: path, ext: e);
    } else {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
              const {'xls', 'doc', 'ppt'}.contains(e)
                  ? 'This is an old spreadsheet or document (.xls, .doc or .ppt). Share it to open it in another app, or ask SubMac to turn it into a new one.'
                  : 'This kind of file can\'t be shown here. Use Share to open it in another app.',
              textAlign: TextAlign.center, style: TextStyle(color: p.muted)),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: AppText.lead)),
        actions: [
          if (f.existsSync())
            TextButton(
              onPressed: () => showSaveSheet(context, path),
              child: Text(tr('Save'), style: TextStyle(color: p.text, fontWeight: FontWeight.w600)),
            ),
          if (f.existsSync())
            TextButton(
              onPressed: () => SharePlus.instance.share(ShareParams(files: [XFile(path)])),
              child: Text('Share', style: TextStyle(color: p.text, fontWeight: FontWeight.w600)),
            ),
        ],
      ),
      body: body,
    );
  }
}

/// A full web page: a local file, a link, or HTML written by the agent.
class WebPageView extends StatelessWidget {
  const WebPageView({super.key, this.fileUrl, this.html, this.interactive = true});
  final String? fileUrl;
  final String? html;
  final bool interactive;

  @override
  Widget build(BuildContext context) {
    final settings = InAppWebViewSettings(
      javaScriptEnabled: true,
      allowFileAccess: true,
      allowFileAccessFromFileURLs: true,
      allowUniversalAccessFromFileURLs: true,
      useHybridComposition: false,
      useWideViewPort: true,
      loadWithOverviewMode: true,
      supportZoom: interactive,
      mediaPlaybackRequiresUserGesture: false,
    );
    final view = html != null
        ? InAppWebView(
            initialSettings: settings,
            initialData: InAppWebViewInitialData(data: html!, baseUrl: WebUri('https://submac.local/')),
          )
        : InAppWebView(initialSettings: settings, initialUrlRequest: URLRequest(url: WebUri(fileUrl ?? 'about:blank')));
    return interactive ? view : IgnorePointer(child: view);
  }
}

/// Plays a video or sound with the phone's built-in web player (no extra app needed).
class MediaView extends StatelessWidget {
  const MediaView({super.key, required this.path});
  final String path;

  @override
  Widget build(BuildContext context) {
    final e = _ext(path);
    final audio = const {'mp3', 'm4a', 'wav', 'ogg', 'aac'}.contains(e);
    final src = 'file://$path';
    final html = '<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">'
        '<style>html,body{margin:0;height:100%;background:#000;display:flex;align-items:center;justify-content:center}'
        'video{width:100%;max-height:100%}audio{width:92%}</style></head><body>'
        '${audio ? '<audio controls autoplay src="$src"></audio>' : '<video controls autoplay playsinline src="$src"></video>'}'
        '</body></html>';
    return InAppWebView(
      initialSettings: InAppWebViewSettings(
        allowFileAccess: true,
        allowFileAccessFromFileURLs: true,
        allowUniversalAccessFromFileURLs: true,
        mediaPlaybackRequiresUserGesture: false,
        useHybridComposition: false,
      ),
      initialData: InAppWebViewInitialData(data: html, baseUrl: WebUri('file:///')),
    );
  }
}

/// PDF pages drawn by Android itself, one picture per page.
class PdfPages extends StatefulWidget {
  const PdfPages({super.key, required this.path});
  final String path;

  @override
  State<PdfPages> createState() => _PdfPagesState();
}

class _PdfPagesState extends State<PdfPages> {
  int? _count;
  String? _error;
  final Map<int, Future<Uint8List?>> _pages = {};

  @override
  void initState() {
    super.initState();
    NativeBridge.call('pdfInfo', {'path': widget.path}).then((v) {
      if (mounted) setState(() => _count = (v as num?)?.toInt() ?? 0);
    }).catchError((Object e) {
      if (mounted) setState(() => _error = '$e');
    });
  }

  Future<Uint8List?> _page(int i, int width) => _pages.putIfAbsent(i, () async {
        final r = await NativeBridge.call('pdfPage', {'path': widget.path, 'page': i, 'width': width});
        return r is Uint8List ? r : null;
      });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    if (_error != null) {
      return Center(child: Text('This PDF won\'t open here. Share it to open it in another app.', style: TextStyle(color: p.muted)));
    }
    if (_count == null) return const Center(child: AgentMark(size: 32, mode: MarkMode.thinking));
    final w = (MediaQuery.of(context).size.width * MediaQuery.of(context).devicePixelRatio).clamp(600, 1600).toInt();
    return InteractiveViewer(
      maxScale: 5,
      child: ListView.builder(
        padding: const EdgeInsets.all(10),
        itemCount: _count,
        itemBuilder: (c, i) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: FutureBuilder<Uint8List?>(
            future: _page(i, w),
            builder: (c, s) => s.data == null
                ? AspectRatio(aspectRatio: 0.707, child: Container(color: p.bubble))
                : Container(
                    decoration: BoxDecoration(border: Border.all(color: p.border, width: 0.6)),
                    child: Image.memory(s.data!, fit: BoxFit.fitWidth),
                  ),
          ),
        ),
      ),
    );
  }
}

class _TextView extends StatelessWidget {
  const _TextView({required this.path, required this.ext});
  final String path;
  final String ext;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    String text;
    try {
      text = File(path).readAsStringSync();
    } catch (_) {
      text = utf8.decode(File(path).readAsBytesSync(), allowMalformed: true);
    }
    if (text.length > 200000) text = '${text.substring(0, 200000)}\n…';
    if (ext == 'md' || ext == 'markdown') {
      return SingleChildScrollView(padding: const EdgeInsets.all(18), child: MarkdownView(text));
    }
    if (ext == 'csv' || ext == 'tsv') {
      final sep = ext == 'tsv' ? '\t' : ',';
      final rows = [
        for (final l in text.split('\n').take(500))
          if (l.trim().isNotEmpty) _splitCsv(l, sep),
      ];
      return SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Table(
            defaultColumnWidth: const IntrinsicColumnWidth(),
            border: TableBorder.all(color: p.border, width: 0.5),
            children: [
              for (var r = 0; r < rows.length; r++)
                TableRow(children: [
                  for (var c = 0; c < (rows.isEmpty ? 0 : rows[0].length); c++)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                      child: Text(c < rows[r].length ? rows[r][c] : '',
                          style: TextStyle(color: p.text, fontSize: AppText.meta, fontWeight: r == 0 ? FontWeight.w600 : FontWeight.w400)),
                    ),
                ]),
            ],
          ),
        ),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(14),
      child: SelectableText(text, style: Brand.mono(size: 12.5, color: p.text)),
    );
  }

  static List<String> _splitCsv(String line, String sep) {
    final out = <String>[];
    final cur = StringBuffer();
    var q = false;
    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '"') {
        if (q && i + 1 < line.length && line[i + 1] == '"') {
          cur.write('"');
          i++;
        } else {
          q = !q;
        }
      } else if (ch == sep && !q) {
        out.add(cur.toString());
        cur.clear();
      } else {
        cur.write(ch);
      }
    }
    out.add(cur.toString().trimRight());
    return out;
  }
}


// ---------------------------------------------------------------- spreadsheets

/// A spreadsheet grid: column letters, row numbers, the first row as the header.
class SheetGrid extends StatelessWidget {
  const SheetGrid({super.key, required this.table, this.maxRows = 5000});
  final SheetTable table;
  final int maxRows;

  static String letters(int i) {
    var n = i + 1, s = '';
    while (n > 0) {
      final r = (n - 1) % 26;
      s = String.fromCharCode(65 + r) + s;
      n = (n - 1) ~/ 26;
    }
    return s;
  }

  static String cell(dynamic v) {
    if (v is double) {
      if (v == v.roundToDouble() && v.abs() < 1e15) return v.toInt().toString();
      return double.parse(v.toStringAsFixed(6)).toString();
    }
    return '${v ?? ''}';
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final cols = table.columns.length;
    if (cols == 0) return Center(child: Text('This sheet is empty', style: TextStyle(color: p.muted)));
    final rows = table.rows.length > maxRows ? table.rows.sublist(0, maxRows) : table.rows;
    // Column widths from the header and the first rows.
    final widths = List<double>.generate(cols, (c) {
      var len = table.columns[c].length;
      for (final r in rows.take(200)) {
        if (c < r.length) len = len < cell(r[c]).length ? cell(r[c]).length : len;
      }
      return (len * 7.6 + 24).clamp(64, 280).toDouble();
    });
    const numW = 44.0;
    final total = widths.fold<double>(numW, (a, b) => a + b);
    final head = TextStyle(color: p.text, fontSize: AppText.meta, fontWeight: FontWeight.w700);
    final body = TextStyle(color: p.text, fontSize: AppText.meta);
    final dim = TextStyle(color: p.muted, fontSize: AppText.caption);
    Widget box(Widget child, double w, {Color? bg, bool right = false}) => Container(
          width: w,
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          alignment: right ? AlignmentDirectional.centerEnd : AlignmentDirectional.centerStart,
          decoration: BoxDecoration(
            color: bg,
            border: Border(right: BorderSide(color: p.border, width: 0.5), bottom: BorderSide(color: p.border, width: 0.5)),
          ),
          child: child,
        );
    return Column(children: [
      Expanded(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: total,
            child: Column(children: [
              Row(children: [
                box(const SizedBox(), numW, bg: p.bubble),
                for (var c = 0; c < cols; c++) box(Text(letters(c), style: dim), widths[c], bg: p.bubble),
              ]),
              Row(children: [
                box(Text('1', style: dim), numW, bg: p.bubble),
                for (var c = 0; c < cols; c++)
                  box(Text(table.columns[c], maxLines: 1, overflow: TextOverflow.ellipsis, style: head), widths[c], bg: p.sheet),
              ]),
              Expanded(
                child: ListView.builder(
                  itemCount: rows.length,
                  itemExtent: 34,
                  itemBuilder: (_, i) {
                    final r = rows[i];
                    return Row(children: [
                      box(Text('${i + 2}', style: dim), numW, bg: p.bubble),
                      for (var c = 0; c < cols; c++)
                        box(
                          Text(c < r.length ? cell(r[c]) : '', maxLines: 1, overflow: TextOverflow.ellipsis, style: body),
                          widths[c],
                          right: c < r.length && r[c] is num,
                        ),
                    ]);
                  },
                ),
              ),
            ]),
          ),
        ),
      ),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        color: p.bubble,
        child: Text(
            '${table.rows.length} rows · $cols columns${table.rows.length > maxRows ? ' · showing the first $maxRows' : ''}',
            style: TextStyle(color: p.muted, fontSize: AppText.micro)),
      ),
    ]);
  }
}

class _XlsxView extends StatefulWidget {
  const _XlsxView({required this.path});
  final String path;
  @override
  State<_XlsxView> createState() => _XlsxViewState();
}

class _XlsxViewState extends State<_XlsxView> {
  Map<String, SheetTable>? _sheets;
  String? _error;
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    File(widget.path).readAsBytes().then((b) {
      final s = SheetTable.fromXlsx(b);
      if (mounted) setState(() => _sheets = s);
    }).catchError((Object _) {
      if (mounted) setState(() => _error = 'This spreadsheet won\'t open here. Share it to open it in another app.');
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    if (_error != null) return Center(child: Padding(padding: const EdgeInsets.all(32), child: Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: p.muted))));
    if (_sheets == null) return const Center(child: AgentMark(size: 32, mode: MarkMode.thinking));
    if (_sheets!.isEmpty) return Center(child: Text('This spreadsheet is empty', style: TextStyle(color: p.muted)));
    final names = _sheets!.keys.toList();
    final tab = _tab.clamp(0, names.length - 1);
    return Column(children: [
      Expanded(child: SheetGrid(key: ValueKey(names[tab]), table: _sheets![names[tab]]!)),
      if (names.length > 1)
        SizedBox(
          height: 46,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            children: [
              for (var i = 0; i < names.length; i++)
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 6),
                  child: LuxWordTab(label: Text(names[i]), selected: i == tab, onSelected: (_) => setState(() => _tab = i)),
                ),
            ],
          ),
        ),
    ]);
  }
}

class _CsvView extends StatelessWidget {
  const _CsvView({required this.path});
  final String path;
  @override
  Widget build(BuildContext context) {
    try {
      final text = utf8.decode(File(path).readAsBytesSync(), allowMalformed: true);
      return SheetGrid(table: SheetTable.fromCsv(text));
    } catch (_) {
      return _TextView(path: path, ext: 'txt');
    }
  }
}

// ---------------------------------------------------------------- Word and PowerPoint

Widget _officeBlocks(BuildContext context, List<OfficeBlock> blocks) {
  final p = Palette.of(context);
  final sizes = {1: 26.0, 2: 22.0, 3: 19.0, 4: 17.0, 5: 16.0, 6: 15.0};
  return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    for (final b in blocks)
      if (b.isTable)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Table(
              defaultColumnWidth: const IntrinsicColumnWidth(),
              border: TableBorder.all(color: p.border, width: 0.6),
              children: [
                for (var r = 0; r < b.rows.length; r++)
                  TableRow(
                    decoration: r == 0 ? BoxDecoration(color: p.bubble) : null,
                    children: [
                      for (var c = 0; c < b.rows.map((x) => x.length).reduce((a, x) => a > x ? a : x); c++)
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 260),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                            child: SelectableText(c < b.rows[r].length ? b.rows[r][c] : '',
                                style: TextStyle(color: p.text, fontSize: AppText.meta, fontWeight: r == 0 ? FontWeight.w600 : FontWeight.w400)),
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        )
      else if (b.text.trim().isEmpty)
        const SizedBox(height: 10)
      else
        Padding(
          padding: EdgeInsetsDirectional.only(top: b.level > 0 ? 12 : 3, bottom: b.level > 0 ? 6 : 3, start: b.bullet ? 6 : 0),
          child: SelectableText(
            '${b.bullet ? '•  ' : ''}${b.text}',
            style: b.level > 0
                ? Brand.serif(size: sizes[b.level] ?? 16, color: p.text)
                : TextStyle(color: p.text, fontSize: AppText.body, height: 1.45, fontWeight: b.bold ? FontWeight.w600 : FontWeight.w400),
          ),
        ),
  ]);
}

class _DocxView extends StatelessWidget {
  const _DocxView({required this.path});
  final String path;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    List<OfficeBlock> blocks;
    try {
      blocks = OfficeReader.docx(File(path).readAsBytesSync());
    } catch (_) {
      return Center(child: Padding(padding: const EdgeInsets.all(32), child: Text('This document won\'t open here. Share it to open it in another app.', textAlign: TextAlign.center, style: TextStyle(color: p.muted))));
    }
    return Container(
      color: p.bubble,
      child: ListView(padding: const EdgeInsets.all(12), children: [
        Container(
          padding: const EdgeInsetsDirectional.fromSTEB(22, 26, 22, 30),
          decoration: BoxDecoration(color: p.sheet, borderRadius: BorderRadius.circular(6), border: Border.all(color: p.border, width: 0.6)),
          child: blocks.isEmpty ? Text('This document has no text.', style: TextStyle(color: p.muted)) : _officeBlocks(context, blocks),
        ),
        const SizedBox(height: 8),
        Text('Text and tables shown. Pictures and exact layout appear when you open it in Word.', textAlign: TextAlign.center, style: TextStyle(color: p.muted, fontSize: AppText.micro)),
      ]),
    );
  }
}

class _PptxView extends StatelessWidget {
  const _PptxView({required this.path});
  final String path;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    List<OfficeSlide> slides;
    try {
      slides = OfficeReader.pptx(File(path).readAsBytesSync());
    } catch (_) {
      return Center(child: Padding(padding: const EdgeInsets.all(32), child: Text('These slides won\'t open here. Share them to open them in another app.', textAlign: TextAlign.center, style: TextStyle(color: p.muted))));
    }
    return Container(
      color: p.bubble,
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: slides.length + 1,
        itemBuilder: (c, i) {
          if (i == slides.length) {
            return Padding(
              padding: const EdgeInsets.all(8),
              child: Text('Slide text shown. Pictures and design appear when you open it in PowerPoint.', textAlign: TextAlign.center, style: TextStyle(color: p.muted, fontSize: AppText.micro)),
            );
          }
          final s = slides[i];
          return Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsetsDirectional.fromSTEB(18, 14, 18, 18),
            constraints: const BoxConstraints(minHeight: 180),
            decoration: BoxDecoration(color: p.sheet, borderRadius: BorderRadius.circular(8), border: Border.all(color: p.border, width: 0.6)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('SLIDE ${s.number}', style: TextStyle(color: p.muted, fontSize: AppText.caption, letterSpacing: 0.9, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              _officeBlocks(c, s.blocks),
            ]),
          );
        },
      ),
    );
  }
}
