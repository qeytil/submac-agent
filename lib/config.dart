class AppConfig {
  static const appName = 'Telesia';
  /// Shown in Settings; keep in step with pubspec.yaml.
  static const version = '1.13.79';
  static const supportEmail = 'contact@telesia.site';
  static const privacyUrl = 'https://telesia.site/telesiaagent/privacypolicy';
  static const termsUrl = 'https://telesia.site/telesiaagent/termsofuse';
  /// Region the cloud proxy (edge functions) runs in, sent as `x-region` on every call. Pinned to the database's
  /// region (Frankfurt): unpinned, Supabase runs the function near the caller and every database check crosses
  /// the world (measured ~1.3 s of setup before the model vs ~0.3 s pinned).
  static const edgeRegion = 'eu-central-1';
  static const supabaseUrl = 'https://moeemacbvsueekuvfjbo.supabase.co';
  // Public anon key (safe to ship; access is protected by Row Level Security).
  static const supabaseAnonKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im1vZWVtYWNidnN1ZWVrdXZmamJvIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTE5MDYxMDAsImV4cCI6MjEwNzQ4MjEwMH0.efFTgN4H5E1MRzyuf3g4cXiXAns3YnQVudfL_x3kT4s';
}
