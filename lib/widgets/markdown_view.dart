import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
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
      data: fixInlineCards(data),
      // Selection lives in the message's long-press sheet ("Select text"), so a tap or a hold on a reply
      // opens its quiet actions instead of starting a text selection.
      selectable: false,
      extensionSet: md.ExtensionSet.gitHubFlavored,
      onTapLink: (text, href, title) {
        // A bad or relative link from the model never crashes the tap; bare domains get https.
        if (href == null || href.trim().isEmpty) return;
        var h = href.trim();
        if (!h.contains(':')) h = 'https://$h';
        final u = Uri.tryParse(h);
        if (u == null) return;
        launchUrl(u, mode: LaunchMode.externalApplication).catchError((_) => false);
      },
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
