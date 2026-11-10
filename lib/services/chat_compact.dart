import '../models.dart';
import 'context_window.dart';
import 'run_status.dart';

/// Auto-compaction of the chat (owner 2026-11-10): before the window is full, the engine folds the older part of
/// a long chat into a summary, so the user never has to start a new one.
///
/// The pure half — when to fold, reading the summary out of the engine's own session messages, and the quiet
/// mark the chat keeps — so it is tested without the engine or the UI. The mark is a 'system' row named
/// `compact:<id>`: AppState.isCompactMark recognizes it, the name carries the id of the last message it covers,
/// and everything sent to the model afterwards keeps the summary plus the messages after that cut.
class ChatCompact {
  ChatCompact._();

  /// The one honest line while the engine folds the older part ([RunStatus.compacting]).
  static const line = RunStatus.compacting;

  /// True when [used] tokens (what the engine had to read for its newest answer) have filled a [window] enough
  /// to fold the older part now. [ContextWindow.compactAtFor] leaves room for the reply.
  static bool due({required int used, required int window}) => used > 0 && used >= ContextWindow.compactAtFor(window);

  /// The engine's own summary out of its `/session/:id/message` answer: the newest assistant message it marked
  /// `summary: true`, its text parts joined as paragraphs. Null when nothing was folded.
  static String? summaryIn(Object? body) {
    if (body is! List) return null;
    for (final m in body.reversed) {
      if (m is! Map) continue;
      final info = m['info'];
      if (info is! Map || info['role'] != 'assistant' || info['summary'] != true) continue;
      final parts = m['parts'];
      if (parts is! List) continue;
      final text = [for (final p in parts) if (p is Map && p['type'] == 'text') '${p['text'] ?? ''}']
          .where((t) => t.trim().isNotEmpty)
          .join('\n\n')
          .trim();
      if (text.isNotEmpty) return text;
    }
    return null;
  }

  /// The quiet chat row holding [summary], covering everything up to the message [covers] (its id).
  static ChatMessage mark({required String id, required String covers, required String summary}) =>
      ChatMessage(id: id, role: 'system', name: 'compact:$covers', content: summary);

  /// The message a new mark covers: the newest real one in [list] (everything before it now lives in the summary).
  static String? coversIn(List<ChatMessage> list) {
    for (final m in list.reversed) {
      if (m.role == 'system' && (m.name ?? '').startsWith('compact:')) continue;
      return m.id;
    }
    return null;
  }
}

/// One compaction running now (owner 2026-11-10): which chat it folds, and the summary once the engine has it.
class CompactLive {
  const CompactLive(this.convId, [this.summary]);
  final String convId;
  final String? summary;
}
