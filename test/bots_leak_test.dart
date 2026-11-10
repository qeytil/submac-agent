// Bots leak audit (owner, 2026-11-03: "there is leakages of bots on agent, investigate that"). Bots and the owner's
// chat all run on one opencode engine and reach Telesia's tools through the same two MCP tools, so every Telesia call
// must go to the turn that made it, and each turn must see only its own tools.
import 'dart:io';

import 'package:agent/models.dart';
import 'package:agent/services/mcp_routes.dart';
import 'package:agent/services/oc_scope.dart';
import 'package:agent/services/telesia_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _tool(String name) => {
      'type': 'function',
      'function': {'name': name, 'description': '$name tool', 'parameters': {'type': 'object'}},
    };

Map<String, dynamic> _part(String session, String id, String tool, Map<String, dynamic> input, {String status = 'running'}) => {
      'type': 'message.part.updated',
      'properties': {
        'part': {
          'id': id,
          'sessionID': session,
          'messageID': 'm1',
          'type': 'tool',
          'tool': tool,
          'callID': 'c-$id',
          'state': {'status': status, 'input': input},
        },
      },
    };

void main() {
  group('routing a Telesia call to the turn that made it', () {
    test('a run_tool call in the turn\'s own session routes to it; another session\'s does not', () async {
      final r = McpRoutes();
      final mine = {'sesBot'};
      r.watch(_part('sesBot', 'p1', 'telesia_run_tool', {'name': 'bot_remember', 'arguments': {'fact': 'x'}}), 'botConv', mine);
      r.watch(_part('sesMain', 'p2', 'telesia_run_tool', {'name': 'remember', 'arguments': {'fact': 'y'}}), 'botConv', mine);
      expect(r.openCount, 1);
      expect(await r.take('bot_remember', {'fact': 'x'}, wait: Duration.zero), 'botConv');
      expect(await r.take('remember', {'fact': 'y'}, wait: Duration.zero), isNull);
    });

    test('a subagent (child session) call routes to the chat whose turn started it', () async {
      final r = McpRoutes();
      final fam = {'sesMain'};
      r.watch({
        'type': 'session.created',
        'properties': {
          'info': {'id': 'sesChild', 'parentID': 'sesMain'},
        },
      }, 'mainConv', fam);
      expect(fam, contains('sesChild'));
      r.watch(_part('sesChild', 'p1', 'telesia_run_tool', {'name': 'browser_task', 'arguments': {'goal': 'g'}}), 'mainConv', fam);
      expect(await r.take('browser_task', {'goal': 'g'}, wait: Duration.zero), 'mainConv');
    });

    test('find_tools is routed too, so a lookup lists the caller\'s own tools', () async {
      final r = McpRoutes();
      r.watch(_part('s', 'p1', 'telesia_find_tools', {'query': 'office'}), 'botConv', {'s'});
      expect(await r.take('find_tools', {'query': 'office'}, wait: Duration.zero), 'botConv');
    });

    test('a "telesia_" prefix on the inner name routes the same as without it (the call is run without it)', () async {
      final r = McpRoutes();
      r.watch(_part('s', 'p1', 'telesia_run_tool', {'name': 'telesia_bot_followup', 'arguments': {'in_minutes': 20}}), 'seo', {'s'});
      final (n, a) = TelesiaGateway.inner({'name': 'telesia_bot_followup', 'arguments': {'in_minutes': 20}});
      expect(n, 'bot_followup');
      expect(await r.take(n, a, wait: Duration.zero), 'seo');
    });

    test('arguments sent as "parameters" are read (seen in a bot\'s office wake)', () {
      final (n, a) = TelesiaGateway.inner({'name': 'office_post', 'parameters': {'message': 'Hi'}});
      expect(n, 'office_post');
      expect(a, {'message': 'Hi'});
    });

    test('a pending part (no input yet) is not noted', () {
      final r = McpRoutes();
      r.watch(_part('s', 'p1', 'telesia_run_tool', {}, status: 'pending'), 'c', {'s'});
      expect(r.openCount, 0);
    });

    test('no route: the only turn running, never a guess between several', () {
      expect(McpRoutes.soleLive({'main'}), 'main');
      expect(McpRoutes.soleLive({'main', 'botConv'}), isNull);
      expect(McpRoutes.soleLive(<String>{}), isNull);
    });

    test('a subagent session asks in its root chat; a session of no chat asks nowhere', () {
      final convs = {'sesMain': 'mainConv'};
      final parent = {'sesChild': 'sesMain', 'sesGrand': 'sesChild'};
      expect(McpRoutes.rootConv('sesGrand', (s) => convs[s], parent), 'mainConv');
      expect(McpRoutes.rootConv('sesOther', (s) => convs[s], parent), isNull);
    });
  });

  group('each turn sees only its own tools', () {
    final app = [_tool('remember'), _tool('browser_task'), _tool('apps_run_tool')];
    final botOwn = [_tool('bot_remember'), _tool('bot_followup')];
    final office = [_tool('office_post')];

    test('the owner\'s chat gets no bot or team tools', () {
      final names = OcToolScope.of(app: app).map(OcToolScope.nameOf).toList();
      expect(names, ['remember', 'browser_task', 'apps_run_tool']);
      final g = TelesiaGateway(tools: () => OcToolScope.of(app: app), run: (n, a) async => 'ran $n');
      expect(g.find('bot followup'), isNot(contains('bot_followup')));
    });

    test('the main agent cannot run a bot tool through run_tool', () async {
      final g = TelesiaGateway(tools: () => OcToolScope.of(app: app), run: (n, a) async => 'ran $n');
      expect(await g.call('run_tool', {'name': 'bot_followup', 'arguments': {'in_minutes': 20, 'instruction': 'x'}}),
          startsWith('Error: no Telesia tool named "bot_followup"'));
    });

    test('a bot gets its own tools, office tools during office work, and the app\'s cut by its powers', () {
      final names = OcToolScope.of(app: app, botOwn: botOwn, office: office, allowed: (n) => n != 'browser_task')
          .map(OcToolScope.nameOf)
          .toList();
      expect(names, ['office_post', 'bot_remember', 'bot_followup', 'remember', 'apps_run_tool']);
    });
  });

  test('a finished run hands back its own last reply, never a thinking row or an older reply', () {
    final old = ChatMessage(id: 'old', role: 'assistant', content: 'an older answer');
    final think = ChatMessage(id: 't', role: 'assistant', content: 'thinking...', name: 'reasoning');
    final step = ChatMessage(id: 's', role: 'assistant', toolCalls: [ToolCall(id: 'c', name: 'x', arguments: '{}')]);
    final reply = ChatMessage(id: 'r', role: 'assistant', content: 'Done. @note');
    expect(OcRunEnd.replyOf([old, reply, think, step], {'r', 't', 's'}), 'Done. @note');
    expect(OcRunEnd.replyOf([old, think, step], {'t', 's'}), '');
  });

  test('source: no Telesia call or ask falls back to the chat on screen', () {
    final src = File('lib/state/agent_runner.dart').readAsStringSync();
    expect(src, isNot(contains('home ?? currentId')));
    expect(src, isNot(contains('conv.isEmpty ? (currentId')));
    expect(src, isNot(contains('b.convId.isEmpty ? currentId')));
    // The end-of-run step runs for every opencode run (bot wake outcomes, office replies, wake marks).
    expect(src, contains('_ocRunEnded(convId, list, run);'));
    // Bot and team tools are not in the app's list; they come only through _mcpTools for a bot or member.
    final app = src.substring(src.indexOf('List<Map<String, dynamic>> _ocAppTools()'), src.indexOf('List<Map<String, dynamic>> _mcpTools('));
    expect(app, isNot(contains('...Bots.definitions')));
    expect(app, isNot(contains('TeamRun.assignTool')));
  });
}
