import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../services/bot_powers.dart';
import '../services/bot_sync.dart';
import '../services/bot_store.dart';
import '../services/bots.dart';
import '../services/offices.dart';
import '../services/system_bridge.dart';
import '../services/system_tools.dart';
import '../services/trust.dart';
import '../theme.dart';
import '../widgets/avatar_picker.dart';
import '../widgets/approval_card.dart';
import '../widgets/surface.dart';
import '../widgets/lux_kit.dart';
import '../widgets/sub_icon.dart';
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
        // Every account keeps exactly one Chief: another bot becomes the Chief first.
        if (!Bots.I.canRemove(b)) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(tr('{name} is your Chief. Make another bot the Chief first, then you can remove {name}.', {'name': b.name}))));
          return;
        }
        final ok = await luxConfirm(context,
            title: tr('Remove {name}?', {'name': b.name}),
            message: b.builtIn
                ? '${b.name} stops working for you and forgets everything. You can start again anytime.'
                : '${b.name} will be deleted with everything they remember.',
            action: 'Remove',
            destructive: true);
        if (ok) {
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
                  // SubMac's "more" glyph opens the quiet choice sheet (no Material overflow menu).
                  IconButton(
                    key: const ValueKey('bot-more'),
                    tooltip: tr('More'),
                    icon: SubIcon('more', size: IconSize.lg, color: p.text),
                    onPressed: () async {
                      final v = await showLuxChoices<String>(context, title: b.name, choices: [
                        // Activity lives once, under Settings > More settings (PLAN.md 3.3).
                        const LuxChoice('edit', 'Edit'),
                        const LuxChoice('share', 'Share'),
                        if (LaunchFlags.storePublishing) LuxChoice('publish', b.storeId.isEmpty ? 'Publish to Bot Store' : 'Update in Bot Store'),
                        if (b.storeId.isNotEmpty) const LuxChoice('unpublish', 'Remove from Bot Store'),
                        if (b.convId.isNotEmpty) ...[
                          LuxChoice('pause', b.active ? 'Pause' : 'Resume'),
                          LuxChoice('fire', tr('Remove {name}', {'name': b.name}), destructive: true),
                        ],
                      ]);
                      if (v != null) await _menu(v, b);
                    },
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
                      child: GestureDetector(onTap: () => pickAvatar(context, b), child: BotAvatar(bot: b, size: 84)),
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
                      LuxWordButton('Your phone may pause ${b.name}. Let it keep working.', onPressed: () => SystemBridge.I.openPermission('battery')),
                    const SizedBox(height: Space.x2),
                    // The two ways to reach the bot, as words (no filled pill, no outlined pill, no Material glyphs).
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      LuxWordButton(
                          started ? 'Message' : 'Start',
                          key: const ValueKey('bot-message'),
                          primary: true,
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
                          }),
                      if (b.active) ...[
                        const SizedBox(width: Space.x4),
                        LuxWordButton('Call', key: const ValueKey('bot-call'), primary: true, onPressed: () {
                          Navigator.of(context).popUntil((r) => r.isFirst);
                          state.callBot(b);
                        }),
                      ],
                    ]),
                  ]),
                ),
              ),
              SliverPersistentHeader(
                pinned: true,
                delegate: _TabsHeader(
                  // Word tabs (fix/ui-restyle): the chosen word in full ink, the others muted. No pill, no underline.
                  _WordTabs(controller: _tabs, labels: [waiting > 0 ? '${tr('Job')} · $waiting' : tr('Job'), tr('Training'), tr('Settings')]),
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

/// The bot page's tabs as words. Tap a word to move; the page's swipe moves the words too.
class _WordTabs extends StatelessWidget {
  const _WordTabs({required this.controller, required this.labels});
  final TabController controller;
  final List<String> labels;

  static const double height = 48;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return AnimatedBuilder(
      animation: controller.animation ?? controller,
      builder: (context, _) {
        final at = controller.animation?.value ?? controller.index.toDouble();
        return SizedBox(
          height: height,
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            for (final (i, l) in labels.indexed)
              LuxTap(
                key: ValueKey('bot-tab-$i'),
                selected: controller.index == i,
                onTap: () => controller.animateTo(i, duration: SubMotion.of(context, LuxMotion.base), curve: LuxMotion.ease),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Space.x4, vertical: Space.x3),
                  child: Text(l,
                      style: AppText.bodyStyle.copyWith(
                        // The words cross-fade with the swipe itself, so the tabs never lag the page.
                        color: Color.lerp(p.text, p.muted, (at - i).abs().clamp(0.0, 1.0).toDouble()),
                        fontWeight: controller.index == i ? FontWeight.w700 : FontWeight.w500,
                      )),
                ),
              ),
          ]),
        );
      },
    );
  }
}

class _TabsHeader extends SliverPersistentHeaderDelegate {
  _TabsHeader(this.bar, this.bg);
  final Widget bar;
  final Color bg;
  @override
  double get minExtent => _WordTabs.height;
  @override
  double get maxExtent => _WordTabs.height;
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
    final ok = await showLuxSheet<bool>(
      context,
      title: 'A new responsibility',
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        LuxWord chip(String label, String t, String d) => LuxWord(
              label,
              selected: time == t && days == d,
              onTap: () => set(() {
                time = t;
                days = d;
              }),
            );
        return Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(Space.x5, Space.x2, Space.x5, Space.x5),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            TextField(
              controller: what,
              autofocus: true,
              minLines: 2,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(hintText: 'e.g. Brief me on my inbox', labelText: 'What should ${b.name} do?'),
            ),
            const SizedBox(height: 12),
            LuxWords([
              chip('Every morning', '08:00', 'daily'),
              chip('Every evening', '19:00', 'daily'),
              chip('Weekdays at 9', '09:00', 'weekdays'),
              chip('Mondays', '09:00', 'mon'),
              LuxWord(
                '${tr('Other time')} · $time',
                onTap: () async {
                  final t = await showTimePicker(context: ctx, initialTime: TimeOfDay(hour: int.parse(time.split(':')[0]), minute: int.parse(time.split(':')[1])));
                  if (t != null) set(() => time = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}');
                },
              ),
            ]),
            const SizedBox(height: Space.x3),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: LuxWordButton('Add', primary: true, onPressed: () => Navigator.pop(ctx, true)),
            ),
          ]),
        );
      }),
    );
    if (ok != true || what.text.trim().isEmpty) return;
    b.routines.add(BotRoutine(id: 'r${DateTime.now().millisecondsSinceEpoch % 100000}', time: time, days: days, kind: 'message', instruction: what.text.trim()));
    await Bots.I.save();
    await Bots.I.arm(b);
  }

  Future<void> _task(BuildContext context, Bot b, DeskTask t) async {
    final v = await showLuxChoices<String>(context, title: t.note.isEmpty ? t.text : '${t.text}\n${t.note}', choices: [
      if (t.status != 'done') const LuxChoice('done', 'Mark as done'),
      const LuxChoice('remove', 'Remove', destructive: true),
    ]);
    if (v == 'done') {
      t
        ..status = 'done'
        ..updated = DateTime.now();
      b.log('work', 'Done: ${t.text}');
      await Bots.I.save();
    } else if (v == 'remove') {
      b.desk.remove(t);
      await Bots.I.save();
    }
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
      for (final t in needs) _Line(text: t.text, sub: t.note.isEmpty ? 'Waiting on you' : t.note, onTap: () => _task(context, b, t)),
      if (!hasNeeds) _Muted('Nothing needs you right now.'),
      _Head('Working on'),
      if (working.isEmpty) _Muted(b.active ? 'Nothing open. Give ${b.name} a job in the chat.' : 'Not working for you yet.'),
      for (final t in working.take(12))
        _Line(text: t.text,
          sub: t.status == 'doing' ? (t.note.isEmpty ? 'In progress' : t.note) : t.note,
          onTap: () => _task(context, b, t),
        ),
      _Head('Responsibilities'),
      for (final r in b.routines)
        _Line(text: r.instruction,
          sub: '${routineWhen(r)}${r.kind == 'call' ? ' · calls you' : r.kind == 'message' ? ' · messages you' : ' · tells you if it matters'}',
          onDelete: () async {
            b.routines.remove(r);
            await Bots.I.save();
            await Bots.I.arm(b);
          },
        ),
      for (final w in b.watches)
        _Line(text: w.instruction.isEmpty ? 'Phone alerts' : w.instruction,
          sub: 'When ${w.app.isEmpty ? 'any app' : w.app}${w.chat.isNotEmpty ? ' (${w.chat})' : ''} '
              '${w.keyword.isEmpty ? 'notifies you' : 'mentions "${w.keyword}"'}',
          onDelete: () async {
            b.watches.remove(w);
            await Bots.I.save();
          },
        ),
      for (final f in b.followups)
        _Line(text: f.instruction.replaceFirst('(retry) ', ''), sub: 'Promised for ${_when(f.at)}'),
      if (b.heartbeatHours > 0) _Line(text: 'Checks in', sub: 'Every ${b.heartbeatHours} hours, outside your quiet hours'),
      if (b.report != 'off')
        _Line(text: 'Sends a note', sub: b.report == 'weekly' ? 'Sundays at 19:00' : 'Evenings at 19:00, when there is something to say'),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: LuxWordButton('Add a responsibility', primary: true, onPressed: () => _addResponsibility(context, b)),
      ),
      _Head('Done'),
      if (Bots.I.weekReport(b).isNotEmpty) Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(Bots.I.weekReport(b), style: TextStyle(color: p.text, fontSize: AppText.meta, height: 1.4))),
      if (done.isEmpty) _Muted('Finished work shows up here.'),
      for (final d in done) _Line(text: d.$1, sub: _when(d.$2), muted: true),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: LuxWordButton('How', onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => BotActivityScreen(bot: b)))),
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
        LuxRow(
          padding: const EdgeInsets.symmetric(vertical: Space.x3),
          title: tr('More settings'),
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
      ]);
    }
    return ListView(padding: const EdgeInsetsDirectional.fromSTEB(20, 8, 20, 48), children: [
      _Head('About'),
      // About sits on the shared sky surface like every other row; tapping it opens the edit screen.
      SurfaceRow(
        margin: const EdgeInsets.symmetric(vertical: 2),
        child: LuxTap(
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => HireScreen(editBotId: b.id))),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Space.x3),
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
      LuxSwitchRow(
        title: tr('Works while you\'re away'),
        sub: tr(b.cloudFit ? 'Runs without your phone.' : 'Runs without your phone. Calls and texts still wait for your phone.'),
        value: b.cloudOn,
        onChanged: (v) async {
          b.cloudChoice = v;
          await Bots.I.save();
          await Bots.I.arm(b);
        },
      ),
      _Head('Tools'),
      BotSetupSection(bot: b),
      _Head('What ${b.name} may use'),
      BotPowersSection(bot: b),
      _Head('Activity'),
      LuxRow(
        padding: const EdgeInsets.symmetric(vertical: Space.x3),
        title: tr('Steps'),
        value: '${BotTraces.I.of(b.id).length}',
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => BotActivityScreen(bot: b))),
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
    return ValueListenableBuilder<BotSyncState>(
      valueListenable: BotSync.I.status,
      builder: (context, st, _) {
        // Plain words only (RESTYLE.md: status is text, no cloud icons): what happened, when, and one way to retry.
        var title = 'Not saved yet';
        var note = 'Saved to your account when you sign in';
        var failed = false;
        switch (st) {
          case BotSyncState.idle:
            break;
          case BotSyncState.syncing:
            title = 'Saving…';
            note = '';
            break;
          case BotSyncState.ok:
            title = 'Saved to your account';
            note = _ago(BotSync.I.lastSync);
            break;
          case BotSyncState.failed:
            title = "Couldn't save";
            note = 'It tries again by itself';
            failed = true;
            break;
        }
        return LuxRow(
          key: const ValueKey('bot-sync-row'),
          padding: const EdgeInsets.symmetric(vertical: Space.x3),
          title: tr(title),
          sub: note.isEmpty ? null : tr(note),
          destructive: failed,
          trailing: failed ? LuxWordButton('Try again', primary: true, onPressed: () => BotSync.I.syncNow()) : null,
        );
      },
    );
  }
}

// ------------------------------------------------------------------ small parts

class _Head extends StatelessWidget {
  const _Head(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => LuxSection(text, padding: const EdgeInsets.only(top: Space.x5, bottom: Space.x1));
}

class _Muted extends StatelessWidget {
  const _Muted(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: Space.x1),
        child: Text(tr(text), style: AppText.bodyStyle.copyWith(color: Palette.of(context).muted)),
      );
}

/// One line on the Job tab: the words, a quiet second line, and a small close glyph when it can be removed. No status
/// icon (the section it sits in says what it is) and no surface behind it.
class _Line extends StatelessWidget {
  const _Line({required this.text, this.sub = '', this.muted = false, this.onDelete, this.onTap});
  final String text;
  final String sub;
  final bool muted;
  final VoidCallback? onDelete;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.x2 + 2),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(text, style: AppText.bodyStyle.copyWith(color: muted ? p.muted : p.text, height: 1.35)),
            if (sub.isNotEmpty) Text(sub, style: AppText.microStyle.copyWith(color: p.muted)),
          ]),
        ),
        if (onDelete != null)
          LuxTap(
            label: tr('Remove'),
            onTap: onDelete,
            child: Padding(padding: const EdgeInsets.all(Space.x2), child: SubIcon('close', size: IconSize.sm, color: p.muted)),
          ),
      ]),
    );
    return onTap == null ? row : LuxTap(onTap: onTap, child: row);
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
    return LuxRow(
      padding: const EdgeInsets.symmetric(vertical: Space.x3),
      title: tr(label),
      sub: options[value] ?? value,
      maxLines: 2,
      onTap: () async {
        final v = await showLuxChoices<String>(context,
            title: label, selected: value, choices: [for (final e in options.entries) LuxChoice(e.key, e.value)]);
        if (v != null) onChanged(v);
      },
    );
  }
}
