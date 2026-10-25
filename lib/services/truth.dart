/// Proof, not promises.
///
/// A completion claim is only true when a tool result from the same task backs
/// it. Everything here is pure Dart - no Flutter, no network, no IO - so the
/// rule that decides "did this really happen?" can be reasoned about and tested
/// on its own.
library;

/// One tool result from the current task.
class Evidence {
  const Evidence({required this.tool, required this.ok, this.summary = ''});

  /// The tool that ran, e.g. `whatsapp_send`.
  final String tool;

  /// True when the tool returned a result instead of an error.
  final bool ok;

  /// The start of what the tool returned, kept for the corrective note.
  final String summary;
}

class _Claim {
  _Claim(this.what, String pattern, this.tools)
      : re = RegExp(pattern, caseSensitive: false);

  /// Plain words for the corrective note, e.g. "a message was sent".
  final String what;
  final RegExp re;

  /// Tool-name fragments that would prove it.
  final List<String> tools;
}

/// Phrasings that assert an action already happened, and the tools that prove it.
final List<_Claim> _claims = [
  _Claim(
    'a message was sent',
    r"(?:i(?:'ve| have)? (?:just )?(?:sent|shared|messaged|emailed|texted|forwarded)|(?:has|have) been sent|(?:it'?s|it is|message is|email is) (?:sent|delivered)|sent it|sent successfully|message sent|email sent|dm sent|sent (?:the|a|an|your|my|his|her|their|him|them|this|that)\b)",
    const ['send', 'whatsapp', 'telegram', 'sms', 'email', 'mail', 'imessage', 'signal', 'dm'],
  ),
  _Claim(
    'a booking was made',
    r"(?:i(?:'ve| have)? (?:just )?(?:booked|reserved)|booked it|booking (?:is )?confirmed|reservation (?:is )?confirmed|(?:has|have) been booked)",
    const ['book', 'calend', 'reserv', 'ticket', 'flight', 'appoint'],
  ),
  _Claim(
    'a file was saved',
    r"(?:i(?:'ve| have)? (?:just )?(?:saved|written|stored|downloaded)|saved (?:it|the file|to|your)|(?:has|have) been saved|written to (?:the )?file|file (?:is )?(?:saved|written))",
    const ['write_file', 'append_file', 'edit_file', 'download', 'save', 'export', 'create_file', 'upload'],
  ),
  _Claim(
    'something was created',
    r"(?:i(?:'ve| have)? (?:just )?(?:created|made|added|set up|scheduled|generated|built)|(?:has|have) been (?:created|added|scheduled|generated)|created (?:the|a|your))",
    const ['create', 'write_file', 'append_file', 'generate', 'make', 'add_', 'calendar', 'alarm', 'reminder', 'doc', 'sheet', 'slide'],
  ),
  _Claim(
    'something was deleted',
    r"(?:i(?:'ve| have)? (?:just )?(?:deleted|removed|cleared)|(?:has|have) been (?:deleted|removed)|deleted (?:it|the|your))",
    const ['delete', 'remove', 'clear', 'trash'],
  ),
  _Claim(
    'something was posted',
    r"(?:i(?:'ve| have)? (?:just )?(?:posted|published|uploaded|shared)|(?:has|have) been (?:posted|published|uploaded)|posted it|published it|uploaded it)",
    const ['post', 'publish', 'upload', 'share', 'tweet', 'social'],
  ),
  _Claim(
    'a payment went through',
    r"(?:i(?:'ve| have)? (?:just )?(?:paid|bought|ordered|purchased)|payment (?:is )?(?:complete|confirmed|sent)|order (?:is )?(?:placed|confirmed)|paid for)",
    const ['pay', 'buy', 'order', 'purchase', 'checkout', 'cart', 'stripe'],
  ),
  _Claim(
    'a call was placed',
    r"(?:i(?:'ve| have)? (?:just )?called|call (?:is )?(?:done|complete)|(?:has|have) been called|called (?:him|her|them))",
    const ['call', 'phone_', 'dial', 'twilio'],
  ),
  _Claim(
    'an app was installed',
    r"(?:i(?:'ve| have)? (?:just )?installed|installed (?:it|the app)|(?:has|have) been installed)",
    const ['install', 'apk', 'package'],
  ),
  _Claim(
    'a command ran successfully',
    r"(?:i(?:'ve| have)? (?:just )?ran|command (?:completed|succeeded|finished)|script (?:completed|succeeded|finished)|tests? (?:passed|pass))",
    const ['run_shell', 'shell', 'exec', 'terminal', 'code_run', 'bash', 'script'],
  ),
];

final RegExp _split = RegExp(r'(?<=[.!?])\s+|\n+|\r+');
final RegExp _fence = RegExp(r'```[\s\S]*?(?:```|$)');
final RegExp _negated = RegExp(
    r"\b(?:not|never|couldn't|could not|can't|cannot|unable|failed|didn't|did not|wasn't|was not|isn't|is not|hasn't|has not|haven't|have not|yet to)\b",
    caseSensitive: false);

class Truth {
  Truth._();

  /// The reason a reply is not backed by evidence, or null when it is honest.
  static String? unproven(String reply, List<Evidence> evidence) {
    final text = reply.replaceAll(_fence, ' ').trim();
    if (text.isEmpty) return null;
    final proved = [for (final e in evidence) if (e.ok) e.tool];
    final missing = <String>[];
    for (final sentence in text.split(_split)) {
      final s = sentence.trim();
      if (s.isEmpty || _negated.hasMatch(s)) continue;
      for (final c in _claims) {
        if (!c.re.hasMatch(s)) continue;
        final ok = proved.any((tool) => c.tools.any(tool.contains));
        if (!ok && !missing.contains(c.what)) missing.add(c.what);
      }
    }
    if (missing.isEmpty) return null;
    final said = missing.length == 1
        ? missing.first
        : '${missing.take(missing.length - 1).join(', ')} and ${missing.last}';
    return 'You said $said, but no successful tool result in this task shows it.';
  }
}

/// The user's explicit requirements, kept so they can be shown again at the
/// moment the model decides it is finished.
class PromptContract {
  PromptContract._();

  static const Map<String, String> _numberWords = {
    'one': '1',
    'two': '2',
    'three': '3',
    'four': '4',
    'five': '5',
    'six': '6',
    'seven': '7',
    'eight': '8',
    'nine': '9',
    'ten': '10',
  };

  static final RegExp _count = RegExp(
      r'\b(\d+|one|two|three|four|five|six|seven|eight|nine|ten)\s+(bullets?|lines?|sentences?|paragraphs?|options?|items?|steps?|examples?|ideas?)\b',
      caseSensitive: false);

  static final RegExp _language = RegExp(
      r'\b(?:in|into|to)\s+(somali|arabic|english|swahili|french|spanish|hindi|urdu|turkish|amharic|chinese|german|portuguese|italian|russian)\b',
      caseSensitive: false);

  static final RegExp _doNot =
      RegExp(r"\b(?:don'?t|do not|never)\s+([a-z][a-z0-9 ,'-]{2,40})", caseSensitive: false);

  static final RegExp _use =
      RegExp(r'\buse\s+([A-Za-z][A-Za-z0-9 .+_\-]{1,28})', caseSensitive: false);

  static final RegExp _format = RegExp(
      r'\b(?:as|in)\s+(?:a\s+|an\s+)?(table|bullet points?|numbered list|list|json|csv|pdf|docx?|spreadsheet|code)\b',
      caseSensitive: false);

  static final RegExp _wordLimit =
      RegExp(r'\b(?:under|less than|max(?:imum)?|at most)\s+(\d+)\s+words?\b', caseSensitive: false);

  static final RegExp _cut =
      RegExp(r'\b(?:to|and|for|in|on|with|from|that|which|please|as)\b|[.,;:!?]', caseSensitive: false);

  /// Pulls out only requirements that are stated explicitly and can be re-read.
  static List<String> extract(String userText) {
    final text = userText.trim();
    if (text.isEmpty) return const <String>[];
    final out = <String>[];
    void add(String v) {
      final value = v.trim();
      if (value.isEmpty || out.contains(value) || out.length >= 8) return;
      out.add(value);
    }

    for (final m in _count.allMatches(text)) {
      final raw = m.group(1)!.toLowerCase();
      add('exactly ${_numberWords[raw] ?? raw} ${m.group(2)!.toLowerCase()}');
    }
    for (final m in _language.allMatches(text)) {
      add('reply in ${_title(m.group(1)!)}');
    }
    for (final m in _doNot.allMatches(text)) {
      final rest = _clean(m.group(1)!);
      if (rest.isNotEmpty) add('do not $rest');
    }
    for (final m in _use.allMatches(text)) {
      final rest = _clean(m.group(1)!);
      if (rest.isNotEmpty) add('use $rest');
    }
    for (final m in _format.allMatches(text)) {
      add('format as ${m.group(1)!.toLowerCase()}');
    }
    for (final m in _wordLimit.allMatches(text)) {
      add('keep it under ${m.group(1)} words');
    }
    return out;
  }

  /// A compact block for the prompt; empty when the user set no requirements.
  static String block(List<String> requirements) {
    if (requirements.isEmpty) return '';
    final sb = StringBuffer(
        "\n\n# The user's own requirements for this task (re-read before you finish)\n");
    for (final r in requirements) {
      sb.writeln('- $r');
    }
    return sb.toString();
  }

  static String _clean(String raw) {
    final s = raw.trim();
    final cut = _cut.firstMatch(s);
    final body = cut != null && cut.start > 0 ? s.substring(0, cut.start) : s;
    return body.trim().replaceAll(RegExp(r'\s+'), ' ');
  }

  static String _title(String w) =>
      w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1).toLowerCase()}';
}
