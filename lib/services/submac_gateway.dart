import 'dart:convert';

/// SubMac's tools reach opencode through two small MCP tools instead of one per tool (owner, 2026-11-03: "give it as
/// mcp and skill, so it will just use when needed, not every message"). opencode sends every MCP tool's schema with
/// every model call, so the full set (memory, documents, media, apps, connectors, the user's MCP servers...) stays
/// behind [findTool]; opencode looks a tool up when a task needs one and runs it with [runTool]. The `submac` skill
/// says what is there. Pure, so it is tested without the app.
class SubMacGateway {
  SubMacGateway({required this.tools, required this.run});

  /// The full SubMac tool list (OpenAI function form), read fresh on every lookup.
  final List<Map<String, dynamic>> Function() tools;

  /// Runs one SubMac tool by name (through SubMac's own gate and approval card).
  final Future<String> Function(String name, Map<String, dynamic> args) run;

  static const findName = 'find_tools';
  static const runName = 'run_tool';

  static const findTool = {
    'type': 'function',
    'function': {
      'name': findName,
      'description': 'Find SubMac app tools on this phone (the built-in browser for websites, phone control of other apps, '
          'alarms, SMS, contacts, calendar, WhatsApp, connected apps and their actions, the user\'s MCP servers, '
          'connectors, memory, reading and making documents and media, the app\'s settings, projects and pages). '
          'Returns matching tools with their parameters; run one with run_tool. An empty query lists every tool by name.',
      'parameters': {
        'type': 'object',
        'properties': {
          'query': {'type': 'string', 'description': 'Words for what you need, e.g. "gmail send", "pdf", "remember"'},
        },
      },
    },
  };

  static const runTool = {
    'type': 'function',
    'function': {
      'name': runName,
      'description': 'Run a SubMac app tool found with find_tools. A risky action asks the user on SubMac\'s approval card first.',
      'parameters': {
        'type': 'object',
        'properties': {
          'name': {'type': 'string', 'description': 'The tool name from find_tools'},
          'arguments': {'type': 'object', 'description': 'The tool\'s arguments, as its parameters describe'},
        },
        'required': ['name'],
      },
    },
  };

  static const definitions = [findTool, runTool];

  static Map<String, dynamic> _fn(Map<String, dynamic> t) =>
      t['function'] is Map ? Map<String, dynamic>.from(t['function'] as Map) : t;

  /// The tool a run_tool call names, and its arguments (for showing the step and routing it to its chat).
  static (String, Map<String, dynamic>) inner(Map<String, dynamic> args) {
    final a = args['arguments'];
    Map<String, dynamic> m = const {};
    if (a is Map) {
      m = Map<String, dynamic>.from(a);
    } else if (a is String && a.trim().isNotEmpty) {
      try {
        final d = jsonDecode(a);
        if (d is Map) m = Map<String, dynamic>.from(d);
      } catch (_) {}
    }
    return ('${args['name'] ?? ''}'.trim(), m);
  }

  Future<String> call(String name, Map<String, dynamic> args) async {
    if (name == findName) return find('${args['query'] ?? ''}');
    if (name == runName) {
      final (tool, a) = inner(args);
      if (tool.isEmpty) return 'Error: name is required. Use find_tools to see the tools.';
      if (tool == findName || tool == runName) return 'Error: $tool is not a SubMac app tool.';
      if (!tools().any((t) => _fn(t)['name'] == tool)) {
        return 'Error: no SubMac tool named "$tool". ${find(tool.replaceAll('_', ' '))}';
      }
      return run(tool, a);
    }
    return 'Error: unknown tool $name.';
  }

  /// Matching tools with their parameters (best first, at most 8); every name when the query is empty.
  String find(String query) {
    final all = [for (final t in tools()) _fn(t)];
    final words = query.toLowerCase().split(RegExp(r'[^a-z0-9]+')).where((w) => w.length > 1).toList();
    if (words.isEmpty) {
      return 'SubMac tools (look one up with a query for its parameters):\n'
          '${all.map((f) => '- ${f['name']}: ${_short('${f['description'] ?? ''}')}').join('\n')}';
    }
    final scored = <(int, Map<String, dynamic>)>[];
    for (final f in all) {
      final n = '${f['name']}'.toLowerCase();
      final d = '${f['description'] ?? ''}'.toLowerCase();
      var s = 0;
      for (final w in words) {
        if (n.contains(w)) s += 3;
        if (d.contains(w)) s += 1;
      }
      if (s > 0) scored.add((s, f));
    }
    scored.sort((a, b) => b.$1.compareTo(a.$1));
    if (scored.isEmpty) return 'No SubMac tool matches "$query". Try other words, or an empty query for the full list.';
    return jsonEncode([
      for (final (_, f) in scored.take(8))
        {'name': f['name'], 'description': f['description'], 'parameters': f['parameters'] ?? {'type': 'object'}},
    ]);
  }

  static String _short(String d) {
    final i = d.indexOf('. ');
    final s = i > 0 ? d.substring(0, i + 1) : d;
    return s.length > 140 ? '${s.substring(0, 137)}...' : s;
  }

  /// The `submac` opencode skill: what the app offers and how to reach it. opencode sees only its name and description
  /// until it loads it.
  static const skill = '''---
name: submac
description: "SubMac app tools on this phone: a real browser for websites (sign in, forms, shopping, booking), control of the phone and its other apps (tap, type, scroll, alarms, SMS, contacts, calendar, WhatsApp), connected apps (Gmail, Calendar, GitHub...), the user's MCP servers, connectors, memory, reading PDFs/Word/photos, making documents and media, the app's settings, projects and pages. Load when a task needs the phone's apps or the user's accounts."
---

# SubMac app tools

You run inside the SubMac app on the user's phone. Beyond your own tools, the app has its own, reached with two MCP tools:

1. `submac_find_tools` with a few words for what you need ("gmail send", "calendar", "pdf", "remember"). It returns the matching tools and their parameters. An empty query lists every tool.
2. `submac_run_tool` with `name` and `arguments`.

What is there:
- Websites: `browser_task` hands a whole job (sign in, fill forms, book, shop, research across pages) to SubMac's browser agent, which shows the user a live card and returns its report. Give the full goal with every detail. `wait:false` runs several jobs at once; then `browser_task_wait`. Use it whenever a page needs clicks, typing or a sign-in; your own webfetch is fine for reading a public page.
- The phone and its other apps: `phone_screen` reads what is on screen (numbered elements), then `phone_tap`, `phone_type`, `phone_scroll`, `phone_gesture`, `phone_nav`, `phone_wait`. Read the screen again after each change. Direct tools are faster when they exist: `set_alarm`, `set_timer`, `open_app`, SMS, contacts, calendar, WhatsApp. Phone control needs the user to switch it on; if a tool says it is off, tell them how.
- Connected apps and their actions: `apps_list_tools` lists an app's actions, `apps_run_tool` runs one. `connect_app` connects a new one.
- The user's own MCP servers: their tools are listed by find_tools. `add_mcp_server` adds a server from a URL (and key).
- Connectors and their APIs.
- Memory: remember, forget, list_memories.
- Reading: PDFs, Word documents, text in photos.
- Making: documents, images to PDF, media conversions, images (when switched on).
- The app: settings, projects, pages (sites).

Risky actions ask the user on SubMac's approval card; wait for the result. If a tool fails, say so plainly; never say it worked.
''';
}
