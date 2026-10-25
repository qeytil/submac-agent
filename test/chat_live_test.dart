import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart' show TextDirection;
import 'package:agent/app_state.dart';
import 'package:agent/models.dart';
import 'package:agent/widgets/message_view.dart';

/// The live chat: plain step labels, quiet progress lines, right-to-left text and the folded step list.
void main() {
  test('Arabic text reads right to left; Somali and English left to right', () {
    expect(textDirOf('مرحبا، كيف حالك؟'), TextDirection.rtl);
    expect(textDirOf('  1. السلام عليكم'), TextDirection.rtl);
    expect(textDirOf('Iska warran, maxaan kuu qabtaa?'), TextDirection.ltr);
    expect(textDirOf('Hello مرحبا'), TextDirection.ltr);
    expect(textDirOf('123'), TextDirection.ltr);
  });

  test('progress lines show only when they read like a person', () {
    expect(plainNarration('Checking Friday flights to Nairobi.'), isTrue);
    expect(plainNarration('Waxaan hubinayaa duulimaadyada Jimcaha.'), isTrue);
    expect(plainNarration('Now I will tap [3] to open it.'), isFalse);
    expect(plainNarration('Calling browser_task with the goal'), isFalse);
    expect(plainNarration('Let me call the tool.'), isFalse);
    expect(plainNarration('{"query": "x"}'), isFalse);
    expect(plainNarration('Opening https://example.com'), isFalse);
  });

  test('failed steps are recognised', () {
    expect(AppState.stepFailed('Error: timed out'), isTrue);
    expect(AppState.stepFailed('The user said no.'), isTrue);
    expect(AppState.stepFailed('exit_code: 1\nnope'), isTrue);
    expect(AppState.stepFailed('exit_code: 0\nok'), isFalse);
    expect(AppState.stepFailed('Results: ...'), isFalse);
  });

  test('several lookups at once get one plain line', () {
    ToolCall c(String n) => ToolCall(id: n, name: n, arguments: '{}');
    expect(AppState.groupLabel([c('fetch_url'), c('fetch_url'), c('fetch_url')]), 'Reading 3 pages');
    expect(AppState.groupLabel([c('web_search'), c('web_search')]), 'Searching the web (2 searches)');
    expect(AppState.groupLabel([c('web_search'), c('fetch_url')]), 'Searching and reading 2 sources');
    expect(AppState.groupLabel([c('read_file'), c('list_dir')]), 'Reading 2 files');
    expect(AppState.groupLabel([c('get_weather'), c('prayer_times')]), 'Checking 2 things at once');
  });

  test('the status line remembers when it changed', () async {
    final r = AgentRun(convId: 'c', side: false, title: 't');
    final t0 = r.statusAt;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    r.status = 'Thinking';
    expect(r.statusAt, t0, reason: 'same text keeps its time');
    r.status = 'Searching the web';
    expect(r.statusAt.isAfter(t0), isTrue);
    final s = RunStep('Searching the web');
    expect(s.done, isFalse);
    s.ended = DateTime.now();
    expect(s.done, isTrue);
  });

  test('the folded step list covers only the last task, in order, without say', () {
    final msgs = <ChatMessage>[
      ChatMessage(id: 'u0', role: 'user', content: 'old'),
      ChatMessage(id: 'a0', role: 'assistant', toolCalls: [ToolCall(id: 'x', name: 'web_search', arguments: '{"query":"old"}')]),
      ChatMessage(id: 'u1', role: 'user', content: 'find it'),
      ChatMessage(id: 'a1', role: 'assistant', content: 'Looking now.', toolCalls: [
        ToolCall(id: 's', name: 'say', arguments: '{"text":"hi"}'),
        ToolCall(id: 'w', name: 'web_search', arguments: '{"query":"flights"}'),
      ]),
      ChatMessage(id: 'a2', role: 'assistant', toolCalls: [ToolCall(id: 'm', name: 'make_document', arguments: '{"kind":"docx"}')]),
      ChatMessage(id: 'a3', role: 'assistant', content: 'Done: your document is ready.'),
    ];
    final results = {
      'w': ChatMessage(id: 'r1', role: 'tool', content: 'Results', toolCallId: 'w'),
      'm': ChatMessage(id: 'r2', role: 'tool', content: 'Error: failed', toolCallId: 'm'),
    };
    final steps = stepsBefore(msgs, 5, results, (n, a) => 'Writing your document');
    expect(steps.map((e) => e.label).toList(), ['Searched the web for "flights"', 'Writing your document']);
    expect(steps.map((e) => e.failed).toList(), [false, true]);
  });
}
