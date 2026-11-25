import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/always_on.dart';
import '../services/bots.dart';
import '../services/missions.dart';
import '../theme.dart';
import '../ui/tokens.dart';
import 'surface.dart';

/// The owner's controls of a bot's or team's mission (owner 2026-11-07): set a goal and switch autonomy on, the
/// on/off switch, the budget, the stop switch, a [needs you] to answer, the plan and the activity log.
class MissionSection extends StatefulWidget {
  const MissionSection({super.key, required this.kind, required this.ownerId, required this.ownerName});

  /// bot | team
  final String kind;
  final String ownerId;
  final String ownerName;

  @override
  State<MissionSection> createState() => _MissionSectionState();
}

class _MissionSectionState extends State<MissionSection> {
  /// Android's own notification switch (off means no brief ever reaches the phone).
  bool? _notifOk;

  @override
  void initState() {
    super.initState();
    Missions.I.init();
    Permission.notification.status
        .then((s) {
          if (mounted) setState(() => _notifOk = s.isGranted);
        })
        .catchError((Object _) {});
  }

  static String _status(Mission m) {
    final now = DateTime.now();
    final parts = <String>[
      switch (m.status) { 'waiting' => 'Waiting on you', 'done' => 'Done', 'stopped' => 'Stopped', _ => m.on ? 'Working on it' : 'Paused' },
      'runs ${m.runsToday}/${m.runsPerDay} today',
      'tokens ${Missions.k(m.tokensToday)}/${Missions.k(m.tokensPerDay)}',
    ];
    if (m.on && !m.finished && m.nextAt != null) {
      final d = m.nextAt!.difference(now);
      parts.add(d.isNegative ? 'next run now' : d.inMinutes < 60 ? 'next in ${d.inMinutes + 1} min' : 'next ${Missions.when(m.nextAt!).substring(5)}');
    }
    return parts.join(' · ');
  }

  Future<void> _setGoal(BuildContext context, {Mission? m}) async {
    final goal = TextEditingController(text: m?.goal ?? '');
    var runs = m?.runsPerDay ?? Mission.defaultRuns;
    var tokens = m?.tokensPerDay ?? Mission.defaultTokens;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (d, set) => AlertDialog(
          title: Text(m == null ? 'Give ${widget.ownerName} a mission' : 'Mission'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              TextField(
                key: const ValueKey('mission-goal'),
                controller: goal,
                autofocus: true,
                minLines: 2,
                maxLines: 5,
                decoration: const InputDecoration(labelText: 'Goal', hintText: 'e.g. Find 20 wholesale suppliers for my shop and get quotes'),
              ),
              const SizedBox(height: Space.x4),
              Text(
                  '${widget.ownerName} plans, works and wakes by itself, also with Telesia closed. It asks you before money, approvals or anything '
                  'that cannot be undone.',
                  style: TextStyle(color: Palette.of(context).muted, fontSize: AppText.meta)),
              const SizedBox(height: Space.x3),
              Row(children: [
                const Expanded(child: Text('Runs a day')),
                IconButton(onPressed: runs > 1 ? () => set(() => runs = runs > 4 ? runs - 4 : 1) : null, icon: const Icon(Icons.remove_rounded)),
                Text('$runs'),
                IconButton(onPressed: runs < 96 ? () => set(() => runs = runs + 4 > 96 ? 96 : runs + 4) : null, icon: const Icon(Icons.add_rounded)),
              ]),
              Row(children: [
                const Expanded(child: Text('Tokens a day')),
                DropdownButton<int>(
                  value: const [100000, 200000, 400000, 1000000, 2000000, 5000000].contains(tokens) ? tokens : 400000,
                  items: [
                    for (final v in const [100000, 200000, 400000, 1000000, 2000000, 5000000]) DropdownMenuItem(value: v, child: Text(Missions.k(v))),
                  ],
                  onChanged: (v) => set(() => tokens = v ?? tokens),
                ),
              ]),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(m == null ? 'Start' : 'Save')),
          ],
        ),
      ),
    );
    if (ok != true || goal.text.trim().isEmpty) return;
    if (m == null || m.finished) {
      await Missions.I.start(widget.kind, widget.ownerId, goal.text.trim(), runsPerDay: runs, tokensPerDay: tokens);
    } else {
      await Missions.I.setGoal(m, goal.text.trim());
      if (runs != m.runsPerDay || tokens != m.tokensPerDay) await Missions.I.setBudget(m, runsPerDay: runs, tokensPerDay: tokens);
    }
  }

  Future<void> _answer(BuildContext context, Mission m, bool approved) async {
    final words = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(approved ? 'Approve' : 'Decline'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(m.needs),
          TextField(controller: words, decoration: const InputDecoration(hintText: 'Anything to add (optional)')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(approved ? 'Approve' : 'Decline')),
        ],
      ),
    );
    if (ok == true) await Missions.I.answer(m, approved, words: words.text);
  }

  Future<void> _stop(BuildContext context, Mission m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Stop this mission?'),
        content: Text('${widget.ownerName} stops working on it now and never wakes for it again. The plan and log stay.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('Stop', style: TextStyle(color: Palette.red))),
        ],
      ),
    );
    if (ok == true) await Missions.I.stop(m);
  }

  void _log(BuildContext context, Mission m) {
    showModalBottomSheet<void>(
      sheetAnimationStyle: SubMotion.sheet,
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (c) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (c, sc) => AnimatedBuilder(
          animation: Missions.I,
          builder: (c, _) => ListView(controller: sc, padding: const EdgeInsets.fromLTRB(Space.x5, 0, Space.x5, Space.x6), children: [
            Text('Activity', style: AppText.titleStyle.copyWith(color: Palette.of(c).text)),
            const SizedBox(height: Space.x2),
            for (final e in m.log.reversed)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Space.x1),
                child: Text.rich(TextSpan(children: [
                  TextSpan(text: '${Missions.when(e.at).substring(5)}  ', style: TextStyle(color: Palette.of(c).muted, fontSize: AppText.micro)),
                  TextSpan(text: '${e.kind}${e.who.isEmpty ? '' : ' · ${e.who}'}  ', style: const TextStyle(fontWeight: FontWeight.w600)),
                  TextSpan(text: e.text),
                ])),
              ),
          ]),
        ),
      ),
    );
  }

  static IconData _icon(String status) => switch (status) {
        'done' => Icons.check_circle_outline_rounded,
        'doing' => Icons.play_circle_outline_rounded,
        'blocked' => Icons.block_rounded,
        _ => Icons.radio_button_unchecked_rounded,
      };

  /// One honest line: will this really wake and reach the owner, or is something switched off? The usual silent
  /// failures (no notification permission, "Always on" off, a paused bot) are named here instead of being found
  /// weeks later.
  Widget _healthLine(BuildContext context, Palette p) {
    final warn = <String>[];
    if (_notifOk == false) warn.add('notifications are off');
    if (!AlwaysOn.I.on) warn.add('"Always on" is off');
    if (widget.kind == 'bot' && Bots.I.byId(widget.ownerId)?.active == false) warn.add('the bot is paused');
    if (warn.isEmpty) {
      return Text('Wakes and reports by itself, also with Telesia closed.',
          style: TextStyle(color: p.muted, fontSize: AppText.meta, height: 1.35));
    }
    return Text('Will not run reliably: ${warn.join(', ')}. Fix in Settings.',
        style: TextStyle(color: Palette.red, fontSize: AppText.meta, height: 1.35));
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Missions.I,
      builder: (context, _) {
        final p = Palette.of(context);
        final m = Missions.I.of(widget.kind, widget.ownerId);
        final head = Padding(
          padding: const EdgeInsets.only(top: 20, bottom: 6),
          child: Text('Mission', style: AppText.sectionStyle.copyWith(color: p.muted)),
        );
        if (m == null || m.finished) {
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            head,
            SurfaceRow(
              margin: const EdgeInsets.symmetric(vertical: 2),
              child: Padding(
                padding: const EdgeInsets.all(Space.x4),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (m != null) ...[
                    Text('Last mission ${m.status == 'done' ? 'done' : 'stopped'}: ${m.goal}', style: const TextStyle(fontWeight: FontWeight.w600)),
                    if (m.summary.isNotEmpty) Text(m.summary, style: TextStyle(color: p.muted, height: 1.4)),
                    TextButton(onPressed: () => _log(context, m), child: const Text('See its log')),
                  ] else
                    Text('Autonomy is off. Give ${widget.ownerName} a goal and it works toward it on its own, also with Telesia closed.',
                        style: TextStyle(color: p.muted, height: 1.4)),
                  const SizedBox(height: Space.x2),
                  FilledButton.tonal(
                    key: const ValueKey('mission-start'),
                    onPressed: () => _setGoal(context),
                    child: Text(m == null ? 'Set a goal' : 'New mission'),
                  ),
                ]),
              ),
            ),
          ]);
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          head,
          SurfaceRow(
            margin: const EdgeInsets.symmetric(vertical: 2),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Space.x4, Space.x2, Space.x2, Space.x3),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(
                    child: InkWell(
                      onTap: () => _setGoal(context, m: m),
                      child: Text(m.goal, style: const TextStyle(fontWeight: FontWeight.w600, height: 1.35)),
                    ),
                  ),
                  Switch(key: const ValueKey('mission-on'), value: m.on, onChanged: (v) => Missions.I.setOn(m, v)),
                ]),
                Text(_status(m), style: TextStyle(color: p.muted, fontSize: AppText.meta)),
                if (m.on) ...[
                  const SizedBox(height: Space.x1),
                  Builder(builder: (c) => _healthLine(c, p)),
                ],
                if (m.needs.isNotEmpty) ...[
                  const SizedBox(height: Space.x2),
                  Text('Needs you: ${m.needs}', style: const TextStyle(fontWeight: FontWeight.w600)),
                  Row(children: [
                    TextButton(onPressed: () => _answer(context, m, true), child: const Text('Approve')),
                    TextButton(onPressed: () => _answer(context, m, false), child: const Text('Decline')),
                  ]),
                ],
                if (m.summary.isNotEmpty) ...[
                  const SizedBox(height: Space.x2),
                  Text(m.summary, style: const TextStyle(height: 1.4)),
                ],
                if (m.plan.isNotEmpty) const SizedBox(height: Space.x2),
                for (final s in m.plan.take(12))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Icon(_icon(s.status), size: 16, color: s.status == 'done' ? p.muted : p.text),
                      const SizedBox(width: Space.x2),
                      Expanded(
                        child: Text('${s.text}${s.who.isEmpty ? '' : ' · ${s.who}'}',
                            style: TextStyle(color: s.status == 'done' ? p.muted : p.text, height: 1.35)),
                      ),
                    ]),
                  ),
                Wrap(spacing: 4, children: [
                  TextButton(onPressed: () => _log(context, m), child: const Text('Activity log')),
                  TextButton(onPressed: () => _setGoal(context, m: m), child: const Text('Budget')),
                  TextButton(
                    key: const ValueKey('mission-stop'),
                    onPressed: () => _stop(context, m),
                    child: const Text('Stop', style: TextStyle(color: Palette.red)),
                  ),
                ]),
              ]),
            ),
          ),
        ]);
      },
    );
  }
}
