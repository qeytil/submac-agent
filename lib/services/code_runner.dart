import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Size;

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;

/// Runs code for the Coder bot, at no cost to SubMac:
///  - Python, JavaScript, TypeScript and SQL run on the phone, in a hidden web view (Python and SQL engines are
///    downloaded once from a public CDN and then cached by the web view);
///  - compiled languages (C, C++, Rust, Go, C#, F#, Dart, Swift, Zig, Ruby, Haskell, Lua, Julia, OCaml, Pascal,
///    Fortran, D, Crystal) go from the phone straight to a free public compiler service.
/// Never name the service to users: it is "the online compiler".
class CodeRunner {
  CodeRunner._();
  static final I = CodeRunner._();

  static const local = {'python', 'javascript', 'typescript', 'sql'};

  /// Compiled languages: our name -> (the compiler service's language, which compiler names count, extra flags).
  static const remote = <String, (String, String, String)>{
    'c': ('c', r'^x86-64 gcc \d', '-O2 -lm'),
    'cpp': ('c++', r'^x86-64 gcc \d', '-O2 -std=c++20'),
    'rust': ('rust', r'^rustc \d', '-C opt-level=2'),
    'go': ('go', r'^x86-64 gc \d', ''),
    'csharp': ('csharp', r'^\.NET \d+\.\d+ CoreCLR$', ''),
    'fsharp': ('fsharp', r'^\.NET \d+\.\d+ CoreCLR$', ''),
    'dart': ('dart', r'^Dart \d', ''),
    'swift': ('swift', r'^x86-64 swiftc \d', ''),
    'zig': ('zig', r'^zig \d', ''),
    'ruby': ('ruby', r'^Ruby \d', ''),
    'haskell': ('haskell', r'^x86-64 ghc \d', ''),
    'lua': ('lua', r'^Lua \d', ''),
    'julia': ('julia', r'^Julia \d', ''),
    'ocaml': ('ocaml', r'^x86-64 ocamlopt \d[\d.]*$', ''),
    'pascal': ('pascal', r'^x86-64 fpc \d', ''),
    'fortran': ('fortran', r'^x86-64 gfortran \d', ''),
    'd': ('d', r'^ldc \d', ''),
    'crystal': ('crystal', r'^Crystal \d', ''),
  };

  /// Every language name the model may pass, with common aliases.
  static String? normalize(String lang) {
    final l = lang.trim().toLowerCase();
    const alias = {
      'py': 'python', 'python3': 'python', 'js': 'javascript', 'node': 'javascript', 'nodejs': 'javascript', 'ts': 'typescript',
      'sqlite': 'sql', 'c++': 'cpp', 'cxx': 'cpp', 'cc': 'cpp', 'rs': 'rust', 'golang': 'go', 'c#': 'csharp', 'cs': 'csharp',
      'f#': 'fsharp', 'fs': 'fsharp', 'rb': 'ruby', 'hs': 'haskell', 'jl': 'julia', 'ml': 'ocaml', 'pas': 'pascal',
      'f90': 'fortran', 'cr': 'crystal',
    };
    final n = alias[l] ?? l;
    return local.contains(n) || remote.containsKey(n) ? n : null;
  }

  /// The language of a file, from its extension.
  static String? languageOfPath(String path) {
    final e = path.contains('.') ? path.split('.').last.toLowerCase() : '';
    const byExt = {
      'py': 'python', 'js': 'javascript', 'mjs': 'javascript', 'cjs': 'javascript', 'ts': 'typescript', 'sql': 'sql', 'c': 'c',
      'cpp': 'cpp', 'cc': 'cpp', 'cxx': 'cpp', 'rs': 'rust', 'go': 'go', 'cs': 'csharp', 'fs': 'fsharp', 'dart': 'dart',
      'swift': 'swift', 'zig': 'zig', 'rb': 'ruby', 'hs': 'haskell', 'lua': 'lua', 'jl': 'julia', 'ml': 'ocaml', 'pas': 'pascal',
      'f90': 'fortran', 'f95': 'fortran', 'd': 'd', 'cr': 'crystal',
    };
    return byExt[e];
  }

  // ---------------------------------------------------------------- the online compiler

  static const _ce = 'https://godbolt.org/api';
  List<Map<String, dynamic>>? _compilers;
  DateTime? _compilersAt;

  static List<int> _ver(Map<String, dynamic> c) {
    final s = '${c['semver'] ?? ''}'.trim();
    final src = RegExp(r'\d').hasMatch(s) ? s : '${c['name']}';
    return [for (final m in RegExp(r'\d+').allMatches(src).take(4)) int.parse(m.group(0)!)];
  }

  static int _cmp(List<int> a, List<int> b) {
    for (var i = 0; i < a.length || i < b.length; i++) {
      final x = i < a.length ? a[i] : 0, y = i < b.length ? b[i] : 0;
      if (x != y) return x.compareTo(y);
    }
    return 0;
  }

  /// The newest stable compiler for [lang] in a compiler list (pure; unit tested).
  static Map<String, dynamic>? pickCompiler(List<Map<String, dynamic>> all, String lang) {
    final spec = remote[lang];
    if (spec == null) return null;
    final rx = RegExp(spec.$2);
    final bad = RegExp(r'trunk|snapshot|nightly|assert|beta|\brc\b|dev|latest|\(', caseSensitive: false);
    final xs = all
        .where((c) => c['lang'] == spec.$1 && c['supportsExecute'] == true && rx.hasMatch('${c['name']}') && !bad.hasMatch('${c['name']}'))
        .toList()
      ..sort((a, b) => _cmp(_ver(a), _ver(b)));
    return xs.isEmpty ? null : xs.last;
  }

  Future<List<Map<String, dynamic>>> _list() async {
    if (_compilers != null && _compilersAt != null && DateTime.now().difference(_compilersAt!) < const Duration(hours: 12)) return _compilers!;
    final r = await http.get(Uri.parse('$_ce/compilers?fields=id,lang,name,semver,supportsExecute'), headers: {'Accept': 'application/json'})
        .timeout(const Duration(seconds: 30));
    if (r.statusCode != 200) throw Exception('the online compiler is not answering (${r.statusCode})');
    _compilers = [for (final e in jsonDecode(r.body) as List) Map<String, dynamic>.from(e as Map)];
    _compilersAt = DateTime.now();
    return _compilers!;
  }

  static String _lines(dynamic l) => [for (final e in (l as List? ?? const [])) '${(e as Map)['text'] ?? ''}'].join('\n');

  Future<String> runRemote(String lang, String source, {String stdin = '', List<String> args = const [], String flags = ''}) async {
    final List<Map<String, dynamic>> all;
    try {
      all = await _list();
    } catch (e) {
      return 'Error: could not reach the online compiler ($e). Check the connection and try again.';
    }
    final c = pickCompiler(all, lang);
    if (c == null) return 'Error: no online compiler for $lang right now.';
    final spec = remote[lang]!;
    final body = {
      'source': source,
      'options': {
        'userArguments': [spec.$3, flags].where((e) => e.trim().isNotEmpty).join(' '),
        'executeParameters': {'args': args, 'stdin': stdin},
        'compilerOptions': {'executorRequest': true},
        'filters': {'execute': true},
        'tools': [],
        'libraries': [],
      },
      'lang': spec.$1,
      'allowStoreCodeDebug': false,
    };
    final http.Response r;
    try {
      r = await http
          .post(Uri.parse('$_ce/compiler/${c['id']}/compile'),
              headers: {'Content-Type': 'application/json', 'Accept': 'application/json'}, body: jsonEncode(body))
          .timeout(const Duration(seconds: 90));
    } on TimeoutException {
      return 'Error: the online compiler took longer than 90 s. Make the program smaller or faster.';
    } catch (e) {
      return 'Error: could not reach the online compiler ($e).';
    }
    if (r.statusCode == 429) return 'Error: the online compiler is busy (too many runs). Wait a minute, then run again.';
    if (r.statusCode != 200) return 'Error: the online compiler answered ${r.statusCode}: ${r.body.length > 300 ? r.body.substring(0, 300) : r.body}';
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return formatRemote(j, '${c['name']}');
  }

  /// The compiler's answer as text for the model (pure; unit tested).
  static String formatRemote(Map<String, dynamic> j, String compiler) {
    final build = j['buildResult'] is Map ? Map<String, dynamic>.from(j['buildResult'] as Map) : const <String, dynamic>{};
    final buildErr = _lines(build['stderr']).trim();
    final buildCode = build['code'];
    final sb = StringBuffer('compiler: $compiler\n');
    if (j['didExecute'] != true) {
      sb.writeln('result: did not run (build failed${buildCode == null ? '' : ', code $buildCode'})');
      final e = buildErr.isNotEmpty ? buildErr : _lines(j['stderr']).trim();
      if (e.isNotEmpty) sb.writeln('build errors:\n${clip(e, 8000)}');
      return sb.toString().trim();
    }
    if (buildErr.isNotEmpty) sb.writeln('build warnings:\n${clip(buildErr, 3000)}');
    sb.writeln('exit_code: ${j['code']}');
    final out = _lines(j['stdout']);
    final err = _lines(j['stderr']);
    if (out.trim().isNotEmpty) sb.writeln('stdout:\n${clip(out, 10000)}');
    if (err.trim().isNotEmpty) sb.writeln('stderr:\n${clip(err, 4000)}');
    if (j['timedOut'] == true) sb.writeln('[stopped: it ran too long]');
    return sb.toString().trim();
  }

  static String clip(String s, int n) => s.length <= n ? s : '${s.substring(0, n)}\n…[${s.length - n} more characters]';

  // ---------------------------------------------------------------- on the phone (hidden web view)

  HeadlessInAppWebView? _view;
  InAppWebViewController? _ctl;
  Completer<void>? _ready;
  Timer? _idle;
  Future<void> _queue = Future.value();

  Future<void> _start() async {
    if (_ready != null) return _ready!.future;
    final ready = _ready = Completer<void>();
    _view = HeadlessInAppWebView(
      initialSize: const Size(400, 400),
      initialData: InAppWebViewInitialData(data: _harness, baseUrl: WebUri('https://submac.local/'), mimeType: 'text/html', encoding: 'utf-8'),
      initialSettings: InAppWebViewSettings(javaScriptEnabled: true, cacheEnabled: true, allowFileAccessFromFileURLs: false),
      onLoadStop: (ctl, _) {
        _ctl = ctl;
        if (!ready.isCompleted) ready.complete();
      },
      onReceivedError: (ctl, req, err) {
        if (req.isForMainFrame == true && !ready.isCompleted) ready.completeError(Exception(err.description));
      },
    );
    await _view!.run();
    return ready.future.timeout(const Duration(seconds: 30));
  }

  Future<void> _stop() async {
    _idle?.cancel();
    final v = _view;
    _view = null;
    _ctl = null;
    _ready = null;
    try {
      await v?.dispose();
    } catch (_) {}
  }

  /// Runs [fn] in the page; one run at a time. A run that hangs (an endless loop) resets the page.
  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> args, int timeoutSec) {
    final c = Completer<Map<String, dynamic>>();
    _queue = _queue.then((_) async {
      try {
        await _start();
        _idle?.cancel();
        final r = await _ctl!
            .callAsyncJavaScript(functionBody: 'return await window.$fn(a);', arguments: {'a': args})
            .timeout(Duration(seconds: timeoutSec));
        if (r?.error != null) {
          c.complete({'ok': false, 'error': '${r!.error}'});
        } else {
          final v = r?.value;
          c.complete(v is Map ? Map<String, dynamic>.from(v) : {'ok': false, 'error': 'no result'});
        }
      } on TimeoutException {
        await _stop();
        c.complete({'ok': false, 'error': 'stopped after $timeoutSec s (an endless loop, or too much work). The runner was reset.'});
      } catch (e) {
        await _stop();
        c.complete({'ok': false, 'error': '$e'});
      } finally {
        _idle = Timer(const Duration(minutes: 5), () => unawaited(_stop()));
      }
    });
    return c.future;
  }

  /// Python (on the phone). [files] are mounted at /work (the current folder); new or changed files come back.
  Future<Map<String, dynamic>> runPython(String code, {Map<String, String> files = const {}, String stdin = '', List<String> args = const [], List<String> packages = const [], int timeoutSec = 120}) =>
      _call('__py', {'code': code, 'files': files, 'stdin': stdin, 'argv': args, 'packages': packages}, timeoutSec + 60);

  Future<Map<String, dynamic>> runJs(String code, {bool typescript = false, String stdin = '', int timeoutSec = 60}) =>
      _call('__js', {'code': code, 'ts': typescript, 'stdin': stdin}, timeoutSec + (typescript ? 60 : 0));

  /// SQL on SQLite. [db] is the database file as base64 ('' = a new empty database); the changed file comes back as base64.
  Future<Map<String, dynamic>> runSql(String sql, {String db = ''}) => _call('__sql', {'sql': sql, 'db': db}, 90);

  /// Syntax check without running: python | javascript | typescript.
  Future<Map<String, dynamic>> syntax(String lang, String code) => _call('__syntax', {'lang': lang, 'code': code}, 90);

  /// Shapes a local run result as text for the model.
  static String formatLocal(Map<String, dynamic> r) {
    final sb = StringBuffer();
    if (r['ok'] != true) sb.writeln('result: failed');
    final out = '${r['stdout'] ?? ''}';
    final err = '${r['stderr'] ?? ''}';
    if (out.trim().isNotEmpty) sb.writeln('stdout:\n${clip(out, 10000)}');
    if (err.trim().isNotEmpty) sb.writeln('stderr:\n${clip(err, 4000)}');
    if (r['result'] != null && '${r['result']}'.isNotEmpty && '${r['result']}' != 'undefined' && '${r['result']}' != 'None') {
      sb.writeln('value: ${clip('${r['result']}', 3000)}');
    }
    if (r['error'] != null && '${r['error']}'.isNotEmpty) sb.writeln('error:\n${clip('${r['error']}', 6000)}');
    if (sb.isEmpty) sb.writeln('ok (no output)');
    return sb.toString().trim();
  }

  static const _pyodide = 'https://cdn.jsdelivr.net/pyodide/v0.27.7/full/';
  static const _ts = 'https://cdn.jsdelivr.net/npm/typescript@5.6.3/lib/typescript.js';
  static const _sqljs = 'https://cdn.jsdelivr.net/npm/sql.js@1.11.0/dist/';

  static const _harness = '''<!doctype html><html><head><meta charset="utf-8"></head><body><script>
const load = (src) => new Promise((ok, no) => { const s = document.createElement('script'); s.src = src; s.onload = ok;
  s.onerror = () => no(new Error('could not download ' + src.split('/').slice(-1)[0] + ' (no internet?)')); document.head.appendChild(s); });
let py = null, tsReady = null, SQL = null;
const fmt = (v) => { try { return typeof v === 'string' ? v : JSON.stringify(v, (k, x) => typeof x === 'bigint' ? x.toString() : x, 2); } catch (e) { return String(v); } };
async function pyInit() {
  if (py) return py;
  if (!window.loadPyodide) await load('$_pyodide' + 'pyodide.js');
  py = await loadPyodide({ indexURL: '$_pyodide' });
  return py;
}
async function tsInit() { if (!tsReady) tsReady = load('$_ts'); await tsReady; }
function walk(FS, dir, out) {
  for (const n of FS.readdir(dir)) {
    if (n === '.' || n === '..') continue;
    const p = dir + '/' + n; const st = FS.stat(p);
    if (FS.isDir(st.mode)) walk(FS, p, out); else out.push(p);
  }
  return out;
}
const b64 = (u8) => { let s = ''; for (let i = 0; i < u8.length; i += 32768) s += String.fromCharCode.apply(null, u8.subarray(i, i + 32768)); return btoa(s); };
const unb64 = (s) => { const b = atob(s); const u = new Uint8Array(b.length); for (let i = 0; i < b.length; i++) u[i] = b.charCodeAt(i); return u; };
window.__py = async (a) => {
  const p = await pyInit();
  let out = '', err = '';
  p.setStdout({ batched: (s) => { if (out.length < 200000) out += s + '\\n'; } });
  p.setStderr({ batched: (s) => { if (err.length < 100000) err += s + '\\n'; } });
  const lines = String(a.stdin || '').split('\\n'); let li = 0;
  p.setStdin({ stdin: () => (li < lines.length ? lines[li++] : null) });
  const FS = p.FS;
  try { walk(FS, '/work', []).forEach((f) => FS.unlink(f)); } catch (e) {}
  try { FS.mkdirTree('/work'); } catch (e) {}
  const before = {};
  for (const [path, data] of Object.entries(a.files || {})) {
    const full = '/work/' + path; const dir = full.split('/').slice(0, -1).join('/');
    try { FS.mkdirTree(dir); } catch (e) {}
    const u8 = unb64(data); FS.writeFile(full, u8); before[full] = data;
  }
  FS.chdir('/work');
  try {
    if ((a.packages || []).length) { await p.loadPackage('micropip'); const mp = p.pyimport('micropip'); await mp.install(a.packages); }
    await p.loadPackagesFromImports(a.code);
    p.globals.set('__argv', p.toPy(['main.py'].concat(a.argv || [])));
    await p.runPythonAsync('import sys, os; sys.argv = list(__argv); os.chdir("/work")');
    const r = await p.runPythonAsync(a.code);
    const files = {};
    for (const f of walk(FS, '/work', [])) {
      const data = b64(FS.readFile(f));
      if (before[f] !== data && data.length < 7000000) files[f.slice(6)] = data;
    }
    return { ok: true, stdout: out, stderr: err, result: r === undefined ? null : String(r), files };
  } catch (e) {
    return { ok: false, stdout: out, stderr: err, error: String(e && e.message || e) };
  }
};
window.__js = async (a) => {
  let out = '', err = '';
  const con = {
    log: (...x) => { out += x.map(fmt).join(' ') + '\\n'; }, info: (...x) => { out += x.map(fmt).join(' ') + '\\n'; },
    warn: (...x) => { err += x.map(fmt).join(' ') + '\\n'; }, error: (...x) => { err += x.map(fmt).join(' ') + '\\n'; },
    table: (x) => { out += fmt(x) + '\\n'; }, debug: () => {},
  };
  let code = a.code;
  try {
    if (a.ts) {
      await tsInit();
      const t = ts.transpileModule(code, { reportDiagnostics: true, compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.None } });
      const d = (t.diagnostics || []).map((x) => ts.flattenDiagnosticMessageText(x.messageText, '\\n'));
      if (d.length) return { ok: false, stdout: '', stderr: '', error: 'TypeScript: ' + d.join('\\n') };
      code = t.outputText.replace(/^export \\{\\};?\\s*\$/m, '');
    }
    const lines = String(a.stdin || '').split('\\n'); let li = 0;
    const input = () => (li < lines.length ? lines[li++] : null);
    const AsyncFn = Object.getPrototypeOf(async function () {}).constructor;
    const r = await new AsyncFn('console', 'input', 'readline', code)(con, input, input);
    return { ok: true, stdout: out, stderr: err, result: r === undefined ? null : fmt(r) };
  } catch (e) {
    return { ok: false, stdout: out, stderr: err, error: String(e && (e.stack || e.message) || e) };
  }
};
window.__sql = async (a) => {
  if (!SQL) { await load('$_sqljs' + 'sql-wasm.js'); SQL = await initSqlJs({ locateFile: (f) => '$_sqljs' + f }); }
  const db = a.db ? new SQL.Database(unb64(a.db)) : new SQL.Database();
  try {
    const res = db.exec(a.sql);
    const tables = res.map((r) => ({ columns: r.columns, rows: r.values.slice(0, 200), total: r.values.length }));
    return { ok: true, tables, changes: db.getRowsModified(), db: b64(db.export()) };
  } catch (e) {
    return { ok: false, error: String(e && e.message || e) };
  } finally { db.close(); }
};
window.__syntax = async (a) => {
  try {
    if (a.lang === 'python') {
      const p = await pyInit();
      p.globals.set('__src', a.code);
      await p.runPythonAsync('compile(__src, "file", "exec")');
      return { ok: true };
    }
    await tsInit();
    const f = ts.createSourceFile(a.lang === 'typescript' ? 'x.ts' : 'x.js', a.code, ts.ScriptTarget.Latest, true, a.lang === 'typescript' ? ts.ScriptKind.TS : ts.ScriptKind.JS);
    const d = f.parseDiagnostics || [];
    if (!d.length) return { ok: true };
    return { ok: false, error: d.slice(0, 20).map((x) => { const lc = f.getLineAndCharacterOfPosition(x.start || 0);
      return 'line ' + (lc.line + 1) + ':' + (lc.character + 1) + ' ' + ts.flattenDiagnosticMessageText(x.messageText, ' '); }).join('\\n') };
  } catch (e) { return { ok: false, error: String(e && e.message || e) }; }
};
</script></body></html>''';
}
