import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// opencode's built-in tools on the phone (owner, 2026-11-03: "make every opencode tool work").
/// Production tool results showed glob/grep/skill failing with "ripgrep execution failed" and bash with
/// "curl: inaccessible or not found" / "opencode: inaccessible or not found": Android has no rg or curl, and opencode is a
/// musl program that only starts through the bundled loader. The APK now ships static rg and curl plus a static
/// `opencode` launcher, and OpenCode.kt links them into filesDir/oc/bin, first on PATH. Source checks, like the other
/// build tests: the binaries themselves only run on a device.
void main() {
  final yml = File('.github/workflows/apk.yml').readAsStringSync();
  final kt = File('android_native/OpenCode.kt').readAsStringSync();

  group('APK workflow bundles the programs the tools call', () {
    test('static aarch64 rg and curl, pinned by sha256, shipped as jniLibs', () {
      expect(yml, contains('ripgrep-v15.0.1-aarch64-unknown-linux-musl.tar.gz'));
      expect(yml, contains('curl-linux-aarch64-musl-8.23.0-1.tar.xz'));
      expect(yml, contains('RG_SHA=dd3738a4b6e8df0fb3bc3edc5af352c4c39e0d97ad118a23e5176bdc5d48ba08'));
      expect(yml, contains('CURL_SHA=e20f26e5b87c1883608f286f86bdabf39d3b8556e8a8e75dfe205e14bd206199'));
      expect(RegExp(r'sha256sum -c').allMatches(yml).length, greaterThanOrEqualTo(2));
      for (final so in ['libocrg.so', 'liboccurl.so', 'libocexec.so']) {
        expect(yml, contains('"\$J/$so"'), reason: '$so copied into jniLibs/arm64-v8a');
        expect(yml, contains('"**/$so"'), reason: '$so never stripped (keepDebugSymbols)');
      }
      expect(yml, contains("grep -q 'ARM aarch64.*static'"), reason: 'refuses a dynamic or wrong-arch binary');
      expect(yml, contains('-gt 1000000'), reason: 'size check');
    });

    test('the opencode launcher is built static from tracked source', () {
      expect(yml, contains('aarch64-linux-gnu-gcc -static'));
      expect(yml, contains('android_native/ocexec.c'));
      final c = File('android_native/ocexec.c').readAsStringSync();
      expect(c, contains('/proc/self/exe'));
      expect(c, contains('libocld.so'));
      expect(c, contains('libopencode.so'));
      expect(c, contains('TELESIA_OC_LIB'));
      expect(c, contains('--library-path'));
      expect(c, contains('execv('));
    });
  });

  group('OpenCode.kt links them and puts them on PATH', () {
    test('bin dir of symlinks into nativeLibraryDir named rg, curl, opencode', () {
      expect(kt, contains('File(root, "bin")'));
      expect(kt, contains('"rg" to "libocrg.so"'));
      expect(kt, contains('"curl" to "liboccurl.so"'));
      expect(kt, contains('"opencode" to "libocexec.so"'));
      expect(kt, contains('link(target, File(binDir, name))'));
      expect(kt, contains('android.system.Os.symlink'), reason: 'symlinks, not copies: app data is not executable');
    });

    test('PATH starts with the bin dir and keeps the system dirs; launcher gets the lib dir', () {
      expect(kt, contains('env["PATH"] = binDir.path + ":" + sysPath'));
      expect(kt, contains('/system/bin'));
      expect(kt, contains('env["TELESIA_OC_LIB"] = links.path'));
      // The links are made before the process starts.
      expect(kt.indexOf('link(target, File(binDir, name))'), lessThan(kt.indexOf('pb.start()')));
      expect(kt.indexOf('env["PATH"] = binDir.path'), lessThan(kt.indexOf('pb.start()')));
    });

    test('home, XDG dirs and the shell stay under app files', () {
      for (final k in ['HOME', 'XDG_DATA_HOME', 'XDG_CONFIG_HOME', 'XDG_CACHE_HOME', 'XDG_STATE_HOME', 'TMPDIR']) {
        expect(kt, contains('env["$k"]'), reason: k);
      }
      expect(kt, contains('env["SHELL"] = "/system/bin/sh"'));
    });
  });
}
