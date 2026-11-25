import io


def sub(path, old, new):
    s = io.open(path, encoding='utf-8').read()
    n = s.count(old)
    assert n == 1, "expected 1 match in %s, got %d for %r" % (path, n, old[:70])
    io.open(path, 'w', encoding='utf-8').write(s.replace(old, new))


# 1) The engine itself: latest opencode (was 1.19.5). Its notes are core fixes only (oversized image sessions, a
#    too-large body now compacts and retries) - no API change for us.
sub('.github/workflows/apk.yml',
    "          OC=1.19.5; ALP=v3.22",
    "          OC=1.19.6; ALP=v3.22")

# 2) Performance: newer engines emit parts that carry no words or steps (snapshots, patches, step markers). Ignore
#    them with one compare so a busier event stream never costs the chat.
sub('lib/services/opencode.dart',
    "        final child = p['sessionID'] == session ? null : '${p['sessionID']}';",
    "        final child = p['sessionID'] == session ? null : '${p['sessionID']}';\n"
    "        // Parts that carry no words or steps (snapshots, patches, step markers opencode added): one compare and\n"
    "        // out, so a busier event stream never costs the chat.\n"
    "        if (type == 'snapshot' || type == 'patch' || type == 'step-start' || type == 'step-finish') return false;")

# 3) The engine and what the newest one is.
SERVICE = '''import 'dart:convert';

import 'package:http/http.dart' as http;

/// The opencode engine Telesia runs, and what the newest one is. The engine is a native binary that ships inside the
/// Telesia APK (Android runs no code from a writable folder), so a new engine arrives with a Telesia update. Keep
/// [version] in step with the `OC=` pin in .github/workflows/apk.yml.
class OcEngine {
  OcEngine._();

  /// The engine bundled in this build (the `OC=` pin in the APK workflow).
  static const version = '1.19.6';

  static const _latestUrl = 'https://api.github.com/repos/anomalyco/opencode/releases/latest';

  /// The newest published engine tag without its leading `v` (e.g. "1.19.6"), or null when it cannot be checked.
  static Future<String?> latest() async {
    try {
      final r = await http
          .get(Uri.parse(_latestUrl), headers: const {'Accept': 'application/vnd.github+json', 'User-Agent': 'telesia'})
          .timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) return null;
      final j = jsonDecode(r.body);
      if (j is! Map) return null;
      final t = '${j['tag_name'] ?? ''}'.trim();
      if (t.isEmpty) return null;
      return t.startsWith('v') ? t.substring(1) : t;
    } catch (_) {
      return null;
    }
  }

  /// True when dotted version [a] is newer than [b].
  static bool newer(String a, String b) {
    final x = a.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final y = b.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final n = x.length > y.length ? x.length : y.length;
    for (var i = 0; i < n; i++) {
      final xi = i < x.length ? x[i] : 0;
      final yi = i < y.length ? y[i] : 0;
      if (xi != yi) return xi > yi;
    }
    return false;
  }
}
'''
with io.open('lib/services/oc_engine.dart', 'w', encoding='utf-8') as f:
    f.write(SERVICE)

# 4) Settings > Engine.
sub('lib/screens/settings_screen.dart',
    "import '../services/notif_text.dart';",
    "import '../services/notif_text.dart';\nimport '../services/oc_engine.dart';")

sub('lib/screens/settings_screen.dart',
    "          _Group([\n            row('Advanced', const _AdvancedPage()),\n            row('Help', const _HelpPage()),\n          ]),",
    "          _Group([\n            row('Engine', const _EnginePage()),\n            row('Advanced', const _AdvancedPage()),\n            row('Help', const _HelpPage()),\n          ]),")

PAGE = '''/// The opencode engine: which version Telesia runs, and how it is updated. The engine is a native binary that only
/// runs from inside the Telesia APK (Android runs no code from app data), so a newer engine arrives with a Telesia
/// update; this page checks what is out and points the owner at that update.
class _EnginePage extends StatefulWidget {
  const _EnginePage();
  @override
  State<_EnginePage> createState() => _EnginePageState();
}

class _EnginePageState extends State<_EnginePage> {
  String? _latest;
  bool _checking = false;
  bool _failed = false;

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _failed = false;
    });
    final v = await OcEngine.latest();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _failed = v == null;
      if (v != null) _latest = v;
    });
  }

  @override
  Widget build(BuildContext context) {
    final muted = Palette.of(context).muted;
    final newer = _latest != null && OcEngine.newer(_latest!, OcEngine.version);
    final sub = _checking
        ? 'Checking...'
        : _failed
            ? 'Could not check. Try again.'
            : _latest == null
                ? 'See if a newer engine is out'
                : newer
                    ? 'opencode $_latest is out'
                    : 'You have the newest engine';
    return _Page('Engine', [
      _Group([
        ListTile(
          title: const Text('opencode engine'),
          subtitle: Text('Version ${OcEngine.version} (built into Telesia)'),
        ),
        ListTile(
          title: const Text('Check for updates'),
          subtitle: Text(sub),
          trailing: _checking
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : Icon(Icons.refresh_rounded, color: muted),
          onTap: _checking ? null : _check,
        ),
      ]),
      if (newer)
        _Group([
          ListTile(
            title: const Text('Update Telesia'),
            subtitle: const Text('The engine ships inside Telesia, so the newest app carries the newest engine.'),
            trailing: Icon(Icons.system_update_alt_rounded, color: muted),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AppUpdateScreen())),
          ),
          ListTile(
            title: const Text('What is new in opencode'),
            subtitle: Text('opencode $_latest release notes'),
            trailing: Icon(Icons.open_in_new_rounded, color: muted),
            onTap: () => launchUrl(Uri.parse('https://github.com/anomalyco/opencode/releases/tag/v$_latest'), mode: LaunchMode.externalApplication),
          ),
        ]),
    ]);
  }
}

'''

sub('lib/screens/settings_screen.dart',
    "// ------------------------------------------------------------------ Advanced",
    PAGE + "// ------------------------------------------------------------------ Advanced")

print('engine: bumped opencode to 1.19.6, perf skip for new part types, Settings > Engine update page')
