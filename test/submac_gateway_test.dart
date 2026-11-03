import 'dart:convert';

import 'package:agent/services/submac_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> fn(String n, String d) => {
      'type': 'function',
      'function': {'name': n, 'description': d, 'parameters': {'type': 'object', 'properties': {}}},
    };

void main() {
  final ran = <String>[];
  final g = SubMacGateway(
    tools: () => [fn('remember', 'Save a fact to memory.'), fn('read_pdf', 'Read a PDF file.'), fn('apps_run_tool', 'Run a connected app action like Gmail send.')],
    run: (n, a) async {
      ran.add('$n ${jsonEncode(a)}');
      return 'ok $n';
    },
  );

  test('only two tools are offered', () {
    expect(SubMacGateway.definitions.map((t) => (t['function'] as Map)['name']), ['find_tools', 'run_tool']);
  });

  test('find ranks by name and description; empty lists every name', () async {
    final r = jsonDecode(await g.call('find_tools', {'query': 'gmail send'})) as List;
    expect(r.first['name'], 'apps_run_tool');
    expect(r.first['parameters'], isA<Map>());
    final all = await g.call('find_tools', {});
    expect(all, contains('- remember:'));
    expect(all, contains('- read_pdf:'));
    expect(await g.call('find_tools', {'query': 'zzz'}), startsWith('No SubMac tool'));
  });

  test('run runs the named tool with its arguments (object or JSON text); unknown names never run', () async {
    expect(await g.call('run_tool', {'name': 'remember', 'arguments': {'text': 'hi'}}), 'ok remember');
    expect(await g.call('run_tool', {'name': 'read_pdf', 'arguments': '{"path":"a.pdf"}'}), 'ok read_pdf');
    expect(ran, ['remember {"text":"hi"}', 'read_pdf {"path":"a.pdf"}']);
    expect(await g.call('run_tool', {'name': 'nope'}), startsWith('Error: no SubMac tool'));
    expect(await g.call('run_tool', {}), startsWith('Error: name is required'));
    expect(ran.length, 2);
  });

  test('the skill names the two MCP tools', () {
    expect(SubMacGateway.skill, contains('name: submac'));
    expect(SubMacGateway.skill, contains('submac_find_tools'));
    expect(SubMacGateway.skill, contains('submac_run_tool'));
  });
}
