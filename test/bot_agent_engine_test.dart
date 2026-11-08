// The bot engine's turn loop on its own (no app, no network): SubMac's own bot engine, owner 2026-11-07.

import 'package:agent/bot_agent/bot_agent_config.dart';
import 'package:agent/bot_agent/bot_agent_engine.dart';
import 'package:agent/models.dart';
import 'package:agent/services/llm_client.dart';
import 'package:flutter_test/flutter_test.dart';

BotAgentConfig _cfg({int maxSteps = 24, int maxContinues = 4}) =>
    BotAgentConfig(botId: 'b1', name: 'Weriye', folder: 'bots/b1', maxSteps: maxSteps, maxContinues: maxContinues);

BotAgentConfig _cfgPar() => BotAgentConfig(botId: 'b1', name: 'Weriye', folder: 'bots/b1', parallelTools: true);
LlmResult _text(String s, [int tokens = 3]) => LlmResult(s, const <ToolCall>[], 'stop', tokens);

LlmResult _call(String name, [String args = '{}', int tokens = 0]) =>
    LlmResult('', [ToolCall(id: 'c1', name: name, arguments: args)], 'tool_calls', tokens);

LlmResult _cut(String s) => LlmResult(s, const <ToolCall>[], 'length');

void main() {
  test('a plain answer ends the turn on the first model step', () async {
    final engine = BotAgentEngine(
      config: _cfg(),
      cancelled: () => false,
      step: (m, t) async => _text('All done.'),
      runTool: (c) async => 'never',
    );
    final r = await engine.run(system: 'sys', history: [
      {'role': 'user', 'content': 'hi'},
    ], tools: const []);
    expect(r.ok, isTrue);
    expect(r.reply, 'All done.');
    expect(r.steps, 1);
    expect(r.toolCalls, 0);
  });

  test('a tool runs and its result goes back to the model', () async {
    var n = 0;
    final engine = BotAgentEngine(
      config: _cfg(),
      cancelled: () => false,
      step: (m, t) async {
        n++;
        if (n == 1) return _call('web_search', '{"q":"x"}');
        expect(m.last['role'], 'tool');
        expect(m.last['content'], 'RESULT');
        return _text('Found it.');
      },
      runTool: (c) async {
        expect(c.name, 'web_search');
        expect(c.arguments, '{"q":"x"}');
        return 'RESULT';
      },
    );
    final r = await engine.run(system: '', history: const [], tools: const []);
    expect(r.reply, 'Found it.');
    expect(r.steps, 2);
    expect(r.toolCalls, 1);
  });

  test('a reply cut for length is continued and joined', () async {
    var n = 0;
    final engine = BotAgentEngine(
      config: _cfg(),
      cancelled: () => false,
      step: (m, t) async => n++ == 0 ? _cut('half a ') : _text('sentence.'),
      runTool: (c) async => '',
    );
    final r = await engine.run(system: '', history: const [], tools: const []);
    expect(r.reply, 'half a sentence.');
    expect(r.steps, 2);
  });

  test("the bot's own allowance stops the turn between steps", () async {
    var stop = false;
    final engine = BotAgentEngine(
      config: _cfg(),
      cancelled: () => false,
      stop: () => stop,
      step: (m, t) async {
        stop = true; // the allowance ran out during this step
        return _call('web_search');
      },
      runTool: (c) async => 'r',
    );
    final r = await engine.run(system: '', history: const [], tools: const []);
    expect(r.stopped, 'stopped');
    expect(r.steps, 1);
  });

  test('the step cap ends a bot that never stops calling tools', () async {
    final engine = BotAgentEngine(
      config: _cfg(maxSteps: 3),
      cancelled: () => false,
      step: (m, t) async => _call('web_search'),
      runTool: (c) async => 'again',
    );
    final r = await engine.run(system: '', history: const [], tools: const []);
    expect(r.stopped, 'steps');
    expect(r.steps, 3);
    expect(r.toolCalls, 3);
  });

  test('tokens from every model step are counted', () async {
    var n = 0;
    final engine = BotAgentEngine(
      config: _cfg(),
      cancelled: () => false,
      step: (m, t) async => n++ == 0 ? _call('t', '{}', 3) : _text('done', 7),
      runTool: (c) async => 'r',
    );
    final r = await engine.run(system: '', history: const [], tools: const []);
    expect(r.tokens, 10);
  });

  test('a cancelled turn stops before another model step', () async {
    var n = 0;
    final engine = BotAgentEngine(
      config: _cfg(),
      cancelled: () => n > 0,
      step: (m, t) async {
        n++;
        return _text('first');
      },
      runTool: (c) async => '',
    );
    final r = await engine.run(system: '', history: const [], tools: const []);
    expect(r.stopped, 'cancelled');
    expect(r.steps, 1);
  });

  test('parallel tools (a team) run at once and their results keep the call order', () async {
    var live = 0, peak = 0;
    final started = <String>[];
    final engine = BotAgentEngine(
      config: _cfgPar(),
      cancelled: () => false,
      step: (m, t) async {
        if (started.isEmpty) {
          return LlmResult('', [
            ToolCall(id: 'c1', name: 'handoff_a', arguments: '{}'),
            ToolCall(id: 'c2', name: 'handoff_b', arguments: '{}'),
          ], 'tool_calls');
        }
        expect(m[m.length - 2]['tool_call_id'], 'c1');
        expect(m[m.length - 1]['tool_call_id'], 'c2');
        expect(m[m.length - 1]['content'], 'result handoff_b');
        return _text('done');
      },
      runTool: (c) async {
        started.add(c.name);
        live++;
        peak = live > peak ? live : peak;
        await Future<void>.delayed(const Duration(milliseconds: 40));
        live--;
        return 'result ${c.name}';
      },
    );
    final r = await engine.run(system: '', history: const [], tools: const []);
    expect(r.reply, 'done');
    expect(peak, 2, reason: 'both hand-offs ran at the same time');
    expect(r.toolCalls, 2);
  });
}