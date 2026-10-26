import 'dart:math' as math;

import 'package:agent/theme.dart';
import 'package:agent/widgets/code_syntax.dart';
import 'package:agent/widgets/markdown_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Owner report 2026-10-26: code blocks in chat showed as a solid black box. Root cause: in daylight the code card's
/// fill (Palette.code) was the ink colour #121110, the same colour as the code text. These tests render a real fenced
/// block through MarkdownView with the app's own theme and fail if any code colour sits too close to the card.

double _lum(Color c) {
  double ch(double v) => v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
}

double contrast(Color a, Color b) {
  final la = _lum(a), lb = _lum(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

Widget app(Widget child, {Brightness b = Brightness.light, TextDirection dir = TextDirection.ltr}) => MaterialApp(
      theme: buildTheme(b),
      home: Directionality(
        textDirection: dir,
        child: Scaffold(body: SingleChildScrollView(padding: const EdgeInsets.all(16), child: child)),
      ),
    );

const fenced = 'Here it is:\n\n```python\n# reverse a string\ndef rev(s):\n    return s[::-1]  # 42\nprint(rev("hello"))\n```\n\nDone.';

/// Every coloured run of text in the code block, with its colour.
List<(String, Color)> codeRuns(WidgetTester t) {
  final editable = t.allRenderObjects.whereType<RenderEditable>().single;
  final out = <(String, Color)>[];
  void walk(InlineSpan s, Color inherited) {
    if (s is! TextSpan) return;
    final c = s.style?.color ?? inherited;
    if (s.text != null && s.text!.trim().isNotEmpty) out.add((s.text!, c));
    for (final k in s.children ?? const <InlineSpan>[]) {
      walk(k, c);
    }
  }

  walk(editable.text!, const Color(0x00000000));
  return out;
}

Color surface(WidgetTester t) {
  final box = t.widget<DecoratedBox>(find.byKey(const ValueKey('code-surface')));
  return (box.decoration as BoxDecoration).color!;
}

void main() {
  for (final b in Brightness.values) {
    for (final dir in TextDirection.values) {
      testWidgets('code block is readable: $b, $dir', (t) async {
        await t.pumpWidget(app(const MarkdownView(fenced), b: b, dir: dir));
        await t.pump();
        // The code itself is on screen, whole.
        expect(find.byKey(const ValueKey('code-text')), findsOneWidget);
        final runs = codeRuns(t);
        final all = t.allRenderObjects.whereType<RenderEditable>().single.text!.toPlainText();
        expect(all, contains('def rev(s):'));
        expect(all, contains('print(rev("hello"))'));
        // Every run contrasts with the card (WCAG AA for body text), and the card is not the ink colour.
        final bg = surface(t);
        for (final (text, color) in runs) {
          expect(color.a, greaterThan(0.9), reason: '"$text" has no colour');
          expect(contrast(color, bg), greaterThanOrEqualTo(4.5), reason: '"$text" ($color) on $bg');
        }
        final p = b == Brightness.dark ? Palette.dark : Palette.light;
        expect(contrast(bg, p.text), greaterThan(10), reason: 'the card must be a quiet surface, not the ink');
        // Syntax tones: more than one colour on a Python snippet, and the comment is set apart.
        expect(runs.map((r) => r.$2).toSet().length, greaterThan(1));
        // Monospace, a sideways scroll, a Copy action, and the code reads left to right even in RTL.
        expect(t.allRenderObjects.whereType<RenderEditable>().single.text!.style?.fontFamily, 'GeistMono');
        expect(find.byKey(const ValueKey('code-scroll')), findsOneWidget);
        expect(t.widget<SingleChildScrollView>(find.byKey(const ValueKey('code-scroll'))).scrollDirection, Axis.horizontal);
        expect(find.byKey(const ValueKey('code-copy')), findsOneWidget);
        expect(t.allRenderObjects.whereType<RenderEditable>().single.textDirection, TextDirection.ltr);
        expect(find.text('Python'), findsOneWidget);
      });
    }
  }

  testWidgets('a long line scrolls sideways instead of being cut or squeezed', (t) async {
    final long = 'x = "${'a' * 400}"';
    await t.pumpWidget(app(MarkdownView('```python\n$long\n```')));
    await t.pump();
    final editable = t.allRenderObjects.whereType<RenderEditable>().single;
    expect(editable.size.width, greaterThan(1000));
    expect(editable.size.height, greaterThan(10));
    expect(t.takeException(), isNull);
  });

  testWidgets('Copy puts the code on the clipboard and says Copied', (t) async {
    String? copied;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    await t.pumpWidget(app(const CodeBlock(code: 'echo hi', language: 'unknown-lang')));
    await t.tap(find.byKey(const ValueKey('code-copy')));
    await t.pump(const Duration(milliseconds: 300));
    expect(copied, 'echo hi');
    expect(find.text('Copied'), findsOneWidget);
    await t.pump(const Duration(seconds: 2));
    expect(find.text('Copy'), findsOneWidget);
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  test('highlighter keeps every character and falls back to plain text', () {
    const base = TextStyle(color: Color(0xFF121110));
    for (final lang in ['dart', 'js', 'ts', 'sh', 'json', 'yaml', 'html', 'sql', 'kt', 'rs', 'nope', '']) {
      const code = 'const a = {"k": [1, 2]}; // note\nif (a) { print(a) }\n<div class="x">y</div>\n';
      expect(CodeSyntax.spans(code, lang, base: base, ink: CodeInk.light).toPlainText(), code, reason: lang);
    }
    expect(CodeSyntax.languageFor('PY'), 'python');
    expect(CodeSyntax.languageFor('brainfuck'), isNull);
  });

  test('both palettes keep code tones readable on the code surface', () {
    for (final (p, ink) in [(Palette.light, CodeInk.light), (Palette.dark, CodeInk.dark)]) {
      for (final c in [p.text, ink.keyword, ink.string, ink.number, ink.comment, ink.type, ink.meta]) {
        expect(contrast(c, p.code), greaterThanOrEqualTo(4.5), reason: '$c on ${p.code}');
      }
    }
  });
}
