// Chat bug hunt ROUND 4, BOTS part (2026-10-25). Host PROBE tests, written because the emulator job could not start
// (GitHub Actions: "recent account payments have failed or your spending limit needs to be increased").
// Each test asserts the CORRECT behaviour, so it is RED while its bug is there. Investigation only, do not merge.
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
import 'package:agent/services/bots.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final alarms = <String>[];
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('submac/system'), (c) async {
      if (c.method == 'scheduleAlarm' || c.method == 'cancelAlarm') alarms.add('${c.method} ${c.arguments}');
      return null;
    });
    await Bots.I.init();
    Bots.I.bots.removeWhere((b) => b.id.startsWith('cb4'));
  });

  Bot bot() {
    final b = Bot(id: 'cb4ledger', name: 'Ledger', role: 'Bookkeeper', persona: '')
      ..active = true
      ..convId = 'conv-cb4';
    b.routines.add(BotRoutine(id: 'rq', time: '09:00', days: 'daily', kind: 'message', instruction: 'Send me one bookkeeping tip.'));
    Bots.I.bots.add(b);
    return b;
  }

  test('CB-35: the same routine alarm delivered twice wakes the bot once', () async {
    final b = bot();
    var wakes = 0;
    Bots.I.onWake = (bot, reason, instruction, kind) async {
      wakes++;
      await Future<void>.delayed(const Duration(milliseconds: 30));
    };
    final r = await Future.wait([Bots.I.fire(Bots.alarmId(b, 'rq')), Bots.I.fire(Bots.alarmId(b, 'rq'))]);
    final late = await Bots.I.fire(Bots.alarmId(b, 'rq'));
    expect(wakes, 1, reason: 'fire() results=$r then a late redelivery=$late: the routine woke the bot $wakes times for one 09:00 slot');
  });

  test('CB-21: a routine whose minute passed while SubMac was stopped is caught up when the app starts', () async {
    final b = bot();
    b.routines.first.time = '08:30';
    final start = DateTime(2026, 10, 25, 8, 40);
    final next = b.routines.first.next(start)!;
    expect(next.difference(start).inMinutes, lessThan(60), reason: 'armed for $next: the missed 08:30 run is skipped until tomorrow, with no note');
  });
}
