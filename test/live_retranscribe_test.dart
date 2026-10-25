import 'dart:typed_data';

import 'package:agent/services/live_retranscribe.dart';
import 'package:agent/services/somali.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List tone(int ms, {int amp = 8000}) {
  final n = 16 * ms;
  final bd = ByteData(n * 2);
  for (var i = 0; i < n; i++) {
    bd.setInt16(i * 2, i.isEven ? amp : -amp, Endian.little);
  }
  return bd.buffer.asUint8List();
}

Uint8List silence(int ms) => Uint8List(32 * ms);

void main() {
  group('utterance clipper', () {
    test('trims silence and keeps the voiced part', () {
      final c = UtteranceClipper()
        ..add(silence(2000))
        ..add(tone(1000))
        ..add(silence(2000));
      final clip = c.cut()!;
      // 1 s of speech plus a little air (0.2 s before, 0.3 s after)
      expect(clip.length, greaterThanOrEqualTo(32 * 1000));
      expect(clip.length, lessThan(32 * 1600));
      expect(c.length, 0);
    });

    test('a click or breath is not a turn', () {
      final c = UtteranceClipper()
        ..add(silence(1000))
        ..add(tone(200))
        ..add(silence(1000));
      expect(c.cut(), isNull);
      expect((UtteranceClipper()..add(silence(3000))).cut(), isNull);
    });

    test('a very long turn keeps its newest seconds', () {
      final c = UtteranceClipper(maxSeconds: 5);
      for (var i = 0; i < 20; i++) {
        c.add(tone(1000));
      }
      expect(c.cut()!.length, lessThanOrEqualTo(5 * 32000));
    });
  });

  test('wav header', () {
    final w = wavFromPcm16(tone(100));
    expect(String.fromCharCodes(w.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(w.sublist(8, 12)), 'WAVE');
    expect(ByteData.sublistView(w).getUint32(24, Endian.little), 16000);
    expect(w.length, 44 + 3200);
  });

  test('transcript cleanup', () {
    expect(cleanTurnTranscript('Speaker 1: Waan fiicnahay, mahadsanid.'), 'Waan fiicnahay, mahadsanid.');
    expect(cleanTurnTranscript('"Cali ii dir fariin"'), 'Cali ii dir fariin');
    expect(cleanTurnTranscript('  [silence] '), '');
    expect(cleanTurnTranscript(''), '');
  });

  test('voice guides teach the Somali C and X', () {
    expect(Somali.voiceGuide, contains('Never say C as J'));
    expect(Somali.voiceHint, contains('never J'));
    expect(Somali.liveTurnPrompt, contains('Output only the words'));
    expect(Somali.voiceGuide.length, lessThan(9500));
  });
}
