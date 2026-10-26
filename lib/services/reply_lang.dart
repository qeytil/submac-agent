import 'somali.dart';

/// Launch hardening (H-1): the agent answers in the language the user wrote in, also after long tool work.
///
/// The system prompt already says "reply in the language the user writes in", but it sits at the very top of a long
/// request. After a few English web pages, files or tool results the final reply often drifted to English for a
/// Somali or Arabic question. Two small pieces fix that without a model call:
///  * [anchor]: one line at the END of every step's request (the tail note, so the prompt cache is untouched) naming
///    the language of the user's latest message;
///  * [mismatch]: a finish check. A final reply that is plainly in another language goes back once to be rewritten.
///    It only fires on clear cases (Arabic script vs Latin, Somali vs English) and never when the user asked for a
///    translation or for the answer in another language.
class ReplyLang {
  ReplyLang._();

  static final _arabic = RegExp(r'[\u0600-\u06FF\u0750-\u077F\u08A0-\u08FF\uFB50-\uFDFF\uFE70-\uFEFF]');
  static final _latin = RegExp(r'[A-Za-z\u00C0-\u024F]');
  static final _persianUrdu = RegExp(r'[\u067E\u0686\u0698\u06AF\u06A9\u06CC\u0679\u0688\u0691\u06BA\u06D2]');
  static final _ethiopic = RegExp(r'[\u1200-\u137F]');
  static final _words = RegExp(r"[A-Za-z\u00C0-\u024F']+");

  /// Common English words: enough of them in a Latin text means English (not Somali, French, Swahili...).
  static const _en = {
    'the', 'and', 'is', 'are', 'to', 'of', 'a', 'an', 'in', 'on', 'for', 'you', 'your', 'i', 'my', 'me', 'it', 'this',
    'that', 'what', 'how', 'can', 'please', 'with', 'be', 'do', 'does', 'was', 'will', 'have', 'has', 'not', 'from',
    'about', 'which', 'when', 'where', 'why', 'who', 'we', 'they', 'there', 'here', 'make', 'write', 'give', 'tell',
    'help', 'need', 'want', 'should', 'could', 'would', 'if', 'or', 'but', 'so', 'all', 'some', 'any', 'more', 'just',
  };

  /// Display names of the codes [detect] returns.
  static const names = {'ar': 'Arabic', 'so': 'Somali', 'en': 'English', 'am': 'Amharic'};

  /// The user asked for another language on purpose: a translation, or the answer/document in a named language.
  static final _otherLanguageAsk = RegExp(
      r'(translat|turjun|turjum|tarjum|ترجم|ترجمة|'
      r'\b(in|into|to)\s+(english|arabic|somali|french|spanish|swahili|turkish|german|italian|chinese|hindi|urdu|amharic)\b|'
      r'\baf[- ](ingiriis|carabi|soomaali|faransiis|talyaani|turki)\w*|\b(ingiriisi|carabi)\b|'
      r'بالإنجليزي|بالانجليزي|بالإنجليزية|بالانجليزية|بالعربي|بالصومالي|باللغة)',
      caseSensitive: false);

  /// Text with code blocks, inline code, cards, links and paths removed: what the user reads as language.
  static String prose(String t) => t
      .replaceAll(RegExp(r'```[\s\S]*?(```|$)'), ' ')
      .replaceAll(RegExp(r'`[^`\n]*`'), ' ')
      .replaceAll(RegExp(r'\]\([^)\s]*\)'), ']')
      .replaceAll(RegExp(r'https?://\S+|www\.\S+'), ' ')
      .replaceAll(RegExp(r'(^|\s)/[\w./\-]+'), ' ')
      .replaceAll(RegExp(r'\$\$[\s\S]*?\$\$|\\\[[\s\S]*?\\\]|\\\([\s\S]*?\\\)'), ' ');

  /// The language of [text]: 'ar' (Arabic script), 'am' (Ethiopic script), 'so' (Somali), 'en' (English), or null when
  /// there is too little to tell or it is another language.
  static String? detect(String text) {
    final t = prose(text);
    final ar = _arabic.allMatches(t).length;
    final la = _latin.allMatches(t).length;
    final et = _ethiopic.allMatches(t).length;
    // Persian and Urdu share the script: their own letters mean "not Arabic", so the generic line is used instead.
    if (ar >= 2 && ar >= la) return _persianUrdu.hasMatch(t) ? null : 'ar';
    if (et >= 2 && et >= la) return 'am';
    final words = _words.allMatches(t.toLowerCase()).map((m) => m.group(0)!).toList();
    if (words.length < 2) return null;
    if (Somali.detect(t)) return 'so';
    final en = words.where(_en.contains).length;
    if (words.length <= 4 ? en >= 1 : en * 5 >= words.length) return 'en';
    return null;
  }

  /// The language to answer in: the newest of the user's messages (newest first) that says enough to tell. Short
  /// answers ("ok", "haa", "2") carry the language of the message before them.
  static String? ofChat(Iterable<String> userTextsNewestFirst) {
    var looked = 0;
    for (final t in userTextsNewestFirst) {
      if (++looked > 4) break;
      final l = detect(t);
      if (l != null) return l;
    }
    return null;
  }

  /// Whether [userText] asks for a translation or for the answer in a named language.
  static bool asksOtherLanguage(String userText) => _otherLanguageAsk.hasMatch(userText);

  /// The tail-note line for this step. [setting] is the app's reply language ('auto' or a language name).
  static String anchor(String? lang, {String setting = 'auto'}) {
    if (setting != 'auto' && setting.trim().isNotEmpty) {
      return '# Reply language\nWrite your reply to the user in $setting (their setting), even when tool results, pages or files '
          'are in another language, unless they ask for another language for this answer.';
    }
    final name = names[lang];
    if (name == null) {
      return '# Reply language\nWrite your reply in the language of the user\'s latest message, even when tool results, pages or files '
          'are in another language. Use another language only if they asked for it (a translation, a text in another language).';
    }
    return '# Reply language\nThe user\'s latest message is in $name. Write your reply to them in $name, even when tool results, pages or '
        'files are in another language. Keep names, code, numbers and links as they are. Use another language only if they asked for it '
        '(a translation, a text in another language).';
  }

  /// Whether a final [reply] is plainly in another language than [userLang] (the user did not ask for another one).
  static bool mismatch(String reply, String? userLang, {String userText = ''}) {
    if (userLang == null || asksOtherLanguage(userText)) return false;
    final t = prose(reply);
    final ar = _arabic.allMatches(t).length;
    final la = _latin.allMatches(t).length;
    final words = _words.allMatches(t.toLowerCase()).map((m) => m.group(0)!).toList();
    final en = words.where(_en.contains).length;
    switch (userLang) {
      case 'ar':
        // An Arabic question answered in Latin letters only (brand names alone never trip it).
        return la >= 60 && ar * 10 < la;
      case 'so':
        // A Somali question answered in plain English.
        return words.length >= 25 && ar * 4 < la && !Somali.detect(t) && en * 4 >= words.length;
      case 'en':
        // An English question answered in Arabic script, or in Somali.
        if (ar >= 60 && ar > la * 2) return true;
        return words.length >= 25 && Somali.detect(t) && en * 10 < words.length;
    }
    return false;
  }

  /// The note that sends a reply in the wrong language back (one round).
  static String fixNote(String userLang) {
    final name = names[userLang] ?? 'the user\'s language';
    return '# Reply in $name\nThe user wrote in $name, but your reply is in another language. Send the same reply again, fully in '
        '$name (keep names, code, numbers, links and cards as they are). Do not call tools.';
  }

  /// Picks the phrase for [lang] ('so', 'ar', else English).
  static String pick(String? lang, {required String en, required String so, required String ar}) =>
      switch (lang) { 'so' => so, 'ar' => ar, _ => en };
}
