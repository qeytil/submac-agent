// Layer 2/3 (2026-11-03): the browser and phone control reach the owner's chat through Telesia's MCP tools (a bot's
// engine turn is offered them by name); only one chat, bot or team member drives the phone's screen at a time.
import 'dart:io';

import 'package:agent/services/screen_lease.dart';
import 'package:agent/services/telesia_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('one driver at a time; the holder keeps going; another gets a plain "in use"', () {
    var now = DateTime(2026, 11, 3, 13);
    final l = ScreenLease(clock: () => now);
    expect(l.take('chatA', label: 'Telesia'), isNull);
    expect(l.take('chatA'), isNull);
    final no = l.take('team:o1:b2', label: 'Nova');
    expect(no, startsWith('Error: the phone screen is in use'));
    now = now.add(const Duration(seconds: 30));
    expect(l.take('team:o1:b2'), isNotNull);
    l.release('chatA');
    expect(l.take('team:o1:b2'), isNull, reason: 'free once the holder\'s turn ended');
  });

  test('a holder that went quiet loses the screen (no stuck lock)', () {
    var now = DateTime(2026, 11, 3, 13);
    final l = ScreenLease(clock: () => now);
    l.take('a');
    now = now.add(const Duration(minutes: 2));
    expect(l.take('b'), isNull);
    expect(l.holder, 'b');
    l.release('a');
    expect(l.holder, 'b', reason: 'an old holder releasing does not free someone else\'s lease');
  });

  test('only screen-driving tools take the lease', () {
    expect(ScreenLease.drives('phone_tap'), isTrue);
    expect(ScreenLease.drives('phone_screen'), isTrue);
    expect(ScreenLease.drives('whatsapp'), isTrue);
    expect(ScreenLease.drives('browser_task'), isFalse, reason: 'the browser runs in its own view, not on the screen');
    expect(ScreenLease.drives('set_alarm'), isFalse);
  });

  test('opencode is offered the browser agent and phone control (behind "Let it take action")', () {
    final src = File('lib/state/agent_runner.dart').readAsStringSync();
    // The app's tool list is _ocAppTools since the bots leak audit (2026-11-03); _mcpTools scopes it per caller.
    final tools = src.substring(src.indexOf('_ocAppTools() => ['), src.indexOf('List<Map<String, dynamic>> _mcpTools('));
    expect(tools, contains('if (agentEnabled) ...['));
    expect(tools, contains('...BrowserJobs.definitions'));
    expect(tools, contains('...PhoneTools.definitions'));
    expect(tools, contains('SystemTools.definitions()'));
    expect(tools, contains('WhatsAppTools.definition'));
    expect(TelesiaGateway.skill, contains('browser_task'));
    expect(TelesiaGateway.skill, contains('phone_screen'));
  });

  test('a team member\'s browser job is not cancelled just because it has no chat run', () {
    final src = File('lib/state/tool_router.dart').readAsStringSync();
    expect(src, contains('AppStateAgentRunner.teamLive[convId]'));
  });
}
