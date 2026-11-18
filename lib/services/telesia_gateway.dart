import 'dart:convert';

/// Telesia's tools reach opencode through two small MCP tools instead of one per tool (owner, 2026-11-03: "give it as
/// mcp and skill, so it will just use when needed, not every message"). opencode sends every MCP tool's schema with
/// every model call, so the full set (memory, documents, media, apps, connectors, the user's MCP servers...) stays
/// behind [findTool]; opencode looks a tool up when a task needs one and runs it with [runTool]. The `telesia` skill
/// says what is there. Pure, so it is tested without the app.
class TelesiaGateway {
  TelesiaGateway({required this.tools, required this.run, this.redirect});

  /// A tool this caller may call by another name (a bot's `remember` is its own bot_remember): the name it runs as,
  /// or null. The call still runs under its own name (the app maps it).
  final String? Function(String name)? redirect;

  /// opencode's own tools. Called through run_tool they are not found (2026-11-05: run_tool name "webfetch"), so the
  /// answer says to call them directly instead of a bare "no Telesia tool".
  static const engineTools = {
    'bash', 'read', 'write', 'edit', 'glob', 'grep', 'list', 'ls', 'webfetch', 'websearch', 'codesearch', 'todowrite', 'todoread',
    'task', 'skill', 'patch', 'multiOdit', 'question',
  };

  /// The full Telesia tool list (OpenAI function form), read fresh on every lookup.
  final List<Map<String, dynamic>> Function() tools;

  /// Runs one Telesia tool by name (through Telesia's own gate and approval card).
  final Future<String> Function(String name, Map<String, dynamic> args) run;

  static const findName = 'find_tools';
  static const runName = 'run_tool';

  static const findTool = {
    'type': 'function',
    'function': {
      'name': findName,
      'description': 'Find Telesia app tools on this phone (the built-in browser for websites, phone control of other apps, '
          'alarms, SMS, contacts, calendar, WhatsApp, connected apps and their actions, the user\'s MCP servers, '
          'connectors, memory, reading and making documents, pictures and media, the app\'s settings, projects and pages). '
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
      'description': 'Run a Telesia app tool found with find_tools. A risky action asks the user on Telesia\'s approval card first.',
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

  /// Telesia tools offered to opencode by their own name as well (not only through run_tool), because a task needs them
  /// without knowing to look (owner 2026-11-04: "no visual output ability, why?"). Each still runs only when the
  /// calling chat's own tool list has it, and through the same gate as run_tool.
  static const directNames = {'generate_image'};

  /// The MCP tool list: find_tools, run_tool, and each direct tool [available] has right now (generate_image only
  /// while Telesia's server can make pictures).
  static List<Map<String, dynamic>> listing(List<Map<String, dynamic>> available) => [
        ...definitions,
        for (final t in available)
          if (directNames.contains(_fn(t)['name'])) t,
      ];

  static Map<String, dynamic> _fn(Map<String, dynamic> t) =>
      t['function'] is Map ? Map<String, dynamic>.from(t['function'] as Map) : t;

  /// The tool a run_tool call names, and its arguments (for showing the step and routing it to its chat).
  static (String, Map<String, dynamic>) inner(Map<String, dynamic> args) {
    // Models also send the arguments as "parameters" (seen 2026-11-03 in a bot's office wake): read either.
    final a = args['arguments'] ?? args['parameters'];
    Map<String, dynamic> m = const {};
    if (a is Map) {
      m = Map<String, dynamic>.from(a);
    } else if (a is String && a.trim().isNotEmpty) {
      try {
        final d = jsonDecode(a);
        if (d is Map) m = Map<String, dynamic>.from(d);
      } catch (_) {}
    }
    return (bare('${args['name'] ?? ''}'.trim()), m);
  }

  /// A tool name without the MCP wrapper's prefix models often add ("telesia_run_tool", "telesia_apps_list_tools").
  /// Used both where a call is noted for routing and where it runs, so the two always agree (a prefix stripped on one
  /// side only made the route miss and the call fall back to whatever chat was open: bots leak, 2026-11-03).
  static String bare(String name) => name.startsWith('telesia_') ? name.substring('telesia_'.length) : name;

  Future<String> call(String name, Map<String, dynamic> args) async {
    if (name == findName) return find('${args['query'] ?? ''}');
    if (directNames.contains(bare(name))) {
      final n = bare(name);
      if (!tools().any((t) => _fn(t)['name'] == n)) return 'Error: $n is not available here.';
      return run(n, args);
    }
    if (name == runName) {
      // inner() already drops the MCP wrapper's prefix models often add (see bare).
      final (tool, a) = inner(args);
      if (tool.isEmpty) return 'Error: name is required. Use find_tools to see the tools.';
      if (tool == findName || tool == runName) return 'Error: $tool is not a Telesia app tool.';
      if (!tools().any((t) => _fn(t)['name'] == tool)) {
        final to = redirect?.call(tool);
        if (to != null && tools().any((t) => _fn(t)['name'] == to)) return run(tool, a);
        if (engineTools.contains(tool.toLowerCase())) {
          return 'Error: "$tool" is one of your own tools, not a Telesia app tool. Call $tool directly (not through run_tool).';
        }
        return 'Error: no Telesia tool named "$tool". ${find(tool.replaceAll('_', ' '))}';
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
      return 'Telesia tools (look one up with a query for its parameters):\n'
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
    if (scored.isEmpty) return 'No Telesia tool matches "$query". Try other words, or an empty query for the full list.';
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

  /// The `telesia` opencode skill: what the app offers and how to reach it. opencode sees only its name and description
  /// until it loads it.
  static const skill = '''---
name: telesia
description: "Telesia app tools on this phone: a real browser for websites (sign in, forms, shopping, booking), control of the phone and its other apps (tap, type, scroll, alarms, SMS, contacts, calendar, WhatsApp), connected apps (Gmail, Calendar, GitHub...), the user's MCP servers, connectors, memory, reading PDFs/Word/photos, making documents and media, pictures, video, speech and music with the user's own media providers, how to show images, charts, drawings, pages and videos in the chat, the app's settings, projects and pages. Load when a task needs the phone's apps or the user's accounts, or a visual answer."
---

# Telesia app tools

You run inside the Telesia app on the user's phone. Beyond your own tools, the app has its own, reached with two MCP tools:

1. `telesia_find_tools` with a few words for what you need ("gmail send", "calendar", "pdf", "remember"). It returns the matching tools and their parameters. An empty query lists every tool.
2. `telesia_run_tool` with `name` and `arguments`.

What is there:
- Websites: drive Telesia's built-in browser yourself (look it up with `find_tools` "browser"). `browser_open` (url) opens the page, `browser_read` lists its numbered elements and text, then `browser_click` (id), `browser_type` (id, text, submit:true to press Enter), `browser_scroll`, `browser_back`, `browser_wait`. Read again after each change. This runs on your own model (BYOK), never through Telesia's browser agent, so browsing uses none of the user's daily replies. Prefer it for any page that needs clicks, typing or a sign-in; your own webfetch is fine for reading a public page.
- The phone and its other apps: `phone_screen` reads what is on screen (numbered elements), then `phone_tap`, `phone_type`, `phone_scroll`, `phone_gesture`, `phone_nav`, `phone_wait`. Read the screen again after each change. Direct tools are faster when they exist: `set_alarm`, `set_timer`, `open_app`, SMS, contacts, calendar, WhatsApp. Phone control needs the user to switch it on; if a tool says it is off, tell them how.
- Connected apps and their actions: `apps_list_tools` lists an app's actions, `apps_run_tool` runs one. `connect_app` connects a new one.
- The user's own MCP servers: their tools are listed by find_tools. `add_mcp_server` adds a server from a URL (and key). For Composio, pass the user's key as `token`; the app knows the address. Never say a server connected unless add_mcp_server said so.
- Connectors and their APIs.
- Memory: remember, forget, list_memories.
- Reading: PDFs, Word documents, text in photos.
- Making: documents, images to PDF, media conversions.
- Visuals: the chat shows pictures, drawings, charts, pages and videos. `generate_image` makes a photo-like picture (when it is listed). For charts, diagrams, icons, posters and anything with exact shapes or text, write the file yourself: an `.svg` (hand-written SVG), an `.html` page (inline SVG or a canvas/JS chart; it opens full screen), or a `.png` from a script when `python3` is on PATH. `code_media` draws a picture, poster or short animation from JavaScript. Then name the file's path in your answer, or put `![what it is](path)` on its own line: the chat draws it there and a tap opens it full screen. Never paste base64 into the answer.
- Media with the user's own providers: `media_generate` (kind image, video, speech or audio) makes pictures, video, spoken audio (text to speech) and music or sound effects with the media providers the user set up in Settings > Media models (their own keys, called from the phone; look it up with find_tools "media"; it exists only while one is set up). Use it when the user asks for generated media or says to use their provider; never make media they did not ask for. `provider` picks one of theirs by name (empty = their default); `input_image` edits or animates a picture. Video takes minutes: say it is on its way; progress shows in the chat and stopping the chat cancels it. The result shows as a card by itself; do not repeat its path. `generate_image` also uses their image provider when Telesia has no picture model.
- The app: settings, projects, pages (sites).

Risky actions ask the user on Telesia's approval card; wait for the result. If a tool fails, say so plainly; never say it worked.
''';
}
