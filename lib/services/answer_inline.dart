/// CB-39: long answers came back only as files (a .docx card and six words) when the user never asked for a file.
/// The rule: make a file only when the user asks for one; otherwise the answer is written in the chat. This is the
/// finish-gate check behind it: a final reply under [minWords] words whose only content is a file card, for a request
/// that did not ask for a file, gets one fix round to answer inline.
class InlineAnswer {
  InlineAnswer._();

  static const minWords = 40;

  static final _fence = RegExp(r'```([a-zA-Z0-9_-]*)[^\n]*\n[\s\S]*?(```|$)');
  static final _fileCard = RegExp(r'```file\b');

  /// The user asked for a file (English, Somali, Arabic): a document, PDF, Word, Excel, slides, a download...
  static final _asked = RegExp(
      r'\b(files?|documents?|docs?|docx|pdfs?|word|excel|xlsx|csv|spreadsheets?|sheets?|slides?|presentations?|powerpoint|pptx?|'
      r'download(able)?|attach(ment|ed)?|export|txt|cv|resume|résumé|invoice|receipt|certificate|letterhead|printable|print|'
      r'fayl|feyl|faylka|dukumenti|dukumiinti|dukumeenti)\b|\.(pdf|docx?|xlsx|csv|txt|pptx?)\b|ملف|مستند|وورد|إكسل|اكسل|عرض تقديمي|تحميل',
      caseSensitive: false);

  /// "not in a file", "no PDF", "without a document", "don't make a file": a request for no file (run 1 t5 said so).
  static final _refused = RegExp(
      r"\b(not|no|without|don'?t|do not|never|rather than|instead of)\b[^.,;!?\n]{0,25}?\b(files?|documents?|docs?|pdfs?|docx|word|attachments?)\b",
      caseSensitive: false);

  static bool askedForFile(String userText) => _asked.hasMatch(userText.replaceAll(_refused, ' '));

  /// The words of the reply outside its cards and code blocks.
  static int words(String reply) {
    final t = reply.replaceAll(_fence, ' ');
    return RegExp(r'[^\s]+').allMatches(t).where((m) => RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(m.group(0)!)).length;
  }

  /// A file card is the reply's only real content.
  static bool fileOnly(String reply) => _fileCard.hasMatch(reply) && words(reply) < minWords;

  /// Whether this final reply goes back once to be answered inline.
  static bool needsInline({required String reply, required String userText, required int rounds}) =>
      rounds < 1 && userText.trim().isNotEmpty && !askedForFile(userText) && fileOnly(reply);

  static const note = '# Answer in the chat\n'
      'The user did not ask for a file, so the answer belongs in the chat. Write the full answer here now as text, in the '
      'user\'s language, with everything the file holds. You may keep the file card under it, but do not make another file.';
}
