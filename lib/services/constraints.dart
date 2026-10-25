/// Reads the hard requirements out of a user's message, in plain Dart (no Flutter, no state), so the loop can keep them
/// in view: a compact "Must:" line at the end of every step and a final self-check before the answer.
///
/// It looks for the things people most often get wrong back:
///  - counts and numbers   "3 ideas", "under 100 words", "in 2 lines", "5 bullet points", "$50", "saddex fikradood"
///  - language             "in Somali", "af Soomaali ku qor", "in English", "Arabic", "Carabi"
///  - format               table, list, bullets, pdf, docx, email, json, one line, short, a paragraph, a poem
///  - limits               don't / do not / never / without / except / only / no <thing>, and Somali ha / ha ku / la'aan /
///                         kaliya / keliya / mooyee / mooyaane
///  - several parts        numbered or bulleted lines, "and also", "then", several questions in one message
///
/// The phrases are kept close to the user's own words (clipped), never reworded, so the model checks against what they
/// actually said. Our own code; the idea of reciting hard constraints near the end of the context is common practice
/// (see docs/agent-loop.md).
class Constraints {
  const Constraints(this.items, {this.parts = 0});

  /// Short phrases, in the order found, each tagged ("count: 3 ideas").
  final List<String> items;

  /// How many separate asks the message has (0 or 1 = one ask).
  final int parts;

  static const none = Constraints([]);

  bool get isEmpty => items.isEmpty && parts < 2;
  bool get any => !isEmpty;

  /// The compact line for the end of the request, or '' when there is nothing to hold on to.
  String mustLine() {
    if (isEmpty) return '';
    final all = [...items, if (parts >= 2) 'answer all $parts parts'];
    var s = 'Must (from the user\'s words; check each before you reply): ${all.join(' · ')}';
    if (s.length > 420) s = '${s.substring(0, 417)}…';
    return s;
  }

  /// Self-check line for the final reply.
  String selfCheck() => isEmpty ? '' : 'Self-check: your reply meets every Must item above; fix anything that does not before you send it.';
}

class ConstraintReader {
  static String _clip(String s, [int n = 60]) {
    final t = s.trim().replaceAll(RegExp(r'\s+'), ' ');
    return t.length <= n ? t : '${t.substring(0, n - 1)}…';
  }

  static const _numWords = r'one|two|three|four|five|six|seven|eight|nine|ten|twelve|fifteen|twenty|fifty|hundred|'
      r'a couple of|a few|single|'
      r'hal|laba|saddex|afar|shan|lix|toddoba|siddeed|sagaal|toban|labaatan|konton|boqol';

  static const _units = r'words?|sentences?|lines?|paragraphs?|points?|bullets?|bullet points?|items?|ideas?|options?|examples?|'
      r'tips?|steps?|questions?|names?|slides?|pages?|minutes?|mins?|seconds?|hours?|days?|characters?|chars?|emojis?|hashtags?|'
      r'tweets?|posts?|headlines?|titles?|reasons?|rows?|columns?|versions?|variations?|people|places|products?|'
      r'eray(o|ada)?|weedh(o|aha)?|sadar(ro|rada)?|qodob(o|ada)?|fikrad(o|ood|aha)?|tusaale(yaal)?|tallaabo(oyin)?|su.aal(o|aha)?|'
      r'bog(ag|ga)?|daqiiq(ad|o)|saacad(o)?|maalm(o|ood)|magac(yo|yada)?';

  static final _count = RegExp(
      '(?:\\b(?:exactly|at most|at least|no more than|not more than|maximum|max|minimum|min|under|below|over|less than|fewer than|'
      'up to|around|about|only|ugu badnaan|ugu yaraan|in ka yar|ka badan)\\s+)?'
      '\\b(\\d+(?:[.,]\\d+)?|$_numWords)\\s*(?:-|to|ilaa)?\\s*(?:\\d+\\s*)?(?:$_units)\\b',
      caseSensitive: false);

  static final _money = RegExp(r'(?:[$€£]\s?\d[\d,.]*|\b\d[\d,.]*\s?(?:usd|dollars?|shillings?|sh|ksh|birr|euros?|doollar|shilin)\b)', caseSensitive: false);
  static final _budget = RegExp(r'\b(?:under|below|less than|max(?:imum)?|budget(?: of)?|up to|within|ka yar|ugu badnaan)\s+[$€£]?\s?\d[\d,.]*\s?\w*',
      caseSensitive: false);

  static final _language = RegExp(
      r'\b(?:in|into|to|using|use)\s+(somali|english|arabic|swahili|french|amharic|oromo|turkish|italian|spanish|german|chinese|hindi|urdu)\b|'
      r'\b(af[- ]?soomaali|af[- ]?somali|soomaali ahaan|ingiriisi|af ingiriisi|carabi|af carabi|sawaaxili)\b|'
      r'\b(somali|english|arabic|swahili|french)\s+(?:only|language|version|translation)\b|'
      r'\btranslat\w*\b[^.?!\n]{0,40}?\b(somali|english|arabic|swahili|french|amharic|turkish|italian|spanish|german)\b|'
      r'\bu (?:turjun|tarjun|beddel)\w*\b',
      caseSensitive: false);

  static final _format = RegExp(
      r'\b((?:as|in|into|make|in the form of) (?:a |an )?(?:table|list|poem|story|letter|email|tweet|thread|script|song|summary|report|chart|checklist|paragraph|bullet(?:ed)? list|numbered list)\b|'
      r'(?:in|as) (?:a )?(?:bullet(?:ed)? points|bullets|one line|one sentence|a single sentence|two lines|json|csv|markdown|plain text|table form)|'
      r'(?:a |an )?(?:pdf|docx|word document|excel|xlsx|csv|powerpoint|slides)\b(?: file| document)?|'
      r'(?:keep it|make it|be|very|really|super)\s+(?:short|brief|concise|detailed|long|formal|informal|casual|simple|professional|funny|polite)\b|'
      r'(?:short|brief|concise|detailed|formal|informal|casual|simple|professional|polite)\s+(?=(?:email|message|text|post|caption|summary|answer|reply|explanation|letter|note|bio|description|version|story|poem|speech)\b)\w+|'
      r'one[- ]liner|tl;?dr|eli5|step[- ]by[- ]step|subject line|'
      r'gaaban|kooban|faahfaahsan|liis ahaan|shax ahaan|qodob qodob|warqad ahaan|hal sadar)',
      caseSensitive: false);

  /// "5 phones", "ten hotels", "saddex magac": a number in front of a plural noun.
  static final _countNoun = RegExp('\\b(\\d{1,3}|$_numWords)\\s+(?!am\\b|pm\\b|years?\\b|times?\\b|percent\\b|%)([a-z]{3,}s)\\b', caseSensitive: false);

  static final _limit = RegExp(
      r"\b(don['’]?t|do not|dont|never|without|except|excluding|apart from|other than|avoid|no more|not (?:a|any|the|too|in|on|more)|only|just the|"
      r"la['’]?aan|aan lahayn|kaliya|keliya|oo kaliya|mooyee|mooyaane|marka laga reebo)\b"
      r"[^.?!\n;]{1,60}",
      caseSensitive: false);

  /// "no emoji", "no links", "no hashtags", "no jargon" (bare "no" as an answer is not a limit).
  static final _noThing = RegExp(r"\bno\s+(emojis?|links?|hashtags?|jargon|headings?|markdown|bullets?|lists?|tables?|filler|intro|preamble|"
      r"names?|numbers?|prices?|sugar|meat|pork|alcohol|ads?|spam|code|images?|pictures?|photos?|swearing|slang)\b", caseSensitive: false);

  /// Somali "don't": ha + (particle) + a verb ending in -in ("ha qorin", "ha ku darin", "ha u dirin"). Plain "ha" is also
  /// an English laugh, so it only counts in that shape.
  static final _haLimit = RegExp(r"\bha\s+(?:(?:ku|u|la|ka|ii|kuu|noo|soo|is)\s+)?[a-z']+in\b[^.?!\n;]{0,50}", caseSensitive: false);

  static Constraints read(String text) {
    final t = text.trim();
    if (t.isEmpty) return Constraints.none;
    final out = <String>[];
    final seen = <String>{};
    void add(String tag, String phrase) {
      final p = _clip(phrase);
      final key = p.toLowerCase();
      if (p.isEmpty || seen.contains(key)) return;
      // Skip a phrase already covered by a longer one ("3 ideas" inside "exactly 3 ideas").
      if (out.any((o) => o.toLowerCase().contains(key))) return;
      seen.add(key);
      out.add('$tag: $p');
    }

    for (final m in _language.allMatches(t)) {
      add('language', m.group(0)!);
    }
    for (final m in _count.allMatches(t)) {
      add('count', m.group(0)!);
    }
    for (final m in _countNoun.allMatches(t)) {
      add('count', m.group(0)!);
    }
    for (final m in _budget.allMatches(t)) {
      add('limit', m.group(0)!);
    }
    if (!out.any((o) => o.startsWith('limit:'))) {
      for (final m in _money.allMatches(t)) {
        add('amount', m.group(0)!);
      }
    }
    for (final m in _format.allMatches(t)) {
      add('format', m.group(0)!);
    }
    for (final m in _noThing.allMatches(t)) {
      add('avoid', m.group(0)!);
    }
    for (final m in _haLimit.allMatches(t)) {
      add('avoid', m.group(0)!);
    }
    for (final m in _limit.allMatches(t)) {
      final p = m.group(0)!;
      final w = m.group(1)!.toLowerCase();
      add(w == 'only' || w == 'just the' || w.startsWith('kaliya') || w.startsWith('keliya') || w == 'oo kaliya' ? 'only' : 'avoid', p);
    }
    return Constraints(out.take(8).toList(), parts: partsOf(t));
  }

  /// Number of separate asks: numbered/bulleted lines, several questions, "and also"/"then" joins.
  static int partsOf(String t) {
    final listed = RegExp(r'(^|\n)\s*(\d+[.)]|[-*•])\s+\S').allMatches(t).length;
    if (listed >= 2) return listed;
    final questions = RegExp(r'\?').allMatches(t).length;
    final joins = RegExp(r'\b(and also|also|then|after that|plus|as well as|iyo sidoo kale|sidoo kale|kadib|ka dib|kaddib|markaas)\b',
            caseSensitive: false)
        .allMatches(t)
        .length;
    final byJoins = 1 + (t.length > 25 ? joins : 0);
    final n = questions > byJoins ? questions : byJoins;
    return n >= 2 ? n : 1;
  }

  /// True when a message carries anything a fast, lightly prompted reply would likely drop.
  static bool hasConstraints(String text) => read(text).any;
}
