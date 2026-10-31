/// Makes small things fast. Every message is sorted into a lane before the model is called:
///
///  quick  greetings, thanks, "ok", "how are you", "who are you": no tools, a tiny prompt, a short reply.
///         The first words appear in about a second on any provider.
///  light  short everyday messages with no sign of an action or a request: only the core tools, plus `more_tools`
///         that opens the full set in the next step if it turns out to be needed. Nothing is ever out of reach.
///  full   everything else: all tools, the full prompt.
class QuickLane {
  static const quick = 'quick';
  static const light = 'light';
  static const full = 'full';

  /// Whole message is small talk (English, Somali, Arabic, French, Swahili and a few more).
  static final _smallTalk = RegExp(
      r'^(hi+|hello+|hey+|hiya|yo|sup|good (morning|afternoon|evening|night)|morning|evening|gm|gn|'
      r'how are (you|u)( doing)?|how r u|how is it going|how\x27s it going|what\x27s up|whats up|wassup|'
      r'thanks?( a lot| so much| you( so much| very much)?)?|thank u|thx|ty|cheers|appreciate it|great|awesome|perfect|nice|cool|'
      r'ok(ay)?|k|kk|alright|sure|yes|yeah|yep|yup|no|nope|nah|got it|understood|noted|fine|good|very good|amazing|wow|lol|haha+|'
      r'bye|goodbye|see you|see ya|later|take care|good job|well done|'
      r'who are you|what are you|what is your name|what\x27s your name|your name|are you there|you there|'
      r'salaam|salam|asc|as+alamu? ?alaykum|assalamu alaikum|wcs|wacalaykum salaam|waalaikum salam|'
      r'iska warran|iska waran|nabad|see tahay|sidee tahay|maxaa la socdaa|mahadsanid|mahadsantahay|haye|haa|maya|waa hagaag|hagaag|'
      r'marhaba|ahlan|shukran|sabah al ?khair|masa al ?khair|kayf halak|'
      r'bonjour|salut|merci|bonsoir|habari|jambo|asante|hola|gracias|ciao|hallo|danke|'
      r'مرحبا|اهلا|أهلا|شكرا|السلام عليكم|كيف حالك|صباح الخير|مساء الخير)'
      r'[\s,.!?😊🙂👍🙏❤️]*'
      r'((there|bro|friend|sir|man|buddy|mate|dear|walaal|saaxiib|habibi|again)[\s,.!?😊🙂👍🙏❤️]*)?'
      r'((submac|nova|amal|rank|ustad|[a-z]{2,12})[\s,.!?😊🙂👍🙏❤️]*)?$',
      caseSensitive: false);

  /// Words that mean "do something" or need fresh facts: never the quick lane.
  static final _action = RegExp(
      r'\b(search|find|look ?up|google|browse|open|go to|book|buy|order|pay|send|email|mail|text|sms|call|message|post|'
      r'remind|schedule|alarm|timer|calendar|event|meeting|create|make|build|write|draft|generate|draw|image|picture|photo|video|'
      r'download|upload|file|folder|pdf|doc|excel|sheet|slides|delete|remove|move|copy|install|run|code|deploy|push|'
      r'translate|summari[sz]e|research|compare|analy[sz]e|plan|price|weather|news|today|tomorrow|latest|current|now|'
      r'website|link|url|http|www|app|phone|screen|tap|click|login|log ?in|sign ?in|account|task|bot|office|team|chief|assign|'
      r'raadi|samee|dir|iibso|ii soo|qor|fur)\b|https?://|\.(com|org|net|so|io)\b',
      caseSensitive: false);

  /// A short answer to a question (yes, no, nope, maya, haa...). After SubMac asked something, it continues that task.
  static final _answer = RegExp(
      r'^(yes|yeah|yep|yup|yes please|no|nope|nah|no thanks|not now|not yet|never mind|ok(ay)?|k|sure|fine|go( ahead)?|do it|'
      r'both|neither|none|either|the first( one)?|the second( one)?|the last( one)?|first|second|third|this one|that one|'
      r'haa|haye|maya|mayo|waa hagaag|hagaag|labadaba|midna|kan|kaas|kii hore|kan koowaad|kan labaad)'
      r'[\s,.!?👍🙏]*((please|pls|thanks|thank you|walaal|saaxiib)[\s,.!?👍🙏]*)?$',
      caseSensitive: false);

  /// A question or a request in disguise ("can you...", "how do i...", "please help", "i need..."): real work
  /// whose wording may carry no action word, so it never takes the light lane — it gets the full prompt and
  /// every tool its words could point at (Claude Code rule, 2026-10-31: never guess a task into a small lane).
  static final _request = RegExp(
      r'\?|\b(can|could|would|will|should|shall|may|might|how|what|why|when|where|which|who|'
      r'please|pls|help|assist|need|needs|want|wants|advice|idea|ideas|suggest|suggestion|recommend|'
      r'caawi|ii sheeg|ii qor|ladoon|rabaa|rabtaa|u baahanahay)\b',
      caseSensitive: false);

  /// True when [text] carries a word that means "do something" (search, send, make, book...).
  static bool hasAction(String text) => _action.hasMatch(text);

  /// True when [text] asks or requests something even without an action word (see [laneFor]).
  static bool isRequest(String text) => _request.hasMatch(text.trim());

  /// True when the whole of [text] is small talk (a greeting, thanks, "ok").
  static bool isSmallTalk(String text) {
    final t = text.trim();
    return t.length <= 60 && _smallTalk.hasMatch(t) && !_action.hasMatch(t);
  }

  /// True when [text] is a short answer to a question (see [laneFor] answeringQuestion).
  static bool isAnswer(String text) => _answer.hasMatch(text.trim());

  /// The lane for the newest user message. [answeringQuestion] = SubMac's own last reply asked the user something
  /// (a question, choices, a confirm): then a short "no", "nope" or "maya" is an answer that continues the task,
  /// not small talk.
  static String laneFor(String text, {bool hasAttachments = false, bool midTask = false, bool answeringQuestion = false}) {
    final t = text.trim();
    if (hasAttachments || midTask || t.isEmpty) return full;
    if (answeringQuestion && _answer.hasMatch(t)) return full;
    if (t.length <= 60 && _smallTalk.hasMatch(t) && !_action.hasMatch(t)) return quick;
    if (t.length <= 160 && !_action.hasMatch(t) && !_request.hasMatch(t) && !t.contains('\n')) return light;
    return full;
  }
}
