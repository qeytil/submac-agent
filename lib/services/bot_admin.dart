/// Let the owner's agent build and run the owner's bots - their digital humans: list them, make a new one, change
/// one, remove one. Handing one a task is a separate tool (assign_bot). See hire/remove/create in
/// `lib/services/bots.dart` and the chat setup in `lib/state/bots_controller.dart`.
class BotAdmin {
  BotAdmin._();

  static const names = {'manage_bots'};

  static final List<Map<String, dynamic>> definitions = [
    {
      'type': 'function',
      'function': {
        'name': 'manage_bots',
        'description': 'Create and manage the owner\'s bots (their digital humans). action "list" shows them with '
            'their state; "create" makes a new one and starts it working; "update" changes its name, role, persona, '
            'mission, model or proactivity; "remove" deletes one. To hand a bot a task, use assign_bot instead.',
        'parameters': {
          'type': 'object',
          'properties': {
            'action': {'type': 'string', 'enum': ['list', 'create', 'update', 'remove']},
            'bot': {'type': 'string', 'description': 'The bot\'s name (or id), for update or remove.'},
            'name': {'type': 'string', 'description': 'Its name.'},
            'role': {'type': 'string', 'description': 'What it is, one line (e.g. "Market researcher").'},
            'persona': {'type': 'string', 'description': 'How it works and speaks - its instructions.'},
            'mission': {'type': 'string', 'description': 'Its standing job, what it keeps working on.'},
            'model': {'type': 'string', 'description': '"auto" (the owner\'s default), "telesia", or a configured model id.'},
            'proactivity': {'type': 'string', 'enum': ['free', 'careful', 'quiet'], 'description': 'How freely it speaks up on its own.'},
            'heartbeat_hours': {'type': 'number', 'description': 'How often it checks in by itself, in hours (0 = never).'},
            'start': {'type': 'boolean', 'description': 'create: start it working now (default true).'},
          },
          'required': ['action'],
        },
      },
    },
  ];
}
