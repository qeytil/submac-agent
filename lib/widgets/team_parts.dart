import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import '../app_state.dart';
import '../screens/bots_screen.dart' show BotAvatar, BotsScreen, botIcon;
import '../screens/offices_screen.dart' show OfficeScreen;
import '../services/bots.dart';
import '../services/offices.dart';
import '../theme.dart';
import '../ui/tokens.dart';
import 'sub_icon.dart';
import '../ui/i18n.dart';

/// Small shared pieces of the Team pages (people, teams, settings rows) and the "Send to" picker for things shared
/// into Telesia.

/// Something was shared into Telesia: send it to a chat, a bot or a team. Returns 'chat', 'bot:<id>' or
/// 'office:<id>' (null = cancelled).
Future<String?> pickShareTarget(BuildContext context) {
  return showModalBottomSheet<String>(
    sheetAnimationStyle: SubMotion.sheet,
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) {
      final p = Palette.of(ctx);
      return SafeArea(
        child: ListView(shrinkWrap: true, padding: const EdgeInsets.only(bottom: 12), children: [
          Padding(padding: const EdgeInsetsDirectional.fromSTEB(20, 0, 20, 8), child: Text('Send to', style: Theme.of(ctx).textTheme.titleLarge)),
          ListTile(
            leading: CircleAvatar(backgroundColor: p.sheet, child: Icon(Icons.chat_bubble_outline_rounded, color: p.text, size: 20)),
            title: Text(tr('New chat')),
            onTap: () => Navigator.pop(ctx, 'chat'),
          ),
          for (final o in Offices.I.offices)
            ListTile(
              leading: CircleAvatar(backgroundColor: p.sheet, child: Icon(botIcon(o.icon), color: p.text, size: 20)),
              title: Text(o.name),
              subtitle: Text('Team · ${o.members.length} ${o.members.length == 1 ? 'bot' : 'bots'}', style: TextStyle(color: p.muted)),
              onTap: () => Navigator.pop(ctx, 'office:${o.id}'),
            ),
          for (final b in Bots.I.hired)
            ListTile(
              leading: BotAvatar(bot: b, size: 40),
              title: Text(b.name),
              subtitle: Text(b.role, style: TextStyle(color: p.muted)),
              onTap: () => Navigator.pop(ctx, 'bot:${b.id}'),
            ),
        ]),
      );
    },
  );
}

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(4, 0, 4, 8),
        child: Text(text, style: AppText.sectionStyle.copyWith(color: Palette.of(context).muted)),
      );
}

class TeamCard extends StatelessWidget {
  const TeamCard({super.key, required this.icon, required this.title, this.sub, required this.onTap, this.badge = 0});
  final IconData icon;
  final String title;
  final String? sub;
  final VoidCallback onTap;
  final int badge;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: p.sheet,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () {
            onTap();
          },
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(shape: BoxShape.circle, color: p.bg),
                child: Icon(icon, size: 22, color: p.text),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: TextStyle(color: p.text, fontSize: AppText.body, fontWeight: FontWeight.w600)),
                  if (sub != null) ...[
                    const SizedBox(height: 3),
                    Text(sub!, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.muted, fontSize: AppText.meta, height: 1.3)),
                  ],
                ]),
              ),
              if (badge > 0)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: p.text, borderRadius: BorderRadius.circular(10)),
                  child: Text('$badge', style: TextStyle(color: p.bg, fontSize: AppText.micro, fontWeight: FontWeight.w600)),
                )
              else
                Icon(Icons.chevron_right_rounded, color: p.muted),
            ]),
          ),
        ),
      ),
    );
  }
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
    final p = Palette.of(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      subtitle: Text(options[value] ?? value, style: TextStyle(color: p.muted)),
      trailing: Icon(Icons.chevron_right_rounded, color: p.muted),
      onTap: onTap ??
          () async {
            final v = await showModalBottomSheet<String>(
              sheetAnimationStyle: SubMotion.sheet,
              context: context,
              showDragHandle: true,
              builder: (ctx) => SafeArea(
                child: ListView(shrinkWrap: true, children: [
                  for (final e in options.entries)
                    ListTile(
                      title: Text(e.value),
                      trailing: e.key == value ? Icon(Icons.check_rounded, color: p.text) : null,
                      onTap: () => Navigator.pop(ctx, e.key),
                    ),
                ]),
              ),
            );
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
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: Text(text, style: TextStyle(color: p.text, fontSize: AppText.meta, height: 1.35))),
        InkWell(
          customBorder: const CircleBorder(),
          onTap: onRemove,
          child: Padding(padding: const EdgeInsets.all(4), child: Icon(Icons.close_rounded, size: 16, color: p.muted)),
        ),
      ]),
    );
  }
}

class BusyNote extends StatelessWidget {
  const BusyNote(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        decoration: BoxDecoration(color: p.sheet, borderRadius: BorderRadius.circular(18)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: p.text)),
          const SizedBox(width: 14),
          Text(text, style: TextStyle(color: p.text, fontSize: AppText.body, decoration: TextDecoration.none, fontWeight: FontWeight.w400)),
        ]),
      ),
    );
  }
}

Future<String?> askText(BuildContext context, {required String title, String hint = '', String initial = '', String action = 'Save', String help = ''}) {
  final ctrl = TextEditingController(text: initial);
  return showModalBottomSheet<String>(
    sheetAnimationStyle: SubMotion.sheet,
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => Padding(
      padding: EdgeInsetsDirectional.fromSTEB(20, 0, 20, MediaQuery.of(ctx).viewInsets.bottom + 20),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: Theme.of(ctx).textTheme.titleLarge),
        if (help.isNotEmpty) ...[const SizedBox(height: 6), Text(help, style: TextStyle(color: Palette.of(ctx).muted))],
        const SizedBox(height: 14),
        TextField(
          controller: ctrl,
          autofocus: true,
          minLines: 2,
          maxLines: 6,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(hintText: hint),
        ),
        const SizedBox(height: 14),
        SizedBox(width: double.infinity, child: FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: Text(action))),
      ]),
    ),
  );
}

/// Your teams at a glance on the home screen: who is working, what got done, what needs you.
class TeamPanel extends StatelessWidget {
  const TeamPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final p = Palette.of(context);
    return AnimatedBuilder(
      animation: Offices.I,
      builder: (context, _) {
        final teams = Offices.I.offices;
        if (teams.isEmpty) return const SizedBox.shrink();
        return Container(
          margin: const EdgeInsets.only(top: 26),
          decoration: BoxDecoration(color: p.sheet, borderRadius: Radii.rowAll),
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
                return ListTile(
                  dense: true,
                  leading: Icon(working.isNotEmpty ? Icons.motion_photos_on_outlined : Icons.groups_2_outlined, size: 20, color: p.text),
                  title: Text(o.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(parts.join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: p.muted)),
                  trailing: o.unread > 0 ? Badge(label: Text('${o.unread}')) : Icon(Icons.chevron_right_rounded, color: p.muted),
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
            child: InkWell(
              borderRadius: BorderRadius.circular(Radii.pill),
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
                    const SizedBox(width: 4),
                    SubIcon('chevron_right', size: IconSize.sm, color: p.muted),
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
