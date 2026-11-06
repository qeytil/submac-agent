// Owner bug report 2026-11-06 (fix/oc-tools): (A) bots save "responsibilities" without end, (B) opencode tool calls
// fail, (C) bots do not use the owner's connected apps. Built from the real run of 2026-11-05 (Weriye, "send me news
// every hour in Telegram"): 133 bot_routine calls and 25 routines for one ask, a cron argument read as "list",
// parallel adds that crashed ("Concurrent modification during iteration"), bot_telegram called with "message",
// run_tool name "webfetch", and every call to the connected Telegram bot answering 404 (url ignored, token doubled).
//
// Run: flutter test test/oc_tools_test.dart
// ignore_for_file: invalid_use_of_visible_for_testing_member, depend_on_referenced_packages
import 'dart:convert';

import 'package:agent/app_state.dart';
import 'package:agent/services/bots.dart';
import 'package:agent/services/connector_catalog.dart';
import 'package:agent/services/oc_scope.dart';
import 'package:agent/services/opencode.dart';
import 'package:agent/services/save_guard.dart';
import 'package:agent/services/submac_gateway.dart';
import 'package:agent/services/system_bridge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _news = 'Fetch the latest Somalia and world news and send me a short brief on Telegram.';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('A · SaveGuard: the same save twice, and a save loop, are stopped', () {
    test('an identical save is answered with the first result, never saved twice', () {
      final g = SaveGuard();
      final a = {'fact': 'Prefers Somali'};
      expect(g.before('c1', 'bot_remember', a), isNull);
      g.after('c1', 'bot_remember', a, 'Remembered.');
      final again = g.before('c1', 'bot_remember', {'fact': 'Prefers Somali'});
      expect(again, startsWith('Already done'));
      expect(again, contains('Do not repeat'));
      expect(g.before('c2', 'bot_remember', a), isNull, reason: 'another chat is another scope');
    });

    test('more saves of one kind than its cap in one turn are refused with a stop line', () {
      final g = SaveGuard();
      for (var i = 0; i < SaveGuard.caps['bot_routine']!; i++) {
        final a = {'action': 'add', 'time': '${i.toString().padLeft(2, '0')}:00', 'instruction': 'job $i'};
        expect(g.before('c', 'bot_routine', a), isNull);
        g.after('c', 'bot_routine', a, 'Routine r$i.');
      }
      final r = g.before('c', 'bot_routine', {'action': 'add', 'time': '23:00', 'instruction': 'one more'});
      expect(r, startsWith('Error: not saved'));
      expect(r, contains('repeat'));
      g.newTurn('c');
      expect(g.before('c', 'bot_routine', {'action': 'add', 'time': '23:00', 'instruction': 'one more'}), isNull,
          reason: 'a new turn starts the count again');
    });

    test('removing, listing and errors never count', () {
      final g = SaveGuard();
      for (var i = 0; i < 40; i++) {
        final a = {'action': 'remove', 'id': 'r$i'};
        expect(g.before('c', 'bot_routine', a), isNull);
        g.after('c', 'bot_routine', a, 'Removed.');
      }
      final bad = {'action': 'add', 'instruction': 'x'};
      g.after('c', 'bot_routine', bad, 'Error: give time');
      expect(g.before('c', 'bot_routine', bad), isNull, reason: 'a failed call may be fixed and tried again');
      expect(SaveGuard.isSave('bot_remember', {'forget': 'x'}), isFalse);
      expect(SaveGuard.isSave('bot_routine', {'cron': '0 * * * *'}), isTrue);
      expect(SaveGuard.isSave('bot_desk', {'action': 'update'}), isFalse);
    });

    test('the window ends a save loop that never marks a turn', () {
      var now = DateTime(2026, 11, 6, 9);
      final g = SaveGuard(clock: () => now);
      final a = {'fact': 'x'};
      g.after('c', 'bot_remember', a, 'Remembered.');
      expect(g.before('c', 'bot_remember', a), isNotNull);
      now = now.add(const Duration(minutes: 11));
      expect(g.before('c', 'bot_remember', a), isNull);
    });
  });

  group('A · bot_routine: "every hour" is one job, never 24 routines', () {
    late Bot b;
    late List<(String, String)> scheduled;
    late List<({String id, String task, String repeat})> repeats;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      SystemBridge.debugCalls = (m, a) {};
      SaveGuard.I.clear();
      await Bots.I.init();
      b = Bot(id: 'w1', name: 'Weriye', role: 'News Reporter', persona: '')
        ..active = true
        ..convId = 'conv-w1';
      Bots.I.bots.add(b);
      scheduled = [];
      repeats = [];
      Bots.I.scheduleRepeat = (bot, job, repeat) async {
        scheduled.add((job, repeat));
        repeats.add((id: 's${repeats.length + 1}', task: job, repeat: repeat));
        return 'Scheduled (s${repeats.length}): "$job", repeating $repeat.';
      };
      Bots.I.repeatsOf = (bot) => bot.id == b.id ? repeats : const [];
      Bots.I.cancelRepeat = (bot, id) async {
        repeats.removeWhere((t) => t.id == id);
        return 'Removed.';
      };
    });
    tearDown(() {
      Bots.I.bots.remove(b);
      Bots.I.scheduleRepeat = null;
      Bots.I.repeatsOf = null;
      Bots.I.cancelRepeat = null;
      SystemBridge.debugCalls = null;
      SaveGuard.I.clear();
    });

    test('repeat hourly makes one repeating task; asking again adds nothing', () async {
      final r = await Bots.I.execute('bot_routine', {'action': 'add', 'repeat': 'hourly', 'instruction': _news}, b.convId);
      expect(r, contains('Scheduled'));
      expect(r, contains('do not add routines for each hour'));
      expect(scheduled, [(_news, 'hourly')]);
      expect(b.routines, isEmpty);
      final again = await Bots.I.execute('bot_routine', {'repeat': 'hourly', 'instruction': '$_news '}, b.convId);
      expect(again, startsWith('Already'));
      expect(scheduled, hasLength(1));
      final list = await Bots.I.execute('bot_routine', {'action': 'list'}, b.convId);
      expect(list, contains('s1: every hour'));
    });

    test('a cron line with no action (2026-11-05: answered "No routines.") is an hourly add', () async {
      final r = await Bots.I.execute('bot_routine', {'cron': '0 * * * *', 'instruction': _news}, b.convId);
      expect(r, contains('Scheduled'));
      expect(scheduled.single.$2, 'hourly');
      expect(Bots.repeatOf({'cron': '0 */3 * * *'}), 'every_3_hours');
      expect(Bots.repeatOf({'every_hours': 6}), 'every_6_hours');
      expect(Bots.repeatOf({'repeat': 'every hour'}), 'hourly');
      expect(Bots.repeatOf({'repeat': 'daily'}), '');
      expect(Bots.repeatOf({'every_hours': 5}), 'bad');
    });

    test('the Weriye loop: one add per hour stops after a few, with a line that says how to do it', () async {
      final answers = <String>[];
      for (var h = 0; h < 24; h++) {
        answers.add(await Bots.I.execute('bot_routine',
            {'action': 'add', 'days': 'daily', 'time': '${h.toString().padLeft(2, '0')}:00', 'instruction': _news}, b.convId));
      }
      expect(b.routines.length, 4, reason: 'one job at many times of day is refused after the fourth');
      expect(answers[4], startsWith('Error: not added'));
      expect(answers[4], contains('repeat'));
      expect(answers.where((a) => a.startsWith('Routine')).length, 4);
    });

    test('every_hours 6 makes the four times in one call; a second call adds nothing', () async {
      final r = await Bots.I.execute('bot_routine', {'action': 'add', 'every_hours': 6, 'time': '07:30', 'instruction': _news}, b.convId);
      expect(r, contains('every 6 hours'));
      expect(b.routines.map((r) => r.time).toList(), ['01:30', '07:30', '13:30', '19:30']);
      SaveGuard.I.clear();
      final again = await Bots.I.execute('bot_routine', {'action': 'add', 'every_hours': 6, 'time': '07:30', 'instruction': _news}, b.convId);
      expect(again, startsWith('Already set'));
      expect(b.routines, hasLength(4));
    });

    test('the same routine twice is "Already set", not a second routine', () async {
      await Bots.I.execute('bot_routine', {'action': 'add', 'time': '8:00', 'instruction': 'Morning brief'}, b.convId);
      SaveGuard.I.clear();
      final r = await Bots.I.execute('bot_routine', {'action': 'add', 'time': '08:00', 'instruction': 'morning brief.'}, b.convId);
      expect(r, startsWith('Already set'));
      expect(b.routines, hasLength(1));
      expect(b.routines.single.time, '08:00');
    });

    test('parallel adds (opencode runs tool calls side by side) never crash on the routine list', () async {
      final rs = await Future.wait([
        for (var i = 0; i < 4; i++) Bots.I.execute('bot_routine', {'action': 'add', 'time': '0$i:15', 'instruction': 'Job number $i'}, b.convId),
      ]);
      expect(rs.where((r) => r.contains('Concurrent modification')), isEmpty);
      expect(rs.every((r) => r.startsWith('Routine')), isTrue, reason: '$rs');
      expect(b.routines, hasLength(4));
    });

    test('removing works for routines and for the repeating task', () async {
      await Bots.I.execute('bot_routine', {'repeat': 'hourly', 'instruction': _news}, b.convId);
      expect(await Bots.I.execute('bot_routine', {'action': 'remove', 'id': 's1'}, b.convId), 'Removed.');
      expect(repeats, isEmpty);
      expect(await Bots.I.execute('bot_routine', {'action': 'remove', 'id': 'nope'}, b.convId), startsWith('Error: no routine'));
    });

    test('routines that are one job at every hour show as one line "every hour"', () {
      final rs = [for (var h = 0; h < 24; h++) BotRoutine(id: 'r$h', time: '${h.toString().padLeft(2, '0')}:00', instruction: _news)];
      rs.add(BotRoutine(id: 'x', time: '12:00', instruction: 'Lunch reminder'));
      final g = Bots.routineGroups(rs);
      expect(g, hasLength(2));
      expect(g.first.when, 'every hour');
      expect(g.first.ids, hasLength(24));
      expect(g.last.when, '12:00 daily');
      final three = Bots.routineGroups([
        BotRoutine(id: 'a', time: '00:00', instruction: 'x'),
        BotRoutine(id: 'b', time: '08:00', instruction: 'x'),
        BotRoutine(id: 'c', time: '16:00', instruction: 'x'),
      ]);
      expect(three.single.when, 'every 8 hours');
      final odd = Bots.routineGroups([BotRoutine(id: 'a', time: '09:00', instruction: 'x'), BotRoutine(id: 'b', time: '18:00', instruction: 'x')]);
      expect(odd.single.when, '09:00, 18:00 daily');
    });

    test("the bot's prompt lists the job once, as already set", () {
      for (var h = 0; h < 24; h++) {
        b.routines.add(BotRoutine(id: 'r$h', time: '${h.toString().padLeft(2, '0')}:00', instruction: _news));
      }
      final p = Bots.I.livePromptOf(b);
      expect(p, contains('never add them again'));
      expect(p, contains('every hour'));
      expect(RegExp(RegExp.escape(_news)).allMatches(p).length, 1);
    });

    test('bot_remember: a token is never saved; the same fact twice is one line', () async {
      final r = await Bots.I.execute(
          'bot_remember', {'fact': 'Telegram bot token: 8762508852:AAEN4wOgMHOQ2jnkBJC2Orcny74eYJ0Qs3I (my bot)'}, b.convId);
      expect(r, startsWith('Error: not saved'));
      expect(b.memory, isEmpty);
      expect(await Bots.I.execute('bot_remember', {'fact': 'Prefers news in Somali.'}, b.convId), 'Remembered.');
      SaveGuard.I.clear();
      expect(await Bots.I.execute('bot_remember', {'fact': 'prefers news in Somali'}, b.convId), 'Already remembered.');
      expect(b.memory, hasLength(1));
      expect(await Bots.I.execute('bot_remember', {'list': true}, b.convId), contains('Prefers news in Somali.'));
    });

    test("the brief says 'every hour' is one routine with repeat", () {
      final p = Bots.I.stablePromptOf(b);
      expect(p, contains('"every hour" is ONE bot_routine with repeat "hourly"'));
      final def = Bots.definitions.firstWhere((d) => (d['function'] as Map)['name'] == 'bot_routine');
      final props = ((def['function'] as Map)['parameters'] as Map)['properties'] as Map;
      expect(props.keys, containsAll(['repeat', 'every_hours', 'time']));
    });
  });

  group("A · a bot's remember never writes the owner's memory", () {
    test('remember / forget / list_memories become the bot\'s own bot_remember', () {
      void same(String n, Map<String, dynamic> a, Map<String, dynamic> want) {
        final r = OcToolScope.botMemory(n, a)!;
        expect(r.$1, 'bot_remember');
        expect(r.$2, want);
      }

      same('remember', {'fact': 'Likes tea'}, {'fact': 'Likes tea'});
      same('forget', {'match': 'tea'}, {'forget': 'tea'});
      same('list_memories', {}, {'list': true});
      expect(OcToolScope.botMemory('web_search', {}), isNull);
    });

    test("a bot's tool list has no owner memory tools; the owner's chat keeps them", () {
      Map<String, dynamic> fn(String n) => {'type': 'function', 'function': {'name': n, 'description': n, 'parameters': {'type': 'object'}}};
      final app = [fn('remember'), fn('forget'), fn('list_memories'), fn('web_search')];
      final bot = OcToolScope.of(app: app, botOwn: [fn('bot_remember')], allowed: (_) => true, exclude: OcToolScope.ownerMemory);
      expect(bot.map(OcToolScope.nameOf), ['bot_remember', 'web_search']);
      final owner = OcToolScope.of(app: app);
      expect(owner.map(OcToolScope.nameOf), containsAll(['remember', 'forget', 'list_memories']));
    });

    test('through the gateway, a bot calling remember runs it (as its own memory), not "no tool"', () async {
      final ran = <String>[];
      final g = SubMacGateway(
        tools: () => [
          {'type': 'function', 'function': {'name': 'bot_remember', 'description': 'x', 'parameters': {'type': 'object'}}}
        ],
        run: (n, a) async {
          ran.add(n);
          return 'Remembered.';
        },
        redirect: (n) => OcToolScope.botMemory(n, const {})?.$1,
      );
      expect(await g.call('run_tool', {'name': 'remember', 'arguments': {'fact': 'x'}}), 'Remembered.');
      expect(ran, ['remember'], reason: 'the app maps the name to the bot memory when it runs');
    });
  });

  group('B · opencode tool calls', () {
    test("run_tool with one of opencode's own tools says to call it directly", () async {
      final g = SubMacGateway(tools: () => const [], run: (n, a) async => 'ran');
      final r = await g.call('run_tool', {'name': 'webfetch', 'arguments': {'url': 'https://example.com'}});
      expect(r, contains('one of your own tools'));
      expect(r, contains('Call webfetch directly'));
    });

    test('bot_telegram takes "message" as the text (2026-11-05: "give the text to send")', () async {
      SharedPreferences.setMockInitialValues({});
      await Bots.I.init();
      final b = Bot(id: 'tg', name: 'Nova', role: 'News', persona: '')
        ..active = true
        ..convId = 'conv-tg';
      Bots.I.bots.add(b);
      addTearDown(() {
        Bots.I.bots.remove(b);
        Bots.telegramSend = null;
      });
      final sent = <String>[];
      Bots.telegramSend = (t, f) async {
        sent.add(t);
        return null;
      };
      expect(await Bots.I.execute('bot_telegram', {'message': 'News brief'}, b.convId), 'Sent to the owner on Telegram.');
      expect(sent, ['News brief']);
    });

    test('Autopilot allows a step once, but never a repeating step (doom_loop)', () async {
      final replies = <String, String>{};
      final asks = OpenCodeAsks(
        ask: (c, t, p, o) async => 'Allow',
        permit: (id, r) async => replies[id] = r,
        answer: (id, a) async {},
        convOf: (_) => 'conv',
        autopilot: () => true,
      );
      await asks.handle({
        'type': 'permission.asked',
        'properties': {'id': 'p1', 'sessionID': 's', 'permission': 'doom_loop', 'patterns': ['bot_routine']},
      });
      await asks.handle({
        'type': 'permission.asked',
        'properties': {'id': 'p2', 'sessionID': 's', 'permission': 'bash', 'patterns': ['ls']},
      });
      expect(replies, {'p1': 'reject', 'p2': 'once'});
    });
  });

  group('C · connected apps for bots', () {
    setUp(() {
      ConnectorCatalog.connected['telegram'] = {'token': '123456:ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghi'};
      ConnectorCatalog.telegramChat = '';
    });
    tearDown(() {
      ConnectorCatalog.connected.remove('telegram');
      ConnectorCatalog.httpClient = http.Client.new;
      ConnectorCatalog.telegramChat = '';
    });

    test("an app call's path loses the base's own path when the model repeats it (the doubled token: 404)", () {
      const tg = 'https://api.telegram.org/bot{token}';
      expect(ConnectorCatalog.normPath(tg, '/bot8762508852:AAEN4wOg/sendMessage'), '/sendMessage');
      expect(ConnectorCatalog.normPath(tg, 'bot{token}/getMe'), '/getMe');
      expect(ConnectorCatalog.normPath(tg, 'sendMessage'), '/sendMessage');
      expect(ConnectorCatalog.normPath(tg, '/botany/plants'), '/botany/plants', reason: 'only a whole segment is the base');
      expect(ConnectorCatalog.normPath(tg, 'https://api.telegram.org/botX/getMe'), 'https://api.telegram.org/botX/getMe');
      expect(ConnectorCatalog.normPath('https://api.github.com', '/user'), '/user');
      expect(ConnectorCatalog.normPath('https://{domain}.freshdesk.com/api/v2', '/api/v2/tickets'), '/tickets');
    });

    test('an app call with no path is refused (it went to the bare base and answered 404)', () async {
      final r = await ConnectorCatalog.execute('app_telegram', {'method': 'POST', 'body': {'chat_id': 1, 'text': 'hi'}});
      expect(r, startsWith('Error: give "path"'));
      expect(r, contains('Nothing was sent'));
      expect(r, isNot(contains('ABCDEFGHIJ')), reason: 'the token is never shown');
    });

    test('"url" is read as the path and a doubled token is fixed: the request goes to /bot<token>/sendMessage', () async {
      final seen = <http.BaseRequest>[];
      ConnectorCatalog.httpClient = () => MockClient((r) async {
            seen.add(r);
            return http.Response('{"ok":true}', 200);
          });
      final r = await ConnectorCatalog.execute('app_telegram', {
        'method': 'POST',
        'url': '/bot8762508852:AAEN4wOgMHOQ2jnkBJC2Orcny74eYJ0Qs3I/sendMessage',
        'body': {'chat_id': 1, 'text': 'hi'},
      });
      expect(r, startsWith('HTTP 200'));
      expect(seen.single.url.toString(), 'https://api.telegram.org/bot123456:ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghi/sendMessage');
    });

    test("the owner's chat is the newest private chat that wrote to the bot", () {
      final j = {
        'ok': true,
        'result': [
          {'update_id': 1, 'message': {'chat': {'id': 111, 'type': 'private'}, 'text': '/start'}},
          {'update_id': 2, 'message': {'chat': {'id': -500, 'type': 'group'}, 'text': 'hi all'}},
          {'update_id': 3, 'my_chat_member': {'chat': {'id': 8367489844, 'type': 'private'}}},
        ],
      };
      expect(ConnectorCatalog.chatIdFromUpdates(j), '8367489844');
      expect(ConnectorCatalog.chatIdFromUpdates({'ok': true, 'result': []}), '');
    });

    test("bot_telegram sends through the owner's connected Telegram bot when SubMac's own Telegram is off", () async {
      final calls = <http.Request>[];
      ConnectorCatalog.httpClient = () => MockClient((r) async {
            calls.add(r);
            if (r.url.path.endsWith('/getUpdates')) {
              return http.Response(jsonEncode({
                'ok': true,
                'result': [
                  {'update_id': 9, 'message': {'chat': {'id': 8367489844, 'type': 'private'}, 'text': '/start'}}
                ]
              }), 200);
            }
            return http.Response('{"ok":true}', 200);
          });
      SharedPreferences.setMockInitialValues({});
      await Bots.I.init();
      final b = Bot(id: 'tg2', name: 'Weriye', role: 'News', persona: '')
        ..active = true
        ..convId = 'conv-tg2';
      Bots.I.bots.add(b);
      addTearDown(() => Bots.I.bots.remove(b));
      final r = await Bots.I.execute('bot_telegram', {'text': 'News brief'}, b.convId);
      expect(r, 'Sent to the owner on Telegram.');
      expect(calls.map((c) => c.url.path.split('/').last), ['getUpdates', 'sendMessage']);
      expect(calls.first.url.path, '/bot123456:ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghi/getUpdates');
      expect(jsonDecode(calls.last.body), {'chat_id': '8367489844', 'text': 'News brief'});
      // The chat is kept: the next send goes straight out.
      calls.clear();
      SaveGuard.I.clear();
      expect(await Bots.I.execute('bot_telegram', {'text': 'Second'}, b.convId), 'Sent to the owner on Telegram.');
      expect(calls.map((c) => c.url.path.split('/').last), ['sendMessage']);
    });

    test('no chat with the bot yet: says to press Start', () async {
      ConnectorCatalog.httpClient = () => MockClient((r) async => http.Response('{"ok":true,"result":[]}', 200));
      expect(await ConnectorCatalog.telegramToOwner('hi'), contains('press Start'));
    });

    test("a bot's brief names the owner's connected apps it may use (and a scoped bot only its own)", () {
      SharedPreferences.setMockInitialValues({});
      final s = AppState();
      final free = Bot(id: 'f', name: 'Nova', role: 'x', persona: '');
      final lines = s.botConnectedApps(free);
      expect(lines.join('\n'), contains('app_telegram'));
      expect(lines.join('\n'), contains('bot_telegram also sends'));
      final scoped = Bot(id: 's', name: 'Lexi', role: 'x', persona: '')..appsScoped = true;
      expect(s.botConnectedApps(scoped), isEmpty, reason: 'Telegram is not one of its apps');
      Bots.I.connectedAppsOf = s.botConnectedApps;
      addTearDown(() => Bots.I.connectedAppsOf = null);
      final brief = Bots.I.opencodeBriefOf(free);
      expect(brief, contains("The owner's connected apps you can use"));
      expect(brief, contains('never say one is not connected before you tried it'));
    });
  });
}
