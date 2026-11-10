import '../../models.dart';

/// A turn's work, sorted for the quiet activity view (owner, 2026-11-03: "minimize the activity of opencode with
/// just the working progress line, and give an expand option; even expanded, categorized actions like thinking,
/// executed tools, etc."). No Flutter, so it is tested on its own.
class ActivityGroups {
  ActivityGroups._(this.thinking, this.tools, this.notes, this.compacts);

  /// Thinking rows (opencode reasoning), oldest first.
  final List<ChatMessage> thinking;

  /// Each tool call with the message that made it, oldest first.
  final List<(ChatMessage, ToolCall)> tools;

  /// Words written between steps (not the answer), oldest first.
  final List<ChatMessage> notes;

  /// The compact notes of this turn: the engine's own summary of the part of the chat it folded away, so opening
  /// the working line (or a finished turn) shows what it kept (owner 2026-11-10).
  final List<ChatMessage> compacts;

  bool get isEmpty => thinking.isEmpty && tools.isEmpty && notes.isEmpty && compacts.isEmpty;

  int failed(Map<String, ChatMessage> results) =>
      tools.where((t) => (results[t.$2.id]?.content ?? '').trimLeft().startsWith('Error')).length;

  /// One line for the folded view: "2 thoughts · 6 tools · 1 note".
  String summary() => [
        if (thinking.isNotEmpty) '${thinking.length} ${thinking.length == 1 ? 'thought' : 'thoughts'}',
        if (tools.isNotEmpty) '${tools.length} ${tools.length == 1 ? 'tool' : 'tools'}',
        if (notes.isNotEmpty) '${notes.length} ${notes.length == 1 ? 'note' : 'notes'}',
        if (compacts.isNotEmpty) '${compacts.length} ${compacts.length == 1 ? 'compact' : 'compacts'}',
      ].join(' · ');

  static bool _activity(ChatMessage m) => m.role == 'assistant' && (m.name == 'reasoning' || (m.toolCalls?.isNotEmpty ?? false));

  /// A text reply written before more work in the same turn: a note between steps, not the answer.
  static bool isNote(List<ChatMessage> turn, int i) {
    final m = turn[i];
    if (m.role != 'assistant' || m.name == 'reasoning' || (m.toolCalls?.isNotEmpty ?? false) || m.content.trim().isEmpty) return false;
    for (var k = i + 1; k < turn.length; k++) {
      if (turn[k].role == 'user') return false;
      if (_activity(turn[k])) return true;
    }
    return false;
  }

  /// Whether [m] is folded into the activity view. Only thinking folds now: opencode's briefs (the words it writes
  /// between steps) show in the chat as they stream, the way opencode desktop shows them (owner 2026-11-09).
  static bool folds(List<ChatMessage> turn, int i) => turn[i].name == 'reasoning';

  /// The groups of one turn's replies (the messages after the user's message, up to the next one).
  static ActivityGroups of(List<ChatMessage> turn) {
    final thinking = <ChatMessage>[], notes = <ChatMessage>[], compacts = <ChatMessage>[];
    final tools = <(ChatMessage, ToolCall)>[];
    for (var i = 0; i < turn.length; i++) {
      final m = turn[i];
      // A compact note is a quiet 'system' row (AppState.isCompactMark): it belongs in the open view of the turn,
      // never as a bubble of its own (owner 2026-11-10).
      if (m.role == 'system' && (m.name ?? '').startsWith('compact:')) {
        if (m.content.trim().isNotEmpty) compacts.add(m);
        continue;
      }
      if (m.role != 'assistant') continue;
      if (m.name == 'reasoning') {
        if (m.content.trim().isNotEmpty) thinking.add(m);
      } else if (m.toolCalls?.isNotEmpty ?? false) {
        for (final c in m.toolCalls!) {
          tools.add((m, c));
        }
      }
    }
    return ActivityGroups._(thinking, tools, notes, compacts);
  }
}
