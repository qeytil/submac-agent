import io


def sub(path, old, new):
    s = io.open(path, encoding='utf-8').read()
    n = s.count(old)
    assert n == 1, "expected 1 match in %s, got %d for %r" % (path, n, old[:70])
    io.open(path, 'w', encoding='utf-8').write(s.replace(old, new))


TR = 'lib/services/team_run.dart'

# In an owner-started team job a member's part runs straight through the team turn, not through the office job pump, so a
# member whose own daily budget was spent just stopped empty: the lead's combined answer quietly missed that part. Say it
# plainly instead, and flag it in the team chat (a bot on its own provider is not billed by Telesia, so it never stops).
sub(TR,
    "import 'bot_manner.dart';",
    "import 'bot_llm.dart';\nimport 'bot_manner.dart';")

sub(TR,
    "  Future<({String note, String result})> _part(Office o, Bot lead, Bot b, String part, TeamPlan plan, List<({Bot bot, String text})> before) async {\n    try {\n      final notes = before.isEmpty",
    "  Future<({String note, String result})> _part(Office o, Bot lead, Bot b, String part, TeamPlan plan, List<({Bot bot, String text})> before) async {\n    try {\n"
    "      // A member whose own daily budget is spent cannot do a real part: say so plainly, so the lead's answer explains\n"
    "      // the missing part instead of the turn just stopping empty. A bot on its own provider is not billed by Telesia,\n"
    "      // so it is never stopped by this.\n"
    "      if (b.overBudget && BotModelRoute.of(b).byok == null) {\n"
    "        TeamStatus.I.flag(o.id, b.id, TeamStatus.outOfBudget);\n"
    "        final f = '${b.name} is out of budget for today, so their part of the job was not done.';\n"
    "        return (note: f, result: f);\n"
    "      }\n"
    "      final notes = before.isEmpty")

print('team: an out-of-budget member says so instead of silently missing their part')