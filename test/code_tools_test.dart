import 'dart:io';

import 'package:agent/services/bots.dart';
import 'package:agent/services/code_git.dart';
import 'package:agent/services/code_runner.dart';
import 'package:agent/services/code_tools.dart';
import 'package:agent/services/tool_scope.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('code_tools');
    CodeTools.dirOverride = tmp.path;
  });
  tearDown(() async {
    CodeTools.dirOverride = null;
    await tmp.delete(recursive: true);
  });

  group('diff and patch', () {
    test('a diff of two texts applies back exactly', () {
      const a = 'one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\n';
      const b = 'one\nTWO\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\neleven\n';
      final d = CodeTools.unified(a, b);
      expect(d, contains('-two'));
      expect(d, contains('+TWO'));
      expect(d, contains('+eleven'));
      expect(CodeTools.applyPatch(a, d), b);
    });

    test('equal texts give no diff', () {
      expect(CodeTools.unified('x\ny\n', 'x\ny\n'), '');
    });

    test('a patch with wrong line numbers still applies by its context', () {
      const text = 'a\nb\nc\nd\n';
      const patch = '--- x\n+++ x\n@@ -40,3 +40,3 @@\n b\n-c\n+C\n d\n';
      expect(CodeTools.applyPatch(text, patch), 'a\nb\nC\nd\n');
    });

    test('a patch that does not match says so', () {
      expect(() => CodeTools.applyPatch('a\nb\n', '@@ -1,1 +1,1 @@\n-zzz\n+y\n'), throwsFormatException);
    });

    test('line diff keeps order', () {
      final ops = CodeTools.diffLines(['a', 'b', 'c'], ['a', 'x', 'c']);
      expect(ops.map((o) => '${o.$1}${o.$2}').toList(), [' a', '-b', '+x', ' c']);
    });
  });

  group('git without git', () {
    test('blob ids match git', () {
      // git hash-object of "hello\n"
      expect(CodeGit.blobSha('hello\n'.codeUnits), 'ce013625030ba8dba906f756967f9e9ca394464a');
    });

    test('repo names from links', () {
      expect(CodeGit.repoOf('https://github.com/flutter/flutter'), 'flutter/flutter');
      expect(CodeGit.repoOf('git@github.com:a-b/c.d.git'), 'a-b/c.d');
      expect(CodeGit.repoOf('owner/name'), 'owner/name');
    });

    test('changes since the base commit', () {
      final c = CodeGit.changes({'a': '1', 'b': '2', 'c': '3'}, {'a': '1', 'b': '9', 'd': '4'});
      expect(c['modified'], ['b']);
      expect(c['added'], ['d']);
      expect(c['deleted'], ['c']);
    });

    test('build workflows for each kind', () {
      final apk = CodeGit.workflowFor('flutter', 'apk')!;
      expect(apk, contains('workflow_dispatch'));
      expect(apk, contains('flutter build apk --release'));
      expect(apk, contains('flutter create .'));
      expect(apk, contains('upload-artifact'));
      expect(CodeGit.workflowFor('flutter', 'web'), contains(r'${{ github.event.repository.name }}'));
      final web = CodeGit.workflowFor('static', 'web')!;
      expect(web, contains('deploy-pages'));
      expect(web, contains('pages: write'));
      expect(CodeGit.workflowFor('python', 'test'), contains('pytest'));
      expect(CodeGit.workflowFor('unknown', 'apk'), isNull);
    });

    test('a folder\'s kind', () async {
      await File('${tmp.path}/pubspec.yaml').writeAsString('name: x\nflutter:\n  uses-material-design: true\n');
      expect(await CodeGit.kindOf(tmp), 'flutter');
    });
  });

  group('runner', () {
    test('languages and aliases', () {
      expect(CodeRunner.normalize('Py'), 'python');
      expect(CodeRunner.normalize('C++'), 'cpp');
      expect(CodeRunner.normalize('golang'), 'go');
      expect(CodeRunner.normalize('java'), isNull);
      expect(CodeRunner.languageOfPath('src/main.rs'), 'rust');
    });

    test('picks the newest stable compiler', () {
      final list = [
        {'id': 'g9', 'lang': 'c++', 'name': 'x86-64 gcc 9.5', 'semver': '9.5', 'supportsExecute': true},
        {'id': 'g16', 'lang': 'c++', 'name': 'x86-64 gcc 16.2', 'semver': '16.2', 'supportsExecute': true},
        {'id': 'gt', 'lang': 'c++', 'name': 'x86-64 gcc (trunk)', 'semver': '(trunk)', 'supportsExecute': true},
        {'id': 'gn', 'lang': 'c++', 'name': 'x86-64 gcc 17.1', 'semver': '17.1', 'supportsExecute': false},
      ];
      expect(CodeRunner.pickCompiler(list, 'cpp')!['id'], 'g16');
      expect(CodeRunner.pickCompiler(list, 'rust'), isNull);
    });

    test('compiler output for the model', () {
      final ok = CodeRunner.formatRemote({
        'didExecute': true, 'code': 0,
        'stdout': [{'text': '42'}], 'stderr': [], 'buildResult': {'code': 0, 'stderr': []},
      }, 'gcc');
      expect(ok, contains('exit_code: 0'));
      expect(ok, contains('42'));
      final bad = CodeRunner.formatRemote({
        'didExecute': false, 'buildResult': {'code': 1, 'stderr': [{'text': 'main.c:1: error: expected ;'}]},
      }, 'gcc');
      expect(bad, contains('did not run'));
      expect(bad, contains('expected ;'));
    });
  });

  group('checks', () {
    test('HTML problems', () {
      final p = CodeTools.staticCheck('index.html', '<html><head></head><body><div><img src="a.png"><script src="app.js"></script></body></html>',
          exists: (ref) => ref == 'app.js');
      expect(p.any((e) => e.contains('<div> is')), isTrue);
      expect(p.any((e) => e.contains('missing file "a.png"')), isTrue);
      expect(p.any((e) => e.contains('alt')), isTrue);
      expect(p.any((e) => e.contains('viewport')), isTrue);
    });

    test('JSON, YAML and conflict markers', () {
      expect(CodeTools.staticCheck('a.json', '{"a": 1,}'), isNotEmpty);
      expect(CodeTools.staticCheck('a.json', '{"a": 1}'), isEmpty);
      expect(CodeTools.staticCheck('a.yml', 'a:\n\tb: 1\n'), isNotEmpty);
      expect(CodeTools.staticCheck('x.dart', 'a\n<<<<<<< HEAD\nb\n=======\nc\n>>>>>>> x\n').length, 3);
    });
  });

  group('projects, search and snapshots', () {
    test('every template has files and uses the name', () {
      for (final t in ['web', 'python', 'node-api', 'ts-node', 'react', 'flutter', 'go', 'rust', 'c', 'cpp', 'chrome-extension']) {
        final f = CodeTools.template(t, 'Hodan Shop');
        expect(f, isNotNull, reason: t);
        expect(f!.values.join().contains('Hodan Shop') || f.values.join().contains('hodan'), isTrue, reason: t);
      }
      expect(CodeTools.template('flutter', 'Hodan Shop')!['pubspec.yaml'], contains('name: hodan_shop'));
      expect(CodeTools.template('nope', 'x'), isNull);
    });

    test('new project, search and symbols', () async {
      final r = await CodeTools.execute('code_project', {'action': 'new', 'template': 'python', 'name': 'Calc'});
      expect(r, contains('code/calc'));
      final g = await CodeTools.execute('code_search', {'action': 'grep', 'query': 'Hello', 'dir': 'code/calc'});
      expect(g, contains('main.py:2:'));
      final s = await CodeTools.execute('code_search', {'action': 'symbols', 'dir': 'code/calc'});
      expect(s, contains('def main'));
      final t = await CodeTools.execute('code_search', {'action': 'tree', 'dir': 'code/calc'});
      expect(t, contains('README.md'));
      final i = await CodeTools.execute('code_project', {'action': 'info', 'dir': 'code/calc'});
      expect(i, contains('Kind: python'));
    });

    test('snapshot save, changes and restore', () async {
      await CodeTools.execute('code_project', {'action': 'new', 'template': 'web', 'name': 'Site'});
      expect(await CodeTools.execute('code_snapshot', {'action': 'save', 'dir': 'code/site', 'label': 'first'}), contains('Saved snapshot'));
      final f = File('${tmp.path}/code/site/app.js');
      await f.writeAsString('broken(');
      await File('${tmp.path}/code/site/extra.txt').writeAsString('x');
      final ch = await CodeTools.execute('code_snapshot', {'action': 'changes', 'dir': 'code/site'});
      expect(ch, contains('M app.js'));
      expect(ch, contains('A extra.txt'));
      await CodeTools.execute('code_snapshot', {'action': 'restore', 'dir': 'code/site', 'id': 'first'});
      expect(await f.readAsString(), contains('Ready.'));
      expect(File('${tmp.path}/code/site/extra.txt').existsSync(), isFalse);
    });

    test('patching a file on disk', () async {
      await File('${tmp.path}/a.txt').writeAsString('x\ny\nz\n');
      final r = await CodeTools.execute('code_diff', {'action': 'apply', 'path': 'a.txt', 'patch': '@@ -1,3 +1,3 @@\n x\n-y\n+Y\n z\n'});
      expect(r, contains('Patched'));
      expect(await File('${tmp.path}/a.txt').readAsString(), 'x\nY\nz\n');
    });

    test('zip and unzip a project', () async {
      await CodeTools.execute('code_project', {'action': 'new', 'template': 'c', 'name': 'Hello C'});
      final z = await CodeTools.execute('code_project', {'action': 'zip', 'dir': 'code/hello-c'});
      expect(z, contains('exports/hello-c.zip'));
      final u = await CodeTools.execute('code_project', {'action': 'unzip', 'path': 'exports/hello-c.zip', 'dir': 'code/copy'});
      expect(u, contains('Unpacked 2 files'));
      expect(File('${tmp.path}/code/copy/main.c').existsSync(), isTrue);
    });
  });

  group('wiring', () {
    test('risky actions ask first', () {
      expect(CodeTools.riskFor('code_git', {'action': 'push', 'dir': 'code/x', 'message': 'm'}), isNotNull);
      expect(CodeTools.riskFor('code_git', {'action': 'status'}), isNull);
      expect(CodeTools.riskFor('code_http', {'url': 'https://x', 'method': 'GET'}), isNull);
      expect(CodeTools.riskFor('code_http', {'url': 'https://x', 'method': 'DELETE'}), isNotNull);
      expect(CodeTools.riskFor('code_snapshot', {'action': 'restore', 'dir': 'x'}), isNotNull);
    });

    test('tool group and hints', () {
      expect(ToolScope.groupOf('code_run'), ToolScope.code);
      expect(ToolScope.groupOf('code_media'), isNot(ToolScope.code));
      expect(ToolScope.hinted('fix this python bug'), contains(ToolScope.code));
      expect(ToolScope.hinted('what is the weather'), isNot(contains(ToolScope.code)));
      expect(CodeTools.definitions.length, CodeTools.names.length);
    });

    test('the coder bot is built in', () {
      final c = BotTemplates.all.firstWhere((b) => b.id == 'coder');
      expect(c.name, 'Barnaamije');
      expect(BotTemplates.isCoder(c), isTrue);
      expect(c.heartbeatHours, 0);
      expect(c.instructions, contains('code_run'));
    });
  });
}
