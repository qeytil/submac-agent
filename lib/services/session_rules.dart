/// Small, pure decisions that keep one chat, bot or account from leaking into another. No Flutter, no platform calls,
/// so each rule is tested on its own (test/trust_fixes_test.dart). The app state calls these at the exact points where
/// a task, a call or a message picks the chat it belongs to.
library;

/// Where a background task (a scheduled run, Telegram, a Live request, a bot wake, team work) goes.
enum BgTarget {
  /// Back into the chat it asked for ([reuseConvId]).
  reuse,

  /// Not started now: its own chat is busy and it must not spill anywhere else.
  busy,

  /// A new chat of its own, without changing what the user is looking at.
  ownChat,

  /// The chat on screen.
  current,

  /// A new chat that also becomes the chat on screen (Live's own tasks).
  newChat,
}

class SessionRules {
  SessionRules._();

  /// Picks the chat for a background task.
  ///
  /// * A task that names its chat goes back there when that chat is loaded and free. When it is busy (or being
  ///   started this very moment) a bot's work and a task with no title of its own report busy; a task with a title
  ///   gets its own chat. It never lands in whatever chat happens to be on screen.
  /// * Otherwise it goes into the chat on screen only when that is the user's own, free chat; a bot's chat that is
  ///   merely open on screen is never borrowed for Telesia's work.
  static BgTarget backgroundTarget({
    String? reuseConvId,
    bool reuseLoaded = false,
    bool reuseBusy = false,
    bool reuseIsBot = false,
    bool hasOwnTitle = false,
    String? currentId,
    bool currentBusy = false,
    bool currentIsForeignBot = false,
  }) {
    if (reuseConvId != null) {
      if (reuseLoaded && !reuseBusy) return BgTarget.reuse;
      if (reuseIsBot) return BgTarget.busy;
      if (reuseBusy && !hasOwnTitle) return BgTarget.busy;
      return BgTarget.ownChat;
    }
    if (hasOwnTitle) return BgTarget.ownChat;
    if (currentId == null || currentBusy || currentIsForeignBot) return BgTarget.newChat;
    return BgTarget.current;
  }

  /// Where a Telesia Live call is saved when it has no chat yet: the chat on screen, unless that is a bot's chat
  /// (a Telesia call never writes into a bot's history). Returns null for "a new Live chat".
  static String? liveSaveTarget({String? currentId, bool currentIsBot = false}) =>
      (currentId == null || currentIsBot) ? null : currentId;

  /// A new chat created by the first message may become the chat on screen only if the user is still looking at
  /// that same draft (they did not tap "+" or open another chat while it was saving).
  static bool adoptNewChat({required String? currentId, required Object onScreen, required Object draft}) =>
      currentId == null && identical(onScreen, draft);

  /// After Stop: the "Working on your task" notification goes as soon as no task is left, instead of waiting for the
  /// stopped step to come back.
  static bool keepAliveOffAfterStop({required int tasksLeft, required bool telegramWaiting}) => tasksLeft == 0 && !telegramWaiting;
}

/// Takes secrets out of text before it is written to the device log (error messages can carry a URL with a token).
class LogScrub {
  LogScrub._();

  static final _patterns = <RegExp>[
    RegExp(r'((?:access_token|token|apikey|api_key|key|secret|password|pass|sig|signature)=)[^&\s#"\x27]+', caseSensitive: false),
    RegExp(r'(Bearer\s+)[A-Za-z0-9._~+/=-]+', caseSensitive: false),
    RegExp(r'()\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{4,}'),
    RegExp(r'()\b(?:sk|pk|rk|ck|ak)[-_][A-Za-z0-9_-]{12,}'),
  ];

  /// [e] as text with tokens, keys and passwords replaced by `***`.
  static String clean(Object? e) {
    var s = '$e';
    for (final p in _patterns) {
      s = s.replaceAllMapped(p, (m) => '${m.group(1) ?? ''}***');
    }
    return s;
  }
}
