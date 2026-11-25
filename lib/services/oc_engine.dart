import 'dart:convert';

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
