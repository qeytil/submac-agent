import 'package:flutter/material.dart';

import '../services/bots.dart';
import '../services/offices.dart';
import '../widgets/motion.dart';
import '../theme.dart';
import '../widgets/approval_card.dart';
import '../ui/tokens.dart';
import '../ui/i18n.dart';
import '../widgets/surface.dart';

/// Needs your OK: every ask from every bot and team, similar asks as one card (plan 5.2), and what was answered before.
class ApprovalsScreen extends StatelessWidget {
  const ApprovalsScreen({super.key});

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'now';
    if (d.inMinutes < 60) return '${d.inMinutes}m';
    if (d.inHours < 24) return '${d.inHours}h';
    return '${d.inDays}d';
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return AnimatedBuilder(
      animation: Listenable.merge([Offices.I, Bots.I]),
      builder: (context, _) {
        final past = Offices.I.approvals.where((a) => a.status != 'pending').toList().reversed.take(30).toList();
        final offers = Bots.I.hired.where((b) => b.trustOffered).toList();
        return Scaffold(
          appBar: AppBar(title: Text(tr('Needs your OK'))),
          body: ListView(padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 16, 40), children: [
            for (final b in offers) TrustOfferCard(bot: b),
            ApprovalList(
              empty: offers.isNotEmpty
                  ? null
                  : EmptyHint(text: tr('Nothing to approve.')),
            ),
            if (past.isNotEmpty) ...[
              const SizedBox(height: 20),
              Text(tr('Earlier'), style: AppText.sectionStyle.copyWith(color: p.muted)),
              SurfaceGroup(children: [
              for (final a in past)
                ListTile(
                  dense: true,
                  title: Text(a.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                      '${Bots.I.byId(a.botId)?.name ?? 'Telesia'} · ${switch (a.status) {
                        'approved' => a.edited.isNotEmpty ? tr('Approved with your edit') : tr('Approved'),
                        'denied' => a.wantsChange ? tr('You asked for a change') : tr('Not now'),
                        _ => tr('No answer')
                      }} · ${_ago(a.at)}',
                      style: TextStyle(color: p.muted)),
                ),
              ]),
            ],
          ]),
        );
      },
    );
  }
}
