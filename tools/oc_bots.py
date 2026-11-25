import io


def sub(path, old, new):
    s = io.open(path, encoding='utf-8').read()
    n = s.count(old)
    assert n == 1, "expected 1 match in %s, got %d for %r" % (path, n, old[:70])
    io.open(path, 'w', encoding='utf-8').write(s.replace(old, new))


SERVICE = '''/// Let the owner's agent build and run the owner's bots - their digital humans: list them, make a new one, change
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
        'description': 'Create and manage the owner\\'s bots (their digital humans). action "list" shows them with '
            'their state; "create" makes a new one and starts it working; "update" changes its name, role, persona, '
            'mission, model or proactivity; "remove" deletes one. To hand a bot a task, use assign_bot instead.',
        'parameters': {
          'type': 'object',
          'properties': {
            'action': {'type': 'string', 'enum': ['list', 'create', 'update', 'remove']},
            'bot': {'type': 'string', 'description': 'The bot\\'s name (or id), for update or remove.'},
            'name': {'type': 'string', 'description': 'Its name.'},
            'role': {'type': 'string', 'description': 'What it is, one line (e.g. "Market researcher").'},
            'persona': {'type': 'string', 'description': 'How it works and speaks - its instructions.'},
            'mission': {'type': 'string', 'description': 'Its standing job, what it keeps working on.'},
            'model': {'type': 'string', 'description': '"auto" (the owner\\'s default), "telesia", or a configured model id.'},
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
'''
with io.open('lib/services/bot_admin.dart', 'w', encoding='utf-8') as f:
    f.write(SERVICE)

# The import rides with the other service imports (the files below are part of app_state.dart).
sub('lib/app_state.dart',
    "import 'services/bot_assign.dart';",
    "import 'services/bot_assign.dart';\nimport 'services/bot_admin.dart';")

# Offer manage_bots wherever assign_bot is offered (the app tool list and opencode's own list).
sub('lib/state/tool_catalog.dart',
    "        ...CodeTools.definitions,\n        ...CaseTools.definitions,\n        ...BotAssign.definitions,\n        ...ModelBridge.definitions,",
    "        ...CodeTools.definitions,\n        ...CaseTools.definitions,\n        ...BotAssign.definitions,\n        ...BotAdmin.definitions,\n        ...ModelBridge.definitions,")

sub('lib/state/agent_runner.dart',
    "        ...DocMaker.definitions,\n        ...CaseTools.definitions,\n        ...BotAssign.definitions,\n        ...ModelBridge.definitions,",
    "        ...DocMaker.definitions,\n        ...CaseTools.definitions,\n        ...BotAssign.definitions,\n        ...BotAdmin.definitions,\n        ...ModelBridge.definitions,")

# Dispatch.
sub('lib/state/tool_router.dart',
    "    if (BotAssign.names.contains(name)) return _assignBot(args, convId);",
    "    if (BotAssign.names.contains(name)) return _assignBot(args, convId);\n"
    "    if (BotAdmin.names.contains(name)) return _manageBots(args, convId);")

METHOD = '''  /// manage_bots: the owner's agent makes and runs the owner's bots (their digital humans) - list, create, update,
  /// remove. Handing one a task is assign_bot.
  Future<String> _manageBots(Map<String, dynamic> a, String? convId) async {
    String str(String k) => '${a[k] ?? ''}'.trim();
    final action = str('action').toLowerCase();
    Bot? find() {
      final who = str('bot');
      if (who.isEmpty) return null;
      return Bots.I.byName(who) ?? Bots.I.byId(who);
    }

    String noBot() {
      final names = Bots.I.bots.map((x) => x.name).where((n) => n.trim().isNotEmpty).join(', ');
      return names.isEmpty ? 'The owner has no bots yet.' : 'No bot named "${str('bot')}". Their bots: $names.';
    }

    if (action == 'list') {
      if (Bots.I.bots.isEmpty) return 'The owner has no bots yet.';
      return Bots.I.bots
          .map((b) => '- ${b.name}${b.role.isEmpty ? '' : ' - ${b.role}'}'
              '${b.active ? ' (working)' : ' (not started)'}, model ${b.model}, ${b.proactivity}')
          .join('\\n');
    }
    if (action == 'create') {
      final name = str('name');
      final role = str('role');
      if (name.isEmpty || role.isEmpty) return 'Error: give at least a name and a role.';
      if (Bots.I.byName(name) != null) return 'Error: a bot named "$name" already exists.';
      final b = await Bots.I.create(<String, dynamic>{
        'name': name,
        'role': role,
        'persona': str('persona'),
        'mission': str('mission'),
        'proactivity': str('proactivity').isEmpty ? 'free' : str('proactivity'),
        if (a['heartbeat_hours'] is num) 'heartbeat_hours': a['heartbeat_hours'],
      });
      if (str('model').isNotEmpty) await Bots.I.setModel(b, str('model'));
      final start = a['start'] != false;
      var started = false;
      if (start && await _ensureBotConv(b)) {
        await Bots.I.hire(b, b.convId);
        started = true;
      }
      return 'Created ${b.name}${b.role.isEmpty ? '' : ', ${b.role}'}${started ? ' and started it' : ''}. '
          'It is in Bots: the Bots row in the menu, then its face in the side rail. Give it a task with assign_bot.';
    }
    if (action == 'update') {
      final b = find();
      if (b == null) return noBot();
      if (str('name').isNotEmpty) b.name = str('name');
      if (str('role').isNotEmpty) b.role = str('role');
      if (str('persona').isNotEmpty) b.persona = str('persona');
      if (str('mission').isNotEmpty) b.mission = str('mission');
      if (str('proactivity').isNotEmpty) b.proactivity = str('proactivity');
      if (a['heartbeat_hours'] is num) b.heartbeatHours = (a['heartbeat_hours'] as num).toInt().clamp(0, 48).toInt();
      if (str('model').isNotEmpty) await Bots.I.setModel(b, str('model'));
      await Bots.I.save();
      return 'Updated ${b.name}.';
    }
    if (action == 'remove') {
      final b = find();
      if (b == null) return noBot();
      final name = b.name;
      await Bots.I.remove(b);
      return 'Removed $name.';
    }
    return 'Error: action must be list, create, update or remove.';
  }

'''

sub('lib/state/tool_router.dart',
    "  Future<ActionRequest?> _riskFor(String name, Map<String, dynamic> args) async {",
    METHOD + "  Future<ActionRequest?> _riskFor(String name, Map<String, dynamic> args) async {")

print('opencode: manage_bots tool (list/create/update/remove the owner\'s bots)')
