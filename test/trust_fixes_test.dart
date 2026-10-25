import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:agent/app_state.dart';
import 'package:agent/models.dart';
import 'package:agent/services/agent_loop.dart';
import 'package:agent/services/bots.dart';
import 'package:agent/services/memory_store.dart';
import 'package:agent/services/send_gate.dart';
import 'package:agent/services/session_rules.dart';

/// Trust fixes (docs/ISSUES.md). Each group reproduces one issue: it failed (or could not be expressed) before the
/// fix and passes after it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final app = AppState();
  final bot = Bot(id: 'tf-bot', name: 'Ayaan', role: 'Researcher', persona: 'Careful.');
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await app.local.init();
    bot.convId = 'c-bot';
    Bots.I.bots.add(bot);
  });
  tearDownAll(() => Bots.I.bots.removeWhere((b) => b.id == 'tf-bot'));

  MemoryFact fact(String id, String t) => MemoryFact(id: id, fact: t, createdAt: DateTime(2026, 10, 23));

  group('T-01 memory never moves to another account', () {
    test('facts kept for account A are not uploaded into account B', () {
      final here = [fact('1', 'Lives in Hargeisa'), fact('2', 'Has two kids')];
      // Before: every local fact the new account lacked was uploaded as "saved offline".
      expect(MemoryStore.pendingUploads(here, {}, owner: 'user-a', uid: 'user-b'), isEmpty);
    });
    test('the same account still gets its offline facts saved', () {
      final here = [fact('1', 'Lives in Hargeisa'), fact('2', 'Has two kids')];
      expect(MemoryStore.pendingUploads(here, {'1'}, owner: 'user-a', uid: 'user-a').map((f) => f.id), ['2']);
      // Facts from before the owner was kept count as the signed-in account's (old installs keep working).
      expect(MemoryStore.pendingUploads(here, {}, owner: '', uid: 'user-a').length, 2);
      expect(MemoryStore.pendingUploads(here, {}, owner: '', uid: ''), isEmpty);
    });
    test('sign-out takes the facts off the phone', () {
      app.memory.facts = [fact('1', 'Prefers Somali')];
      app.local.prefs.setString(MemoryStore.ownerKey, 'user-a');
      app.memory.forgetDevice();
      expect(app.memory.facts, isEmpty);
      expect(app.local.memories, isEmpty);
      expect(app.local.prefs.getString(MemoryStore.ownerKey), isNull);
    });
  });

  group('T-02 nothing of the old account stays in the app after sign-out', () {
    test('custom instructions, memory, loaded chats, a picked skill and skill notes are cleared', () async {
      app.aboutYou = 'I am Amina, a nurse in Garowe.';
      app.howToRespond = 'Short answers.';
      app.memory.facts = [fact('1', 'Allergic to penicillin')];
      app.listsForTest['c-old'] = [ChatMessage(id: 'm1', role: 'user', content: 'my bank pin is…')];
      app.skillNotesForTest['c-old'] = '# Skill for this message: x';
      app.awaitingReply = 'm1';
      app.banner = 'Task finished in "Rent".';
      await app.clearAccountState();
      expect(app.aboutYou, isEmpty);
      expect(app.howToRespond, isEmpty);
      expect(app.memory.facts, isEmpty);
      expect(app.listsForTest, isEmpty);
      expect(app.skillNotesForTest, isEmpty);
      expect(app.awaitingReply, isNull);
      expect(app.banner, isNull);
      expect(app.messagesOf('c-old'), isEmpty);
    });
  });

  group('T-05 a trimmed bot chat keeps its own bot', () {
    test('the payload is built for the chat the runner names, not the chat on screen', () {
      app.currentId = 'c-owner'; // the user is looking at their own SubMac chat
      final botChat = [ChatMessage(id: 'u1', role: 'user', content: 'Find three suppliers in Bosaso.')];
      app.listsForTest['c-bot'] = botChat;
      // A trimmed copy (what _tail() returns when the chat is too long) is a different list.
      final trimmed = botChat.sublist(0);
      final before = app.payloadForTest(trimmed); // the old lookup: falls back to the chat on screen
      final after = app.payloadForTest(trimmed, convId: 'c-bot');
      expect('${before.first['content']}', isNot(contains('Ayaan')));
      expect('${after.first['content']}', contains('Ayaan'));
      app.listsForTest.remove('c-bot');
      app.currentId = null;
    });
  });

  group('T-06 / T-13 / T-18 background work stays in its own chat', () {
    test('a Live task with a bot chat open does not run inside the bot chat', () {
      expect(SessionRules.backgroundTarget(currentId: 'c-bot', currentIsForeignBot: true), BgTarget.newChat);
      expect(SessionRules.backgroundTarget(currentId: 'c-owner'), BgTarget.current);
      expect(SessionRules.backgroundTarget(currentId: 'c-owner', currentBusy: true), BgTarget.newChat);
    });
    test('a scheduled run whose chat is busy is not spilled into the chat on screen', () {
      // Before: busy chat + no title of its own fell through to the chat on screen.
      expect(
          SessionRules.backgroundTarget(reuseConvId: 'c-sched', reuseLoaded: true, reuseBusy: true, currentId: 'c-owner'), BgTarget.busy);
      expect(SessionRules.backgroundTarget(reuseConvId: 'c-sched', reuseLoaded: true, currentId: 'c-owner'), BgTarget.reuse);
      // Telegram (has a title): a busy chat gets a new chat of its own.
      expect(SessionRules.backgroundTarget(reuseConvId: 'c-tg', reuseLoaded: true, reuseBusy: true, hasOwnTitle: true), BgTarget.ownChat);
      // A bot's chat never lends itself while busy.
      expect(SessionRules.backgroundTarget(reuseConvId: 'c-bot', reuseLoaded: true, reuseBusy: true, reuseIsBot: true), BgTarget.busy);
      // Not loaded and no title: its own chat, never the screen's.
      expect(SessionRules.backgroundTarget(reuseConvId: 'c-x', currentId: 'c-owner'), BgTarget.ownChat);
    });
    test('a SubMac call is not saved into an open bot chat', () {
      expect(SessionRules.liveSaveTarget(currentId: 'c-bot', currentIsBot: true), isNull);
      expect(SessionRules.liveSaveTarget(currentId: 'c-owner'), 'c-owner');
      expect(SessionRules.liveSaveTarget(), isNull);
    });
  });

  group('T-07 "+" while the first message saves', () {
    test('a message in the next new chat does not join the first one', () {
      final gate = SendGate();
      final first = gate.claim(null); // first message of a new chat, still saving
      expect(gate.openOn(null), same(first));
      gate.forgetNewChat(); // the user tapped "+"
      expect(gate.openOn(null), isNull);
      // The first message's chat is still covered once it has its id.
      first.alias('c-new');
      expect(gate.openOn('c-new'), same(first));
      first.open('c-new');
      expect(gate.openOn('c-new'), isNull);
    });
    test('the created chat becomes the open chat only if the user is still on that draft', () {
      final draft = <ChatMessage>[];
      expect(SessionRules.adoptNewChat(currentId: null, onScreen: draft, draft: draft), isTrue);
      expect(SessionRules.adoptNewChat(currentId: null, onScreen: <ChatMessage>[], draft: draft), isFalse);
      expect(SessionRules.adoptNewChat(currentId: 'c-other', onScreen: draft, draft: draft), isFalse);
    });
  });

  group('T-08 the wrap-up note only comes before a real stop', () {
    test('no "two steps left" at step 48 when the task will carry on past the checkpoint', () {
      expect(StepBudget.note(48, 50, willPause: false, ceiling: 1000), isNull);
      expect(StepBudget.note(48, 50, willPause: true, ceiling: 1000), isNotNull);
    });
    test('later checkpoints and the ceiling get it too', () {
      expect(StepBudget.note(98, 50, willPause: true, ceiling: 1000), isNotNull);
      expect(StepBudget.note(998, 50, willPause: false, ceiling: 1000), isNotNull);
      expect(StepBudget.note(60, 50, willPause: true, ceiling: 1000), isNull);
    });
  });

  group('T-09 a stuck task stops instead of being nudged forever', () {
    test('after three ignored stuck notes the guard says stop', () {
      final g = LoopGuard();
      var notes = 0;
      var stop = false;
      for (var step = 0; step < 60 && !stop; step++) {
        g.record('fetch_url', '{"url":"https://example.so"}', 'Error: 403 Forbidden');
        final sig = g.check();
        if (sig.stuck) {
          g.reset();
          notes++;
          stop = g.strike();
        }
      }
      expect(stop, isTrue);
      expect(notes, LoopGuard.maxStrikes);
      expect(LoopGuard.giveUp, contains('Call no more tools'));
    });
  });

  group('T-10 one snackbar per banner', () {
    test('only the first of several callbacks shows it', () {
      app.banner = 'A message didn\'t sync.';
      final shown = [for (var i = 0; i < 3; i++) app.takeBanner('A message didn\'t sync.')];
      expect(shown, [true, false, false]);
      expect(app.banner, isNull);
    });
    test('a newer banner is not taken by an older callback', () {
      app.banner = 'Second';
      expect(app.takeBanner('First'), isFalse);
      expect(app.banner, 'Second');
      app.banner = null;
    });
  });

  group('T-12 Stop takes the ongoing notification down', () {
    test('when no task is left', () {
      expect(SessionRules.keepAliveOffAfterStop(tasksLeft: 0, telegramWaiting: false), isTrue);
      expect(SessionRules.keepAliveOffAfterStop(tasksLeft: 1, telegramWaiting: false), isFalse);
      expect(SessionRules.keepAliveOffAfterStop(tasksLeft: 0, telegramWaiting: true), isFalse);
    });
  });

  group('T-14 no secrets in logs', () {
    test('the Live socket URL token is removed', () {
      const e = "WebSocketChannelException: WebSocketException: Connection to "
          "'https://live.example.com/ws?access_token=eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.abcDEF123456#' was not upgraded";
      final c = LogScrub.clean(e);
      expect(c, isNot(contains('eyJhbGciOiJIUzI1NiJ9')));
      expect(c, contains('access_token=***'));
    });
    test('bearer tokens, keys and JWTs are removed; plain text stays', () {
      expect(LogScrub.clean('Authorization: Bearer abc.def-123'), 'Authorization: Bearer ***');
      expect(LogScrub.clean('url?key=AIzaSyXYZ&x=1'), 'url?key=***&x=1');
      expect(LogScrub.clean('token sk-proj_abcdefghijklmnop leaked'), isNot(contains('abcdefghijklmnop')));
      expect(LogScrub.clean('code 1006: connection lost'), 'code 1006: connection lost');
    });
  });
}
