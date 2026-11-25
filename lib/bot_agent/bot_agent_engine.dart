// Telesia's own bot turn loop (owner 2026-11-07).
//
// One turn is: model step -> the tools it asked for -> model step ... until the bot answers without a tool, its own
// allowance stops it, the turn is cancelled, or [BotAgentConfig.maxSteps] is reached. A reply that ran out of room is
// continued where it stopped, so a bot never sends half a sentence.
//
// The loop deliberately has no opinion about who supplies the model (Telesia's lane or one of the owner's BYOK keys) or
// how a tool is run: the app passes [step] and [runTool] in. That keeps opencode out of a bot's path and makes the loop
// testable on its own (test/bot_agent_engine_test.dart).

import '../models.dart';
import '../services/llm_client.dart';
import 'bot_agent_config.dart';

/// One model step: [messages] in the OpenAI shape, [tools] as function definitions. The app streams the answer into the
/// chat itself and returns what the model said.
typedef BotAgentStep = Future<LlmResult> Function(List<Map<String, dynamic>> messages, List<Map<String, dynamic>> tools);

/// Runs one tool the model asked for and returns what the model should see (already clipped by the app).
typedef BotAgentTool = Future<String> Function(ToolCall call);

/// What one bot turn ended with.
class BotTurnResult {
  BotTurnResult({
    required this.reply,
    required this.steps,
    required this.toolCalls,
    required this.tokens,
    required this.stopped,
  });

  /// The bot's final reply (the last model step's text, a continued reply joined), '' when it ended with a tool.
  final String reply;

  /// How many model steps ran.
  final int steps;

  /// How many tools ran.
  final int toolCalls;

  /// Tokens the model steps used (as the provider counted them).
  final int tokens;

  /// Why the loop ended early: '' the bot answered on its own, 'cancelled', 'stopped' (the app's own guard),
  /// 'steps' (the step cap), 'continues' (a reply still cut off after every continuation).
  final String stopped;

  bool get ok => stopped.isEmpty;
}

class BotAgentEngine {
  BotAgentEngine({
    required this.config,
    required this.step,
    required this.runTool,
    required this.cancelled,
    this.stop,
    this.onStep,
    this.mustAct = false,
  });

  final BotAgentConfig config;
  final BotAgentStep step;
  final BotAgentTool runTool;
  final bool Function() cancelled;

  /// An extra stop the app checks between steps (the bot's own allowance ran out, its mission is out): true ends the loop.
  final bool Function()? stop;

  /// Called after every model step with what it used, so the app can bill the bot as the turn goes.
  final void Function(LlmResult r)? onStep;

  /// This turn is background work the owner is waiting on: the bot must actually act, never just say it will.
  final bool mustAct;

  /// Words that mean the model intends to act ("Let me do this", "I'll now...") but has not called a tool yet.
  static final _intent = RegExp(
      r"\b(i'?ll|i will|i am going to|i'?m going to|let me|now i|i'?m now|starting to|going to|will now|next,? i|first,? i|i'?m on it|on it now)\b",
      caseSensitive: false);

  /// One turn. [history] and [tools] are in the OpenAI shape; [system] is the bot's brief.
  Future<BotTurnResult> run({
    required String system,
    required List<Map<String, dynamic>> history,
    required List<Map<String, dynamic>> tools,
  }) async {
    final messages = <Map<String, dynamic>>[
      if (system.trim().isNotEmpty) {'role': 'system', 'content': system.trim()},
      ...history,
    ];
    var reply = '';
    var continuing = false;
    var continues = 0;
    var steps = 0;
    var calls = 0;
    var tokens = 0;
    var stopped = '';
    var nudged = false;
    var checkpointed = false;

    for (var i = 0; i < config.maxSteps; i++) {
      if (cancelled()) {
        stopped = 'cancelled';
        break;
      }
      if (stop?.call() ?? false) {
        stopped = 'stopped';
        break;
      }
      // A long task would otherwise be cut at the step cap mid-flight (the bot just stops). Close to the cap the
      // model is told to book its handoff: what is done, what is left, the exact next step, so the next run
      // continues from there instead of starting blind (owner 2026-11-25: long-horizon tasks stopped).
      if (!checkpointed && i >= config.maxSteps - 4) {
        checkpointed = true;
        messages.add({
          'role': 'user',
          'content': 'You are close to the step limit for this run. If the task is not finished: write a short '
              'progress note (what is done, what is left) and the exact next step, then end this run cleanly. Do '
              'not start anything new that you cannot finish in the few steps you have left.',
        });
      }
      final r = await step(messages, tools);
      steps++;
      tokens += r.tokens;
      onStep?.call(r);
      if (cancelled()) {
        stopped = 'cancelled';
        break;
      }
      if (r.toolCalls.isNotEmpty) {
        // Anything written before the tool calls is narration; the real reply is a later step's text.
        reply = r.content;
        continuing = false;
        messages.add({
          'role': 'assistant',
          'content': r.content,
          'tool_calls': [for (final c in r.toolCalls) c.toJson()],
        });
        // Parts that do not depend on each other run at the same time (a team's hand-offs; owner 2026-11-08). The
        // results go back in the calls' own order, so the model reads them as its call list.
        if (config.parallelTools && r.toolCalls.length > 1) {
          final outs = await Future.wait([for (final c in r.toolCalls) runTool(c)]);
          for (var k = 0; k < r.toolCalls.length; k++) {
            final c = r.toolCalls[k];
            messages.add({'role': 'tool', 'tool_call_id': c.id, 'name': c.name, 'content': outs[k]});
          }
          calls += r.toolCalls.length;
          if (cancelled()) {
            stopped = 'cancelled';
            break;
          }
          continue;
        }
        var cutByUser = false;
        for (final c in r.toolCalls) {
          if (cancelled()) {
            cutByUser = true;
            break;
          }
          calls++;
          final out = await runTool(c);
          messages.add({'role': 'tool', 'tool_call_id': c.id, 'name': c.name, 'content': out});
        }
        if (cutByUser) {
          stopped = 'cancelled';
          break;
        }
        continue;
      }
      // A step that only talks (no tool call) used to end the turn there, so a narrating model just said "let me do
      // this" and did nothing, and the bot looked broken. When nothing has run yet and it clearly means to act (or
      // this is background work that must deliver), ask it once to actually use its tools, then take the next reply
      // as final (one nudge only; a model that truly cannot call tools still ends here).
      if (!nudged && calls == 0 && !continuing && r.content.trim().isNotEmpty && (mustAct || _intent.hasMatch(r.content))) {
        nudged = true;
        messages.add({'role': 'assistant', 'content': r.content});
        messages.add({
          'role': 'user',
          'content': 'You have not used any tool yet. Do the task NOW with your tools: run the tool, do not describe or '
              'promise it. When it is truly finished, reply with only the final result for the user.',
        });
        continue;
      }
      // A reply that ran out of room goes on in the same turn instead of ending mid-sentence.
      reply = continuing ? '$reply${r.content}' : r.content;
      if (r.cutOff) {
        if (continues >= config.maxContinues) {
          // Out of continuations (not the step cap): say so, so a cut reply is not filed as "ran out of steps".
          stopped = 'continues';
          break;
        }
        if (i >= config.maxSteps - 1) break; // the step cap: reported as 'steps' below
        continues++;
        continuing = true;
        messages.add({'role': 'assistant', 'content': r.content});
        messages.add({
          'role': 'user',
          'content': 'Your reply was cut off. Continue exactly where you stopped and do not repeat anything you already wrote.',
        });
        continue;
      }
      return BotTurnResult(reply: reply, steps: steps, toolCalls: calls, tokens: tokens, stopped: '');
    }
    return BotTurnResult(
      reply: reply,
      steps: steps,
      toolCalls: calls,
      tokens: tokens,
      stopped: stopped.isEmpty ? 'steps' : stopped,
    );
  }
}