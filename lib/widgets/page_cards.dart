import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:share_plus/share_plus.dart';

import '../models.dart';
import '../screens/preview_screen.dart';
import '../screens/site_screens.dart' show showPublishSheet;
import '../theme.dart';
import '../ui/tokens.dart';
import 'chat/message_actions.dart';
import 'sub_icon.dart';

/// Website / page cards, after the hark.com study (2026-10-24).
///
/// While the agent writes a page, [PageBuildCard] shows the build in one dark card: the page title, the phase word
/// ("writing", "done") with the elapsed time, the line count, the last lines of source in monochrome mono, and one
/// faded status pill. When the file is written the card settles into its done state with "Page built" and an
/// "Open page" button. The finished page itself is the [PageCard] (hark_cards.dart): thumbnail, title, "Page built by
/// Telesia", Open page (in-app preview with Share and Publish).

/// True when a tool call writes a web page (shown as a build card instead of a step line).
bool isPageWrite(ToolCall c) {
  if (c.name != 'write_file') return false;
  final a = pageWriteArgs(c.arguments);
  return RegExp(r'\.html?$', caseSensitive: false).hasMatch(a.$1);
}

/// (path, content) of a write_file call; tolerant of half-streamed JSON.
(String, String) pageWriteArgs(String arguments) {
  try {
    final j = jsonDecode(arguments);
    if (j is Map) return ('${j['path'] ?? ''}', '${j['content'] ?? ''}');
  } catch (_) {}
  final path = RegExp(r'"path"\s*:\s*"([^"]*)"').firstMatch(arguments)?.group(1) ?? '';
  final m = RegExp(r'"content"\s*:\s*"').firstMatch(arguments);
  var content = m == null ? '' : arguments.substring(m.end);
  content = content.replaceAll(r'\n', '\n').replaceAll(r'\"', '"').replaceAll(r'\t', '  ');
  return (path, content);
}

/// The page's own title (<title>), else its file name without the extension.
String pageTitleOf(String html, String path) {
  final m = RegExp(r'<title>([^<]*)</title>', caseSensitive: false).firstMatch(html);
  final t = m?.group(1)?.trim() ?? '';
  if (t.isNotEmpty) return t;
  final name = path.split('/').last.replaceAll(RegExp(r'\.html?$', caseSensitive: false), '');
  return name.isEmpty ? 'Your page' : name.replaceAll(RegExp(r'[-_]+'), ' ');
}


// ───────────────────────────────── One card per build (owner bug 2026-10-24)
//
// A page build used to show two different previews: the build card flipped to "Page built / Open page" the moment its
// first write_file returned (while append_file, fixes and the page check were still running), then the final reply's
// ```file card drew a second, iframe preview. A rewrite in a fix round even made a second build card, and a reply held
// on screen during the finish check carried its own page card early. Now each page gets exactly ONE card per turn: the
// first write of that page owns it, later writes/appends of the same page feed it, and it settles into its done state
// only when the whole task has finished. Page cards in the turn's replies are hidden while the task runs, and a page
// that has a build card never gets a second preview card.

/// The path's segments without "file://", "./" or empty parts, lower case.
List<String> _segs(String path) {
  var p = path.trim().replaceAll('\\', '/');
  if (p.startsWith('file://')) p = p.substring(7);
  p = p.replaceAll('%20', ' ');
  return [for (final s in p.split('/')) if (s.isNotEmpty && s != '.') s.toLowerCase()];
}

/// True when two paths name the same page: a relative path ("sites/x/index.html") matches the end of the absolute one
/// the tool resolved it to ("/data/…/workspace/sites/x/index.html").
bool samePage(String a, String b) {
  final x = _segs(a), y = _segs(b);
  if (x.isEmpty || y.isEmpty) return false;
  final (short, long) = x.length <= y.length ? (x, y) : (y, x);
  for (var i = 1; i <= short.length; i++) {
    if (short[short.length - i] != long[long.length - i]) return false;
  }
  return true;
}

/// One page built in a turn: the call that owns its card, every call that wrote to it, and the page as it stands.
class PageBuild {
  PageBuild(this.owner, this.path, this.source) : calls = [owner];
  final ToolCall owner;
  final String path;
  final List<ToolCall> calls;
  String source;

  /// The last call that wrote to the page (its result says where the file went).
  ToolCall get last => calls.last;
}

/// The page builds of one turn (every assistant step since the user last wrote), in order.
class PageBuildPlan {
  PageBuildPlan._(this.builds);
  final List<PageBuild> builds;

  static final empty = PageBuildPlan._(const []);

  /// Works out the builds from the tool calls of one turn, oldest first.
  factory PageBuildPlan.of(Iterable<ToolCall> calls) {
    final out = <PageBuild>[];
    for (final c in calls) {
      if (c.name != 'write_file' && c.name != 'append_file') continue;
      final (path, content) = pageWriteArgs(c.arguments);
      if (!RegExp(r'\.html?$', caseSensitive: false).hasMatch(path)) continue;
      final at = out.indexWhere((b) => samePage(b.path, path));
      if (at < 0) {
        // An append to a page this turn never wrote still starts its card (it was begun in an earlier turn).
        out.add(PageBuild(c, path, content));
        continue;
      }
      final b = out[at];
      b.calls.add(c);
      // A rewrite starts the page over; an append adds to it.
      b.source = c.name == 'write_file' ? content : '${b.source}${b.source.endsWith('\n') || content.startsWith('\n') ? '' : '\n'}$content';
    }
    return PageBuildPlan._(out);
  }

  /// The build whose card [callId] owns, or null.
  PageBuild? ownedBy(String callId) {
    for (final b in builds) {
      if (b.owner.id == callId) return b;
    }
    return null;
  }

  /// True for a page write that feeds another call's card (it shows nothing of its own).
  bool feeds(String callId) => builds.any((b) => b.owner.id != callId && b.calls.any((c) => c.id == callId));

  /// True when [path] is a page this turn built (its preview is the build card, never a second card).
  bool built(String path) => builds.any((b) => samePage(b.path, path));
}

/// Takes the page previews out of a reply: every ```page block and every ```file card of a web page while the task is
/// still [running] (no preview of a page that is not finished), and afterwards the ```file cards of pages that already
/// have their build card in this turn ([plan]). Anything else is left exactly as it was.
String hidePageCards(String text, {required bool running, PageBuildPlan? plan}) {
  if (!text.contains('```')) return text;
  final b = plan ?? PageBuildPlan.empty;
  if (!running && b.builds.isEmpty) return text;
  var out = text.replaceAllMapped(RegExp(r'\n?[ \t]*```(file|page)[ \t]*\n([\s\S]*?)(\n[ \t]*```[ \t]*(?=\n|$)|$)'), (m) {
    final lang = m.group(1)!;
    final body = m.group(2)!.trim();
    final first = body.split('\n').first.trim();
    final isPagePath = RegExp(r'\.html?$', caseSensitive: false).hasMatch(first);
    if (lang == 'file' && !isPagePath) return m.group(0)!;
    if (running) return '';
    if (isPagePath && b.built(first)) return '';
    return m.group(0)!;
  });
  // A card written on one line ("```file /x/index.html```").
  out = out.replaceAllMapped(RegExp(r'```(file|page)[ \t]+([^\n`]+?)[ \t]*```'), (m) {
    final first = m.group(2)!.trim();
    if (!RegExp(r'\.html?$', caseSensitive: false).hasMatch(first)) return m.group(0)!;
    return running || b.built(first) ? '' : m.group(0)!;
  });
  return out == text ? text : out.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
}

enum PagePhase { writing, done, stopped }

class PageBuildCard extends StatefulWidget {
  const PageBuildCard({super.key, required this.call, this.result, this.running = true, this.onOpen, this.source, this.path});
  final ToolCall call;

  /// The result of the last write to this page (null while it is being written).
  final String? result;

  /// The whole task is still going. The card stays in its building state until the task has finished (later parts,
  /// fixes and the page check all happen while it runs), so it never shows "Page built" or Open page early.
  final bool running;

  /// The page as it stands after every write and append of this turn (defaults to [call]'s own content).
  final String? source;

  /// The page's path as asked (defaults to [call]'s own path).
  final String? path;

  /// Opens the finished page; defaults to the in-app preview of the written file.
  final void Function(BuildContext context, String path)? onOpen;

  PagePhase get phase => running ? PagePhase.writing : (result != null ? PagePhase.done : PagePhase.stopped);

  @override
  State<PageBuildCard> createState() => _PageBuildCardState();
}

class _PageBuildCardState extends State<PageBuildCard> {
  final _started = DateTime.now();
  Duration _took = Duration.zero;
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(PageBuildCard old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (widget.phase == PagePhase.writing) {
      _clock ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _took = DateTime.now().difference(_started));
      });
    } else {
      _clock?.cancel();
      _clock = null;
    }
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  static String clock(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  /// The file the page went to: the tool's own answer names it when it resolved a relative path.
  String _path(String asked) {
    final r = widget.result ?? '';
    final m = RegExp(r'(/[^\s]+\.html?)').firstMatch(r);
    return m?.group(1) ?? asked;
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final (askedOwn, htmlOwn) = pageWriteArgs(widget.call.arguments);
    final asked = widget.path ?? askedOwn;
    final html = widget.source ?? htmlOwn;
    final title = pageTitleOf(html, asked);
    final lines = html.isEmpty ? 0 : '\n'.allMatches(html.trimRight()).length + 1;
    final phase = widget.phase;
    final word = switch (phase) { PagePhase.writing => lines == 0 ? 'starting' : 'writing', PagePhase.done => 'done', PagePhase.stopped => 'stopped' };
    final tail = html.trimRight().split('\n');
    final shown = tail.length > 8 ? tail.sublist(tail.length - 8) : tail;
    final path = _path(asked);
    return Semantics(
      container: true,
      label: phase == PagePhase.done ? 'Page built: $title' : 'Building your page: $title',
      child: GestureDetector(
        // Done: hold for Open page, Publish and Share (the build card is the page's only card).
        onLongPress: phase == PagePhase.done ? () => _more(context, path) : null,
        child: DecoratedBox(
        decoration: BoxDecoration(color: p.code, borderRadius: Radii.sheetAll),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(Space.x4, Space.x4, Space.x4, Space.x4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Expanded(
                child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: AppText.bodyStyle.copyWith(color: p.text, fontWeight: FontWeight.w500)),
              ),
              const SizedBox(width: Space.x3),
              Text(phase == PagePhase.writing ? '$word ${clock(_took)}' : word,
                  key: const ValueKey('page-build-phase'), style: Brand.mono(size: AppText.micro, color: p.muted)),
            ]),
            const SizedBox(height: Space.x1),
            Row(children: [
              Expanded(
                child: Text(
                  switch (phase) { PagePhase.writing => 'Building your page', PagePhase.done => 'Page built', PagePhase.stopped => 'Stopped before the page was finished' },
                  style: AppText.metaStyle.copyWith(color: p.muted),
                ),
              ),
              if (lines > 0) Text('$lines ${lines == 1 ? 'line' : 'lines'}', style: AppText.metaStyle.copyWith(color: p.muted)),
            ]),
            if (phase != PagePhase.done && shown.any((l) => l.trim().isNotEmpty)) ...[
              const SizedBox(height: Space.x3),
              ShaderMask(
                // The newest lines are brightest; older ones fade upward.
                shaderCallback: (r) => LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [p.code.withValues(alpha: 0.1), p.text],
                ).createShader(r),
                blendMode: BlendMode.modulate,
                child: Text(
                  shown.join('\n'),
                  maxLines: 8,
                  overflow: TextOverflow.clip,
                  textDirection: TextDirection.ltr,
                  style: Brand.mono(size: AppText.micro, color: p.muted, height: 1.45),
                ),
              ),
            ],
            if (phase == PagePhase.done) ...[
              const SizedBox(height: Space.x3),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: OpenPageButton(onTap: () => (widget.onOpen ?? _openDefault)(context, path)),
              ),
            ],
          ]),
        ),
      ),
      ),
    );
  }

  void _more(BuildContext context, String path) => showMessageActions(context, actions: [
        MessageAction('Open page', 'expand', () => (widget.onOpen ?? _openDefault)(context, path)),
        MessageAction('Publish', 'send', () => showPublishSheet(context, path)),
        MessageAction('Share', 'share', () => SharePlus.instance.share(ShareParams(files: [XFile(path)]))),
      ]);

  static void _openDefault(BuildContext context, String path) => openPreview(context, path);
}

/// Hark's "Open page" button: a rounded pill in the button family with the expand glyph.
class OpenPageButton extends StatelessWidget {
  const OpenPageButton({super.key, required this.onTap, this.label = 'Open page'});
  final VoidCallback onTap;
  final String label;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Semantics(
      container: true,
      button: true,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: Space.x4),
          decoration: BoxDecoration(color: p.text, borderRadius: BorderRadius.circular(Radii.pill)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            SubIcon('expand', size: IconSize.sm, color: p.bg),
            const SizedBox(width: Space.x2),
            Text(label, style: AppText.metaStyle.copyWith(color: p.bg, fontWeight: FontWeight.w500)),
          ]),
        ),
      ),
    );
  }
}
