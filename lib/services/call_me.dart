/// "Call me": the user wants SubMac, or the bot they are talking to, to call THEM, here in the app (the Live voice call:
/// the call screen, or a bot's incoming-call card). Never a phone number: the phone dialer (call_number) and WhatsApp
/// calls are only for another person or a number the user gives.
///
/// Owner report (2026-10-26): "Bots lost their calling tools. If I say 'call me', it always asks which number instead of
/// calling me in the app." The main agent had no in-app call tool at all (only the dialer, which needs a number), and a
/// bot's bot_call was missing from its chat prompt since the Grok-style rewrite, with a hedged description next to the
/// dialer's, so the model reached for the dialer and asked for a number.
class CallMe {
  CallMe._();

  /// The main agent's in-app call. A bot has its own [botTool] (it rings, with quiet hours, "calls off" and the daily cap).
  static const tool = 'call_user';
  static const botTool = 'bot_call';

  static const _words = 'Use it whenever the user asks you to call them or to talk by voice: "call me", "ring me", '
      '"give me a call", Somali "i soo wac" / "ii wac", Arabic "اتصل بي". Never ask for their phone number for this: the call '
      'happens inside SubMac. Not for calling another person or a number: that is call_number (or a WhatsApp call).';

  static final Map<String, dynamic> definition = {
    'type': 'function',
    'function': {
      'name': tool,
      'description': 'Start an in-app voice call between you and the user right now (SubMac\'s own call screen, no phone '
          'number needed; it uses their call minutes as any call does). $_words',
      'parameters': {
        'type': 'object',
        'properties': {
          'reason': {'type': 'string', 'description': 'Optional: what the call is about, in a few words.'},
        },
        'required': <String>[],
      },
    },
  };

  /// bot_call's description (the tool itself and its rules live in Bots).
  static const botDescription = 'Ring the user now for an in-app voice call with you (their incoming-call screen in SubMac, '
      'no phone number needed). $_words Also when it is truly worth a call on your own.';

  /// The dialer's description: only for someone else or a number the user gives.
  static const dialerDescription = 'Open the phone dialer with a number ready, to call another person or a number the user gives. '
      'The user taps call. Never for "call me": when the user wants you to call them, use the in-app call ($tool, or $botTool for a bot).';

  /// What call_number answers when it got no number.
  static const dialerNoNumber = 'Error: no phone number. If the user asked you to call them, do not ask for a number: start the '
      'in-app call ($tool, or $botTool for a bot). call_number is only for another person or a number they give.';

  /// One line for the chat prompts (main agent phone section and every bot).
  static const promptLine = '- "Call me" (ring me, give me a call, i soo wac, اتصل بي) means an in-app voice call with you: $tool '
      '(a bot: $botTool). Never ask for their phone number for it. call_number and WhatsApp calls are only for another person or a '
      'number the user gives.';
  static const botPromptLine = '- The owner says "call me" (ring me, i soo wac, اتصل بي): ring them now with $botTool, an in-app call. '
      'Never ask for a phone number for it; call_number is only for another person or a number they give.';

  // ---------------------------------------------------------------- reading the request

  /// English: "call me", "ring me", "give me a call", "call me back"...
  static final _en = RegExp(
      r"\b(call|ring|phone|buzz)\s+me\b|\bgive\s+me\s+a\s+(quick\s+)?(call|ring|buzz)\b|"
      r"\b(start|have|do|make)\s+a\s+(voice\s+|quick\s+)?call\s+with\s+me\b|\blet'?s\s+(talk|speak)\s+(on\s+(a|the)\s+)?(call|phone)\b|"
      r"\b(can|could|will|would)\s+(we|you)\s+(talk|speak)\s+(by|on\s+(a|the))\s+(voice|call|phone)\b",
      caseSensitive: false);

  /// What may follow "call me" when it still means a call ("call me now", "call me back"), not a name ("call me Ali").
  static final _afterCallMe = RegExp(
      r"\b(call|ring|phone|buzz)\s+me\b\s*([,.!?…]|$|now|back|please|pls|plz|asap|right|quick|quickly|again|here|in\s+the\s+app|on\s+submac|when|if|so|and|i\s+want|we|let'?s)",
      caseSensitive: false);

  /// Somali: wac = call, soo = toward me, i / ii = me ("i soo wac", "ii wac", "soo wac", "i garaac").
  static final _so = RegExp(r"\b(i|ii)\s+(soo\s+)?(wac|garaac)\b|\bsoo\s+(i\s+)?wac\b|\bwicitaan\s+(ii|i)\s+(samee|soo\s+dir)\b",
      caseSensitive: false);

  /// Arabic (no \b in Arabic script).
  static final _ar = RegExp(r'(اتصل|اتصلي|إتصل|إتصلي|رن|دق|كلم|كلمي)\s*(بي|علي|عليّ|علىّ|لي|فيني|معي)|كلمني|كلميني|اتصل\s+بيا');

  /// "Don't call me", "never call me", "stop calling me"...
  static final _no = RegExp(
      r"\b(don'?t|do\s+not|never|not|no\s+need\s+to|stop)\s+(\w+\s+)?(call|ring|phone)(ing)?\s+me\b|\bha\s+(i\s+|ii\s+)?(soo\s+)?wac(in)?\b|لا\s*(تتصل|تتصلي)",
      caseSensitive: false);

  /// A later call is a follow-up or routine of kind "call", not a call now.
  static final _later = RegExp(
      r"\b(tomorrow|tonight|later|in\s+\d+\s*(min|mins|minutes|hours?|h)|at\s+\d|every|each|on\s+(mon|tue|wed|thu|fri|sat|sun)\w*|"
      r"morning|evening|next\s+(week|day)|berri|caawa|subaxdii|galabta|fiidkii|saacad)\b|غدا|غداً|بكرة|لاحقا|لاحقاً|كل\s+يوم|الساعة",
      caseSensitive: false);

  /// A phone number in the message: then the user means that number (the dialer), not the in-app call.
  static final _number = RegExp(r'\+?\d[\d\s\-()]{6,}\d');

  /// True when [text] asks SubMac (or the bot) to call the user now, in the app.
  static bool wantsCallNow(String text) {
    final t = text.trim();
    if (t.isEmpty || t.length > 300) return false;
    if (_number.hasMatch(t) || _no.hasMatch(t) || _later.hasMatch(t)) return false;
    if (_so.hasMatch(t) || _ar.hasMatch(t)) return true;
    if (!_en.hasMatch(t)) return false;
    // "call me Ali" names the user; "call me", "call me now", "please call me back" ask for a call.
    final plain = RegExp(r"\b(call|ring|phone|buzz)\s+me\b", caseSensitive: false);
    if (plain.hasMatch(t) && !_afterCallMe.hasMatch(t)) {
      // Only "call me <word>" left: a call when another call phrase is there too ("give me a call, call me Ali" is rare).
      final other = RegExp(r"\bgive\s+me\s+a\s+(quick\s+)?(call|ring|buzz)\b|\bcall\s+with\s+me\b|\b(talk|speak)\s+(by|on)\b", caseSensitive: false);
      return other.hasMatch(t);
    }
    return true;
  }

  /// The step note when the newest message asks for a call now: start it, do not ask for a number.
  static String turnNote({required bool bot}) => '# The user asked you to call them\n'
      'Start the in-app voice call now with ${bot ? botTool : tool}${bot ? ' (reason: a few words on what it is about)' : ''}. Do not ask for a '
      'phone number and do not use call_number or WhatsApp: the call happens inside SubMac. If a tool result already shows the '
      'call started, is ringing or cannot happen, do not call again: tell the user in one short line.';

  // ---------------------------------------------------------------- results of call_user

  static String opening(String reason) => '[Call] The user asked you to call them from the chat'
      '${reason.isEmpty ? '' : ' (about: $reason)'}. Greet them by voice in one short sentence, then help.';
  static const started = 'The in-app voice call with the user has started and the call screen is open. Reply with one very short '
      'line at most (for example "Calling you now."); the conversation continues by voice.';
  static const alreadyOnCall = 'The user is already on a voice call with you. Do not start another one.';
  static const unavailable = 'Voice calls are not available right now, so no call started. Tell the user in one short line that '
      'you cannot call right now and that they can keep typing here. Do not ask for a phone number.';
  static String noMinutes(String why) => 'No call started: $why Tell the user this in one short line. Do not ask for a phone number.';
  static const notInApp = 'The user is not in SubMac right now, so a call cannot start. Send them a short message instead.';
}
