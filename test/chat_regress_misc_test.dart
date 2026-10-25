import 'package:agent/services/chat_search.dart';
import 'package:agent/services/mcp_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// PR-11 fix/chat-misc: CB-32 (menu search reads message text) and CB-33 (MCP tool names don't collide at 64).

Map<String, dynamic> _row(String role, String content) => {'role': role, 'content': content, 'created_at': '2026-10-25T10:00:00Z'};

void main() {
  group('CB-32 chat search finds words inside chats', () {
    final chats = <String, List<Map<String, dynamic>>>{
      'a': [_row('user', 'Plan my trip to Hargeisa'), _row('assistant', 'Here is a plan.\nDay 1: the Laas Geel caves.\nDay 2: market.')],
      'b': [_row('user', 'Recipe for bariis'), _row('tool', 'laas geel appears only in tool output')],
      'c': [_row('system', 'Laas Geel in the system prompt'), _row('user', 'hello')],
    };
    Future<List<Map<String, dynamic>>?> rows(String id) async => chats[id];

    test('a body match is found, with the matching line', () async {
      final hits = await ChatSearch(rows).search(['a', 'b', 'c', 'missing'], 'laas geel');
      expect(hits.keys, ['a']);
      expect(hits['a'], 'Day 1: the Laas Geel caves.');
    });

    test('tool output and system rows are not searched', () async {
      final hits = await ChatSearch(rows).search(['b', 'c'], 'laas');
      expect(hits, isEmpty);
    });

    test('one letter does not read chats', () async {
      var reads = 0;
      final hits = await ChatSearch((id) async {
        reads++;
        return chats[id];
      }).search(['a', 'b'], 'a');
      expect(hits, isEmpty);
      expect(reads, 0);
    });

    test('at most 200 chats are read, newest first as given', () async {
      final read = <String>[];
      final ids = [for (var i = 0; i < 300; i++) 'c$i'];
      final hits = await ChatSearch((id) async {
        read.add(id);
        return [_row('user', 'needle in $id')];
      }).search(ids, 'needle');
      expect(read.length, ChatSearch.cap200);
      expect(read.first, 'c0');
      expect(hits.length, 200);
      expect(hits.containsKey('c250'), isFalse);
    });

    test('a long line is cut around the match, and reply quotes are skipped', () {
      final long = '${'word ' * 40}the secret phrase ${'tail ' * 40}';
      final line = ChatSearch.matchLine([_row('assistant', long)], 'secret phrase')!;
      expect(line, contains('secret phrase'));
      expect(line.length, lessThanOrEqualTo(82));
      expect(line.startsWith('…'), isTrue);
      final quoted = '[Reply to SubMac · #m1]\n> zebra stripes\n\nthanks';
      expect(ChatSearch.matchLine([_row('user', quoted)], 'zebra'), isNull);
      expect(ChatSearch.matchLine([_row('user', quoted)], 'thanks'), 'thanks');
    });

    test('a chat that fails to load is skipped', () async {
      final hits = await ChatSearch((id) async => id == 'bad' ? throw StateError('broken file') : chats[id]).search(['bad', 'a'], 'market');
      expect(hits.keys, ['a']);
    });
  });

  group('CB-33 MCP tool names', () {
    final server = McpServerConfig(id: 's1', name: 'Composio', url: 'https://x.example/mcp');
    McpTool tool(String n) => McpTool(server, n, '', const {});

    test('two long names that share their first 64 characters stay different', () {
      const base = 'GOOGLESHEETS_BATCH_UPDATE_VALUES_BY_DATA_FILTER_AND_RANGE';
      final a = tool('${base}_FOR_SPREADSHEET');
      final b = tool('${base}_FOR_WORKSHEET');
      final oldA = 'mcp_${server.slug}__${a.name}'.substring(0, 64);
      final oldB = 'mcp_${server.slug}__${b.name}'.substring(0, 64);
      expect(oldA, oldB, reason: 'the old cut made these identical');
      expect(a.fnName, isNot(b.fnName));
      expect(a.fnName.length, 64);
      expect(b.fnName.length, 64);
      expect(a.fnName, matches(RegExp(r'^mcp_composio__[A-Za-z0-9_-]+_[0-9a-f]{8}$')));
      expect(a.fnName.substring(0, 55), oldA.substring(0, 55));
    });

    test('the name is stable, and the definition uses it', () {
      final a = tool('${'X' * 70}_ONE');
      expect(a.fnName, tool('${'X' * 70}_ONE').fnName);
      expect((a.toDefinition()['function'] as Map)['name'], a.fnName);
    });

    test('short names are unchanged', () {
      expect(tool('search_docs').fnName, 'mcp_composio__search_docs');
      expect(tool('get.page').fnName, 'mcp_composio__get_page');
      final exactly64 = 'T' * (64 - 'mcp_composio__'.length);
      expect(tool(exactly64).fnName, 'mcp_composio__$exactly64');
    });

    test('dispatch finds each tool by its own name', () {
      final tools = [tool('${'A' * 60}_READ'), tool('${'A' * 60}_WRITE')];
      for (final t in tools) {
        expect(tools.where((e) => e.fnName == t.fnName).single.name, t.name);
      }
    });
  });
}
