import 'dart:convert';
import 'dart:io';

import 'package:agent/services/opencode.dart';
import 'package:agent/services/submac_mcp.dart';
import 'package:flutter_test/flutter_test.dart';

/// Layer 1 of opencode + SubMac (owner, 2026-11-02): SubMac's MCP server, and opencode's permission and question
/// requests shown as SubMac's ask card. Proven against opencode 1.19.5 in the sandbox the same day (connected, a call
/// round trip, a 75 s call with the long timeout, a bash permission, a question).
void main() {
  group('Telesia MCP server', () {
    late SubMacMcp mcp;
    final calls = <String>[];
    setUp(() async {
      calls.clear();
      mcp = SubMacMcp(
        tools: () => [
          {
            'type': 'function',
            'function': {
              'name': 'remember',
              'description': 'Save a fact',
              'parameters': {
                'type': 'object',
                'properties': {
                  'text': {'type': 'string'}
                }
              }
            }
          },
          {'name': 'qibla', 'description': 'Direction', 'parameters': <String, dynamic>{}},
          {'name': 'remember', 'description': 'duplicate'},
        ],
        call: (name, args) async {
          calls.add('$name ${jsonEncode(args)}');
          if (name == 'qibla') return 'Error: no location';
          return 'saved ${args['text']}';
        },
      );
      await mcp.start();
    });
    tearDown(() => mcp.stop());

    Future<(int, dynamic)> post(Object body, {String? auth}) async {
      final c = HttpClient();
      try {
        final req = await c.postUrl(Uri.parse(mcp.url));
        req.headers.set('authorization', auth ?? 'Bearer ${mcp.token}');
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
        final res = await req.close();
        final text = await utf8.decoder.bind(res).join();
        return (res.statusCode, text.isEmpty ? null : jsonDecode(text));
      } finally {
        c.close(force: true);
      }
    }

    test('listens on 127.0.0.1 only, behind its token', () async {
      expect(mcp.url, startsWith('http://127.0.0.1:'));
      expect(mcp.token.length, 32);
      final (code, _) = await post({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'}, auth: 'Bearer wrong');
      expect(code, 401);
    });

    test('initialize answers the client\'s protocol version and offers tools', () async {
      final (code, j) = await post({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': {'protocolVersion': '2025-03-26', 'capabilities': {}, 'clientInfo': {'name': 'opencode', 'version': '1'}},
      });
      expect(code, 200);
      expect(j['result']['protocolVersion'], '2025-03-26');
      expect(j['result']['capabilities']['tools'], isNotNull);
      expect(j['result']['serverInfo']['name'], 'submac');
    });

    test('a notification gets 202 and no body', () async {
      final (code, j) = await post({'jsonrpc': '2.0', 'method': 'notifications/initialized'});
      expect(code, 202);
      expect(j, isNull);
    });

    test('tools/list: OpenAI and plain forms, an object schema each, no duplicates', () async {
      final (_, j) = await post({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'});
      final tools = j['result']['tools'] as List;
      expect(tools.map((t) => t['name']), ['remember', 'qibla']);
      expect(tools[0]['inputSchema']['properties']['text']['type'], 'string');
      expect(tools[1]['inputSchema'], {'type': 'object', 'properties': {}});
    });

    test('tools/call runs the Telesia tool and returns its text', () async {
      final (_, j) = await post({
        'jsonrpc': '2.0',
        'id': 3,
        'method': 'tools/call',
        'params': {
          'name': 'remember',
          'arguments': {'text': 'tea'}
        },
      });
      expect(j['result']['content'][0]['text'], 'saved tea');
      expect(j['result']['isError'], false);
      expect(calls, ['remember {"text":"tea"}']);
    });

    test('an error from the tool is marked as one; an unknown tool never runs', () async {
      final (_, a) = await post({'jsonrpc': '2.0', 'id': 4, 'method': 'tools/call', 'params': {'name': 'qibla'}});
      expect(a['result']['isError'], true);
      final (_, b) = await post({'jsonrpc': '2.0', 'id': 5, 'method': 'tools/call', 'params': {'name': 'bash'}});
      expect(b['result']['isError'], true);
      expect(calls, ['qibla {}']);
    });

    test('an unknown method is a JSON-RPC error', () async {
      final (_, j) = await post({'jsonrpc': '2.0', 'id': 6, 'method': 'sampling/createMessage'});
      expect(j['error']['code'], -32601);
    });
  });

  group('opencode asks on Telesia\'s card', () {
    late List<(String, String, String, List<String>)> shown;
    late List<(String, String)> permits;
    late List<(String, List<List<String>>?)> answers;
    String? next;

    OpenCodeAsks make() => OpenCodeAsks(
          ask: (conv, title, prompt, options) async {
            shown.add((conv, title, prompt, options));
            return next;
          },
          permit: (id, reply) async => permits.add((id, reply)),
          answer: (id, a) async => answers.add((id, a)),
          convOf: (s) => s == 'ses_1' ? 'chat-1' : null,
        );

    setUp(() {
      shown = [];
      permits = [];
      answers = [];
      next = null;
    });

    Map<String, dynamic> perm(String id) => {
          'type': 'permission.asked',
          'properties': {
            'id': id,
            'sessionID': 'ses_1',
            'permission': 'bash',
            'patterns': ['echo hi'],
            'metadata': {'command': 'echo hi'},
            'always': ['echo *'],
          },
        };

    test('Autopilot allows a permission once without a card', () async {
      final a = OpenCodeAsks(
        ask: (conv, title, prompt, options) async {
          shown.add((conv, title, prompt, options));
          return null;
        },
        permit: (id, reply) async => permits.add((id, reply)),
        answer: (id, ans) async => answers.add((id, ans)),
        convOf: (s) => 'chat-1',
        autopilot: () => true,
      );
      expect(await a.handle(perm('per_auto')), true);
      expect(shown, isEmpty);
      expect(permits, [('per_auto', 'once')]);
    });

    test('a command asks in its chat; Allow, Always allow and Deny map to once, always and reject', () async {
      final a = make();
      next = OpenCodeAsks.allow;
      expect(await a.handle(perm('per_1')), true);
      next = OpenCodeAsks.always;
      await a.handle(perm('per_2'));
      next = OpenCodeAsks.deny;
      await a.handle(perm('per_3'));
      next = null; // skipped
      await a.handle(perm('per_4'));
      expect((shown.first.$1, shown.first.$2, shown.first.$3), ('chat-1', 'Run this command?', 'echo hi'));
      expect(shown.first.$4, [OpenCodeAsks.allow, OpenCodeAsks.always, OpenCodeAsks.deny]);
      expect(permits, [('per_1', 'once'), ('per_2', 'always'), ('per_3', 'reject'), ('per_4', 'reject')]);
    });

    test('the same request is asked once', () async {
      final a = make();
      next = OpenCodeAsks.allow;
      await a.handle(perm('per_9'));
      expect(await a.handle(perm('per_9')), false);
      expect(permits.length, 1);
    });

    test('a question shows its choices and sends the label back; skipped rejects it', () async {
      final a = make();
      final q = {
        'type': 'question.asked',
        'properties': {
          'id': 'que_1',
          'sessionID': 'ses_1',
          'questions': [
            {
              'question': 'Pick a colour',
              'header': 'Colour',
              'options': [
                {'label': 'Red', 'description': 'r'},
                {'label': 'Blue', 'description': 'b'}
              ]
            }
          ],
        },
      };
      next = 'Blue';
      await a.handle(q);
      expect((shown.single.$1, shown.single.$2, shown.single.$3), ('chat-1', 'Pick a colour', ''));
      expect(shown.single.$4, ['Red', 'Blue']);
      expect(answers.single.$1, 'que_1');
      expect(answers.single.$2, [['Blue']]);
      next = null;
      await a.handle({...q, 'properties': {...q['properties'] as Map, 'id': 'que_2'}});
      expect(answers.last.$1, 'que_2');
      expect(answers.last.$2, isNull);
    });

    test('other events are left alone', () async {
      expect(await make().handle({'type': 'session.idle', 'properties': {'sessionID': 'ses_1'}}), false);
      expect(shown, isEmpty);
    });

    test('permission texts', () {
      expect(OpenCodeAsks.permissionText('external_directory', ['/sdcard/*'], {}).$1, 'Use files outside the workspace?');
      expect(OpenCodeAsks.permissionText('webfetch', [], {'url': 'https://a.b'}), ('Open this web page?', 'https://a.b'));
      expect(OpenCodeAsks.permissionText('lsp', ['x'], {}).$1, 'Allow lsp?');
    });
  });
}
