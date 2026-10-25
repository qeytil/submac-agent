import 'dart:math' as math;
import 'dart:typed_data';

/// Keeps what the caller said since SubMac last answered (16 kHz mono PCM16), so a Somali turn can be written down
/// again by a model that knows Somali. The call's own live transcription is weak for Somali; this fixes the chat
/// the call is saved to (and so the tasks, the recap and later calls that read it).
class UtteranceClipper {
  UtteranceClipper({this.maxSeconds = 45});

  static const rate = 16000;
  static const _frame = 640; // 20 ms of PCM16 at 16 kHz

  final int maxSeconds;
  final BytesBuilder _buf = BytesBuilder(copy: true);

  int get length => _buf.length;

  void add(Uint8List chunk) {
    if (chunk.isEmpty) return;
    _buf.add(chunk);
    final max = maxSeconds * rate * 2;
    if (_buf.length > max * 1.5) {
      // Keep only the newest [maxSeconds]: a very long turn loses its start, never the end.
      final all = _buf.takeBytes();
      _buf.add(Uint8List.sublistView(all, all.length - max));
    }
  }

  void clear() => _buf.clear();

  /// The voiced part of what was collected (leading and trailing silence trimmed), or null when it holds less
  /// than [minVoicedMs] of speech. Always empties the buffer.
  Uint8List? cut({int minVoicedMs = 500, double threshold = 0.02}) {
    final all = _buf.takeBytes();
    final max = maxSeconds * rate * 2;
    final pcm = all.length > max ? Uint8List.sublistView(all, all.length - max) : all;
    final frames = pcm.length ~/ _frame;
    if (frames == 0) return null;
    var first = -1, last = -1, voiced = 0;
    for (var f = 0; f < frames; f++) {
      if (frameRms(pcm, f * _frame, _frame) >= threshold) {
        if (first < 0) first = f;
        last = f;
        voiced++;
      }
    }
    if (first < 0 || voiced * 20 < minVoicedMs) return null;
    // A little air on both sides so first and last sounds are not clipped.
    final from = math.max(0, first - 10) * _frame;
    final to = math.min(frames, last + 16) * _frame;
    return Uint8List.fromList(pcm.sublist(from, to));
  }

  static double frameRms(Uint8List pcm, int offset, int length) {
    final bd = ByteData.sublistView(pcm, offset, offset + length);
    var sum = 0.0;
    final n = length ~/ 2;
    for (var i = 0; i < n; i++) {
      final s = bd.getInt16(i * 2, Endian.little) / 32768.0;
      sum += s * s;
    }
    return n == 0 ? 0 : math.sqrt(sum / n);
  }
}

/// A WAV file around raw PCM16 mono audio.
Uint8List wavFromPcm16(Uint8List pcm, {int sampleRate = 16000}) {
  final h = ByteData(44);
  void tag(int at, String s) {
    for (var i = 0; i < 4; i++) {
      h.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  h.setUint32(4, 36 + pcm.length, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  h.setUint32(16, 16, Endian.little);
  h.setUint16(20, 1, Endian.little); // PCM
  h.setUint16(22, 1, Endian.little); // mono
  h.setUint32(24, sampleRate, Endian.little);
  h.setUint32(28, sampleRate * 2, Endian.little);
  h.setUint16(32, 2, Endian.little);
  h.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  h.setUint32(40, pcm.length, Endian.little);
  return Uint8List.fromList([...h.buffer.asUint8List(), ...pcm]);
}

/// The model's transcript as one clean line: no speaker labels, quotes or notes. Empty when it heard nothing.
String cleanTurnTranscript(String raw) {
  var t = raw.trim();
  t = t.replaceAll(RegExp(r'^(speaker\s*\d+|caller|user|qofka)\s*:\s*', caseSensitive: false, multiLine: true), '');
  t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (t.length >= 2 && ((t.startsWith('"') && t.endsWith('"')) || (t.startsWith('“') && t.endsWith('”')))) {
    t = t.substring(1, t.length - 1).trim();
  }
  final low = t.toLowerCase();
  if (low.isEmpty || low == '[silence]' || low == '(silence)' || low.startsWith('no speech') || low.startsWith('[no speech')) return '';
  return t;
}
