// "Try again" picks up where the task failed (R2 item 2) instead of sending the whole request again.
//
// Before: ChatController.regenerate() deleted every row after the user's message (tool calls, their results, `say`
// lines, the failed bubble) and ran the task from the start, so the model read the request as new and repeated every
// step, sends and approvals included.
//
// Now the turn is kept: only the failed or last answer bubble goes. When the task had done work (a tool call with its
// result), the run resumes after it: the model sees every finished step and a note not to repeat it, and only the failed
// model call is made again. A call that has no result (cut off) is settled with a result that says so, never run here.
// Without any work in the turn there is nothing to resume, and only the last answer is generated again. The user's
// message is never added a second time.
import '../agent/tool_effects.dart';
import '../models.dart';

class RetryPlan {
  RetryPlan({required this.remove, required this.settle, required this.resume});

  /// Rows of the turn that leave the chat (the failed bubble, a stopped partial reply, the last answer).
  final List<ChatMessage> remove;

  /// Tool calls kept in the chat without a result: the result each one gets (nothing is run).
  final Map<ToolCall, String> settle;

  /// The turn did real work: the run resumes after it (with [note]). False: only the last answer is made again.
  final bool resume;

  /// [turn]: the rows after the user's last message, in order.
  static RetryPlan of(List<ChatMessage> turn) {
    // The last row that is work: a tool result, or the assistant's tool calls.
    var w = -1;
    for (var i = turn.length - 1; i >= 0; i--) {
      final m = turn[i];
      if (m.role == 'tool' || (m.role == 'assistant' && (m.toolCalls?.isNotEmpty ?? false))) {
        w = i;
        break;
      }
    }
    if (w < 0) return RetryPlan(remove: [for (final m in turn) if (m.role == 'assistant') m], settle: const {}, resume: false);
    // After the work: only answers (the failed bubble, a partial or stopped reply, a final answer). They go.
    final remove = [for (var i = w + 1; i < turn.length; i++) if (turn[i].role == 'assistant') turn[i]];
    final answered = {for (final m in turn) if (m.role == 'tool' && m.toolCallId != null) m.toolCallId!};
    final settle = <ToolCall, String>{
      for (final m in turn.take(w + 1))
        if (m.role == 'assistant')
          for (final c in m.toolCalls ?? const <ToolCall>[])
            if (!answered.contains(c.id)) c: cutOff(c.name),
    };
    return RetryPlan(remove: remove, settle: settle, resume: true);
  }

  /// The result of a call that never finished before the task failed.
  static String cutOff(String name) => ToolEffects.rerunnable(name)
      ? 'Not finished: the task failed before $name returned, so there is no result. Call it again if you still need it.'
      : 'Unknown: the task failed while $name was running, so it may or may not have happened. Check first (the sent '
          'message, the saved item, the payment) and never repeat it blindly. If you cannot check, tell the user.';

  /// The note the resumed run starts with.
  static String note({required int settled}) => '# Try again after a failed step\n'
      'The user tapped Try again because the last step failed. Everything above already happened: keep those results and '
      'do not start over. Do not repeat a step that already has a result, above all a send, post, payment, delete or an '
      'approval the user gave${settled > 0 ? ', and check before redoing any of the $settled call(s) whose result says it did not finish' : ''}. '
      'Continue from where it stopped and finish the task as asked.';
}
