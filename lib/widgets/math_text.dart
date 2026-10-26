import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:markdown/markdown.dart' as md;

import '../theme.dart';

/// Textbook-quality maths (LaTeX). Falls back to calm serif italics if the formula can't be typeset.
class MathText extends StatelessWidget {
  const MathText(this.tex, {super.key, this.size = 17, this.color, this.display = false});
  final String tex;
  final double size;
  final Color? color;
  final bool display;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Palette.of(context).text;
    final clean = tex.trim().replaceAll(RegExp(r'^\$+|\$+$'), '').trim();
    return Math.tex(
      clean,
      mathStyle: display ? MathStyle.display : MathStyle.text,
      textStyle: TextStyle(fontSize: size, color: c),
      onErrorFallback: (_) => Text(clean, style: Brand.serif(size: size + 1, color: c, style: FontStyle.italic)),
    );
  }
}

/// $$ ... $$ or \[ ... \] on their own lines: a centred display formula.
class MathBlockSyntax extends md.BlockSyntax {
  @override
  RegExp get pattern => RegExp(r'^\s*(\$\$|\\\[)');

  /// Launch hardening M-4: only a formula that is closed counts. An unclosed `$$` (a cut-off reply, a price written
  /// "$$$") turned the whole rest of the reply into one broken formula; now it stays plain text.
  @override
  bool canParse(md.BlockParser parser) {
    if (!super.canParse(parser)) return false;
    final first = parser.current.content.trim();
    final open = first.startsWith(r'$$') ? r'$$' : r'\[';
    final close = open == r'$$' ? r'$$' : r'\]';
    final rest = first.substring(open.length);
    if (rest.trim().isNotEmpty && rest.trimRight().endsWith(close)) return true;
    for (var i = 1; i <= 200; i++) {
      final l = parser.peek(i);
      if (l == null) return false;
      if (l.content.contains(close)) return true;
    }
    return false;
  }

  @override
  md.Node parse(md.BlockParser parser) {
    final first = parser.current.content.trim();
    final open = first.startsWith(r'$$') ? r'$$' : r'\[';
    final close = open == r'$$' ? r'$$' : r'\]';
    var body = first.substring(open.length);
    if (body.trimRight().endsWith(close) && body.trim().length >= close.length) {
      body = body.trimRight();
      body = body.substring(0, body.length - close.length);
      parser.advance();
    } else {
      parser.advance();
      final lines = <String>[body];
      while (!parser.isDone) {
        final l = parser.current.content;
        parser.advance();
        final i = l.indexOf(close);
        if (i >= 0) {
          lines.add(l.substring(0, i));
          break;
        }
        lines.add(l);
      }
      body = lines.join('\n');
    }
    return md.Element.text('mathblock', body.trim());
  }
}

/// $...$ or \( ... \) inside a sentence. "$5 and $10" stays money: the inside must look like maths.
class MathInlineSyntax extends md.InlineSyntax {
  MathInlineSyntax() : super(r'\\\((.+?)\\\)|\$(?!\s)([^\$\n]+?)(?<!\s)\$(?!\d)');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final tex = match.group(1) ?? match.group(2) ?? '';
    final looksMath = match.group(1) != null || RegExp(r'[\\^_=+\-*/()a-zA-Z]').hasMatch(tex) && !RegExp(r'^\d+([.,]\d+)?$').hasMatch(tex);
    if (!looksMath) {
      parser.addNode(md.Text(match.group(0)!));
      return true;
    }
    parser.addNode(md.Element.text('mathinline', tex));
    return true;
  }
}

class MathBuilder extends MarkdownElementBuilder {
  MathBuilder({required this.display});
  final bool display;

  @override
  bool isBlockElement() => display;

  @override
  Widget? visitElementAfterWithContext(BuildContext context, md.Element element, TextStyle? preferredStyle, TextStyle? parentStyle) {
    final p = Palette.of(context);
    final tex = element.textContent;
    if (display) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Center(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: MathText(tex, size: 19, color: p.text, display: true),
          ),
        ),
      );
    }
    return MathText(tex, size: (parentStyle?.fontSize ?? 16) + 0.5, color: parentStyle?.color ?? p.text);
  }
}

/// Turns typed maths ("y = x^3 - 3x", "r = 4cos(4theta)") into tidy LaTeX for display.
String plainToTex(String s) {
  var t = s.trim();
  if (t.contains('\\')) return t; // already LaTeX
  t = t.replaceAll('**', '^').replaceAll('θ', 'theta').replaceAll('π', 'pi');
  // sqrt(...) with balanced brackets
  t = _wrapFn(t, 'sqrt', (inner) => '\\sqrt{$inner}');
  t = _wrapFn(t, 'abs', (inner) => '\\left|$inner\\right|');
  t = t.replaceAllMapped(RegExp(r'(?<![a-zA-Z\\])(arcsin|arccos|arctan|sinh|cosh|tanh|sin|cos|tan|cot|sec|csc|ln|log|exp)(?![a-zA-Z])'), (m) => '\\${m.group(1)}');
  t = t.replaceAllMapped(RegExp(r'(?<![a-zA-Z\\])(theta|phi|alpha|beta|pi|tau)(?![a-zA-Z])'), (m) => '\\${m.group(1)}');
  // Exponents: ^(...) -> ^{...}, ^-2x -> ^{-2x}
  t = t.replaceAllMapped(RegExp(r'\^\(([^()]*)\)'), (m) => '^{${m.group(1)}}');
  t = t.replaceAllMapped(RegExp(r'\^(-?[0-9.]+|-?[a-zA-Z])'), (m) => '^{${m.group(1)}}');
  t = t.replaceAll('*', ' \\cdot ');
  t = t.replaceAll('<=', '\\le ').replaceAll('>=', '\\ge ');
  return t;
}

String _wrapFn(String t, String fn, String Function(String) wrap) {
  var out = t;
  var guard = 0;
  while (guard++ < 20) {
    final i = out.indexOf('$fn(');
    if (i < 0) break;
    var depth = 0, j = i + fn.length;
    for (; j < out.length; j++) {
      if (out[j] == '(') depth++;
      if (out[j] == ')') {
        depth--;
        if (depth == 0) break;
      }
    }
    if (j >= out.length) break;
    out = out.substring(0, i) + wrap(out.substring(i + fn.length + 1, j)) + out.substring(j + 1);
  }
  return out;
}
