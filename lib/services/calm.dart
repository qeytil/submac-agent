/// Turns raw failures into calm, plain words, and notices when the user is getting frustrated,
/// so SubMac can change approach instead of repeating itself.
class CalmError {
  final String title;
  final String body;

  /// What the main button does: retry, settings, newchat, none.
  final String action;
  final String raw;
  const CalmError(this.title, this.body, this.action, this.raw);
}

class Calm {
  Calm._();

  static bool isContextTooLong(String e) => RegExp(
          r'context.{0,20}(length|window|limit)|maximum context|too many tokens|prompt is too long|input is too long|'
          r'request too large|reduce the length|too long to send in one go|413',
          caseSensitive: false)
      .hasMatch(e);

  static bool offline(String e) => RegExp(r'socketexception|failed host lookup|network is unreachable|connection (closed|reset|refused|failed)|no address|clientexception',
          caseSensitive: false)
      .hasMatch(e);

  static CalmError explain(String raw) {
    final e = raw.toLowerCase();
    bool has(String p) => RegExp(p, caseSensitive: false).hasMatch(e);
    if (has(r"done a lot today|refreshes tomorrow|resting until tomorrow|allowance|today's replies|replies in your plan|get a plan")) {
      return CalmError('That\'s it for today', raw, 'none', raw);
    }
    // PLAN 1.3: nothing came back within 45 s. The message is kept; tapping tries again.
    if (has(r'tap to try again')) {
      return CalmError('SubMac is busy', 'Tap to try again.', 'retry', raw);
    }
    if (has(r'sign in again|\b401\b|unauthori[sz]ed|jwt')) {
      return CalmError('Please sign in again', 'Your session ended. Log out and back in from Settings, then try again.', 'settings', raw);
    }
    if (has(r'account needs attention|\bblocked\b')) {
      return CalmError('Your account needs attention', 'Please contact SubMac support at submac.site.', 'none', raw);
    }
    if (has(r'short break')) {
      return CalmError('SubMac is taking a short break', 'Please try again in a few minutes.', 'retry', raw);
    }
    if (isContextTooLong(raw)) {
      return CalmError('This chat got too long',
          'Start a new chat; I\'ll keep what matters in memory.', 'newchat', raw);
    }
    if (has(r"you're offline|socketexception|failed host lookup|network error|connection (closed|reset|refused)|no address|handshake")) {
      return CalmError('No connection',
          'I couldn\'t reach the internet. Check your data or Wi-Fi, then try again.', 'retry', raw);
    }
    if (has(r'timeout|timed out|took too long')) {
      return CalmError('That took too long', 'Try again in a moment.', 'retry', raw);
    }
    if (has(r'\b429\b|\b5\d\d\b|busy|rate limit|too many requests|overloaded|couldn.t reach its models|couldn.t get an answer just now|lost the connection')) {
      return CalmError('SubMac is busy', 'Lots of people are using it right now. Try again in a moment.', 'retry', raw);
    }
    if (has(r'safety|content policy|content_filter|refus')) {
      return CalmError('I couldn\'t answer that', 'Try rewording it.', 'retry', raw);
    }
    if (has(r'empty response')) {
      return CalmError('No answer came back', 'Try again.', 'retry', raw);
    }
    if (has(r'could not save')) {
      return CalmError('Not saved yet', 'Your message is here, but it didn\'t sync. It will try again.', 'none', raw);
    }
    return CalmError('That didn\'t go through', 'Something went wrong on the way. Try again.', 'retry', raw);
  }

  /// Plan 5.5: one short, warm line for a snackbar or a status row, never a raw error.
  /// [app] names what was being reached ("Notion"), when there is one.
  static String short(Object raw, {String? app}) {
    final e = raw.toString().toLowerCase();
    final who = app ?? 'It';
    if (offline(e) || RegExp(r"failed host lookup|network|handshake").hasMatch(e)) {
      return app == null ? 'You\'re offline. Try again once you\'re connected.' : 'You\'re offline, so $app can\'t be reached. Try again once you\'re connected.';
    }
    if (RegExp(r'\b401\b|\b403\b|unauthori[sz]ed|invalid.{0,10}(token|key)|expired').hasMatch(e)) {
      return app == null ? 'That sign-in has expired. Connect again to carry on.' : '$app needs you to sign in again.';
    }
    if (RegExp(r'timeout|timed out|took too long').hasMatch(e)) {
      return '$who is slow to answer right now. Try again in a moment.';
    }
    if (RegExp(r'\b429\b|\b5\d\d\b|busy|rate limit|too many|overloaded|unavailable').hasMatch(e)) {
      return '$who is resting for a moment. Try again in a few minutes.';
    }
    return app == null ? 'That didn\'t go through. Try again in a moment.' : '$app didn\'t answer this time. Try again in a moment.';
  }

  static final _angry = RegExp(
      r"\b(not working|doesn'?t work|does not work|didn'?t work|still (not|broken|wrong|the same)|broken|useless|stupid|"
      r"idiot|dumb|wtf|wth|ffs|annoying|frustrat\w*|i told you|wrong again|you never|terrible|horrible|worst|"
      r"waste of time|ugh+)\b|"
      // Somali
      r"\b(ma shaqeynayo|ma shaqaynayo|kuma shaqeyn|waa khalad|khalad baa|waan ku idhi|waan kuu sheegay|maxaad|"
      r"nacas|doqon|waan ka daalay)\b|"
      // Arabic
      r"(لا يعمل|ما يشتغل|غلط|قلت لك|مرة ثانية|ليش|سيء)",
      caseSensitive: false);

  static final _mild = RegExp(
      r"(again|fix it|come on|seriously|why (can'?t|won'?t|didn'?t|isn'?t) (you|it)|still|weli|mar kale)",
      caseSensitive: false);

  /// 0 calm, 1 a little frustrated, 2 clearly frustrated.
  static int frustration(String text, {List<String> earlier = const [], int recentErrors = 0}) {
    final t = text.trim();
    if (t.isEmpty) return 0;
    var score = 0;
    if (_angry.hasMatch(t)) score += 2;
    if (_mild.hasMatch(t)) score += 1;
    if (RegExp(r'[!?]{2,}').hasMatch(t)) score += 1;
    final letters = t.replaceAll(RegExp(r'[^A-Za-z]'), '');
    if (letters.length >= 8 && letters.replaceAll(RegExp(r'[^A-Z]'), '').length / letters.length > 0.6) score += 1;
    // Asking the same thing again.
    final low = _norm(t);
    for (final e in earlier) {
      if (low.length > 6 && _similar(low, _norm(e)) > 0.75) {
        score += 1;
        break;
      }
    }
    score += recentErrors.clamp(0, 2);
    return score >= 3 ? 2 : (score >= 2 ? 1 : 0);
  }

  static String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9\u0600-\u06FF ]'), '').trim();

  static double _similar(String a, String b) {
    if (a.isEmpty || b.isEmpty) return 0;
    final wa = a.split(' ').toSet(), wb = b.split(' ').toSet();
    final inter = wa.intersection(wb).length;
    return inter / (wa.length > wb.length ? wa.length : wb.length);
  }

  static String guidance(int level) {
    if (level <= 0) return '';
    return '# The user is frustrated\n'
        '${level >= 2 ? 'They are clearly upset: something has failed more than once.' : 'They sound a little frustrated.'}\n'
        '- Start with one short, sincere line that names the actual problem (no "I understand your frustration", no long apology, '
        'no excuses, never blame them).\n'
        '- Do NOT repeat what failed. Change approach: a different tool, site, model or method. If you are unsure what they want, '
        'ask ONE short, specific question instead of guessing again.\n'
        '- Keep the reply short and concrete: the fix or the next step first. No filler, no lists unless needed.\n'
        '- If it truly cannot be done, say so plainly and offer the closest thing that works.\n'
        '- Stay warm and calm; match their language.';
  }
}
