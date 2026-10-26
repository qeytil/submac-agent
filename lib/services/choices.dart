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
    if (v is! Map) return null;
    final q = '${v['question'] ?? v['title'] ?? v['q'] ?? ''}'.trim();
    return q.isEmpty ? null : q;
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
