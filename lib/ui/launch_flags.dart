/// Things hidden for launch (PLAN.md 3.3). The code stays; only the way in is closed.
/// Flip one to true to bring it back.
class LaunchFlags {
  LaunchFlags._();

  /// Teams: groups of bots with a lead. On since 2026-10-23 (owner: "turn on teams, like Grok").
  static const bool teams = true;

  /// Publishing your own bot to the Bot Store.
  static const bool storePublishing = false;

  /// SubMac's own Bot Store bots kept out for launch: Health and Coder are hidden (PLAN.md 3.3), and Nova, Amal, Rank
  /// and Ustad already come from the roles on the Hire screen, so the Store does not list them twice.
  static const Set<String> hiddenStoreBots = {'health', 'coder', 'researcher', 'legal', 'seo', 'teacher'};
}
