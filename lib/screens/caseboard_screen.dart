import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../services/cases.dart';
import '../theme.dart';
import '../ui/i18n.dart';
import '../ui/tokens.dart';
import '../widgets/motion.dart';

/// The Investigation board: every case as a quiet, text-first row. No cards (ui-rules.md). A case opens the
/// case room; a new case is three fields.
class CaseboardScreen extends StatefulWidget {
  const CaseboardScreen({super.key});

  @override
  State<CaseboardScreen> createState() => _CaseboardScreenState();
}

class _CaseboardScreenState extends State<CaseboardScreen> {
  String _filter = 'all';

  bool _match(Case c) => switch (_filter) {
        'open' => c.isOpen,
        'cold' => c.status == 'cold',
        'solved' => c.status == 'solved',
        _ => true,
      };

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(tr('Investigation'))),
      body: AnimatedBuilder(
        animation: Cases.I,
        builder: (context, _) {
          final all = Cases.I.list;
          final open = all.where((c) => c.isOpen).length;
          final cold = all.where((c) => c.status == 'cold').length;
          final solved = all.where((c) => c.status == 'solved').length;
          final shown = all.where(_match).toList();
          return ListView(
            padding: const EdgeInsetsDirectional.fromSTEB(Space.x4, Space.x3, Space.x4, Space.x6),
            children: [
              Text('$open open · $cold cold · $solved solved', style: AppText.metaStyle.copyWith(color: p.muted)),
              const SizedBox(height: Space.x3),
              Row(children: [
                _Filter(label: 'All', on: _filter == 'all', onTap: () => setState(() => _filter = 'all')),
                _Filter(label: 'Open', on: _filter == 'open', onTap: () => setState(() => _filter = 'open')),
                _Filter(label: 'Cold', on: _filter == 'cold', onTap: () => setState(() => _filter = 'cold')),
                _Filter(label: 'Solved', on: _filter == 'solved', onTap: () => setState(() => _filter = 'solved')),
              ]),
              const SizedBox(height: Space.x2),
              if (shown.isEmpty)
                Padding(
                  padding: const EdgeInsetsDirectional.only(top: Space.x6),
                  child: Text(all.isEmpty ? tr('No cases yet. Open one to begin.') : tr('Nothing here.'),
                      textAlign: TextAlign.center, style: AppText.metaStyle.copyWith(color: p.muted)),
                ),
              for (final c in shown) _CaseRow(item: c),
              const SizedBox(height: Space.x2),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton(
                  onPressed: () => _newCase(context),
                  child: Text(tr('New case'), style: AppText.bodyStyle.copyWith(color: p.text, fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _newCase(BuildContext context) async {
    final title = TextEditingController();
    final brief = TextEditingController();
    final reportedTo = TextEditingController();
    final ok = await showModalBottomSheet<bool>(
      sheetAnimationStyle: SubMotion.sheet,
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: EdgeInsetsDirectional.fromSTEB(Space.x5, 0, Space.x5, MediaQuery.of(ctx).viewInsets.bottom + Space.x5),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('New case'), style: AppText.titleStyle.copyWith(color: Palette.of(ctx).text)),
          const SizedBox(height: Space.x3),
          TextField(controller: title, autofocus: true, textCapitalization: TextCapitalization.sentences, decoration: const InputDecoration(labelText: 'What is it about')),
          const SizedBox(height: Space.x2),
          TextField(controller: brief, minLines: 2, maxLines: 4, textCapitalization: TextCapitalization.sentences, decoration: const InputDecoration(labelText: 'Brief')),
          const SizedBox(height: Space.x2),
          TextField(controller: reportedTo, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Reported to (optional)')),
          const SizedBox(height: Space.x4),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('Open case'), style: AppText.bodyStyle.copyWith(color: Palette.of(ctx).text, fontWeight: FontWeight.w600)),
            ),
          ),
        ]),
      ),
    );
    final t = title.text.trim();
    final b = brief.text;
    final r = reportedTo.text;
    title.dispose();
    brief.dispose();
    reportedTo.dispose();
    if (ok != true || t.isEmpty || !context.mounted) return;
    final nav = Navigator.of(context);
    await context.read<AppState>().createCase(title: t, brief: b, reportedTo: r);
    if (nav.canPop()) nav.pop();
  }
}

class _Filter extends StatelessWidget {
  const _Filter({required this.label, required this.on, required this.onTap});
  final String label;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: Space.x3),
      child: InkWell(
        borderRadius: Radii.fieldAll,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsetsDirectional.symmetric(horizontal: Space.x1, vertical: Space.x1),
          child: Text(label, style: AppText.metaStyle.copyWith(color: on ? p.text : p.muted, fontWeight: on ? FontWeight.w600 : FontWeight.w400)),
        ),
      ),
    );
  }
}

class _CaseRow extends StatelessWidget {
  const _CaseRow({required this.item});
  final Case item;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final state = context.read<AppState>();
    final bits = [
      item.numberLabel,
      item.statusWord,
      if (item.exhibits.isNotEmpty) '${item.exhibits.length} ${item.exhibits.length == 1 ? 'exhibit' : 'exhibits'}',
      if (item.openQuestions > 0) '${item.openQuestions} open ${item.openQuestions == 1 ? 'question' : 'questions'}',
    ];
    return InkWell(
      key: ValueKey('case-${item.id}'),
      onTap: () async {
        final nav = Navigator.of(context);
        await state.openCase(item.id);
        if (nav.canPop()) nav.pop();
      },
      child: Padding(
        padding: const EdgeInsetsDirectional.symmetric(vertical: Space.x3),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.bodyStyle.copyWith(color: p.text, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(bits.join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.captionStyle.copyWith(color: p.muted)),
        ]),
      ),
    );
  }
}
