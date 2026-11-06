import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../services/bot_powers.dart';
import '../services/bot_sync.dart';
import '../services/byok.dart';
import '../services/bot_store.dart';
import '../services/bots.dart';
import '../services/offices.dart';
import '../services/system_bridge.dart';
import '../services/system_tools.dart';
import '../services/trust.dart';
import '../theme.dart';
import '../widgets/avatar_picker.dart';
import '../widgets/approval_card.dart';
import '../widgets/model_picker.dart';
import '../widgets/surface.dart';
import 'bot_activity_screen.dart';
import 'bot_setup_screens.dart';
import 'bot_store_screen.dart';
import 'hire_screen.dart';
import '../ui/i18n.dart';
import 'bots_screen.dart' show BotAvatar;
import '../ui/tokens.dart';
import '../ui/launch_flags.dart';

/// Plan 5.2: one bot's job page. Job (Needs you · Working on · Responsibilities · Done), Training
/// (Tell it · Files · Learned) and Settings. Replaces the separate desk, routines and watches views.
class BotProfileScreen extends StatefulWidget {
  const BotProfileScreen({super.key, required this.botId, this.tab = 0});
  final String botId;
  final int tab;

  @override
  State<BotProfileScreen> createState() => _BotProfileScreenState();
}

class _BotProfileScreenState extends State<BotProfileScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this, initialIndex: widget.tab.clamp(0, 2).toInt());

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _menu(String v, Bot b) async {
    final state = context.read<AppState>();
    switch (v) {
      case 'edit':
        await Navigator.push(context, MaterialPageRoute(builder: (_) => HireScreen(editBotId: b.id)));
      case 'activity':
        await Navigator.push(context, MaterialPageRoute(builder: (_) => BotActivityScreen(bot: b)));
      case 'share':
        await shareBotSheet(context, b);
      case 'publish':
        await publishBotSheet(context, b);
      case 'unpublish':
        final messenger = ScaffoldMessenger.of(context);
        final e = await BotStore.I.unpublish(b);
        messenger.showSnackBar(SnackBar(content: Text(e ?? '${b.name} is no longer in the Bot Store.')));
      case 'pause':
        await (b.active ? Bots.I.pause(b) : Bots.I.resume(b));
      case 'fire':
        final ok = await showDialog<bool>(
          context: context,
          builder: (d) => AlertDialog(
            title: Text('Remove ${b.name}?'),
            content: Text(b.builtIn
                ? '${b.name} stops working for you and forgets everything. You can start again anytime.'
                : '${b.name} will be deleted with everything they remember.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(d, false), child: Text(tr('Cancel'))),
              TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('Remove', style: TextStyle(color: Palette.red))),
            ],
          ),
        );
        if (ok == true) {
          if (b.convId.isNotEmpty) await state.deleteConversation(b.convId);
          await Bots.I.remove(b);
          if (mounted) Navigator.pop(context);
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final p = Palette.of(context);
    return AnimatedBuilder(
      animation: Listenable.merge([Bots.I, Offices.I, state]),
      builder: (context, _) {
        final b = Bots.I.byId(widget.botId);
        if (b == null) return const Scaffold(body: SizedBox.shrink());
        final started = b.active || b.convId.isNotEmpty;
        final presence = Bots.I.presenceOf(b);
        final waiting = Offices.I.pending.where((a) => a.botId == b.id).length + (b.trustOffered ? 1 : 0) + b.desk.where((t) => t.status == 'waiting').length;
        return Scaffold(
          body: NestedScrollView(
            headerSliverBuilder: (context, _) => [
              SliverAppBar(
                pinned: true,
                title: Text(b.name),
                actions: [
                  PopupMenuButton<String>(
                    onSelected: (v) => _menu(v, b),
                    itemBuilder: (_) => [
                      // Activity lives once, under Settings > More settings (PLAN.md 3.3).
                      PopupMenuItem(value: 'edit', child: Text(tr('Edit'))),
                      const PopupMenuItem(value: 'share', child: Text('Share')),
                      if (LaunchFlags.storePublishing)
                        PopupMenuItem(value: 'publish', child: Text(b.storeId.isEmpty ? 'Publish to Bot Store' : 'Update in Bot Store')),
                      if (b.storeId.isNotEmpty) const PopupMenuItem(value: 'unpublish', child: Text('Remove from Bot Store')),
                      if (b.convId.isNotEmpty) ...[
                        PopupMenuItem(value: 'pause', child: Text(b.active ? 'Pause' : 'Resume')),
                        PopupMenuItem(value: 'fire', child: Text('Remove ${b.name}')),
                      ],
                    ],
                  ),
                ],
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(20, 4, 20, 8),
                  child: Column(children: [
                    // Tap the face to change how this bot looks (SubMac avatar set).
                    Semantics(
                      button: true,
                      label: 'Change look',
                      child: GestureDetector(onTap: () => pickAvatar(context, b), child: BotAvatar(bot: b, size: 84, presence: started)),
                    ),
                    const SizedBox(height: 12),
                    Text(b.name, style: Brand.serif(size: 30, color: p.text, height: 1.1)),
                    const SizedBox(height: 4),
                    Text(b.role, style: TextStyle(color: p.muted, fontSize: AppText.body)),
                    const SizedBox(height: 6),
                    Text(
                      started
                          ? [
                              Bot.presenceLabels[presence]!,
                              BotTrust.labels[b.level]!,
                              if (Bots.I.health(b).isNotEmpty) Bots.I.health(b),
                            ].join(' · ')
                          : 'Not working for you yet',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: p.muted, fontSize: AppText.meta),
                    ),
                    if (b.active && SystemTools.perms['battery'] == false)
                      TextButton(
                        style: TextButton.styleFrom(foregroundColor: p.muted),
                        onPressed: () => SystemBridge.I.openPermission('battery'),
                        child: Text('Your phone may pause ${b.name}. Let it keep working.'),
                      ),
                    const SizedBox(height: 12),
                    Row(children: [
                      Expanded(
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(backgroundColor: p.text, foregroundColor: p.bg, minimumSize: const Size.fromHeight(46), shape: const StadiumBorder()),
                          onPressed: () async {
                            Navigator.of(context).popUntil((r) => r.isFirst);
                            if (b.active) {
                              await state.openBot(b);
                            } else if (b.convId.isNotEmpty) {
                              await Bots.I.resume(b);
                              await state.openBot(b);
                            } else {
                              final e = await state.hireBot(b);
                              if (e != null) state.showBanner(e);
                            }
                          },
                          icon: const Icon(Icons.chat_bubble_outline_rounded, size: 18),
                          label: Text(started ? 'Message' : 'Start'),
                        ),
                      ),
                      if (b.active) ...[
                        const SizedBox(width: 10),
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(minimumSize: const Size(0, 46), foregroundColor: p.text, backgroundColor: p.sheet, shape: const StadiumBorder()),
                          onPressed: () {
                            Navigator.of(context).popUntil((r) => r.isFirst);
                            state.callBot(b);
                          },
                          icon: const Icon(Icons.call_outlined, size: 18),
                          label: Text(tr('Call')),
                        ),
                      ],
                    ]),
                  ]),
                ),
              ),
              SliverPersistentHeader(
                pinned: true,
                delegate: _TabsHeader(
                  // Grok-like segmented tabs: the chosen one sits on a soft sheet pill, no underline, no line under the bar.
                  TabBar(
                    controller: _tabs,
                    labelColor: p.text,
                    unselectedLabelColor: p.muted,
                    indicator: BoxDecoration(color: p.sheet, borderRadius: const BorderRadius.all(Radius.circular(Radii.pill))),
                    indicatorSize: TabBarIndicatorSize.tab,
                    indicatorPadding: const EdgeInsets.symmetric(horizontal: Space.x2, vertical: Space.x1),
                    dividerColor: Colors.transparent,
                    splashBorderRadius: const BorderRadius.all(Radius.circular(Radii.pill)),
                    tabs: [
                      Tab(text: waiting > 0 ? 'Job · $waiting' : 'Job'),
                      const Tab(text: 'Training'),
                      const Tab(text: 'Settings'),
                    ],
                  ),
                  p.bg,
                ),
              ),
            ],
            body: TabBarView(controller: _tabs, children: [
              _JobTab(bot: b),
              BotTrainingView(botId: b.id),
              _SettingsTab(bot: b),
            ]),
          ),
        );
      },
    );
  }
}

class _TabsHeader extends SliverPersistentHeaderDelegate {
  _TabsHeader(this.bar, this.bg);
  final TabBar bar;
  final Color bg;
  @override
  double get minExtent => bar.preferredSize.height;
  @override
  double get maxExtent => bar.preferredSize.height;
  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) => ClipRect(
        // Frosted over the sky (restyle): the page scrolls softly under the tabs instead of under a solid bar.
        child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18), child: ColoredBox(color: bg.withValues(alpha: 0.55), child: bar)),
      );
  @override
  bool shouldRebuild(_TabsHeader old) => old.bar != bar || old.bg != bg;
}

// ------------------------------------------------------------------ job

/// "Every day at 08:00", "Weekdays at 09:00", "Mondays and Thursdays at 10:00".
String routineWhen(BotRoutine r) {
  const names = {'mon': 'Mondays', 'tue': 'Tuesdays', 'wed': 'Wednesdays', 'thu': 'Thursdays', 'fri': 'Fridays', 'sat': 'Saturdays', 'sun': 'Sundays'};
  final days = switch (r.days) {
    'daily' => 'Every day',
    'weekdays' => 'Weekdays',
    'weekends' => 'Weekends',
    _ => () {
        final l = [for (final d in r.days.toLowerCase().split(RegExp(r'[ ,]+'))) if (d.length >= 3) names[d.substring(0, 3)] ?? d];
        return l.length <= 1 ? (l.isEmpty ? r.days : l.first) : '${l.sublist(0, l.length - 1).join(', ')} and ${l.last}';
      }(),
  };
  return '$days at ${r.time}';
}

String _when(DateTime d) {
  final now = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  final t = '${two(d.hour)}:${two(d.minute)}';
  final day = DateTime(d.year, d.month, d.day).difference(DateTime(now.year, now.month, now.day)).inDays;
  if (day == 0) return 'Today $t';
  if (day == -1) return 'Yesterday $t';
  if (day == 1) return 'Tomorrow $t';
  return '${d.day}/${d.month} $t';
}

class _JobTab extends StatelessWidget {
  const _JobTab({required this.bot});
  final Bot bot;

  Future<void> _addResponsibility(BuildContext context, Bot b) async {
    final what = TextEditingController();
    var time = '08:00';
    var days = 'daily';
    final ok = await showModalBottomSheet<bool>(
      sheetAnimationStyle: SubMotion.sheet,
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        final p = Palette.of(ctx);
        Widget chip(String label, String t, String d) => ChoiceChip(
              label: Text(label),
              selected: time == t && days == d,
              onSelected: (_) => set(() {
                time = t;
                days = d;
              }),
            );
        return Padding(
          padding: EdgeInsetsDirectional.fromSTEB(20, 0, 20, MediaQuery.of(ctx).viewInsets.bottom + 20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('A new responsibility', style: Brand.serif(size: 24, color: p.text)),
            const SizedBox(height: 12),
            TextField(
              controller: what,
              autofocus: true,
              minLines: 2,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(hintText: 'e.g. Brief me on my inbox', labelText: 'What should ${b.name} do?'),
            ),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              chip('Every morning', '08:00', 'daily'),
              chip('Every evening', '19:00', 'daily'),
              chip('Weekdays at 9', '09:00', 'weekdays'),
              chip('Mondays', '09:00', 'mon'),
              ActionChip(
                label: Text('Other time · $time'),
                onPressed: () async {
                  final t = await showTimePicker(context: ctx, initialTime: TimeOfDay(hour: int.parse(time.split(':')[0]), minute: int.parse(time.split(':')[1])));
                  if (t != null) set(() => time = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}');
                },
              ),
            ]),
            const SizedBox(height: 16),
            SizedBox(width: double.infinity, child: FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Add'))),
          ]),
        );
      }),
    );
    if (ok != true || what.text.trim().isEmpty) return;
    b.routines.add(BotRoutine(id: 'r${DateTime.now().millisecondsSinceEpoch % 100000}', time: time, days: days, kind: 'message', instruction: what.text.trim()));
    await Bots.I.save();
    await Bots.I.arm(b);
  }

  void _task(BuildContext context, Bot b, DeskTask t) {
    showModalBottomSheet<void>(
      sheetAnimationStyle: SubMotion.sheet,
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(20, 0, 20, 8),
            child: Text(t.text, style: Theme.of(ctx).textTheme.titleMedium),
          ),
          if (t.note.isNotEmpty) Padding(padding: const EdgeInsetsDirectional.fromSTEB(20, 0, 20, 8), child: Text(t.note)),
          if (t.status != 'done')
            ListTile(
              leading: const Icon(Icons.check_rounded),
              title: const Text('Mark as done'),
              onTap: () async {
                Navigator.pop(ctx);
                t
                  ..status = 'done'
                  ..updated = DateTime.now();
                b.log('work', 'Done: ${t.text}');
                await Bots.I.save();
              },
            ),
          ListTile(
            leading: const Icon(Icons.close_rounded),
            title: const Text('Remove'),
            onTap: () async {
              Navigator.pop(ctx);
              b.desk.remove(t);
              await Bots.I.save();
            },
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final b = bot;
    final needs = b.desk.where((t) => t.status == 'waiting').toList();
    final working = b.desk.where((t) => t.status == 'doing' || t.status == 'todo').toList()
      ..sort((x, y) => x.status == y.status ? 0 : (x.status == 'doing' ? -1 : 1));
    final since = DateTime.now().subtract(const Duration(days: 7));
    final doneDesk = b.desk.where((t) => t.status == 'done').toList().reversed.take(8).map((t) => (t.text, t.updated)).toList();
    final done = <(String, DateTime)>[...doneDesk];
    for (final e in b.journal.reversed) {
      if (e.at.isBefore(since) || e.kind != 'work' || !e.text.startsWith('Done: ')) continue;
      final t = e.text.substring(6);
      if (!done.any((d) => d.$1 == t)) done.add((t, e.at));
      if (done.length >= 10) break;
    }
    final hasNeeds = needs.isNotEmpty || b.trustOffered || Offices.I.pending.any((a) => a.botId == b.id);
    return ListView(padding: const EdgeInsetsDirectional.fromSTEB(20, 8, 20, 48), children: [
      _Head('Needs you'),
      if (b.trustOffered) TrustOfferCard(bot: b),
      ApprovalList(botId: b.id),
      for (final t in needs) _Line(icon: Icons.hourglass_empty_rounded, text: t.text, sub: t.note.isEmpty ? 'Waiting on you' : t.note, onTap: () => _task(context, b, t)),
      if (!hasNeeds) _Muted('Nothing needs you right now.'),
      _Head('Working on'),
      if (working.isEmpty) _Muted(b.active ? 'Nothing open. Give ${b.name} a job in the chat.' : 'Not working for you yet.'),
      for (final t in working.take(12))
        _Line(
          icon: t.status == 'doing' ? Icons.play_circle_outline_rounded : Icons.east_rounded,
          text: t.text,
          sub: t.status == 'doing' ? (t.note.isEmpty ? 'In progress' : t.note) : t.note,
          onTap: () => _task(context, b, t),
        ),
      _Head('Responsibilities'),
      // One job at several times of day is one line (it used to show 24 for an hourly job, 2026-11-05).
      for (final g in Bots.routineGroups(b.routines))
        _Line(
          icon: g.kind == 'call' ? Icons.call_outlined : Icons.schedule_rounded,
          text: g.instruction,
          sub: '${g.routines.length == 1 ? routineWhen(g.routines.first) : g.when[0].toUpperCase() + g.when.substring(1)}'
              '${g.kind == 'call' ? ' · calls you' : g.kind == 'message' ? ' · messages you' : ' · tells you if it matters'}',
          onDelete: () async {
            for (final r in g.routines) {
              b.routines.remove(r);
              await SystemBridge.I.cancelAlarm(Bots.alarmId(b, r.id));
            }
            await Bots.I.save();
            await Bots.I.arm(b);
          },
        ),
      // A job through the day ("every hour"): the bot's own repeating scheduled task.
      for (final t in Scheduler.I.tasks.where((t) => t.bot == b.id && t.repeat != 'none').toList())
        _Line(
          icon: Icons.repeat_rounded,
          text: t.task,
          sub: t.repeat == 'hourly' ? 'Every hour' : (t.repeat == 'every_3_hours' ? 'Every 3 hours' : t.repeat),
          onDelete: () async {
            await Scheduler.I.cancel(t.id);
          },
        ),
      for (final w in b.watches)
        _Line(
          icon: Icons.notifications_none_rounded,
          text: w.instruction.isEmpty ? 'Phone alerts' : w.instruction,
          sub: 'When ${w.app.isEmpty ? 'any app' : w.app}${w.chat.isNotEmpty ? ' (${w.chat})' : ''} '
              '${w.keyword.isEmpty ? 'notifies you' : 'mentions "${w.keyword}"'}',
          onDelete: () async {
            b.watches.remove(w);
            await Bots.I.save();
          },
        ),
      for (final f in b.followups)
        _Line(icon: Icons.event_outlined, text: f.instruction.replaceFirst('(retry) ', ''), sub: 'Promised for ${_when(f.at)}'),
      if (b.heartbeatHours > 0) _Line(icon: Icons.favorite_border_rounded, text: 'Checks in', sub: 'Every ${b.heartbeatHours} hours, outside your quiet hours'),
      if (b.report != 'off')
        _Line(icon: Icons.edit_note_rounded, text: 'Sends a note', sub: b.report == 'weekly' ? 'Sundays at 19:00' : 'Evenings at 19:00, when there is something to say'),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton.icon(
          style: TextButton.styleFrom(foregroundColor: p.text, padding: EdgeInsets.zero),
          onPressed: () => _addResponsibility(context, b),
          icon: const Icon(Icons.add_rounded, size: 18),
          label: const Text('Add a responsibility'),
        ),
      ),
      _Head('Done'),
      if (Bots.I.weekReport(b).isNotEmpty) Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(Bots.I.weekReport(b), style: TextStyle(color: p.text, fontSize: AppText.meta, height: 1.4))),
      if (done.isEmpty) _Muted('Finished work shows up here.'),
      for (final d in done) _Line(icon: Icons.check_circle_outline_rounded, text: d.$1, sub: _when(d.$2), muted: true),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton.icon(
          style: TextButton.styleFrom(foregroundColor: p.muted, padding: EdgeInsets.zero),
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => BotActivityScreen(bot: b))),
          icon: const Icon(Icons.timeline_rounded, size: 18),
          label: const Text('How'),
        ),
      ),
    ]);
  }
}

// ------------------------------------------------------------------ settings

class _SettingsTab extends StatelessWidget {
  const _SettingsTab({required this.bot, this.more = false});
  final Bot bot;
  /// The second page: About, rhythm, calls, tools, activity, account.
  final bool more;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final b = bot;
    final calls = !b.allowCalls ? 'off' : (Bots.I.fullScreenCalls ? 'full' : 'top');
    // Bot settings (PLAN.md 3.3): Trust, Voice and Off hours up front; everything else under More settings.
    if (!more) {
      return ListView(padding: const EdgeInsetsDirectional.fromSTEB(20, 8, 20, 48), children: [
      _Head('Trust'),
      _Pick(
        label: 'Freedom',
        value: b.level,
        options: {for (final e in BotTrust.labels.entries) e.key: '${e.value}: ${BotTrust.blurbs[e.key]}'},
        onChanged: (v) => Bots.I.setTrust(b, v),
      ),
      if (b.level == BotTrust.levelNew)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
              b.cleanOk > 0
                  ? '${b.cleanOk} approval${b.cleanOk == 1 ? '' : 's'} in a row without changes. On its own is offered after ${b.trustOfferAt}.'
                  : 'On its own is offered after ${BotTrust.promoteAfter} approvals in a row without changes.',
              style: TextStyle(color: p.muted, fontSize: AppText.micro)),
        ),
      _Pick(
        label: 'Voice',
        value: b.voice,
        options: const {
          '': 'Same as my calls', 'Aoede': 'Bright', 'Kore': 'Calm', 'Charon': 'Deep', 'Puck': 'Lively',
          'Fenrir': 'Warm', 'Leda': 'Soft', 'Orus': 'Firm', 'Zephyr': 'Light'
        },
        onChanged: (v) async {
          b.voice = v;
          await Bots.I.save();
        },
      ),
      BotModelRow(bot: b),
      _Pick(
        label: 'Off hours',
        value: '${b.quietFrom}-${b.quietTo}',
        options: const {'22-7': '10 pm to 7 am', '23-6': '11 pm to 6 am', '21-8': '9 pm to 8 am', '0-0': 'None'},
        onChanged: (v) async {
          final parts = v.split('-');
          b.quietFrom = int.parse(parts[0]);
          b.quietTo = int.parse(parts[1]);
          await Bots.I.save();
          await Bots.I.arm(b);
        },
      ),
        SurfaceRow(
          margin: const EdgeInsets.symmetric(vertical: 2),
          child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: Space.x4),
          title: const Text('More settings'),
          trailing: Icon(Icons.chevron_right_rounded, color: p.muted),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => Scaffold(
                appBar: AppBar(title: const Text('More settings')),
                body: AnimatedBuilder(animation: Bots.I, builder: (_, __) => _SettingsTab(bot: b, more: true)),
              ),
            ),
          ),
          ),
        ),
      ]);
    }
    return ListView(padding: const EdgeInsetsDirectional.fromSTEB(20, 8, 20, 48), children: [
      _Head('About'),
      // About sits on the shared sky surface like every other row; tapping it opens the edit screen.
      SurfaceRow(
        margin: const EdgeInsets.symmetric(vertical: 2),
        child: InkWell(
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => HireScreen(editBotId: b.id))),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Space.x3, horizontal: Space.x4),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(b.persona, style: TextStyle(color: p.text, fontSize: AppText.meta, height: 1.4)),
                  if (b.mission.isNotEmpty) ...[
                    const SizedBox(height: Space.x2),
                    Text('Mission: ${b.mission}', style: TextStyle(color: p.muted, fontSize: AppText.meta, height: 1.4)),
                  ],
                  const SizedBox(height: Space.x2),
                  Text(tr('Edit'), style: TextStyle(color: p.text, fontSize: AppText.meta, fontWeight: FontWeight.w600)),
                ]),
              ),
              Icon(Icons.chevron_right_rounded, color: p.muted),
            ]),
          ),
        ),
      ),
      _Head('Rhythm'),
      _Pick(
        label: 'Notes from ${b.name}',
        value: b.report,
        options: const {'daily': 'Every evening, when there is something to say', 'weekly': 'Once a week, on Sundays', 'off': 'No notes'},
        onChanged: (v) async {
          b.report = v;
          await Bots.I.save();
          await Bots.I.arm(b);
        },
      ),
      _Pick(
        label: 'How often ${b.name} reaches out',
        value: b.proactivity,
        options: const {'quiet': 'Rarely', 'balanced': 'When it matters', 'active': 'Often'},
        onChanged: (v) async {
          b.proactivity = v;
          await Bots.I.save();
        },
      ),
      _Pick(
        label: 'Checks in',
        value: '${b.heartbeatHours}',
        options: const {'0': 'Only for its responsibilities', '3': 'Every 3 hours', '6': 'Every 6 hours', '8': 'Every 8 hours', '12': 'Twice a day', '24': 'Once a day'},
        onChanged: (v) async {
          b.heartbeatHours = int.tryParse(v) ?? 0;
          await Bots.I.save();
          await Bots.I.arm(b);
        },
      ),
      _Pick(
        label: 'Calls',
        value: calls,
        options: const {'off': 'Can\'t call me', 'top': 'Can call me · rings at the top', 'full': 'Can call me · rings full screen (all bots)'},
        onChanged: (v) async {
          b.allowCalls = v != 'off';
          if (v != 'off') await Bots.I.setFullScreenCalls(v == 'full');
          await Bots.I.save();
        },
      ),
      SurfaceRow(
        margin: const EdgeInsets.symmetric(vertical: 2),
        child: SwitchListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: Space.x4),
        title: const Text('Works while you\'re away'),
        subtitle: Text(
            b.cloudFit
                ? 'Runs without your phone.'
                : 'Runs without your phone. Calls and texts still wait for your phone.',
            style: TextStyle(color: p.muted)),
        value: b.cloudOn,
        onChanged: (v) async {
          b.cloudChoice = v;
          await Bots.I.save();
          await Bots.I.arm(b);
        },
      ),
      ),
      _Head('Tools'),
      BotSetupSection(bot: b),
      _Head('What ${b.name} may use'),
      BotPowersSection(bot: b),
      _Head('Activity'),
      SurfaceRow(
        margin: const EdgeInsets.symmetric(vertical: 2),
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: Space.x4),
          leading: Icon(Icons.timeline_rounded, color: p.text),
          title: const Text('Steps'),
          subtitle: Text('${BotTraces.I.of(b.id).length} recent', style: TextStyle(color: p.muted)),
          trailing: Icon(Icons.chevron_right_rounded, color: p.muted),
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => BotActivityScreen(bot: b))),
        ),
      ),
      _Head('Your account'),
      const _SyncRow(),
    ]);
  }
}

/// Whether this bot is in the owner's account, in plain words: saving, saved, not saved yet, or a
/// problem with one way to try again. A sync never fails in silence (see BotSync).
class _SyncRow extends StatelessWidget {
  const _SyncRow();

  static String _ago(DateTime? t) {
    if (t == null) return '';
    final d = DateTime.now().difference(t);
    if (d.inSeconds < 60) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours} h ago';
    return '${d.inDays} d ago';
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return ValueListenableBuilder<BotSyncState>(
      valueListenable: BotSync.I.status,
      builder: (context, st, _) {
        var icon = Icons.cloud_off_rounded;
        var title = 'Not saved yet';
        var note = 'Saved to your account when you sign in';
        var color = p.muted;
        var retry = false;
        switch (st) {
          case BotSyncState.idle:
            break;
          case BotSyncState.syncing:
            icon = Icons.cloud_sync_rounded;
            title = 'Saving…';
            note = '';
            break;
          case BotSyncState.ok:
            icon = Icons.cloud_done_rounded;
            title = 'Saved to your account';
            note = _ago(BotSync.I.lastSync);
            color = p.ok;
            break;
          case BotSyncState.failed:
            title = "Couldn't save";
            note = 'It tries again by itself';
            color = p.accent;
            retry = true;
            break;
        }
        return SurfaceRow(
          margin: const EdgeInsets.symmetric(vertical: 2),
          child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: Space.x4),
          leading: Icon(icon, color: color),
          title: Text(title, style: TextStyle(color: p.text)),
          subtitle: note.isEmpty ? null : Text(note, style: TextStyle(color: p.muted)),
          trailing: retry
              ? TextButton(
                  onPressed: () async {
                    await BotSync.I.syncNow();
                  },
                  child: Text(tr('Try again')),
                )
              : null,
          ),
        );
      },
    );
  }
}

/// The bot's own model (owner 2026-11-05): part of the bot's settings in its profile, not in Settings. Always shown.
/// "Default (same as SubMac)" follows the model the owner's chats use; SubMac or one of the owner's own provider
/// models pins this bot to it. Saved on the bot (`model`) and synced with its other settings; every turn of this bot
/// (its chat, team parts, routines and wakes) runs on it (OcLane.pick).
class BotModelRow extends StatelessWidget {
  const BotModelRow({super.key, required this.bot});
  final Bot bot;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([ByokStore.I, Bots.I]),
      builder: (context, _) => SurfaceRow(
        margin: const EdgeInsets.symmetric(vertical: 2),
        child: ListTile(
          key: const ValueKey('bot-model'),
          contentPadding: const EdgeInsets.symmetric(horizontal: Space.x4),
          title: Text(tr('Model')),
          subtitle: Text(botModelLabel(bot.model), style: TextStyle(color: p.muted)),
          trailing: Icon(Icons.chevron_right_rounded, color: p.muted),
          onTap: () async {
            final v = await showModelPicker(context, current: bot.model, title: 'Model for ${bot.name}', forBot: true);
            if (v == null) return;
            await Bots.I.setModel(bot, v);
          },
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ small parts

class _Head extends StatelessWidget {
  const _Head(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 6),
        child: Text(text, style: AppText.sectionStyle.copyWith(color: Palette.of(context).muted)),
      );
}

class _Muted extends StatelessWidget {
  const _Muted(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(text, style: TextStyle(color: Palette.of(context).muted, height: 1.4)),
      );
}

class _Line extends StatelessWidget {
  const _Line({required this.icon, required this.text, this.sub = '', this.muted = false, this.onDelete, this.onTap});
  final IconData icon;
  final String text;
  final String sub;
  final bool muted;
  final VoidCallback? onDelete;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    // Each line sits on the shared sky surface (restyle), like Grok's calm rows.
    return SurfaceRow(
      margin: const EdgeInsets.symmetric(vertical: 2),
      child: InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Space.x3, horizontal: Space.x4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 18, color: muted ? p.muted : p.text)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(text, style: TextStyle(color: muted ? p.muted : p.text, fontSize: AppText.meta, height: 1.35)),
              if (sub.isNotEmpty) Text(sub, style: TextStyle(color: p.muted, fontSize: AppText.micro)),
            ]),
          ),
          if (onDelete != null)
            InkWell(
              customBorder: const CircleBorder(),
              onTap: onDelete,
              child: Padding(padding: const EdgeInsets.all(4), child: Icon(Icons.close_rounded, size: 16, color: p.muted)),
            ),
        ]),
      ),
      ),
    );
  }
}

class _Pick extends StatelessWidget {
  const _Pick({required this.label, required this.value, required this.options, required this.onChanged});
  final String label;
  final String value;
  final Map<String, String> options;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return SurfaceRow(
      margin: const EdgeInsets.symmetric(vertical: 2),
      child: ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: Space.x4),
      title: Text(label),
      subtitle: Text(options[value] ?? value, style: TextStyle(color: p.muted)),
      trailing: Icon(Icons.chevron_right_rounded, color: p.muted),
      onTap: () async {
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
      ),
    );
  }
}
