import 'dart:io';

import 'package:flutter/services.dart';

/// Ships the hybrid (2D characters in a 3D world) animation skill into the workspace.
///
/// opencode loads skills from its own folder and from `<workspace>/skills` (OpenCode.kt lists both). The hybrid skill
/// is a folder (SKILL.md + template + scripts), unlike the single-file skills written natively, so it ships as assets
/// and is copied here once per version. It lives in the workspace so the agent's bash tool can read it without an
/// external-directory prompt.
class HybridSkill {
  HybridSkill._();

  /// Bump when the bundled files change, so a stale copy is replaced.
  static const _v = 1;
  static const _root = 'skills/hybrid/';
  static bool _done = false;

  static Future<void> install(String workspace) async {
    if (_done) return;
    _done = true;
    try {
      final dir = Directory('$workspace/skills/hybrid');
      final stamp = File('$workspace/skills/hybrid/.installed');
      if (await stamp.exists() && (await stamp.readAsString()).trim() == '$_v') return;
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      final files = manifest.listAssets().where((p) => p.startsWith(_root)).toList();
      if (files.isEmpty) return;
      await dir.create(recursive: true);
      for (final p in files) {
        final data = await rootBundle.load(p);
        final out = File('$workspace/$p');
        await out.parent.create(recursive: true);
        await out.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
      }
      await stamp.writeAsString('$_v');
    } catch (_) {
      // Best effort: a missing skill never blocks the engine.
    }
  }
}