import 'dart:convert';

import '../models.dart';

/// Some models (Qwen, Hermes, Llama, many free ones) write their tool calls as text
/// instead of using the API's tool_calls field. This turns that text back into real calls,
/// so the task keeps working and the user never sees raw markup.
class TextToolCalls {
  TextToolCalls._(this.calls, this.rest);
  final List<ToolCall> calls;
  final String rest;

  static int _n = 0;

  static bool looksLike(String s) =>
      s.contains('<tool_call') || s.contains('<function=') || s.contains('<|tool_call') || s.contains('<function_call');

  static TextToolCalls parse(String text) {
    if (!looksLike(text)) return TextToolCalls._(const [], text);
    final calls = <ToolCall>[];
    var rest = text;

    void add(String name, Map<String, dynamic> args) {
      name = name.trim();
      if (name.isEmpty) return;
      calls.add(ToolCall(id: 'call_t${DateTime.now().millisecondsSinceEpoch}_${_n++}', name: name, arguments: jsonEncode(args)));
    }

    // 1) XML style: <function=name> <parameter=key> value </parameter> ... </function>
    final fnRe = RegExp(r'<function=([\w.\-]+)>([\s\S]*?)(?:</function>|$)');
    final paramRe = RegExp(r'<parameter=([\w.\-]+)>([\s\S]*?)(?:</parameter>|(?=<parameter=)|(?=</function>)|$)');
    for (final m in fnRe.allMatches(text)) {
      final args = <String, dynamic>{};
      for (final p in paramRe.allMatches(m.group(2) ?? '')) {
        args[p.group(1)!] = _value((p.group(2) ?? '').trim());
      }
      add(m.group(1)!, args);
    }
    if (calls.isNotEmpty) {
      rest = text.replaceAll(RegExp(r'<tool_call>[\s\S]*?(</tool_call>|$)'), '').replaceAll(fnRe, '');
      return TextToolCalls._(calls, _clean(rest));
    }

    // 2) JSON style: <tool_call>{"name": ..., "arguments": {...}}</tool_call> (also <function_call>, <|tool_call|>)
    final jsonRe = RegExp(r'<\|?(?:tool_call|function_call)\|?>([\s\S]*?)(?:<\|?/(?:tool_call|function_call)\|?>|<\|?(?:tool_call|function_call)\|?>|$)');
    for (final m in jsonRe.allMatches(text)) {
      final body = (m.group(1) ?? '').trim();
      final start = body.indexOf('{');
      final end = body.lastIndexOf('}');
      if (start < 0 || end <= start) continue;
      try {
        final j = jsonDecode(body.substring(start, end + 1));
        for (final c in (j is List ? j : [j])) {
          if (c is! Map) continue;
          final name = '${c['name'] ?? (c['function'] is Map ? c['function']['name'] : '') ?? ''}';
          var a = c['arguments'] ?? c['parameters'] ?? (c['function'] is Map ? c['function']['arguments'] : null) ?? const {};
          if (a is String) {
            try {
              a = jsonDecode(a);
            } catch (_) {
              a = <String, dynamic>{};
            }
          }
          add(name, a is Map ? Map<String, dynamic>.from(a) : <String, dynamic>{});
        }
      } catch (_) {}
    }
    if (calls.isNotEmpty) rest = text.replaceAll(jsonRe, '');
    return TextToolCalls._(calls, _clean(rest));
  }

  static dynamic _value(String v) {
    if (v == 'true') return true;
    if (v == 'false') return false;
    if (RegExp(r'^-?\d+(\.\d+)?$').hasMatch(v)) return num.parse(v);
    if ((v.startsWith('{') && v.endsWith('}')) || (v.startsWith('[') && v.endsWith(']'))) {
      try {
        return jsonDecode(v);
      } catch (_) {}
    }
    return v;
  }

  static String _clean(String s) =>
      s.replaceAll(RegExp(r'</?tool_call>|</?function_call>|<\|/?tool_call\|>'), '').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
}
