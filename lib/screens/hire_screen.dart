import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../services/bot_powers.dart';
import '../services/bots.dart';
import '../services/roles.dart';
import '../services/trust.dart';
import '../theme.dart';
import '../widgets/lux_kit.dart';
import '../ui/i18n.dart';
import '../ui/tokens.dart';
import '../widgets/sub_avatar.dart';
import '../widgets/surface.dart';
import 'bot_store_screen.dart';

/// Make or edit a bot (owner, 2026-10-24: "making new bot is still in the old style … make it professional like grok
/// bot"). One calm page on the sky, after Grok Bot's create screen (docs/grok-bots-research.md): the face on top with its
/// colour and shape right under it, then name, role, a short description and instructions on one shared surface, what it
/// may use as plain switches, and one clear primary button. Ready roles sit underneath as suggestions that fill the form;
/// nothing is created until the owner taps Create.
///
/// A new bot opens its chat, says in a line what it can take on and suggests one or two first tasks (BotAsk), as a new Grok
/// Bot does. No dots, no borders, no app name.
class HireScreen extends StatefulWidget {
  const HireScreen({super.key, this.editBotId});

  /// Edit this bot instead of making a new one.
  final String? editBotId;

  @override
  State<HireScreen> createState() => _HireScreenState();
}

class _HireScreenState extends State<HireScreen> {
  final _name = TextEditingController();
  final _role = TextEditingController();
  final _about = TextEditingController();
  final _rules = TextEditingController();
  late AvatarSpec _look;
  final Set<String> _off = {};
  BotRole? _from;
  Bot? _described;
  bool _busy = false;

  Bot? get _editing => widget.editBotId == null ? null : Bots.I.byId(widget.editBotId!);
  bool get _isEdit => _editing != null;

  @override
  void initState() {
    super.initState();
    final b = _editing;
    if (b != null) {
      _name.text = b.name;
      _role.text = b.role;
      _about.text = b.mission;
      _rules.text = b.instructions;
      _off.addAll(b.powersOff);
      _look = AvatarSpec.parse(b.look) ?? AvatarSpec.seeded(b.id);
    } else {
      _look = AvatarSpec.seeded('new-${DateTime.now().millisecondsSinceEpoch}');
    }
    _name.addListener(_changed);
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    _name.removeListener(_changed);
    for (final c in [_name, _role, _about, _rules]) {
      c.dispose();
    }
    // A described colleague nobody created after all is not left behind.
    final d = _described;
    if (d != null && !d.active && d.convId.isEmpty && !_saved) Bots.I.remove(d);
    super.dispose();
  }

  bool _saved = false;

  void _useRole(BotRole r) {
    setState(() {
      _from = r;
      _name.text = RoleHire.freeName(r.name, Bots.I.bots.map((b) => b.name));
      _role.text = r.title;
      _about.text = r.mission.isNotEmpty ? r.mission : r.pitch;
      _look = AvatarSpec.seeded(r.id);
    });
  }

  Future<void> _describe() async {
    final ctrl = TextEditingController();
    final desc = await showModalBottomSheet<String>(
      sheetAnimationStyle: SubMotion.sheet,
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        final p = Palette.of(ctx);
        return Padding(
          padding: EdgeInsetsDirectional.fromSTEB(Space.x5, 0, Space.x5, MediaQuery.of(ctx).viewInsets.bottom + Space.x5),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(tr('Describe the job'), style: AppText.titleStyle.copyWith(color: p.text, fontWeight: FontWeight.w600)),
            const SizedBox(height: Space.x1),
            Text(tr('A line or two. The form fills itself, and you can change anything.'), style: AppText.metaStyle.copyWith(color: p.muted)),
            const SizedBox(height: Space.x4),
            TextField(
              controller: ctrl,
              autofocus: true,
              minLines: 2,
              maxLines: 5,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(hintText: tr('e.g. A bookkeeper for my phone shop who tracks daily sales')),
            ),
            const SizedBox(height: Space.x4),
            _PrimaryButton(label: tr('Fill the form'), onPressed: () => Navigator.pop(ctx, ctrl.text)),
          ]),
        );
      },
    );
    if (desc == null || desc.trim().isEmpty || !mounted) return;
    setState(() => _busy = true);
    final b = await context.read<AppState>().createBotFromText(desc.trim());
    if (!mounted) return;
    setState(() => _busy = false);
    if (b == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('I could not read that. Please try once more.'))));
      return;
    }
    final old = _described;
    if (old != null && old != b && !old.active && old.convId.isEmpty) Bots.I.remove(old);
    setState(() {
      _described = b;
      _from = null;
      _name.text = b.name;
      _role.text = b.role;
      _about.text = b.mission;
      if (b.instructions.trim().isNotEmpty) _rules.text = b.instructions.trim();
    });
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty || _busy) return;
    final state = context.read<AppState>();
    final nav = Navigator.of(context);
    setState(() => _busy = true);
    final edit = _editing;
    if (edit != null) {
      edit
        ..name = name
        ..role = _role.text.trim().isEmpty ? edit.role : _role.text.trim()
        ..mission = _about.text.trim()
        ..instructions = _rules.text.trim();
      edit.powersOff
        ..clear()
        ..addAll(_off);
      await Bots.I.setLook(edit, _look == AvatarSpec.seeded(edit.id) ? null : _look.look);
      await Bots.I.save();
      _saved = true;
      nav.pop();
      return;
    }
    final role = _role.text.trim().isEmpty ? tr('Assistant') : _role.text.trim();
    final r = _from;
    Bot b;
    final d = _described;
    if (d != null) {
      b = d
        ..name = name
        ..role = role
        ..mission = _about.text.trim();
    } else {
      b = await Bots.I.create({
        'name': RoleHire.freeName(name, Bots.I.bots.map((x) => x.name)),
        'role': role,
        'persona': r?.persona ??
            'You are a calm, capable $role: precise, plain-spoken and reliable. You work like a trusted senior colleague and '
                'keep the owner informed in a few clear lines.',
        'mission': _about.text.trim(),
        'icon': r?.icon ?? 'person',
        'proactivity': r?.proactivity ?? 'balanced',
        'heartbeat_hours': 0,
        'routines': const [],
      });
      if (r != null && r.voice.isNotEmpty) b.voice = r.voice;
    }
    b
      ..instructions = _rules.text.trim()
      ..trust = BotTrust.levelNew;
    b.powersOff
      ..clear()
      ..addAll(_off);
    await Bots.I.setLook(b, _look.look);
    await Bots.I.save();
    _saved = true;
    nav.popUntil((x) => x.isFirst);
    // It opens its chat and suggests a first task; it starts work when the owner gives it some (BotAsk).
    final e = await state.hireBot(b);
    if (e != null) state.showBanner(e);
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final ready = _name.text.trim().isNotEmpty && !_busy;
    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? tr('Edit bot') : tr('New bot'))),
      body: Stack(children: [
        ListView(
          key: const ValueKey('bot-editor'),
          padding: const EdgeInsetsDirectional.fromSTEB(Space.x4, Space.x2, Space.x4, Space.x8),
          children: [
            _Face(look: _look, onChanged: (s) => setState(() => _look = s)),
            const SizedBox(height: Space.x5),
            SurfaceGroup(padding: const EdgeInsets.symmetric(vertical: Space.x2), children: [
              _Field(label: tr('Name'), controller: _name, hint: tr('e.g. Hodan'), words: true, fieldKey: const ValueKey('bot-name')),
              _Field(label: tr('Role'), controller: _role, hint: tr('e.g. Sales assistant'), words: true),
              _Field(label: tr('What it does'), controller: _about, hint: tr('One or two lines about its job'), lines: 3),
              _Field(
                  label: tr('Instructions'),
                  controller: _rules,
                  hint: tr('How it should work: tone, rules, what to ask you before doing'),
                  lines: 6),
            ]),
            const SizedBox(height: Space.x4),
            _Label(tr('Can use')),
            SurfaceGroup(children: [
              for (final g in BotPowers.all)
                SwitchListTile(
                  key: ValueKey('power-$g'),
                  contentPadding: const EdgeInsetsDirectional.fromSTEB(Space.x4, 0, Space.x3, 0),
                  title: Text(tr(BotPowers.labels[g]!), style: AppText.bodyStyle.copyWith(color: p.text)),
                  subtitle: Text(tr(BotPowers.blurbs[g]!), style: AppText.microStyle.copyWith(color: p.muted)),
                  value: !_off.contains(g),
                  onChanged: (v) => setState(() => v ? _off.remove(g) : _off.add(g)),
                ),
            ]),
            const SizedBox(height: Space.x6),
            _PrimaryButton(
              key: const ValueKey('bot-save'),
              label: _isEdit ? tr('Save') : tr('Create'),
              onPressed: ready ? _save : null,
            ),
            const SizedBox(height: Space.x3),
            Text(
              tr('Give it a task in its chat. It carries the work through and comes back when it needs you.'),
              textAlign: TextAlign.center,
              style: AppText.microStyle.copyWith(color: p.muted),
            ),
            if (!_isEdit) ...[
              const SizedBox(height: Space.x8),
              _Label(tr('Suggestions')),
              SurfaceGroup(children: [
                for (final r in BotRoles.all)
                  _SuggestionRow(
                    face: SubAvatar(spec: AvatarSpec.seeded(r.id), size: 40),
                    title: tr(r.title),
                    sub: tr(r.pitch),
                    onTap: () => _useRole(r),
                  ),
              ]),
              const SizedBox(height: Space.x4),
              _Label(tr('More ways')),
              SurfaceGroup(children: [
                _SuggestionRow(title: tr('Describe your own'), sub: tr('Say the job in a line or two'), onTap: _describe),
                _SuggestionRow(
                    title: tr('Bot Store'),
                    sub: tr('Ready-made bots'),
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BotStoreScreen()))),
                _SuggestionRow(title: tr('Add from code or file'), sub: tr('A bot someone shared'), onTap: () => addSharedBot(context)),
              ]),
            ],
          ],
        ),
        if (_busy)
          Positioned.fill(
            child: ColoredBox(
              color: p.bg.withValues(alpha: 0.6),
              child: Center(child: SizedBox(width: IconSize.xl, height: IconSize.xl, child: CircularProgressIndicator(strokeWidth: 2, color: p.text))),
            ),
          ),
      ]),
    );
  }
}

/// The bot's face, large, with its colours and shapes right under it (as on Grok's create screen). The chosen one is
/// shown full strength and the rest stay faint: nothing is ringed, boxed or dotted.
class _Face extends StatelessWidget {
  const _Face({required this.look, required this.onChanged});
  final AvatarSpec look;
  final ValueChanged<AvatarSpec> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget pick({required bool on, required Widget child, required VoidCallback tap, required String tip}) => Semantics(
          button: true,
          selected: on,
          label: tip,
          child: LuxTap(
            onTap: tap,
            child: Padding(
              padding: const EdgeInsets.all(Space.x1),
              child: AnimatedOpacity(
                duration: SubMotion.quick,
                opacity: on ? 1 : 0.38,
                child: AnimatedScale(duration: SubMotion.quick, scale: on ? 1.08 : 1, child: child),
              ),
            ),
          ),
        );
    return Column(children: [
      AnimatedSwitcher(
        duration: SubMotion.of(context, SubMotion.base),
        switchInCurve: SubMotion.settle,
        switchOutCurve: SubMotion.leave,
        child: SubAvatar(key: ValueKey(look.look), spec: look, size: 96),
      ),
      const SizedBox(height: Space.x4),
      Wrap(alignment: WrapAlignment.center, spacing: Space.x1, runSpacing: Space.x1, children: [
        for (final c in AvatarSpec.colors)
          pick(
            on: look.color == c,
            tip: tr(AvatarSpec.colorNames[c] ?? c),
            tap: () => onChanged(look.copyWith(color: c)),
            child: SizedBox.square(
              dimension: IconSize.xl,
              child: DecoratedBox(decoration: BoxDecoration(color: AvatarSpec.colorOf(c), shape: BoxShape.circle)),
            ),
          ),
      ]),
      const SizedBox(height: Space.x2),
      Wrap(alignment: WrapAlignment.center, spacing: Space.x1, runSpacing: Space.x1, children: [
        for (final s in AvatarSpec.shapes)
          pick(on: look.shape == s, tip: s, tap: () => onChanged(look.copyWith(shape: s)), child: SubAvatar(spec: look.copyWith(shape: s), size: 32)),
      ]),
    ]);
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(Space.x2, Space.x2, Space.x2, Space.x1),
        child: Text(text, style: AppText.sectionStyle.copyWith(color: Palette.of(context).muted)),
      );
}

/// One labelled field on the shared surface: a quiet label over a borderless field.
class _Field extends StatelessWidget {
  const _Field({required this.label, required this.controller, this.hint = '', this.lines = 1, this.words = false, this.fieldKey});
  final String label;
  final TextEditingController controller;
  final String hint;
  final int lines;
  final bool words;
  final Key? fieldKey;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(Space.x4, Space.x2, Space.x4, Space.x2),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(label, style: AppText.metaStyle.copyWith(color: p.muted, fontWeight: FontWeight.w600)),
        const SizedBox(height: Space.x1),
        TextField(
          key: fieldKey,
          controller: controller,
          minLines: 1,
          maxLines: lines,
          textCapitalization: words ? TextCapitalization.words : TextCapitalization.sentences,
          style: AppText.bodyStyle.copyWith(color: p.text),
          decoration: InputDecoration(hintText: hint, isDense: true),
        ),
      ]),
    );
  }
}

class _SuggestionRow extends StatelessWidget {
  const _SuggestionRow({this.face, required this.title, required this.sub, required this.onTap});
  final Widget? face;
  final String title;
  final String sub;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return LuxTap(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(Space.x4, Space.x3, Space.x4, Space.x3),
        child: Row(children: [
          if (face != null) ...[SizedBox.square(dimension: 40, child: Center(child: face)), const SizedBox(width: Space.x3)],
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: AppText.bodyStyle.copyWith(color: p.text, fontWeight: FontWeight.w600)),
              Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.microStyle.copyWith(color: p.muted)),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// The one primary action: an ink pill with paper text (no outline, no shadow).
class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({super.key, required this.label, required this.onPressed});
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return FilledButton(
      style: FilledButton.styleFrom(
        backgroundColor: p.text,
        foregroundColor: p.bg,
        disabledBackgroundColor: p.text.withValues(alpha: 0.12),
        disabledForegroundColor: p.faint,
        minimumSize: const Size.fromHeight(52),
        shape: const StadiumBorder(),
      ),
      onPressed: onPressed,
      child: Text(label),
    );
  }
}
