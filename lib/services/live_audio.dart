import 'dart:math' as math;
import 'dart:typed_data';

/// Pure audio logic for Live calls, kept apart from the socket and the plugins so it can be tested.
///
/// Why this exists (v1.13.29): Gemini Live sends a long answer much faster than it is spoken (about 45 s of
/// speech arrives in 7 s). The phone then plays it from its own queue for the next 40 s, and the server keeps
/// the turn open until it thinks the playback is done. Anything its voice detector hears in that window
/// (the speaker's own echo, a door, a cough) ends the turn with `interrupted`, and the app had to throw the
/// rest of the queue away, so long answers were cut off. The mic now goes to the server as silence while
/// SubMac speaks, unless the user is clearly talking over it ([EchoGate]).

/// Voice detection on the server. The start of the user's turn needs a little more than a click or a breath
/// (prefix padding), and a short pause mid-sentence does not end their turn. Talking over SubMac still stops it.
const Map<String, dynamic> liveRealtimeInputConfig = {
  'automaticActivityDetection': {
    'prefixPaddingMs': 200,
    'silenceDurationMs': 800,
  },
  'activityHandling': 'START_OF_ACTIVITY_INTERRUPTS',
};

/// When the queued speech really ends on the speaker, and how loud it is at each moment.
class PlaybackClock {
  PlaybackClock({this.tail = const Duration(milliseconds: 400), this.drainGrace = const Duration(seconds: 2)});

  /// Kept "playing" this long after the estimated end: the speaker's own buffer and start-up delay.
  final Duration tail;

  /// When the plugin has not yet reported an empty queue, playback may run later than estimated by up to this.
  final Duration drainGrace;

  static const int sampleRate = 24000;
  static const int _segSamples = 2400; // 100 ms

  DateTime _end = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _drainedAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _awaitingDrain = false;
  final List<(DateTime, DateTime, double)> _segs = [];

  /// Estimated end of what is queued (without the tail).
  DateTime get end => _end;

  /// 16-bit mono PCM at 24 kHz was queued at [now].
  void feed(Uint8List pcm, DateTime now) {
    final samples = pcm.length ~/ 2;
    if (samples <= 0) return;
    var t = _end.isAfter(now) ? _end : now;
    for (var i = 0; i < samples; i += _segSamples) {
      final n = math.min(_segSamples, samples - i);
      final e = t.add(Duration(microseconds: (n / sampleRate * 1e6).round()));
      _segs.add((t, e, pcmRms(Uint8List.sublistView(pcm, i * 2, (i + n) * 2))));
      t = e;
    }
    _end = t;
    _awaitingDrain = true;
    final old = now.subtract(const Duration(seconds: 2));
    while (_segs.isNotEmpty && _segs.first.$2.isBefore(old)) {
      _segs.removeAt(0);
    }
  }

  /// The player says its queue is empty (the last chunk is in the speaker's small buffer).
  void drained(DateTime now) {
    _awaitingDrain = false;
    _drainedAt = now;
  }

  /// Playback was cut (the user spoke): nothing is queued any more.
  void flush() {
    _end = DateTime.fromMillisecondsSinceEpoch(0);
    _drainedAt = DateTime.fromMillisecondsSinceEpoch(0);
    _awaitingDrain = false;
    _segs.clear();
  }

  bool isPlaying(DateTime now) {
    if (now.isBefore(_end.add(tail))) return true;
    if (_awaitingDrain && now.isBefore(_end.add(drainGrace))) return true;
    return now.isBefore(_drainedAt.add(tail));
  }

  /// Seconds of speech still queued at [now] (0 when done).
  double secondsLeft(DateTime now) => math.max(0, _end.difference(now).inMicroseconds / 1e6);

  /// How loud SubMac's own speech is around [now] (the loudest part of the last ~0.4 s, since the echo
  /// reaches the mic a little late). 0 in a pause or when nothing plays.
  double levelAt(DateTime now) {
    final from = now.subtract(const Duration(milliseconds: 400));
    final to = now.add(const Duration(milliseconds: 50));
    var m = 0.0;
    for (final s in _segs) {
      if (s.$2.isBefore(from) || s.$1.isAfter(to)) continue;
      if (s.$3 > m) m = s.$3;
    }
    return m;
  }
}

/// What to send for one mic chunk.
class GateResult {
  const GateResult(this.send);

  /// Chunks to send, in order. A chunk the gate holds back goes out as silence of the same length.
  final List<Uint8List> send;
}

/// Decides, chunk by chunk, whether the mic is heard by the server while SubMac is speaking.
///
/// Not speaking: everything passes. Speaking: the mic goes out as silence. The gate knows how loud SubMac's
/// own speech is at each moment ([PlaybackClock.levelAt]) and learns how much of it comes back into the mic
/// (the echo ratio). Only a voice clearly louder than the expected echo, held for about a third of a second
/// (short gaps forgiven), counts as the user talking over SubMac; then the last half second (so the first word
/// is not lost) and everything after it is sent, and the server stops the answer as usual.
class EchoGate {
  EchoGate({
    this.minLevel = 0.10,
    this.overEcho = 2.0,
    this.holdMs = 300,
    this.preRollMs = 500,
    this.releaseMs = 1500,
  });

  /// Below this level (0..1 RMS) nothing ever counts as talking over SubMac.
  final double minLevel;

  /// How many times louder than the expected echo a voice must be.
  final double overEcho;

  /// How long (ms, with short gaps forgiven) the voice must last before it counts.
  final int holdMs;

  /// How much recent mic audio is sent when the user starts talking over SubMac.
  final int preRollMs;

  /// After this long without a raised voice the gate closes again (a false start).
  final int releaseMs;

  static const int bytesPerMs = 32; // 16 kHz, 16-bit mono
  static const double _startRatio = 0.3;

  /// The first moment SubMac speaks in a call is used to measure the echo (nobody talks over a first word).
  static const int calibrateMs = 1200;
  int _calibratedMs = 0;

  /// Learnt share of SubMac's own voice that comes back into the mic (kept across answers in one call).
  double _ratio = _startRatio;
  double _score = 0;
  bool _open = false;
  int _quietMs = 0;
  bool _wasPlaying = false;
  final List<Uint8List> _preRoll = [];
  int _preRollBytes = 0;

  /// True while the user is talking over SubMac and the mic is going through.
  bool get bargeIn => _open;

  /// The learnt echo ratio.
  double get echoRatio => _ratio;

  /// The level a mic chunk must reach to count as the user while SubMac plays at [speakerLevel].
  double threshold(double speakerLevel) => math.max(minLevel, _ratio * speakerLevel * overEcho);

  void _resetRun() {
    _score = 0;
    _open = false;
    _quietMs = 0;
    _preRoll.clear();
    _preRollBytes = 0;
  }

  GateResult process(Uint8List chunk, double rms, {required bool playing, double speakerLevel = 0, bool muted = false}) {
    if (muted) {
      _resetRun();
      _wasPlaying = playing;
      return GateResult([Uint8List(chunk.length)]);
    }
    if (!playing) {
      if (_wasPlaying) _resetRun();
      _wasPlaying = false;
      return GateResult([chunk]);
    }
    if (!_wasPlaying) {
      _resetRun();
      _wasPlaying = true;
    }
    final ms = math.max(1, chunk.length ~/ bytesPerMs);
    final loud = rms >= threshold(speakerLevel);
    if (_open) {
      _quietMs = loud ? 0 : _quietMs + ms;
      if (_quietMs >= releaseMs) {
        // It was not the user after all (or they stopped): back to silence.
        _resetRun();
        _remember(chunk);
        return GateResult([Uint8List(chunk.length)]);
      }
      return GateResult([chunk]);
    }
    // Learn the echo ratio while SubMac's voice is clearly playing: quickly from chunks that look like echo,
    // slowly from loud ones (so a strong echo still lifts it, while a real voice barely moves it).
    var calibrating = false;
    if (speakerLevel >= 0.02) {
      final r = (rms / speakerLevel).clamp(0.0, 3.0);
      if (_calibratedMs < calibrateMs) {
        calibrating = true;
        _calibratedMs += ms;
        _ratio = _ratio * 0.7 + r * 0.3;
      } else {
        _ratio = loud ? _ratio * 0.98 + r * 0.02 : _ratio * 0.9 + r * 0.1;
      }
      _ratio = _ratio.clamp(0.02, 3.0);
    }
    _score = loud && !calibrating ? _score + ms : math.max(0, _score - ms / 2);
    _remember(chunk);
    if (_score >= holdMs) {
      _open = true;
      _quietMs = 0;
      final out = List<Uint8List>.from(_preRoll);
      _preRoll.clear();
      _preRollBytes = 0;
      return GateResult(out);
    }
    return GateResult([Uint8List(chunk.length)]);
  }

  void _remember(Uint8List chunk) {
    _preRoll.add(chunk);
    _preRollBytes += chunk.length;
    while (_preRoll.length > 1 && _preRollBytes - _preRoll.first.length >= preRollMs * bytesPerMs) {
      _preRollBytes -= _preRoll.removeAt(0).length;
    }
  }
}

/// Loudness (0..1 RMS) of 16-bit little-endian PCM, every 4th sample.
double pcmRms(Uint8List bytes) {
  final bd = ByteData.sublistView(bytes);
  final n = bytes.length ~/ 2;
  if (n == 0) return 0;
  var sum = 0.0;
  var count = 0;
  for (var i = 0; i < n; i += 4) {
    final v = bd.getInt16(i * 2, Endian.little) / 32768.0;
    sum += v * v;
    count++;
  }
  return math.sqrt(sum / count);
}

/// Gemini durations look like "12s" or "1.5s" (also "500ms"). Null when unreadable.
Duration? parseLiveDuration(Object? v) {
  if (v is num) return Duration(milliseconds: (v * 1000).round());
  if (v is! String) return null;
  final s = v.trim();
  final m = RegExp(r'^(\d+(?:\.\d+)?)(ms|s)$').firstMatch(s);
  if (m == null) return null;
  final n = double.parse(m.group(1)!);
  return Duration(milliseconds: m.group(2) == 'ms' ? n.round() : (n * 1000).round());
}

/// When to move to a new connection after a goAway: as soon as the current answer has fully arrived
/// (and no step is running), or a few seconds before the server closes the old one, whichever is first.
bool goAwayMoveNow({
  required DateTime now,
  required DateTime deadline,
  required bool generating,
  required bool toolRunning,
}) {
  if (!now.isBefore(deadline)) return true;
  return !generating && !toolRunning;
}

/// App notes (task news, the minute warning) wait until SubMac has finished speaking, so they do not cut an
/// answer off: a new turn sent while the model is answering ends that answer. After [maxWait] they go anyway.
bool injectMayGo({
  required bool speaking,
  required bool generating,
  required bool toolRunning,
  required Duration waited,
  Duration maxWait = const Duration(seconds: 60),
}) {
  if (waited >= maxWait) return true;
  return !speaking && !generating && !toolRunning;
}
