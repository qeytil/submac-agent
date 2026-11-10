// Owner 2026-11-10: a full window never costs the user their chat — the older part is folded into a summary
// before the window runs out, the chat keeps that summary as one quiet note, and opening the note's group shows
// it. These are the pure rules (no engine, no widgets).
import 'package:agent/models.dart';
import 'package:agent/services/chat_compact.dart';
import 'package:agent/services/context_window.dart';
import 'package:agent/widgets/chat/activity_groups.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the chat folds before the window is full, at any size', () {
    expect(ChatCompact.due(used: 0, window: 128000), isFalse, reason: 'nothing was read yet');
    expect(ChatCompact.due(used: 90000, window: 128000), isFalse);
    expect(ChatCompact.due(used: ContextWindow.compactAtFor(128000), window: 128000), isTrue);
    expect(ChatCompact.due(used: 700000, window: 1000000), isFalse, reason: 'a 1M window folds near its own limit');
    expect(ChatCompact.due(used: ContextWindow.compactAtFor(1000000), window: 1000000), isTrue);
    expect(ContextWindow.compactAtFor(1000000) > ContextWindow.compactAtFor(128000), isTrue);
  });

  test('the mark is the quiet row the chat already reads', () {
    final m = ChatCompact.mark(id: 'c1', covers: 'a9', summary: 'Earlier: we renamed the app to Telesia.');
    expect(m.role, 'system');
    expect(m.name, 'compact:a9', reason: 'the name carries the last covered message');
    expect(m.content, contains('Telesia'));
    expect(ChatCompact.coversIn([
      ChatMessage(id: 'u1', role: 'user', content: 'hi'),
      ChatMessage(id: 'a1', role: 'assistant', content: 'hello'),
      m,
    ]), 'a1', reason: 'a new mark never covers another mark');
    expect(ChatCompact.coversIn(const []), isNull);
  });

  test('the engine summary is read from its own session messages', () {
    final body = [
      {'info': {'id': 'u1', 'role': 'user', 'sessionID': 's'}, 'parts': []},
      {
        'info': {'id': 'a1', 'role': 'assistant', 'sessionID': 's', 'summary': true},
        'parts': [
          {'type': 'text', 'text': 'First part.'},
          {'type': 'text', 'text': 'Second part.'},
        ],
      },
    ];
    expect(ChatCompact.summaryIn(body), 'First part.\n\nSecond part.');
    expect(ChatCompact.summaryIn([
      {'info': {'role': 'assistant', 'summary': false}, 'parts': []}
    ]), isNull);
    expect(ChatCompact.summaryIn(null), isNull);
  });

  test('a compact note folds into the turn: the group counts it and keeps its words', () {
    final g = ActivityGroups.of([
      ChatMessage(id: 't1', role: 'assistant', name: 'reasoning', content: 'Looking...'),
      ChatMessage(id: 'c1', role: 'system', name: 'compact:u1', content: 'Earlier: the app was renamed.'),
    ]);
    expect(g.compacts.map((m) => m.id), ['c1']);
    expect(g.summary(), '1 thought · 1 compact');
    expect(ActivityGroups.of([
      ChatMessage(id: 'c9', role: 'system', name: 'compact:u1', content: '   '),
    ]).compacts, isEmpty, reason: 'an empty note never shows');
  });
}
