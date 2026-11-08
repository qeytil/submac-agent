// Notifications (owner 2026-11-05, docs/notifications.md): who it is from (Agent "SubMac", a bot by name, a team by
// name), a short summary of the result (never "Running your scheduled task"), separate channels, and a Reply in the
// notification that reaches the right chat with SubMac closed. The engine is mocked (AppState.debugRunAgent).
//
// Run: flutter test test/notifications_test.dart
// ignore_for_file: invalid_use_of_visible_for_testing_member, invalid_use_of_protected_member, depend_on_referenced_packages
import 'dart:io';

import 'package:agent/app_state.dart';
import 'package:agent/models.dart';
import 'package:agent/services/bg_runs.dart';
import 'package:agent/services/bots.dart';
import 'package:agent/services/notif_text.dart';
import 'package:agent/services/offices.dart';
import 'package:agent/services/system_bridge.dart';
import 'package:agent/services/team_key.dart';
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

Future<void> _settle([int ms = 20]) => Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NotifText.summary: the first meaningful sentences, plain', () {
    test('markdown, headings, bullets, links and code are taken off', () {
      const reply = '## Hourly news\n\n'
          '**Local:** The city council approved the new [bus line](https://x.example/bus) today.\n'
          '- International: talks resumed in Geneva.\n'
          '```json\n{"a": 1}\n```\n'
          '* Markets were flat.\n'
          'A fourth line that should not fit.';
      final s = NotifText.summary(reply);
      expect(s, 'Hourly news\nLocal: The city council approved the new bus line today.\nInternational: talks resumed in Geneva.');
      expect(s, isNot(contains('**')));
      expect(s, isNot(contains('http')));
      expect(s, isNot(contains('{')));
      expect(s.split('\n').length, lessThanOrEqualTo(3));
    });

    test('greetings, "Here is…:" lines, bot tags and silence marks are not the summary', () {
      expect(NotifText.summary('Hello there\nHere is your news:\nRain from 3 pm, 24°C.\n@message'), 'Rain from 3 pm, 24°C.');
      expect(NotifText.summary('[needs you] Which logo do you prefer?'), 'Which logo do you prefer?');
      expect(NotifText.summary('Done, sent it. [no reply]'), 'Done, sent it.');
    });

    test('never longer than ~240 characters; ends on a sentence or a word', () {
      final long = List.filled(30, 'The quick brown fox jumps over the lazy dog.').join(' ');
      final s = NotifText.summary(long);
      expect(s.length, lessThanOrEqualTo(NotifText.maxSummary));
      expect(s.endsWith('.') || s.endsWith('…'), isTrue);
      final words = List.filled(80, 'word').join(' ');
      final w = NotifText.summary(words);
      expect(w.length, lessThanOrEqualTo(NotifText.maxSummary));
      expect(w.endsWith('…'), isTrue);
      expect(w, isNot(contains('wor…')));
    });

    test('a card-only reply uses its title; nothing at all uses the fallback', () {
      expect(NotifText.summary('```summary\n{"title": "Weekly sales up 4%", "items": []}\n```'), 'Weekly sales up 4%');
      expect(NotifText.summary('```\nls -la\n```', fallback: 'Done: Clean up'), 'Done: Clean up');
    });

    test('result: silence and a watcher with nothing new stay quiet; an empty reply says the task is done', () {
      expect(NotifText.result('NO_CHANGE'), '');
      expect(NotifText.result('[no reply]'), '');
      expect(NotifText.result('', task: 'Hourly news'), '');
      expect(NotifText.result('```\nx\n```', task: 'Hourly news'), 'Done: Hourly news');
      expect(NotifText.result('Dollar at 27,500 SOS, up 0.4%.'), 'Dollar at 27,500 SOS, up 0.4%.');
    });

    test('the running line names who and what, never "Running your scheduled task"', () {
      expect(NotifText.running('Nova', 'Hourly news'), 'Nova · Hourly news');
      expect(NotifText.running('Nova', ''), 'Nova');
      expect(NotifText.running('', 'Weather'), 'SubMac · Weather');
      expect(NotifText.running('Nova', '**Send me** the news every hour').toLowerCase(), isNot(contains('running')));
    });
  });

  group('channels and titles', () {
    test('Agent, Bots, Teams and Background work each have their own new channel', () {
      final ids = NotifFrom.values.map(NotifChannels.of).toList();
      expect(ids.toSet().length, NotifFrom.values.length);
      expect(NotifChannels.of(NotifFrom.agent), 'submac_agent_v2');
      expect(NotifChannels.of(NotifFrom.bot), 'submac_bots_v2');
      expect(NotifChannels.of(NotifFrom.team), 'submac_teams_v2');
      expect(NotifChannels.of(NotifFrom.work), 'submac_work_v2');
      for (final id in ids) {
        expect(NotifChannels.retired, isNot(contains(id)), reason: 'a channel keeps its old sound: new ids only');
      }
      expect(NotifChannels.retired, containsAll(['submac_tasks_v2', 'submac_bot_msgs']));
    });

    test('titles: SubMac for the agent, the bot by name, the team by name', () {
      expect(NotifText.title(NotifFrom.agent, bot: 'Nova'), 'SubMac');
      expect(NotifText.title(NotifFrom.bot, bot: 'Nova'), 'Nova');
      expect(NotifText.title(NotifFrom.team, bot: 'Nova', team: 'Launch team'), 'Launch team');
      expect(NotifText.teamLine('Nova', '**Draft** is ready.'), 'Nova: Draft is ready.');
    });

    test('a bot face is its first letter on its avatar colour; the agent keeps SubMac red', () {
      final f = NotifFace.ofBot('bot-1', 'nova', null);
      expect(f.initial, 'N');
      expect(f.color, isNot(0));
      expect(NotifFace.ofBot('bot-1', 'nova', null).color, f.color, reason: 'stable for the same bot');
      expect(NotifFace.ofBot('bot-1', 'Nova', 'av:pebble.red.dots').color, 0xFFC2361B);
      expect(NotifFace.agentAccent, 0xFFC2361B);
    });
  });

  group('NotifRoute: where a reply typed in a notification goes', () {
    test('team, bot chat and SubMac chat', () {
      final team = NotifRoute.parse('office/o1')!;
      expect((team.from, team.id, team.payload), (NotifFrom.team, 'o1', 'office/o1'));
      final bot = NotifRoute.parse('conv/c-bot', isBotConv: (c) => c == 'c-bot')!;
      expect((bot.from, bot.id), (NotifFrom.bot, 'c-bot'));
      final agent = NotifRoute.parse('conv/c-own', isBotConv: (c) => c == 'c-bot')!;
      expect((agent.from, agent.payload), (NotifFrom.agent, 'conv/c-own'));
      expect(NotifRoute.parse('botchat/b1')!.from, NotifFrom.bot);
      expect(NotifRoute.parse('approvals'), isNull);
      expect(NotifRoute.parse('conv/'), isNull);
    });
  });

  test('a result the owner scheduled ("message") reaches them past the bot\'s own message cap, not in quiet hours', () {
    expect(BgRun.outreach(wakeKind: 'message', want: 'message', allowed: 'note', quiet: false), 'message');
    expect(BgRun.outreach(wakeKind: 'message', want: 'message', allowed: 'note', quiet: true), 'note');
    expect(BgRun.outreach(wakeKind: 'work', want: 'message', allowed: 'note', quiet: false), 'note', reason: 'a check-in is the bot\'s own outreach');
    expect(BgRun.outreach(wakeKind: 'work', want: 'call', allowed: 'call', quiet: false), 'call');
  });

  group('routing with SubMac closed (mock engine)', () {
    late Directory tmp;
    late AppState s;
    late Bot b;
    late List<(String, Map<String, dynamic>?)> calls;
    late List<AgentRun> started;

    List<Map<String, dynamic>?> sent(String m) => calls.where((c) => c.$1 == m).map((c) => c.$2).toList();

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      tmp = await Directory.systemTemp.createTemp('notifs');
      PathProviderPlatform.instance = _Docs(tmp.path);
      await Bots.I.init();
      b = Bot(id: 'nb1', name: 'Nova', role: 'News', persona: '')
        ..active = true
        ..convId = 'conv-nb1'
        // Explicit off hours so delivery is deterministic whatever the bot's default is (this suite once ran at
        // 06:49 UTC, inside the old 22:00-07:00 default). A new bot's default is now off too.
        ..quietFrom = 0
        ..quietTo = 0;
      Bots.I.bots.add(b);
      s = AppState()..appVisible = false;
      s.repo.testUserId = 'u1';
      s.listsForTest[b.convId] = <ChatMessage>[];
      calls = [];
      started = [];
      SystemBridge.debugCalls = (m, a) => calls.add((m, a));
      AppState.debugRunAgent = (app, run) async => started.add(run);
    });
    tearDown(() async {
      AppState.debugRunAgent = null;
      SystemBridge.debugCalls = null;
      Bots.I.bots.remove(b);
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('a bot\'s scheduled result: its own name, face and channel, a short summary, a Reply', () async {
      s.listsForTest[b.convId]!.add(ChatMessage(id: 'm1', role: 'assistant', content: '## News\n**Local:** rain later today.\nMore below.\n@message'));
      await s.botOutcomeForTest(b, '## News\n**Local:** rain later today.\nMore below.\n@message', 'message');
      final n = sent('notifyFrom');
      expect(n, hasLength(1));
      expect(n.single!['channel'], NotifChannels.bots);
      expect(n.single!['title'], 'Nova');
      expect(n.single!['body'], 'News\nLocal: rain later today.\nMore below.');
      expect(n.single!['reply'], isTrue);
      expect(n.single!['payload'], 'conv/conv-nb1');
      expect(n.single!['initial'], 'N');
      expect(sent('notifyBot'), isEmpty, reason: 'the old plain bot notification is not used');
    });

    test('an hourly task past the bot\'s daily message cap still notifies', () async {
      b.messagesLeft; // rolls the day
      b.messagesToday = 99;
      s.listsForTest[b.convId]!.add(ChatMessage(id: 'm2', role: 'assistant', content: 'Top story: the bridge reopened.'));
      await s.botOutcomeForTest(b, 'Top story: the bridge reopened.\n@message', 'message');
      expect(sent('notifyFrom').map((a) => a!['body']), ['Top story: the bridge reopened.']);
    });

    test('SubMac\'s own scheduled task ends with an Agent notification: "SubMac" and the result', () {
      final list = <ChatMessage>[ChatMessage(id: 'u', role: 'user', content: 'Weather?')];
      final run = AgentRun(convId: 'own1', side: false, title: 'Weather');
      final reply = ChatMessage(id: 'r', role: 'assistant', content: 'Here is the weather:\nRain from 3 pm, 24°C. Take an umbrella.');
      list.add(reply);
      run.wrote.add('r');
      s.scheduledConvsForTest.add('own1');
      s.ocRunEndedForTest('own1', list, run);
      final n = sent('notifyFrom');
      expect(n, hasLength(1));
      expect(n.single!['channel'], NotifChannels.agent);
      expect(n.single!['title'], 'SubMac');
      expect(n.single!['body'], 'Rain from 3 pm, 24°C. Take an umbrella.');
      expect(n.single!['color'], NotifFace.agentAccent);
      expect(s.scheduledConvsForTest, isNot(contains('own1')));
    });

    test('a watcher with nothing new, or a chat the owner is looking at, stays quiet', () {
      final list = <ChatMessage>[ChatMessage(id: 'r', role: 'assistant', content: 'NO_CHANGE')];
      final run = AgentRun(convId: 'w1', side: false, title: 'Watch')..wrote.add('r');
      s.notifyRunEndForTest('w1', list, run, scheduled: true);
      s.appVisible = true;
      s.currentId = 'own2';
      final run2 = AgentRun(convId: 'own2', side: false, title: 'x')..wrote.add('r2');
      s.notifyRunEndForTest('own2', [ChatMessage(id: 'r2', role: 'assistant', content: 'Done.')], run2, scheduled: true);
      expect(sent('notifyFrom'), isEmpty);
    });

    test('a bot\'s scheduled wake reports through its outcome, never twice at the run end', () {
      final run = AgentRun(convId: b.convId, side: false, title: 'x')..wrote.add('r');
      s.notifyRunEndForTest(b.convId, [ChatMessage(id: 'r', role: 'assistant', content: 'News.')], run, scheduled: true);
      expect(sent('notifyFrom'), isEmpty);
    });

    test('a team post: "<Team>" with "<Bot>: message"; [needs you] pops up; nothing while the team is on screen', () async {
      final o = Office(id: 'o1', name: 'Launch team', members: [b.id], chiefId: b.id);
      await s.officeNotifyForTest(o, b, 'The **draft** is ready for review.');
      await s.officeNotifyForTest(o, b, 'Which logo should we use?', needs: true);
      final n = sent('notifyTeam');
      expect(n, hasLength(2));
      expect(n.first!['name'], 'Launch team');
      expect(n.first!['team'], 'o1');
      expect(n.first!['sender'], 'Nova');
      expect(n.first!['text'], 'The draft is ready for review.');
      expect(n.first!['needs'], isFalse);
      expect(n.last!['needs'], isTrue);
      expect(n.first!['id'], n.last!['id'], reason: 'one conversation per team');
      s.appVisible = true;
      s.viewingOffice = 'o1';
      await s.officeNotifyForTest(o, b, 'Another line.');
      expect(sent('notifyTeam'), hasLength(2));
    });

    test('Reply in a bot\'s notification: the owner\'s words land in its chat, it answers, the answer notifies', () async {
      await s.notificationReplyForTest('conv/${b.convId}', 'Thanks, and the weather?');
      await _settle();
      final list = s.listsForTest[b.convId]!;
      expect(list.last.role, 'user');
      expect(list.last.content, 'Thanks, and the weather?');
      expect(started.map((r) => r.convId), [b.convId]);
      expect(sent('keepAlive').where((a) => a!['on'] == true).map((a) => a!['text']), contains('Nova · Your reply'));
      // The run ends (engine mocked): its answer comes back as Nova's notification.
      final run = started.single;
      list.add(ChatMessage(id: 'ans', role: 'assistant', content: 'Sunny, 26°C all afternoon.'));
      run.wrote.add('ans');
      s.ocRunEndedForTest(b.convId, list, run);
      final n = sent('notifyFrom');
      expect(n, hasLength(1));
      expect((n.single!['channel'], n.single!['title'], n.single!['body']), (NotifChannels.bots, 'Nova', 'Sunny, 26°C all afternoon.'));
    });

    test('Reply in SubMac\'s own notification answers as SubMac', () async {
      s.listsForTest['own3'] = <ChatMessage>[];
      await s.notificationReplyForTest('conv/own3', 'Also tomorrow?');
      await _settle();
      final run = started.single;
      final list = s.listsForTest['own3']!;
      list.add(ChatMessage(id: 'a', role: 'assistant', content: 'Tomorrow: dry, 22°C.'));
      run.wrote.add('a');
      s.ocRunEndedForTest('own3', list, run);
      expect(sent('notifyFrom').single!['title'], 'SubMac');
      expect(sent('notifyFrom').single!['channel'], NotifChannels.agent);
    });

    test('Reply in a team\'s notification goes to that team chat as the owner\'s message', () async {
      final o = Office(id: 'o-reply', name: 'Ops', members: [b.id], chiefId: b.id);
      Offices.I.offices.add(o);
      addTearDown(() => Offices.I.offices.remove(o));
      await s.notificationReplyForTest('office/o-reply', 'Ship it today');
      await _settle();
      expect(o.posts.any((p) => p.from == 'you' && p.text == 'Ship it today'), isTrue, reason: '${o.posts.map((p) => '${p.from}: ${p.text}')}');
      expect(started.where((r) => r.convId == b.convId), isEmpty, reason: 'never the bot\'s private chat');
    });

    test('team work with SubMac off screen follows the unattended rules (no approval card nobody can see)', () {
      final key = TeamKey.of('o9', b.id, job: TeamKey.job());
      expect(s.unattendedRun(key), isTrue);
      s.appVisible = true;
      expect(s.unattendedRun(key), isFalse, reason: 'the owner can answer in the app');
    });

    test('a reply to something unknown starts nothing', () async {
      await s.notificationReplyForTest('approvals', 'ok');
      await s.notificationReplyForTest('conv/', 'ok');
      expect(started, isEmpty);
    });
  });
}
