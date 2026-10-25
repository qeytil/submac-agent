// The Genkit agent core: turns, tools, signatures round trip, finish gates, guards, interrupts (approvals), steer and
// stop, true token usage.
import 'dart:async';
import 'dart:convert';

import 'package:agent/agent/core.dart';
import 'package:agent/models.dart';
import 'package:agent/services/llm_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// A scripted model: each call pops the next answer and records what it was sent.
class Script {
  Script(this.answers);
  final List<LlmResult Function(Turn t)> answers;
  final List<Turn> seen = [];
  int i = 0;
  Future<LlmResult> call(Turn t) async {
    seen.add(t);
    if (i >= answers.length) return LlmResult('done', [], 'stop', 3, 2, 1);
    return answers[i++](t);
  }
}

LlmResult say(String s, {int tin = 10, int tout = 5}) => LlmResult(s, [], 'stop', tin + tout, tin, tout);
LlmResult calls(List<ToolCall> c, {int tin = 10, int tout = 5}) => LlmResult('', c, 'tool_calls', tin + tout, tin, tout);
ToolCall tc(String id, String name, Map<String, dynamic> args, {Map<String, dynamic>? extra}) =>
    ToolCall(id: id, name: name, arguments: jsonEncode(args), extra: extra);

final tools = [
  for (final n in ['web_search', 'read_file', 'send_sms', 'todo'])
    {
      'type': 'function',
      'function': {
        'name': n,
        'description': n,
        'parameters': {'type': 'object', 'properties': {}},
      },
    }
];

/// A tiny app: the chat is a list of OpenAI messages, rebuilt into every turn like the real app does.
class FakeApp extends CoreHooks {
  final chat = <Map<String, dynamic>>[
    {'role': 'system', 'content': 'sys'},
    {'role': 'user', 'content': 'hi'},
  ];
  final ran = <String>[];
  final notes = <String?>[];
  final committed = <Reply>[];
  final discarded = <Reply>[];
  bool stop = false;
  Set<String> needsOk = {};
  ToolApproval Function(ToolCall c)? decide;
  int errors = 0;

  @override
  bool get cancelled => stop;

  @override
  Future<Turn> buildTurn(int step, String? notes) async {
    this.notes.add(notes);
    return Turn(step: step, payload: [...chat, if (notes != null) {'role': 'user', 'content': notes}], tools: tools);
  }

  @override
  Future<void> commit(Reply r) async {
    committed.add(r);
    chat.add({'role': 'assistant', 'content': r.text, if (r.hasCalls) 'tool_calls': [for (final c in r.calls) c.toJson()]});
  }

  @override
  Future<void> discard(Reply r, {bool hold = false}) async => discarded.add(r);

  @override
  Future<String> runTool(ToolCall call, Map<String, dynamic> args, {Object? approved}) async {
    ran.add(call.name);
    return '${call.name} ok';
  }

  @override
  Future<void> toolDone(ToolCall call, Map<String, dynamic> args, String output) async {
    chat.add({'role': 'tool', 'tool_call_id': call.id, 'content': output});
  }

  @override
  Future<Map<String, dynamic>?> approvalFor(ToolCall call, Map<String, dynamic> args) async =>
      needsOk.contains(call.name) ? {'title': 'Send ${call.name}?', 'kind': 'send'} : null;

  @override
  Future<ToolApproval> answer(ToolCall call, Map<String, dynamic> args, Map<String, dynamic> data) async =>
      decide?.call(call) ?? const ToolApproval.no('No.');

  @override
  Future<ErrorAction> onError(Object error) async {
    errors++;
    return '$error'.contains('retry') ? ErrorAction.retry : ErrorAction.stop;
  }
}

void main() {
  test('tool turns run, then the plain answer ends the run; usage is the model\'s own count summed', () async {
    final s = Script([
      (_) => calls([tc('a', 'web_search', {'q': 'x'})], tin: 100, tout: 7),
      (_) => say('All done.', tin: 120, tout: 9),
    ]);
    final app = FakeApp();
    final core = AgentCore(hooks: app, transport: s.call, tools: tools);
    final r = await core.run();
    expect(r.end, RunEnd.done);
    expect(r.reply!.text, 'All done.');
    expect(app.ran, ['web_search']);
    expect(core.state.step, 2);
    expect(core.state.tokensIn, 220);
    expect(core.state.tokensOut, 16);
    // The second turn was rebuilt from the chat: it carries the call and its result.
    final p = s.seen[1].payload;
    expect(p.any((m) => m['role'] == 'tool' && m['content'] == 'web_search ok'), isTrue);
  });

  test('Gemini thought signatures survive the round trip: model → Genkit part → chat → next request', () async {
    final sig = {
      'google': {'thought_signature': 'SIG-123'}
    };
    final s = Script([
      (_) => calls([tc('c1', 'read_file', {'path': 'a'}, extra: sig)]),
      (_) => say('ok'),
    ]);
    final app = FakeApp();
    await AgentCore(hooks: app, transport: s.call, tools: tools).run();
    expect(app.committed.first.calls.single.thoughtSignature, 'SIG-123');
    final asst = s.seen[1].payload.firstWhere((m) => m['role'] == 'assistant');
    final call = (asst['tool_calls'] as List).single as Map;
    expect((call['extra_content'] as Map)['google']['thought_signature'], 'SIG-123');
    // Wire conversion both ways keeps it too.
    final back = Wire.toOpenAi(Wire.toGenkit([Map<String, dynamic>.from(asst)]));
    expect(jsonEncode(back.single), jsonEncode(asst));
    final part = Wire.callToPart(app.committed.first.calls.single);
    expect(Wire.partToCall(part).extra, sig);
    expect(Wire.partToCall(part).arguments, '{"path":"a"}');
  });

  test('LlmClient keeps extra_content across stream deltas', () {
    var ex = LlmClient.mergeExtra(null, {
      'google': {'thought_signature': 'S'}
    });
    ex = LlmClient.mergeExtra(ex, null);
    expect(ex!['google']['thought_signature'], 'S');
    final j = ToolCall(id: '1', name: 'n', arguments: '{}', extra: ex).toJson();
    expect(ToolCall.fromJson(j).thoughtSignature, 'S');
  });

  test('broken arguments are never run', () async {
    final s = Script([
      (_) => calls([ToolCall(id: 'b', name: 'read_file', arguments: '{"path": "a')]),
      (_) => say('ok'),
    ]);
    final app = FakeApp();
    await AgentCore(hooks: app, transport: s.call, tools: tools).run();
    expect(app.ran, isEmpty);
    expect(app.chat.any((m) => m['role'] == 'tool' && '${m['content']}'.contains('not valid JSON')), isTrue);
  });

  test('a finish gate sends a reply back once with a note, then accepts', () async {
    final s = Script([(_) => say('I sent it.'), (_) => say('Not sent yet: no tool ran.')]);
    final app = FakeApp();
    var tries = 0;
    final r = await AgentCore(hooks: app, transport: s.call, tools: tools, gates: [
      (rep) async => (tries++ == 0 && rep.text.contains('sent it')) ? (note: '# That is not proven yet', hold: false) : null,
    ]).run();
    expect(r.reply!.text, 'Not sent yet: no tool ran.');
    expect(app.discarded.single.text, 'I sent it.');
    expect(app.notes[1], contains('not proven'));
    expect(app.committed.length, 1, reason: 'one final reply only');
  });

  test('a guard can take the tools away: the reply becomes the final status', () async {
    final s = Script([
      (_) => calls([tc('a', 'web_search', {})]),
      (_) => calls([tc('b', 'web_search', {})]),
    ]);
    final app = FakeApp();
    final r = await AgentCore(hooks: app, transport: s.call, tools: tools, after: [
      (rep, st) async {
        if (st.step >= 2) st.noMoreTools = true;
      },
    ]).run();
    expect(app.ran, ['web_search']);
    expect(r.end, RunEnd.done);
  });

  test('a before-guard halts the run with its reason (checkpoint / budget)', () async {
    final s = Script([(_) => calls([tc('a', 'web_search', {})]), (_) => say('never')]);
    final app = FakeApp();
    final core = AgentCore(hooks: app, transport: s.call, tools: tools, before: [(st) => st.step >= 1 ? 'Paused at checkpoint' : null]);
    final r = await core.run();
    expect(r.end, RunEnd.halted);
    expect(core.state.haltReason, 'Paused at checkpoint');
    expect(s.seen.length, 1);
  });

  test('approval as an interrupt: yes runs the tool once (with edits), no tells the model', () async {
    final s = Script([
      (_) => calls([tc('s1', 'send_sms', {'text': 'hi'})]),
      (_) => calls([tc('s2', 'send_sms', {'text': 'again'})]),
      (_) => say('ok'),
    ]);
    final app = FakeApp()
      ..needsOk = {'send_sms'}
      ..decide = (c) => c.id == 's1' ? const ToolApproval.yes(args: {'text': 'hello'}) : const ToolApproval.no('The user said no.');
    final seenArgs = <Map<String, dynamic>>[];
    final core = AgentCore(hooks: _Spy(app, seenArgs), transport: s.call, tools: tools);
    final r = await core.run();
    expect(r.end, RunEnd.done);
    expect(app.ran, ['send_sms'], reason: 'approved once, refused once');
    expect(seenArgs.single['text'], 'hello');
    expect(app.chat.any((m) => m['role'] == 'tool' && m['content'] == 'The user said no.'), isTrue);
  });

  test('a model failure the app retries resumes from the last good history; a final one ends the run', () async {
    var n = 0;
    final s = Script([
      (_) => throw LlmException('retry me'),
      (_) => say('fine'),
    ]);
    final app = FakeApp();
    final r = await AgentCore(hooks: app, transport: (t) => (n++ < 9) ? s.call(t) : Future.value(say('x')), tools: tools).run();
    expect(r.end, RunEnd.done);
    expect(app.errors, 1);
    final app2 = FakeApp();
    final r2 = await AgentCore(hooks: app2, transport: (t) async => throw LlmException('final'), tools: tools).run();
    expect(r2.end, RunEnd.failed);
    expect('${r2.error}', 'final');
  });

  test('steer restarts the cut call without counting it; stop ends the run', () async {
    final app = FakeApp();
    late AgentCore core;
    var calls0 = 0;
    core = AgentCore(
      hooks: app,
      tools: tools,
      transport: (t) async {
        calls0++;
        if (calls0 == 1) {
          core.state.cancelWhy = 'steer';
          core.state.cancel!.cancel('steer');
          throw LlmException('steered');
        }
        return say('heard you');
      },
    );
    final r = await core.run();
    expect(r.reply!.text, 'heard you');
    expect(core.state.step, 1, reason: 'the steered call is not a step');

    final app2 = FakeApp();
    late AgentCore c2;
    c2 = AgentCore(
        hooks: app2,
        tools: tools,
        transport: (t) async {
          app2.stop = true;
          c2.stop();
          throw LlmException('cancelled');
        });
    expect((await c2.run()).end, RunEnd.cancelled);
  });

  test('independent reads of one turn start together', () async {
    final started = <String>[];
    final gate = Completer<void>();
    final s = Script([
      (_) => calls([tc('a', 'web_search', {}), tc('b', 'read_file', {})]),
      (_) => say('ok'),
    ]);
    final app = _Parallel(started, gate);
    final f = AgentCore(hooks: app, transport: s.call, tools: tools).run();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(started, ['a', 'b'], reason: 'both started before either finished');
    gate.complete();
    expect((await f).end, RunEnd.done);
  });
}

class _Spy extends FakeApp {
  _Spy(this.inner, this.args);
  final FakeApp inner;
  final List<Map<String, dynamic>> args;
  @override
  bool get cancelled => inner.cancelled;
  @override
  Future<Turn> buildTurn(int step, String? notes) => inner.buildTurn(step, notes);
  @override
  Future<void> commit(Reply r) => inner.commit(r);
  @override
  Future<String> runTool(ToolCall call, Map<String, dynamic> a, {Object? approved}) {
    args.add(a);
    return inner.runTool(call, a, approved: approved);
  }

  @override
  Future<void> toolDone(ToolCall call, Map<String, dynamic> a, String output) => inner.toolDone(call, a, output);
  @override
  Future<Map<String, dynamic>?> approvalFor(ToolCall call, Map<String, dynamic> a) => inner.approvalFor(call, a);
  @override
  Future<ToolApproval> answer(ToolCall call, Map<String, dynamic> a, Map<String, dynamic> data) => inner.answer(call, a, data);
}

class _Parallel extends FakeApp {
  _Parallel(this.started, this.gate);
  final List<String> started;
  final Completer<void> gate;
  @override
  List<List<int>> parallel(List<ToolCall> calls) => [
        [for (var i = 0; i < calls.length; i++) i]
      ];
  @override
  Future<String> runTool(ToolCall call, Map<String, dynamic> args, {Object? approved}) async {
    started.add(call.id);
    await gate.future;
    return 'ok';
  }
}
