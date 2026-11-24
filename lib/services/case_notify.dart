import 'cases.dart';
import 'notif_text.dart';
import 'system_bridge.dart';

/// The Investigation section's own notifications (docs/investigation.md §20).
///
/// Milestones only: a finished Solo pass, a strong lead, a decision needed. It has its own channel ("Investigation")
/// and its payload opens the case room. Nothing here throws: on a phone that does not yet know the channel the call
/// is simply dropped.
class CaseNotify {
  CaseNotify._();

  static const channel = NotifChannels.cases;

  /// One slot per case (a newer milestone replaces the last).
  static int noteId(String caseId) => 9800 + (caseId.hashCode % 100).abs();

  static Future<void> milestone(Case c, String text, {bool urgent = false}) async {
    final body = NotifText.summary(text, fallback: text.trim());
    if (body.isEmpty) return;
    try {
      await SystemBridge.I.notifyFrom(
        id: noteId(c.id),
        channel: channel,
        title: '${NotifText.title(NotifFrom.agent)} · ${c.numberLabel}',
        body: body,
        payload: 'case/${c.id}',
        high: urgent,
      );
    } catch (_) {}
  }
}
