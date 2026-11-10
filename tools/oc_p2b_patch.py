import sys, pathlib

def patch(path, old, new):
    p = pathlib.Path(path); s = p.read_text(); n = s.count(old)
    if n != 1:
        print("::error file=%s::pattern found %d times" % (path, n)); sys.exit(1)
    p.write_text(s.replace(old, new)); print("patched", path)

patch("lib/state/bots_controller.dart",
"""  Future<void> _botWake(Bot b, String reason, String instruction, String kind) async {
""",
"""  Future<void> _botWake(Bot b, String reason, String instruction, String kind) async {
    // BYOK only: with no model of the owner's own there is nothing to run on (SubMac's own model is going away).
    if (ByokStore.I.loaded && !ByokStore.I.hasChoices) {
      b.log('note', 'I need a model before I can work. Connect one in Settings > Models.');
      await Bots.I.save();
      return;
    }
""")

patch("lib/services/bot_llm.dart",
"""    final r = route ?? BotModelRoute.of(b);
    final pick = r.byok;
    if (pick != null) return byokCall(pick, messages, maxTokens: maxTokens);
""",
"""    final r = route ?? BotModelRoute.of(b);
    final pick = r.byok;
    // BYOK only: a bot's work never goes to SubMac's own model.
    if (pick == null && ByokStore.I.loaded && !ByokStore.I.hasChoices) {
      throw LlmException('Connect a model before a bot can work.', status: 400, code: 'no_model');
    }
    if (pick != null) return byokCall(pick, messages, maxTokens: maxTokens);
""")
