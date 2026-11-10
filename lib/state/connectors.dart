// Connected apps and MCP servers, plus memory facts.
// Split out of app_state.dart (no behaviour change). Fields stay on AppState.
part of '../app_state.dart';

extension AppStateConnectors on AppState {
  // ---------- connectors ----------
  Future<void> _saveMcp() => local.setSecret('mcpServers', jsonEncode(mcpServers.map((e) => e.toJson()).toList()));

  Future<void> upsertMcpServer(McpServerConfig s) async {
    final i = mcpServers.indexWhere((e) => e.id == s.id);
    if (i >= 0) {
      mcpServers[i] = s;
    } else {
      mcpServers.add(s);
    }
    McpClient.reset(s.id);
    await _saveMcp();
    _notify();
    unawaited(refreshMcpTools());
  }

  /// Stops a sign-in that is waiting on the browser (the Cancel on a Connecting row).
  void cancelMcpSignIn() => McpOAuth.cancel('Stopped. Tap Try again whenever you like.');

  /// Connects a ready-made app: open ones straight away, the rest by signing in in the browser.
  /// Returns null when connected, or a plain sentence saying what went wrong.
  Future<String?> connectMcpPreset(McpPreset pr, {String? key}) =>
      pr.needsKey ? connectMcpKey(pr, key ?? '') : connectMcpUrl(pr.url, name: pr.name, key: pr.id, signIn: pr.signIn);

  /// An app connected with a key the user pasted. It is saved only when the app answers with its tools; otherwise
  /// the app's real answer comes back and nothing half-connected stays in Apps.
  Future<String?> connectMcpKey(McpPreset pr, String key) async {
    final k = key.trim();
    if (k.isEmpty) return 'Paste your ${pr.name} key first.';
    if (mcpSigningIn.contains(pr.id)) return null;
    mcpSigningIn.add(pr.id);
    mcpConnectError.remove(pr.id);
    _notify();
    try {
      final existing = mcpServers.where((e) => e.url == pr.url).firstOrNull;
      final s = McpServerConfig(id: existing?.id ?? _uuid.v4(), name: pr.name, url: pr.url, headers: {pr.keyHeader!: k});
      McpClient.reset(s.id);
      List<McpTool> tools;
      try {
        tools = await McpClient(s).listTools().timeout(const Duration(seconds: 30));
      } catch (e) {
        final raw = '$e'.replaceFirst('Exception: ', '');
        final msg = RegExp(r'HTTP 40[13]').hasMatch(raw)
            ? '${pr.name} did not accept that key. Check it and paste it again.'
            : Calm.short(raw, app: pr.name);
        mcpConnectError[pr.id] = msg;
        return msg;
      }
      if (tools.isEmpty) {
        final msg = '${pr.name} answered but offered no tools. Check the key.';
        mcpConnectError[pr.id] = msg;
        return msg;
      }
      if (existing != null) {
        existing
          ..headers = s.headers
          ..enabled = true;
        McpClient.reset(existing.id);
        await upsertMcpServer(existing);
      } else {
        await upsertMcpServer(s);
      }
      // Earlier failed tries at the same app (other addresses, no tools) go, so Apps shows one working entry.
      for (final o in [...mcpServers]) {
        if (o.url != pr.url && o.name.toLowerCase() == pr.name.toLowerCase() && !mcpTools.any((t) => t.server.id == o.id)) {
          await deleteMcpServer(o.id);
        }
      }
      await (_mcpRefreshing ?? refreshMcpTools()).timeout(const Duration(seconds: 30), onTimeout: () {});
      return null;
    } finally {
      mcpSigningIn.remove(pr.id);
      _notify();
    }
  }

  Future<String?> connectMcpUrl(String url, {required String name, String? key, bool? signIn}) async {
    final k = key ?? url;
    if (mcpSigningIn.contains(k)) return null;
    mcpSigningIn.add(k);
    mcpConnectError.remove(k);
    _notify();
    McpClient.onTokensChanged ??= () => unawaited(_saveMcp());
    try {
      final existing = mcpServers.where((e) => e.url == url).firstOrNull;
      var needs = signIn;
      if (needs == null) {
        final w = await McpOAuth.probe(url);
        if (w == null) return '$name isn\'t answering right now. Check your internet, then tap Connect again.';
        needs = w.isNotEmpty;
      }
      final s = existing ?? McpServerConfig(id: _uuid.v4(), name: name, url: url);
      if (needs) {
        final tok = await McpOAuth.signIn(url, appName: name, backToApp: () => SystemBridge.I.bringToFront());
        s.oauth = tok;
        s.headers['Authorization'] = 'Bearer ${tok['access_token']}';
      }
      s.enabled = true;
      await upsertMcpServer(s);
      return null;
    } catch (e) {
      final raw = '$e'.replaceFirst('Exception: ', '');
      // Network trouble reads as one warm line; the sign-in's own messages are already plain.
      final msg = RegExp(r'socket|host lookup|timeout|handshake|clientexception|connection', caseSensitive: false).hasMatch(raw)
          ? Calm.short(raw, app: name)
          : raw;
      mcpConnectError[k] = msg;
      return msg;
    } finally {
      mcpSigningIn.remove(k);
      _notify();
    }
  }

  /// The agent adds an MCP server the user described in chat (address, and a key or token when it needs one). It is
  /// saved like one added in Apps, so it shows there and every chat, bot and call can use it. No key: Telesia checks
  /// whether the server wants a sign-in and opens it.
  Future<String> addMcpServerFromChat(Map<String, dynamic> a) async {
    final token = '${a['token'] ?? ''}'.trim();
    final known = McpKnown.fix('${a['url'] ?? ''}'.trim(), token, '${a['header'] ?? ''}'.trim());
    final url = known.url;
    final header = known.header;
    final u = Uri.tryParse(url);
    if (u == null || !(u.isScheme('https') || u.isScheme('http')) || u.host.isEmpty) {
      return 'Error: url must be the server\'s full http(s) address.';
    }
    final name = '${a['name'] ?? ''}'.trim().isEmpty ? u.host : '${a['name']}'.trim();
    final extra = a['headers'] is Map ? Map<String, dynamic>.from(a['headers'] as Map) : const <String, dynamic>{};
    final before = mcpServers.where((e) => e.url == url).firstOrNull;
    final beforeJson = before?.toJson();
    if (token.isEmpty && extra.isEmpty) {
      final err = await connectMcpUrl(url, name: name);
      if (err != null) return 'Error: $err';
    } else {
      final s = mcpServers.where((e) => e.url == url).firstOrNull ?? McpServerConfig(id: _uuid.v4(), name: name, url: url);
      s.name = name;
      for (final e in extra.entries) {
        s.headers[e.key] = '${e.value}';
      }
      if (token.isNotEmpty) {
        final h = header.isEmpty ? 'Authorization' : header;
        s.headers[h] = h.toLowerCase() == 'authorization' && !token.contains(' ') ? 'Bearer $token' : token;
      }
      s.enabled = true;
      await upsertMcpServer(s);
    }
    await (_mcpRefreshing ?? refreshMcpTools()).timeout(const Duration(seconds: 30), onTimeout: () {});
    final s = mcpServers.where((e) => e.url == url).firstOrNull;
    final n = s == null ? 0 : mcpTools.where((t) => t.server.id == s.id).length;
    final st = s == null ? '' : (mcpStatus[s.id] ?? '');
    if (n == 0) {
      // Nothing half-connected stays behind (2026-11-03: failed tries left "Composio · 0 tools" entries in Apps).
      if (s != null) {
        if (beforeJson == null) {
          await deleteMcpServer(s.id);
        } else {
          final old = McpServerConfig.fromJson(beforeJson);
          s
            ..name = old.name
            ..headers = old.headers
            ..enabled = old.enabled;
          McpClient.reset(s.id);
          await upsertMcpServer(s);
        }
      }
      return 'Error: $name did not connect: it answered "$st" at $url. Nothing was saved. Do not tell the user it is '
          'connected. Check the address and the key with the user; do not guess other addresses.';
    }
    // Earlier failed tries at the same app under other addresses go, so Apps shows one working entry.
    for (final o in [...mcpServers]) {
      if (o.id != s!.id && o.name.toLowerCase() == name.toLowerCase() && !mcpTools.any((t) => t.server.id == o.id)) {
        await deleteMcpServer(o.id);
      }
    }
    return '$name is connected ($n tools) and saved in the user\'s Apps. Its tools work now: look them up with find_tools '
        '(or apps_list_tools with app "$name") and run them with run_tool.';
  }

  Future<void> deleteMcpServer(String id) async {
    mcpServers.removeWhere((e) => e.id == id);
    mcpTools.removeWhere((t) => t.server.id == id);
    mcpStatus.remove(id);
    McpClient.reset(id);
    await _saveMcp();
    _notify();
  }

  /// [all]: every app tool (for opencode, which looks tools up with find_tools instead of being sent each schema).
  List<Map<String, dynamic>> _mcpToolDefs({bool all = false}) {
    if (mcpTools.isEmpty && !mcpServers.any((s) => s.enabled)) return const [];
    final defs = <Map<String, dynamic>>[];
    if (all || mcpTools.length <= AppState._directMcpLimit) {
      defs.addAll(mcpTools.map((t) => t.toDefinition()));
    } else {
      // A fair share per app, read/search tools first (they unlock everything else).
      final byServer = <String, List<McpTool>>{};
      for (final t in mcpTools) {
        byServer.putIfAbsent(t.server.id, () => []).add(t);
      }
      final share = (AppState._directMcpLimit / byServer.length).floor().clamp(1, AppState._directMcpLimit);
      for (final list in byServer.values) {
        final sorted = [...list]..sort((a, b) => (AppState._readOnlyTool.hasMatch(a.name) ? 0 : 1).compareTo(AppState._readOnlyTool.hasMatch(b.name) ? 0 : 1));
        defs.addAll(sorted.take(share).map((t) => t.toDefinition()));
      }
      if (defs.length > AppState._directMcpLimit) defs.removeRange(AppState._directMcpLimit, defs.length);
    }
    final apps = mcpServers.where((s) => s.enabled).map((s) => s.name).join(', ');
    defs.add({
      'type': 'function',
      'function': {
        'name': 'apps_list_tools',
        'description': 'List what a connected app can do: every tool with its description and inputs. Connected: $apps. '
            'Call this first when you need an app action you do not see as a tool, or are unsure which inputs a tool takes.',
        'parameters': {
          'type': 'object',
          'properties': {
            'app': {'type': 'string', 'description': 'App name, e.g. "Notion". Empty = all apps (names only).'},
            'query': {'type': 'string', 'description': 'Optional words to filter tools, e.g. "create page".'},
          },
        },
      },
    });
    defs.add({
      'type': 'function',
      'function': {
        'name': 'apps_run_tool',
        'description': 'Run any tool of a connected app by its exact name from apps_list_tools, with its arguments.',
        'parameters': {
          'type': 'object',
          'properties': {
            'app': {'type': 'string'},
            'tool': {'type': 'string', 'description': 'Exact tool name from apps_list_tools.'},
            'arguments': {'type': 'object', 'description': 'The tool inputs, matching its schema.'},
          },
          'required': ['tool'],
        },
      },
    });
    return defs;
  }

  McpTool? _findMcpTool(String tool, String app, {Bot? bot}) {
    final t = tool.trim();
    final a = app.trim().toLowerCase();
    McpTool? hit;
    for (final e in mcpTools) {
      if (bot != null && !_botToolOk(bot, e)) continue;
      if (e.fnName == t || e.name == t) {
        if (a.isEmpty || e.server.name.toLowerCase().contains(a) || a.contains(e.server.name.toLowerCase())) return e;
        hit ??= e;
      }
    }
    return hit;
  }

  String _appTools(Map<String, dynamic> args, {Bot? bot}) {
    if (mcpTools.isEmpty) {
      final on = mcpServers.where((s) => s.enabled).toList();
      if (on.isEmpty) return 'No apps are connected. The user can connect one in Apps > Sign in, or you can call connect_app to show the connect sheet.';
      return 'Connected but not reachable right now: ${on.map((s) => '${s.name} (${mcpStatus[s.id] ?? 'loading'})').join(', ')}. '
          'Tell the user in one line to reconnect it in Apps if it says signed out or 401.';
    }
    final app = '${args['app'] ?? ''}'.trim().toLowerCase();
    final words = '${args['query'] ?? ''}'.toLowerCase().split(RegExp(r'\s+')).where((w) => w.length > 1).toList();
    final sb = StringBuffer();
    final servers = mcpServers.where((s) =>
        s.enabled &&
        (bot == null || !bot.appsScoped || _botMcp(bot, s) != null) &&
        (app.isEmpty || s.name.toLowerCase().contains(app) || app.contains(s.name.toLowerCase())));
    if (servers.isEmpty) return 'No connected app called "${args['app']}". Connected: ${mcpServers.map((s) => s.name).join(', ')}.';
    for (final s in servers) {
      final tools = mcpTools.where((t) => t.server.id == s.id && (bot == null || _botToolOk(bot, t))).where((t) {
        if (words.isEmpty) return true;
        final hay = '${t.name} ${t.description}'.toLowerCase();
        return words.any(hay.contains);
      }).toList();
      sb.writeln('## ${s.name} (${tools.length} tools)');
      for (final t in tools) {
        if (app.isEmpty && words.isEmpty) {
          // Overview: names and a few words each. Ask with app or query for inputs.
          var d = t.description.replaceAll(RegExp(r'\s+'), ' ').trim();
          if (d.length > 60) d = '${d.substring(0, 60)}…';
          sb.writeln('- ${t.name}${d.isEmpty ? '' : ': $d'}');
          continue;
        }
        var d = t.description.replaceAll(RegExp(r'\s+'), ' ');
        if (d.length > 240) d = '${d.substring(0, 240)}…';
        final props = (t.schema['properties'] as Map?) ?? const {};
        final req = ((t.schema['required'] as List?) ?? const []).map((e) => '$e').toSet();
        final inputs = [
          for (final e in props.entries)
            '${e.key}${req.contains(e.key) ? '*' : ''}:${(e.value is Map ? (e.value as Map)['type'] : null) ?? 'any'}'
        ].join(', ');
        sb.writeln('- ${t.name}: $d\n  inputs: ${inputs.isEmpty ? 'none' : inputs}  (* = required)');
      }
    }
    var out = sb.toString();
    if (out.length > 4000) out = '${out.substring(0, 4000)}\n…(more: call again with app and query words to narrow it)';
    return out;
  }

  /// Every enabled app, in parallel, each with its own time limit, so one slow or signed-out app
  /// never hides the tools of the others. Keeps an app's last good tools if it fails this time.
  Future<void> refreshMcpTools() => _mcpRefreshing = _refreshMcp();

  Future<void> _refreshMcp() async {
    final servers = mcpServers.where((e) => e.enabled).toList();
    final lists = await Future.wait(servers.map((s) async {
      try {
        final tools = await McpClient.of(s).listTools().timeout(const Duration(seconds: 25));
        mcpStatus[s.id] = 'Connected · ${tools.length} tools';
        return tools;
      } catch (e) {
        mcpStatus[s.id] = Calm.short(e, app: s.name);
        return mcpTools.where((t) => t.server.id == s.id).toList();
      }
    }));
    final seen = <String>{};
    mcpTools = [for (final l in lists) for (final t in l) if (seen.add(t.fnName)) t];
    _mcpListedAt = DateTime.now();
    _notify();
  }

  /// Before a task: make sure every connected app's tools are loaded (new sign-ins, restarts, expiries).
  Future<void> ensureMcpTools() async {
    final enabled = mcpServers.where((e) => e.enabled).toList();
    if (enabled.isEmpty) return;
    final missing = enabled.any((s) => !mcpTools.any((t) => t.server.id == s.id));
    final stale = DateTime.now().difference(_mcpListedAt) > const Duration(minutes: 15);
    if (!missing && !stale) return;
    // Known tools that are only a bit old: refresh in the background, never make the user wait.
    if (!missing) {
      if (_mcpRefreshing == null) unawaited(refreshMcpTools().catchError((_) {}));
      return;
    }
    try {
      await (_mcpRefreshing ?? refreshMcpTools()).timeout(const Duration(seconds: 12));
    } catch (_) {}
  }

  // ---------- apps connected with the user's own keys ----------
  Future<void> _loadApps() async {
    try {
      final raw = await local.secret('apps');
      if (raw.isNotEmpty) {
        final m = jsonDecode(raw) as Map;
        m.forEach((k, v) => ConnectorCatalog.connected['$k'] = Map<String, String>.from(v as Map));
      }
      final rc = await local.secret('customApis');
      if (rc.isNotEmpty) {
        ConnectorCatalog.custom
          ..clear()
          ..addAll([for (final e in jsonDecode(rc) as List) Map<String, String>.from(e as Map)]);
      }
    } catch (_) {}
    // Older versions kept these on their own.
    var moved = false;
    if (ConnectorTools.githubToken.isNotEmpty && !ConnectorCatalog.connected.containsKey('github')) {
      ConnectorCatalog.connected['github'] = {'token': ConnectorTools.githubToken};
      moved = true;
    }
    if (ConnectorTools.notionToken.isNotEmpty && !ConnectorCatalog.connected.containsKey('notion')) {
      ConnectorCatalog.connected['notion'] = {'token': ConnectorTools.notionToken};
      moved = true;
    }
    if (WebTools.braveKey.isNotEmpty && !ConnectorCatalog.connected.containsKey('brave')) {
      ConnectorCatalog.connected['brave'] = {'key': WebTools.braveKey};
      moved = true;
    }
    if (WebTools.tavilyKey.isNotEmpty && !ConnectorCatalog.connected.containsKey('tavily')) {
      ConnectorCatalog.connected['tavily'] = {'key': WebTools.tavilyKey};
      moved = true;
    }
    ConnectorTools.githubToken = '';
    ConnectorTools.notionToken = '';
    if (moved) await _saveApps();
  }

  Future<void> _saveApps() => local.setSecret('apps', jsonEncode(ConnectorCatalog.connected));

  Future<void> connectApp(String id, Map<String, String> values) async {
    ConnectorCatalog.connected[id] = values;
    if (id == 'brave') WebTools.braveKey = values['key'] ?? '';
    if (id == 'tavily') WebTools.tavilyKey = values['key'] ?? '';
    await _saveApps();
    _notify();
  }

  Future<void> disconnectApp(String id) async {
    ConnectorCatalog.connected.remove(id);
    if (id == 'brave') {
      WebTools.braveKey = '';
      await local.setSecret('braveKey', '');
    }
    if (id == 'tavily') {
      WebTools.tavilyKey = '';
      await local.setSecret('tavilyKey', '');
    }
    if (id == 'github') await local.setSecret('githubToken', '');
    if (id == 'notion') await local.setSecret('notionToken', '');
    await _saveApps();
    _notify();
  }

  Future<void> saveCustomApi(Map<String, String> c) async {
    ConnectorCatalog.custom.removeWhere((e) => e['id'] == c['id']);
    ConnectorCatalog.custom.add(c);
    await local.setSecret('customApis', jsonEncode(ConnectorCatalog.custom));
    _notify();
  }

  Future<void> removeCustomApi(String id) async {
    ConnectorCatalog.custom.removeWhere((e) => e['id'] == id);
    await local.setSecret('customApis', jsonEncode(ConnectorCatalog.custom));
    _notify();
  }

  int get connectedAppCount => ConnectorCatalog.connected.length + ConnectorCatalog.custom.length + mcpTools.length;

  Future<void> setConnectorSecret(String key, String value) async {
    await local.setSecret(key, value.trim());
    switch (key) {
      case 'braveKey':
        WebTools.braveKey = value.trim();
        break;
      case 'tavilyKey':
        WebTools.tavilyKey = value.trim();
        break;
      case 'githubToken':
        ConnectorTools.githubToken = value.trim();
        break;
      case 'notionToken':
        ConnectorTools.notionToken = value.trim();
        break;
    }
    _notify();
  }

  void setMemoryEnabled(bool v) {
    memoryEnabled = v;
    local.memoryEnabled = v;
    _notify();
  }

  Future<void> addMemory(String fact) async {
    await memory.add(fact);
    _notify();
  }

  Future<void> updateMemory(MemoryFact f, String text) async {
    await memory.update(f, text);
    _notify();
  }

  Future<void> removeMemory(MemoryFact f) async {
    await memory.remove(f);
    _notify();
  }

  Future<void> clearMemories() async {
    await memory.clear();
    _notify();
  }
}
