import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'code_runner.dart';
import 'tools.dart';

/// Tools the agent makes for itself (core loop v3, owner 2026-11-01: "writing its own tools if all doors are closed").
///
/// When no tool does what a task needs, the agent writes one: a small Python, JavaScript or shell program with a name,
/// a one-line description and its parameters. `tool_make` tests it on the spot and saves it in the workspace
/// (`tools/<name>.json`); from the next step on it is a real tool in the agent's list, called `my_<name>`, with its own
/// schema, on this phone and in every later chat. It runs with no more power than code_run and run_shell already have
/// (the workspace, the web through `submac`), and a shell tool goes through the same approval rules as run_shell.
class ForgedTools {
  ForgedTools._();

  static const make = 'tool_make';
  static const prefix = 'my_';
  static const names = {make};

  /// At most this many own tools are offered to the model (the newest first).
  static const maxOffered = 20;

  static final _name = RegExp(r'^[a-z][a-z0-9_]{2,39}$');

  static List<ForgedTool> _tools = [];
  static bool _loaded = false;

  /// Every tool saved on this phone (loaded once; [load] again after a restore).
  static List<ForgedTool> get tools => _tools;

  static bool handles(String name) => name == make || (name.startsWith(prefix) && byName(name) != null);

  static ForgedTool? byName(String toolName) {
    final n = toolName.startsWith(prefix) ? toolName.substring(prefix.length) : toolName;
    for (final t in _tools) {
      if (t.name == n) return t;
    }
    return null;
  }

  static Future<Directory> _dir() async {
    final d = Directory('${await AgentTools.workspaceDir()}/tools');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  static Future<void> load() async {
    try {
      final d = await _dir();
      final out = <ForgedTool>[];
      for (final f in d.listSync().whereType<File>()) {
        if (!f.path.endsWith('.json')) continue;
        try {
          out.add(ForgedTool.fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>));
        } catch (_) {}
      }
      out.sort((a, b) => b.updated.compareTo(a.updated));
      _tools = out;
    } catch (_) {}
    _loaded = true;
  }

  static Future<void> _ensure() async {
    if (!_loaded) await load();
  }

  static final Map<String, dynamic> makeDef = {
    'type': 'function',
    'function': {
      'name': make,
      'description': 'Make your own tool when no tool you have does the job: a small python, javascript or shell program. It is '
          'tested now with test_args and saved; from your next step it is in your list as my_<name>, here and in later chats. '
          'The program reads its inputs from ARGS (a dict in Python, an object in JavaScript, \$ARGS JSON in shell) and prints '
          'its result. Python and JavaScript can use the web through submac (await submac.get(url), await submac.search(q)). '
          'action list shows your tools; remove deletes one.',
      'parameters': {
        'type': 'object',
        'properties': {
          'action': {'type': 'string', 'enum': ['save', 'list', 'remove']},
          'name': {'type': 'string', 'description': 'lowercase_with_underscores'},
          'description': {'type': 'string', 'description': 'What it does and when to use it, one or two lines.'},
          'language': {'type': 'string', 'enum': ['python', 'javascript', 'shell']},
          'code': {'type': 'string'},
          'params': {'type': 'object', 'description': 'Its inputs as JSON-schema properties, e.g. {"city":{"type":"string"}}.'},
          'required': {'type': 'array', 'items': {'type': 'string'}},
          'test_args': {'type': 'object', 'description': 'Inputs for the test run.'},
        },
        'required': ['action'],
      },
    },
  };

  static List<Map<String, dynamic>> get definitions => [makeDef];

  /// The saved tools as function definitions (the newest [maxOffered]).
  static List<Map<String, dynamic>> userDefinitions() => [for (final t in _tools.take(maxOffered)) t.definition()];

  static Future<String> execute(String name, Map<String, dynamic> a, {Set<String> taken = const {}}) async {
    await _ensure();
    if (name == make) return _make(a, taken);
    final t = byName(name);
    if (t == null) return 'Error: no own tool called $name. tool_make action list shows yours.';
    final out = await run(t, a);
    t.uses++;
    await _save(t);
    return out;
  }

  /// The action of a tool_make call as [_make] reads it ("Save", " list " and the rest count the same).
  static String actionOf(Map<String, dynamic> a) => '${a['action'] ?? 'save'}'.trim().toLowerCase();

  /// The code of a tool_make call that will run as a shell command (its test run), or null. Read exactly as [_make]
  /// reads it, so "Shell" or an action other than list/remove can never test-run a shell command without the
  /// approval run_shell would need.
  static String? makeShellCode(Map<String, dynamic> a) {
    final act = actionOf(a);
    if (act == 'list' || act == 'remove') return null;
    return '${a['language'] ?? ''}'.trim().toLowerCase() == 'shell' ? '${a['code'] ?? ''}' : null;
  }

  /// Why [n] cannot be used for a new tool, or null. The agent's own tool of that name is not a clash: saving it again
  /// is how a broken tool gets fixed (a new version).
  static String? nameClash(String n, Set<String> taken) {
    if (byName(n) != null) return null;
    if (taken.contains(n) || taken.contains('$prefix$n')) return 'Error: "$n" is already a tool you have. Pick another name.';
    return null;
  }

  /// Whether a test run's output is a failure (an error, a failed run, a non-zero or timed-out exit).
  static bool testFailed(String out) =>
      out.startsWith('Error') ||
      RegExp(r'^(error|result: failed|exit_code: (-|[1-9]))', multiLine: true).hasMatch(out) ||
      out.contains('Traceback (most recent call last)');

  @visibleForTesting
  static set toolsForTest(List<ForgedTool> t) {
    _tools = t;
    _loaded = true;
  }

  static Future<String> _make(Map<String, dynamic> a, Set<String> taken) async {
    final action = actionOf(a);
    if (action == 'list') {
      if (_tools.isEmpty) return 'You have made no tools yet.';
      return [for (final t in _tools) '$prefix${t.name} (${t.language}, used ${t.uses}×): ${t.description}'].join('\n');
    }
    final n = '${a['name'] ?? ''}'.trim().toLowerCase();
    if (!_name.hasMatch(n)) return 'Error: name must be 3-40 characters: lowercase letters, digits and _ (starting with a letter).';
    final file = File('${(await _dir()).path}/$n.json');
    if (action == 'remove') {
      if (!await file.exists()) return 'Error: no own tool called $n.';
      await file.delete();
      _tools.removeWhere((t) => t.name == n);
      return 'Removed $prefix$n.';
    }
    final clash = nameClash(n, taken);
    if (clash != null) return clash;
    final lang = '${a['language'] ?? ''}'.trim().toLowerCase();
    if (!const {'python', 'javascript', 'shell'}.contains(lang)) return 'Error: language must be python, javascript or shell.';
    final code = '${a['code'] ?? ''}';
    if (code.trim().isEmpty) return 'Error: code is empty.';
    final desc = '${a['description'] ?? ''}'.trim();
    if (desc.isEmpty) return 'Error: give a description (what it does and when to use it).';
    final params = a['params'] is Map ? Map<String, dynamic>.from(a['params'] as Map) : <String, dynamic>{};
    final req = [for (final e in (a['required'] is List ? a['required'] as List : const [])) '$e'];
    final t = ForgedTool(name: n, description: desc, language: lang, code: code, params: params, required: req);
    final testArgs = a['test_args'] is Map ? Map<String, dynamic>.from(a['test_args'] as Map) : <String, dynamic>{};
    final test = await run(t, testArgs);
    if (testFailed(test)) {
      return 'Not saved: the test run failed. Fix the code and call tool_make again.\n--- test output ---\n$test';
    }
    final old = byName(n);
    if (old != null) {
      t.uses = old.uses;
      t.version = old.version + 1;
    }
    await _save(t);
    return 'Saved $prefix$n (v${t.version}). It is in your tools from the next step, here and in later chats.\n--- test output ---\n$test';
  }

  static Future<void> _save(ForgedTool t) async {
    t.updated = DateTime.now().toUtc();
    final f = File('${(await _dir()).path}/${t.name}.json');
    await f.writeAsString(const JsonEncoder.withIndent('  ').convert(t.toJson()));
    _tools.removeWhere((x) => x.name == t.name);
    _tools.insert(0, t);
  }

  /// Runs [t] with [args]: Python and JavaScript in the phone's code runner (with `submac` for the web), shell in the
  /// workspace with $ARGS set.
  static Future<String> run(ForgedTool t, Map<String, dynamic> args) async {
    final json = jsonEncode(args);
    switch (t.language) {
      case 'python':
        final code = 'import json as __j\nARGS = __j.loads(${jsonEncode(json)})\n${t.code}';
        return CodeRunner.formatLocal(await CodeRunner.I.runPython(code, timeoutSec: 120));
      case 'javascript':
        final code = 'const ARGS = JSON.parse(${jsonEncode(json)});\n${t.code}';
        return CodeRunner.formatLocal(await CodeRunner.I.runJs(code, timeoutSec: 60));
      default:
        return AgentTools.execute('run_shell', {'command': shellCommand(t.code, json), 'timeout_seconds': 120});
    }
  }

  /// The shell line that runs [code] with ARGS (the inputs as JSON) in its environment. Single quotes are escaped.
  static String shellCommand(String code, String argsJson) => "export ARGS='${argsJson.replaceAll("'", "'\\''")}'\n$code";

  /// The approval a shell tool needs: the same as run_shell for its code.
  static String? shellCodeOf(String name) {
    final t = byName(name);
    return t != null && t.language == 'shell' ? t.code : null;
  }
}

class ForgedTool {
  ForgedTool({required this.name, required this.description, required this.language, required this.code,
      this.params = const {}, this.required = const [], this.uses = 0, this.version = 1, DateTime? updated})
      : updated = updated ?? DateTime.now().toUtc();

  final String name;
  final String description;
  final String language;
  final String code;
  final Map<String, dynamic> params;
  final List<String> required;
  int uses;
  int version;
  DateTime updated;

  /// Its definition for the model. Every own tool rides along on every request, so a schema the provider refuses
  /// (a parameter written as `"city": "string"`, a required name that is no parameter) would fail every step of every
  /// later task: each parameter is made a schema object and required keeps only real parameters.
  Map<String, dynamic> definition() {
    final props = <String, dynamic>{
      for (final e in params.entries)
        e.key: e.value is Map
            ? Map<String, dynamic>.from(e.value as Map)
            : <String, dynamic>{'type': const {'string', 'number', 'integer', 'boolean', 'array', 'object'}.contains('${e.value}') ? '${e.value}' : 'string'},
    };
    for (final p in props.values) {
      if (p is Map && p['type'] == 'array' && p['items'] == null) p['items'] = {'type': 'string'};
    }
    return {
      'type': 'function',
      'function': {
        'name': '${ForgedTools.prefix}$name',
        'description': '(your own tool) $description',
        'parameters': {'type': 'object', 'properties': props, 'required': [for (final r in required) if (props.containsKey(r)) r]},
      },
    };
  }

  Map<String, dynamic> toJson() => {
        'name': name, 'description': description, 'language': language, 'code': code, 'params': params, 'required': required,
        'uses': uses, 'version': version, 'updated': updated.toIso8601String(),
      };

  factory ForgedTool.fromJson(Map<String, dynamic> j) => ForgedTool(
        name: '${j['name']}',
        description: '${j['description'] ?? ''}',
        language: '${j['language'] ?? 'python'}',
        code: '${j['code'] ?? ''}',
        params: j['params'] is Map ? Map<String, dynamic>.from(j['params'] as Map) : const {},
        required: [for (final e in (j['required'] is List ? j['required'] as List : const [])) '$e'],
        uses: (j['uses'] as num?)?.toInt() ?? 0,
        version: (j['version'] as num?)?.toInt() ?? 1,
        updated: DateTime.tryParse('${j['updated'] ?? ''}'),
      );
}
