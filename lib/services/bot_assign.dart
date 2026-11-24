/// Let the agent hand a task to one of the owner's bots — the way opencode spins off a subagent, but onto a person
/// with its own model, role, memory and folder. The assignment and the bot's result are shown as quiet rows in the
/// chat that asked. See the live bot engine in `lib/state/agent_runner.dart` and `_botWake`.
class BotAssign {
  BotAssign._();

  static const names = {'assign_bot'};

  static final List<Map<String, dynamic>> definitions = [
    {
      'type': 'function',
      'function': {
        'name': 'assign_bot',
        'description': 'Hand a task to one of the owner\'s bots, which works it in its own chat and reports the result '
            'back here (like spinning off a teammate with its own model and memory). Use it when a bot is better suited '
            'to the work. The owner sees "Assigned to <bot>" now and the bot\'s result here when it is done — so do not '
            'do the task yourself.',
        'parameters': {
          'type': 'object',
          'properties': {
            'bot': {'type': 'string', 'description': 'The bot\'s name (or id).'},
            'task': {'type': 'string', 'description': 'Exactly what the bot should do, with the detail it needs.'},
          },
          'required': ['bot', 'task'],
        },
      },
    },
  ];

  /// Where a bot's finished task is reported back: bot id -> (the chat that asked, the bot's name). Written when the
  /// agent assigns, read and cleared when the bot's turn ends.
  static final Map<String, ({String owner, String name})> back = {};
}