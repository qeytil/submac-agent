import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import '../app_state.dart';
import '../screens/bots_screen.dart' show BotAvatar, BotsScreen;
import '../screens/offices_screen.dart' show OfficeScreen;
import '../services/bots.dart';
import '../services/offices.dart';
import '../theme.dart';
import '../ui/tokens.dart';
import 'sub_icon.dart';
import 'lux_kit.dart';
import 'team_face.dart';
import '../ui/i18n.dart';

/// Small shared pieces of the Team pages (people, teams, settings rows) and the "Send to" picker for things shared
/// into SubMac.

/// Something was shared into SubMac: send it to a chat, a bot or a team. Returns 'chat', 'bot:<id>' or
/// 'office:<id>' (null = cancelled).
Future<String?> pickShareTarget(BuildContext context) {
  return showLuxSheet<String>(
    context,
    title: 'Send to',
    builder: (ctx) => ListView(shrinkWrap: true, padding: const EdgeInsets.only(bottom: Space.x3), children: [
      LuxRow(title: tr('New chat'), onTap: () => Navigator.pop(ctx, 'chat')),
      for (final o in Offices.I.offices)
        LuxRow(
          leading: TeamFace(office: o, size: 36),
          title: o.name,
          sub: tr('Team · {n}', {'n': '${o.members.length} ${o.members.length == 1 ? tr('bot') : tr('bots')}'}),
          onTap: () => Navigator.pop(ctx, 'office:${o.id}'),
        ),
      for (final b in Bots.I.hired)
        LuxRow(
          leading: BotAvatar(bot: b, size: 36),
          title: b.name,
          sub: b.role,
          onTap: () => Navigator.pop(ctx, 'bot:${b.id}'),
        ),
    ]),
  );
}

/// A section label on the Team pages (the shared [LuxSection] look, with the page's own margins).
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => LuxSection(text, padding: const EdgeInsetsDirectional.fromSTEB(Space.x1, Space.x4, Space.x1, Space.x2));
}

/// A way in on the Team pages ("Start a team", a team, a ready-made team): words on the paper, the unread count as a
/// quiet number. No card, no icon disc, no badge pill (fix/ui-restyle).
class TeamCard extends StatelessWidget {
  const TeamCard({super.key, required this.title, this.sub, required this.onTap, this.badge = 0, this.leading});
  final String title;
  final String? sub;
  final VoidCallback onTap;
  final int badge;

  /// A team's or a bot's face, when the row is about one.
  final Widget? leading;

  @override
  Widget build(BuildContext context) => LuxRow(
        title: tr(title),
        sub: sub,
        leading: leading,
        value: badge > 0 ? '$badge' : null,
        selected: badge > 0,
        maxLines: 2,
        padding: const EdgeInsetsDirectional.symmetric(horizontal: Space.x1, vertical: Space.x3),
        onTap: onTap,
      );
}

class ChoiceRow extends StatelessWidget {
  const ChoiceRow({super.key, required this.label, required this.value, required this.options, required this.onChanged}) : onTap = null;
  const ChoiceRow.text(this.label, this.value, VoidCallback this.onTap, {super.key})
      : options = const {},
        onChanged = _none;
  final String label;
  final String value;
  final Map<String, String> options;
  final ValueChanged<String> onChanged;
  final VoidCallback? onTap;

  static void _none(String _) {}

  @override
  Widget build(BuildContext context) {
    return LuxRow(
      title: tr(label),
      sub: options[value] ?? value,
      padding: const EdgeInsetsDirectional.symmetric(horizontal: Space.x1, vertical: Space.x3),
      onTap: onTap ??
          () async {
            final v = await showLuxChoices<String>(context,
                title: label, selected: value, choices: [for (final e in options.entries) LuxChoice(e.key, e.value)]);
            if (v != null) onChanged(v);
          },
    );
  }
}

class RemovableLine extends StatelessWidget {
  const RemovableLine({super.key, required this.text, required this.onRemove});
  final String text;
  final VoidCallback onRemove;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.x1),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: Text(text, style: AppText.metaStyle.copyWith(color: p.text))),
        LuxTap(
          label: tr('Remove'),
          onTap: onRemove,
          child: Padding(padding: const EdgeInsets.all(Space.x2), child: SubIcon('close', size: IconSize.sm, color: p.muted)),
        ),
      ]),
    );
  }
}

/// "Setting up your team": one plain line with the breathing status word, straight on the dimmed page.
class BusyNote extends StatelessWidget {
  const BusyNote(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Center(
      child: Material(
        type: MaterialType.transparency,
        child: Breath(child: Text(tr(text), style: AppText.leadStyle.copyWith(color: p.text, fontWeight: FontWeight.w500))),
      ),
    );
  }
}

Future<String?> askText(BuildContext context, {required String title, String hint = '', String initial = '', String action = 'Save', String help = ''}) =>
    luxPrompt(context, title: title, hint: hint.isEmpty ? null : hint, initial: initial, action: action, message: help.isEmpty ? null : help, maxLines: 6);

/// Your teams at a glance on the home screen: who is working, what got done, what needs you.
class TeamPanel extends StatelessWidget {
  const TeamPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return AnimatedBuilder(
      animation: Offices.I,
      builder: (context, _) {
        final teams = Offices.I.offices;
        if (teams.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: Space.x6),
          child: Column(children: [
            for (final o in teams.take(4))
              Builder(builder: (context) {
                final st = OfficeStats(o);
                final working = state.officeWorking(o.id);
                final parts = [
                  working.isNotEmpty ? working.first : (o.paused ? 'Paused' : (o.onHold ? 'Resting' : (o.workingNow() ? 'Ready' : 'Quiet'))),
                  if (st.doneToday > 0) '${st.doneToday} done today',
                  if (st.blocked > 0) '${st.blocked} blocked',
                  if (st.proposed > 0) '${st.proposed} to approve',
                ];
                return LuxRow(
                  dense: true,
                  leading: TeamFace(office: o, size: 28),
                  title: o.name,
                  sub: parts.join(' · '),
                  value: o.unread > 0 ? '${o.unread}' : null,
                  selected: o.unread > 0,
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => OfficeScreen(officeId: o.id))),
                );
              }),
          ]),
        );
      },
    );
  }
}

/// One quiet line on a new chat: who is working, what needs you, what got done.
/// A single team opens straight into it; several open the Team screen. The full
/// panel (TeamPanel) still lives on the Team pages.

class TeamLine extends StatelessWidget {
  const TeamLine({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final p = Palette.of(context);
    return AnimatedBuilder(
      animation: Offices.I,
      builder: (context, _) {
        final teams = Offices.I.offices;
        if (teams.isEmpty) return const SizedBox.shrink();

        var working = 0;
        var done = 0;
        var needs = 0;
        for (final office in teams) {
          working += state.officeWorking(office.id).length;
          final stats = OfficeStats(office);
          done += stats.doneToday;
          needs += stats.proposed + stats.review + stats.blocked;
        }

        final verb = needs == 1 ? 'needs' : 'need';
        final parts = <String>[
          if (working > 0) '$working working',
          if (needs > 0) '$needs $verb you',
          if (done > 0) '$done done today',
        ];
        final summary = parts.isEmpty ? 'Nothing needs you' : parts.join(' · ');

        return Padding(
          padding: const EdgeInsets.only(top: Space.x6),
          child: Semantics(
            button: true,
            child: LuxTap(
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => teams.length == 1
                        ? OfficeScreen(officeId: teams.first.id)
                        : const BotsScreen(),
                  ),
                );
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Flexible(
                      child: Text(
                        summary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: p.muted, fontSize: AppText.meta),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
