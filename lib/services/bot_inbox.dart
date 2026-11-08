/// A person's event inbox (owner 2026-11-08).
///
/// Events about the world — a watched notification, and later an email, a price or a page changing — wait in one
/// person's [BotInbox] instead of waking them one at a time. A burst becomes ONE wake carrying one digest, so a busy
/// group chat does not become five turns, and nothing about one person's events reaches another.
class BotEvent {
  BotEvent({
    required this.key,
    required this.source,
    required this.title,
    this.detail = '',
    this.instruction = '',
    DateTime? at,
  }) : at = at ?? DateTime.now();

  /// The dedupe key: the same thing is never delivered twice (the native side may repeat a delivery).
  final String key;

  /// Where it came from: 'notification' today; 'email', 'site', ... later.
  final String source;

  /// One short line: "a new WhatsApp message from Ali".
  final String title;

  /// The raw thing itself (already clipped by the producer).
  final String detail;

  /// What the person asked to happen for this kind of event (a watch's instruction; '' when none).
  final String instruction;

  final DateTime at;

  Map<String, dynamic> toJson() => {
        'key': key,
        'src': source,
        'title': title,
        'detail': detail,
        'ins': instruction,
        'at': at.toIso8601String(),
      };

  static BotEvent fromJson(Map<String, dynamic> j) => BotEvent(
        key: '${j['key']}',
        source: '${j['src'] ?? 'event'}',
        title: '${j['title'] ?? ''}',
        detail: '${j['detail'] ?? ''}',
        instruction: '${j['ins'] ?? ''}',
        at: DateTime.tryParse('${j['at']}') ?? DateTime.now(),
      );
}

/// One person's queue of events. Bounded, deduped, and emptied by a single wake.
class BotInbox {
  BotInbox(this.botId);

  final String botId;

  /// The most events held (the digest stays a readable size); older ones fall off first.
  static const max = 20;

  /// How many delivered keys are remembered for dedupe.
  static const seenMax = 60;

  final List<BotEvent> _events = [];
  final List<String> _seen = [];
  final Set<String> _seenSet = {};

  List<BotEvent> get events => List.unmodifiable(_events);
  int get length => _events.length;
  bool get isEmpty => _events.isEmpty;

  /// Queues [e] unless its key was already delivered. True when it is new.
  bool add(BotEvent e) {
    if (!_seenSet.add(e.key)) return false;
    _seen.add(e.key);
    while (_seen.length > seenMax) {
      _seenSet.remove(_seen.removeAt(0));
    }
    _events.add(e);
    while (_events.length > max) {
      _events.removeAt(0);
    }
    return true;
  }

  /// Empties the queue (the wake that carries it has taken it).
  List<BotEvent> take() {
    final out = List<BotEvent>.from(_events);
    _events.clear();
    return out;
  }

  /// Tests: start from nothing.
  void clear() {
    _events.clear();
    _seen.clear();
    _seenSet.clear();
  }

  /// The one instruction a wake carries for [events]: what arrived, and what the person asked to do about each kind.
  static String digest(List<BotEvent> events) {
    final lines = <String>[];
    final asks = <String>[];
    for (final e in events) {
      final hhmm = '${e.at.hour.toString().padLeft(2, '0')}:${e.at.minute.toString().padLeft(2, '0')}';
      final body = e.detail.trim();
      lines.add('- $hhmm ${e.title}${body.isEmpty ? '' : ': $body'}');
      final ask = e.instruction.trim();
      if (ask.isNotEmpty && !asks.contains(ask)) asks.add(ask);
    }
    return 'These just arrived for you:\n${lines.join('\n')}'
        '${asks.isEmpty ? '' : '\n\nWhat you asked to be told about:\n${asks.map((a) => '- $a').join('\n')}'}'
        '\n\nFor each thing, decide what genuinely helps the owner and do it with your tools. '
        'Nothing worth telling them: reply with only [no reply].';
  }
}