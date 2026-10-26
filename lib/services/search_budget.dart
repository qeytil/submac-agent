import 'dart:convert';

import 'web_tools.dart';

/// CB-38: one task's budget for searching that does not work. With no search key, web_search can fall back to
/// Wikipedia (or find nothing) again and again; the model then loops through searches and starts costly read-only
/// browser tasks. Per task:
///   * after [weakLimit] searches that came back empty or Wikipedia-only, every further search result carries a note:
///     stop searching, read known sites with fetch_url, or answer with what you have;
///   * a read-only browser_task (research, look up, compare) runs at most [browserReadLimit] time(s). Tasks that act on
///     a site (sign in, book, buy, fill, send...) are not counted.
class SearchBudget {
  static const weakLimit = 2;
  static const browserReadLimit = 1;

  int weakSearches = 0;
  int browserReads = 0;

  /// A search that gave the model nothing it can use as a web result: an error, no results, or Wikipedia only.
  static bool isWeak(String output) {
    final t = output.trim();
    if (t.startsWith('Error')) return true;
    try {
      final j = jsonDecode(t);
      if (j is! Map) return false;
      if (j['engine'] == 'Wikipedia' || j['warning'] == WebTools.wikiOnlyWarning) return true;
      final r = j['results'];
      return r is List && r.isEmpty;
    } catch (_) {
      return false;
    }
  }

  static final _acts = RegExp(
      r'\b(sign(ed|ing)?[ -]?(in|up)|log(ged|ging)?[ -]?in|register|book(ing)?|reserve|buy|purchase|order|pay|checkout|check out|'
      r'add to (the )?cart|subscribe|unsubscribe|cancel|apply|submit|fill( in| out)?|post|publish|send|message|reply|comment|upload|'
      r'download|create (an? )?account|delete|edit|change|update|install|enrol+|join|follow|like|share|transfer|renew)\b',
      caseSensitive: false);

  /// A browser_task whose goal only reads (research, find, compare, look up a price).
  static bool readOnlyBrowser(Map<String, dynamic> args) {
    final goal = '${args['goal'] ?? ''} ${args['details'] ?? ''}';
    if (goal.trim().isEmpty) return false;
    return !_acts.hasMatch(goal);
  }

  static const browserCapText = 'Not started: a read-only browser task already ran in this task, and they are slow and costly. '
      'Read the exact pages you need with fetch_url, or answer now with what you have and say plainly what you could not check.';

  static const stopSearchingNote = '\n\nNote: web search is not working in this task (several searches came back empty or '
      'with encyclopedia results only). Do not search again. Read known sites directly with fetch_url (the official site, '
      'a well-known shop, news or reference site for this topic), or answer now with what you have and say plainly what '
      'you could not check.';

  /// Before a call runs: the text to give back instead of running it, or null to run it.
  String? before(String tool, Map<String, dynamic> args) {
    if (tool == 'browser_task' && readOnlyBrowser(args)) {
      if (browserReads >= browserReadLimit) return browserCapText;
      browserReads++;
    }
    return null;
  }

  /// After a call ran: its output; a weak search from the [weakLimit]th on carries the stop-searching note (a search
  /// that worked never does: DuckDuckGo fails only some of the time).
  String after(String tool, String output) {
    if (tool != 'web_search') return output;
    if (!isWeak(output)) return output;
    weakSearches++;
    return weakSearches >= weakLimit ? '$output$stopSearchingNote' : output;
  }
}
