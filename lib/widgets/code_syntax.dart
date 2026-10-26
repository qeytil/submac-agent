import 'package:flutter/painting.dart';
import 'package:highlight/highlight.dart' show Highlight, Node;
import 'package:highlight/languages/bash.dart';
import 'package:highlight/languages/cpp.dart';
import 'package:highlight/languages/css.dart';
import 'package:highlight/languages/dart.dart';
import 'package:highlight/languages/go.dart';
import 'package:highlight/languages/java.dart';
import 'package:highlight/languages/javascript.dart';
import 'package:highlight/languages/json.dart';
import 'package:highlight/languages/kotlin.dart';
import 'package:highlight/languages/markdown.dart';
import 'package:highlight/languages/php.dart';
import 'package:highlight/languages/python.dart';
import 'package:highlight/languages/ruby.dart';
import 'package:highlight/languages/rust.dart';
import 'package:highlight/languages/sql.dart';
import 'package:highlight/languages/swift.dart';
import 'package:highlight/languages/typescript.dart';
import 'package:highlight/languages/xml.dart';
import 'package:highlight/languages/yaml.dart';

import '../theme.dart';

/// Syntax tones for code blocks (fix/ui-restyle). Only the languages people ask SubMac for are registered (the whole
/// highlight.js set would add weight to the APK for nothing). Anything else, or anything the highlighter cannot read,
/// stays plain monospace in the page's text colour: the code is always shown.
class CodeSyntax {
  CodeSyntax._();

  static final Highlight _hl = Highlight()
    ..registerLanguage('bash', bash)
    ..registerLanguage('cpp', cpp)
    ..registerLanguage('css', css)
    ..registerLanguage('dart', dart)
    ..registerLanguage('go', go)
    ..registerLanguage('java', java)
    ..registerLanguage('javascript', javascript)
    ..registerLanguage('json', json)
    ..registerLanguage('kotlin', kotlin)
    ..registerLanguage('markdown', markdown)
    ..registerLanguage('php', php)
    ..registerLanguage('python', python)
    ..registerLanguage('ruby', ruby)
    ..registerLanguage('rust', rust)
    ..registerLanguage('sql', sql)
    ..registerLanguage('swift', swift)
    ..registerLanguage('typescript', typescript)
    ..registerLanguage('xml', xml)
    ..registerLanguage('yaml', yaml);

  static const _alias = {
    'shell': 'bash', 'console': 'bash', 'sh': 'bash', 'zsh': 'bash', 'html': 'xml', 'svg': 'xml', 'js': 'javascript',
    'jsx': 'javascript', 'ts': 'typescript', 'tsx': 'typescript', 'py': 'python', 'kt': 'kotlin', 'c': 'cpp',
    'c++': 'cpp', 'rs': 'rust', 'rb': 'ruby', 'yml': 'yaml', 'md': 'markdown', 'golang': 'go',
  };

  /// Code longer than this is shown plain (highlighting it would cost a frame on a phone).
  static const maxChars = 20000;

  /// The registered language for a fence word, or null when it is shown plain.
  static String? languageFor(String fence) {
    final l = fence.trim().toLowerCase();
    if (l.isEmpty) return null;
    final name = _alias[l] ?? l;
    return const {
      'bash', 'cpp', 'css', 'dart', 'go', 'java', 'javascript', 'json', 'kotlin', 'markdown', 'php', 'python', 'ruby',
      'rust', 'sql', 'swift', 'typescript', 'xml', 'yaml',
    }.contains(name)
        ? name
        : null;
  }

  static Color? _tone(String? cls, CodeInk ink) {
    if (cls == null) return null;
    switch (cls) {
      case 'keyword':
      case 'selector-tag':
      case 'built_in':
      case 'literal':
      case 'tag':
      case 'name':
        return ink.keyword;
      case 'string':
      case 'regexp':
      case 'addition':
      case 'attribute':
      case 'symbol':
      case 'bullet':
      case 'link':
        return ink.string;
      case 'number':
        return ink.number;
      case 'comment':
      case 'quote':
      case 'deletion':
        return ink.comment;
      case 'type':
      case 'class':
      case 'title':
      case 'section':
      case 'selector-id':
      case 'selector-class':
        return ink.type;
      case 'meta':
      case 'meta-keyword':
      case 'attr':
      case 'variable':
      case 'template-variable':
      case 'params':
        return ink.meta;
    }
    return null;
  }

  /// The code as styled spans on [base] (monospace in the text colour). Plain when the language is unknown.
  static TextSpan spans(String code, String fence, {required TextStyle base, required CodeInk ink}) {
    final lang = languageFor(fence);
    if (lang == null || code.length > maxChars) return TextSpan(text: code, style: base);
    try {
      final nodes = _hl.parse(code, language: lang).nodes ?? const <Node>[];
      List<InlineSpan> walk(List<Node> list) => [
            for (final n in list)
              if (n.value != null)
                TextSpan(text: n.value, style: _styleFor(n.className, ink))
              else if (n.children != null)
                TextSpan(style: _styleFor(n.className, ink), children: walk(n.children!)),
          ];
      final children = walk(nodes);
      // The highlighter must hand back every character; if it ever drops some, show the code plain instead.
      final out = TextSpan(style: base, children: children);
      if (out.toPlainText(includeSemanticsLabels: false) != code) return TextSpan(text: code, style: base);
      return out;
    } catch (_) {
      return TextSpan(text: code, style: base);
    }
  }

  static TextStyle? _styleFor(String? cls, CodeInk ink) {
    final c = _tone(cls, ink);
    if (c == null) return null;
    return TextStyle(color: c, fontStyle: cls == 'comment' || cls == 'quote' ? FontStyle.italic : null);
  }
}
