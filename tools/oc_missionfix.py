import io


def sub(path, old, new):
    s = io.open(path, encoding='utf-8').read()
    n = s.count(old)
    assert n == 1, "expected 1 match in %s, got %d for %r" % (path, n, old[:70])
    io.open(path, 'w', encoding='utf-8').write(s.replace(old, new))


M = 'lib/services/missions.dart'
BC = 'lib/state/bots_controller.dart'
MS = 'lib/widgets/mission_section.dart'

# 1) Answering a [needs you] from the phone's notification Reply did not clear the mission: the words reached the bot's
#    chat but the mission stayed "waiting" forever. The reply now answers the mission too (no extra wake; that turn
#    carries it). A mission that could not start also leaves a line in its log instead of retrying silently.
sub(M,
    "  Future<void> answer(Mission m, bool approved, {String words = ''}) async {",
    "  Future<void> answer(Mission m, bool approved, {String words = '', bool wake = true}) async {")

sub(M,
    "    if (m.on && !m.finished) await setNext(m, clock().add(const Duration(minutes: 1)), 'the owner answered', by: 'app');",
    "    if (wake && m.on && !m.finished) await setNext(m, clock().add(const Duration(minutes: 1)), 'the owner answered', by: 'app');")

sub(M,
    "    if (!ok) {\n      m.runningSince = null;\n      m.runsToday = (m.runsToday - 1).clamp(0, 1 << 30).toInt();\n      await setNext(m, now.add(const Duration(minutes: 20)), 'retry', by: 'app');\n      await save(m);\n    }",
    "    if (!ok) {\n      m.runningSince = null;\n      m.runsToday = (m.runsToday - 1).clamp(0, 1 << 30).toInt();\n      // Say why nothing started, so a paused bot or an exhausted budget is visible instead of a silent retry loop.\n      m.add('skip', 'Could not start (the bot may be paused, busy or out of its daily budget). Again at '\n          '${when(now.add(const Duration(minutes: 20)))}.');\n      await setNext(m, now.add(const Duration(minutes: 20)), 'retry', by: 'app');\n      await save(m);\n    }")

sub(BC,
    "    _notifReplyConvs.add(convId);\n    final bot = Bots.I.byConv(convId);",
    "    _notifReplyConvs.add(convId);\n    final bot = Bots.I.byConv(convId);\n"
    "    // A reply to a mission's \"[needs you]\" is the owner's answer: clear it so the mission goes on (these same\n"
    "    // words reach the bot in the chat below). No extra wake: this reply's own turn carries it.\n"
    "    final waiting = bot == null ? null : Missions.I.liveOf('bot', bot.id);\n"
    "    if (waiting != null && waiting.status == 'waiting' && waiting.needs.isNotEmpty) {\n"
    "      final no = RegExp(r\"^(no|nope|dont|stop|cancel|decline|later|wait)( |$)\", caseSensitive: false).hasMatch(text);\n"
    "      unawaited(Missions.I.answer(waiting, !no, words: text.trim(), wake: false));\n"
    "    }")

# 2) The mission card now says, honestly, whether it will really wake and reach the owner.
sub(MS,
    "import 'package:flutter/material.dart';\n\nimport '../services/missions.dart';",
    "import 'package:flutter/material.dart';\nimport 'package:permission_handler/permission_handler.dart';\n\n"
    "import '../services/always_on.dart';\nimport '../services/bots.dart';\nimport '../services/missions.dart';")

sub(MS,
    "class _MissionSectionState extends State<MissionSection> {\n  @override\n  void initState() {\n    super.initState();\n    Missions.I.init();\n  }",
    "class _MissionSectionState extends State<MissionSection> {\n"
    "  /// Android's own notification switch (off means no brief ever reaches the phone).\n  bool? _notifOk;\n\n"
    "  @override\n  void initState() {\n    super.initState();\n    Missions.I.init();\n"
    "    Permission.notification.status\n"
    "        .then((s) {\n          if (mounted) setState(() => _notifOk = s.isGranted);\n        })\n"
    "        .catchError((Object _) {});\n  }")

sub(MS,
    "                Text(_status(m), style: TextStyle(color: p.muted, fontSize: AppText.meta)),",
    "                Text(_status(m), style: TextStyle(color: p.muted, fontSize: AppText.meta)),\n"
    "                if (m.on) ...[\n                  const SizedBox(height: Space.x1),\n                  Builder(builder: (c) => _healthLine(c, p)),\n                ],")

sub(MS,
    "  @override\n  Widget build(BuildContext context) {\n    return AnimatedBuilder(",
    "  /// One honest line: will this really wake and reach the owner, or is something switched off? The usual silent\n"
    "  /// failures (no notification permission, \"Always on\" off, a paused bot) are named here instead of being found\n"
    "  /// weeks later.\n"
    "  Widget _healthLine(BuildContext context, Palette p) {\n"
    "    final warn = <String>[];\n"
    "    if (_notifOk == false) warn.add('notifications are off');\n"
    "    if (!AlwaysOn.I.on) warn.add('\"Always on\" is off');\n"
    "    if (widget.kind == 'bot' && Bots.I.byId(widget.ownerId)?.active == false) warn.add('the bot is paused');\n"
    "    if (warn.isEmpty) {\n"
    "      return Text('Wakes and reports by itself, also with Telesia closed.',\n"
    "          style: TextStyle(color: p.muted, fontSize: AppText.meta, height: 1.35));\n"
    "    }\n"
    "    return Text('Will not run reliably: ${warn.join(', ')}. Fix in Settings.',\n"
    "        style: TextStyle(color: Palette.red, fontSize: AppText.meta, height: 1.35));\n"
    "  }\n\n"
    "  @override\n  Widget build(BuildContext context) {\n    return AnimatedBuilder(")

print('missions: needs-you reply clears the mission, failures are logged, and the card says if it will really run')
