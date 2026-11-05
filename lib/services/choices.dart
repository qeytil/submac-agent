// Tap answers for a question: one reader for every shape a model writes them in, and the rules for good options.
//
// Owner, 2026-10-24: "The follow up questions have bugs and it's asking questions with minimal choices." Root causes
// (all older than build-61):
//   * a ```choices card drew only a bare JSON list of strings. {"question","options":[…]}, [{"label":…}] or plain lines
//     drew nothing, or failed the reply check and cost another model call ("Tidying the answer");
//   * ask_user crashed on options sent as one string ("A, B, C" or a JSON string), so the model asked again with none;
//   * "Other" / "Something else" written by the model showed twice next to the app's own "Something else" row;
//   * the prompt and the tool asked for "2-5" answers, so models gave the minimum: two.
import 'dart:convert';

class Choices {
  Choices._();

  /// The most answers shown at once (the app adds "Something else" for the user's own words below them).
  static const max = 6;

  /// The fewest answers a card draws: one suggestion is still worth a tap (with "Something else" under it). A card
  /// below this was dropped, or sent back to the model for another call.
  static const min = 1;

  /// What the model is asked for: 3 to 5 real answers.
  static const askFor = '3-5';

  static final _other = RegExp(
      r'^(other|others|other\s*\(.*\)|something else|anything else|else|none of (these|the above)|custom|type (your|my) own|'
      r'kale|wax kale|wax kale ah|غير ذلك|شيء آخر|أخرى)\W*$',
      caseSensitive: false);
  static final _bullet = RegExp(r'^\s*(?:[-*•·]|\d{1,2}[.)]|[a-eA-E][.)])\s+');

  /// The answers in [raw]: a list of strings, a list of objects (label/title/text/value/option/name), an object with
  /// options/choices/answers/items, a JSON string of any of these, or plain lines ("A\nB", "A | B", "A, B, C").
  /// Trimmed, bullets dropped, empty and duplicate answers dropped, the model's own "Other" dropped (the app adds its
  /// own "Something else" row), at most [max].
  static List<String> parse(Object? raw) {
    var v = raw;
    if (v is String) {
      final t = v.trim();
      if (t.startsWith('[') || t.startsWith('{')) {
        try {
          v = jsonDecode(t);
        } catch (_) {}
      }
    }
    // opencode's question-tool shape ({"questions":[…]}, a list of {"question","options"}, or the tool call written
    // out as text): the first question's answers.
    final first = _firstQuestion(v);
    if (first != null) v = first;
    if (v is Map) v = v['options'] ?? v['choices'] ?? v['answers'] ?? v['items'] ?? v['buttons'];
    final items = <String>[];
    if (v is List) {
      for (final e in v) {
        if (e is Map) {
          final l = e['label'] ?? e['title'] ?? e['text'] ?? e['value'] ?? e['option'] ?? e['name'];
          if (l != null) items.add('$l');
        } else if (e != null) {
          items.add('$e');
        }
      }
    } else if (v is String) {
      final t = v.trim();
      final parts = t.contains('\n')
          ? t.split('\n')
          : t.contains('|')
              ? t.split('|')
              : t.contains(';')
                  ? t.split(';')
                  // Never inside a number: "Under $1,000" is one answer (CB-11a).
                  : t.split(RegExp(r'(?<!\d),\s*(?:or\s+)?|(?<=\d),(?!\d)\s*(?:or\s+)?|\s+or\s+'));
      items.addAll(parts);
    }
    final out = <String>[];
    final seen = <String>{};
    for (var s in items) {
      s = s.replaceFirst(_bullet, '').trim();
      if (s.length > 1 && ((s.startsWith('"') && s.endsWith('"')) || (s.startsWith("'") && s.endsWith("'")))) {
        s = s.substring(1, s.length - 1).trim();
      }
      if (s.isEmpty || _other.hasMatch(s)) continue;
      if (!seen.add(s.toLowerCase())) continue;
      out.add(s);
      if (out.length >= max) break;
    }
    return out;
  }

  /// The question a card carries with its answers ({"question": …}), or null.
  static String? question(Object? raw) {
    var v = raw;
    if (v is String && v.trim().startsWith('{')) {
      try {
        v = jsonDecode(v.trim());
      } catch (_) {}
    }
    v = _firstQuestion(v) ?? v;
    if (v is! Map) return null;
    final q = '${v['question'] ?? v['title'] ?? v['q'] ?? v['header'] ?? ''}'.trim();
    return q.isEmpty ? null : q;
  }

  /// Bot questions written as raw code (owner, 2026-11-04, APK 1.13.121: "in bots' private chat, the bots' questions
  /// are raw code"). A bot's brief asks for a ```choices card (BotAsk.rule), and opencode turns go straight to the chat
  /// with no reply check (the old core's reply_schema repaired these before 1.13.109), so a model's slips showed as
  /// code: a ```json / plain ``` fence holding {"question","options"}, the fence opened mid-line ("Pick one: ```choices"
  /// reads as an inline code span), a one-line card, a fence indented under a list item, or the JSON (or opencode's
  /// question-tool call) written bare in the text. The owner's chat rarely hit it: on opencode it asks with the native
  /// question tool. Each of these becomes a proper ```choices fence here, while it streams (an unclosed fence shows the
  /// card's placeholder) and after. Other code is left alone: only question-shaped JSON is touched.
  static String fixReply(String text) {
    if (!text.contains('```') && !text.contains('{')) return text;
    if (!RegExp(r'choices|"(question|questions|options|header)"').hasMatch(text)) return text;
    final lines = text.split('\n');
    final out = <String>[];
    String? fence; // a fence passed through untouched until it closes
    bool closes(String t, String f) => t.startsWith(f) && t.replaceAll(f[0], '').trim().isEmpty;
    final opener = RegExp(r'^\s*(```+|~~~+)\s*([^\s`]*)(.*)$');
    var i = 0;
    while (i < lines.length) {
      final line = lines[i];
      final t = line.trim();
      if (fence != null) {
        out.add(line);
        if (closes(t, fence)) fence = null;
        i++;
        continue;
      }
      final m = opener.firstMatch(line);
      if (m != null) {
        final mark = m.group(1)!;
        final lang = m.group(2)!.toLowerCase();
        final rest = m.group(3)!;
        if (lang == 'choices' || lang.startsWith('choices')) {
          i = _choicesFence(lines, i, mark, rest, out);
          continue;
        }
        if (const {'', 'json', 'json5', 'jsonc', 'js', 'javascript'}.contains(lang) && !rest.contains(mark)) {
          var j = i + 1;
          while (j < lines.length && !closes(lines[j].trim(), mark)) {
            j++;
          }
          final body = lines.sublist(i + 1, j > lines.length ? lines.length : j).join('\n');
          final closed = j < lines.length;
          if (closed ? isQuestionJson(body) : looksLikeQuestion(body)) {
            out
              ..add('```choices')
              ..addAll(lines.sublist(i + 1, j));
            if (closed) out.add('```');
            i = closed ? j + 1 : lines.length;
            continue;
          }
        }
        out.add(line);
        if (!rest.contains(mark)) fence = mark;
        i++;
        continue;
      }
      // A card opened after words on the same line ("Which one? ```choices ...").
      final mid = RegExp(r'^(.*?\S)\s*(```+)\s*choices\b(.*)$').firstMatch(line);
      if (mid != null) {
        out.add(mid.group(1)!);
        i = _choicesFence(lines, i, mid.group(2)!, mid.group(3)!, out);
        continue;
      }
      // Question JSON written bare in the text, one line or several.
      if (t.startsWith('{') || t.startsWith(RegExp(r'\[\s*(\{|$)'))) {
        var j = i;
        var depth = 0;
        var inStr = false, esc = false;
        var balanced = false;
        for (; j < lines.length; j++) {
          for (final c in lines[j].runes) {
            final ch = String.fromCharCode(c);
            if (inStr) {
              if (esc) {
                esc = false;
              } else if (ch == r'\') {
                esc = true;
              } else if (ch == '"') {
                inStr = false;
              }
              continue;
            }
            if (ch == '"') inStr = true;
            if (ch == '{' || ch == '[') depth++;
            if (ch == '}' || ch == ']') depth--;
          }
          if (depth <= 0) {
            balanced = true;
            break;
          }
        }
        final end = balanced ? j + 1 : lines.length;
        final body = lines.sublist(i, end).join('\n');
        if (balanced ? isQuestionJson(body) : looksLikeQuestion(body)) {
          out
            ..add('```choices')
            ..addAll(lines.sublist(i, end));
          if (balanced) out.add('```');
          i = end;
          continue;
        }
      }
      out.add(line);
      i++;
    }
    return out.join('\n');
  }

  /// Writes one ```choices card that opens on lines[i] (its fence mark and whatever followed `choices` on that line)
  /// as a clean fence, and returns the index of the first line after it. A card closed on its own line is copied up
  /// to its closing fence; a one-line card (```choices [..]```) is split; an unclosed one (still streaming) runs to the
  /// end.
  static int _choicesFence(List<String> lines, int i, String mark, String rest, List<String> out) {
    final f = mark.startsWith('~') ? mark : '```';
    var r = rest.replaceFirst(RegExp(r'^[^\s\[{]*'), ''); // "choices json" -> the info word after it goes
    out.add('${f}choices');
    final close = r.indexOf(mark);
    if (close >= 0) {
      final body = r.substring(0, close).trim();
      final after = r.substring(close + mark.length).trim();
      if (body.isNotEmpty) out.add(body);
      out.add(f);
      if (after.isNotEmpty) out.add(after);
      return i + 1;
    }
    r = r.trim();
    if (r.isNotEmpty) out.add(r);
    var j = i + 1;
    for (; j < lines.length; j++) {
      final t = lines[j].trim();
      if (t.startsWith(mark) && t.replaceAll(mark[0], '').trim().isEmpty) {
        out.add(f);
        return j + 1;
      }
      // A closing fence glued to the end of the JSON ("…]```").
      if (t.endsWith(mark) && t.length > mark.length) {
        out
          ..add(lines[j].trimLeft().substring(0, lines[j].trimLeft().length - mark.length).trimRight())
          ..add(f);
        return j + 1;
      }
      out.add(lines[j].trimLeft());
    }
    return j;
  }

  /// Whether [body] is a finished question with answers: {"question","options"}, opencode's {"questions":[…]}, a list
  /// of such questions, or the question tool's call written out ({"name":"question","arguments":{…}}). A plain JSON
  /// list or any other object is not (it may be real data), so a ```json block of data stays code.
  static bool isQuestionJson(String body) {
    final v = _decode(body);
    if (v == null) return false;
    final q = _firstQuestion(v);
    if (q is Map) return true;
    return v is Map && _isQuestionMap(v);
  }

  /// Whether the start of a block still being written reads as question JSON (shown as the card's placeholder until
  /// it has arrived).
  static bool looksLikeQuestion(String body) => RegExp(
          r'^\s*(\[\s*)?\{\s*"(question|questions|header)"\s*:|^\s*\{\s*"(name|tool)"\s*:\s*"question"')
      .hasMatch(body);

  static Object? _decode(String body) {
    final t = body.trim();
    if (t.isEmpty) return null;
    try {
      return jsonDecode(t);
    } catch (_) {}
    final s = t.indexOf(RegExp(r'[\[{]'));
    final e = t.lastIndexOf(RegExp(r'[\]}]'));
    if (s >= 0 && e > s) {
      try {
        return jsonDecode(t.substring(s, e + 1));
      } catch (_) {}
    }
    return null;
  }

  static bool _isQuestionMap(Map v) =>
      (v['question'] ?? v['q'] ?? v['header']) != null &&
      (v['options'] ?? v['choices'] ?? v['answers'] ?? v['items'] ?? v['buttons']) != null;

  /// Every question a card holds, each with its answers: one for {"question","options"} or a plain list, several for
  /// opencode's {"questions":[…]} (or a list of questions). Questions with neither words nor answers are left out.
  static List<(String?, List<String>)> questionsIn(Object? raw) {
    var v = raw;
    if (v is String) v = _decode(v) ?? v;
    if (v is Map && (v['name'] == 'question' || v['tool'] == 'question')) {
      final a = v['arguments'] ?? v['input'] ?? v['parameters'] ?? v['args'];
      if (a != null) v = a is String ? (_decode(a) ?? a) : a;
    }
    final many = v is Map && v['questions'] is List
        ? v['questions'] as List
        : (v is List && v.isNotEmpty && v.every((e) => e is Map && _isQuestionMap(e)) ? v : null);
    final out = <(String?, List<String>)>[];
    for (final q in many ?? [v]) {
      final opts = parse(q);
      final text = question(q);
      if (opts.isEmpty && text == null) continue;
      out.add((text, opts));
    }
    return out;
  }

  /// The first question in opencode's question-tool shapes, or null when [v] is not one of them.
  static Object? _firstQuestion(Object? v) {
    if (v is Map) {
      final args = (v['name'] == 'question' || v['tool'] == 'question') ? (v['arguments'] ?? v['input'] ?? v['parameters'] ?? v['args']) : null;
      if (args != null) return _firstQuestion(args is String ? _decode(args) : args) ?? (args is Map ? args : null);
      final qs = v['questions'];
      if (qs is List) {
        for (final q in qs) {
          if (q is Map) return q;
        }
      }
      return null;
    }
    if (v is List && v.isNotEmpty && v.every((e) => e is Map && _isQuestionMap(e))) return v.first;
    return null;
  }

  /// The ```choices blocks in a reply, each as its answers.
  static List<List<String>> blocksIn(String reply) {
    final out = <List<String>>[];
    for (final m in RegExp(r'```choices[^\n]*\n([\s\S]*?)(```|$)').allMatches(reply)) {
      out.add(parse(m.group(1)!.trim()));
    }
    return out;
  }

  /// Whether two answer lists are the same card.
  static bool same(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].toLowerCase() != b[i].toLowerCase()) return false;
    }
    return true;
  }

  /// The answer in [reply] the user picked from [options] (case and spaces ignored), or null.
  static String? pickedIn(String reply, List<String> options) {
    final r = reply.trim().toLowerCase();
    for (final o in options) {
      if (o.trim().toLowerCase() == r) return o;
    }
    return null;
  }

  /// The rule the prompt and the ask_user tool give the model.
  static const rule = 'Give $askFor real, distinct answers the user would actually pick, most likely first, each a few words '
      '(specific: "Friday 7 pm", "Under \$50", not "Yes"/"Maybe"). Two only for a true yes/no. Never add "Other" or '
      '"Something else": the app always adds a row for their own words.';
}
