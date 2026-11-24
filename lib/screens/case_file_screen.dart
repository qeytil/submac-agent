import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/case_report.dart';
import '../services/cases.dart';
import '../services/case_engine.dart';
import '../services/case_jobs.dart';
import '../theme.dart';
import '../ui/i18n.dart';
import '../ui/tokens.dart';
import '../widgets/sub_icon.dart';
import 'case_file_sheets.dart' as sheets;
import 'preview_screen.dart' show canPreview, openPreview;

/// The Case File (docs/investigation.md §11): brief, evidence, timeline, persons, findings and the report.
/// Quiet and text-first, no cards; editing happens in the sheets in `case_file_sheets.dart`.
class CaseFileScreen extends StatefulWidget {
  const CaseFileScreen({super.key, required this.caseId});
  final String caseId;

  @override
  State<CaseFileScreen> createState() => _CaseFileScreenState();
}

class _CaseFileScreenState extends State<CaseFileScreen> {
  Case? get _case => Cases.I.byId(widget.caseId);

  static String _day(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(tr('Case file'))),
      body: AnimatedBuilder(
        animation: Listenable.merge([Cases.I, CaseJobs.I]),
        builder: (context, _) {
          final c = _case;
          if (c == null) return const SizedBox.shrink();
          return ListView(
            padding: const EdgeInsetsDirectional.fromSTEB(Lux.gutter, Space.x2, Lux.gutter, Space.x8),
            children: [
              Text(c.numberLabel, style: AppText.metaStyle.copyWith(color: p.muted)),
              const SizedBox(height: 2),
              Text(c.title, style: Brand.serif(size: AppText.display, color: p.text, height: 1.2)),
              const SizedBox(height: Space.x1),
              Text('${c.statusWord}${c.locked ? ' · ${tr('Locked')}' : ''}', style: AppText.captionStyle.copyWith(color: p.muted)),
              const SizedBox(height: Space.x5),
              _brief(c),
              _evidence(c),
              _timeline(c),
              _persons(c),
              _findings(c),
              _work(c),
              _report(c),
            ],
          );
        },
      ),
    );
  }

  // ------------------------------------------------------------------ sections

  Widget _brief(Case c) {
    final p = Palette.of(context);
    return _Section(title: tr('Brief'), children: [
      Text(c.brief.isEmpty ? tr('No brief yet.') : c.brief, style: AppText.bodyStyle.copyWith(color: c.brief.isEmpty ? p.muted : p.text)),
      if (c.client.isNotEmpty) Text('${tr('Client')}: ${c.client}', style: AppText.captionStyle.copyWith(color: p.muted)),
      if (c.reportedTo.isNotEmpty) Text('${tr('Reported to')}: ${c.reportedTo}', style: AppText.captionStyle.copyWith(color: p.muted)),
      _action(tr('Edit brief'), () => sheets.editBriefSheet(context, c)),
      _action(c.locked ? tr('Unlock case') : tr('Lock case'), () => Cases.I.update(c, locked: !c.locked)),
    ]);
  }

  Widget _evidence(Case c) {
    final p = Palette.of(context);
    return _Section(title: tr('Evidence'), children: [
      if (c.exhibits.isEmpty) Text(tr('No evidence yet.'), style: AppText.bodyStyle.copyWith(color: p.muted)),
      for (final x in c.exhibits)
        _Line(
          title: x.name,
          subtitle: '${x.kind} · ${_day(x.addedAt)}${x.note.isNotEmpty ? ' · ${x.note}' : ''}',
          onTap: canPreview(x.path) ? () => openPreview(context, x.path) : null,
          onRemove: () => Cases.I.removeExhibit(c, x.id),
        ),
      _action(tr('Add exhibit'), () => _addExhibit(c)),
    ]);
  }

  Widget _timeline(Case c) {
    final p = Palette.of(context);
    final events = [...c.timeline]..sort((a, b) => b.at.compareTo(a.at));
    return _Section(title: tr('Timeline'), children: [
      if (events.isEmpty) Text(tr('Nothing on the timeline yet.'), style: AppText.bodyStyle.copyWith(color: p.muted)),
      for (final e in events)
        _Line(
          title: _day(e.at),
          subtitle: e.text,
          onRemove: () {
            c.timeline.removeWhere((x) => x.id == e.id);
            c.updated = DateTime.now();
            Cases.I.save();
          },
        ),
      _action(tr('Add note'), () => sheets.addNoteSheet(context, c)),
    ]);
  }

  Widget _persons(Case c) {
    final p = Palette.of(context);
    return _Section(title: tr('Persons'), children: [
      if (c.persons.isEmpty) Text(tr('No people yet.'), style: AppText.bodyStyle.copyWith(color: p.muted)),
      for (final person in c.persons)
        _Line(
          title: person.name,
          subtitle: '${person.role}${person.notes.isNotEmpty ? ' · ${person.notes}' : ''}',
          onRemove: () {
            c.persons.removeWhere((x) => x.id == person.id);
            c.updated = DateTime.now();
            Cases.I.save();
          },
        ),
      _action(tr('Add person'), () => sheets.addPersonSheet(context, c)),
    ]);
  }

  Widget _findings(Case c) {
    final p = Palette.of(context);
    return _Section(title: tr('Findings'), children: [
      if (c.findings.isEmpty) Text(tr('No findings yet.'), style: AppText.bodyStyle.copyWith(color: p.muted)),
      for (final f in c.findings)
        _Line(
          title: f.text,
          subtitle: '${f.confidence} · ${f.status}',
          onTap: () => sheets.editFindingSheet(context, c, f),
          onRemove: () {
            c.findings.removeWhere((x) => x.id == f.id);
            c.updated = DateTime.now();
            Cases.I.save();
          },
        ),
      _action(tr('Add finding'), () => sheets.addFindingSheet(context, c)),
    ]);
  }

  Widget _work(Case c) {
    final p = Palette.of(context);
    final jobs = CaseJobs.I.of(c.id);
    return _Section(title: tr('Work'), children: [
      Text(CaseEngine.note(), style: AppText.microStyle.copyWith(color: p.muted)),
      if (jobs.isEmpty) Text(tr('No jobs yet.'), style: AppText.bodyStyle.copyWith(color: p.muted)),
      for (final j in jobs)
        _Line(
          title: j.title,
          subtitle: '${j.status} · ${CaseEngine.word(j.lane)}${j.output.isNotEmpty ? ' · ${j.output}' : ''}',
        ),
      _action(tr('Clear finished'), () => CaseJobs.I.clearFinished(c.id)),
    ]);
  }

  Widget _report(Case c) {
    final p = Palette.of(context);
    return _Section(title: tr('Report'), children: [
      if (c.locked)
        Text(tr('This case is locked. Unlock it to build a report.'), style: AppText.bodyStyle.copyWith(color: p.muted))
      else ...[
        _action(tr('Case report (PDF)'), () => _buildReport(c)),
        _action(tr('Evidence PDF'), () => _buildEvidence(c)),
      ],
    ]);
  }

  // ------------------------------------------------------------------ actions

  Widget _action(String label, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.only(top: Space.x1),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton(
            style: TextButton.styleFrom(minimumSize: const Size(0, 34), padding: const EdgeInsets.symmetric(horizontal: Space.x2)),
            onPressed: onTap,
            child: Text(label, style: AppText.bodyStyle.copyWith(color: Palette.of(context).text, fontWeight: FontWeight.w600)),
          ),
        ),
      );

  Future<void> _addExhibit(Case c) async {
    final res = await FilePicker.pickFiles(allowMultiple: true, withData: false);
    if (res == null) return;
    for (final f in res.files) {
      final path = f.path;
      if (path != null) await Cases.I.addExhibit(c, path);
    }
  }

  Future<void> _buildReport(Case c) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(content: Text(tr('Building the report…'))));
    final path = await CaseReport.makeReport(c);
    if (!mounted) return;
    if (path == null) {
      messenger.showSnackBar(SnackBar(content: Text(tr('Could not build the report.'))));
      return;
    }
    if (canPreview(path)) await openPreview(context, path);
  }

  Future<void> _buildEvidence(Case c) async {
    final messenger = ScaffoldMessenger.of(context);
    final path = await CaseReport.makeEvidencePdf(c);
    if (!mounted) return;
    if (path == null) {
      messenger.showSnackBar(SnackBar(content: Text(tr('No image exhibits to bundle.'))));
      return;
    }
    if (canPreview(path)) await openPreview(context, path);
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.x4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.only(bottom: Space.x1),
          child: Text(title, style: AppText.sectionStyle.copyWith(color: Palette.of(context).faint)),
        ),
        ...children,
      ]),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.title, this.subtitle = '', this.onTap, this.onRemove});
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return InkWell(
      borderRadius: Radii.fieldAll,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Space.x2),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(title, style: AppText.bodyStyle.copyWith(color: p.text, fontWeight: FontWeight.w600)),
              if (subtitle.isNotEmpty)
                Padding(padding: const EdgeInsets.only(top: 2), child: Text(subtitle, style: AppText.captionStyle.copyWith(color: p.muted))),
            ]),
          ),
          if (onRemove != null)
            IconButton(
              tooltip: tr('Remove'),
              visualDensity: VisualDensity.compact,
              onPressed: onRemove,
              icon: SubIcon('close', size: IconSize.md, color: p.muted),
            ),
        ]),
      ),
    );
  }
}
