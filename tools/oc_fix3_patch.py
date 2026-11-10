import sys, pathlib

def patch(path, old, new):
    p = pathlib.Path(path)
    s = p.read_text()
    n = s.count(old)
    if n != 1:
        print("::error file=%s::pattern found %d times" % (path, n))
        sys.exit(1)
    p.write_text(s.replace(old, new))
    print("patched", path)

patch(
    "lib/services/bots.dart",
    """  int get messagesLeft {
    _rollDay();
    return (messageCap - messagesToday).clamp(0, 99).toInt();
  }""",
    """  int get messagesLeft {
    _rollDay();
    // Bound by the real cap: a 'free' bot's cap is _noCap (1000), so clamping at 99 told it "99 left" all day.
    return (messageCap - messagesToday).clamp(0, messageCap).toInt();
  }""",
)

patch(
    "lib/services/bots.dart",
    """  int get callsLeft {
    _rollDay();
    return (callCap - callsToday).clamp(0, 99).toInt();
  }""",
    """  int get callsLeft {
    _rollDay();
    return (callCap - callsToday).clamp(0, callCap).toInt();
  }""",
)

patch(
    "lib/bot_agent/bot_agent_engine.dart",
    """      reply = continuing ? '$reply${r.content}' : r.content;
      if (r.cutOff) {
        if (continues >= config.maxContinues || i >= config.maxSteps - 1) break;
        continues++;""",
    """      reply = continuing ? '$reply${r.content}' : r.content;
      if (r.cutOff) {
        if (continues >= config.maxContinues) {
          // Out of continuations (not the step cap): say so, so a cut reply is not filed as "ran out of steps".
          stopped = 'continues';
          break;
        }
        if (i >= config.maxSteps - 1) break; // the step cap: reported as 'steps' below
        continues++;""",
)

patch(
    "lib/bot_agent/bot_agent_engine.dart",
    """  /// Why the loop ended early: '' the bot answered on its own, 'cancelled', 'stopped' (the app's own guard),
  /// 'steps' (the step cap).
  final String stopped;""",
    """  /// Why the loop ended early: '' the bot answered on its own, 'cancelled', 'stopped' (the app's own guard),
  /// 'steps' (the step cap), 'continues' (a reply still cut off after every continuation).
  final String stopped;""",
)