import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'apk_build.dart';
import 'code_runner.dart';
import 'connector_catalog.dart';
import 'connector_tools.dart';

/// Git for the Coder bot, on the user's own GitHub (their token, their free Actions minutes and Pages): clone a repo
/// into the workspace, see what changed, diff, pull, commit and push, branches, pull requests, issues, and builds
/// (APK, web, tests) on GitHub Actions with the result downloaded back to the phone. There is no git program on the
/// phone, so a local copy keeps `.telesia-git.json`: the repo, branch, base commit and every file's blob sha.
class CodeGit {
  static const meta = '.telesia-git.json';
  static const api = 'https://api.github.com';

  /// Set by the app: shows the GitHub connect sheet and returns true when the user connected.
  static Future<bool> Function(String why)? connect;

  static String get token {
    if (ConnectorTools.githubToken.isNotEmpty) return ConnectorTools.githubToken;
    final c = ConnectorCatalog.connected['github'];
    return c?['token'] ?? c?['key'] ?? (c == null || c.isEmpty ? '' : c.values.first);
  }

  /// Makes sure GitHub is connected, showing the connect sheet when it is not.
  static Future<String?> needToken(String why) async {
    if (token.isNotEmpty) return null;
    final ok = await connect?.call(why) ?? false;
    if (ok && token.isNotEmpty) return null;
    return 'GitHub is not connected, so this needs the user first. Say in one line what connecting GitHub lets you do '
        '(keep the code safe online, host it, build the APK for free), then call connect_app with app "GitHub".';
  }

  static Map<String, String> get _h => {
        'Authorization': 'Bearer $token',
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'Telesia',
      };

  static Future<(int, dynamic)> call(String method, String path, [Object? body]) async {
    final uri = Uri.parse(path.startsWith('http') ? path : '$api$path');
    final req = http.Request(method, uri)..headers.addAll(_h);
    if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    final res = await http.Response.fromStream(await req.send().timeout(const Duration(seconds: 60)));
    dynamic j;
    try {
      j = res.body.isEmpty ? null : jsonDecode(res.body);
    } catch (_) {
      j = res.body;
    }
    return (res.statusCode, j);
  }

  static String err(int code, dynamic j) {
    final m = j is Map ? '${j['message'] ?? ''}' : '$j';
    final hint = switch (code) {
      401 => ' The GitHub token is wrong or expired: ask the user to connect GitHub again (connect_app).',
      403 => ' The token may lack a permission (repo, workflow, pages) or the rate limit is reached.',
      404 => ' Not found, or the token cannot see it.',
      409 => ' The branch moved or the repo is empty.',
      422 => ' GitHub refused the input.',
      _ => '',
    };
    return 'Error: GitHub answered $code: ${m.length > 300 ? m.substring(0, 300) : m}.$hint';
  }

  /// git's blob id for some bytes (sha1 of "blob <size>\0" + bytes), so changes are found without a git program.
  static String blobSha(List<int> bytes) => sha1.convert([...utf8.encode('blob ${bytes.length}\u0000'), ...bytes]).toString();

  /// owner/name from "owner/name", a GitHub link or a clone address.
  static String? repoOf(String s) {
    final m = RegExp(r'(?:github\.com[/:])?([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(?:\.git)?/?$').firstMatch(s.trim());
    return m == null ? null : '${m.group(1)}/${m.group(2)}';
  }

  /// Folders a copy never sends to GitHub or snapshots.
  static final skipDir = RegExp(r'^(\.git|node_modules|\.dart_tool|build|dist|\.gradle|\.idea|__pycache__|\.venv|venv|target|\.snapshots|\.next)$');

  static Future<Map<String, File>> localFiles(Directory root) async {
    final out = <String, File>{};
    if (!await root.exists()) return out;
    Future<void> walk(Directory d, String rel) async {
      await for (final e in d.list(followLinks: false)) {
        final name = e.path.split('/').last;
        final r = rel.isEmpty ? name : '$rel/$name';
        if (e is Directory) {
          if (skipDir.hasMatch(name)) continue;
          await walk(e, r);
        } else if (e is File) {
          if (r == meta) continue;
          out[r] = e;
        }
      }
    }

    await walk(root, '');
    return out;
  }

  static Future<Map<String, dynamic>?> readMeta(Directory root) async {
    final f = File('${root.path}/$meta');
    if (!await f.exists()) return null;
    try {
      return Map<String, dynamic>.from(jsonDecode(await f.readAsString()) as Map);
    } catch (_) {
      return null;
    }
  }

  static Future<void> writeMeta(Directory root, Map<String, dynamic> m) =>
      File('${root.path}/$meta').writeAsString(const JsonEncoder.withIndent(' ').convert(m));

  /// What changed in a local copy since its base commit: modified, added, deleted (pure on the inputs; unit tested).
  static Map<String, List<String>> changes(Map<String, String> base, Map<String, String> now) {
    final mod = <String>[], add = <String>[], del = <String>[];
    now.forEach((p, s) {
      final b = base[p];
      if (b == null) {
        add.add(p);
      } else if (b != s) {
        mod.add(p);
      }
    });
    for (final p in base.keys) {
      if (!now.containsKey(p)) del.add(p);
    }
    return {'modified': mod..sort(), 'added': add..sort(), 'deleted': del..sort()};
  }

  static Future<Map<String, String>> shasOf(Directory root) async {
    final out = <String, String>{};
    for (final e in (await localFiles(root)).entries) {
      out[e.key] = blobSha(await e.value.readAsBytes());
    }
    return out;
  }

  // ---------------------------------------------------------------- download a commit into a folder

  /// Downloads [ref] of [repo] and writes its files into [root]. Returns the commit sha and each file's blob sha.
  /// [only] limits writing to those paths (a pull that keeps local edits).
  static Future<(String, Map<String, String>)> download(String repo, String ref, Directory root, {Set<String>? only}) async {
    final (c1, commit) = await call('GET', '/repos/$repo/commits/${Uri.encodeComponent(ref)}');
    if (c1 != 200) throw Exception(err(c1, commit));
    final sha = '${commit['sha']}';
    final treeSha = '${commit['commit']['tree']['sha']}';
    final (c2, tree) = await call('GET', '/repos/$repo/git/trees/$treeSha?recursive=1');
    if (c2 != 200) throw Exception(err(c2, tree));
    final shas = <String, String>{
      for (final e in (tree['tree'] as List? ?? const []))
        if ((e as Map)['type'] == 'blob') '${e['path']}': '${e['sha']}',
    };
    final res = await http.get(Uri.parse('$api/repos/$repo/zipball/$sha'), headers: _h).timeout(const Duration(minutes: 3));
    if (res.statusCode != 200) throw Exception('Error: could not download the code (${res.statusCode}).');
    if (res.bodyBytes.length > 80 * 1024 * 1024) throw Exception('Error: the repo is over 80 MB; too big for the phone.');
    final zip = ZipDecoder().decodeBytes(res.bodyBytes);
    await root.create(recursive: true);
    for (final f in zip.files) {
      if (!f.isFile) continue;
      final i = f.name.indexOf('/');
      final rel = i < 0 ? f.name : f.name.substring(i + 1);
      if (rel.isEmpty || rel.split('/').contains('..')) continue;
      if (only != null && !only.contains(rel)) continue;
      final out = File('${root.path}/$rel');
      await out.parent.create(recursive: true);
      await out.writeAsBytes(f.content as List<int>);
    }
    return (sha, shas);
  }

  // ---------------------------------------------------------------- push

  /// Commits every change in [root] and pushes it to [branch] (made from the base commit when new).
  static Future<String> push(Directory root, String message, {String? branch}) async {
    final m = await readMeta(root);
    if (m == null) return 'Error: this folder is not linked to GitHub. Use code_git clone, or publish to make a new repo from it.';
    final repo = '${m['repo']}';
    final base = '${m['commit']}';
    final target = (branch ?? '${m['branch']}').trim();
    final baseShas = Map<String, String>.from(m['files'] as Map? ?? const {});
    final files = await localFiles(root);
    final now = <String, String>{};
    for (final e in files.entries) {
      now[e.key] = blobSha(await e.value.readAsBytes());
    }
    final ch = changes(baseShas, now);
    final n = ch['modified']!.length + ch['added']!.length + ch['deleted']!.length;
    if (n == 0) return 'Nothing to push: no changes since ${base.substring(0, 7)}.';
    // The branch must still be where this copy started, or the push would undo someone else's work.
    final (cr, ref) = await call('GET', '/repos/$repo/git/ref/heads/${Uri.encodeComponent(target)}');
    final exists = cr == 200;
    if (exists && '${ref['object']['sha']}' != base) {
      return 'Error: $target on GitHub has new commits since this copy (${base.substring(0, 7)}). Run code_git pull first, '
          'or push to a new branch (branch: "a-new-name") and open a pull request.';
    }
    final (cc, bc) = await call('GET', '/repos/$repo/git/commits/$base');
    if (cc != 200) return err(cc, bc);
    final entries = <Map<String, dynamic>>[];
    for (final p in [...ch['modified']!, ...ch['added']!]) {
      final bytes = await files[p]!.readAsBytes();
      if (bytes.length > 50 * 1024 * 1024) return 'Error: $p is over 50 MB; GitHub refuses files that big.';
      final (cb, blob) = await call('POST', '/repos/$repo/git/blobs', {'content': base64Encode(bytes), 'encoding': 'base64'});
      if (cb != 201) return err(cb, blob);
      final mode = (await _isExec(files[p]!)) ? '100755' : '100644';
      entries.add({'path': p, 'mode': mode, 'type': 'blob', 'sha': '${blob['sha']}'});
    }
    for (final p in ch['deleted']!) {
      entries.add({'path': p, 'mode': '100644', 'type': 'blob', 'sha': null});
    }
    final (ct, tree) = await call('POST', '/repos/$repo/git/trees', {'base_tree': '${bc['tree']['sha']}', 'tree': entries});
    if (ct != 201) return err(ct, tree);
    final (cm, commit) = await call('POST', '/repos/$repo/git/commits', {'message': message, 'tree': '${tree['sha']}', 'parents': [base]});
    if (cm != 201) return err(cm, commit);
    final sha = '${commit['sha']}';
    final (cu, up) = exists
        ? await call('PATCH', '/repos/$repo/git/refs/heads/${Uri.encodeComponent(target)}', {'sha': sha})
        : await call('POST', '/repos/$repo/git/refs', {'ref': 'refs/heads/$target', 'sha': sha});
    if (cu != 200 && cu != 201) return err(cu, up);
    m
      ..['commit'] = sha
      ..['branch'] = target
      ..['files'] = now;
    await writeMeta(root, m);
    return 'Pushed ${sha.substring(0, 7)} to $repo ($target${exists ? '' : ', new branch'}): ${ch['modified']!.length} changed, '
        '${ch['added']!.length} added, ${ch['deleted']!.length} deleted.\nhttps://github.com/$repo/commit/$sha';
  }

  static Future<bool> _isExec(File f) async => f.path.endsWith('/gradlew') || f.path.endsWith('.sh');

  /// Makes a new repo on the user's account and pushes every file in [root] as the first commit.
  static Future<String> publish(Directory root, String name, {bool private = true, String description = ''}) async {
    if (await readMeta(root) != null) return 'This folder is already on GitHub: use code_git push.';
    final (c, r) = await call('POST', '/user/repos', {'name': name, 'private': private, 'description': description, 'auto_init': true});
    if (c != 201) return err(c, r);
    final repo = '${r['full_name']}';
    final branch = '${r['default_branch'] ?? 'main'}';
    // auto_init made one commit (a README); start from it.
    String? head;
    for (var i = 0; i < 6 && head == null; i++) {
      final (cr, ref) = await call('GET', '/repos/$repo/git/ref/heads/$branch');
      if (cr == 200) head = '${ref['object']['sha']}';
      if (head == null) await Future<void>.delayed(const Duration(seconds: 2));
    }
    if (head == null) return 'Error: GitHub made $repo but its first commit is not ready yet. Try code_git push in a minute.';
    final (_, tree) = await call('GET', '/repos/$repo/git/trees/$head?recursive=1');
    final shas = <String, String>{
      for (final e in ((tree is Map ? tree['tree'] : null) as List? ?? const []))
        if ((e as Map)['type'] == 'blob') '${e['path']}': '${e['sha']}',
    };
    // The README from GitHub stays unless the folder has its own.
    final readme = File('${root.path}/README.md');
    if (!await readme.exists() && shas.containsKey('README.md')) {
      await readme.writeAsString('# $name\n${description.isEmpty ? '' : '\n$description\n'}');
    }
    await writeMeta(root, {'repo': repo, 'branch': branch, 'commit': head, 'files': shas});
    final p = await push(root, 'First version from Telesia');
    return 'Made ${private ? 'private' : 'public'} repo https://github.com/$repo\n$p';
  }

  // ---------------------------------------------------------------- builds on GitHub Actions

  static const workflow = '.github/workflows/telesia-build.yml';

  /// What kind of project a folder holds: flutter | android | react-native | capacitor | node | python | go | rust | static | unknown.
  static Future<String> kindOf(Directory root) async {
    bool has(String p) => File('${root.path}/$p').existsSync();
    if (has('pubspec.yaml')) {
      return File('${root.path}/pubspec.yaml').readAsStringSync().contains('flutter:') ? 'flutter' : 'dart';
    }
    if (has('gradlew') || has('settings.gradle') || has('settings.gradle.kts')) return 'android';
    if (has('package.json')) {
      final pkg = File('${root.path}/package.json').readAsStringSync();
      if (has('capacitor.config.ts') || has('capacitor.config.json') || has('capacitor.config.js') || pkg.contains('"@capacitor/android"')) {
        return 'capacitor';
      }
      if (pkg.contains('"react-native"')) return 'react-native';
      return 'node';
    }
    if (has('requirements.txt') || has('pyproject.toml') || has('setup.py')) return 'python';
    if (has('go.mod')) return 'go';
    if (has('Cargo.toml')) return 'rust';
    if (has('index.html')) return 'static';
    return 'unknown';
  }

  /// A Flutter project made on the phone has no android/ or web/ folder: the build makes them (existing files stay).
  static const _create = '      - name: Platform folders\n        run: |\n'
      '          N=\$(grep -m1 "^name:" pubspec.yaml | awk \'{print \$2}\')\n'
      '          [ -d android ] && [ -d web ] || flutter create . --project-name "\$N" --platforms=android,web --org com.telesia.app\n';

  /// The workflow file for a build (pure; unit tested). target: apk | aab | web | test.
  static String? workflowFor(String kind, String target) {
    // React Native and Capacitor are Node projects for tests and websites.
    if ((kind == 'react-native' || kind == 'capacitor') && target != 'apk') return workflowFor('node', target);
    const head = 'name: Telesia build\non:\n  workflow_dispatch:\n';
    const pagesPerms = 'permissions:\n  contents: read\n  pages: write\n  id-token: write\n';
    const deploy = '  deploy:\n    needs: build\n    runs-on: ubuntu-latest\n    environment:\n      name: github-pages\n'
        '      url: \${{ steps.d.outputs.page_url }}\n    steps:\n      - id: d\n        uses: actions/deploy-pages@v4\n';
    String pages(String steps, String dir) => '$head$pagesPerms'
        'jobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v4\n$steps'
        '      - uses: actions/upload-pages-artifact@v3\n        with:\n          path: $dir\n$deploy';
    String job(String steps, String artifact, String paths) => '${head}jobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n'
        '      - uses: actions/checkout@v4\n$steps'
        '${artifact.isEmpty ? '' : '      - uses: actions/upload-artifact@v4\n        with:\n          name: $artifact\n          path: |\n$paths'}';
    const flutter = '      - uses: actions/setup-java@v4\n        with:\n          distribution: temurin\n          java-version: "17"\n'
        '      - uses: subosito/flutter-action@v2\n        with:\n          channel: stable\n          cache: true\n$_create      - run: flutter pub get\n';
    switch ('$kind/$target') {
      case 'flutter/apk':
        return job('$flutter      - run: flutter build apk --release\n', 'app', '            build/app/outputs/flutter-apk/app-release.apk\n');
      case 'flutter/aab':
        return job('$flutter      - run: flutter build appbundle --release\n', 'app', '            build/app/outputs/bundle/release/*.aab\n');
      case 'flutter/web':
        return pages('      - uses: subosito/flutter-action@v2\n        with:\n          channel: stable\n$_create      - run: flutter pub get\n'
            '      - run: flutter build web --release --base-href "/\${{ github.event.repository.name }}/"\n', 'build/web');
      case 'flutter/test':
        return job('$flutter      - run: flutter analyze --no-fatal-infos\n      - run: flutter test\n', '', '');
      case 'android/apk':
        // A committed local.properties points sdk.dir at someone's computer; the runner's ANDROID_HOME is the right one.
        return job('      - uses: actions/setup-java@v4\n        with:\n          distribution: temurin\n          java-version: "17"\n'
            '      - uses: gradle/actions/setup-gradle@v4\n      - run: rm -f local.properties && chmod +x gradlew && ./gradlew assembleDebug --stacktrace\n',
            'app', '            **/build/outputs/apk/**/*.apk\n');
      case 'react-native/apk':
        // Release, because a debug APK loads its JavaScript from a computer (Metro); the RN template signs release with the debug key.
        return job('      - uses: actions/setup-node@v4\n        with:\n          node-version: 20\n'
            '      - uses: actions/setup-java@v4\n        with:\n          distribution: temurin\n          java-version: "17"\n'
            '      - uses: gradle/actions/setup-gradle@v4\n      - run: npm ci || npm install\n'
            '      - working-directory: android\n        run: rm -f local.properties && chmod +x gradlew && ./gradlew assembleRelease --stacktrace\n',
            'app', '            android/app/build/outputs/apk/**/*.apk\n');
      case 'capacitor/apk':
        return job('      - uses: actions/setup-node@v4\n        with:\n          node-version: 20\n'
            '      - id: jv\n        run: |\n'
            '          V=\$(grep -o \'"@capacitor/android": *"[^0-9]*[0-9]*\' package.json | grep -o \'[0-9]*\$\' || true)\n'
            '          if [ "\${V:-6}" -ge 7 ]; then echo "java=21" >> \$GITHUB_OUTPUT; else echo "java=17" >> \$GITHUB_OUTPUT; fi\n'
            '      - uses: actions/setup-java@v4\n        with:\n          distribution: temurin\n          java-version: \${{ steps.jv.outputs.java }}\n'
            '      - uses: gradle/actions/setup-gradle@v4\n      - run: npm ci || npm install\n      - run: npm run build\n'
            '      - run: |\n          [ -d android ] || npx cap add android\n          npx cap sync android\n'
            '      - working-directory: android\n        run: rm -f local.properties && chmod +x gradlew && ./gradlew assembleDebug --stacktrace\n',
            'app', '            android/app/build/outputs/apk/**/*.apk\n');
      case 'android/test':
        return job('      - uses: actions/setup-java@v4\n        with:\n          distribution: temurin\n          java-version: "17"\n'
            '      - uses: gradle/actions/setup-gradle@v4\n      - run: chmod +x gradlew && ./gradlew test --stacktrace\n', '', '');
      case 'node/web':
        return pages('      - uses: actions/setup-node@v4\n        with:\n          node-version: 22\n      - run: npm ci || npm install\n'
            '      - run: npm run build\n      - run: mkdir -p out && cp -r dist/. out/ 2>/dev/null || cp -r build/. out/\n', 'out');
      case 'node/test':
        return job('      - uses: actions/setup-node@v4\n        with:\n          node-version: 22\n      - run: npm ci || npm install\n'
            '      - run: npm test\n', '', '');
      case 'static/web':
        return pages('', '.');
      case 'python/test':
        return job('      - uses: actions/setup-python@v5\n        with:\n          python-version: "3.12"\n'
            '      - run: pip install -r requirements.txt || true\n      - run: pip install pytest && pytest -q\n', '', '');
      case 'go/test':
        return job('      - uses: actions/setup-go@v5\n        with:\n          go-version: stable\n      - run: go vet ./... && go test ./...\n', '', '');
      case 'rust/test':
        return job('      - run: cargo test\n', '', '');
      case 'dart/test':
        return job('      - uses: dart-lang/setup-dart@v1\n      - run: dart pub get\n      - run: dart analyze\n      - run: dart test\n', '', '');
    }
    return null;
  }

  static Future<String> buildStart(Directory root, String target) async {
    final m = await readMeta(root);
    if (m == null) {
      return 'Error: this folder is not on GitHub yet. First code_git publish (a new private repo) or clone, then build.';
    }
    final repo = '${m['repo']}', branch = '${m['branch']}';
    final kind = await kindOf(root);
    final wf = workflowFor(kind, target);
    if (wf == null) {
      return 'Error: no ready build for a $kind project with target $target. Ready: flutter (apk, aab, web, test), android (apk, test), '
          'react-native and capacitor (apk, plus node web and test), node (web, test), static (web), python, go, rust and dart (test). '
          'For anything else write your own $workflow with workflow_dispatch (skill_use ${ApkBuild.skillId} has Android templates), '
          'push, then code_build start.';
    }
    if (wf.contains('deploy-pages')) {
      // Pages must be on, with GitHub Actions as its source.
      final (cp, _) = await call('GET', '/repos/$repo/pages');
      if (cp == 404) {
        final (c, r) = await call('POST', '/repos/$repo/pages', {'build_type': 'workflow'});
        if (c != 201 && c != 409) {
          return '${err(c, r)}\nGitHub Pages needs a public repo on a free account (or a paid plan for private).';
        }
      } else {
        await call('PUT', '/repos/$repo/pages', {'build_type': 'workflow'});
      }
    }
    final f = File('${root.path}/$workflow');
    final old = await f.exists() ? await f.readAsString() : '';
    if (old != wf) {
      await f.parent.create(recursive: true);
      await f.writeAsString(wf);
    }
    final p = await push(root, 'Telesia: build $target');
    if (p.startsWith('Error')) return p;
    // GitHub needs a moment to see a new workflow file.
    var started = false;
    String last = '';
    for (var i = 0; i < 6 && !started; i++) {
      if (i > 0) await Future<void>.delayed(const Duration(seconds: 3));
      final (c, r) = await call('POST', '/repos/$repo/actions/workflows/telesia-build.yml/dispatches', {'ref': branch});
      started = c == 204;
      last = err(c, r);
    }
    if (!started) return '$last\nThe token needs the "workflow" permission to start builds.';
    final now = DateTime.now().toUtc();
    m['build'] = {'target': target, 'at': now.toIso8601String()};
    await writeMeta(root, m);
    final mins = switch ('$kind/$target') {
      'flutter/apk' || 'flutter/aab' || 'react-native/apk' || 'capacitor/apk' => '6 to 10',
      'android/apk' => '4 to 8',
      _ => '2 to 5'
    };
    return 'Build started on GitHub ($kind, $target). It usually takes $mins minutes. Call code_build wait to follow it.';
  }

  static Future<Map<String, dynamic>?> _latestRun(String repo) async {
    final (c, r) = await call('GET', '/repos/$repo/actions/workflows/telesia-build.yml/runs?per_page=1');
    if (c != 200) return null;
    final runs = (r['workflow_runs'] as List? ?? const []);
    return runs.isEmpty ? null : Map<String, dynamic>.from(runs.first as Map);
  }

  /// The build's state; when it finished, the APK (or other file) is downloaded to builds/<repo>/ and the web address is
  /// given. [waitSec] > 0 follows a running build for that long.
  static Future<String> buildStatus(Directory root, String ws, {int waitSec = 0}) async {
    final m = await readMeta(root);
    if (m == null) return 'Error: this folder is not on GitHub.';
    final repo = '${m['repo']}';
    final until = DateTime.now().add(Duration(seconds: waitSec));
    Map<String, dynamic>? run;
    while (true) {
      run = await _latestRun(repo);
      if (run == null) return 'No build found yet. Start one with code_build start.';
      if (run['status'] == 'completed' || DateTime.now().isAfter(until)) break;
      await Future<void>.delayed(const Duration(seconds: 15));
    }
    final link = '${run['html_url']}';
    if (run['status'] != 'completed') {
      final mins = DateTime.now().toUtc().difference(DateTime.parse('${run['created_at']}')).inMinutes;
      return 'Still building (${run['status']}, $mins min so far). $link\nCall code_build wait again.';
    }
    if (run['conclusion'] != 'success') {
      final log = await _failLog(repo, run['id']);
      final why = ApkBuild.diagnosis(log);
      return 'The build FAILED (${run['conclusion']}). $link\n$log\n${why.isEmpty ? '' : '$why\n'}'
          'Fix the cause in the code, then code_build start again (at most 3 tries in a row; then tell the user the exact error '
          'line above and what it needs from them).';
    }
    final target = '${(m['build'] as Map?)?['target'] ?? ''}';
    final sb = StringBuffer('Build succeeded. $link\n');
    if (target == 'web') {
      final (c, p) = await call('GET', '/repos/$repo/pages');
      if (c == 200) sb.writeln('Live at ${p['html_url']} (it can take a minute to appear).');
    }
    final (ca, arts) = await call('GET', '/repos/$repo/actions/runs/${run['id']}/artifacts');
    if (ca == 200) {
      for (final a in (arts['artifacts'] as List? ?? const [])) {
        final res = await http.get(Uri.parse('${(a as Map)['archive_download_url']}'), headers: _h).timeout(const Duration(minutes: 3));
        if (res.statusCode != 200) {
          sb.writeln('Could not download ${a['name']} (${res.statusCode}).');
          continue;
        }
        final dir = Directory('$ws/builds/${repo.split('/').last}');
        await dir.create(recursive: true);
        for (final f in ZipDecoder().decodeBytes(res.bodyBytes).files) {
          if (!f.isFile) continue;
          final out = File('${dir.path}/${f.name.split('/').last}');
          await out.writeAsBytes(f.content as List<int>);
          final mb = (await out.length()) / (1024 * 1024);
          sb.writeln('Downloaded ${out.path} (${mb.toStringAsFixed(1)} MB). Show it with a ```file block so the user can install or share it.');
        }
      }
    }
    return sb.toString().trim();
  }

  static Future<String> _failLog(String repo, Object? runId) async {
    final (c, r) = await call('GET', '/repos/$repo/actions/runs/$runId/jobs');
    if (c != 200) return '';
    for (final j in (r['jobs'] as List? ?? const [])) {
      if ((j as Map)['conclusion'] != 'failure') continue;
      final step = [for (final s in (j['steps'] as List? ?? const [])) if ((s as Map)['conclusion'] == 'failure') s['name']].join(', ');
      final res = await http.get(Uri.parse('$api/repos/$repo/actions/jobs/${j['id']}/logs'), headers: _h).timeout(const Duration(seconds: 60));
      if (res.statusCode != 200) return 'Failed step: $step';
      final lines = utf8.decode(res.bodyBytes, allowMalformed: true).split('\n');
      // The lines around the first error say the most; the tail says how it ended.
      final i = lines.indexWhere((l) => RegExp(r'error|Error|FAILURE|failed|Exception', caseSensitive: true).hasMatch(l));
      final around = i < 0 ? <String>[] : lines.sublist((i - 5).clamp(0, lines.length), (i + 40).clamp(0, lines.length));
      final tail = lines.sublist((lines.length - 40).clamp(0, lines.length));
      String clean(List<String> l) => l.map((e) => e.replaceFirst(RegExp(r'^\d{4}-\d\d-\d\dT[\d:.]+Z '), '')).join('\n');
      return CodeRunner.clip('Failed step: $step\n--- first error ---\n${clean(around)}\n--- end of log ---\n${clean(tail)}', 9000);
    }
    return '';
  }
}
