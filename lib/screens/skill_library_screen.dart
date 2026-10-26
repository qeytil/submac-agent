import 'package:flutter/material.dart';

import '../services/bots.dart';
import '../services/skill_library.dart';
import '../widgets/motion.dart';
import '../theme.dart';
import '../widgets/lux_kit.dart';
import '../widgets/markdown_view.dart';
import '../widgets/pill_kit.dart';
import '../ui/tokens.dart';

/// The shared skill library: browse, read and install skills for SubMac or for one of the bots.
class SkillLibraryScreen extends StatefulWidget {
  const SkillLibraryScreen({super.key, this.target = SkillLibrary.agent});
  /// SkillLibrary.agent, or a bot id.
  final String target;

  @override
  State<SkillLibraryScreen> createState() => _SkillLibraryScreenState();
}

class _SkillLibraryScreenState extends State<SkillLibraryScreen> {
  String _q = '';
  String _cat = 'All';

  String get _who => widget.target == SkillLibrary.agent ? 'SubMac' : (Bots.I.byId(widget.target)?.name ?? 'this bot');

  @override
  void initState() {
    super.initState();
    if (SkillLibrary.I.skills.isEmpty) SkillLibrary.I.refresh();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return AnimatedBuilder(
      animation: SkillLibrary.I,
      builder: (context, _) {
        final lib = SkillLibrary.I;
        final cats = lib.categories;
        final tabs = ['All', 'Installed', for (final c in cats) SkillLibrary.label(c)];
        final catId = cats.where((c) => SkillLibrary.label(c) == _cat).firstOrNull ?? '';
        List<LibSkill> list;
        if (_q.trim().isNotEmpty) {
          list = lib.search(_q, cat: catId, limit: 60);
        } else if (_cat == 'Installed') {
          list = [for (final id in lib.of(widget.target)) lib.byId(id)].whereType<LibSkill>().toList();
        } else {
          list = catId.isEmpty ? lib.skills : lib.skills.where((s) => s.cat == catId).toList();
        }
        return Scaffold(
          appBar: AppBar(
            toolbarHeight: 48,
            centerTitle: true,
            title: Text(widget.target == SkillLibrary.agent ? 'Skill library' : 'Skills for $_who',
                style: TextStyle(color: p.text, fontSize: AppText.lead, fontWeight: FontWeight.w600)),
          ),
          body: RefreshIndicator(
            onRefresh: lib.refresh,
            child: ListView(padding: const EdgeInsets.only(bottom: 32), children: [
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(16, 4, 16, 10),
                child: PillSearch(hint: 'Search ${lib.skills.isEmpty ? '' : '${lib.skills.length} '}skills', onChanged: (v) => setState(() => _q = v)),
              ),
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(20, 0, 20, 12),
                child: Text(
                  'Expert playbooks $_who reads before a task. Installed ones are always at hand; '
                  'the rest are found when a task needs them.',
                  style: TextStyle(color: p.muted, fontSize: AppText.meta, height: 1.35),
                ),
              ),
              CategoryTabs(tabs: tabs, selected: _cat, onSelect: (c) => setState(() => _cat = c)),
              const SizedBox(height: 8),
              if (lib.loading && lib.skills.isEmpty)
                const SkeletonList(rows: 5),
              if (!lib.loading && lib.skills.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(children: [
                    Text(lib.error ?? 'The library is empty.', textAlign: TextAlign.center, style: TextStyle(color: p.muted)),
                    const SizedBox(height: 12),
                    PillButton('Try again', onTap: lib.refresh),
                  ]),
                ),
              for (final s in list.take(200))
                CardRow(
                  title: s.name,
                  subtitle: '${s.sub.isEmpty ? SkillLibrary.label(s.cat) : s.sub} · ${s.desc}',
                  leading: Monogram(s.sub.isEmpty ? s.name : s.sub),
                  action: lib.has(widget.target, s.id) ? 'Added' : 'Add',
                  done: lib.has(widget.target, s.id),
                  onAction: () => _toggle(s),
                  onTap: () => _open(context, s),
                ),
              if (lib.skills.isNotEmpty && list.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(_cat == 'Installed' ? 'Nothing installed yet.' : 'No skill matches that.',
                      textAlign: TextAlign.center, style: TextStyle(color: p.muted)),
                ),
            ]),
          ),
        );
      },
    );
  }

  Future<void> _toggle(LibSkill s, [String? target]) async {
    final t = target ?? widget.target;
    if (SkillLibrary.I.has(t, s.id)) {
      await SkillLibrary.I.uninstall(t, s.id);
      return;
    }
    final e = await SkillLibrary.I.install(t, s.id);
    if (e != null && mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e)));
  }

  Future<void> _open(BuildContext context, LibSkill s) async {
    final p = Palette.of(context);
    final body = SkillLibrary.I.body(s.id);
    await showModalBottomSheet<void>(
      sheetAnimationStyle: SubMotion.sheet,
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        maxChildSize: 0.95,
        builder: (ctx, scroll) => AnimatedBuilder(
          animation: SkillLibrary.I,
          builder: (ctx, _) => ListView(controller: scroll, padding: const EdgeInsetsDirectional.fromSTEB(20, 0, 20, 30), children: [
            Text(s.name, style: Brand.serif(size: 24, color: p.text)),
            const SizedBox(height: 4),
            Text('${SkillLibrary.label(s.cat)}${s.sub.isEmpty ? '' : ' · ${s.sub}'}${s.level == 'pro' ? ' · Pro' : ''}',
                style: TextStyle(color: p.muted, fontSize: AppText.meta)),
            if (s.powers.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('Uses: ${s.powers.join(', ')}', style: TextStyle(color: p.muted, fontSize: AppText.micro)),
              ),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: p.text, foregroundColor: p.bg),
                  onPressed: () => _toggle(s),
                  child: Text(SkillLibrary.I.has(widget.target, s.id) ? 'Remove from $_who' : 'Add to $_who'),
                ),
              ),
              if (widget.target == SkillLibrary.agent && Bots.I.hired.isNotEmpty) ...[
                const SizedBox(width: 10),
                OutlinedButton(onPressed: () => _giveToBot(ctx, s), child: const Text('Give to a bot')),
              ],
            ]),
            const SizedBox(height: 18),
            FutureBuilder<String?>(
              future: body,
              builder: (ctx, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const SkeletonList(rows: 3, leading: false, padding: EdgeInsets.zero);
                }
                final t = snap.data;
                if (t == null || t.isEmpty) return Text(s.desc, style: TextStyle(color: p.text, height: 1.4));
                return MarkdownView(t);
              },
            ),
          ]),
        ),
      ),
    );
  }

  Future<void> _giveToBot(BuildContext context, LibSkill s) async {
    final bots = Bots.I.hired.toList();
    final id = await showLuxChoices<String>(context, choices: [
      for (final b in bots) LuxChoice(b.id, b.name, sub: b.role),
    ], selected: bots.where((b) => SkillLibrary.I.has(b.id, s.id)).map((b) => b.id).firstOrNull);
    if (id == null) return;
    if (SkillLibrary.I.has(id, s.id)) return;
    final e = await SkillLibrary.I.install(id, s.id);
    if (mounted) {
      ScaffoldMessenger.of(this.context).showSnackBar(SnackBar(content: Text(e ?? '${Bots.I.byId(id)?.name} has "${s.name}" now.')));
    }
  }
}
