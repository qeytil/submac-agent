import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:provider/provider.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:io';
import 'dart:typed_data';

import '../app_state.dart';
import '../screens/preview_screen.dart' show openPreview;
import '../services/tools.dart' show AgentTools;
import '../services/turn_visuals.dart';
import 'visual_card.dart';
import '../services/reply_text.dart' show cleanGlyphs;
import '../theme.dart';
import 'chat_logic.dart';
import 'math_text.dart';
import 'output_cards.dart';
import '../ui/tokens.dart';

class MarkdownView extends StatelessWidget {
  final String data;
  const MarkdownView(this.data, {super.key});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final base = TextStyle(fontSize: Lux.read, height: Lux.readHeight, color: p.text);
    return MarkdownBody(
      // U+2010/2011/202F have no glyph in the app's fonts and drew as "_" (CB-43).
      data: cleanGlyphs(fixInlineCards(data)),
      // Selection lives in the message's long-press sheet ("Select text"), so a tap or a hold on a reply
      // opens its quiet actions instead of starting a text selection.
      selectable: false,
      extensionSet: md.ExtensionSet.gitHubFlavored,
      onTapLink: (text, href, title) {
        // A bad or relative link from the model never crashes the tap; bare domains get https.
        if (href == null || href.trim().isEmpty) return;
        var h = href.trim();
        // A file the agent made ([the chart](chart.html)): open it in the app, not as a web address.
        final local = localFileOf(h);
        if (local != null) {
          openPreview(context, local);
          return;
        }
        if (!h.contains(':')) h = 'https://$h';
        final u = Uri.tryParse(h);
        if (u == null) return;
        launchUrl(u, mode: LaunchMode.externalApplication).catchError((_) => false);
      },
      // Pictures inside a sentence (one on its own line is lifted into a card before this, see TurnVisuals.liftImages):
      // a file the agent made, an SVG, a data URI or a web picture, tap to open.
      sizedImageBuilder: (c) => InlinePicture(src: c.uri.toString(), alt: c.alt ?? ''),
      blockSyntaxes: [MathBlockSyntax()],
      inlineSyntaxes: [MathInlineSyntax()],
      builders: {
        'code': CodeElementBuilder(),
        'mathblock': MathBuilder(display: true),
        'mathinline': MathBuilder(display: false),
      },
      styleSheet: MarkdownStyleSheet(
        p: base,
        a: base.copyWith(decoration: TextDecoration.underline),
        strong: base.copyWith(fontWeight: FontWeight.w700),
        em: base.copyWith(fontStyle: FontStyle.italic),
        h1: Brand.serif(size: 23, color: p.text, height: 1.25),
        h2: Brand.serif(size: 20, color: p.text, height: 1.3),
        h3: base.copyWith(fontSize: AppText.lead, fontWeight: FontWeight.w600, height: 1.35),
        h4: base.copyWith(fontSize: AppText.body, fontWeight: FontWeight.w600),
        // Hark-style long text (owner 2026-10-24): headings get air above them so sections read apart, without rules.
        h1Padding: const EdgeInsets.only(top: Space.x2),
        h2Padding: const EdgeInsets.only(top: Space.x2),
        h3Padding: const EdgeInsets.only(top: Space.x1),
        listBullet: base.copyWith(color: p.muted),
        listIndent: Space.x6,
        blockSpacing: Space.x3 + 2,
        code: Brand.mono(size: 14, color: p.text).copyWith(fontWeight: FontWeight.w500),
        codeblockDecoration: const BoxDecoration(color: Colors.transparent),
        codeblockPadding: EdgeInsets.zero,
        blockquote: base.copyWith(color: p.muted, fontStyle: FontStyle.italic),
        blockquoteDecoration: const BoxDecoration(),
        // The markdown package wants plain EdgeInsets, so pick the side by reading direction.
        blockquotePadding: Directionality.of(context) == TextDirection.rtl ? const EdgeInsets.only(right: 12) : const EdgeInsets.only(left: 12),
        tableBody: base.copyWith(fontSize: AppText.meta),
        tableHead: base.copyWith(fontSize: AppText.meta, fontWeight: FontWeight.w700),
        // Tables are open (UI rules): no frame, no lines, no fill. Row air and a semibold head do the separating.
        tableBorder: const TableBorder(),
        tableHeadAlign: TextAlign.start,
        tableCellsDecoration: const BoxDecoration(),
        tableCellsPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        // Wide tables scroll sideways instead of squeezing every column into a sliver.
        tableColumnWidth: const _CappedColumnWidth(),
        horizontalRuleDecoration: const BoxDecoration(),
      ),
    );
  }
}

/// The phone path behind a link or picture the agent wrote, when it is a file here (a workspace path, absolute or
/// relative, or file://). Null for web links, mail links and anything not on the phone.
String? localFileOf(String href) {
  final h = href.trim();
  final scheme = RegExp(r'^[a-z][a-z0-9+.-]*:', caseSensitive: false).hasMatch(h);
  if (h.isEmpty || h.startsWith('#') || (scheme && !h.toLowerCase().startsWith('file:'))) return null;
  // A bare domain ("example.com") is a web link, not a file.
  if (!h.contains('/') && !TurnVisuals.isVisual(h) && !RegExp(r'\.(pdf|csv|txt|md|json|xlsx|docx|pptx|wav|mp3)$', caseSensitive: false).hasMatch(h)) {
    return null;
  }
  try {
    final p = AgentTools.cardPath(h);
    return p.startsWith('/') && File(p).existsSync() ? p : null;
  } catch (_) {
    return null;
  }
}

/// A picture inside a line of text: the agent's own file (PNG, JPEG, SVG...), an SVG or PNG data URI, or a web
/// picture. Bounded in height so the chat stays scannable; a tap opens it full screen. Nothing at all when it cannot
/// be drawn (never a broken box).
class InlinePicture extends StatelessWidget {
  const InlinePicture({super.key, required this.src, this.alt = ''});
  final String src;
  final String alt;

  static const _maxHeight = 300.0;

  @override
  Widget build(BuildContext context) {
    final s = src.trim();
    Widget? pic;
    String? open;
    final svg = s.toLowerCase().contains('svg');
    if (s.startsWith('data:')) {
      final bytes = TurnVisuals.dataBytes(s);
      if (bytes != null) {
        final b = Uint8List.fromList(bytes);
        pic = s.startsWith('data:image/svg')
            ? SvgPicture.memory(b, fit: BoxFit.contain, errorBuilder: (c, e, t) => const SizedBox.shrink())
            : Image.memory(b, fit: BoxFit.contain, errorBuilder: (c, e, t) => const SizedBox.shrink());
      }
    } else if (s.startsWith('http://') || s.startsWith('https://')) {
      pic = svg && s.split('?').first.toLowerCase().endsWith('.svg')
          ? SvgPicture.network(s, fit: BoxFit.contain, errorBuilder: (c, e, t) => const SizedBox.shrink())
          : Image.network(s, fit: BoxFit.contain, errorBuilder: (c, e, t) => const SizedBox.shrink());
    } else {
      final path = localFileOf(s);
      if (path != null) {
        open = path;
        pic = path.toLowerCase().endsWith('.svg')
            ? SvgPicture.file(File(path), fit: BoxFit.contain, errorBuilder: (c, e, t) => const SizedBox.shrink())
            : Image.file(File(path), fit: BoxFit.contain, errorBuilder: (c, e, t) => const SizedBox.shrink());
      }
    }
    if (pic == null) return const SizedBox.shrink();
    final target = open;
    return Semantics(
      image: true,
      label: alt.isEmpty ? 'Picture' : alt,
      child: GestureDetector(
        onTap: target == null ? null : () => openPreview(context, target),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: _maxHeight),
          child: ClipRRect(borderRadius: Radii.rowAll, child: pic),
        ),
      ),
    );
  }
}

/// Columns as wide as their content, but never wider than 240 px: long cells wrap, and a wide table scrolls sideways.
/// (Subclasses IntrinsicColumnWidth so the markdown table keeps its horizontal scroll.)
class _CappedColumnWidth extends IntrinsicColumnWidth {
  const _CappedColumnWidth();

  @override
  double maxIntrinsicWidth(Iterable<RenderBox> cells, double containerWidth) {
    final full = super.maxIntrinsicWidth(cells, containerWidth);
    final least = super.minIntrinsicWidth(cells, containerWidth);
    return math.min(full, math.max(240.0, least));
  }
}

class CodeElementBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfterWithContext(
      BuildContext context, md.Element element, TextStyle? preferredStyle, TextStyle? parentStyle) {
    final text = element.textContent;
    final cls = element.attributes['class'];
    final isBlock = cls != null || text.contains('\n');
    if (!isBlock) return null;
    final lang = cls?.replaceFirst('language-', '') ?? '';
    if (cardLanguages.contains(lang)) {
      return buildOutputCard(lang, text) ?? const SizedBox.shrink();
    }
    // SVG markup in a fence (```svg / ```xml) is a drawing: shown drawn, as the ```visual card.
    if ((lang == 'svg' || lang == 'xml') && VisualCard.isSvg(text)) return VisualCard(text);
    return CodeBlock(code: text.replaceAll(RegExp(r'\n$'), ''), language: lang);
  }
}

const _runnable = {'sh', 'bash', 'shell', 'zsh', 'console'};

class CodeBlock extends StatefulWidget {
  final String code;
  final String language;
  const CodeBlock({super.key, required this.code, required this.language});

  @override
  State<CodeBlock> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<CodeBlock> {
  String? _output;
  bool _running = false;

  String get code => widget.code;
  String get language => widget.language;

  Future<void> _run() async {
    final state = context.read<AppState>();
    setState(() {
      _running = true;
      _output = null;
    });
    final out = await state.runToolWithApproval('run_shell', {'command': code});
    if (mounted) {
      setState(() {
        _running = false;
        _output = out.trim();
      });
    }
  }

  static const _names = {
    'py': 'Python', 'python': 'Python', 'js': 'JavaScript', 'javascript': 'JavaScript', 'ts': 'TypeScript',
    'typescript': 'TypeScript', 'dart': 'Dart', 'kt': 'Kotlin', 'kotlin': 'Kotlin', 'java': 'Java', 'sh': 'Shell',
    'bash': 'Shell', 'shell': 'Shell', 'zsh': 'Shell', 'console': 'Shell', 'html': 'HTML', 'css': 'CSS', 'sql': 'SQL',
    'json': 'JSON', 'yaml': 'YAML', 'yml': 'YAML', 'go': 'Go', 'rust': 'Rust', 'rs': 'Rust', 'c': 'C', 'cpp': 'C++',
    'swift': 'Swift', 'php': 'PHP', 'rb': 'Ruby', 'ruby': 'Ruby', 'md': 'Markdown', 'xml': 'XML',
  };

  /// "Python" for py, the fence word as written for anything else, "Code" when there is none.
  static String languageName(String lang) => _names[lang.toLowerCase()] ?? (lang.isEmpty ? 'Code' : lang);

  /// Hark's code card: the darkest card fill, the language as a muted label, a Copy corner button, and the code in
  /// plain monochrome mono straight on the card (no inner box, no line numbers). Shell snippets keep Run.
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final mono = Brand.mono(size: AppText.meta, color: p.text, height: 1.45);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.x1),
      child: DecoratedBox(
        decoration: BoxDecoration(color: p.code, borderRadius: Radii.sheetAll),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(Space.x4, Space.x3, Space.x3, Space.x4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: Text(languageName(language), style: AppText.metaStyle.copyWith(color: p.muted))),
                  if (_runnable.contains(language) && context.read<AppState>().agentEnabled)
                    TextButton(
                      style: TextButton.styleFrom(foregroundColor: p.text, visualDensity: VisualDensity.compact),
                      onPressed: _running ? null : _run,
                      child: Text(_running ? 'Running' : 'Run', style: AppText.microStyle.copyWith(fontWeight: FontWeight.w600)),
                    ),
                  HarkCornerButton(icon: 'copy', label: 'Copy', onTap: () => harkCopy(context, code)),
                ],
              ),
              const SizedBox(height: Space.x3),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Directionality(textDirection: TextDirection.ltr, child: SelectableText(code, style: mono)),
              ),
              if (_output != null)
                Container(
                  padding: const EdgeInsetsDirectional.only(top: Space.x3),
                  constraints: const BoxConstraints(maxHeight: 260),
                  child: SingleChildScrollView(
                    child: SelectableText(_output!, style: mono.copyWith(fontSize: AppText.micro, color: p.muted)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
