import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

/// The on-device Linux toolbox (a proot rootfs). Opt-in; see docs/toolbox.md. The heavy lifting is native
/// (Toolbox.kt): this only exposes it to the agent as tools and to Settings as status/install/run.
class Toolbox {
  Toolbox._();

  static const _ch = MethodChannel('telesia/native');

  /// Alpine minirootfs (aarch64). Pin the sha256 once a build is verified and copy it into [rootfsSha256].
  static const rootfsUrl =
      'https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/aarch64/alpine-minirootfs-3.20.3-aarch64.tar.gz';
  static const rootfsSha256 = '';

  static Future<Map<String, dynamic>> status() async {
    try {
      final r = await _ch.invokeMethod<String>('toolboxStatus');
      return r == null ? const {'installed': false, 'ready': false} : jsonDecode(r) as Map<String, dynamic>;
    } catch (_) {
      return const {'installed': false, 'ready': false};
    }
  }

  static Future<String> install({String url = rootfsUrl, String sha256 = rootfsSha256}) async {
    try {
      return await _ch.invokeMethod<String>('toolboxInstall', {'url': url, 'sha256': sha256}) ?? '';
    } catch (e) {
      return 'error: $e';
    }
  }

  static Future<String> run(String command, {String cwd = '', int timeoutSeconds = 120}) async {
    try {
      return await _ch.invokeMethod<String>('toolboxRun', {
        'command': command,
        'cwd': cwd,
        'timeout': timeoutSeconds,
      }) ?? '';
    } catch (e) {
      return 'error: $e';
    }
  }

  /// Tool declarations the agent registers (same OpenAI function shape as AgentTools.definitions).
  static List<Map<String, dynamic>> definitions() => [
        _fn('toolbox_status', 'Is the Linux toolbox installed and ready? Use before installing packages.', {}, const []),
        _fn(
            'pkg_install',
            'Install Linux packages inside the toolbox, one command. Examples: "apk add github-cli ffmpeg python3", '
                '"apk add nodejs npm && npm i -g wrangler". Turns network on for package downloads.',
            {'command': {'type': 'string'}},
            const ['command']),
        _fn('pkg_run', 'Run a command in the Linux toolbox (the app workspace is at /work). Use git, gh, wrangler...',
            {'command': {'type': 'string'}, 'cwd': {'type': 'string'}, 'timeout_seconds': {'type': 'integer'}},
            const ['command']),
      ];

  static Map<String, dynamic> _fn(String name, String desc, Map<String, dynamic> props, List<String> req) => {
        'type': 'function',
        'function': {
          'name': name,
          'description': desc,
          'parameters': {'type': 'object', 'properties': props, 'required': req},
        },
      };
}