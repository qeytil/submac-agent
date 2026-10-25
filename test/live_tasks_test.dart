import 'package:flutter_test/flutter_test.dart';
import 'package:agent/app_state.dart';
import 'package:agent/services/live_controller.dart';
import 'package:agent/services/live_tasks.dart';
import 'package:agent/services/phone_tools.dart';
import 'package:agent/services/system_tools.dart';
import 'package:agent/services/whatsapp.dart';

void main() {
  group('task registry', () {
    test('ids, finish and status', () {
      final r = LiveTasks();
      final t0 = DateTime(2026, 10, 19, 17);
      expect(r.statusText(), contains('No background task'));
      final a = r.start('Book a table at Hiltop', 'c1', now: t0);
      final b = r.start('Research flights', 'c2', now: t0);
      expect(a.id, 'T1');
      expect(b.id, 'T2');
      expect(r.running.length, 2);
      expect(r.statusText(id: 't1', now: t0.add(const Duration(minutes: 3))), contains('still running (3 min'));
      final f = r.finish('c1', status: 'done', result: 'Booked for 8 pm');
      expect(f?.id, 'T1');
      expect(r.byId('T1')!.status, 'done');
      expect(r.statusText(id: 'T1'), contains('Booked for 8 pm'));
      expect(r.finish('nope', status: 'done'), isNull);
      expect(r.statusText(id: 'T9'), contains('no task T9'));
      expect(r.running.single.id, 'T2');
    });
    test('started this call', () {
      final r = LiveTasks();
      final call = DateTime(2026, 10, 19, 17);
      expect(r.anySince(call), isFalse);
      r.start('x', 'c', now: call.subtract(const Duration(hours: 1)));
      r.finish('c', status: 'done');
      expect(r.anySince(call), isFalse);
      r.start('y', 'd', now: call.add(const Duration(minutes: 1)));
      expect(r.anySince(call), isTrue);
    });
  });

  group('background-claim guard', () {
    test('catches fake background claims in several languages', () {
      for (final s in [
        "I'm doing it in the background and will report when it's done.",
        "Sure, I'll let you know when it's finished.",
        'I will keep you posted.',
        'Waan kuu soo sheegi doonaa marka uu dhammaado.',
        'سأخبرك عندما ينتهي',
      ]) {
        expect(LiveGuard.claimsBackground(s), isTrue, reason: s);
        expect(LiveGuard.correction(s, taskStarted: false), isNotNull, reason: s);
      }
    });
    test('leaves real progress and real tasks alone', () {
      for (final s in ['Opening WhatsApp.', 'Typing it now.', 'Sent.', 'Done, the alarm is set for 7.']) {
        expect(LiveGuard.claimsBackground(s), isFalse, reason: s);
      }
      expect(LiveGuard.correction("Started task T1, I'll let you know when it's done.", taskStarted: true), isNull);
    });
  });

  test('Live really has the phone tools', () {
    final phone = {
      for (final d in [...SystemTools.definitions(), ...PhoneTools.definitions, WhatsAppTools.definition]) '${(d['function'] as Map)['name']}'
    };
    for (final n in ['phone_screen', 'phone_tap', 'phone_type', 'phone_scroll', 'open_app', 'whatsapp', 'set_alarm']) {
      expect(phone, contains(n));
      expect(AppState.liveSkip(n), isFalse, reason: '$n must reach Live');
    }
    for (final n in ['phone_screen', 'phone_tap', 'open_app', 'whatsapp']) {
      expect(LiveController.screenTools, contains(n));
    }
    // The real task tool is declared first, and says it returns an id.
    final first = '${(AppState.liveTaskTools.first['function'] as Map)['description']}';
    expect(first, contains('task id'));
  });
}
