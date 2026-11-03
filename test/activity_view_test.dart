// Owner 2026-11-03: the chat stays quiet while opencode works (one working line); the turn's work opens on tap,
// sorted into Thinking, Tools run and Notes. Same in bots' chats (one chat view for both).
import 'dart:io';

import 'package:agent/models.dart';
import 'package:agent/widgets/chat/activity_groups.dart';
import 'package:agent/widgets/chat/activity_panel.dart';
import 'package:flutter_test/flutter_test.dart';

ChatMessage a(String id, {String text = '', String? name, List<ToolCall>? calls}) =>
    ChatMessage(id: id, role: 'assistant', content: text, name: name, toolCalls: calls);

void main() {
  final turn = [
    a('t1', name: 'reasoning', text: 'Let me look at the repo.'),
    a('n1', text: 'Checking the files first.'),
    a('c1', calls: [ToolCall(id: 'k1', name: 'read', arguments: '{}')]),
    ChatMessage(id: 'r1', role: 'tool', toolCallId: 'k1', name: 'read', content: 'ok'),
    a('t2', name: 'reasoning', text: 'Now the fix.'),
    a('c2', calls: [ToolCall(id: 'k2', name: 'edit', arguments: '{}'), ToolCall(id: 'k3', name: 'bash', arguments: '{}')]),
    a('ans', text: 'Done: fixed the bug.'),
  ];

  test('a turn sorts into thinking, tools and notes; the answer is none of them', () {
    final g = ActivityGroups.of(turn);
    expect(g.thinking.map((m) => m.id), ['t1', 't2']);
    expect(g.tools.map((t) => t.$2.id), ['k1', 'k2', 'k3']);
    expect(g.notes.map((m) => m.id), ['n1']);
    expect(g.summary(), '2 thoughts · 3 tools · 1 note');
    expect(ActivityGroups.folds(turn, 6), isFalse, reason: 'the answer stays in the chat');
    expect(ActivityGroups.folds(turn, 1), isTrue);
    expect(ActivityGroups.folds(turn, 0), isTrue);
  });

  test('failed tools are counted; the folded line reads plainly', () {
    final g = ActivityGroups.of(turn);
    final res = {'k1': ChatMessage(id: 'x', role: 'tool', content: 'Error: nope')};
    expect(g.failed(res), 1);
    expect(ActivityFold.head(g, const Duration(seconds: 72)), 'Worked for 1m 12s');
    expect(ActivityFold.head(g, null), 'Worked');
  });

  test('a plain reply has no activity', () {
    expect(ActivityGroups.of([a('x', text: 'Hi')]).isEmpty, isTrue);
  });

  test('quiet by default: no every-step chat, the working line opens to the activity', () {
    expect(File('lib/state/settings_store.dart').readAsStringSync(), contains('bool get showSteps => false;'));
    final home = File('lib/screens/home_screen.dart').readAsStringSync();
    expect(home, contains('activity: showStepsNow ? null : turnGroups'));
    expect(home, contains('ActivityFold('));
    expect(File('lib/widgets/composer.dart').readAsStringSync(), contains('ActivityPanel(groups: act'));
  });
}
