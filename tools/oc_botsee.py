import io


def sub(path, old, new):
    s = io.open(path, encoding='utf-8').read()
    n = s.count(old)
    assert n == 1, "expected 1 match in %s, got %d for %r" % (path, n, old[:70])
    io.open(path, 'w', encoding='utf-8').write(s.replace(old, new))


# A bot answering a colleague (bot_ask) is a real call on that colleague's own model, but it was invisible: no ring, no
# record, so the owner could only trust the asker's words (owner 2026-11-25: "I cannot verify if it's lying or it's
# from that bot"). Now the colleague shows a working ring while it answers, and the question and its answer are kept in
# the colleague's own chat, so the owner can open it and read the exchange.
sub('lib/services/bots.dart',
    "  bool Function(Bot b)? working;",
    "  bool Function(Bot b)? working;\n\n"
    "  /// Bots answering a colleague's question right now (bot_ask): the ring shows them working.\n"
    "  final Set<String> consulting = {};\n\n"
    "  /// Tells the ring (BotStatus) the working set changed (a colleague consult started or ended).\n"
    "  void ping() => notifyListeners();")

sub('lib/services/bots.dart',
    "    if (rt.phase == BotPhase.working || (working?.call(b) ?? false)) return 'working';",
    "    if (rt.phase == BotPhase.working || (working?.call(b) ?? false) || consulting.contains(b.id)) return 'working';")

OLD = """  Future<String> _botConsult(Bot asker, Bot expert, String question) async {
    final route = BotModelRoute.of(expert);
    try {
      if (!route.isByok) await RateLimiter.acquire(telesiaRef.provider, 1500, local, onWait: (_) {}, cancelled: () => false);
      // An expert view is a full answer: the model's own maximum, continued when it is cut (was 1,200, owner 2026-11-06).
      final t = await BotLlm.complete(expert, [
        {'role': 'system', 'content': '${Bots.I.chatPromptOf(expert)}\\n\\nYour colleague ${asker.name} (${asker.role}) asks for your expert view. Answer concisely and concretely.'},
        {'role': 'user', 'content': question},
      ], maxTokens: OutputLimits.answer, continues: ReplyContinuation.maxContinues, source: 'bot', background: _backgroundLane(asker.convId), route: route, provider: telesiaRef.provider);
      expert.log('work', 'Helped ${asker.name}: ${question.length > 80 ? '${question.substring(0, 80)}...' : question}');
      unawaited(Bots.I.save());
      return t.trim();
    } catch (e) {
      return 'Could not reach ${expert.name}: $e';
    }
  }"""

NEW = """  Future<String> _botConsult(Bot asker, Bot expert, String question) async {
    final route = BotModelRoute.of(expert);
    // Visible while it answers (the rail ring turns green, then blue "done" until read) and the exchange is written
    // into the expert's own chat, so the owner can open it and see the question really reached that bot (owner 2026-11-25).
    Bots.I.consulting.add(expert.id);
    Bots.I.ping();
    try {
      if (!route.isByok) await RateLimiter.acquire(telesiaRef.provider, 1500, local, onWait: (_) {}, cancelled: () => false);
      // An expert view is a full answer: the model's own maximum, continued when it is cut (was 1,200, owner 2026-11-06).
      final t = await BotLlm.complete(expert, [
        {'role': 'system', 'content': '${Bots.I.chatPromptOf(expert)}\\n\\nYour colleague ${asker.name} (${asker.role}) asks for your expert view. Answer concisely and concretely.'},
        {'role': 'user', 'content': question},
      ], maxTokens: OutputLimits.answer, continues: ReplyContinuation.maxContinues, source: 'bot', background: _backgroundLane(asker.convId), route: route, provider: telesiaRef.provider);
      expert.log('work', 'Helped ${asker.name}: ${question.length > 80 ? '${question.substring(0, 80)}...' : question}');
      unawaited(Bots.I.save());
      final answer = t.trim();
      await _recordBotAsk(asker, expert, question, answer);
      return answer;
    } catch (e) {
      final msg = 'Could not reach ${expert.name}: $e';
      await _recordBotAsk(asker, expert, question, msg);
      return msg;
    } finally {
      Bots.I.consulting.remove(expert.id);
      Bots.I.ping();
    }
  }

  /// Writes a bot-to-bot question and its answer into the expert's own chat, so the owner can verify the exchange
  /// instead of trusting the asker's words. The expert's ring turns blue ("done") until the owner opens that chat.
  Future<void> _recordBotAsk(Bot asker, Bot expert, String question, String answer) async {
    if (expert.convId.isEmpty) return;
    try {
      final list = _lists[expert.convId] ??= await repo.listMessages(expert.convId).catchError((_) => <ChatMessage>[]);
      final q = ChatMessage(id: _uuid.v4(), role: 'user', content: '${asker.name} (colleague) asked:\\n$question');
      final a = ChatMessage(id: _uuid.v4(), role: 'assistant', content: answer);
      list..add(q)..add(a);
      await repo.insertMessage(expert.convId, q);
      await repo.insertMessage(expert.convId, a);
      _notify();
    } catch (_) {}
  }"""

sub('lib/state/bots_controller.dart', OLD, NEW)

print('bot-to-bot: colleague question shows a working ring and the exchange is kept in its chat')
