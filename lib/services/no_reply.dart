/// Silence as the natural default (owner, 2026-10-24: "@silent makes things worse").
///
/// Before: every team and background job ended with "Nothing worth posting: end with @silent alone on the last line".
/// That hurt in four ways (docs/team-intelligence.md):
///  1. The owner's own "@silent" in a team chat looked like an @mention of a bot nobody has, so the message fell through
///     to the lead, who then answered: the opposite of what was meant.
///  2. A reply that answered the owner AND ended with the tag was thrown away whole (its kind was "silent").
///  3. A tag written mid-line ("Nothing to add. @silent") was not seen, so "@silent" showed up in the chat.
///  4. Saying "end with @silent" in every job primed the models to treat the team chat as a pipeline with a stop code.
///
/// Now a bot that has nothing useful to add simply replies with [token] (or nothing at all), as a person would just not
/// speak. The parser is lenient: the old tags still read as silence, a tag stuck to real text is stripped and the text
/// kept, and the owner's "@silent" means "just post this, nobody answer".
class NoReply {
  NoReply._();

  /// What a bot writes when it decides not to speak.
  static const token = '[no reply]';

  /// The one line every prompt that allows silence uses.
  static const rule = 'If you have nothing useful to add, reply with exactly [no reply] and nothing else. Staying quiet is normal '
      'and fine; never post filler, acknowledgements or status chatter.';

  static final _whole = RegExp(
      r'^[\s.,!:;"*_`()\-]*(\[\s*no[\s_-]*reply\s*\]|no[\s_-]*reply|@silent|silent|\[silent\]|no_change|nothing to add|\[no response\])[\s.,!:;"*_`()\-]*$',
      caseSensitive: false);

  /// Tags at the end of a reply (the old @silent and the new marker), with what precedes them on the same line.
  static final _tail = RegExp(r'\s*(\[\s*no[\s_-]*reply\s*\]|@silent\b)\s*$', caseSensitive: false);

  /// True when [text] says nothing: empty, the marker, or one of the old silence tags on its own.
  static bool isSilent(String text) {
    final t = text.trim();
    return t.isEmpty || _whole.hasMatch(t);
  }

  /// [text] without a trailing silence tag (the words before it are kept). Silent text becomes ''.
  static String clean(String text) {
    var t = text.trim();
    if (isSilent(t)) return '';
    for (var i = 0; i < 3 && _tail.hasMatch(t); i++) {
      t = t.replaceFirst(_tail, '').trimRight();
    }
    return isSilent(t) ? '' : t;
  }

  /// The owner asked for no answer: "@silent" (or "@quiet") anywhere in their message.
  static final _ownerQuiet = RegExp(r'(^|\s)@(silent|quiet)\b', caseSensitive: false);
  static bool ownerWantsQuiet(String text) => _ownerQuiet.hasMatch(text);

  /// The owner's message without the "@silent" marker.
  static String withoutOwnerQuiet(String text) => text.replaceAll(_ownerQuiet, ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
}
