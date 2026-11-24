import 'package:shared_preferences/shared_preferences.dart';

/// The Investigation engine's phone/cloud split and fallback chain (docs/investigation.md §23).
///
/// Phone = vault and sensor: light tools, the case DB, permanent storage. The cloud = muscle: heavy scans and long
/// batch jobs. Smart routing: small work stays on the phone; heavy/long work takes the first available cloud lane,
/// falling back along the chain and, at the end, to phone-only with a plain note of what could not run.
class CaseEngine {
  CaseEngine._();

  static const phone = 'phone';
  static const actions = 'actions'; // GitHub Actions, via the existing code_build tool (always available).
  static const codespaces = 'codespaces';
  static const box = 'box'; // the user's own cloud box.
  static const phoneOnly = 'phoneOnly';

  static const _codespacesKey = 'case_codespaces_url';
  static const _boxKey = 'case_cloud_box_url';

  /// A Codespaces endpoint, if the user configured one.
  static String codespacesUrl = '';

  /// The user's own cloud box, if configured.
  static String boxUrl = '';

  static Future<void> init() async {
    try {
      final p = await SharedPreferences.getInstance();
      codespacesUrl = p.getString(_codespacesKey) ?? '';
      boxUrl = p.getString(_boxKey) ?? '';
    } catch (_) {}
  }

  /// Heavy work's fallback chain, in order: Codespaces → GitHub Actions → the user's box. (Phone-only is the floor
  /// when the chain cannot run.) GitHub Actions is always there because `code_build` already builds on it.
  static List<String> get chain => [
        if (codespacesUrl.isNotEmpty) codespaces,
        actions,
        if (boxUrl.isNotEmpty) box,
      ];

  /// Where a job runs: small work on the phone; heavy/long work on the first cloud lane, or phone-only when none.
  static String route({required bool heavy}) => heavy ? (chain.isEmpty ? phoneOnly : chain.first) : phone;

  static String word(String lane) => switch (lane) {
        phone => 'the phone',
        actions => 'GitHub Actions',
        codespaces => 'Codespaces',
        box => 'your cloud box',
        _ => 'the phone only',
      };

  /// A plain line for the case prompt and the Work section.
  static String note() {
    final c = chain;
    final where = c.isEmpty ? 'the phone (no cloud lane is set up)' : c.map(word).join(' → ');
    return 'Heavy work runs on the cloud chain: $where. Small work stays on the phone. If a cloud lane is not set up, '
        'say so plainly and do it on the phone.';
  }
}