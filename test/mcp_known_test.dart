// 2026-11-03: the agent could not connect the owner's Composio account. It guessed dead or wrong addresses and sent
// the consumer key as a Bearer token; failed tries stayed in Apps; Composio's and Canva's tools past the 8-tool cap
// could not be found or run from opencode.
import 'dart:io';

import 'package:agent/services/mcp_known.dart';
import 'package:agent/services/mcp_oauth.dart';
import 'package:agent/services/submac_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a Composio consumer key goes to Connect in x-consumer-api-key, whatever address the model guessed', () {
    for (final guess in [
      'https://mcp.composio.dev',
      'https://mcp.composio.dev/mcp',
      'https://backend.composio.dev/mcp',
      'https://backend.composio.dev/api/v3.1/tool_router/session',
      'https://composio.dev/mcp',
      'https://connect.composio.dev/mcp',
    ]) {
      final f = McpKnown.fix(guess, 'ck_abc123', '');
      expect(f.url, McpKnown.composioConnect, reason: guess);
      expect(f.header, 'x-consumer-api-key', reason: guess);
    }
  });

  test('a project key keeps its generated server and uses x-api-key', () {
    const gen = 'https://backend.composio.dev/v3/mcp/abcd-1234-ef?user_id=u1';
    final f = McpKnown.fix(gen, 'ak_xyz', '');
    expect(f.url, gen);
    expect(f.header, 'x-api-key');
  });

  test('Composio with no key goes to Connect (its own sign-in); other servers are untouched', () {
    expect(McpKnown.fix('https://mcp.composio.dev', '', '').url, McpKnown.composioConnect);
    final other = McpKnown.fix('https://mcp.linear.app/mcp', 'lin_123', '');
    expect(other.url, 'https://mcp.linear.app/mcp');
    expect(other.header, '');
  });

  test('add_mcp_server: a failed try is not left in Apps and never reads as connected', () {
    final src = File('lib/state/connectors.dart').readAsStringSync();
    expect(src, contains('McpKnown.fix('));
    expect(src, contains('Nothing was saved'));
    expect(src, contains('await deleteMcpServer(s.id)'));
    expect(src, isNot(contains('submac_apps_list_tools')));
  });

  test('opencode can find and run every app tool (no 8-tool cap)', () {
    final src = File('lib/state/agent_runner.dart').readAsStringSync();
    expect(src, contains('..._mcpToolDefs(all: true)'));
  });

  test('run_tool forgives the submac_ prefix models add', () async {
    final ran = <String>[];
    final g = SubMacGateway(
        tools: () => [
              {
                'type': 'function',
                'function': {'name': 'apps_list_tools', 'parameters': {'type': 'object'}}
              }
            ],
        run: (n, a) async {
          ran.add(n);
          return 'ok';
        });
    expect(await g.call('run_tool', {'name': 'submac_apps_list_tools', 'arguments': {}}), 'ok');
    expect(ran, ['apps_list_tools']);
  });

  test('Composio is an app in Apps: paste the key, nothing else', () {
    final pr = McpOAuth.presetFor('composio')!;
    expect(pr.url, McpKnown.composioConnect);
    expect(pr.needsKey, isTrue);
    expect(pr.keyHeader, 'x-consumer-api-key');
    expect(pr.signIn, isFalse);
    final other = McpOAuth.presetFor('notion')!;
    expect(other.needsKey, isFalse);
    final src = File('lib/state/connectors.dart').readAsStringSync();
    expect(src, contains('pr.needsKey ? connectMcpKey(pr'));
    expect(File('lib/screens/connectors_screen.dart').readAsStringSync(), contains('askAppKey(context, pr)'));
    expect(File('lib/widgets/ask_bar.dart').readAsStringSync(), contains('askAppKey(context, pr)'));
  });
}
