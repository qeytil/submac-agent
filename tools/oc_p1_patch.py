import sys, pathlib

def patch(path, old, new):
    p = pathlib.Path(path); s = p.read_text(); n = s.count(old)
    if n != 1:
        print("::error file=%s::pattern found %d times" % (path, n)); sys.exit(1)
    p.write_text(s.replace(old, new)); print("patched", path)

patch("lib/services/oc_lanes.dart",
"  static const models = ['submac', 'submac-smart', 'submac-fast', 'submac-think', 'submac-lite', 'submac-vision', 'submac-somali'];",
"  // BYOK only: no SubMac chat-model aliases are offered any more.\n  static const models = <String>[];")

patch("lib/services/oc_lanes.dart",
"""  static List<Map<String, String>> providers() => [
        {'id': fg, 'name': 'SubMac', 'path': '', 'source': 'opencode'},
        for (final e in bgSources.entries) {'id': e.key, 'name': 'SubMac (${e.value})', 'path': '$lanePath${e.value}', 'source': e.value},
      ];""",
"""  /// BYOK only: no SubMac providers are injected; opencode runs the owner's own providers.
  static List<Map<String, String>> providers() => const [];""")

patch("test/oc_lanes_test.dart",
"""    test('each provider has its own proxy path: only background providers use the lane path', () {
      final ps = {for (final p in OcLane.providers()) p['id']: p};
      expect(ps.keys.toSet(), {'submac', 'submac-bg', 'submac-office'});
      expect(ps['submac']!['path'], '');
      expect(ps['submac-bg']!['path'], '/lane/bot');
      expect(ps['submac-office']!['path'], '/lane/office');
      for (final p in ps.values) {
        expect(RegExp(r'^[a-z0-9-]{1,32}$').hasMatch(p['id']!), isTrue, reason: 'OpenCode.kt keeps ids of this shape');
        if (p['path']!.isNotEmpty) expect(RegExp(r'^/lane/[a-z-]{1,20}$').hasMatch(p['path']!), isTrue);
      }
    });""",
"""    test('BYOK only: opencode is given the owner\\'s providers, never SubMac', () {
      expect(OcLane.providers(), isEmpty, reason: 'SubMac Cloud is removed');
      expect(OcLane.models, isEmpty, reason: 'no SubMac chat-model aliases');
    });""")
