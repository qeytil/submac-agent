// fix/bot-call-tool (owner, 2026-10-26): "Bots lost their calling tools. If I say 'call me', it always asks which number
// instead of calling me in the app." "Call me" must start the in-app call (main agent: call_user, a bot: bot_call); the
// phone dialer (call_number) is only for another person or a number the user gives. Each group failed on the old code.
import 'package:agent/app_state.dart';
import 'package:agent/models.dart';
import 'package:agent/services/bots.dart';
import 'package:agent/services/call_me.dart';
import 'package:agent/services/cloud.dart';
import 'package:agent/services/full_access.dart';
import 'package:agent/services/phone_tools.dart';
import 'package:agent/ui/i18n.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

List<String> _names(List<Map<String, dynamic>> tools) => [for (final t in tools) '${(t['function'] as Map?)?['name']}'];

String _desc(List<Map<String, dynamic>> tools, String name) =>
    '${(tools.firstWhere((t) => (t['function'] as Map)['name'] == name)['function'] as Map)['description']}';

Bot _bot(String id, {bool calls = true, Set<String> off = const {}}) => Bot(
    id: id, name: 'Ada $id', role: 'helper', persona: 'Kind.', quietFrom: 0, quietTo: 0, allowCalls: calls, proactivity: 'active')
  ..convId = 'conv-$id'
  ..powersOff.addAll(off);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppState app;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await FullAccess.I.set(false);
    AppLang.I.choice = 'en';
    app = AppState();
    await app.local.init();
    Cloud.features.value = const CloudFeatures();
    Cloud.calls.value = const CallMinutes();
    app.appVisible = true;
  });

  tearDown(() {
    Bots.I.bots.removeWhere((b) => b.id.startsWith('bc'));
    Bots.I.ring = null;
  });

  group('the in-app call tool is there for the main agent and every bot', () {
    test('main chat: call_user in the full, scoped and light tool sets', () {
      app.listsForTest['m1'] = [ChatMessage(id: 'u1', role: 'user', content: 'call me')];
      expect(_names(app.allToolsForTest('m1')), contains(CallMe.tool));
      expect(_names(app.scopedToolsForTest('m1')), contains(CallMe.tool), reason: 'never behind more_tools');
      expect(_names(app.lightToolsForTest('m1')), contains(CallMe.tool), reason: 'a short "i wac" runs in the light lane');
    });

    test('every bot (plain, each built-in template, the Chief, powers off, own apps only) has bot_call and not call_user', () {
      final bots = <Bot>[
        _bot('bc1'),
        _bot('bc2', off: {'phone', 'web', 'browser', 'files', 'apps'}),
        _bot('bc3')..appsScoped = true,
        for (final t in BotTemplates.all) Bot.fromJson({...t.toJson(), 'id': 'bc_${t.id}'})..convId = 'conv-bc_${t.id}',
      ];
      Bots.I.bots.addAll(bots);
      final chief = Bots.I.chiefId;
      Bots.I.chiefId = 'bc1';
      addTearDown(() => Bots.I.chiefId = chief);
      for (final b in bots) {
        for (final set in [app.allToolsForTest(b.convId), app.scopedToolsForTest(b.convId), app.lightToolsForTest(b.convId)]) {
          final n = _names(set);
          expect(n, contains(CallMe.botTool), reason: '${b.id} lost bot_call');
          expect(n, isNot(contains(CallMe.tool)), reason: '${b.id}: one call tool per bot, its own ring');
        }
      }
    });

    test('a voice call does not offer call_user (it is already a call)', () {
      expect(AppState.liveSkip(CallMe.tool), isTrue);
    });

    test('the bot chat prompt names bot_call for "call me" (the Grok-style rewrite had dropped it)', () {
      final b = _bot('bc4');
      final p = Bots.I.stablePromptOf(b);
      expect(p, contains(CallMe.botPromptLine));
      expect(p, contains('bot_call'));
    });

    test('the main prompt (phone section) routes "call me" to call_user', () {
      expect(app.systemPromptForTest(), contains(CallMe.promptLine));
    });
  });

  group('tool descriptions route "call me" to the in-app call, the dialer only to a number', () {
    test('call_user and bot_call say in-app, no phone number, and name the user\'s words', () {
      app.listsForTest['m2'] = [];
      final main = _desc(app.allToolsForTest('m2'), CallMe.tool);
      final bot = _desc(Bots.definitions, CallMe.botTool);
      for (final d in [main, bot]) {
        expect(d, contains('in-app'));
        expect(d, contains('"call me"'));
        expect(d, contains('i soo wac'));
        expect(d.toLowerCase(), contains('never ask for their phone number'));
      }
      expect(bot, isNot(contains('only when they asked')), reason: 'the old hedge made the model avoid it');
      expect((CallMe.definition['function'] as Map)['parameters'], containsPair('required', isEmpty));
    });

    test('call_number is for another person or a given number, never "call me"', () {
      final d = _desc(PhoneTools.definitions, 'call_number');
      expect(d, contains('another person'));
      expect(d, contains('Never for "call me"'));
      expect(d, contains(CallMe.tool));
    });

    test('call_number with no number points at the in-app call instead of "which number?"', () async {
      final out = await PhoneTools.execute('call_number', {'number': ''});
      expect(out, CallMe.dialerNoNumber);
      expect(out, contains('do not ask for a number'));
    });
  });

  group('"call me" in English, Somali and Arabic', () {
    const yes = [
      'call me',
      'Call me now please',
      'can you call me?',
      'please call me back',
      'ring me',
      'give me a call',
      'i soo wac',
      'Fadlan ii soo wac',
      'ii wac',
      'soo wac',
      'اتصل بي',
      'كلمني الآن',
    ];
    const no = [
      'call me Ali',
      'call 0615123456',
      'call me at +252 61 5123456',
      'call my mom',
      "don't call me",
      'call me tomorrow at 9',
      'ha i soo wacin',
      'who called me today?',
      'how do I call someone abroad',
      'لا تتصل بي',
    ];
    for (final t in yes) {
      test('call now: "$t"', () => expect(CallMe.wantsCallNow(t), isTrue));
    }
    for (final t in no) {
      test('not a call now: "$t"', () => expect(CallMe.wantsCallNow(t), isFalse));
    }

    test('the step note names the right tool and never asks for a number; app wakes get none', () {
      expect(AppState.callMeNote('call me', bot: false), contains(CallMe.tool));
      expect(AppState.callMeNote('i soo wac', bot: true), contains(CallMe.botTool));
      expect(AppState.callMeNote('call me', bot: true), contains('Do not ask for a phone number'));
      expect(AppState.callMeNote('$botWakeMark[Woken: routine]\ncall me', bot: true), isNull);
      expect(AppState.callMeNote('call my brother on 0615123456', bot: false), isNull);
      expect(AppState.callMeNote(null, bot: false), isNull);
    });
  });

  group('call_user starts the in-app call', () {
    test('main agent: starts the call in this chat, no approval card, no number', () async {
      final calls = <(String, String)>[];
      app.userCallStarter = (conv, opening) async {
        calls.add((conv, opening));
        return null;
      };
      final g = await app.toolGate(CallMe.tool, const {}, 'm3');
      expect(g.blocked, isNull);
      expect(g.ask, isNull, reason: 'the user asked for the call: no approval card');
      final out = await app.runToolWithApproval(CallMe.tool, {'reason': 'quick question'}, convId: 'm3');
      expect(out, CallMe.started);
      expect(calls, hasLength(1));
      expect(calls.single.$1, 'm3');
      expect(calls.single.$2, startsWith('[Call]'));
      expect(calls.single.$2, contains('quick question'));
    });

    test('no call minutes left: no call, the user is told why (minutes are not touched)', () async {
      var started = false;
      app.userCallStarter = (c, o) async {
        started = true;
        return null;
      };
      Cloud.calls.value = CallMinutes(secondsLeft: 0, checkedAt: DateTime.now());
      final out = await app.runToolWithApproval(CallMe.tool, const {}, convId: 'm4');
      expect(started, isFalse);
      expect(out, startsWith('No call started'));
      expect(out, contains(Cloud.calls.value.usedUpMessage));
    });

    test('voice off, or SubMac not on screen: no call', () async {
      var started = false;
      app.userCallStarter = (c, o) async {
        started = true;
        return null;
      };
      Cloud.features.value = const CloudFeatures(live: false);
      expect(await app.runToolWithApproval(CallMe.tool, const {}, convId: 'm5'), CallMe.unavailable);
      Cloud.features.value = const CloudFeatures();
      app.appVisible = false;
      expect(await app.runToolWithApproval(CallMe.tool, const {}, convId: 'm5'), CallMe.notInApp);
      expect(started, isFalse);
    });

    test('the call could not connect: says so', () async {
      app.userCallStarter = (c, o) async => 'needs_key';
      expect(await app.runToolWithApproval(CallMe.tool, const {}, convId: 'm6'), CallMe.unavailable);
    });

    test('a bot: bot_call rings the user; call_user in a bot chat rings through the bot\'s own ring', () async {
      final b = _bot('bc5');
      Bots.I.bots.add(b);
      final rang = <(String, String)>[];
      Bots.I.ring = (bot, reason) async {
        rang.add((bot.id, reason));
        return 'Ringing the user now.';
      };
      var started = false;
      app.userCallStarter = (c, o) async {
        started = true;
        return null;
      };
      expect(await app.runToolWithApproval(CallMe.botTool, {'reason': 'Your report is ready'}, convId: b.convId), 'Ringing the user now.');
      expect(await app.runToolWithApproval(CallMe.tool, const {}, convId: b.convId), 'Ringing the user now.');
      expect(rang, [('bc5', 'Your report is ready'), ('bc5', 'You asked me to call')]);
      expect(started, isFalse, reason: 'a bot never opens a plain SubMac call');
    });
  });
}
