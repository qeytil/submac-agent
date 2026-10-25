import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../services/bots.dart';
import '../services/inbox.dart';
import '../services/offices.dart';
import '../services/system_tools.dart' show Scheduler;
import '../theme.dart';
import 'inbox_screen.dart';
import 'approvals_screen.dart';
import 'bots_screen.dart' show BotAvatar;
import '../widgets/approval_card.dart';
import 'system_screens.dart';
import '../ui/tokens.dart';
import '../ui/i18n.dart';
import '../widgets/surface.dart';

/// Today (PLAN.md 3.3): the single feed. Needs your OK, done while you were away, From SubMac, coming up.
/// No ask box here: the chat is the one place to ask. The menu shows Today only once there is a bot or a routine.
class TodayScreen extends StatelessWidget {
  const TodayScreen({super.key});

  /// True once Today has something to show: a working bot or a scheduled routine.
  static bool get hasFeed => Bots.I.hired.isNotEmpty || Scheduler.I.tasks.isNotEmpty;

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _hm(DateTime d) {
    final now = DateTime.now();
    final hm = '${_two(d.hour)}:${_two(d.minute)}';
    final days = DateTime(now.year, now.month, now.day).difference(DateTime(d.year, d.month, d.day)).inDays;
    return days == 0 ? hm : days == 1 ? tr('Yesterday {time}', {'time': hm}) : '${d.day}/${d.month}';
  }

  static String _next(DateTime d) {
    final now = DateTime.now();
    final hm = '${_two(d.hour)}:${_two(d.minute)}';
    final days = DateTime(d.year, d.month, d.day).difference(DateTime(now.year, now.month, now.day)).inDays;
    return days <= 0 ? hm : days == 1 ? tr('Tomorrow {time}', {'time': hm}) : '${d.day}/${d.month} $hm';
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return AnimatedBuilder(
      animation: Listenable.merge([Bots.I, Offices.I, Inbox.I, Scheduler.I]),
      builder: (context, _) {
        final since = DateTime.now().subtract(const Duration(hours: 24));
        final done = <(Bot, JournalEntry)>[
          for (final b in Bots.I.bots)
            for (final e in b.journal)
              if (e.at.isAfter(since) && const {'work', 'message', 'call', 'learned'}.contains(e.kind) && !e.text.startsWith('Checked in')) (b, e),
        ]..sort((a, b) => b.$2.at.compareTo(a.$2.at));
        final unread = Inbox.I.items.where((i) => i.unread).toList();
        final upcoming = [...Scheduler.I.tasks]..sort((a, b) => a.next.compareTo(b.next));
        Widget seeAll(VoidCallback onTap) => TextButton(
              style: TextButton.styleFrom(foregroundColor: p.muted, padding: EdgeInsets.zero, minimumSize: const Size(0, 30)),
              onPressed: onTap,
              child: Text(tr('See all')),
            );
        return Scaffold(
          appBar: AppBar(title: Text(tr('Today'), style: Brand.serif(size: 28, color: p.text)), actions: const [InboxBell(), SizedBox(width: Space.x2)]),
          body: ListView(padding: const EdgeInsetsDirectional.fromSTEB(Space.x4, Space.x1, Space.x4, Space.x8), children: [
            Row(children: [
              Expanded(child: _head(p, 'Needs your OK')),
              if (Offices.I.approvals.isNotEmpty)
                seeAll(() => Navigator.push(context, MaterialPageRoute(builder: (_) => const ApprovalsScreen()))),
            ]),
            for (final b in Bots.I.hired.where((b) => b.trustOffered)) TrustOfferCard(bot: b),
            ApprovalList(empty: _muted(p, 'Nothing to approve.')),
            const SizedBox(height: Space.x5),
            _head(p, 'Done while you were away'),
            if (done.isEmpty)
              _muted(p, 'Nothing yet.')
            else
              SurfaceGroup(children: [
              for (final d in done.take(8))
                ListTile(
                  leading: BotAvatar(bot: d.$1, size: 34),
                  title: Text(d.$2.text, maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${d.$1.name} · ${_hm(d.$2.at)}', style: TextStyle(color: p.muted)),
                  onTap: () {
                    Navigator.pop(context);
                    context.read<AppState>().openBot(d.$1);
                  },
                ),
              ]),
            if (unread.isNotEmpty) ...[
              const SizedBox(height: Space.x5),
              Row(children: [
                Expanded(child: _head(p, 'Inbox')),
                seeAll(() => Navigator.push(context, MaterialPageRoute(builder: (_) => const InboxScreen()))),
              ]),
              SurfaceGroup(children: [
                for (final it in unread.take(3))
                  ListTile(
                    title: Text(it.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const InboxScreen())),
                  ),
              ]),
            ],
            const SizedBox(height: Space.x5),
            Row(children: [
              Expanded(child: _head(p, 'Coming up')),
              if (upcoming.isNotEmpty)
                seeAll(() => Navigator.push(context, MaterialPageRoute(builder: (_) => const ScheduledScreen()))),
            ]),
            if (upcoming.isEmpty)
              _muted(p, 'Nothing scheduled.')
            else
              SurfaceGroup(children: [
                for (final t in upcoming.take(5))
                  ListTile(
                    title: Text(t.task, maxLines: 2, overflow: TextOverflow.ellipsis),
                    subtitle: Text(_next(t.next), style: TextStyle(color: p.muted)),
                  ),
              ]),
          ]),
        );
      },
    );
  }

  static Widget _head(Palette p, String t) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(tr(t), style: AppText.sectionStyle.copyWith(color: p.muted)),
      );

  static Widget _muted(Palette p, String t) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(tr(t), style: TextStyle(color: p.muted, height: 1.4)),
      );
}
