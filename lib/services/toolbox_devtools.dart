import 'toolbox.dart';

/// The preinstalled developer set for the Linux toolbox (owner, 2026-11-19: "include python, node, android/flutter
/// tools, so opencode has the full set"): git/gh, node/npm, python/pip, compilers, JDK, cmake/ninja, go, rust,
/// ffmpeg, imagemagick. Alpine ships no arm64 Android SDK and no official Flutter build, so those are downloaded
/// by the agent on request; everything here is what a Linux build box needs. Two calls stay under the 10 min cap.
const _base = 'git gh curl wget bash jq ripgrep unzip tar less nano openssh-client ca-certificates';
const _dev = 'nodejs npm python3 py3-pip py3-virtualenv ffmpeg imagemagick build-base cmake ninja pkgconf '
    'openjdk17-jdk go rust cargo clang lld gdb sqlite zip';

/// Installs the set into an existing rootfs. Safe to re-run: apk skips what is already there.
Future<String> toolboxInstallDevTools() async {
  final up = await Toolbox.run('apk update', timeoutSeconds: 600);
  if (up.contains('error:')) return up;
  final a = await Toolbox.run('apk add --no-cache $_base', timeoutSeconds: 600);
  if (a.contains('error:')) return a;
  final b = await Toolbox.run('apk add --no-cache $_dev', timeoutSeconds: 600);
  final tail = b.length > 400 ? b.substring(b.length - 400) : b;
  return 'tools: ${b.contains('error:') ? 'failed' : 'installed'}\n$tail';
}
