import 'dart:math' as math;
import 'dart:typed_data';

import 'package:agent/services/live_audio.dart';
import 'package:flutter_test/flutter_test.dart';

/// A 16-bit sine wave chunk with RMS of about [rms] (0..1).
Uint8List tone(int ms, double rms, {int rate = 16000}) {
  final n = rate * ms ~/ 1000;
  final amp = rms * math.sqrt2 * 32767;
  final bd = ByteData(n * 2);
  for (var i = 0; i < n; i++) {
    bd.setInt16(i * 2, (amp * math.sin(2 * math.pi * 220 * i / rate)).round().clamp(-32768, 32767), Endian.little);
  }
  return bd.buffer.asUint8List();
}

bool isSilence(Uint8List b) => b.every((x) => x == 0);

void main() {
  final t0 = DateTime(2026, 10, 19, 20);

  group('PlaybackClock', () {
    test('a long answer that arrives fast keeps playing for its whole length', () {
      final c = PlaybackClock();
      // 46 s of speech arriving within 7 s (what Gemini Live really does).
      for (var i = 0; i < 46; i++) {
        c.feed(Uint8List(48000), t0.add(Duration(milliseconds: i * 150)));
      }
      expect(c.isPlaying(t0.add(const Duration(seconds: 10))), isTrue);
      expect(c.isPlaying(t0.add(const Duration(seconds: 45))), isTrue);
      expect(c.secondsLeft(t0.add(const Duration(seconds: 40))), closeTo(6, 0.01));
      // Past the end and the tail, but the player has not said its queue is empty: grace.
      expect(c.isPlaying(t0.add(const Duration(milliseconds: 46500))), isTrue);
      c.drained(t0.add(const Duration(milliseconds: 46100)));
      expect(c.isPlaying(t0.add(const Duration(milliseconds: 46700))), isFalse);
    });

    test('flush stops it at once', () {
      final c = PlaybackClock();
      c.feed(Uint8List(48000 * 10), t0);
      expect(c.isPlaying(t0.add(const Duration(seconds: 2))), isTrue);
      c.flush();
      expect(c.isPlaying(t0.add(const Duration(seconds: 2))), isFalse);
      expect(c.levelAt(t0.add(const Duration(seconds: 2))), 0);
    });

    test('a gap between chunks restarts from now', () {
      final c = PlaybackClock();
      c.feed(Uint8List(48000), t0); // 1 s
      c.feed(Uint8List(48000), t0.add(const Duration(seconds: 5)));
      expect(c.end, t0.add(const Duration(seconds: 6)));
    });

    test('knows how loud its own speech is at each moment', () {
      final c = PlaybackClock();
      c.feed(tone(1000, 0.3, rate: 24000), t0);
      c.feed(Uint8List(48000), t0); // then 1 s of silence
      expect(c.levelAt(t0.add(const Duration(milliseconds: 500))), closeTo(0.3, 0.03));
      expect(c.levelAt(t0.add(const Duration(milliseconds: 1800))), 0);
    });
  });

  group('EchoGate', () {
    test('passes everything while SubMac is silent', () {
      final g = EchoGate();
      final c = tone(40, 0.02);
      final r = g.process(c, pcmRms(c), playing: false);
      expect(r.send, [c]);
    });

    test('muted sends silence', () {
      final g = EchoGate();
      final c = tone(40, 0.5);
      final r = g.process(c, pcmRms(c), playing: false, muted: true);
      expect(r.send.length, 1);
      expect(isSilence(r.send.single), isTrue);
    });

    test('echo of its own voice never reaches the server during a long answer', () {
      final g = EchoGate();
      final rnd = math.Random(1);
      // 40 s of speaker echo: the mic hears about 40% of what plays, speech-like level changes.
      for (var i = 0; i < 1000; i++) {
        final speaker = 0.05 + rnd.nextDouble() * 0.35;
        final c = tone(40, speaker * 0.4);
        final r = g.process(c, pcmRms(c), playing: true, speakerLevel: speaker);
        expect(r.send.length, 1, reason: 'chunk $i');
        expect(isSilence(r.send.single), isTrue, reason: 'chunk $i');
      }
      expect(g.bargeIn, isFalse);
    });

    test('a strong echo (no echo canceller) is learnt and still ignored', () {
      final g = EchoGate();
      for (var i = 0; i < 500; i++) {
        final c = tone(40, 0.45); // the mic hears 1.5x what plays
        final r = g.process(c, pcmRms(c), playing: true, speakerLevel: 0.3);
        expect(isSilence(r.send.single), isTrue, reason: 'chunk $i');
      }
    });

    test('the user talking over SubMac opens it, with the first words kept', () {
      final g = EchoGate();
      for (var i = 0; i < 50; i++) {
        final c = tone(40, 0.04);
        g.process(c, pcmRms(c), playing: true, speakerLevel: 0.15);
      }
      List<Uint8List> sent = [];
      var opened = -1;
      for (var i = 0; i < 20; i++) {
        final c = tone(40, 0.35);
        final r = g.process(c, pcmRms(c), playing: true, speakerLevel: 0.15);
        if (r.send.any((b) => !isSilence(b))) {
          opened = i;
          sent = r.send;
          break;
        }
      }
      expect(opened, inInclusiveRange(6, 9)); // about 300 ms of voice
      expect(g.bargeIn, isTrue);
      // The pre-roll carries the voice that came before the decision (about half a second).
      expect(sent.length, greaterThanOrEqualTo(8));
      // Then the mic goes straight through.
      final c = tone(40, 0.3);
      expect(g.process(c, pcmRms(c), playing: true, speakerLevel: 0.15).send, [c]);
    });

    test('with a strong echo the user still gets through, in SubMac\'s pauses or by speaking up', () {
      final g = EchoGate();
      for (var i = 0; i < 100; i++) {
        final c = tone(40, 0.3); // echo at the speaker's own level
        g.process(c, pcmRms(c), playing: true, speakerLevel: 0.3);
      }
      expect(g.bargeIn, isFalse);
      var opened = false;
      for (var i = 0; i < 15 && !opened; i++) {
        final c = tone(40, 0.25); // normal voice while SubMac pauses between sentences
        opened = g.process(c, pcmRms(c), playing: true, speakerLevel: 0.0).send.any((b) => !isSilence(b));
      }
      expect(opened, isTrue);
      final g2 = EchoGate();
      for (var i = 0; i < 100; i++) {
        final c = tone(40, 0.1);
        g2.process(c, pcmRms(c), playing: true, speakerLevel: 0.3);
      }
      opened = false;
      for (var i = 0; i < 15 && !opened; i++) {
        final c = tone(40, 0.35); // speaking up over SubMac
        opened = g2.process(c, pcmRms(c), playing: true, speakerLevel: 0.3).send.any((b) => !isSilence(b));
      }
      expect(opened, isTrue);
    });

    test('a single click or cough does not interrupt', () {
      final g = EchoGate();
      for (var i = 0; i < 30; i++) {
        final loud = i % 10 == 0; // 40 ms bangs every 400 ms
        final c = tone(40, loud ? 0.6 : 0.03);
        final r = g.process(c, pcmRms(c), playing: true, speakerLevel: 0.1);
        expect(isSilence(r.send.single), isTrue, reason: 'chunk $i');
      }
    });

    test('closes again after a false start, and resets when SubMac stops', () {
      final g = EchoGate(releaseMs: 400);
      for (var i = 0; i < 40; i++) {
        final c = tone(40, 0.01);
        g.process(c, pcmRms(c), playing: true, speakerLevel: 0.05);
      }
      for (var i = 0; i < 10; i++) {
        final c = tone(40, 0.4);
        g.process(c, pcmRms(c), playing: true, speakerLevel: 0.05);
      }
      expect(g.bargeIn, isTrue);
      for (var i = 0; i < 11; i++) {
        final c = tone(40, 0.01);
        g.process(c, pcmRms(c), playing: true, speakerLevel: 0.05);
      }
      expect(g.bargeIn, isFalse);
      final c = tone(40, 0.01);
      expect(g.process(c, pcmRms(c), playing: false).send, [c]);
    });
  });

  group('timing rules', () {
    test('parses Gemini durations', () {
      expect(parseLiveDuration('12s'), const Duration(seconds: 12));
      expect(parseLiveDuration('1.5s'), const Duration(milliseconds: 1500));
      expect(parseLiveDuration('500ms'), const Duration(milliseconds: 500));
      expect(parseLiveDuration(3), const Duration(seconds: 3));
      expect(parseLiveDuration('soon'), isNull);
      expect(parseLiveDuration(null), isNull);
    });

    test('goAway waits for the answer to arrive, but not past the deadline', () {
      final by = t0.add(const Duration(seconds: 20));
      expect(goAwayMoveNow(now: t0, deadline: by, generating: true, toolRunning: false), isFalse);
      expect(goAwayMoveNow(now: t0, deadline: by, generating: false, toolRunning: true), isFalse);
      expect(goAwayMoveNow(now: t0, deadline: by, generating: false, toolRunning: false), isTrue);
      expect(goAwayMoveNow(now: by, deadline: by, generating: true, toolRunning: true), isTrue);
    });

    test('app notes wait until SubMac has finished speaking', () {
      expect(injectMayGo(speaking: true, generating: false, toolRunning: false, waited: Duration.zero), isFalse);
      expect(injectMayGo(speaking: false, generating: true, toolRunning: false, waited: Duration.zero), isFalse);
      expect(injectMayGo(speaking: false, generating: false, toolRunning: true, waited: Duration.zero), isFalse);
      expect(injectMayGo(speaking: false, generating: false, toolRunning: false, waited: Duration.zero), isTrue);
      expect(injectMayGo(speaking: true, generating: true, toolRunning: true, waited: const Duration(seconds: 60)), isTrue);
    });

    test('voice detection settings are well formed', () {
      final a = liveRealtimeInputConfig['automaticActivityDetection'] as Map;
      expect(a['prefixPaddingMs'], isA<int>());
      expect(a['silenceDurationMs'], isA<int>());
      expect(liveRealtimeInputConfig['activityHandling'], 'START_OF_ACTIVITY_INTERRUPTS');
    });
  });
}
