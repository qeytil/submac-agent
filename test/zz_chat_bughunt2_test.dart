// Chat bug hunt ROUND 2 (2026-10-25, main a891a83 / v1.13.102+172). PROBE TESTS: each test asserts the CORRECT
// behaviour, so it is RED on main and turns green once its bug is fixed. Investigation only, do not merge.
// Report: docs/chat-bughunt-2.md on this branch (same text as work/chatbugs2/report.md).
//
// Run: flutter test test/zz_chat_bughunt2_test.dart
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent/app_state.dart';
import 'package:agent/models.dart';
import 'package:agent/screens/bots_workspace.dart';
import 'package:agent/services/bot_status.dart';
import 'package:agent/services/bots.dart';
import 'package:agent/services/chat_store.dart';
import 'package:agent/services/cloud.dart';
import 'package:agent/services/llm_client.dart';
import 'package:agent/services/offices.dart';
import 'package:agent/services/team_run.dart';
import 'package:agent/theme.dart';
import 'package:agent/widgets/composer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:provider/provider.dart';
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

Bot _bot(String id, String name, String role) => Bot(id: id, name: name, role: role, persona: '')
  ..active = true
  ..convId = 'conv-$id';

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

  // ---------------------------------------------------------------- CB-16 Bots workspace keeps showing the old bot
  group('CB-16 the Bots workspace does not follow a chat opened from outside (notification tap)', () {
    Widget app(AppState s) => ChangeNotifierProvider<AppState>.value(
          value: s,
          child: MaterialApp(
            theme: buildTheme(Brightness.light),
            builder: (context, child) => MediaQuery(
              data: const MediaQueryData(size: Size(400, 860), padding: EdgeInsets.only(top: 24), disableAnimations: true),
              child: child!,
            ),
            home: const BotsWorkspace(),
          ),
        );

    setUp(() {
      SharedPreferences.setMockInitialValues({'office_bg_asked': true});
      BotStatus.I.reset();
      RailPins.I.reset();
      Composer.drafts.clear();
      BotsWorkspace.debugOpenBot = (s, b) async {
        s.currentId = b.convId;
        s.messages = [ChatMessage(id: 'm-${b.id}', role: 'assistant', content: 'Hello from ${b.name}')];
        s.loadingMessages = false;
        s.notifyListeners();
      };
      final chief = _bot('chief', 'Chief', 'Chief of staff');
      Bots.I.bots.addAll([chief, _bot('nova', 'Nova', 'Researcher')]);
      Bots.I.chiefId = chief.id;
    });
    tearDown(() {
      BotsWorkspace.debugOpenBot = null;
      Bots.I.bots.clear();
      Bots.I.chiefId = '';
      BotStatus.I.reset();
    });

    testWidgets('a bot notification for Nova tapped while the Chief is on screen: what you type goes where you look', (t) async {
      t.view.physicalSize = const Size(400, 860);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final s = AppState();
      await t.pumpWidget(app(s));
      await t.pumpAndSettle();
      final ws = t.state<BotsWorkspaceState>(find.byType(BotsWorkspace));
      expect(ws.active, 'b:chief');
      // _onNotificationTap('conv/<nova conv>') -> openConversation(novaConv): the open chat changes under the workspace.
      s.currentId = 'conv-nova';
      s.messages = [ChatMessage(id: 'n1', role: 'assistant', content: 'Nova found 3 suppliers')];
      s.notifyListeners();
      await t.pumpAndSettle();
      final shownChief = find.textContaining('Hello from Chief').evaluate().isNotEmpty;
      // The composer sends to state.currentId (Nova). The screen must then be Nova's chat, not the Chief's.
      expect(ws.active == 'b:nova' || !shownChief, isTrue,
          reason: 'the workspace still shows the Chief (active=${ws.active}, Chief\'s messages on screen=$shownChief) while the '
              'composer now sends to ${s.currentId}: the user writes to Nova believing they talk to the Chief');
    });
  });

  // ---------------------------------------------------------------- CB-19 Stop in a team: a member says it failed
  group('CB-19 stopping a team posts "I could not finish my part" after "stopped"', () {
    final lead = Bot(id: 'srl', name: 'Hodan', role: 'Manager', persona: 'Calm.');
    final nova = Bot(id: 'srn', name: 'Nova', role: 'Researcher', persona: 'Curious.');
    late Office o;
    setUp(() {
      Bots.I.bots.addAll([lead, nova]);
      o = Office(id: 'ostop', name: 'Coffee', members: ['srl', 'srn'], chiefId: 'srl');
      TeamRun.I
        ..reset()
        ..promptOf = ((b) => 'You are ${b.name}.')
        ..ask = (b, system, user, {int maxTokens = 0}) async {
          if (system.contains('# Who speaks')) return '{"speaker":"Hodan","team_task":true}';
          if (system.contains('# Plan for the owner')) {
            return '{"reply":"Cheapest coffee suppliers.","questions":[],"parts":[{"bot":"Nova","ask":"Find suppliers"}]}';
          }
          if (system.contains('# Your part')) {
            // The owner taps Stop while Nova is working.
            TeamRun.I.send(o, 'stop');
            await Future<void>.delayed(const Duration(milliseconds: 20));
            return '';
          }
          return '';
        };
    });
    tearDown(() {
      Bots.I.bots.removeWhere((b) => b.id.startsWith('sr'));
      TeamRun.I.reset();
    });

    test('after Stop, no member post claims the part failed', () async {
      TeamRun.I.send(o, 'Find the three cheapest coffee suppliers in Hargeisa');
      await TeamRun.I.work;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final texts = [for (final p in o.posts) '${p.from}: ${p.text}'];
      final iStop = texts.indexWhere((t) => t.contains('I have stopped the team'));
      expect(iStop, greaterThanOrEqualTo(0), reason: 'the stop line is posted: $texts');
      final after = texts.sublist(iStop + 1);
      expect(after.where((t) => t.contains('could not finish my part')), isEmpty,
          reason: 'after the owner stopped the team, Nova still posts a failure: $after');
    });
  });

  // ---------------------------------------------------------------- CB-21 a routine missed while the phone was off
  group('CB-21 a routine whose time passed while the phone was off or SubMac was killed never runs', () {
    test('booting at 08:40 with an 08:30 daily routine not yet run today schedules a catch-up soon', () {
      final r = BotRoutine(id: 'r1', time: '08:30', days: 'daily', instruction: 'Send me the morning brief');
      final boot = DateTime(2026, 10, 25, 8, 40);
      final next = r.next(boot)!;
      // Bots.arm() (run by BootReceiver -> "rearm" and at every start) arms exactly r.next(now). Nothing stores when a
      // routine last ran, so the 08:30 brief is silently skipped until tomorrow.
      expect(next.difference(boot).inMinutes, lessThan(60),
          reason: 'the next run is $next: today\'s missed 08:30 brief is skipped without a word');
    });
  });

  // ---------------------------------------------------------------- CB-24 a stream that just stops counts as finished
  group('CB-24 a reply stream that ends without finish_reason or [DONE] is taken as the whole answer', () {
    test('half an answer followed by a closed connection is a drop, not a finished reply', () async {
      String chunk(Map<String, dynamic> d) => 'data: ${jsonEncode({'choices': [{'index': 0, 'delta': d, 'finish_reason': null}]})}\n\n';
      LlmClient.testHeaders = (_) async => {'Content-Type': 'application/json'};
      LlmClient.testClient = MockClient.streaming((req, body) async {
        final ctrl = StreamController<List<int>>();
        () async {
          ctrl.add(utf8.encode(': ping\n\n'));
          await Future<void>.delayed(Duration.zero);
          ctrl.add(utf8.encode(chunk({'content': 'Your 3-day plan:\n| Day | Plan |\n|---|---|\n| 1 | Arrive and '})));
          await Future<void>.delayed(Duration.zero);
          await ctrl.close(); // the line closes: no finish_reason, no [DONE] (proxy/gateway cut, radio switch)
        }();
        return http.StreamedResponse(ctrl.stream, 200, headers: {'content-type': 'text/event-stream'});
      });
      Object? err;
      LlmResult? r;
      try {
        r = await LlmClient().streamChat(provider: Cloud.provider, model: Cloud.submac, messages: const [
          {'role': 'user', 'content': 'plan my trip'}
        ], onDelta: (_) {});
      } catch (e) {
        err = e;
      }
      LlmClient.testHeaders = null;
      expect(err != null || (r?.cutOff ?? false), isTrue,
          reason: 'streamChat returned finish=${r?.finishReason} with "${r?.content}" as a complete reply: the runner saves it as the final '
              'answer (no drop retry, no cut-off continuation)');
    });
  });
}
