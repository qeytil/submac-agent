import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../services/reply_text.dart' show cleanGlyphs;
import '../theme.dart';
import 'chat_logic.dart';
import 'code_syntax.dart';
import 'lux_kit.dart';
import 'sub_icon.dart';
import '../ui/i18n.dart';
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

  /// The code card (fix/ui-restyle): a quiet surface one step off the page ([Palette.code]), the language as a muted
  /// label, a Copy word that says "Copied" for a moment, and the code in syntax-toned monospace that scrolls sideways.
  /// Code always reads left to right, even in an Arabic chat; the label row follows the chat's direction.
  ///
  /// Root cause of the black box (owner, 2026-10-26): in daylight [Palette.code] was the ink colour (#121110), the same
  /// as the code text, so the card painted ink on ink. Shell snippets keep Run.
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final mono = Brand.mono(size: AppText.meta, color: p.text, height: 1.5);
    final spans = CodeSyntax.spans(code, language, base: mono, ink: CodeInk.of(context));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.x1),
      child: DecoratedBox(
        key: const ValueKey('code-surface'),
        decoration: BoxDecoration(color: p.code, borderRadius: Radii.rowAll),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(Space.x4, Space.x2, Space.x2, Space.x4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: Text(languageName(language), style: AppText.microStyle.copyWith(color: p.muted))),
                  if (_runnable.contains(language) && context.read<AppState>().agentEnabled)
                    _CodeWord(label: _running ? tr('Running') : tr('Run'), onTap: _running ? null : _run),
                  _CodeWord(
                    key: const ValueKey('code-copy'),
                    label: _copied ? tr('Copied') : tr('Copy'),
                    icon: _copied ? 'check' : 'copy',
                    onTap: _copy,
                  ),
                ],
              ),
              const SizedBox(height: Space.x2),
              Directionality(
                textDirection: TextDirection.ltr,
                child: SingleChildScrollView(
                  key: const ValueKey('code-scroll'),
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsetsDirectional.only(end: Space.x2),
                  child: SelectableText.rich(spans, key: const ValueKey('code-text'), style: mono, textDirection: TextDirection.ltr),
                ),
              ),
              if (_output != null)
                Container(
                  padding: const EdgeInsetsDirectional.only(top: Space.x3),
                  constraints: const BoxConstraints(maxHeight: 260),
                  child: SingleChildScrollView(
                    child: Directionality(
                      textDirection: TextDirection.ltr,
                      child: SelectableText(_output!, style: mono.copyWith(fontSize: AppText.micro, color: p.muted)),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  bool _copied = false;
  Timer? _copiedTimer;

  void _copy() {
    Clipboard.setData(ClipboardData(text: code));
    setState(() => _copied = true);
    _copiedTimer?.cancel();
    _copiedTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  void dispose() {
    _copiedTimer?.cancel();
    super.dispose();
  }
}

/// A quiet word action on the code card (Copy, Run): an optional SubMac glyph and the word, no box.
class _CodeWord extends StatelessWidget {
  const _CodeWord({super.key, required this.label, this.icon, this.onTap});
  final String label;
  final String? icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final c = onTap == null ? p.faint : p.text;
    return LuxTap(
      onTap: onTap,
      label: label,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 40, minWidth: 48),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.x2),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[SubIcon(icon!, size: IconSize.sm, color: c), const SizedBox(width: Space.x1 + 2)],
            AnimatedSwitcher(
              duration: SubMotion.of(context, LuxMotion.quick),
              switchInCurve: LuxMotion.ease,
              switchOutCurve: SubMotion.leave,
              layoutBuilder: SubMotion.topStartLayout,
              child: Text(label, key: ValueKey(label), style: AppText.microStyle.copyWith(color: c, fontWeight: FontWeight.w600)),
            ),
          ]),
        ),
      ),
    );
  }
}
