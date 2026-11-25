// The per-bot configuration of Telesia's own bot engine (owner 2026-11-07).
//
// Bots used to run on opencode, the same engine as the owner's chat. A bot is a "digital person" that works on its own,
// 24/7, on the phone and under its own profile (its model, its allowance, its notes folder), so it gets its own engine:
// one bot, one [BotAgentConfig]. opencode stays reserved for the Telesia agent (the owner's chat). See docs/bot-autonomy.md.

import '../services/bots.dart';

/// Everything one bot's turn needs that does not depend on the conversation: who it is, its notes folder and the
/// limits its own loop runs under. Stable per bot, kept by [BotAgents] for the life of the app.
class BotAgentConfig {
  BotAgentConfig({
    required this.botId,
    required this.name,
    required this.folder,
    this.maxSteps = 40,
    this.maxContinues = 4,
    this.maxToolChars = 16000,
    this.parallelTools = false,
  });

  /// The bot this engine runs for.
  final String botId;

  /// The bot's name, shown in logs and the notification line.
  final String name;

  /// The bot's own folder inside Telesia's workspace (notes, drafts, files).
  final String folder;

  /// The most model steps one turn may take (each step may run tools). A backstop against a looping bot.
  final int maxSteps;

  /// The most times a reply cut for length is continued.
  final int maxContinues;

  /// The most characters of a tool's output kept in the model's context and the chat row.
  final int maxToolChars;

  /// Run a step's tool calls at the same time when there is more than one (a team's independent hand-offs). Off for a
  /// bot's own chat, where steps usually run one tool and rows must stay in order.
  final bool parallelTools;

  /// A stable key for the bot's own session and log lines (never shared with the owner's chat).
  String get sessionKey => 'bot:$botId';

  @override
  String toString() => 'BotAgentConfig($botId, $name)';
}

/// One [BotAgentConfig] per bot, kept for the life of the app so a bot always runs under the same config.
class BotAgents {
  BotAgents._();

  static final BotAgents I = BotAgents._();

  final Map<String, BotAgentConfig> _byId = {};

  BotAgentConfig forBot(Bot b) => _byId.putIfAbsent(
        b.id,
        () => BotAgentConfig(botId: b.id, name: b.name, folder: Bots.botFolder(b)),
      );

  void forget(String botId) => _byId.remove(botId);

  /// Tests: start from no configs.
  void clear() => _byId.clear();
}