// Per-bot runtime (owner 2026-11-08): each digital person runs on its own rhythm, so a crowd of them never wake in the
// same minute and an idle one costs no model call. Pure logic; nothing Android.
//
// Run: flutter test test/bot_runtime_test.dart
// ignore_for_file: depend_on_referenced_packages
import 'package:agent/services/bot_runtime.dart';
import 'package:agent/services/bots.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => RuntimeHost.I.clear());
  tearDown(() => RuntimeHost.I.clear());

  Bot bot(String id) => Bot(id: id, name: 'B', role: 'R', persona: '')..active = true;

  group('jitter', () {
    test('is stable for the same person and inside the window', () {
      final w = const Duration(hours: 6);
      final a = RuntimeHost.jitter('nova-1', w);
      final b = RuntimeHost.jitter('nova-1', w);
      expect(a, b, reason: 'the same person keeps the same offset');
      expect(a.inMinutes, greaterThanOrEqualTo(0));
      expect(a.inMinutes, lessThan(6 * 60 ~/ 4));
    });

    test('staggers a crowd: different people land on different minutes', () {
      final w = const Duration(hours: 6);
      final offsets = {for (var i = 0; i < 40; i++) RuntimeHost.jitter('bot-$i', w).inMinutes};
      // Not everyone on the same minute (the old thundering herd), and not one per minute either in practice.
      expect(offsets.length, greaterThan(3));
    });

    test('is zero when the window is too small to spread', () {
      expect(RuntimeHost.jitter('nova-1', const Duration(minutes: 3)), Duration.zero);
    });
  });

  group('runtime host', () {
    test('one runtime per person, kept by id', () {
      final r = RuntimeHost.I.of('nova-1');
      expect(identical(r, RuntimeHost.I.of('nova-1')), isTrue);
      expect(r.botId, 'nova-1');
      expect(r.phase, BotPhase.idle);
      RuntimeHost.I.forget('nova-1');
      expect(identical(r, RuntimeHost.I.of('nova-1')), isFalse);
    });

    test('presence reads the person\'s own phase', () {
      final b = bot('nova-2');
      expect(Bots.I.presenceOf(b), 'free');
      RuntimeHost.I.of(b.id).phase = BotPhase.thinking;
      expect(Bots.I.presenceOf(b), 'thinking');
      RuntimeHost.I.of(b.id).phase = BotPhase.waiting;
      expect(Bots.I.presenceOf(b), 'waiting');
      RuntimeHost.I.of(b.id).phase = BotPhase.idle;
      expect(Bots.I.presenceOf(b), 'free');
      b.active = false;
      expect(Bots.I.presenceOf(b), 'off');
    });

    test('a desk item left for the owner reads as waiting', () {
      final b = bot('nova-7');
      b.desk.add(DeskTask('d7', 'ask the owner which supplier', status: 'waiting'));
      expect(Bots.I.presenceOf(b), 'waiting');
    });
  });

  group('check-in gate', () {
    test('an idle person\'s check-in is empty: no open work, no promise', () {
      final b = bot('nova-3');
      expect(b.checkInEmpty, isTrue);
      expect(Bots.I.checkInEmpty(b), isTrue);
    });

    test('open work or a promised follow-up keeps the check-in worth doing', () {
      final b = bot('nova-4');
      b.desk.add(DeskTask('d1', 'research suppliers', status: 'todo'));
      expect(b.checkInEmpty, isFalse);
      expect(Bots.I.checkInEmpty(b), isFalse);

      final c = bot('nova-5');
      c.followups.add(BotFollowup('f1', DateTime.now().add(const Duration(hours: 2)), 'ask for the quote', 'message'));
      expect(Bots.I.checkInEmpty(c), isFalse);
    });
  });
}
