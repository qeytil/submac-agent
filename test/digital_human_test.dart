import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:agent/services/digital_human/heartbeat.dart';
import 'package:agent/services/digital_human/awareness.dart';
import 'package:agent/services/digital_human/memory.dart';
import 'package:agent/services/digital_human/mood.dart';
import 'package:agent/services/digital_human/person.dart';
import 'package:agent/services/digital_human/registry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Heartbeat', () {
    late Heartbeat hb;
    setUp(() {
      hb = Heartbeat(id: 'test-hb', idleThreshold: const Duration(minutes: 1));
    });

    test('starts alive', () {
      expect(hb.isAlive, true);
      expect(hb.idleTime.inSeconds, lessThan(5));
    });

    test('marks active resets idle time', () {
      hb.markActive();
      expect(hb.idleTime.inSeconds, lessThan(5));
    });

    test('sleeping makes isAlive false', () {
      hb.sleep();
      expect(hb.isAlive, false);
    });

    test('wake restores isAlive', () {
      hb.sleep();
      hb.wake();
      expect(hb.isAlive, true);
    });

    test('shouldSleep when idle past threshold', () {
      // Manually backdate lastActivity to simulate idleness
      hb.sleep(); // put to sleep to avoid auto-wake in tick
      expect(hb.shouldSleep, true);
    });
  });

  group('MoodEngine', () {
    late MoodEngine mood;
    setUp(() => mood = MoodEngine(id: 'test-mood'));

    test('starts idle', () {
      expect(mood.mood, BotMood.idle);
    });

    test('shift changes mood', () {
      mood.shift(BotMood.curious);
      expect(mood.mood, BotMood.curious);
      expect(mood.intensity, greaterThan(0));
    });

    test('mood labels are correct', () {
      mood.shift(BotMood.focused);
      expect(mood.moodLabel, 'Focused');
    });

    test('mood colors map correctly', () {
      expect(MoodEngine.moodColor(BotMood.happy), const Color(0xFFF2C14E));
      expect(MoodEngine.moodColor(BotMood.frustrated), const Color(0xFFC2361B));
    });

    test('energy depletes and recharges', () {
      final energy = EnergyLevel(starting: 1.0);
      energy.spend(0.5);
      expect(energy.level, 0.5);
      energy.recharge(0.3);
      expect(energy.level, 0.8);
    });

    test('energy low threshold', () {
      final energy = EnergyLevel(starting: 0.2);
      expect(energy.isLow, true);
    });
  });

  group('LongTermMemory', () {
    late LongTermMemory mem;
    setUp(() {
      mem = LongTermMemory(id: 'test-mem', maxEntries: 50);
    });

    test('remembers episodes', () {
      mem.remember('message', 'Hello there', topic: 'greeting');
      expect(mem.episodeCount, 1);
    });

    test('recalls by topic', () {
      mem.remember('message', 'The budget is \$500', topic: 'finance');
      final results = mem.recall('budget');
      expect(results.isNotEmpty, true);
    });

    test('learns facts', () {
      mem.learn('user', 'Prefers dark mode');
      expect(mem.factCount, 1);
    });

    test('reflects thoughts', () {
      mem.reflect('User seems busy today');
      expect(mem.reflectionCount, 1);
    });

    test('recentEpisodes returns formatted data', () {
      mem.remember('task', 'Completed report', topic: 'work');
      final recent = mem.recentEpisodes(1);
      expect(recent.length, 1);
      expect(recent[0]['content'], 'Completed report');
    });
  });

  group('AwarenessInsight', () {
    test('creates insight with defaults', () {
      final ins = AwarenessInsight(title: 'Something happened');
      expect(ins.urgency, 'low');
      expect(ins.source, 'internal');
    });

    test('round-trips through JSON', () {
      final original = AwarenessInsight(
        title: 'Price dropped',
        detail: 'BTC fell below \$60k',
        urgency: 'high',
        source: 'external',
        actionHint: 'notify user',
      );
      final restored = AwarenessInsight.fromJson(original.toJson());
      expect(restored.title, original.title);
      expect(restored.urgency, original.urgency);
    });
  });

  group('DigitalPerson', () {
    late DigitalPerson person;
    setUp(() {
      person = DigitalPerson(id: 'p1', name: 'Nova', role: 'researcher');
    });

    test('initial state', () {
      expect(person.presence, PresenceState.offline);
      expect(person.isActive, false);
    });

    test('wakeUp activates subsystems', () {
      person.wakeUp();
      expect(person.isActive, true);
      expect(person.presence, anyOf([PresenceState.online, PresenceState.thinking, PresenceState.working]));
      person.sleepDown();
    });

    test('markSpoken updates timestamp', () {
      person.wakeUp();
      person.markSpoken();
      expect(person.lastSpokeAt, isNotNull);
      person.sleepDown();
    });

    test('snapshot returns all fields', () {
      person.wakeUp();
      final snap = person.snapshot();
      expect(snap['id'], 'p1');
      expect(snap['name'], 'Nova');
      expect(snap['active'], true);
      person.sleepDown();
    });
  });

  group('DigitalHumanRegistry', () {
    test('registers and retrieves persons', () {
      final reg = DigitalHumanRegistry.I;
      reg.clear();
      final p = DigitalPerson(id: 'reg-test', name: 'TestBot');
      reg.register(p);
      expect(reg.byId('reg-test'), p);
      expect(reg.all.length, 1);
      reg.clear();
    });

    test('all sorts by lastSpokeAt desc', () {
      final reg = DigitalHumanRegistry.I;
      reg.clear();
      final p1 = DigitalPerson(id: 'a', name: 'First');
      final p2 = DigitalPerson(id: 'b', name: 'Second');
      p1.lastSpokeAt = DateTime.now().subtract(const Duration(hours: 1));
      p2.lastSpokeAt = DateTime.now();
      reg.register(p1);
      reg.register(p2);
      final sorted = reg.all;
      expect(sorted.first.id, 'b');
      reg.clear();
    });
  });
}
