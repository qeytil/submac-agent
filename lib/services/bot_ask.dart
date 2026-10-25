import 'quick_lane.dart';

/// How a bot opens a conversation, the Grok Bot way (owner, 2026-10-24: "focus on grok first"; research in
/// docs/grok-bots-research.md). On Grok a Bot is a teammate you message: a clear task is carried through end to end
/// without check-ins, and the Bot comes back only for a judgment call or an approval. A bot never starts work nobody gave
/// it, though: when its chat is first opened, or the owner only greets it, it answers in a few calm lines, says what it can
/// take on and suggests one or two concrete first tasks as tap replies (Grok shows suggestions; its Primary Bot "offers to
/// handle" work rather than starting it).
///
/// Enforced in the prompt ([rule], through BotManner.block) and in the engine: an opening or small-talk turn in a bot's
/// chat gets no tools at all (the agent runner switches it to the quick lane with [turnNote]). Any real request runs
/// normally, with the approval rules in Settings > Full access / Trust level.
class BotAsk {
  BotAsk._();

  /// The wake reasons that open a chat rather than give work (the first meeting after a bot is made or started).
  static bool isOpening(String reason) {
    final r = reason.toLowerCase();
    return r.startsWith('first meeting') || r.contains('opened your chat') || r.startsWith('greeting');
  }

  /// The reason inside an app wake's text ("[first meeting: …]\n…" or "[Woken: …. 2026-10-24 09:00]\n…"), or '' when none.
  static String wakeReasonOf(String wakeText) {
    final t = wakeText.trimLeft();
    if (!t.startsWith('[')) return '';
    final end = t.indexOf(']');
    var r = end < 0 ? t.substring(1) : t.substring(1, end);
    if (r.startsWith('Woken: ')) r = r.substring(7);
    return r.trim();
  }

  /// Words that ask a bot to do something, beyond the action words the quick lane knows. English, Somali, Arabic.
  static final _request = RegExp(
      r"\b(can you|could you|would you|will you|please|pls|i need|i want|i'd like|id like|let's|lets|go ahead|start|do it|do that|"
      r'get me|show me|tell me about|help me with|set up|setup|check|fix|update|prepare|organi[sz]e|track|list|review|explain|'
      r'fadlan|ii sheeg|ii samee|ii qor|i tus|bilow|hubi|sax|diyaari)\b|'
      r'(من فضلك|ارجو|أريد|اريد|اعمل|ابحث|اكتب|ارسل|أرسل|ابدأ|جهز|راجع)',
      caseSensitive: false);

  /// True when [text] is a clear request to act: an action word ("search", "send", "make"), a polite ask ("could you…",
  /// "please…"), or an imperative the owner means as work.
  static bool isRequest(String text) {
    final t = text.trim();
    if (t.isEmpty) return false;
    return QuickLane.hasAction(t) || _request.hasMatch(t);
  }

  /// Whether this turn of a bot chat only greets and suggests (no tools, no work): the chat was just opened, or the owner
  /// only greeted it or made small talk. Everything else is a request and runs normally (Grok: message a Bot and it gets
  /// the work done).
  ///
  /// [text] is the newest user message (or the app's wake text). [wakeReason] is set when the app woke the bot (only an
  /// opening wake holds; routines are work the owner already gave). [answeringBot] = the bot's last reply asked something,
  /// so a short "yes" or "the first one" is the go-ahead. [midTask] = a task in this chat is running or paused.
  static bool askFirst({required String text, String? wakeReason, bool answeringBot = false, bool midTask = false}) {
    if (wakeReason != null) return isOpening(wakeReason);
    if (midTask) return false;
    final t = text.trim();
    if (t.isEmpty) return true;
    if (answeringBot && QuickLane.isAnswer(t)) return false;
    return QuickLane.isSmallTalk(t);
  }

  /// The standing rule in every bot prompt (part of BotManner.block).
  static const rule = '# Working with the owner\n'
      '- When the owner gives you a task, carry it through end to end, the way a capable colleague would: no check-ins at '
      'every step. Come back only for a real judgment call, information only they have, or an approval the app asks for.\n'
      '- When they only greet you, do not start anything: say in a line what you can take on and suggest '
      'one or two concrete first tasks from your job as a ```choices card (a JSON list of one or two short tap replies).\n'
      '- Never add work they did not ask for. Routines and follow-ups the owner set up are work they already gave you.';

  /// The turn note when the engine holds a turn to asking (no tools in this reply).
  static String turnNote({required bool opening}) => '# This turn: greet and suggest\n'
      '${opening ? 'The owner has just opened your chat. ' : 'The owner only greeted you; there is no task yet. '}'
      'You have no tools in this reply and you start no work. If they asked a plain question you can answer from what you '
      'know, answer it in a line or two. Otherwise greet them back briefly, say in one line what you can take on, and ask what '
      'they would like done. End with a ```choices card of two or three concrete suggestions from your job (short, specific, '
      'in their language), written exactly like this on its own lines:\n```choices\n["Draft this week\'s sales summary","Check today\'s open orders","Plan next week\'s stock"]\n```\n'
      'No lists, no headings, no emoji. Wait for their answer.';
}
