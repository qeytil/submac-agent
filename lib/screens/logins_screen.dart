import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../services/browser_agent.dart';
import '../widgets/motion.dart';
import '../theme.dart';
import '../ui/tokens.dart';
import '../widgets/surface.dart';
import '../ui/i18n.dart';

/// Sites Telesia can sign in to for the user. Logins stay encrypted on this phone.
class LoginsScreen extends StatelessWidget {
  const LoginsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final p = Palette.of(context);
    final sites = state.savedLoginSites;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Saved logins'))),
      body: ListView(children: [
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 16, 12),
          child: Text(
            'Saved on this phone only.',
            style: TextStyle(color: p.muted, fontSize: AppText.meta),
          ),
        ),
        if (sites.isEmpty)
          const EmptyHint(text: 'No saved logins yet.'),
        if (sites.isNotEmpty)
          SurfaceGroup(margin: const EdgeInsets.symmetric(horizontal: Space.x4, vertical: Space.x1), children: [
            for (final s in sites)
              ListTile(
                title: Text(s),
                trailing: TextButton(
                  onPressed: () => state.forgetLogin(s),
                  child: Text('Remove', style: TextStyle(color: p.accent)),
                ),
              ),
          ]),
        const SizedBox(height: Space.x3),
        SurfaceGroup(margin: const EdgeInsets.symmetric(horizontal: Space.x4, vertical: Space.x1), children: [
        ListTile(
          title: const Text('Sign out of all sites'),
          subtitle: const Text('Clears the browser\'s cookies and closes it'),
          onTap: () async {
            await CookieManager.instance().deleteAllCookies();
            await BrowserAgent.I.close();
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Signed out of all sites')));
            }
          },
        ),
        ]),
      ]),
    );
  }
}
