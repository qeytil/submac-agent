/// What the page answers when asked to find a redrawn control again (P6).
///
/// A control the page redrew (a list that refreshed, a form that re-rendered) gets a new number. The page
/// script remembers what each number looked like and can find it again; this turns that answer into
/// something the agent can act on — the new number, and how it was found (so the message can say it).
class HealedTarget {
  const HealedTarget(this.id, this.how, this.label);
  final int id;

  /// 'label' (same words), 'link' (same href), 'text' (one label contains the other), 'kind' (same kind of
  /// control, no label to go on), or 'look' when the page did not say.
  final String how;

  /// What the found control says, for the message the model reads.
  final String label;

  @override
  String toString() => 'HealedTarget($id, $how, "$label")';
}

/// Reads the page's answer. Null means "nothing to heal": the control is still there under the same number,
/// the page could not find it again, or the answer makes no sense. A wrong heal is worse than none, so every
/// odd answer becomes null.
HealedTarget? parseHeal(Map<String, dynamic> h, int oldId) {
  if (h['ok'] != true) return null;
  final raw = h['id'];
  final id = raw is num ? raw.toInt() : int.tryParse('$raw');
  if (id == null || id < 0 || id == oldId) return null;
  final how = '${h['how'] ?? ''}'.trim();
  final label = '${h['t'] ?? ''}'.trim();
  return HealedTarget(id, how.isEmpty ? 'look' : how, label.length > 80 ? '${label.substring(0, 80)}…' : label);
}
