import io


def sub(path, old, new):
    s = io.open(path, encoding='utf-8').read()
    n = s.count(old)
    assert n == 1, "expected 1 match in %s, got %d for %r" % (path, n, old[:70])
    io.open(path, 'w', encoding='utf-8').write(s.replace(old, new))


E = 'lib/bot_agent/bot_agent_engine.dart'
AR = 'lib/state/agent_runner.dart'

# The bot kept answering "let me do this" and then doing nothing: a step that came back with words and no tool call was
# taken as the final answer, so a model that only narrates ended the whole turn having acted on nothing. The loop now
# notices that once per turn - when nothing has run yet and the bot clearly means to act (or this is background work
# that must deliver) - and asks it to actually use its tools, then takes the next reply as final.

sub(E,
    "    required this.cancelled,\n    this.stop,\n    this.onStep,\n  });",
    "    required this.cancelled,\n    this.stop,\n    this.onStep,\n    this.mustAct = false,\n  });")

sub(E,
    "  /// Called after every model step with what it used, so the app can bill the bot as the turn goes.\n"
    "  final void Function(LlmResult r)? onStep;",
    "  /// Called after every model step with what it used, so the app can bill the bot as the turn goes.\n"
    "  final void Function(LlmResult r)? onStep;\n\n"
    "  /// This turn is background work the owner is waiting on: the bot must actually act, never just say it will.\n"
    "  final bool mustAct;\n\n"
    "  /// Words that mean the model intends to act (\"Let me do this\", \"I'll now...\") but has not called a tool yet.\n"
    "  static final _intent = RegExp(\n"
    "      r\"\\b(i'?ll|i will|i am going to|i'?m going to|let me|now i|i'?m now|starting to|going to|will now|next,? i|first,? i|i'?m on it|on it now)\\b\",\n"
    "      caseSensitive: false);")

sub(E,
    "    var stopped = '';",
    "    var stopped = '';\n    var nudged = false;")

sub(E,
    "      // A reply that ran out of room goes on in the same turn instead of ending mid-sentence.\n"
    "      reply = continuing ? '$reply${r.content}' : r.content;",
    "      // A step that only talks (no tool call) used to end the turn there, so a narrating model just said \"let me do\n"
    "      // this\" and did nothing, and the bot looked broken. When nothing has run yet and it clearly means to act (or\n"
    "      // this is background work that must deliver), ask it once to actually use its tools, then take the next reply\n"
    "      // as final (one nudge only; a model that truly cannot call tools still ends here).\n"
    "      if (!nudged && calls == 0 && !continuing && r.content.trim().isNotEmpty && (mustAct || _intent.hasMatch(r.content))) {\n"
    "        nudged = true;\n"
    "        messages.add({'role': 'assistant', 'content': r.content});\n"
    "        messages.add({\n"
    "          'role': 'user',\n"
    "          'content': 'You have not used any tool yet. Do the task NOW with your tools: run the tool, do not describe or '\n"
    "              'promise it. When it is truly finished, reply with only the final result for the user.',\n"
    "        });\n"
    "        continue;\n"
    "      }\n"
    "      // A reply that ran out of room goes on in the same turn instead of ending mid-sentence.\n"
    "      reply = continuing ? '$reply${r.content}' : r.content;")

# A bot's own wake is background work when nobody is at that chat; office/team work always is.
sub(AR,
    "    final engine = BotAgentEngine(\n      config: cfg,\n      cancelled: () => run.cancelled,",
    "    final engine = BotAgentEngine(\n      config: cfg,\n      mustAct: bg,\n      cancelled: () => run.cancelled,")

sub(AR,
    "      final engine = BotAgentEngine(\n        config: cfg,\n        cancelled: dead,",
    "      final engine = BotAgentEngine(\n        config: cfg,\n        mustAct: true,\n        cancelled: dead,")

print('bot engine: a narrating step is nudged once to actually act')
