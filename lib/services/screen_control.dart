/// Who is driving the phone's screen right now (SubMac's own task, a bot's run, Live), and when each last did
/// something. Pure logic with no Flutter or platform calls, so it can be tested on its own.
///
/// It decides two things:
///  * whether the "SubMac is using your phone" badge may stay up (some owner is still active), and
///  * which task the floating chat bubble should show.
///
/// The watchdog: an owner that has not taken a step for a while is dropped, even if nobody told us it ended (a crash,
/// a lost callback, a run that hung). A step still in progress, or a question waiting on the user, keeps its owner.
class ScreenControl {
  ScreenControl({
    this.idle = const Duration(seconds: 45),
    this.pinnedIdle = const Duration(minutes: 2),
    this.stepMax = const Duration(seconds: 90),
  });

  /// An owner with no run behind it (Live, a browser job) is dropped this long after its last step.
  final Duration idle;

  /// An owner whose run is still going (pinned) is dropped this long after its last step: the watchdog.
  final Duration pinnedIdle;

  /// A step that never reports back counts as finished after this long.
  final Duration stepMax;

  final Map<String, ScreenOwner> _owners = {};

  /// The owner id Live uses (it has no chat of its own while it acts).
  static const live = 'live';

  bool get any => _owners.isNotEmpty;
  Iterable<ScreenOwner> get owners => _owners.values;
  ScreenOwner? owner(String id) => _owners[id];

  /// A screen step is starting (a tap, a WhatsApp action, a browser step).
  void stepStarted(String id, String label, DateTime now) {
    final o = _owners.putIfAbsent(id, () => ScreenOwner(id, now));
    o.last = now;
    o.stepAt = now;
    o.steps++;
    if (label.trim().isNotEmpty) o.label = label.trim();
  }

  /// The step finished (whatever the result).
  void stepFinished(String id, DateTime now) {
    final o = _owners[id];
    if (o == null) return;
    o.last = now;
    o.stepAt = null;
  }

  /// A run is behind this owner: it uses the longer watchdog instead of the short idle time.
  void pin(String id, DateTime now) {
    final o = _owners.putIfAbsent(id, () => ScreenOwner(id, now));
    o.pinned = true;
  }

  /// The owner's run ended (success, failure, cancel): it stops controlling the screen at once.
  /// Returns true when it was there.
  bool end(String id) => _owners.remove(id) != null;

  /// Every owner ends (Stop, the app restarted, phone control turned off).
  void clear() => _owners.clear();

  /// Whether [o] has gone quiet long enough to be dropped.
  bool stale(ScreenOwner o, DateTime now, {bool waiting = false}) {
    if (waiting) return false;
    final step = o.stepAt;
    if (step != null) return now.difference(step) > stepMax;
    return now.difference(o.last) > (o.pinned ? pinnedIdle : idle);
  }

  /// The watchdog: drops owners that went quiet. [waiting] says whether an owner is waiting on the user (an approval,
  /// a question); those stay. Returns the ids dropped.
  List<String> prune(DateTime now, {bool Function(String id)? waiting}) {
    final gone = <String>[];
    for (final o in _owners.values.toList()) {
      if (stale(o, now, waiting: waiting?.call(o.id) ?? false)) gone.add(o.id);
    }
    for (final id in gone) {
      _owners.remove(id);
    }
    return gone;
  }

  /// The owner the bubble shows: the most recently active one that has a chat (not Live).
  ScreenOwner? focus() {
    ScreenOwner? best;
    for (final o in _owners.values) {
      if (o.id == live) continue;
      if (best == null || o.last.isAfter(best.last)) best = o;
    }
    return best;
  }
}

class ScreenOwner {
  ScreenOwner(this.id, this.last);
  final String id;
  DateTime last;
  DateTime? stepAt;
  bool pinned = false;
  int steps = 0;
  String label = '';
}

/// Whether the floating bubble may show at all.
bool bubbleAllowed({required bool appVisible, required bool hasFocus, required bool liveFloating}) =>
    hasFocus && !appVisible && !liveFloating;

/// One message as the bubble shows it.
class BubbleLine {
  const BubbleLine(this.me, this.text);
  final bool me;
  final String text;
  Map<String, Object> toJson() => {'me': me, 'text': text};
}

/// The newest chat lines for the bubble: user and assistant text only (no tool output, no empty steps), oldest first,
/// each trimmed to one short paragraph. [messages] are (role, content) pairs, oldest first.
List<BubbleLine> bubbleLines(Iterable<(String, String)> messages, {int max = 4, int chars = 220}) {
  final out = <BubbleLine>[];
  for (final (role, content) in messages.toList().reversed) {
    if (role != 'user' && role != 'assistant') continue;
    var t = content.replaceAll(RegExp(r'```[\s\S]*?```'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.isEmpty) continue;
    if (t.length > chars) t = '${t.substring(0, chars - 1).trimRight()}…';
    out.add(BubbleLine(role == 'user', t));
    if (out.length >= max) break;
  }
  return out.reversed.toList();
}

/// A short "what it is doing now" line for the collapsed bubble.
String bubbleStep(String label, {int chars = 48}) {
  var t = label.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (t.isEmpty) return 'Working on it';
  if (t.length > chars) t = '${t.substring(0, chars - 1).trimRight()}…';
  return t;
}

/// The question the bubble asks, in the one approval card's terms: Approve · Edit · Not now.
class BubbleAsk {
  const BubbleAsk({
    required this.id,
    required this.kind,
    required this.who,
    required this.title,
    this.body = '',
    this.editText,
    this.options = const [],
    this.needsApp = false,
  });

  /// approval (a bot's ask), confirm (SubMac's own ask), question (the task asks something), app (only in the app).
  final String id;
  final String kind;
  final String who;
  final String title;
  final String body;

  /// The text the user may change before approving (null = Edit means "ask me what to change").
  final String? editText;
  final List<String> options;

  /// Sign-ins and private answers are never typed into the bubble: it offers "Open SubMac".
  final bool needsApp;

  Map<String, Object?> toJson() => {
        'id': id,
        'kind': kind,
        'who': who,
        'title': title,
        'body': body,
        'editable': editText != null,
        'editText': editText ?? '',
        'options': options,
        'needsApp': needsApp,
      };
}

/// What Edit does on an ask: open the text to change it, or tell the asker the user wants a change.
enum BubbleEdit { inPlace, askForChange }

BubbleEdit bubbleEditMode(BubbleAsk a) => a.editText != null ? BubbleEdit.inPlace : BubbleEdit.askForChange;

/// The whole state the native bubble draws, as plain JSON-ready values.
Map<String, Object?> bubbleState({
  required String owner,
  required String who,
  required String step,
  required List<BubbleLine> lines,
  BubbleAsk? ask,
  bool canType = true,
}) =>
    {
      'owner': owner,
      'who': who,
      'step': bubbleStep(step),
      'messages': [for (final l in lines) l.toJson()],
      'ask': ask?.toJson(),
      'canType': canType,
    };
