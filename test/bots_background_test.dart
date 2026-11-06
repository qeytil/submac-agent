import 'dart:io';

import 'package:agent/app_state.dart';
import 'package:agent/services/bot_manner.dart';
import 'package:agent/services/bot_sync.dart';
import 'package:agent/services/bots.dart';
import 'package:agent/services/system_tools.dart';
import 'package:flutter_test/flutter_test.dart';

/// Owner 2026-11-02: "the bots do not do the scheduled tasks and other background work, they just send me a message
/// about it and want me to say start. The bot should be a bot."
/// Seen in the account: a follow-up fired in the cloud, the cloud had no web, journaled "Waiting for the phone",
/// sent "I'm starting the SEO audit… I'll have the report ready", and nothing ran it until the owner asked "Finished?".
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('a job the cloud hands over is run by the phone, once', () {
    test('new handoffs are taken once; old ones are dropped', () {
      final now = DateTime.now().toUtc();
      final rs = {
        'handoff': {
          'f1': {'do': 'Audit submac.site and send a short brief', 'kind': 'message', 'needs': 'browser', 'at': now.toIso8601String()},
          'f0': {'do': 'old', 'kind': 'work', 'at': now.subtract(const Duration(days: 2)).toIso8601String()},
        },
      };
      final first = BotSync.I.takeHandoffs('bh_test_bot', rs);
      expect(first.map((e) => e.id), ['f1']);
      expect(first.single.instruction, contains('submac.site'));
      expect(first.single.kind, 'message');
      expect(BotSync.I.takeHandoffs('bh_test_bot', rs), isEmpty, reason: 'a second pull never runs it again');
    });
    test('no handoff, nothing to do', () {
      expect(BotSync.I.takeHandoffs('bh_test_bot2', {'done': {}}), isEmpty);
      expect(BotSync.I.takeHandoffs('bh_test_bot2', null), isEmpty);
    });
  });

  group('a bot\'s scheduled task belongs to the bot', () {
    test('the bot id survives saving', () {
      final t = ScheduledTask('s1', 'Check submac.site', DateTime(2026, 11, 2, 9), 'daily', bot: 'u17934');
      final back = ScheduledTask.fromJson(t.toJson());
      expect(back.bot, 'u17934');
      expect(ScheduledTask.fromJson(ScheduledTask('s2', 'x', DateTime(2026), 'none').toJson()).bot, '', reason: 'Telesia\'s own task');
    });
  });

  group('follow-ups at an exact time', () {
    test('bot_followup takes in_minutes and no longer requires "when"', () {
      final d = Bots.definitions.firstWhere((x) => (x['function'] as Map)['name'] == 'bot_followup')['function'] as Map;
      final p = d['parameters'] as Map;
      expect((p['properties'] as Map).containsKey('in_minutes'), isTrue);
      expect(p['required'], ['instruction']);
    });
  });

  group('the cloud runner does the work itself', () {
    final src = File('supabase/functions/bot-run/index.ts').readAsStringSync();
    test('it has the web', () {
      expect(src, contains('name: "web_search"'));
      expect(src, contains('name: "fetch_url"'));
    });
    test('it never sends "starting / will report later" messages', () {
      expect(src, contains('Never send a message that only says you are starting'));
    });
    test('a handed-over job is recorded for the phone and stays silent', () {
      expect(src, contains('state.handoff[id] ='));
      expect(src, contains('outcome: "handoff"'));
    });
  });

  test('the phone wake asks for the result, never for "start"', () {
    final src = File('lib/state/bots_controller.dart').readAsStringSync();
    expect(src, contains('never ask the user to say "start" or "go"'));
  });

  group('local or cloud: a job runs where its tools are (owner 2026-11-02)', () {
    final b = Bot(id: 'lc1', name: 'Rank', role: 'SEO', persona: '');
    test('building a page and emailing the link runs on the phone', () {
      expect(b.needsPhone('Build a landing page every hour and send the link to ali@example.com', 'work'), isTrue);
    });
    test('research and writing may run in the cloud', () {
      expect(b.needsPhone('Check the news about Somalia and summarise the top three stories', 'message'), isFalse);
    });
    test('the bot\'s own on_phone choice wins', () {
      expect(b.needsPhone('Check the prices', 'work', local: true), isTrue);
    });
    test('the choice is kept', () {
      final r = BotRoutine(id: 'r1', time: '09:00', instruction: 'x', local: true);
      expect(BotRoutine.fromJson(r.toJson()).local, isTrue);
      final f = BotFollowup('f1', DateTime(2026, 11, 2, 9), 'x', 'work', local: true);
      expect(BotFollowup.fromJson(f.toJson()).local, isTrue);
      expect(BotFollowup.fromJson(BotFollowup('f2', DateTime(2026), 'x', 'work').toJson()).local, isFalse);
    });
    test('routine and follow-up tools offer on_phone', () {
      for (final n in ['bot_routine', 'bot_followup']) {
        final d = Bots.definitions.firstWhere((x) => (x['function'] as Map)['name'] == n)['function'] as Map;
        expect(((d['parameters'] as Map)['properties'] as Map).containsKey('on_phone'), isTrue, reason: n);
      }
    });
    test('a phone-run job is never sent to the cloud', () {
      b.routines.add(BotRoutine(id: 'r9', time: '10:00', instruction: 'Publish the weekly page', local: false));
      expect(b.cloudFit, isFalse);
    });
  });

  group('time: later means later (owner 2026-11-02)', () {
    test('the prompt clock is exact to the minute, with weekday and zone', () {
      final l = AppState.nowLineFor(DateTime(2026, 11, 2, 12, 56));
      expect(l, contains('Monday 2026-11-02 12:56'));
      expect(l, contains('UTC'));
      expect(l, isNot(contains('rounded')));
    });
    test('a time already gone is refused with the real time', () {
      final e = Bots.pastTimeError('2026-11-02T12:30', DateTime(2026, 11, 2, 12, 56));
      expect(e, startsWith('Error:'));
      expect(e, contains('12:56'));
      expect(e, contains('in_minutes'));
    });
    test('every bot reads WHEN as well as what', () {
      expect(BotManner.block, contains('do not start the work now'));
      expect(BotManner.block, contains('in_minutes'));
    });
    test('schedule_task takes in_minutes and no longer requires when', () {
      final d = SystemTools.scheduleTools.first['function'] as Map;
      final params = d['parameters'] as Map;
      expect((params['properties'] as Map).containsKey('in_minutes'), isTrue);
      expect(params['required'], ['task']);
    });
  });
}
