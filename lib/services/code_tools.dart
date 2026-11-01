import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;

import 'code_git.dart';
import 'code_runner.dart';
import 'site_check.dart';
import 'tools.dart';

/// The Coder bot's toolbox (and the main chat's, for coding work). Everything runs free for SubMac: on the phone,
/// on a free public compiler, or on the user's own GitHub. The files themselves are the workspace file tools
/// (read_file, write_file, append_file, edit_file, list_dir, delete_file, run_shell); these add what a developer needs
/// on top: run and test code, search, diffs and patches, undo points, git and GitHub, builds (APK, web, tests), an
/// API tester, package docs, checks and project starters.
class CodeTools {
  static const names = {
    'code_run', 'code_search', 'code_diff', 'code_git', 'code_build', 'code_snapshot', 'code_http', 'code_docs', 'code_check',
    'code_project',
  };

  /// Tests point the workspace at a temp folder.
  static String? dirOverride;

  static Future<String> _ws() async => dirOverride ?? await AgentTools.workspaceDir();

  static Future<String> resolve(String p) async {
    final ws = await _ws();
    final t = p.trim();
    if (t.isEmpty || t == '.') return ws;
    if (t.startsWith('/')) return t;
    return '$ws/$t';
  }

  static Map<String, dynamic> _fn(String name, String desc, Map<String, dynamic> props, [List<String> req = const []]) => {
        'type': 'function',
        'function': {
          'name': name,
          'description': desc,
          'parameters': {'type': 'object', 'properties': props, 'required': req},
        },
      };

  static const _dir = {'type': 'string', 'description': 'Project folder in the workspace, e.g. "code/shop-app"'};

  static final List<Map<String, dynamic>> definitions = [
    _fn('code_run', 'Run code and see the real output. Python, JavaScript, TypeScript and SQL (SQLite) run on the phone; C, C++, Rust, Go, '
        'C#, F#, Dart, Swift, Zig, Ruby, Haskell, Lua, Julia, OCaml, Pascal, Fortran, D and Crystal run on an online compiler. '
        'Give code, or path to a file (dir mounts that folder for Python, so it can read and write files there; new files come back). '
        'Python packages: pure-Python and the common science ones (numpy, pandas, matplotlib...). No Java, Kotlin, PHP or Node APIs. '
        'Web from Python/JS: `import submac` (Python) or the submac object (JS): await submac.get(url), post, search(q), '
        'research(q), read(url). Always run what you write before saying it works.', {
      'language': {'type': 'string', 'description': 'python, javascript, typescript, sql, c, cpp, rust, go, csharp, fsharp, dart, swift, zig, ruby, haskell, lua, julia, ocaml, pascal, fortran, d, crystal'},
      'code': {'type': 'string', 'description': 'The program (or SQL). Leave empty to run path.'},
      'path': {'type': 'string', 'description': 'A file in the workspace to run (its extension picks the language).'},
      'dir': _dir,
      'stdin': {'type': 'string'},
      'args': {'type': 'array', 'items': {'type': 'string'}},
      'packages': {'type': 'array', 'items': {'type': 'string'}, 'description': 'Python: extra packages to install first'},
      'db': {'type': 'string', 'description': 'SQL: a .db / .sqlite file in the workspace (made when missing; changes are saved)'},
      'flags': {'type': 'string', 'description': 'Compiled languages: extra compiler flags'},
      'timeout_seconds': {'type': 'integer', 'description': 'Python/JS: default 60, max 300'},
    }),
    _fn('code_search', 'Search a project. grep = lines matching text or a regex (with file:line); find = files by name; '
        'tree = the folder layout with sizes; symbols = where classes, functions and methods are defined (all languages).', {
      'action': {'type': 'string', 'enum': ['grep', 'find', 'tree', 'symbols']},
      'query': {'type': 'string', 'description': 'grep: text or regex; find: part of a file name or a glob like *.dart; symbols: a name (empty = all)'},
      'dir': _dir,
      'regex': {'type': 'boolean'},
      'case_sensitive': {'type': 'boolean'},
      'glob': {'type': 'string', 'description': 'Only files like this, e.g. *.py'},
      'max': {'type': 'integer', 'description': 'Most results (default 80)'},
    }, ['action']),
    _fn('code_diff', 'compare = a unified diff between two files (a, b) or two texts; apply = apply a unified diff (patch) to path. '
        'Use apply for many edits in one file at once; edit_file for one change.', {
      'action': {'type': 'string', 'enum': ['compare', 'apply']},
      'a': {'type': 'string', 'description': 'compare: first file'},
      'b': {'type': 'string', 'description': 'compare: second file'},
      'text_a': {'type': 'string'},
      'text_b': {'type': 'string'},
      'path': {'type': 'string', 'description': 'apply: the file to patch'},
      'patch': {'type': 'string', 'description': 'apply: unified diff with @@ hunks (context lines must match)'},
    }, ['action']),
    _fn('code_git', 'Git on the user\'s GitHub (connects GitHub first when needed). repos = their repos; clone (repo, dir, branch); '
        'status; diff (what changed, line by line); pull; push (message, optional new branch); publish (make a new repo from a folder: '
        'name, private default true); branch (make one); branches; log; pr (title, body, head, base) and prs; issues, issue (number), '
        'create_issue, comment; pages (host a plain website folder free on GitHub Pages). Push only work you ran and checked.', {
      'action': {'type': 'string', 'enum': ['repos', 'clone', 'status', 'diff', 'pull', 'push', 'publish', 'branch', 'branches', 'log', 'pr', 'prs', 'issues', 'issue', 'create_issue', 'comment', 'pages']},
      'repo': {'type': 'string', 'description': 'owner/name or a GitHub link (clone; or to work without a local copy)'},
      'dir': _dir,
      'branch': {'type': 'string'},
      'message': {'type': 'string', 'description': 'push: commit message'},
      'name': {'type': 'string', 'description': 'publish: new repo name'},
      'private': {'type': 'boolean'},
      'description': {'type': 'string'},
      'title': {'type': 'string'},
      'body': {'type': 'string'},
      'number': {'type': 'integer'},
      'base': {'type': 'string'},
      'head': {'type': 'string'},
    }, ['action']),
    _fn('code_build', 'Build on the user\'s GitHub Actions (free): target apk (Android app to install), aab (Play Store), web '
        '(hosts it on GitHub Pages and gives the link), or test (full test run with the real toolchain: flutter, gradle, node, python, '
        'go, rust, dart). The folder must be on GitHub (code_git publish or clone). start, then wait (follows it up to 4 minutes; call '
        'again until done). On success the APK is downloaded to builds/<repo>/; on failure you get the error log to fix. APK works for Flutter, native '
        'Android, React Native and Capacitor; no Android Studio or computer is needed.', {
      'action': {'type': 'string', 'enum': ['start', 'status', 'wait']},
      'dir': _dir,
      'target': {'type': 'string', 'enum': ['apk', 'aab', 'web', 'test']},
    }, ['action', 'dir']),
    _fn('code_snapshot', 'Undo points for a project folder. save (label) before a risky change; list; changes (what differs from a '
        'snapshot); restore (id) puts the folder back as it was (it saves the current state first).', {
      'action': {'type': 'string', 'enum': ['save', 'list', 'changes', 'restore']},
      'dir': _dir,
      'label': {'type': 'string'},
      'id': {'type': 'string', 'description': 'Snapshot id from list (default: the newest)'},
    }, ['action', 'dir']),
    _fn('code_http', 'Call an HTTP API like Postman/curl: any method, headers and body; returns status, time, headers and the body '
        '(JSON pretty-printed). For testing APIs the user owns or public APIs. Never send the user\'s passwords.', {
      'method': {'type': 'string', 'enum': ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS']},
      'url': {'type': 'string'},
      'headers': {'type': 'object'},
      'body': {'type': 'string'},
      'json': {'type': 'object', 'description': 'A JSON body (sets Content-Type)'},
    }, ['url']),
    _fn('code_docs', 'Package facts from the official registries: info (latest version, licence, links, install line, dependencies), '
        'versions, readme, search. Ecosystems: npm, pypi, pub (Dart/Flutter), crates (Rust), go, nuget, packagist (PHP), rubygems. '
        'Check versions and APIs here instead of guessing.', {
      'action': {'type': 'string', 'enum': ['info', 'versions', 'readme', 'search']},
      'ecosystem': {'type': 'string', 'enum': ['npm', 'pypi', 'pub', 'crates', 'go', 'nuget', 'packagist', 'rubygems']},
      'package': {'type': 'string'},
      'query': {'type': 'string', 'description': 'search: words'},
    }, ['action', 'ecosystem']),
    _fn('code_check', 'Check files for mistakes without running them: syntax of Python, JavaScript and TypeScript; JSON; HTML (unclosed '
        'tags, missing local files, images without alt); CSS braces; YAML tabs; and in any file: merge conflict markers, TODOs. '
        'path = one file, dir = every file in a folder.', {
      'path': {'type': 'string'},
      'dir': _dir,
    }),
    _fn('code_project', 'Projects: new (a ready starter: web, python, node-api, flutter, react, ts-node, go, rust, c, cpp, chrome-extension; '
        'name), info (stack, languages, files, lines, git link, how to run), zip (pack a folder to share), unzip (unpack a zip '
        'into the workspace).', {
      'action': {'type': 'string', 'enum': ['new', 'info', 'zip', 'unzip']},
      'template': {'type': 'string'},
      'name': {'type': 'string'},
      'dir': _dir,
      'path': {'type': 'string', 'description': 'unzip: the zip file'},
    }, ['action']),
  ];

  // ---------------------------------------------------------------- dispatch

  static Future<String> execute(String name, Map<String, dynamic> a) async {
    try {
      return switch (name) {
        'code_run' => await _run(a),
        'code_search' => await _search(a),
        'code_diff' => await _diff(a),
        'code_git' => await _git(a),
        'code_build' => await _build(a),
        'code_snapshot' => await _snapshot(a),
        'code_http' => await _http(a),
        'code_docs' => await _docs(a),
        'code_check' => await _check(a),
        'code_project' => await _project(a),
        _ => 'Error: unknown tool $name',
      };
    } on TimeoutException {
      return 'Error: it took too long (no answer). Check the connection and try again.';
    } catch (e) {
      final s = '$e';
      return s.startsWith('Exception: Error') ? s.substring(11) : 'Error: $s';
    }
  }

  static String _s(Map<String, dynamic> a, String k) => '${a[k] ?? ''}'.trim();

  /// Approval for actions that change things outside the phone (pushes, new repos, PRs, comments, API calls that write).
  static ActionRequest? riskFor(String name, Map<String, dynamic> a) {
    if (name == 'code_git') {
      final act = _s(a, 'action');
      final where = _s(a, 'repo').isNotEmpty ? _s(a, 'repo') : _s(a, 'dir');
      return switch (act) {
        'push' => ActionRequest(title: 'Push the changes to GitHub?', body: _s(a, 'message'), detail: '$where${_s(a, 'branch').isEmpty ? '' : ' → ${_s(a, 'branch')}'}', confirmLabel: 'Push'),
        'publish' => ActionRequest(title: 'Make a new ${a['private'] == false ? 'public' : 'private'} GitHub repo "${_s(a, 'name')}"?', body: 'The folder\'s files are uploaded to it.', detail: _s(a, 'dir'), confirmLabel: 'Create'),
        'pr' => ActionRequest(title: 'Open a pull request?', body: _s(a, 'title'), detail: '$where: ${_s(a, 'head')} → ${_s(a, 'base')}', confirmLabel: 'Open'),
        'comment' || 'create_issue' => ActionRequest(title: act == 'comment' ? 'Post this comment on GitHub?' : 'Open this issue on GitHub?', body: _s(a, 'title'), detail: _s(a, 'body'), confirmLabel: 'Post'),
        'pages' => ActionRequest(title: 'Host this on GitHub Pages?', body: 'Anyone with the link can see it.', detail: where, confirmLabel: 'Host'),
        _ => null,
      };
    }
    if (name == 'code_build' && _s(a, 'action') == 'start' && _s(a, 'target') == 'web') {
      return ActionRequest(title: 'Build and host the website on GitHub Pages?', body: 'Anyone with the link can see it.', detail: _s(a, 'dir'), confirmLabel: 'Build');
    }
    if (name == 'code_snapshot' && _s(a, 'action') == 'restore') {
      return ActionRequest(title: 'Put ${_s(a, 'dir')} back to an earlier snapshot?', body: 'The current files are saved as a snapshot first.', detail: _s(a, 'id'), confirmLabel: 'Restore');
    }
    if (name == 'code_http') {
      final m = _s(a, 'method').toUpperCase();
      if (m.isEmpty || m == 'GET' || m == 'HEAD' || m == 'OPTIONS') return null;
      return ActionRequest(title: 'Send a $m request?', body: 'It may change data on that server.', detail: _s(a, 'url'), confirmLabel: 'Send');
    }
    return null;
  }

  // ---------------------------------------------------------------- run

  static Future<String> _run(Map<String, dynamic> a) async {
    var code = '${a['code'] ?? ''}';
    final path = _s(a, 'path');
    var lang = CodeRunner.normalize(_s(a, 'language'));
    if (code.trim().isEmpty && path.isNotEmpty) {
      final f = File(await resolve(path));
      if (!await f.exists()) return 'Error: file not found: $path';
      code = await f.readAsString();
      lang ??= CodeRunner.languageOfPath(path);
    }
    if (code.trim().isEmpty) return 'Error: give code or path.';
    if (lang == null) {
      final l = _s(a, 'language');
      if (RegExp(r'^(java|kotlin|php|scala|perl|r|elixir|bash|sh|shell)$', caseSensitive: false).hasMatch(l)) {
        return 'Error: $l can\'t run here. bash/sh: use run_shell (Android sh). Java, Kotlin, PHP and the rest: write the files, then '
            'code_build start with target test on GitHub, or run the logic in Python or JavaScript to check it.';
      }
      return 'Error: say the language (python, javascript, typescript, sql, c, cpp, rust, go, csharp, dart, swift...).';
    }
    final stdin = '${a['stdin'] ?? ''}';
    final args = [for (final e in (a['args'] as List? ?? const [])) '$e'];
    final t = ((a['timeout_seconds'] as num?)?.toInt() ?? 60).clamp(5, 300).toInt();
    if (CodeRunner.remote.containsKey(lang)) {
      return CodeRunner.I.runRemote(lang, code, stdin: stdin, args: args, flags: _s(a, 'flags'));
    }
    switch (lang) {
      case 'python':
        final dir = _s(a, 'dir').isNotEmpty ? _s(a, 'dir') : (path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : '');
        final files = <String, String>{};
        Directory? root;
        if (dir.isNotEmpty) {
          root = Directory(await resolve(dir));
          var total = 0;
          for (final e in (await CodeGit.localFiles(root)).entries) {
            final len = await e.value.length();
            if (len > 5 * 1024 * 1024 || total + len > 20 * 1024 * 1024) continue;
            total += len;
            files[e.key] = base64Encode(await e.value.readAsBytes());
          }
        }
        final r = await CodeRunner.I.runPython(code, files: files, stdin: stdin, args: args,
            packages: [for (final e in (a['packages'] as List? ?? const [])) '$e'], timeoutSec: t);
        final out = StringBuffer(CodeRunner.formatLocal(r));
        final back = r['files'] is Map ? Map<String, dynamic>.from(r['files'] as Map) : const <String, dynamic>{};
        if (back.isNotEmpty) {
          root ??= Directory('${await _ws()}/code/output');
          final saved = <String>[];
          for (final e in back.entries) {
            final f = File('${root.path}/${e.key}');
            await f.parent.create(recursive: true);
            await f.writeAsBytes(base64Decode('${e.value}'));
            saved.add(f.path);
          }
          out.write('\nfiles written: ${saved.take(30).join(', ')}${saved.length > 30 ? ' …' : ''}');
        }
        return out.toString();
      case 'javascript':
      case 'typescript':
        return CodeRunner.formatLocal(await CodeRunner.I.runJs(code, typescript: lang == 'typescript', stdin: stdin, timeoutSec: t));
      case 'sql':
        final dbPath = _s(a, 'db');
        File? dbf;
        var db = '';
        if (dbPath.isNotEmpty) {
          dbf = File(await resolve(dbPath));
          if (await dbf.exists()) db = base64Encode(await dbf.readAsBytes());
        }
        final r = await CodeRunner.I.runSql(code, db: db);
        if (r['ok'] != true) return 'error: ${r['error']}';
        final sb = StringBuffer();
        for (final t in (r['tables'] as List? ?? const [])) {
          final m = Map<String, dynamic>.from(t as Map);
          final cols = [for (final c in m['columns'] as List) '$c'];
          sb.writeln('| ${cols.join(' | ')} |\n|${List.filled(cols.length, '---').join('|')}|');
          for (final row in (m['rows'] as List)) {
            sb.writeln('| ${[for (final v in row as List) v == null ? 'NULL' : '$v'.replaceAll('|', '/')].join(' | ')} |');
          }
          if ((m['total'] as num) > 200) sb.writeln('(${m['total']} rows, first 200 shown)');
        }
        sb.writeln('rows changed: ${r['changes']}');
        if (dbf != null) {
          await dbf.parent.create(recursive: true);
          await dbf.writeAsBytes(base64Decode('${r['db']}'));
          sb.writeln('saved ${dbf.path}');
        }
        return sb.toString().trim();
    }
    return 'Error: $lang is not supported.';
  }

  // ---------------------------------------------------------------- search

  static bool isText(String path) => !RegExp(
          r'\.(png|jpe?g|gif|webp|ico|bmp|pdf|zip|gz|tar|7z|rar|apk|aab|jar|class|so|dll|exe|bin|o|a|wasm|mp3|mp4|wav|ogg|mov|avi|ttf|otf|woff2?|db|sqlite|keystore|jks|lock)$',
          caseSensitive: false)
      .hasMatch(path);

  static RegExp globRx(String g) =>
      RegExp('^${RegExp.escape(g).replaceAll(r'\*\*', '.*').replaceAll(r'\*', '[^/]*').replaceAll(r'\?', '.')}\$', caseSensitive: false);

  static final _sym = RegExp(
      r'^\s*(?:export\s+)?(?:pub(?:\(crate\))?\s+)?(?:public|private|protected|internal|static|abstract|final|async|override|open|data|sealed|inline|const|extern|unsafe|\s)*'
      r'(class|interface|enum|struct|trait|impl|mixin|extension|record|object|type|def|fn|func|function|fun|sub|module|namespace|typedef)\s+([A-Za-z_$][\w$]*)');
  static final _dartFn = RegExp(r'^\s{0,2}(?:static\s+)?(?:Future<[^>]*>|Stream<[^>]*>|void|int|double|bool|String|Widget|[A-Z]\w*(?:<[^>]*>)?\??)\s+([a-zA-Z_]\w*)\s*\(');
  static final _jsFn = RegExp(r'^\s*(?:export\s+)?(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s*)?(?:\([^)]*\)|[A-Za-z_$][\w$]*)\s*=>');

  static Future<String> _search(Map<String, dynamic> a) async {
    final root = Directory(await resolve(_s(a, 'dir')));
    if (!await root.exists()) return 'Error: folder not found: ${root.path}';
    final act = _s(a, 'action');
    final q = '${a['query'] ?? ''}';
    final max = ((a['max'] as num?)?.toInt() ?? 80).clamp(1, 400).toInt();
    final glob = _s(a, 'glob');
    final gx = glob.isEmpty ? null : globRx(glob.contains('/') ? glob : '**$glob');
    final files = (await CodeGit.localFiles(root)).entries.where((e) => gx == null || gx.hasMatch(e.key) || gx.hasMatch('/${e.key}')).toList()
      ..sort((x, y) => x.key.compareTo(y.key));
    final out = <String>[];
    switch (act) {
      case 'tree':
        var total = 0;
        for (final e in files) {
          final n = await e.value.length();
          total += n;
          if (out.length < max * 3) out.add('${e.key}  ${_size(n)}');
        }
        return '${root.path}: ${files.length} files, ${_size(total)}\n${out.join('\n')}${files.length > out.length ? '\n…' : ''}';
      case 'find':
        final fx = q.contains('*') || q.contains('?') ? globRx(q.contains('/') ? q : '**$q') : null;
        for (final e in files) {
          final name = e.key.split('/').last;
          if (fx != null ? (fx.hasMatch(e.key) || fx.hasMatch('/${e.key}')) : name.toLowerCase().contains(q.toLowerCase())) out.add(e.key);
          if (out.length >= max) break;
        }
        return out.isEmpty ? 'No file names match "$q".' : out.join('\n');
      case 'grep':
      case 'symbols':
        if (act == 'grep' && q.isEmpty) return 'Error: give query.';
        final cs = a['case_sensitive'] == true;
        RegExp rx;
        try {
          rx = RegExp(a['regex'] == true ? q : RegExp.escape(q), caseSensitive: cs);
        } catch (e) {
          return 'Error: bad regex: $e';
        }
        var hits = 0;
        for (final e in files) {
          if (!isText(e.key) || await e.value.length() > 2 * 1024 * 1024) continue;
          final List<String> lines;
          try {
            lines = const LineSplitter().convert(await e.value.readAsString());
          } catch (_) {
            continue;
          }
          for (var i = 0; i < lines.length; i++) {
            final l = lines[i];
            if (act == 'grep') {
              if (!rx.hasMatch(l)) continue;
            } else {
              final m = _sym.firstMatch(l) ?? _jsFn.firstMatch(l) ?? (e.key.endsWith('.dart') ? _dartFn.firstMatch(l) : null);
              if (m == null) continue;
              final nm = m.groupCount >= 2 ? (m.group(2) ?? m.group(1)) : m.group(1);
              if (q.isNotEmpty && !(nm ?? '').toLowerCase().contains(q.toLowerCase())) continue;
            }
            hits++;
            if (out.length < max) out.add('${e.key}:${i + 1}: ${l.trim().length > 200 ? '${l.trim().substring(0, 200)}…' : l.trim()}');
          }
        }
        if (hits == 0) return act == 'grep' ? 'No matches for "$q".' : 'No definitions found${q.isEmpty ? '' : ' for "$q"'}.';
        return '${out.join('\n')}${hits > out.length ? '\n… $hits matches in all (narrow with dir or glob)' : ''}';
    }
    return 'Error: action must be grep, find, tree or symbols.';
  }

  static String _size(int n) => n < 1024 ? '$n B' : (n < 1048576 ? '${(n / 1024).toStringAsFixed(1)} KB' : '${(n / 1048576).toStringAsFixed(1)} MB');

  // ---------------------------------------------------------------- diff and patch (pure parts unit tested)

  /// Line diff (Myers). Returns ops: ' ' same, '-' only in a, '+' only in b.
  static List<(String, String)> diffLines(List<String> a, List<String> b) {
    final n = a.length, m = b.length, max = n + m;
    if (max == 0) return const [];
    final v = <int, int>{1: 0};
    final trace = <Map<int, int>>[];
    var found = false;
    outer:
    for (var d = 0; d <= max; d++) {
      trace.add(Map<int, int>.from(v));
      for (var k = -d; k <= d; k += 2) {
        int x;
        if (k == -d || (k != d && (v[k - 1] ?? -1) < (v[k + 1] ?? -1))) {
          x = v[k + 1] ?? 0;
        } else {
          x = (v[k - 1] ?? 0) + 1;
        }
        var y = x - k;
        while (x < n && y < m && a[x] == b[y]) {
          x++;
          y++;
        }
        v[k] = x;
        if (x >= n && y >= m) {
          trace.add(Map<int, int>.from(v));
          found = true;
          break outer;
        }
      }
      if (d > 6000) break;
    }
    // Too different to line up: everything out, everything in.
    if (!found) return [for (final l in a) ('-', l), for (final l in b) ('+', l)];
    // Walk back through the trace.
    final ops = <(String, String)>[];
    var x = n, y = m;
    for (var d = trace.length - 2; d >= 0 && (x > 0 || y > 0); d--) {
      final vv = trace[d];
      final k = x - y;
      int prevK;
      if (k == -d || (k != d && (vv[k - 1] ?? -1) < (vv[k + 1] ?? -1))) {
        prevK = k + 1;
      } else {
        prevK = k - 1;
      }
      final px = vv[prevK] ?? 0;
      final py = px - prevK;
      while (x > px && y > py) {
        ops.add((' ', a[--x]));
        y--;
      }
      if (d > 0) {
        if (x == px) {
          ops.add(('+', b[--y]));
        } else {
          ops.add(('-', a[--x]));
        }
      }
    }
    while (x > 0 && y > 0) {
      ops.add((' ', a[--x]));
      y--;
    }
    while (x > 0) {
      ops.add(('-', a[--x]));
    }
    while (y > 0) {
      ops.add(('+', b[--y]));
    }
    return ops.reversed.toList();
  }

  /// A unified diff with [ctx] lines of context ('' when equal).
  static String unified(String a, String b, {String nameA = 'a', String nameB = 'b', int ctx = 3}) {
    final la = const LineSplitter().convert(a), lb = const LineSplitter().convert(b);
    final ops = diffLines(la, lb);
    if (ops.every((o) => o.$1 == ' ')) return '';
    final sb = StringBuffer('--- $nameA\n+++ $nameB\n');
    var i = 0;
    var ai = 0, bi = 0;
    final idxA = <int>[], idxB = <int>[];
    for (final o in ops) {
      idxA.add(ai);
      idxB.add(bi);
      if (o.$1 != '+') ai++;
      if (o.$1 != '-') bi++;
    }
    while (i < ops.length) {
      if (ops[i].$1 == ' ') {
        i++;
        continue;
      }
      var start = (i - ctx).clamp(0, ops.length);
      var end = i;
      // Grow the hunk while changes are within 2*ctx of each other.
      var j = i;
      while (j < ops.length) {
        if (ops[j].$1 != ' ') {
          end = j;
          j++;
          continue;
        }
        var k = j;
        while (k < ops.length && ops[k].$1 == ' ') {
          k++;
        }
        if (k < ops.length && k - j <= ctx * 2) {
          j = k;
          continue;
        }
        break;
      }
      final stop = (end + ctx + 1).clamp(0, ops.length);
      final hunk = ops.sublist(start, stop);
      final aLen = hunk.where((o) => o.$1 != '+').length, bLen = hunk.where((o) => o.$1 != '-').length;
      sb.writeln('@@ -${idxA[start] + (aLen == 0 ? 0 : 1)},$aLen +${idxB[start] + (bLen == 0 ? 0 : 1)},$bLen @@');
      for (final o in hunk) {
        sb.writeln('${o.$1}${o.$2}');
      }
      i = stop;
    }
    return sb.toString();
  }

  /// Applies a unified diff to [text]. Hunks are found by their context (line numbers may be off). Throws on a mismatch.
  static String applyPatch(String text, String patch) {
    final lines = const LineSplitter().convert(text);
    final endsNl = text.endsWith('\n');
    final p = const LineSplitter().convert(patch);
    final hunks = <List<String>>[];
    for (final l in p) {
      if (l.startsWith('@@')) {
        hunks.add([]);
      } else if (hunks.isNotEmpty && !l.startsWith('--- ') && !l.startsWith('+++ ') && !l.startsWith(r'\ No newline')) {
        hunks.last.add(l);
      }
    }
    if (hunks.isEmpty) throw const FormatException('no @@ hunks in the patch');
    var out = lines;
    var from = 0;
    for (var h = 0; h < hunks.length; h++) {
      final hk = hunks[h];
      final old = <String>[], neu = <String>[];
      for (final l in hk) {
        final t = l.isEmpty ? ' ' : l[0];
        final body = l.isEmpty ? '' : l.substring(1);
        if (t == '-' || t == ' ') old.add(body);
        if (t == '+' || t == ' ') neu.add(body);
      }
      int at = _find(out, old, from);
      if (at < 0) at = _find(out, old, 0);
      if (at < 0) {
        // Forgive trailing spaces.
        final trim = [for (final l in out) l.trimRight()];
        at = _find(trim, [for (final l in old) l.trimRight()], 0);
      }
      if (at < 0) throw FormatException('hunk ${h + 1} does not match the file (its context lines are not there): ${old.take(3).join(' | ')}');
      out = [...out.sublist(0, at), ...neu, ...out.sublist(at + old.length)];
      from = at + neu.length;
    }
    return out.join('\n') + (endsNl || text.isEmpty ? '\n' : '');
  }

  static int _find(List<String> hay, List<String> needle, int from) {
    if (needle.isEmpty) return from.clamp(0, hay.length);
    for (var i = from; i + needle.length <= hay.length; i++) {
      var ok = true;
      for (var j = 0; j < needle.length; j++) {
        if (hay[i + j] != needle[j]) {
          ok = false;
          break;
        }
      }
      if (ok) return i;
    }
    return -1;
  }

  static Future<String> _diff(Map<String, dynamic> a) async {
    if (_s(a, 'action') == 'apply') {
      final f = File(await resolve(_s(a, 'path')));
      if (!await f.exists()) return 'Error: file not found: ${f.path}';
      final before = await f.readAsString();
      try {
        final after = applyPatch(before, '${a['patch'] ?? ''}');
        await f.writeAsString(after);
        final d = unified(before, after, nameA: 'before', nameB: 'after', ctx: 0);
        final add = RegExp(r'^\+(?!\+\+)', multiLine: true).allMatches(d).length;
        final del = RegExp(r'^-(?!--)', multiLine: true).allMatches(d).length;
        return 'Patched ${f.path}: +$add -$del lines.';
      } on FormatException catch (e) {
        return 'Error: ${e.message}. Read the file again (read_file) and make the patch from its real lines, or use edit_file.';
      }
    }
    var ta = a['text_a'] == null ? null : '${a['text_a']}';
    var tb = a['text_b'] == null ? null : '${a['text_b']}';
    if (ta == null && _s(a, 'a').isNotEmpty) ta = await File(await resolve(_s(a, 'a'))).readAsString();
    if (tb == null && _s(a, 'b').isNotEmpty) tb = await File(await resolve(_s(a, 'b'))).readAsString();
    if (ta == null || tb == null) return 'Error: give a and b (files) or text_a and text_b.';
    final d = unified(ta, tb, nameA: _s(a, 'a').isEmpty ? 'a' : _s(a, 'a'), nameB: _s(a, 'b').isEmpty ? 'b' : _s(a, 'b'));
    return d.isEmpty ? 'No differences.' : CodeRunner.clip(d, 14000);
  }

  // ---------------------------------------------------------------- git

  static Future<Directory?> _repoDir(Map<String, dynamic> a) async {
    final d = _s(a, 'dir');
    if (d.isNotEmpty) return Directory(await resolve(d));
    final r = CodeGit.repoOf(_s(a, 'repo'));
    if (r == null) return null;
    final dd = Directory('${await _ws()}/code/${r.split('/').last}');
    return await dd.exists() ? dd : null;
  }

  static Future<String> _git(Map<String, dynamic> a) async {
    final act = _s(a, 'action');
    final need = await CodeGit.needToken(switch (act) {
      'publish' || 'push' => 'Keep this code safe on your GitHub and share it',
      'pages' => 'Host this website free on your GitHub',
      _ => 'Work with your code on GitHub',
    });
    if (need != null) return need;
    final dir = await _repoDir(a);
    final m = dir == null ? null : await CodeGit.readMeta(dir);
    final repo = CodeGit.repoOf(_s(a, 'repo')) ?? (m == null ? null : '${m['repo']}');
    String need2(String what) => 'Error: $what needs repo (owner/name) or dir of a cloned copy.';
    switch (act) {
      case 'repos':
        final (c, r) = await CodeGit.call('GET', '/user/repos?sort=updated&per_page=40');
        if (c != 200) return CodeGit.err(c, r);
        return [
          for (final e in r as List)
            '${e['full_name']}${e['private'] == true ? ' (private)' : ''} · ${e['language'] ?? '-'} · updated ${'${e['updated_at']}'.substring(0, 10)}${'${e['description'] ?? ''}'.isEmpty ? '' : ' · ${e['description']}'}'
        ].join('\n');
      case 'clone':
        if (repo == null) return need2('clone');
        final (c, info) = await CodeGit.call('GET', '/repos/$repo');
        if (c != 200) return CodeGit.err(c, info);
        final branch = _s(a, 'branch').isNotEmpty ? _s(a, 'branch') : '${info['default_branch']}';
        final root = Directory(_s(a, 'dir').isNotEmpty ? await resolve(_s(a, 'dir')) : '${await _ws()}/code/${repo.split('/').last}');
        if (await root.exists() && (await CodeGit.localFiles(root)).isNotEmpty) {
          return 'Error: ${root.path} already has files. Use pull to update it, or give another dir.';
        }
        final (sha, shas) = await CodeGit.download(repo, branch, root);
        await CodeGit.writeMeta(root, {'repo': repo, 'branch': branch, 'commit': sha, 'files': shas});
        return 'Cloned $repo ($branch @ ${sha.substring(0, 7)}) into ${root.path}: ${shas.length} files. '
            'Next: code_project info and code_search tree to learn it.';
      case 'status':
      case 'diff':
        if (dir == null || m == null) return 'Error: give dir of a cloned copy.';
        final ch = CodeGit.changes(Map<String, String>.from(m['files'] as Map), await CodeGit.shasOf(dir));
        final n = ch.values.fold<int>(0, (s, l) => s + l.length);
        if (act == 'status') {
          if (n == 0) return '${m['repo']} (${m['branch']} @ ${'${m['commit']}'.substring(0, 7)}): no changes.';
          return '${m['repo']} (${m['branch']} @ ${'${m['commit']}'.substring(0, 7)}): $n changed\n'
              '${[for (final p in ch['modified']!) 'M $p', for (final p in ch['added']!) 'A $p', for (final p in ch['deleted']!) 'D $p'].join('\n')}';
        }
        if (n == 0) return 'No changes.';
        final sb = StringBuffer();
        final base = Map<String, String>.from(m['files'] as Map);
        for (final p in [...ch['modified']!, ...ch['deleted']!]) {
          if (!isText(p)) {
            sb.writeln('Binary $p changed');
            continue;
          }
          final (c, blob) = await CodeGit.call('GET', '/repos/${m['repo']}/git/blobs/${base[p]}');
          if (c != 200) continue;
          final old = utf8.decode(base64Decode('${blob['content']}'.replaceAll('\n', '')), allowMalformed: true);
          final f = File('${dir.path}/$p');
          final now = await f.exists() ? await f.readAsString() : '';
          sb.write(unified(old, now, nameA: 'a/$p', nameB: 'b/$p'));
          if (sb.length > 14000) break;
        }
        for (final p in ch['added']!) {
          sb.writeln('+++ new file $p');
        }
        return CodeRunner.clip(sb.toString(), 15000);
      case 'pull':
        if (dir == null || m == null) return 'Error: give dir of a cloned copy.';
        final branch = '${m['branch']}';
        final (cr, ref) = await CodeGit.call('GET', '/repos/${m['repo']}/git/ref/heads/${Uri.encodeComponent(branch)}');
        if (cr != 200) return CodeGit.err(cr, ref);
        final head = '${ref['object']['sha']}';
        if (head == m['commit']) return 'Already up to date (${head.substring(0, 7)}).';
        final base = Map<String, String>.from(m['files'] as Map);
        final now = await CodeGit.shasOf(dir);
        final local = CodeGit.changes(base, now);
        final mine = {...local['modified']!, ...local['added']!, ...local['deleted']!};
        // Download the new commit into a temp folder, then take every file this copy did not change.
        final tmp = Directory('${await _ws()}/.cache/pull-${DateTime.now().millisecondsSinceEpoch}');
        final (sha, remote) = await CodeGit.download('${m['repo']}', head, tmp);
        final conflicts = <String>[];
        final newBase = <String, String>{};
        for (final e in remote.entries) {
          final p = e.key;
          if (mine.contains(p)) {
            if (base[p] != e.value) conflicts.add(p);
            newBase[p] = conflicts.contains(p) ? (base[p] ?? '') : e.value;
            if (conflicts.contains(p)) {
              final theirs = File('${tmp.path}/$p');
              if (await theirs.exists()) await theirs.copy('${dir.path}/$p.theirs');
            }
            continue;
          }
          final src = File('${tmp.path}/$p');
          if (await src.exists()) {
            final dst = File('${dir.path}/$p');
            await dst.parent.create(recursive: true);
            await src.copy(dst.path);
          }
          newBase[p] = e.value;
        }
        var removed = 0;
        for (final p in base.keys) {
          if (!remote.containsKey(p) && !mine.contains(p)) {
            final f = File('${dir.path}/$p');
            if (await f.exists()) await f.delete();
            removed++;
          }
        }
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
        m
          ..['commit'] = sha
          ..['files'] = newBase;
        await CodeGit.writeMeta(dir, m);
        return 'Pulled ${sha.substring(0, 7)}.${removed > 0 ? ' $removed files removed.' : ''}'
            '${mine.isEmpty ? '' : ' Your ${mine.length} local changes were kept.'}'
            '${conflicts.isEmpty ? '' : '\nCONFLICTS (changed on both sides): ${conflicts.join(', ')}. GitHub\'s version of each is next to it as <file>.theirs: merge them by hand, delete the .theirs files, then push.'}';
      case 'push':
        if (dir == null) return 'Error: give dir of a cloned copy.';
        final msg = _s(a, 'message');
        if (msg.isEmpty) return 'Error: give a commit message that says what changed and why.';
        // .theirs files from a pull must never go up.
        if ((await CodeGit.localFiles(dir)).keys.any((p) => p.endsWith('.theirs'))) {
          return 'Error: merge the .theirs files from the last pull first, then delete them.';
        }
        return CodeGit.push(dir, msg, branch: _s(a, 'branch').isEmpty ? null : _s(a, 'branch'));
      case 'publish':
        final d = _s(a, 'dir');
        if (d.isEmpty) return 'Error: give dir (the folder to publish).';
        final root = Directory(await resolve(d));
        if (!await root.exists()) return 'Error: folder not found: ${root.path}';
        final name = _s(a, 'name').isNotEmpty ? _s(a, 'name') : root.path.split('/').last;
        return CodeGit.publish(root, name.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-'),
            private: a['private'] != false, description: _s(a, 'description'));
      case 'branch':
        if (repo == null) return need2('branch');
        final name = _s(a, 'branch');
        if (name.isEmpty) return 'Error: give branch (the new name).';
        var from = m == null ? '' : '${m['commit']}';
        if (from.isEmpty) {
          final (c, info) = await CodeGit.call('GET', '/repos/$repo');
          if (c != 200) return CodeGit.err(c, info);
          final (c2, ref) = await CodeGit.call('GET', '/repos/$repo/git/ref/heads/${info['default_branch']}');
          if (c2 != 200) return CodeGit.err(c2, ref);
          from = '${ref['object']['sha']}';
        }
        final (c, r) = await CodeGit.call('POST', '/repos/$repo/git/refs', {'ref': 'refs/heads/$name', 'sha': from});
        if (c != 201) return CodeGit.err(c, r);
        if (dir != null && m != null) {
          m['branch'] = name;
          await CodeGit.writeMeta(dir, m);
        }
        return 'Made branch $name from ${from.substring(0, 7)}${m == null ? '' : '; this copy now pushes to it'}.';
      case 'branches':
        if (repo == null) return need2('branches');
        final (c, r) = await CodeGit.call('GET', '/repos/$repo/branches?per_page=50');
        if (c != 200) return CodeGit.err(c, r);
        return [for (final b in r as List) '${b['name']}${b['name'] == m?['branch'] ? ' (this copy)' : ''}'].join('\n');
      case 'log':
        if (repo == null) return need2('log');
        final br = _s(a, 'branch').isNotEmpty ? _s(a, 'branch') : (m == null ? '' : '${m['branch']}');
        final (c, r) = await CodeGit.call('GET', '/repos/$repo/commits?per_page=15${br.isEmpty ? '' : '&sha=${Uri.encodeComponent(br)}'}');
        if (c != 200) return CodeGit.err(c, r);
        return [
          for (final e in r as List)
            '${'${e['sha']}'.substring(0, 7)} ${'${e['commit']['author']['date']}'.substring(0, 10)} ${e['commit']['author']['name']}: ${'${e['commit']['message']}'.split('\n').first}'
        ].join('\n');
      case 'pr':
        if (repo == null) return need2('pr');
        var base = _s(a, 'base');
        if (base.isEmpty) {
          final (c, info) = await CodeGit.call('GET', '/repos/$repo');
          base = c == 200 ? '${info['default_branch']}' : 'main';
        }
        final head = _s(a, 'head').isNotEmpty ? _s(a, 'head') : (m == null ? '' : '${m['branch']}');
        if (head.isEmpty || head == base) return 'Error: push your work to its own branch first (push with branch), then pr with head = that branch.';
        final (c, r) = await CodeGit.call('POST', '/repos/$repo/pulls', {'title': _s(a, 'title'), 'body': '${a['body'] ?? ''}', 'head': head, 'base': base});
        if (c != 201) return CodeGit.err(c, r);
        return 'Opened pull request #${r['number']}: ${r['html_url']}';
      case 'prs':
      case 'issues':
        if (repo == null) return need2(act);
        final (c, r) = await CodeGit.call('GET', '/repos/$repo/${act == 'prs' ? 'pulls' : 'issues'}?state=open&per_page=30');
        if (c != 200) return CodeGit.err(c, r);
        final l = [
          for (final e in r as List)
            if (act == 'prs' || e['pull_request'] == null) '#${e['number']} ${e['title']} (${e['user']?['login'] ?? ''})'
        ];
        return l.isEmpty ? 'None open.' : l.join('\n');
      case 'issue':
        if (repo == null) return need2('issue');
        final n = (a['number'] as num?)?.toInt();
        if (n == null) return 'Error: give number.';
        final (c, r) = await CodeGit.call('GET', '/repos/$repo/issues/$n');
        if (c != 200) return CodeGit.err(c, r);
        final (_, cm) = await CodeGit.call('GET', '/repos/$repo/issues/$n/comments?per_page=30');
        return CodeRunner.clip('#$n ${r['title']} [${r['state']}] by ${r['user']?['login']}\n${r['body'] ?? ''}\n'
            '${[for (final e in (cm is List ? cm : const [])) '--- ${e['user']?['login']}: ${e['body']}'].join('\n')}', 12000);
      case 'create_issue':
        if (repo == null) return need2('create_issue');
        final (c, r) = await CodeGit.call('POST', '/repos/$repo/issues', {'title': _s(a, 'title'), 'body': '${a['body'] ?? ''}'});
        if (c != 201) return CodeGit.err(c, r);
        return 'Opened issue #${r['number']}: ${r['html_url']}';
      case 'comment':
        if (repo == null) return need2('comment');
        final n = (a['number'] as num?)?.toInt();
        if (n == null) return 'Error: give number.';
        final (c, r) = await CodeGit.call('POST', '/repos/$repo/issues/$n/comments', {'body': '${a['body'] ?? ''}'});
        if (c != 201) return CodeGit.err(c, r);
        return 'Commented: ${r['html_url']}';
      case 'pages':
        if (repo == null) return need2('pages');
        final branch = _s(a, 'branch').isNotEmpty ? _s(a, 'branch') : (m == null ? 'main' : '${m['branch']}');
        var (c, r) = await CodeGit.call('POST', '/repos/$repo/pages', {'source': {'branch': branch, 'path': '/'}});
        if (c == 409) (c, r) = await CodeGit.call('GET', '/repos/$repo/pages');
        if (c != 201 && c != 200) {
          return '${CodeGit.err(c, r)}\nFree GitHub accounts host Pages only from public repos.';
        }
        return 'Hosting on GitHub Pages from $branch: ${r['html_url'] ?? 'https://${repo.split('/').first.toLowerCase()}.github.io/${repo.split('/').last}/'} '
            '(the first deploy takes about a minute).';
    }
    return 'Error: unknown action $act.';
  }

  static Future<String> _build(Map<String, dynamic> a) async {
    final need = await CodeGit.needToken('Build the app on your GitHub for free and download it here');
    if (need != null) return need;
    final root = Directory(await resolve(_s(a, 'dir')));
    if (!await root.exists()) return 'Error: folder not found: ${root.path}';
    final act = _s(a, 'action');
    if (act == 'start') {
      final t = _s(a, 'target');
      if (t.isEmpty) return 'Error: give target: apk, aab, web or test.';
      return CodeGit.buildStart(root, t);
    }
    return CodeGit.buildStatus(root, await _ws(), waitSec: act == 'wait' ? 240 : 0);
  }

  // ---------------------------------------------------------------- snapshots

  static Future<Directory> _snapDir(String dir) async => Directory('${await _ws()}/.snapshots/${dir.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_')}');

  static Future<String> _snapshot(Map<String, dynamic> a) async {
    final d = _s(a, 'dir');
    final root = Directory(await resolve(d));
    if (!await root.exists()) return 'Error: folder not found: ${root.path}';
    final sd = await _snapDir(d);
    final act = _s(a, 'action');
    Future<List<File>> all() async =>
        await sd.exists() ? ((await sd.list().where((e) => e is File && e.path.endsWith('.zip')).cast<File>().toList())..sort((x, y) => x.path.compareTo(y.path))) : <File>[];
    Future<File> save(String label) async {
      final arc = Archive();
      for (final e in (await CodeGit.localFiles(root)).entries) {
        final b = await e.value.readAsBytes();
        arc.addFile(ArchiveFile(e.key, b.length, b));
      }
      final m = File('${root.path}/${CodeGit.meta}');
      if (await m.exists()) {
        final b = await m.readAsBytes();
        arc.addFile(ArchiveFile(CodeGit.meta, b.length, b));
      }
      await sd.create(recursive: true);
      final ts = DateTime.now().toIso8601String().substring(0, 19).replaceAll(RegExp(r'[-:T]'), '');
      final f = File('${sd.path}/$ts-${label.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '-')}.zip');
      await f.writeAsBytes(ZipEncoder().encode(arc));
      // Keep the newest 20.
      final l = await all();
      for (final old in l.take((l.length - 20).clamp(0, l.length))) {
        await old.delete();
      }
      return f;
    }

    switch (act) {
      case 'save':
        final f = await save(_s(a, 'label').isEmpty ? 'snapshot' : _s(a, 'label'));
        return 'Saved snapshot ${f.path.split('/').last.replaceAll('.zip', '')} (${_size(await f.length())}).';
      case 'list':
        final l = await all();
        if (l.isEmpty) return 'No snapshots of $d yet.';
        return [for (final f in l.reversed) f.path.split('/').last.replaceAll('.zip', '')].join('\n');
      case 'changes':
      case 'restore':
        final l = await all();
        if (l.isEmpty) return 'No snapshots of $d yet.';
        final id = _s(a, 'id');
        final f = id.isEmpty ? l.last : l.where((x) => x.path.contains(id)).lastOrNull;
        if (f == null) return 'Error: no snapshot "$id". Use list.';
        final arc = ZipDecoder().decodeBytes(await f.readAsBytes());
        if (act == 'changes') {
          final then = <String, String>{
            for (final e in arc.files)
              if (e.isFile && e.name != CodeGit.meta) e.name: CodeGit.blobSha(e.content as List<int>),
          };
          final ch = CodeGit.changes(then, await CodeGit.shasOf(root));
          final n = ch.values.fold<int>(0, (s, x) => s + x.length);
          if (n == 0) return 'Same as ${f.path.split('/').last}.';
          return 'Since ${f.path.split('/').last.replaceAll('.zip', '')}:\n'
              '${[for (final p in ch['modified']!) 'M $p', for (final p in ch['added']!) 'A $p', for (final p in ch['deleted']!) 'D $p'].join('\n')}';
        }
        await save('before-restore');
        for (final e in (await CodeGit.localFiles(root)).values) {
          await e.delete();
        }
        for (final e in arc.files) {
          if (!e.isFile) continue;
          final out = File('${root.path}/${e.name}');
          await out.parent.create(recursive: true);
          await out.writeAsBytes(e.content as List<int>);
        }
        return 'Restored $d to ${f.path.split('/').last.replaceAll('.zip', '')} (the state before is saved as "before-restore").';
    }
    return 'Error: unknown action $act.';
  }

  // ---------------------------------------------------------------- http

  static Future<String> _http(Map<String, dynamic> a) async {
    final url = _s(a, 'url');
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return 'Error: give a full url (https://...).';
    final method = _s(a, 'method').isEmpty ? 'GET' : _s(a, 'method').toUpperCase();
    final req = http.Request(method, uri);
    final h = a['headers'];
    if (h is Map) {
      h.forEach((k, v) => req.headers['$k'] = '$v');
    }
    if (a['json'] != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(a['json']);
    } else if (a['body'] != null) {
      req.body = '${a['body']}';
    }
    final sw = Stopwatch()..start();
    final res = await http.Response.fromStream(await http.Client().send(req).timeout(const Duration(seconds: 45)));
    sw.stop();
    var body = utf8.decode(res.bodyBytes, allowMalformed: true);
    final ct = res.headers['content-type'] ?? '';
    if (ct.contains('json') || body.trimLeft().startsWith('{') || body.trimLeft().startsWith('[')) {
      try {
        body = const JsonEncoder.withIndent('  ').convert(jsonDecode(body));
      } catch (_) {}
    }
    const keep = {'content-type', 'content-length', 'location', 'cache-control', 'set-cookie', 'www-authenticate', 'x-ratelimit-remaining', 'retry-after', 'access-control-allow-origin'};
    final hs = res.headers.entries.where((e) => keep.contains(e.key)).map((e) => '${e.key}: ${e.value}').join('\n');
    return 'HTTP ${res.statusCode} ${res.reasonPhrase ?? ''} · ${sw.elapsedMilliseconds} ms · ${_size(res.bodyBytes.length)}\n$hs\n\n${CodeRunner.clip(body, 12000)}';
  }

  // ---------------------------------------------------------------- package docs

  static Future<dynamic> _getJson(String url) async {
    final r = await http.get(Uri.parse(url), headers: {'Accept': 'application/json', 'User-Agent': 'SubMac (https://submac.site)'}).timeout(const Duration(seconds: 30));
    if (r.statusCode == 404) throw Exception('Error: not found in the registry. Check the exact package name (action search).');
    if (r.statusCode != 200) throw Exception('Error: the registry answered ${r.statusCode}.');
    return jsonDecode(utf8.decode(r.bodyBytes, allowMalformed: true));
  }

  static Future<String> _docs(Map<String, dynamic> a) async {
    final eco = _s(a, 'ecosystem');
    final act = _s(a, 'action');
    final p = _s(a, 'package');
    final q = Uri.encodeQueryComponent(_s(a, 'query').isEmpty ? p : _s(a, 'query'));
    final pe = Uri.encodeComponent(p);
    if (act != 'search' && p.isEmpty) return 'Error: give package.';
    String readme(String s) => CodeRunner.clip(s, 12000);
    switch (eco) {
      case 'npm':
        if (act == 'search') {
          final j = await _getJson('https://registry.npmjs.org/-/v1/search?text=$q&size=10');
          return [for (final o in j['objects'] as List) '${o['package']['name']} ${o['package']['version']}: ${o['package']['description'] ?? ''}'].join('\n');
        }
        if (act == 'info') {
          final j = await _getJson('https://registry.npmjs.org/$p/latest');
          return 'npm $p ${j['version']} · ${j['license'] ?? ''}\n${j['description'] ?? ''}\nInstall: npm install $p\n'
              'Homepage: ${j['homepage'] ?? ''}\nRepo: ${j['repository']?['url'] ?? ''}\nDependencies: ${(j['dependencies'] as Map?)?.keys.join(', ') ?? 'none'}'
              '${j['types'] != null || j['typings'] != null ? '\nHas TypeScript types.' : ''}';
        }
        final j = await _getJson('https://registry.npmjs.org/$p');
        if (act == 'versions') {
          final t = Map<String, dynamic>.from(j['time'] as Map? ?? {});
          final v = (j['versions'] as Map).keys.toList();
          return 'Latest: ${j['dist-tags']?['latest']}\n${v.reversed.take(25).map((e) => '$e ${'${t[e] ?? ''}'.split('T').first}').join('\n')}';
        }
        return readme('${j['readme'] ?? 'No readme.'}');
      case 'pypi':
        if (act == 'search') {
          return 'PyPI has no search API. Use web_search "pypi $q", then code_docs info with the exact name.';
        }
        final j = await _getJson('https://pypi.org/pypi/$pe/json');
        final info = j['info'] as Map;
        if (act == 'versions') {
          final rel = (j['releases'] as Map).keys.toList();
          return 'Latest: ${info['version']}\n${rel.reversed.take(30).join(', ')}';
        }
        if (act == 'readme') return readme('${info['description'] ?? 'No readme.'}');
        return 'PyPI $p ${info['version']} · ${info['license'] ?? ''} · Python ${info['requires_python'] ?? 'any'}\n${info['summary'] ?? ''}\n'
            'Install: pip install $p\nHome: ${info['home_page'] ?? (info['project_urls'] as Map?)?.values.firstOrNull ?? ''}\n'
            'Requires: ${(info['requires_dist'] as List?)?.take(15).join(', ') ?? 'none'}';
      case 'pub':
        if (act == 'search') {
          final j = await _getJson('https://pub.dev/api/search?q=$q');
          return [for (final x in (j['packages'] as List).take(15)) '${x['package']}'].join('\n');
        }
        final j = await _getJson('https://pub.dev/api/packages/$pe');
        final l = j['latest']['pubspec'] as Map;
        if (act == 'versions') {
          return 'Latest: ${j['latest']['version']}\n${(j['versions'] as List).reversed.take(25).map((v) => '${v['version']} ${'${v['published'] ?? ''}'.split('T').first}').join('\n')}';
        }
        if (act == 'readme') {
          return 'Pub has no readme API. Read https://pub.dev/packages/$p with fetch_url. Description: ${l['description'] ?? ''}';
        }
        return 'pub $p ${j['latest']['version']}\n${l['description'] ?? ''}\nAdd: flutter pub add $p (or $p: ^${j['latest']['version']} in pubspec.yaml)\n'
            'SDK: ${l['environment']?['sdk'] ?? ''}${l['environment']?['flutter'] != null ? ', Flutter ${l['environment']['flutter']}' : ''}\n'
            'Repo: ${l['repository'] ?? l['homepage'] ?? ''}\nDependencies: ${(l['dependencies'] as Map?)?.keys.join(', ') ?? 'none'}';
      case 'crates':
        if (act == 'search') {
          final j = await _getJson('https://crates.io/api/v1/crates?q=$q&per_page=10');
          return [for (final c in j['crates'] as List) '${c['name']} ${c['max_stable_version'] ?? c['max_version']}: ${c['description'] ?? ''}'].join('\n');
        }
        final j = await _getJson('https://crates.io/api/v1/crates/$pe');
        final c = j['crate'] as Map;
        if (act == 'versions') return [for (final v in (j['versions'] as List).take(25)) '${v['num']} ${'${v['created_at']}'.split('T').first}${v['yanked'] == true ? ' (yanked)' : ''}'].join('\n');
        if (act == 'readme') return 'Read https://docs.rs/$p with fetch_url. ${c['description'] ?? ''}';
        return 'crate $p ${c['max_stable_version'] ?? c['max_version']}\n${c['description'] ?? ''}\nAdd: cargo add $p\nDocs: https://docs.rs/$p\nRepo: ${c['repository'] ?? ''}';
      case 'go':
        if (act == 'search') return 'Use web_search "pkg.go.dev $q", then code_docs info with the module path.';
        final r = await http.get(Uri.parse('https://proxy.golang.org/${p.toLowerCase()}/@${act == 'versions' ? 'v/list' : 'latest'}')).timeout(const Duration(seconds: 30));
        if (r.statusCode != 200) return 'Error: module not found (${r.statusCode}). Give the full module path, e.g. github.com/gin-gonic/gin.';
        if (act == 'versions') return r.body.trim().split('\n').reversed.take(30).join('\n');
        final j = jsonDecode(r.body);
        return 'Go module $p ${j['Version']} (${'${j['Time']}'.split('T').first})\nAdd: go get $p@${j['Version']}\nDocs: https://pkg.go.dev/$p';
      case 'nuget':
        final j = await _getJson('https://azuresearch-usnc.nuget.org/query?q=${act == 'search' ? q : 'packageid:$pe'}&take=10');
        return [for (final x in j['data'] as List) '${x['id']} ${x['version']}: ${x['description'] ?? ''}${act == 'search' ? '' : '\nAdd: dotnet add package ${x['id']}'}'].join('\n');
      case 'packagist':
        if (act == 'search') {
          final j = await _getJson('https://packagist.org/search.json?q=$q&per_page=10');
          return [for (final x in j['results'] as List) '${x['name']}: ${x['description'] ?? ''}'].join('\n');
        }
        final j = await _getJson('https://repo.packagist.org/p2/$p.json');
        final v = ((j['packages'] as Map)[p] as List).first as Map;
        return 'Packagist $p ${v['version']}\n${v['description'] ?? ''}\nAdd: composer require $p\nPHP: ${v['require']?['php'] ?? 'any'}';
      case 'rubygems':
        if (act == 'search') {
          final j = await _getJson('https://rubygems.org/api/v1/search.json?query=$q');
          return [for (final x in (j as List).take(10)) '${x['name']} ${x['version']}: ${x['info'] ?? ''}'].join('\n');
        }
        final j = await _getJson('https://rubygems.org/api/v1/gems/$pe.json');
        return 'Gem $p ${j['version']}\n${j['info'] ?? ''}\nAdd: gem install $p (or bundle add $p)\nDocs: ${j['documentation_uri'] ?? j['homepage_uri'] ?? ''}';
    }
    return 'Error: ecosystem must be npm, pypi, pub, crates, go, nuget, packagist or rubygems.';
  }

  // ---------------------------------------------------------------- check

  /// Static checks that need no engine (pure; unit tested). Returns problems, one per line ('' = fine).
  static List<String> staticCheck(String path, String text, {bool Function(String rel)? exists}) {
    final p = <String>[];
    final ext = path.contains('.') ? path.split('.').last.toLowerCase() : '';
    final lines = const LineSplitter().convert(text);
    for (var i = 0; i < lines.length; i++) {
      if (RegExp(r'^(<{7}|={7}|>{7})( |$)').hasMatch(lines[i])) p.add('line ${i + 1}: merge conflict marker');
    }
    switch (ext) {
      case 'json':
        try {
          jsonDecode(text);
        } on FormatException catch (e) {
          p.add('JSON: ${e.message}${e.offset == null ? '' : ' at character ${e.offset}'}');
        }
      case 'yaml':
      case 'yml':
        for (var i = 0; i < lines.length; i++) {
          if (lines[i].startsWith('\t') || RegExp(r'^ *\t').hasMatch(lines[i])) p.add('line ${i + 1}: YAML can\'t indent with tabs');
        }
      case 'css':
      case 'scss':
        final o = '{'.allMatches(text).length, c = '}'.allMatches(text).length;
        if (o != c) p.add('CSS: $o "{" but $c "}"');
      case 'html':
      case 'htm':
        final body = text.replaceAll(RegExp(r'<!--[\s\S]*?-->'), '').replaceAll(RegExp(r'<(script|style)\b[\s\S]*?</\1>', caseSensitive: false), '');
        const voids = {'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'source', 'track', 'wbr', '!doctype'};
        final stack = <String>[];
        for (final m in RegExp(r'<(/?)([a-zA-Z!][\w-]*)[^>]*?(/?)>').allMatches(body)) {
          final name = m.group(2)!.toLowerCase();
          if (voids.contains(name) || m.group(3) == '/') continue;
          if (m.group(1) == '/') {
            final at = stack.lastIndexOf(name);
            if (at < 0) {
              p.add('HTML: </$name> without an opening tag');
            } else {
              for (final un in stack.sublist(at + 1)) {
                if (!const {'p', 'li', 'td', 'tr', 'th', 'option', 'dt', 'dd'}.contains(un)) p.add('HTML: <$un> is not closed before </$name>');
              }
              stack.removeRange(at, stack.length);
            }
          } else {
            stack.add(name);
          }
        }
        for (final un in stack) {
          if (!const {'p', 'li', 'td', 'tr', 'th', 'option', 'html', 'body', 'head', 'dt', 'dd'}.contains(un)) p.add('HTML: <$un> is never closed');
        }
        for (final m in RegExp(r'''<img\b(?![^>]*\balt=)[^>]*>''', caseSensitive: false).allMatches(text).take(5)) {
          p.add('HTML: image without alt text: ${m.group(0)!.length > 80 ? '${m.group(0)!.substring(0, 80)}…' : m.group(0)}');
        }
        if (!RegExp(r'<meta[^>]+name=.viewport', caseSensitive: false).hasMatch(text) && text.contains('<head')) {
          p.add('HTML: no <meta name="viewport"> (looks tiny on phones)');
        }
        if (exists != null) {
          for (final m in RegExp(r'''(?:src|href)\s*=\s*["']([^"'#?]+)''', caseSensitive: false).allMatches(text)) {
            final ref = m.group(1)!.trim();
            if (ref.isEmpty || RegExp(r'^(https?:|//|mailto:|tel:|data:|javascript:|#|\{)').hasMatch(ref)) continue;
            if (!exists(ref)) p.add('HTML: missing file "$ref"');
          }
        }
    }
    return p;
  }

  static Future<String> _check(Map<String, dynamic> a) async {
    final targets = <String, File>{};
    String base = '';
    if (_s(a, 'path').isNotEmpty) {
      final f = File(await resolve(_s(a, 'path')));
      if (!await f.exists()) return 'Error: file not found: ${f.path}';
      targets[f.path.split('/').last] = f;
      base = f.parent.path;
    } else {
      final root = Directory(await resolve(_s(a, 'dir')));
      if (!await root.exists()) return 'Error: folder not found: ${root.path}';
      base = root.path;
      for (final e in (await CodeGit.localFiles(root)).entries) {
        if (isText(e.key) && targets.length < 300) targets[e.key] = e.value;
      }
    }
    final out = <String>[];
    var checked = 0;
    var todos = 0;
    for (final e in targets.entries) {
      if (await e.value.length() > 1024 * 1024) continue;
      String text;
      try {
        text = await e.value.readAsString();
      } catch (_) {
        continue;
      }
      checked++;
      todos += RegExp(r'\b(TODO|FIXME|XXX)\b').allMatches(text).length;
      final dir = e.value.parent.path;
      final probs = staticCheck(e.key, text, exists: (ref) {
        final full = ref.startsWith('/') ? '$base$ref' : '$dir/$ref';
        return File(full).existsSync() || Directory(full).existsSync();
      });
      // Pages also get the site check's extras: cut-off files, filler text, links that go nowhere, srcset and CSS url() files.
      final low = e.key.toLowerCase();
      if (low.endsWith('.html') || low.endsWith('.htm')) {
        final (sp, _) = SiteCheck.checkHtml(e.key, text, exists: (ref) {
          final full = ref.startsWith('/') ? '$base$ref' : '$dir/$ref';
          return File(full).existsSync() || Directory(full).existsSync();
        });
        for (final x in sp) {
          final short = x.startsWith('${e.key}: ') ? x.substring(e.key.length + 2) : x;
          if (!probs.any((q) => q.replaceFirst('HTML: ', '') == short)) probs.add(short);
        }
      } else if (low.endsWith('.css')) {
        for (final r in SiteCheck.cssRefs(text)) {
          if (RegExp(r'^(https?:|//|data:|#)').hasMatch(r)) continue;
          final ref = r.split('#').first.split('?').first;
          final full = ref.startsWith('/') ? '$base$ref' : '$dir/$ref';
          if (!File(full).existsSync()) probs.add('missing file "$ref"');
        }
      }
      final lang = CodeRunner.languageOfPath(e.key);
      if (lang == 'python' || lang == 'javascript' || lang == 'typescript') {
        final r = await CodeRunner.I.syntax(lang!, text);
        if (r['ok'] != true) probs.add('$lang syntax: ${r['error']}');
      }
      for (final x in probs) {
        out.add('${e.key}: $x');
      }
    }
    if (checked == 0) return 'No text files to check.';
    final head = out.isEmpty ? 'Checked $checked files: no problems found.' : 'Checked $checked files: ${out.length} problems.';
    return '$head${todos > 0 ? ' ($todos TODO/FIXME notes left.)' : ''}${out.isEmpty ? '' : '\n${CodeRunner.clip(out.join('\n'), 10000)}'}';
  }

  // ---------------------------------------------------------------- projects

  /// Starter files for each template (pure; unit tested). [n] = the project name.
  static Map<String, String>? template(String t, String n) {
    final id = n.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
    final slug = id.replaceAll('_', '-');
    const gi = 'node_modules/\nbuild/\ndist/\n.dart_tool/\n__pycache__/\n.venv/\ntarget/\n.env\n';
    switch (t) {
      case 'web':
        return {
          'index.html': '<!doctype html>\n<html lang="en">\n<head>\n  <meta charset="utf-8">\n  <meta name="viewport" content="width=device-width, initial-scale=1">\n'
              '  <title>$n</title>\n  <link rel="stylesheet" href="style.css">\n</head>\n<body>\n  <main>\n    <h1>$n</h1>\n    <p id="out"></p>\n  </main>\n'
              '  <script src="app.js"></script>\n</body>\n</html>\n',
          'style.css': ':root { --ink: #1b1b1b; --paper: #fafaf7; --accent: #2f6fde; }\n* { box-sizing: border-box; }\n'
              'body { margin: 0; font-family: system-ui, sans-serif; color: var(--ink); background: var(--paper); }\n'
              'main { max-width: 960px; margin: 0 auto; padding: 32px 20px; }\nh1 { font-size: clamp(28px, 6vw, 56px); }\n',
          'app.js': "document.getElementById('out').textContent = 'Ready.';\n",
          'README.md': '# $n\n\nOpen index.html. Host it with code_build (target web) or the Publish button.\n',
        };
      case 'python':
        return {
          'main.py': 'def main() -> None:\n    print("Hello from $n")\n\n\nif __name__ == "__main__":\n    main()\n',
          'test_main.py': 'from main import main\n\n\ndef test_main(capsys):\n    main()\n    assert "Hello" in capsys.readouterr().out\n',
          'requirements.txt': '',
          '.gitignore': gi,
          'README.md': '# $n\n\nRun: python main.py\nTest: pytest\n',
        };
      case 'node-api':
        return {
          'package.json': '{\n  "name": "$slug",\n  "version": "1.0.0",\n  "type": "module",\n  "scripts": { "start": "node server.js", "test": "node --test" },\n'
              '  "dependencies": { "express": "^4.21.0" }\n}\n',
          'server.js': "import express from 'express';\n\nexport const app = express();\napp.use(express.json());\n\n"
              "app.get('/health', (req, res) => res.json({ ok: true }));\n\nif (process.argv[1].endsWith('server.js')) {\n"
              "  const port = process.env.PORT || 3000;\n  app.listen(port, () => console.log('Listening on ' + port));\n}\n",
          'server.test.js': "import test from 'node:test';\nimport assert from 'node:assert';\nimport { app } from './server.js';\n\n"
              "test('app exists', () => assert.ok(app));\n",
          '.gitignore': gi,
          'README.md': '# $n\n\nnpm install, then npm start. Tests: npm test.\n',
        };
      case 'ts-node':
        return {
          'package.json': '{\n  "name": "$slug",\n  "version": "1.0.0",\n  "type": "module",\n  "scripts": { "build": "tsc", "start": "node dist/index.js", "test": "tsc --noEmit" },\n'
              '  "devDependencies": { "typescript": "^5.6.0" }\n}\n',
          'tsconfig.json': '{\n  "compilerOptions": { "target": "ES2022", "module": "NodeNext", "moduleResolution": "NodeNext", "strict": true, "outDir": "dist" },\n  "include": ["src"]\n}\n',
          'src/index.ts': 'export function greet(name: string): string {\n  return `Hello, \${name}`;\n}\n\nconsole.log(greet("$n"));\n',
          '.gitignore': gi,
        };
      case 'react':
        return {
          'package.json': '{\n  "name": "$slug",\n  "private": true,\n  "type": "module",\n  "scripts": { "dev": "vite", "build": "vite build", "test": "vite build" },\n'
              '  "dependencies": { "react": "^18.3.1", "react-dom": "^18.3.1" },\n  "devDependencies": { "@vitejs/plugin-react": "^4.3.0", "vite": "^5.4.0" }\n}\n',
          'vite.config.js': "import { defineConfig } from 'vite';\nimport react from '@vitejs/plugin-react';\n\nexport default defineConfig({ plugins: [react()], base: './' });\n",
          'index.html': '<!doctype html>\n<html lang="en">\n<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>$n</title></head>\n'
              '<body><div id="root"></div><script type="module" src="/src/main.jsx"></script></body>\n</html>\n',
          'src/main.jsx': "import React from 'react';\nimport { createRoot } from 'react-dom/client';\nimport App from './App.jsx';\n\n"
              "createRoot(document.getElementById('root')).render(<App />);\n",
          'src/App.jsx': "import { useState } from 'react';\n\nexport default function App() {\n  const [n, setN] = useState(0);\n"
              "  return (\n    <main style={{ fontFamily: 'system-ui', padding: 24 }}>\n      <h1>$n</h1>\n"
              "      <button onClick={() => setN(n + 1)}>Clicked {n} times</button>\n    </main>\n  );\n}\n",
          '.gitignore': gi,
        };
      case 'flutter':
        return {
          'pubspec.yaml': 'name: ${id.isEmpty ? 'app' : id}\ndescription: $n\npublish_to: none\nversion: 1.0.0+1\n\nenvironment:\n  sdk: ">=3.4.0 <4.0.0"\n\n'
              'dependencies:\n  flutter:\n    sdk: flutter\n\ndev_dependencies:\n  flutter_test:\n    sdk: flutter\n  flutter_lints: ^4.0.0\n\nflutter:\n  uses-material-design: true\n',
          'lib/main.dart': "import 'package:flutter/material.dart';\n\nvoid main() => runApp(const App());\n\nclass App extends StatelessWidget {\n"
              "  const App({super.key});\n\n  @override\n  Widget build(BuildContext context) => MaterialApp(\n        title: '$n',\n"
              "        theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),\n        home: const Home(),\n      );\n}\n\n"
              "class Home extends StatefulWidget {\n  const Home({super.key});\n\n  @override\n  State<Home> createState() => _HomeState();\n}\n\n"
              "class _HomeState extends State<Home> {\n  int count = 0;\n\n  @override\n  Widget build(BuildContext context) => Scaffold(\n"
              "        appBar: AppBar(title: const Text('$n')),\n        body: Center(child: Text('Tapped \$count times')),\n"
              "        floatingActionButton: FloatingActionButton(onPressed: () => setState(() => count++), child: const Icon(Icons.add)),\n      );\n}\n",
          'test/widget_test.dart': "import 'package:flutter_test/flutter_test.dart';\nimport 'package:${id.isEmpty ? 'app' : id}/main.dart';\n\n"
              "void main() {\n  testWidgets('counts taps', (t) async {\n    await t.pumpWidget(const App());\n    await t.tap(find.byType(FloatingActionButton));\n"
              "    await t.pump();\n    expect(find.text('Tapped 1 times'), findsOneWidget);\n  });\n}\n",
          'analysis_options.yaml': 'include: package:flutter_lints/flutter.yaml\n',
          '.gitignore': gi,
          'README.md': '# $n\n\nFlutter app. The android/ and web/ folders are made by the build (flutter create .) on GitHub.\n',
        };
      case 'go':
        return {
          'go.mod': 'module example.com/$slug\n\ngo 1.22\n',
          'main.go': 'package main\n\nimport "fmt"\n\nfunc Greet(name string) string { return "Hello, " + name }\n\nfunc main() { fmt.Println(Greet("$n")) }\n',
          'main_test.go': 'package main\n\nimport "testing"\n\nfunc TestGreet(t *testing.T) {\n\tif Greet("x") != "Hello, x" {\n\t\tt.Fatal("wrong greeting")\n\t}\n}\n',
          '.gitignore': gi,
        };
      case 'rust':
        return {
          'Cargo.toml': '[package]\nname = "${id.isEmpty ? 'app' : id}"\nversion = "0.1.0"\nedition = "2021"\n\n[dependencies]\n',
          'src/main.rs': 'fn greet(name: &str) -> String {\n    format!("Hello, {name}")\n}\n\nfn main() {\n    println!("{}", greet("$n"));\n}\n\n'
              '#[cfg(test)]\nmod tests {\n    #[test]\n    fn greets() {\n        assert_eq!(super::greet("x"), "Hello, x");\n    }\n}\n',
          '.gitignore': gi,
        };
      case 'c':
        return {'main.c': '#include <stdio.h>\n\nint main(void) {\n    printf("Hello from $n\\n");\n    return 0;\n}\n', 'README.md': '# $n\n\nRun with code_run (path main.c).\n'};
      case 'cpp':
        return {'main.cpp': '#include <iostream>\n\nint main() {\n    std::cout << "Hello from $n\\n";\n    return 0;\n}\n', 'README.md': '# $n\n\nRun with code_run (path main.cpp).\n'};
      case 'chrome-extension':
        return {
          'manifest.json': '{\n  "manifest_version": 3,\n  "name": "$n",\n  "version": "1.0.0",\n  "description": "$n",\n  "action": { "default_popup": "popup.html" },\n  "permissions": ["storage"]\n}\n',
          'popup.html': '<!doctype html>\n<html><head><meta charset="utf-8"><style>body{font-family:system-ui;width:260px;padding:12px}</style></head>\n'
              '<body><h3>$n</h3><button id="go">Go</button><p id="out"></p><script src="popup.js"></script></body></html>\n',
          'popup.js': "document.getElementById('go').addEventListener('click', () => {\n  document.getElementById('out').textContent = 'Clicked';\n});\n",
        };
    }
    return null;
  }

  static Future<String> _project(Map<String, dynamic> a) async {
    final act = _s(a, 'action');
    final ws = await _ws();
    switch (act) {
      case 'new':
        final t = _s(a, 'template');
        final name = _s(a, 'name').isEmpty ? 'my-app' : _s(a, 'name');
        final files = template(t, name);
        if (files == null) {
          return 'Error: templates: web, python, node-api, ts-node, react, flutter, go, rust, c, cpp, chrome-extension.';
        }
        final root = Directory(_s(a, 'dir').isNotEmpty ? await resolve(_s(a, 'dir')) : '$ws/code/${name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-')}');
        if (await root.exists() && (await CodeGit.localFiles(root)).isNotEmpty) return 'Error: ${root.path} already has files. Pick another name or dir.';
        for (final e in files.entries) {
          final f = File('${root.path}/${e.key}');
          await f.parent.create(recursive: true);
          await f.writeAsString(e.value);
        }
        final extra = t == 'flutter'
            ? ' The android/ and web/ platform folders are made on GitHub at build time (code_build adds "flutter create .").'
            : '';
        return 'Made ${root.path} (${files.length} files: ${files.keys.where((k) => !k.startsWith('.github')).join(', ')}).$extra';
      case 'info':
        final root = Directory(await resolve(_s(a, 'dir')));
        if (!await root.exists()) return 'Error: folder not found: ${root.path}';
        final files = await CodeGit.localFiles(root);
        final byLang = <String, int>{};
        var lines = 0, bytes = 0;
        for (final e in files.entries) {
          final n = await e.value.length();
          bytes += n;
          final ext = e.key.contains('.') ? e.key.split('.').last.toLowerCase() : '(none)';
          if (isText(e.key) && n < 1024 * 1024) {
            try {
              final c = '\n'.allMatches(await e.value.readAsString()).length + 1;
              lines += c;
              byLang[ext] = (byLang[ext] ?? 0) + c;
            } catch (_) {}
          }
        }
        final top = byLang.entries.toList()..sort((x, y) => y.value.compareTo(x.value));
        final kind = await CodeGit.kindOf(root);
        final m = await CodeGit.readMeta(root);
        final how = switch (kind) {
          'flutter' => 'Flutter app. Test: code_build start target test. App: target apk. Web: target web.',
          'android' => 'Android (Gradle). APK: code_build target apk.',
          'react-native' => 'React Native. APK: code_build target apk (release build, runs on GitHub). Tests: target test.',
          'capacitor' => 'Capacitor/Ionic. APK: code_build target apk (web build, cap sync, Gradle on GitHub). Site: target web.',
          'node' => 'Node project: scripts in package.json. Test: code_build target test; site: target web.',
          'python' => 'Python. Run: code_run path main.py with dir. Full tests: code_build target test.',
          'go' || 'rust' || 'dart' => 'Run: code_run with the main file. Tests: code_build target test.',
          'static' => 'Plain website: show index.html with a ```file block (it has Publish), or code_build target web.',
          _ => 'Run single files with code_run.',
        };
        return '${root.path}\nKind: $kind · ${files.length} files · $lines lines · ${_size(bytes)}\n'
            'Languages (lines): ${top.take(8).map((e) => '.${e.key} ${e.value}').join(', ')}\n'
            '${m == null ? 'Not on GitHub.' : 'GitHub: ${m['repo']} (${m['branch']} @ ${'${m['commit']}'.substring(0, 7)})'}\n$how';
      case 'zip':
        final root = Directory(await resolve(_s(a, 'dir')));
        if (!await root.exists()) return 'Error: folder not found: ${root.path}';
        final arc = Archive();
        final name = root.path.split('/').last;
        for (final e in (await CodeGit.localFiles(root)).entries) {
          final b = await e.value.readAsBytes();
          arc.addFile(ArchiveFile('$name/${e.key}', b.length, b));
        }
        final out = File('$ws/exports/$name.zip');
        await out.parent.create(recursive: true);
        await out.writeAsBytes(ZipEncoder().encode(arc));
        return 'Packed ${arc.length} files into ${out.path} (${_size(await out.length())}). Show it with a ```file block to share.';
      case 'unzip':
        final f = File(await resolve(_s(a, 'path')));
        if (!await f.exists()) return 'Error: file not found: ${f.path}';
        final arc = ZipDecoder().decodeBytes(await f.readAsBytes());
        final root = Directory(_s(a, 'dir').isNotEmpty ? await resolve(_s(a, 'dir')) : '$ws/code/${f.path.split('/').last.replaceAll(RegExp(r'\.zip$'), '')}');
        // A zip with one top folder unpacks without that extra level.
        final tops = {for (final e in arc.files) e.name.split('/').first};
        final strip = tops.length == 1 && arc.files.any((e) => e.name.contains('/'));
        var n = 0;
        for (final e in arc.files) {
          if (!e.isFile) continue;
          var rel = strip ? e.name.substring(e.name.indexOf('/') + 1) : e.name;
          if (rel.isEmpty || rel.split('/').contains('..') || rel.startsWith('__MACOSX')) continue;
          rel = rel.replaceAll('\\', '/');
          final out = File('${root.path}/$rel');
          await out.parent.create(recursive: true);
          await out.writeAsBytes(e.content as List<int>);
          n++;
        }
        return 'Unpacked $n files into ${root.path}.';
    }
    return 'Error: unknown action $act.';
  }
}
