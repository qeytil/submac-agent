// Bots team audit (owner, 2026-11-04): "bots in a team send their messages in both their private chat and the team
// chat", "there should be no chat and bot leakage", and "remove limits on how many bots can talk or work at the same
// time". Team work runs under its own route key (TeamKey) in its own opencode session and posts only to the team chat;
// nothing of one chat reaches another; nothing caps how many bots work at once.
import 'dart:io';

import 'package:agent/services/bots.dart';
import 'package:agent/services/mcp_routes.dart';
import 'package:agent/services/offices.dart';
import 'package:agent/services/opencode.dart';
import 'package:agent/services/team_key.dart';
import 'package:agent/services/team_run.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _part(String session, String id, String tool, Map<String, dynamic> input) => {
      'type': 'message.part.updated',
      'properties': {
        'part': {
          'id': id,
          'sessionID': session,
          'messageID': 'm1',
          'type': 'tool',
          'tool': tool,
          'callID': 'c-$id',
          'state': {'status': 'running', 'input': input},
        },
      },
    };

String _src(String path) => File(path).readAsStringSync();

String _between(String src, String from, String to) {
  final a = src.indexOf(from);
  expect(a, greaterThanOrEqualTo(0), reason: 'missing: $from');
  final b = src.indexOf(to, a + from.length);
  return src.substring(a, b < 0 ? src.length : b);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('team work has its own route key, never the private chat id', () {
    test('TeamKey names the team and the bot, with or without a job tag', () {
      final k = TeamKey.of('o17', 'b9');
      expect(k, 'team:o17:b9');
      expect(TeamKey.isKey(k), isTrue);
      expect(TeamKey.officeOf(k), 'o17');
      expect(TeamKey.botOf(k), 'b9');
      final j = TeamKey.of('o17', 'b9', job: TeamKey.job());
      expect(j, isNot(k));
      expect(TeamKey.officeOf(j), 'o17');
      expect(TeamKey.botOf(j), 'b9');
      expect(TeamKey.of('o17', 'b9', job: TeamKey.job()), isNot(j), reason: 'two jobs of one bot never share a key');
      for (final not in ['', 'team:', 'chat-123', '5f3a-uuid', 'team:x']) {
        expect(TeamKey.isKey(not), isFalse, reason: not);
        expect(TeamKey.botOf(not), '');
        expect(TeamKey.officeOf(not), '');
      }
    });

    test('a team key acts as its bot (powers, tools), and a private chat id still finds its bot', () {
      final b = Bot(id: 'tiso1', name: 'Nova', role: 'Researcher', persona: '')..convId = 'conv-nova';
      Bots.I.bots.add(b);
      addTearDown(() => Bots.I.bots.remove(b));
      expect(Bots.I.byConv(TeamKey.of('o1', 'tiso1', job: 'j1')), same(b));
      expect(Bots.I.byConv('conv-nova'), same(b));
      expect(Bots.I.byConv(TeamKey.of('o1', 'nobody')), isNull);
      expect(Bots.I.byConv('conv-other'), isNull);
    });
  });

  group('the private chat brief has no team work in it', () {
    test('team journal lines stay out of the 1:1 brief and in the team brief', () {
      final b = Bot(id: 'tiso2', name: 'Amal', role: 'Analyst', persona: '');
      b.log('work', 'Answered the owner about the budget');
      b.log('work', 'Team part for Coffee: compare supplier prices', team: true);
      b.log('work', 'Coffee: reply', team: true);
      final private = Bots.I.agentBriefOf(b);
      expect(private, contains('Answered the owner about the budget'));
      expect(private, isNot(contains('compare supplier prices')));
      expect(private, isNot(contains('Coffee: reply')));
      final team = Bots.I.agentBriefOf(b, team: true);
      expect(team, contains('compare supplier prices'));
      expect(team, contains('Answered the owner about the budget'));
    });

    test('the team mark survives saving', () {
      final e = JournalEntry(DateTime.utc(2026, 11, 4), 'work', 'Led Coffee: report', team: true);
      expect(JournalEntry.fromJson(e.toJson()).team, isTrue);
      expect(JournalEntry.fromJson(JournalEntry(DateTime.utc(2026), 'note', 'x').toJson()).team, isFalse);
      expect(JournalEntry(DateTime.utc(2026), 'note', 'x').toJson().containsKey('tm'), isFalse, reason: 'old format kept');
    });
  });

  group('engine events reach only their own turn', () {
    test('a session.error naming no session ends no turn', () {
      final main = OpenCodeTurn('sesMain'), bot = OpenCodeTurn('sesBot');
      final e = {
        'type': 'session.error',
        'properties': {
          'error': {'name': 'APIError', 'data': {'message': 'boom'}},
        },
      };
      expect(main.apply(e), isFalse);
      expect(bot.apply(e), isFalse);
      expect(main.error, isNull);
      expect(bot.error, isNull);
    });

    test('a session.error of another session ends only that session\'s turn', () {
      final main = OpenCodeTurn('sesMain'), bot = OpenCodeTurn('sesBot');
      final e = {
        'type': 'session.error',
        'properties': {
          'sessionID': 'sesBot',
          'error': {'name': 'APIError', 'data': {'message': 'quota'}},
        },
      };
      expect(main.apply(e), isFalse);
      expect(bot.apply(e), isTrue);
      expect(main.error, isNull);
      expect(bot.error, 'quota');
    });

    test('parts, deltas and idle of one session never land in another turn', () {
      final main = OpenCodeTurn('sesMain');
      main.apply({
        'type': 'message.part.updated',
        'properties': {
          'part': {'id': 'p1', 'sessionID': 'sesTeam', 'messageID': 'm', 'type': 'text', 'text': 'team result'},
        },
      });
      main.apply({
        'type': 'message.part.delta',
        'properties': {'sessionID': 'sesTeam', 'messageID': 'm', 'partID': 'p1', 'field': 'text', 'delta': 'more'},
      });
      main.apply({
        'type': 'session.idle',
        'properties': {'sessionID': 'sesTeam'},
      });
      expect(main.parts, isEmpty);
      expect(main.done, isFalse);
    });
  });

  group('Telesia calls route only to the turn that made them', () {
    test('a call from a session no running turn owns is refused, not run as the only live turn', () async {
      final r = McpRoutes();
      final owned = {'sesMain'};
      // A stopped bot turn's session still finishes a step after its turn ended.
      final e = _part('sesGone', 'p1', 'telesia_run_tool', {'name': 'bot_remember', 'arguments': {'fact': 'x'}});
      r.watchOrphans(e, owned.contains);
      r.watch(e, 'mainConv', owned);
      expect(await r.take('bot_remember', {'fact': 'x'}, wait: Duration.zero), McpRoutes.orphan);
      expect(McpRoutes.orphan, isEmpty);
    });

    test('a running turn\'s own calls, and its subagents\', are not orphans', () async {
      final r = McpRoutes();
      final fam = {'sesMain'};
      bool owned(String s) => fam.contains(s);
      final created = {
        'type': 'session.created',
        'properties': {
          'info': {'id': 'sesChild', 'parentID': 'sesMain'},
        },
      };
      r.watchOrphans(created, owned);
      r.watch(created, 'mainConv', fam);
      final e = _part('sesChild', 'p2', 'telesia_run_tool', {'name': 'browser_task', 'arguments': {'goal': 'g'}});
      r.watchOrphans(e, owned);
      r.watch(e, 'mainConv', fam);
      expect(await r.take('browser_task', {'goal': 'g'}, wait: Duration.zero), 'mainConv');
    });

    test('with several turns running, a call with other arguments never takes another turn\'s entry', () async {
      final r = McpRoutes();
      r.watch(_part('sesBot', 'p1', 'telesia_run_tool', {'name': 'remember', 'arguments': {'fact': 'bot fact'}}), 'botConv', {'sesBot'});
      expect(await r.take('remember', {'fact': 'main fact'}, wait: Duration.zero, fuzzy: false), isNull);
      expect(await r.take('remember', {'fact': 'bot fact'}, wait: Duration.zero, fuzzy: false), 'botConv');
    });

    test('alone, a call whose arguments changed on the way still finds its only entry', () async {
      final r = McpRoutes();
      r.watch(_part('s', 'p1', 'telesia_run_tool', {'name': 'remember', 'arguments': {'fact': 'a'}}), 'mainConv', {'s'});
      expect(await r.take('remember', {'fact': 'a '}, wait: Duration.zero), 'mainConv');
    });
  });

  group('the engine runs sessions side by side', () {
    test('it restarts for new settings only when no turn is working', () {
      expect(OpenCodeEngine.shouldRestart(stale: true, turnsInFlight: 0, appBusy: false), isTrue);
      expect(OpenCodeEngine.shouldRestart(stale: true, turnsInFlight: 1, appBusy: false), isFalse);
      expect(OpenCodeEngine.shouldRestart(stale: true, turnsInFlight: 0, appBusy: true), isFalse);
      expect(OpenCodeEngine.shouldRestart(stale: false, turnsInFlight: 0, appBusy: false), isFalse);
    });

    test('Telesia\'s MCP server is re-added only by a turn running alone', () {
      expect(OpenCodeEngine.mayResync(0), isTrue);
      expect(OpenCodeEngine.mayResync(1), isTrue);
      expect(OpenCodeEngine.mayResync(2), isFalse);
      expect(OpenCodeEngine.mayResync(5), isFalse);
    });

    test('ending a turn never goes below zero', () {
      final before = OpenCodeEngine.I.turnsInFlight;
      for (var i = 0; i < before + 2; i++) {
        OpenCodeEngine.I.endTurn();
      }
      expect(OpenCodeEngine.I.turnsInFlight, 0);
    });
  });

  group('no cap on bots working at once', () {
    final lead = Bot(id: 'tisl', name: 'Hodan', role: 'Manager', persona: '');
    final nova = Bot(id: 'tisn', name: 'Nova', role: 'Researcher', persona: '');
    final amal = Bot(id: 'tisa', name: 'Amal', role: 'Analyst', persona: '');
    final omar = Bot(id: 'tiso', name: 'Omar', role: 'Writer', persona: '');
    setUp(() {
      Bots.I.bots.addAll([lead, nova, amal, omar]);
      TeamRun.I
        ..reset()
        ..promptOf = ((b) => 'You are ${b.name}.')
        ..ask = (b, system, user, {int maxTokens = 0}) async {
          if (system.contains('# Plan for the owner')) {
            return '{"reply":"Go.","questions":[],"parts":[{"bot":"Nova","ask":"a"},{"bot":"Amal","ask":"b"},{"bot":"Omar","ask":"c"}]}';
          }
          if (system.contains('# Combine')) return 'Combined.';
          return '{"speaker":"Hodan","team_task":true}';
        };
    });
    tearDown(() {
      Bots.I.bots.removeWhere((b) => b.id.startsWith('tis'));
      Offices.I.offices.clear();
      TeamRun.I
        ..ocTurn = null
        ..reset();
    });

    test('parts the lead did not hand off all run at once, each with its own key', () async {
      var live = 0, peak = 0;
      final keys = <String>[];
      TeamRun.I.ocTurn = (b, key, system, task, {stopped, assign}) async {
        keys.add(key);
        if (assign != null) return ''; // the lead hands nothing off: the leftovers still run
        live++;
        peak = live > peak ? live : peak;
        await Future<void>.delayed(const Duration(milliseconds: 50));
        live--;
        return 'Hodan, done.\n---\nResult from ${b.name}.';
      };
      final o = Office(id: 'otis', name: 'Coffee', members: ['tisl', 'tisn', 'tisa', 'tiso'], chiefId: 'tisl');
      expect(TeamRun.I.startJob(o, 'Weekly report'), startsWith('Started'));
      await TeamRun.I.work;
      expect(peak, 3, reason: 'three members, three at once');
      expect(keys.toSet().length, keys.length);
      expect(keys.every(TeamKey.isKey), isTrue);
      expect(o.posts.last.kind, 'answer');
      expect(o.posts.last.parts.map((p) => p.from).toSet(), {'tisn', 'tisa', 'tiso'});
    });

    test('team work is logged as team work (kept out of the private chat brief)', () async {
      TeamRun.I.ocTurn = (b, key, system, task, {stopped, assign}) async {
        if (assign != null) return 'Lead answer.';
        return 'Hodan, done.\n---\nResult.';
      };
      final o = Office(id: 'otis2', name: 'Coffee', members: ['tisl', 'tisn', 'tisa', 'tiso'], chiefId: 'tisl');
      TeamRun.I.startJob(o, 'Weekly report');
      await TeamRun.I.work;
      expect(nova.journal.where((e) => e.text.startsWith('Team part for')).every((e) => e.team), isTrue);
      expect(nova.journal.any((e) => e.team), isTrue);
      expect(Bots.I.agentBriefOf(nova), isNot(contains('Team part for')));
    });

    test('a teammate\'s @mentions are no longer capped per hour; a chain of bot turns stops at its depth', () async {
      SharedPreferences.setMockInitialValues({});
      final o = Office(id: 'otis3', name: 'Coffee', members: ['tisl', 'tisn'], chiefId: 'tisl');
      Offices.I.offices.add(o);
      Offices.I.queue.clear();
      for (var i = 0; i < 9; i++) {
        final r = await Offices.I.execute('office_post', {'text': '@Nova check $i'}, o, lead, job: 'task');
        expect(r, contains('1 teammate'), reason: 'mention $i');
        // The lead handing work over starts the assignee's turn (owner 2026-11-06: "assigned bots stayed silent").
        expect(Offices.I.queue.where((j) => j.kind == 'assign' && j.botId == 'tisn'), hasLength(1));
        Offices.I.queue.clear();
      }
      // Two bots can no longer wake each other without end: a turn deep in a chain wakes nobody (TeamReact.maxDepth).
      Offices.I.jobOf = (id, officeId) => (kind: 'mention', depth: 4, cause: 'tisn');
      addTearDown(() => Offices.I.jobOf = null);
      final r = await Offices.I.execute('office_post', {'text': '@Nova again'}, o, lead, job: 'mention');
      expect(r, 'Posted.');
      expect(Offices.I.queue, isEmpty);
    });

    test('source: no concurrency cap in teams, offices or wakes', () {
      final team = _src('lib/services/team_run.dart');
      expect(team, isNot(contains('static const parallel')));
      expect(team, isNot(contains('working >= parallel')));
      final app = _src('lib/app_state.dart');
      expect(app, isNot(contains('_officeParallel')));
      final ctl = _src('lib/state/bots_controller.dart');
      final pump = _between(ctl, 'void _officePump()', '/// Tasks marked');
      expect(pump, isNot(contains('_officeBusy.length')));
      expect(pump, isNot(contains('_officeBusy.contains(b.id)')));
      expect(pump, isNot(contains('runsLeft')), reason: 'no daily cap on team work');
      expect(pump, isNot(contains('runs.any((r) => r.convId == b.convId')), reason: 'a bot chatting with the owner still does team work');
      expect(_src('lib/services/offices.dart'), isNot(contains('_mentionAllowed')));
      expect(_src('lib/services/bots.dart'), isNot(contains('officeBusy')));
    });
  });

  group('source: team work stays out of the private chat', () {
    final ctl = _src('lib/state/bots_controller.dart');
    final runner = _src('lib/state/agent_runner.dart');
    final router = _src('lib/state/tool_router.dart');
    final phone = _src('lib/state/system_phone.dart');

    test('an office job is a team turn under its own key, posted to the team chat only', () {
      final run = _between(ctl, 'Future<void> _officeRun(', 'Future<void> _dropWakeTurn(');
      expect(run, contains('TeamKey.of(o.id, b.id'));
      expect(run, contains('await teamTurn(b, key'));
      expect(run, isNot(contains('startBackgroundTask')), reason: 'it used to run as a wake inside the bot\'s private chat');
      expect(run, isNot(contains('reuseConvId')));
      expect(run, isNot(contains('_rewrite(')));
      expect(run, isNot(contains('_lists[')));
      expect(run, isNot(contains('_officeCtx[convId]')));
      expect(run, contains('Offices.I.post(o, b.id'));
    });

    test('a team turn runs on Telesia\'s bot engine under its key, not the member\'s chat', () {
      final tt = _between(runner, 'Future<String> teamTurn(', 'Future<String?> _teamPermission(');
      expect(tt, contains('BotAgentEngine('));
      expect(tt, contains('BotBrowserModel.of(b, telesiaRef)'));
      expect(tt, contains('convId: key'));
      expect(tt, isNot(contains('OpenCodeEngine')), reason: 'team work no longer runs on opencode');
      expect(tt, isNot(contains('newSession(')), reason: 'team work opens no opencode session');
      expect(tt, isNot(contains('b.convId')));
      expect(tt, isNot(contains('_teamConv')), reason: 'member asks used to land in the "Telesia team" chat');
      expect(tt, contains('teamLive[key]'));
      expect(runner, contains('if (TeamKey.isKey(convId)) return;'), reason: 'no team key ever runs as a chat turn');
      final routed = _between(runner, 'Future<String> _runRouted(', 'String _screenLabel(');
      expect(routed, contains('runToolWithApproval(name, args, convId: conv)'));
      expect(routed, isNot(contains('convId: home')));
      expect(runner, contains('if (TeamKey.isKey(conv)) return _teamPermission('));
      expect(runner, contains('_routes.watchOrphans(e, _ocOwned)'));
      expect(runner, contains('fuzzy: _ocLive.length <= 1'));
    });

    test('team asks never wait on a card in a chat; team approvals name their team', () {
      final ask = _between(router, 'Future<Map<String, String>?> askUser(UserAsk a) {', 'void answerAsk(');
      expect(ask, contains('if (TeamKey.isKey(a.convId)) return'));
      expect(router, contains('_officeCtx[convId] ?? TeamKey.officeOf(convId)'));
    });

    test('a team\'s stop no longer stops the members\' private chats', () {
      final stop = _between(phone, 'Offices.I.stopRunning = (officeId) {', '};');
      expect(stop, isNot(contains('stopRun(')));
      expect(stop, isNot(contains('bot.convId')));
    });

    test('office tools are offered only under a team key, never in a bot\'s private chat', () {
      final tools = _between(runner, 'List<Map<String, dynamic>> _mcpTools(', 'Future<void> _bgNeeds(');
      expect(tools, contains('office: teamKey && _officeCtx.containsKey(conv)'));
      expect(tools, contains('if (teamKey && _teamAssign.containsKey(conv)) TeamRun.assignTool'));
    });
  });
}
