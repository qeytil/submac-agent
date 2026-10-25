// Chat data safety regressions (PR-1 fix/chat-data-safety): CB-14, CB-17, CB-18, CB-22.
// The CB-14 group is the round-2 probe from test/zz_chat_bughunt2_test.dart, moved here with its assertions unchanged.
//
// Run: flutter test test/chat_regress_data_test.dart
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member, depend_on_referenced_packages
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent/app_state.dart';
import 'package:agent/models.dart';
import 'package:agent/services/bots.dart';
import 'package:agent/services/chat_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Docs extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Docs(this.dir);
  final String dir;
  @override
  Future<String?> getApplicationDocumentsPath() async => dir;
  @override
  Future<String?> getTemporaryPath() async => dir;
  @override
  Future<String?> getApplicationSupportPath() async => dir;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ---------------------------------------------------------------- CB-14 chat file written by two flushes at once
  group('CB-14 two saves at once corrupt the chat file', () {
    test('overlapping flushes leave a chat file that still reads back', () async {
      final tmp = await Directory.systemTemp.createTemp('cb14');
      PathProviderPlatform.instance = _Docs(tmp.path);
      final s = ChatStore();
      await s.open('u1');
      s.index['c1'] = {'id': 'c1', 'title': 'Long chat', '_remote': false};
      final c = await s.chatOrNew('c1');
      // A long chat: tool results are kept whole on the phone, so a few MB is normal after a browsing task.
      final big = 'x' * 4000;
      for (var i = 0; i < 1500; i++) {
        c.rows.add({'id': 'm$i', 'role': i.isEven ? 'user' : 'tool', 'content': big, 'created_at': s.stamp()});
      }
      final file = File('${tmp.path}/chats/u1/c1.json');
      final bad = <String>[];
      // The 400 ms save timer and "app went to the background" (or the end of a backup round) both call flush(); nothing
      // stops a second flush from writing the same "<chat>.json.tmp" while the first is still writing it.
      for (var round = 0; round < 40; round++) {
        while (c.rows.length < 1500) {
          c.rows.add({'id': 'm${c.rows.length}-$round', 'role': 'tool', 'content': big, 'created_at': s.stamp()});
        }
        s.markChanged('c1');
        final f1 = s.flush();
        await Future<void>.delayed(Duration(microseconds: 200 * (round % 20)));
        // While the first write is still going, the chat changes again (rows removed: an edit, a regenerate).
        c.rows.removeRange(10, c.rows.length);
        s.markChanged('c1');
        final f2 = s.flush();
        Object? e1, e2;
        await f1.catchError((Object e) => e1 = e);
        await f2.catchError((Object e) => e2 = e);
        // Whatever is on disk now is what the next app start reads.
        final text = await file.readAsString();
        try {
          final rows = ((jsonDecode(text) as Map)['rows'] as List).length;
          if (rows != c.rows.length) bad.add('round $round: file has $rows rows, chat has ${c.rows.length}');
        } catch (e) {
          bad.add('round $round: not JSON (${text.length} bytes) ${e1 ?? ''} ${e2 ?? ''}');
        }
      }
      expect(bad, isEmpty, reason: 'overlapping saves left a broken or stale chat file: ${bad.take(5).toList()} (${bad.length}/40). '
          'On the next start ChatStore.chat() returns null for a broken file and the chat is treated as missing.');
      await tmp.delete(recursive: true);
    });
  });

  group('CB-14 last good copy', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('cb14bak');
      PathProviderPlatform.instance = _Docs(tmp.path);
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    Future<ChatStore> saved(int saves) async {
      final s = ChatStore();
      await s.open('u1');
      s.index['c1'] = {'id': 'c1', 'title': 'Chat', '_remote': false};
      final c = await s.chatOrNew('c1');
      for (var i = 0; i < saves; i++) {
        c.rows.add({'id': 'm$i', 'role': 'user', 'content': 'hello $i', 'created_at': s.stamp()});
        s.markChanged('c1');
        await s.flush();
      }
      return s;
    }

    test('a corrupt chat file with a good .bak reads back from the .bak', () async {
      await saved(3);
      final main = File('${tmp.path}/chats/u1/c1.json');
      final bak = File('${tmp.path}/chats/u1/c1.json.bak');
      expect(await bak.exists(), isTrue, reason: 'every save keeps the previous file as the last good copy');
      // A write cut off by a kill: half a JSON file.
      final text = await main.readAsString();
      await main.writeAsString(text.substring(0, text.length ~/ 2));
      final s2 = ChatStore();
      await s2.open('u1');
      final c = await s2.chat('c1');
      expect(c, isNotNull, reason: 'the chat must not be treated as missing while its last good copy is on disk');
      expect(c!.rows.length, 2, reason: 'the .bak holds the save before the last one');
    });

    test('a chat whose main file is gone (killed between the two renames) reads back from the .bak', () async {
      await saved(2);
      await File('${tmp.path}/chats/u1/c1.json').delete();
      final s2 = ChatStore();
      await s2.open('u1');
      expect((await s2.chat('c1'))?.rows.length, 1);
    });

    test('a corrupt chat list falls back to its .bak', () async {
      await saved(2);
      await File('${tmp.path}/chats/u1/index.json').writeAsString('{"v":1,"chats":[{"id":"c1"');
      final s2 = ChatStore();
      await s2.open('u1');
      expect(s2.index.keys, contains('c1'));
    });

    test('a deleted chat does not come back from its .bak', () async {
      final s = await saved(3);
      await s.forget('c1');
      await s.flush();
      expect(await File('${tmp.path}/chats/u1/c1.json.bak').exists(), isFalse);
      final s2 = ChatStore();
      await s2.open('u1');
      expect(await s2.chat('c1'), isNull);
    });

    test('wipe removes the .bak copies too', () async {
      final s = await saved(3);
      await s.wipe();
      final left = tmp.listSync(recursive: true).whereType<File>().map((f) => f.path.split('/').last).where((n) => n.startsWith('c1'));
      expect(left, isEmpty);
    });
  });

  // ---------------------------------------------------------------- CB-17 a silent bot wake deletes the owner's message
  group('CB-17 a silent bot wake removes only its own rows', () {
    late Directory tmp;
    late AppState s;
    final bot = Bot(id: 'b17', name: 'Nova', role: 'Researcher', persona: '')
      ..active = true
      ..convId = 'conv-b17';
    late List<ChatMessage> list;
    late Set<String> wakeIds;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      tmp = await Directory.systemTemp.createTemp('cb17');
      PathProviderPlatform.instance = _Docs(tmp.path);
      Bots.I.bots.add(bot);
      s = AppState();
      s.repo.testUserId = 'u17';
      final mark = ChatMessage(id: 'w0', role: 'user', content: '$botWakeMark[Woken: check-in]\nThis is your regular check-in.');
      final call = ChatMessage(id: 'w1', role: 'assistant', content: '', toolCalls: [ToolCall(id: 't1', name: 'web_search', arguments: '{}')]);
      final result = ChatMessage(id: 'w2', role: 'tool', content: 'results', toolCallId: 't1', name: 'web_search');
      // Typed by the owner while the wake was working (steer path), and the quick side reply to it.
      final owner = ChatMessage(id: 'o1', role: 'user', content: 'Also check flights to Nairobi next week');
      final side = ChatMessage(id: 's1', role: 'assistant', content: 'Sure, I will look at flights too.');
      final silent = ChatMessage(id: 'w3', role: 'assistant', content: '[no reply]');
      list = [ChatMessage(id: 'old', role: 'assistant', content: 'Morning brief sent.'), mark, call, result, owner, side, silent];
      wakeIds = {'w1', 'w2', 'w3'};
      s.listsForTest[bot.convId] = list;
    });
    tearDown(() async {
      Bots.I.bots.remove(bot);
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('bot wake silent keeps owner rows typed during the wake', () async {
      s.wakeRowsForTest[bot.convId] = wakeIds;
      await s.botOutcomeForTest(bot, '[no reply]', 'work');
      final ids = [for (final m in list) m.id];
      expect(ids, containsAll(['old', 'o1', 's1']), reason: 'the owner\'s message and the reply to it were deleted: $ids');
      expect(ids.where((id) => id.startsWith('w')), isEmpty, reason: 'the silent wake\'s own rows stay behind: $ids');
    });

    test('without the wake\'s row list, an owner message after the mark keeps everything but the mark', () async {
      await s.botOutcomeForTest(bot, '[no reply]', 'work');
      final ids = [for (final m in list) m.id];
      expect(ids, containsAll(['old', 'o1', 's1']));
      expect(ids, isNot(contains('w0')));
    });

    test('a quiet wake nobody interrupted still leaves no trace', () async {
      list.removeWhere((m) => m.id == 'o1' || m.id == 's1');
      s.wakeRowsForTest[bot.convId] = wakeIds;
      await s.botOutcomeForTest(bot, '[no reply]', 'work');
      expect([for (final m in list) m.id], ['old']);
    });

    test('a real reply with a stray silence tag is kept', () async {
      list
        ..removeWhere((m) => m.id == 'o1' || m.id == 's1')
        ..last.content = 'Flights to Nairobi dropped to \$210 for Tuesday.\n@silent';
      s.wakeRowsForTest[bot.convId] = wakeIds;
      await s.botOutcomeForTest(bot, list.last.content, 'work');
      final kept = list.where((m) => m.role == 'assistant' && m.content.contains('Nairobi'));
      expect(kept, isNotEmpty, reason: 'a reply with real words was deleted as silence: ${[for (final m in list) m.content]}');
    });
  });

  // ---------------------------------------------------------------- CB-18 delete-all leaves ghost chats
  group('CB-18 delete-all while a task runs', () {
    late Directory tmp;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      tmp = await Directory.systemTemp.createTemp('cb18');
      PathProviderPlatform.instance = _Docs(tmp.path);
    });
    tearDown(() async {
      AppState.debugRunAgent = null;
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('delete-all while a run streams leaves 0 conversations after the run ends', () async {
      final s = AppState();
      s.repo.testUserId = 'u18';
      final c = await s.repo.createConversation(title: 'Trip to Hargeisa');
      final user = ChatMessage(id: 'u1', role: 'user', content: 'Plan a 3 day trip to Hargeisa');
      await s.repo.insertMessage(c.id, user);
      s.conversations = [c];
      s.currentId = c.id;
      s.messages = [user];
      s.listsForTest[c.id] = s.messages;
      // The step in flight does not notice Stop: it saves its streamed reply when it returns, as a real step does.
      AppState.debugRunAgent = (app, run) async {
        await Future<void>.delayed(const Duration(milliseconds: 80));
        await app.repo.insertMessage(run.convId, ChatMessage(id: 'late', role: 'assistant', content: 'Day 1: arrive and'));
        await app.repo.updateConversation(run.convId, {'model': 'submac'});
      };
      final running = s.regenerate();
      for (var i = 0; i < 50 && s.runs.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(s.runs, isNotEmpty, reason: 'the task is running when the user deletes every chat');
      await s.deleteAllConversations();
      await running;
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(s.runs, isEmpty);
      expect(s.repo.store.index, isEmpty, reason: 'a ghost chat came back after delete-all: ${s.repo.store.index.values.toList()}');
      expect(await s.repo.localConversations(), isEmpty);
    });

    test('a write to a chat deleted this session is ignored', () async {
      final s = AppState();
      s.repo.testUserId = 'u18b';
      final c = await s.repo.createConversation(title: 'Old chat');
      await s.repo.deleteAllConversations();
      expect(s.repo.wasDeletedHere(c.id), isTrue);
      await s.repo.insertMessage(c.id, ChatMessage(id: 'x', role: 'assistant', content: 'late reply'));
      expect(s.repo.store.index.containsKey(c.id), isFalse);
      // A new chat afterwards works as before.
      final n = await s.repo.createConversation(title: 'New chat');
      await s.repo.insertMessage(n.id, ChatMessage(id: 'y', role: 'user', content: 'hi'));
      expect((await s.repo.store.chat(n.id))?.rows.length, 1);
    });

    test('a bot\'s chat stays writable after delete-all (its id is reused by its next wake)', () async {
      final s = AppState();
      s.repo.testUserId = 'u18c';
      final c = await s.repo.createConversation(title: 'Nova');
      await s.repo.deleteAllConversations(keepWritable: {c.id});
      expect(s.repo.wasDeletedHere(c.id), isFalse);
    });
  });

  // ---------------------------------------------------------------- CB-22 "Try again" sends twice
  group('CB-22 Try again starts one run', () {
    late Directory tmp;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      tmp = await Directory.systemTemp.createTemp('cb22');
      PathProviderPlatform.instance = _Docs(tmp.path);
    });
    tearDown(() async {
      AppState.debugRunAgent = null;
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('two regenerate taps in one frame start one run', () async {
      final s = AppState();
      s.repo.testUserId = 'u22';
      final c = await s.repo.createConversation(title: 'Chat');
      final user = ChatMessage(id: 'u1', role: 'user', content: 'Summarise this article');
      final old = ChatMessage(id: 'a1', role: 'assistant', content: 'An old answer');
      await s.repo.insertMessage(c.id, user);
      await s.repo.insertMessage(c.id, old);
      s.conversations = [c];
      s.currentId = c.id;
      s.messages = [user, old];
      s.listsForTest[c.id] = s.messages;
      var started = 0;
      final hold = Completer<void>();
      AppState.debugRunAgent = (app, run) async {
        if (!run.side) started++;
        await hold.future;
      };
      // Two taps on "Try again" in the same frame.
      final a = s.regenerate();
      final b = s.regenerate();
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(started, 1, reason: 'two taps started $started runs: two answers and two charges');
      hold.complete();
      await a;
      await b;
      expect(s.runs, isEmpty);
    });

    test('a second main run in a chat that already has one is not started', () async {
      final s = AppState();
      s.repo.testUserId = 'u22b';
      final c = await s.repo.createConversation(title: 'Chat');
      final user = ChatMessage(id: 'u1', role: 'user', content: 'hello');
      s.conversations = [c];
      s.currentId = c.id;
      s.messages = [user];
      s.listsForTest[c.id] = s.messages;
      var started = 0;
      final hold = Completer<void>();
      AppState.debugRunAgent = (app, run) async {
        started++;
        await hold.future;
      };
      final first = s.regenerate();
      for (var i = 0; i < 20 && s.runs.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      // The run is going: another "Try again" is refused by the busy check and the runner's own guard.
      await s.regenerate();
      expect(started, 1);
      hold.complete();
      await first;
    });
  });
}
