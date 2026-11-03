// A SubMac tool call from opencode goes to the chat (or team member) that made it, never another (2026-11-03).
import 'package:agent/services/mcp_routes.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('two chats running the same tool at once each get their own call', () async {
    final r = McpRoutes();
    r.note('bot_remember', {'fact': 'A likes tea'}, 'chatA', part: 'p1');
    r.note('bot_remember', {'fact': 'B likes coffee'}, 'chatB', part: 'p2');
    expect(await r.take('bot_remember', {'fact': 'B likes coffee'}), 'chatB');
    expect(await r.take('bot_remember', {'fact': 'A likes tea'}), 'chatA');
    expect(r.openCount, 0);
  });

  test('key order and whole numbers do not matter', () async {
    final r = McpRoutes();
    r.note('bot_desk', {'action': 'add', 'n': 2, 'meta': {'b': 1, 'a': 2}}, 'c1', part: 'p');
    expect(await r.take('bot_desk', {'meta': {'a': 2, 'b': 1}, 'n': 2.0, 'action': 'add'}), 'c1');
  });

  test('a part is noted once however many updates it gets', () async {
    final r = McpRoutes();
    for (var i = 0; i < 5; i++) {
      r.note('x', {'a': 1}, 'c1', part: 'same');
    }
    expect(r.openCount, 1);
  });

  test('the event may arrive just after the call', () async {
    final r = McpRoutes();
    final f = r.take('x', {'a': 1});
    await Future<void>.delayed(const Duration(milliseconds: 120));
    r.note('x', {'a': 1}, 'late', part: 'p');
    expect(await f, 'late');
  });

  test('no match: null (the caller uses the open chat); ambiguous calls are never guessed', () async {
    final r = McpRoutes();
    r.note('x', {'a': 1}, 'c1', part: 'p1');
    r.note('x', {'a': 2}, 'c2', part: 'p2');
    expect(await r.take('x', {'a': 3}, wait: const Duration(milliseconds: 10)), isNull);
    expect(await r.take('y', {}, wait: const Duration(milliseconds: 10)), isNull);
  });

  test('old entries expire and the table is capped (no leak)', () async {
    var now = DateTime(2026, 11, 3, 12);
    final r = McpRoutes(clock: () => now, max: 5);
    for (var i = 0; i < 20; i++) {
      r.note('x', {'i': i}, 'c', part: 'p$i');
    }
    expect(r.openCount, lessThanOrEqualTo(6));
    now = now.add(const Duration(minutes: 11));
    r.note('y', {}, 'c', part: 'fresh');
    expect(r.openCount, 1);
  });
}
