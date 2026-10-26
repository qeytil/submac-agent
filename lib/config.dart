class AppConfig {
  static const appName = 'SubMac Agent';
  /// The version of the running build ("1.13.104"), as Android reports it (PackageManager versionName, set from
  /// pubspec.yaml at build time). Sent by touch_device, shown in Settings. Filled at start by
  /// `Updater.loadBuildVersion()`; until then (and off Android, e.g. tests) it is [pubspecVersion].
  static String get version => _buildVersion.isNotEmpty ? _buildVersion : pubspecVersion;
  static String _buildVersion = '';
  static set buildVersion(String v) => _buildVersion = v.trim().split('+').first;

  /// Fallback only. test/app_config_version_test.dart fails when it drifts from pubspec.yaml.
  static const pubspecVersion = '1.13.104';
  static const supportEmail = 'contact@submac.site';
  static const privacyUrl = 'https://submac.site/submacagent/privacypolicy';
  static const termsUrl = 'https://submac.site/submacagent/termsofuse';
  /// Region the cloud proxy (edge functions) runs in, sent as `x-region` on every call. Pinned to the database's
  /// region (Frankfurt): unpinned, Supabase runs the function near the caller and every database check crosses
  /// the world (measured ~1.3 s of setup before the model vs ~0.3 s pinned).
  static const edgeRegion = 'eu-central-1';
  static const supabaseUrl = 'https://moeemacbvsueekuvfjbo.supabase.co';
  // Public anon key (safe to ship; access is protected by Row Level Security).
  static const supabaseAnonKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im1vZWVtYWNidnN1ZWVrdXZmamJvIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTE5MDYxMDAsImV4cCI6MjEwNzQ4MjEwMH0.efFTgN4H5E1MRzyuf3g4cXiXAns3YnQVudfL_x3kT4s';
}
