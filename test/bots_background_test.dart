import 'dart:io';

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
      expect(ScheduledTask.fromJson(ScheduledTask('s2', 'x', DateTime(2026), 'none').toJson()).bot, '', reason: 'SubMac\'s own task');
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
}
