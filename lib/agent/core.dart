// SubMac's agent core on Genkit Dart (stable API only: generate, tools, interrupts, middleware, cancellation).
//
// One loop for every agent in the app (main chat, bots, team members, the browser sub-agent). Genkit runs the turns:
// model call → tool calls → model call … until the model answers without tools, an interrupt (an approval) stops it, or
// it is cancelled. SubMac's product rules ride on top as Genkit middleware:
//   * the request of every turn is rebuilt from the chat by the app ([CoreHooks.buildTurn]) so prompt caching, compaction,
//     screenshots and one-time images work exactly as the app designs them;
//   * guards (step caps, token budgets, loop/stuck detection, checklist nudges, the proof check, the page check, the
//     reply-format check) are middleware and finish gates;
//   * approvals are Genkit interrupts, answered through the app's approval cards and resumed with `interruptRestart`;
//   * every model step and tool call is written to a [RunLog] (the per-run journal) so a killed run can resume.
import 'dart:async';
import 'dart:convert';

import 'package:genkit/lite.dart' as gk;
import 'package:genkit/genkit.dart'
    show
        CancellationController,
        FinishReason,
        GenerateMiddleware,
        GenerateResult,
        GenerateTurnState,
        GenkitException,
        InterruptResponse,
        Message,
        Model,
        ModelRequest,
        ModelResponse,
        ModelResponseChunk,
        Part,
        PartExtension,
        Role,
        TextPart,
        Tool,
        ToolRequest,
        ToolRequestPart,
        ToolResult,
        GenerationUsage,
        ActionFnArg,
        GenerateActionOptions;

import 'package:schemantic/schemantic.dart' show SchemanticType;

import '../models.dart';
import '../services/llm_client.dart';
import '../services/text_tool_calls.dart';
import 'wire.dart';

export 'wire.dart';

/// One model call as the app sends it: the OpenAI-style messages and tool definitions for this step.
class Turn {
  Turn({required this.step, required this.payload, this.tools, this.hints = const {}});

  /// 0-based index of this model call in the run (retries of a turn get a new index too).
  final int step;
  final List<Map<String, dynamic>> payload;
  final List<Map<String, dynamic>>? tools;

  /// Per-step hints for the transport (effort, lane...).
  final Map<String, Object?> hints;
}

/// Sends one [Turn] to a model and returns what came back (text, tool calls with their provider data, usage).
typedef Transport = Future<LlmResult> Function(Turn turn);

/// What one model call gave back, in app terms.
class Reply {
  Reply({required this.text, required this.calls, this.finish, this.tokensIn = 0, this.tokensOut = 0, this.tokens = 0, this.step = 0});
  String text;
  List<ToolCall> calls;
  final String? finish;
  final int tokensIn, tokensOut, tokens;
  final int step;
  bool get cutOff => finish == 'length' || finish == 'max_tokens';
  bool get hasCalls => calls.isNotEmpty;
  bool get blank => text.trim().isEmpty && calls.isEmpty;
}

/// Shared state of one run, read and written by the middleware.
class RunState {
  /// Model calls answered so far in this run.
  int step = 0;

  /// True token usage reported by the model (summed over every call), and the last call's prompt size.
  int tokensIn = 0, tokensOut = 0, lastPromptTokens = 0;

  /// Tool calls run so far.
  int toolCalls = 0;

  final List<String> _notes = [];

  /// A note for the next model call only (a guard's nudge, a steer, a checkpoint).
  void note(String n) {
    if (n.trim().isNotEmpty) _notes.add(n.trim());
  }


  /// The notes for this call, cleared.
  String? takeNotes() {
    if (_notes.isEmpty) return null;
    final s = _notes.join('\n\n');
    _notes.clear();
    return s;
  }

  /// Set by a guard: the model may not call tools any more; the next reply is the final one (wrap-up / stuck stop).
  bool noMoreTools = false;

  /// Reads started early (independent read-only calls of the same turn run together).
  final Map<String, Future<String>> early = {};

  /// Why the run stopped early (a cap, a budget), shown to the user; null when it ended normally.
  String? haltReason;

  /// The newest Genkit cancellation controller (one per generate call).
  CancellationController? cancel;

  /// What cancelled the current call: 'stop' (the user), 'steer' (a new message: think again with it).
  String? cancelWhy;
}

/// Long-task checkpoints by distance from the last one, never `step % segment == 0`: a finish gate can make several
/// model calls inside one turn, so the step counter the before-guards see can jump past an exact multiple.
class CheckpointClock {
  int last = 0;

  /// True (and the checkpoint is recorded) when [segment] or more steps passed since the last checkpoint.
  bool due(int step, int segment) {
    if (segment <= 0 || step - last < segment) return false;
    last = step;
    return true;
  }
}

/// Carries the app's turn and transport into the Genkit model for one call.
class TurnBox {
  static const key = 'submac.turn';
  TurnBox(this.transport);
  final Transport transport;
  Turn? next;
}

/// The model every SubMac agent uses: a Genkit model whose wire is the app's own transport (ai-chat, or a test fake).
/// Gemini thought signatures arrive on [ToolCall.extra] and go out on the tool request part's metadata, and back.
Model<Map<String, dynamic>> submacModel({String name = 'submac', Transport? transport}) {
  return Model<Map<String, dynamic>>(
    name: name,
    fn: (req, ctx) async {
      final box = ctx.context?[TurnBox.key];
      final t = box is TurnBox ? box.next : null;
      if (box is TurnBox) box.next = null;
      final send = box is TurnBox ? box.transport : transport;
      if (send == null) throw StateError('submacModel: no transport');
      final turn = t ??
          Turn(
            step: -1,
            payload: Wire.toOpenAi(req.messages),
            tools: req.tools?.isEmpty ?? true
                ? null
                : [
                    for (final d in req.tools!)
                      {
                        'type': 'function',
                        'function': {'name': d.name, 'description': d.description, 'parameters': d.inputSchema ?? {'type': 'object'}},
                      }
                  ],
          );
      final r = await send(turn);
      return responseOf(r);
    },
  );
}

/// An app [LlmResult] as a Genkit response: text, tool requests (with signatures), finish reason and usage.
ModelResponse responseOf(LlmResult r) {
  final parts = <Part>[
    if (r.content.isNotEmpty) TextPart(text: r.content),
    for (final c in r.toolCalls) Wire.callToPart(c),
  ];
  final fr = switch (r.finishReason) {
    'length' || 'max_tokens' => FinishReason.length,
    'cancelled' => FinishReason.aborted,
    _ => FinishReason.stop,
  };
  return ModelResponse(
    message: Message(role: Role.model, content: parts.isEmpty ? [TextPart(text: '')] : parts),
    finishReason: fr,
    usage: GenerationUsage(inputTokens: r.tokensIn, outputTokens: r.tokensOut, totalTokens: r.tokens),
    custom: {'finish': r.finishReason, 'tokens': r.tokens},
  );
}

/// A Genkit response as an app [Reply].
Reply replyOf(ModelResponse resp, {int step = 0}) {
  final msg = resp.message;
  final text = msg == null ? '' : msg.content.map((p) => p.textPart?.text ?? '').join();
  final calls = msg == null ? <ToolCall>[] : [for (final p in msg.content) if (p.toolRequestPart != null) Wire.partToCall(p.toolRequestPart!)];
  final u = resp.usage;
  final custom = resp.custom ?? const {};
  return Reply(
    text: text,
    calls: calls,
    finish: custom['finish'] is String ? custom['finish'] as String : (resp.finishReason == FinishReason.length ? 'length' : null),
    tokensIn: u?.inputTokens ?? 0,
    tokensOut: u?.outputTokens ?? 0,
    tokens: custom['tokens'] is int ? custom['tokens'] as int : (u?.totalTokens ?? 0),
    step: step,
  );
}

/// A response rebuilt from a (possibly edited) [Reply]: guards drop tool calls or rewrite text this way.
ModelResponse responseFrom(Reply r, ModelResponse base) {
  final parts = <Part>[
    if (r.text.isNotEmpty) TextPart(text: r.text),
    for (final c in r.calls) Wire.callToPart(c),
  ];
  return ModelResponse(
    message: Message(role: Role.model, content: parts.isEmpty ? [TextPart(text: '')] : parts),
    finishReason: base.finishReason,
    usage: base.usage,
    custom: base.custom,
  );
}

/// A turn that ends the run without calling the model (a cap or budget said stop).
ModelResponse haltResponse(String reason) =>
    ModelResponse(finishReason: FinishReason.stop, finishMessage: reason, custom: {'halt': reason});

bool isHalt(GenerateResult r) => r.custom?['halt'] != null;

/// Runs one tool for the model. Never throws: failures come back as "Error: …" text the model can read.
typedef ToolExec = Future<String> Function(ToolCall call, Map<String, dynamic> args, ToolRequestPart part);

/// Genkit tools for OpenAI-style definitions (the app's tool catalog), all routed to [exec].
List<Tool<Map<String, dynamic>, String>> genkitTools(List<Map<String, dynamic>> defs, ToolExec exec) {
  final seen = <String>{};
  final out = <Tool<Map<String, dynamic>, String>>[];
  for (final d in defs) {
    final f = (d['function'] as Map?) ?? d;
    final name = '${f['name'] ?? ''}';
    if (name.isEmpty || !seen.add(name)) continue;
    final params = f['parameters'] is Map ? Map<String, Object?>.from(f['parameters'] as Map) : <String, Object?>{'type': 'object'};
    out.add(Tool<Map<String, dynamic>, String>(
      name: name,
      description: '${f['description'] ?? name}',
      inputSchema: SchemanticType.from<Map<String, dynamic>>(
        jsonSchema: params,
        parse: (j) => j is Map ? Map<String, dynamic>.from(j) : <String, dynamic>{},
      ),
      fn: (input, ctx) async {
        final part = ctx.toolRequest ?? ToolRequestPart(toolRequest: ToolRequest(name: name, input: input));
        try {
          return ToolResult.response(await exec(Wire.partToCall(part), input, part));
        } catch (e) {
          return ToolResult.response('Error in $name: $e');
        }
      },
    ));
  }
  return out;
}

/// The app side of a run: what to send each turn, how to run tools, approvals, and what to show.
abstract class CoreHooks {
  /// The request for model call [step]: rebuilt from the chat every time (with this step's [notes]).
  Future<Turn> buildTurn(int step, String? notes);

  /// A model call is about to start / has finished (the chat shows a live reply and updates it).
  void modelStarted(int step) {}

  /// The reply of this turn is final for the turn (tools run next, or it is the answer). Saved to the chat.
  Future<void> commit(Reply r) async {}

  /// A reply that a finish gate sent back: it leaves the chat (or is held on screen until the next reply replaces it).
  Future<void> discard(Reply r, {bool hold = false}) async {}

  /// The words of the current model call that already reached the screen (CB-2): what a stopped call gives back.
  String partialText() => '';

  /// The user stopped the run while a model call was streaming (CB-2). Called instead of [commit]: the reply is not
  /// final, and the app decides what stays (the words already shown are kept; an empty bubble goes).
  Future<void> onStopped(Reply r) async {}

  /// Runs one tool (approval, when needed, was already given: [approved]).
  Future<String> runTool(ToolCall call, Map<String, dynamic> args, {Object? approved});

  /// Whether this call needs the user's OK first. A non-null map interrupts the run with it as the interrupt data.
  Future<Map<String, dynamic>?> approvalFor(ToolCall call, Map<String, dynamic> args) async => null;

  /// Puts an interrupt in front of the user (the app's approval card) and waits for the answer.
  Future<ToolApproval> answer(ToolCall call, Map<String, dynamic> args, Map<String, dynamic> data) async =>
      const ToolApproval.no('Not approved.');

  /// Every tool result passes through this before it is journaled, saved or sent to the model (secrets hidden).
  String cleanOutput(String out) => out;

  /// One model call came back (every call, with or without tool calls, including replies a finish gate sends back):
  /// its true token usage, for budgets and Bot Activity.
  void usage(Reply r) {}

  /// A tool result is in (journal and chat updated by the core; this is for step rows, evidence, traces).
  Future<void> toolDone(ToolCall call, Map<String, dynamic> args, String output) async {}

  /// A model call failed. [gotOutput]: some of the reply had already streamed.
  Future<ErrorAction> onError(Object error) async => ErrorAction.stop;

  /// Reads that may run together (independent, read-only), as batches of call indexes.
  List<List<int>> parallel(List<ToolCall> calls) => const [];

  /// Whether a call's arguments arrived cut off / broken; the text the model gets back instead of running it.
  String brokenText(Reply r) => r.cutOff
      ? 'Error: this call was cut off because it was too long for one reply, so nothing was done. Split it into smaller parts.'
      : 'Error: the arguments of this call were not valid JSON, so nothing was done. Send it again with valid JSON.';

  bool get cancelled;
}

/// The user's answer to an approval interrupt.
class ToolApproval {
  const ToolApproval.yes({this.args, this.note = ''})
      : ok = true,
        text = '';
  const ToolApproval.no(this.text)
      : ok = false,
        args = null,
        note = '';
  final bool ok;

  /// Edited arguments (the user changed the message before approving).
  final Map<String, dynamic>? args;
  final String note;

  /// What the model reads when the user said no.
  final String text;
}

enum ErrorAction { retry, stop }

/// One finish gate: given the final reply, a note to send it back for another try, or null to accept it.
/// [hold]: the reply stays on screen while the work goes on (the next final reply replaces it).
typedef FinishGate = Future<({String note, bool hold})?> Function(Reply r);

/// Where each step of a run is written down (the journal). The default writes nothing.
class RunLog {
  const RunLog();
  Future<void> modelStep(Reply r) async {}
  Future<void> toolStart(ToolCall c) async {}
  Future<void> toolEnd(ToolCall c, String output) async {}
  Future<void> interrupt(ToolCall c, Map<String, dynamic> data) async {}
  Future<void> status(String s) async {}
}

// ------------------------------------------------------------------ middleware

/// Innermost: builds each turn from the chat, sends it, and keeps the true token usage.
class TurnMiddleware extends GenerateMiddleware {
  TurnMiddleware(this.hooks, this.state, this.box, {this.parseTextCalls = true});
  final CoreHooks hooks;
  final RunState state;
  final TurnBox box;
  final bool parseTextCalls;

  @override
  Future<ModelResponse> model(ModelRequest request, ActionFnArg<ModelResponseChunk, ModelRequest, void> ctx,
      Future<ModelResponse> Function(ModelRequest, ActionFnArg<ModelResponseChunk, ModelRequest, void>) next) async {
    final step = state.step;
    final turn = await hooks.buildTurn(step, state.takeNotes());
    // Only the tools this turn offers are shown to the model (scoping); every tool stays callable.
    final names = turn.tools == null ? const <String>{} : {for (final t in turn.tools!) Wire.toolName(t)};
    box.next = turn;
    hooks.modelStarted(step);
    final req = ModelRequest(
      messages: request.messages,
      config: request.config,
      tools: turn.tools == null ? const [] : request.tools?.where((t) => names.contains(t.name)).toList(),
      toolChoice: request.toolChoice,
      output: request.output,
    );
    final resp = await next(req, ctx);
    state.step++;
    var r = replyOf(resp, step: step);
    state.tokensIn += r.tokensIn;
    state.tokensOut += r.tokensOut;
    if (r.tokensIn > 0) state.lastPromptTokens = r.tokensIn;
    hooks.usage(r);
    // Some models write their tool calls as text (<tool_call>…): real calls from here on.
    if (parseTextCalls && r.calls.isEmpty && r.text.isNotEmpty) {
      final parsed = TextToolCalls.parse(r.text);
      if (parsed.calls.isNotEmpty) {
        r = Reply(text: parsed.rest, calls: parsed.calls, finish: r.finish, tokensIn: r.tokensIn, tokensOut: r.tokensOut, tokens: r.tokens, step: step);
        return responseFrom(r, resp);
      }
    }
    return resp;
  }
}

/// Finish gates: a final reply (no tool calls) is checked before it counts. A gate that objects sends it back with a
/// note (one more model call, same turn). Gates run in order; the first objection wins.
class FinishGateMiddleware extends GenerateMiddleware {
  FinishGateMiddleware(this.hooks, this.state, this.gates);
  final CoreHooks hooks;
  final RunState state;
  final List<FinishGate> gates;

  @override
  Future<ModelResponse> model(ModelRequest request, ActionFnArg<ModelResponseChunk, ModelRequest, void> ctx,
      Future<ModelResponse> Function(ModelRequest, ActionFnArg<ModelResponseChunk, ModelRequest, void>) next) async {
    while (true) {
      final resp = await next(request, ctx);
      final r = replyOf(resp, step: state.step - 1);
      if (r.hasCalls || hooks.cancelled || resp.custom?['halt'] != null || resp.finishReason == FinishReason.aborted) return resp;
      ({String note, bool hold})? sendBack;
      for (final g in gates) {
        sendBack = await g(r);
        if (sendBack != null) break;
      }
      if (sendBack == null) return resp;
      await hooks.discard(r, hold: sendBack.hold);
      state.note(sendBack.note);
    }
  }
}

/// Guards that look at each model reply before its tools run: token budget, stuck detection. They can post a note for
/// the next call, or take the tools away (the next reply must be the final status).
typedef ReplyGuard = Future<void> Function(Reply r, RunState s);

/// Turn guards: before a model call (a cap can halt the run, a steer/inbox note is added), and after it (budgets,
/// loop detection; [RunState.noMoreTools] strips the calls so the reply is the last one).
class GuardMiddleware extends GenerateMiddleware {
  GuardMiddleware(this.state, {this.before = const [], this.after = const []});
  final RunState state;

  /// Run before each model call; a non-null result halts the run with that reason (shown to the user).
  final List<FutureOr<String?> Function(RunState s)> before;
  final List<ReplyGuard> after;

  @override
  Future<ModelResponse> model(ModelRequest request, ActionFnArg<ModelResponseChunk, ModelRequest, void> ctx,
      Future<ModelResponse> Function(ModelRequest, ActionFnArg<ModelResponseChunk, ModelRequest, void>) next) async {
    for (final b in before) {
      final why = await b(state);
      if (why != null) {
        state.haltReason = why;
        return haltResponse(why);
      }
    }
    final resp = await next(request, ctx);
    if (resp.custom?['halt'] != null) return resp;
    final r = replyOf(resp, step: state.step - 1);
    if (!r.hasCalls) return resp;
    for (final a in after) {
      await a(r, state);
    }
    if (state.noMoreTools) {
      r.calls = [];
      return responseFrom(r, resp);
    }
    return resp;
  }
}

/// Outermost: commits each turn's reply to the chat and the journal, starts independent reads together, and wraps every
/// tool call (broken arguments, approvals as interrupts, journal, results to the chat).
class CommitMiddleware extends GenerateMiddleware {
  CommitMiddleware(this.hooks, this.state, this.log, {this.stopped});
  /// Completes when the run is stopped: a tool still running is not waited for.
  final Future<void>? stopped;
  final CoreHooks hooks;
  final RunState state;
  final RunLog log;
  Reply? _last;

  @override
  Future<ModelResponse> model(ModelRequest request, ActionFnArg<ModelResponseChunk, ModelRequest, void> ctx,
      Future<ModelResponse> Function(ModelRequest, ActionFnArg<ModelResponseChunk, ModelRequest, void>) next) async {
    final resp = await next(request, ctx);
    if (resp.custom?['halt'] != null || resp.message == null) return resp;
    final r = replyOf(resp, step: state.step - 1);
    _last = r;
    // CB-2: a call cut by Stop is not this turn's reply; committing it replaced the streamed words with nothing.
    if (resp.finishReason == FinishReason.aborted) {
      await hooks.onStopped(r);
      return resp;
    }
    await hooks.commit(r);
    await log.modelStep(r);
    // Independent reads of this turn start now, together; each call still reports in order.
    if (r.calls.length > 1 && !hooks.cancelled) {
      for (final batch in hooks.parallel(r.calls)) {
        if (batch.length < 2) continue;
        for (final i in batch) {
          final c = r.calls[i];
          final args = Wire.argsOf(Wire.callToPart(c));
          state.early[c.id] = hooks.runTool(c, args);
        }
      }
    }
    return resp;
  }

  @override
  Future<ToolResult> tool(ToolRequestPart request, ActionFnArg<void, dynamic, void> ctx,
      Future<ToolResult> Function(ToolRequestPart, ActionFnArg<void, dynamic, void>) next) async {
    final call = Wire.partToCall(request);
    final args = Wire.argsOf(request);
    String out;
    if (Wire.isBroken(request) && (_last == null || _last!.calls.any((c) => c.id == call.id))) {
      out = hooks.brokenText(_last ?? Reply(text: '', calls: const []));
    } else {
      final resumed = request.metadata?['resumed'];
      final approved = resumed is Map && resumed['approved'] == true ? resumed : null;
      final early = state.early.remove(call.id);
      if (approved == null && early == null) {
        final ask = await hooks.approvalFor(call, args);
        if (ask != null) {
          await log.interrupt(call, ask);
          return ToolResult.interrupt(ask);
        }
      }
      await log.toolStart(call);
      final running = early ?? hooks.runTool(call, args, approved: approved);
      final stop = stopped;
      out = stop == null ? await running : await Future.any([running, stop.then((_) => 'Stopped by the user before this finished.')]);
    }
    out = hooks.cleanOutput(out);
    state.toolCalls++;
    await log.toolEnd(call, out);
    await hooks.toolDone(call, args, out);
    return ToolResult.response(out);
  }
}

// ------------------------------------------------------------------ the run

/// How a run ended.
enum RunEnd { done, cancelled, halted, failed }

class RunResult {
  RunResult(this.end, {this.reply, this.error});
  final RunEnd end;
  final Reply? reply;
  final Object? error;
}

/// Runs one agent task end to end on Genkit.
class AgentCore {
  AgentCore({
    required this.hooks,
    required this.transport,
    required this.tools,
    this.gates = const [],
    this.before = const [],
    this.after = const [],
    this.log = const RunLog(),
    this.maxSteps = 50,
    RunState? state,
    this.modelName = 'submac',
  }) : state = state ?? RunState();

  final CoreHooks hooks;
  final Transport transport;

  /// Every tool the run may call (scoping per turn happens in [CoreHooks.buildTurn]).
  final List<Map<String, dynamic>> tools;
  final List<FinishGate> gates;
  final List<FutureOr<String?> Function(RunState s)> before;
  final List<ReplyGuard> after;
  final RunLog log;

  /// The most model calls this run may make (a hard ceiling; [before] guards pause earlier).
  final int maxSteps;
  final RunState state;
  final String modelName;

  /// Seed history for the first call. The app rebuilds the real request every turn, so this only has to be valid.
  List<Message> seed = [Message(role: Role.user, content: [TextPart(text: '(task)')])];

  /// Completes on [stop]. Genkit's cancellation does not interrupt a model call or tool already in flight, so both
  /// race this: the run ends at once and a late answer is ignored.
  final Completer<void> _stopped = Completer<void>();

  /// Stops the current model call or tool and ends the run.
  void stop() {
    state.cancelWhy = 'stop';
    state.cancel?.cancel('stop');
    if (!_stopped.isCompleted) _stopped.complete();
  }

  /// One model call that Stop ends at once. A stopped call gives back the words already shown (CB-2), not ''.
  Future<LlmResult> _send(Turn t) {
    LlmResult stoppedResult() => LlmResult(hooks.partialText(), const [], 'cancelled');
    if (_stopped.isCompleted) return Future.value(stoppedResult());
    return Future.any([transport(t), _stopped.future.then((_) => stoppedResult())]);
  }

  Future<RunResult> run() async {
    final box = TurnBox(_send);
    final model = submacModel(name: modelName);
    final gTools = genkitTools(tools, (c, a, p) => hooks.runTool(c, a));
    final mw = <GenerateMiddleware>[
      CommitMiddleware(hooks, state, log, stopped: _stopped.future),
      GuardMiddleware(state, before: before, after: after),
      FinishGateMiddleware(hooks, state, gates),
      TurnMiddleware(hooks, state, box),
    ];
    var messages = seed;
    List<ToolRequestPart>? restart;
    List<InterruptResponse>? respond;
    // Errors in a row without progress (a step that came back resets it); steers are new messages, never failures.
    var failures = 0, steers = 0, stepAtFail = -1;
    Reply? last;
    while (true) {
      if (hooks.cancelled) return RunResult(RunEnd.cancelled, reply: last);
      final left = maxSteps - state.step;
      if (left <= 0) {
        state.haltReason ??= 'step_cap';
        return RunResult(RunEnd.halted, reply: last);
      }
      final ctl = CancellationController();
      state.cancel = ctl;
      state.cancelWhy = null;
      final GenerateResult res;
      try {
        res = await gk.generate(
          model: model,
          messages: messages,
          tools: gTools,
          maxTurns: left,
          use: mw,
          cancel: ctl.token,
          context: {TurnBox.key: box},
          interruptRestart: restart,
          interruptRespond: respond,
        );
      } catch (e) {
        // A setup fault (never a model or tool failure, those resolve to a response).
        return RunResult(RunEnd.failed, error: e, reply: last);
      }
      restart = null;
      respond = null;
      if (res.message != null && res.finishReason != FinishReason.aborted) last = replyOf(res.modelResponse, step: state.step - 1);
      if (isHalt(res)) return RunResult(RunEnd.halted, reply: last);
      switch (res.finishReason) {
        case FinishReason.interrupted:
          messages = res.messages;
          final r = <ToolRequestPart>[], a = <InterruptResponse>[];
          for (final p in res.message?.content ?? const <Part>[]) {
            final tr = p.toolRequestPart;
            final data = tr?.metadata?['interrupt'];
            if (tr == null || data == null) continue;
            final call = Wire.partToCall(tr);
            final args = Wire.argsOf(tr);
            final ans = await hooks.answer(call, args, data is Map ? Map<String, dynamic>.from(data) : {'ask': data});
            if (hooks.cancelled) return RunResult(RunEnd.cancelled, reply: last);
            if (ans.ok) {
              final meta = Map<String, dynamic>.from(tr.metadata ?? const {})
                ..remove('interrupt')
                ..['resumed'] = {'approved': true, 'note': ans.note, if (data is Map) ...Map<String, dynamic>.from(data)};
              if (ans.args != null) meta[Wire.argsKey] = jsonEncode(ans.args);
              r.add(ToolRequestPart(toolRequest: ToolRequest(ref: tr.toolRequest.ref, name: tr.toolRequest.name, input: ans.args ?? args), metadata: meta));
            } else {
              a.add(InterruptResponse(tr, ans.text));
              await log.toolEnd(call, ans.text);
              await hooks.toolDone(call, args, ans.text);
            }
          }
          restart = r.isEmpty ? null : r;
          respond = a.isEmpty ? null : a;
          continue;
        case FinishReason.aborted:
          if (state.cancelWhy == 'steer' && !hooks.cancelled) {
            // A new message from the user: think again with it. The step that was cut is not counted (no rewind needed:
            // only answered calls count).
            messages = res.messages;
            continue;
          }
          if (hooks.cancelled || state.cancelWhy == 'stop') return RunResult(RunEnd.cancelled, reply: last);
          // Genkit's own turn limit (maxTurns).
          state.haltReason ??= 'step_cap';
          return RunResult(RunEnd.halted, reply: last);
        case FinishReason.failed:
          if (hooks.cancelled) return RunResult(RunEnd.cancelled, reply: last);
          final cause = causeOf(res.cause ?? res.error?.message);
          if (state.step != stepAtFail) {
            failures = 0;
            stepAtFail = state.step;
          }
          final act = await hooks.onError(cause);
          final steer = isSteer(cause);
          if (act == ErrorAction.retry && (steer ? steers++ < maxSteers : failures++ < maxFailuresInRow)) {
            messages = res.messages;
            continue;
          }
          return RunResult(RunEnd.failed, error: steer ? LlmException(steerStopText) : cause, reply: last);
        default:
          return RunResult(hooks.cancelled ? RunEnd.cancelled : RunEnd.done, reply: last);
      }
    }
  }

  /// Retries of errors in a row with no step in between (a step that comes back starts the count again).
  static const maxFailuresInRow = 8;

  /// New messages from the user mid-step (each restarts the step). A ceiling only so a stuck flag can never loop.
  static const maxSteers = 100;

  /// What the user reads if a run ever ends on a steer (never the raw word "steered").
  static const steerStopText = 'The task stopped while reading your new message. Send it again to carry on.';

  /// A model call cut short because the user sent a new message (not a failure).
  static bool isSteer(Object? e) => e is LlmException && e.message == 'steered';

  /// The original error behind Genkit's wrappers (an [LlmException] from the transport, a tool's own error).
  static Object causeOf(Object? e) {
    var cur = e;
    for (var i = 0; i < 6; i++) {
      if (cur is GenkitException && cur.cause != null) {
        cur = cur.cause;
        continue;
      }
      break;
    }
    return cur ?? 'Unknown error';
  }
}

/// Small helper for the app: the reply of a turn as a chat message fields update.
extension ReplyCalls on Reply {
  List<ToolCall>? get callsOrNull => calls.isEmpty ? null : calls;
}

// Keep the analyzer quiet about types re-exported for callers of this library.
typedef GenkitTurnState = GenerateTurnState;
typedef GenkitOptions = GenerateActionOptions;
