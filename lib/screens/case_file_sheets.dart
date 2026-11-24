import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../services/cases.dart';
import '../theme.dart';
import '../ui/i18n.dart';
import '../ui/tokens.dart';

/// The Case File's editing sheets (docs/investigation.md §11): brief, timeline note, person, finding.
/// Each mutates the case and saves it; the screen rebuilds through its `Cases.I` listener.

const _roles = ['subject', 'witness', 'contact', 'unknown'];
const _conf = ['low', 'med', 'high'];
const _findingStates = ['open', 'confirmed', 'dropped'];
const _statuses = ['open', 'active', 'cold', 'solved', 'closed'];

String _day(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

Future<void> editBriefSheet(BuildContext context, Case c) async {
  final title = TextEditingController(text: c.title);
  final brief = TextEditingController(text: c.brief);
  final client = TextEditingController(text: c.client);
  final reportedTo = TextEditingController(text: c.reportedTo);
  var status = c.status;
  final ok = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    sheetAnimationStyle: SubMotion.sheet,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheet) => Padding(
        padding: EdgeInsetsDirectional.fromSTEB(Space.x5, 0, Space.x5, MediaQuery.of(ctx).viewInsets.bottom + Space.x5),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Edit brief'), style: AppText.titleStyle.copyWith(color: Palette.of(ctx).text)),
          const SizedBox(height: Space.x3),
          TextField(controller: title, textCapitalization: TextCapitalization.sentences, decoration: InputDecoration(labelText: tr('What is it about'))),
          const SizedBox(height: Space.x2),
          TextField(controller: brief, minLines: 3, maxLines: 6, textCapitalization: TextCapitalization.sentences, decoration: InputDecoration(labelText: tr('Brief'))),
          const SizedBox(height: Space.x2),
          TextField(controller: client, textCapitalization: TextCapitalization.words, decoration: InputDecoration(labelText: tr('Client (optional)'))),
          const SizedBox(height: Space.x2),
          TextField(controller: reportedTo, textCapitalization: TextCapitalization.words, decoration: InputDecoration(labelText: tr('Reported to (optional)'))),
          const SizedBox(height: Space.x3),
          _ChoiceRow(label: tr('Status'), options: _statuses, value: status, onPick: (v) => setSheet(() => status = v)),
          const SizedBox(height: Space.x3),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Save'), style: AppText.bodyStyle.copyWith(fontWeight: FontWeight.w600))),
          ),
        ]),
      ),
    ),
  );
  final t = title.text, b = brief.text, cl = client.text.trim(), r = reportedTo.text;
  title.dispose();
  brief.dispose();
  client.dispose();
  reportedTo.dispose();
  if (ok != true) return;
  await Cases.I.update(c, title: t, brief: b, reportedTo: r, status: status);
  c.client = cl;
  c.updated = DateTime.now();
  await Cases.I.save();
}

Future<void> addNoteSheet(BuildContext context, Case c) async {
  final text = TextEditingController();
  var at = DateTime.now();
  final ok = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    sheetAnimationStyle: SubMotion.sheet,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheet) => Padding(
        padding: EdgeInsetsDirectional.fromSTEB(Space.x5, 0, Space.x5, MediaQuery.of(ctx).viewInsets.bottom + Space.x5),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Add to the timeline'), style: AppText.titleStyle.copyWith(color: Palette.of(ctx).text)),
          const SizedBox(height: Space.x3),
          TextField(controller: text, autofocus: true, minLines: 1, maxLines: 4, textCapitalization: TextCapitalization.sentences, decoration: InputDecoration(labelText: tr('What happened'))),
          const SizedBox(height: Space.x1),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              onPressed: () async {
                final d = await showDatePicker(context: ctx, initialDate: at, firstDate: DateTime(2000), lastDate: DateTime(2100));
                if (d != null) setSheet(() => at = d);
              },
              child: Text(_day(at), style: AppText.bodyStyle.copyWith(color: Palette.of(ctx).muted)),
            ),
          ),
          const SizedBox(height: Space.x2),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Add'), style: AppText.bodyStyle.copyWith(fontWeight: FontWeight.w600))),
          ),
        ]),
      ),
    ),
  );
  final t = text.text.trim();
  text.dispose();
  if (ok != true || t.isEmpty) return;
  c.timeline.add(CaseEvent(id: const Uuid().v4(), at: at, text: t));
  c.updated = DateTime.now();
  await Cases.I.save();
}

Future<void> addPersonSheet(BuildContext context, Case c) async {
  final name = TextEditingController();
  final notes = TextEditingController();
  var role = 'unknown';
  final ok = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    sheetAnimationStyle: SubMotion.sheet,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheet) => Padding(
        padding: EdgeInsetsDirectional.fromSTEB(Space.x5, 0, Space.x5, MediaQuery.of(ctx).viewInsets.bottom + Space.x5),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Add a person'), style: AppText.titleStyle.copyWith(color: Palette.of(ctx).text)),
          const SizedBox(height: Space.x3),
          TextField(controller: name, autofocus: true, textCapitalization: TextCapitalization.words, decoration: InputDecoration(labelText: tr('Name'))),
          const SizedBox(height: Space.x2),
          TextField(controller: notes, minLines: 1, maxLines: 4, textCapitalization: TextCapitalization.sentences, decoration: InputDecoration(labelText: tr('Notes (optional)'))),
          const SizedBox(height: Space.x3),
          _ChoiceRow(label: tr('Role'), options: _roles, value: role, onPick: (v) => setSheet(() => role = v)),
          const SizedBox(height: Space.x3),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Add'), style: AppText.bodyStyle.copyWith(fontWeight: FontWeight.w600))),
          ),
        ]),
      ),
    ),
  );
  final n = name.text.trim(), note = notes.text.trim();
  name.dispose();
  notes.dispose();
  if (ok != true || n.isEmpty) return;
  c.persons.add(CasePerson(id: const Uuid().v4(), name: n, role: role, notes: note));
  c.updated = DateTime.now();
  await Cases.I.save();
}

Future<void> addFindingSheet(BuildContext context, Case c) async {
  final text = TextEditingController();
  var confidence = 'low';
  var status = 'open';
  final ok = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    sheetAnimationStyle: SubMotion.sheet,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheet) => Padding(
        padding: EdgeInsetsDirectional.fromSTEB(Space.x5, 0, Space.x5, MediaQuery.of(ctx).viewInsets.bottom + Space.x5),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Add a finding'), style: AppText.titleStyle.copyWith(color: Palette.of(ctx).text)),
          const SizedBox(height: Space.x3),
          TextField(controller: text, autofocus: true, minLines: 1, maxLines: 4, textCapitalization: TextCapitalization.sentences, decoration: InputDecoration(labelText: tr('What do we believe'))),
          const SizedBox(height: Space.x3),
          _ChoiceRow(label: tr('Confidence'), options: _conf, value: confidence, onPick: (v) => setSheet(() => confidence = v)),
          const SizedBox(height: Space.x2),
          _ChoiceRow(label: tr('Status'), options: _findingStates, value: status, onPick: (v) => setSheet(() => status = v)),
          const SizedBox(height: Space.x3),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Add'), style: AppText.bodyStyle.copyWith(fontWeight: FontWeight.w600))),
          ),
        ]),
      ),
    ),
  );
  final t = text.text.trim();
  text.dispose();
  if (ok != true || t.isEmpty) return;
  c.findings.add(CaseFinding(id: const Uuid().v4(), text: t, confidence: confidence, status: status));
  c.updated = DateTime.now();
  await Cases.I.save();
}

Future<void> editFindingSheet(BuildContext context, Case c, CaseFinding f) async {
  var confidence = f.confidence;
  var status = f.status;
  final ok = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    sheetAnimationStyle: SubMotion.sheet,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheet) => Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(Space.x5, 0, Space.x5, Space.x5),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(f.text, style: AppText.bodyStyle.copyWith(color: Palette.of(ctx).text, fontWeight: FontWeight.w600)),
          const SizedBox(height: Space.x3),
          _ChoiceRow(label: tr('Confidence'), options: _conf, value: confidence, onPick: (v) => setSheet(() => confidence = v)),
          const SizedBox(height: Space.x2),
          _ChoiceRow(label: tr('Status'), options: _findingStates, value: status, onPick: (v) => setSheet(() => status = v)),
          const SizedBox(height: Space.x3),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Save'), style: AppText.bodyStyle.copyWith(fontWeight: FontWeight.w600))),
          ),
        ]),
      ),
    ),
  );
  if (ok != true) return;
  f.confidence = confidence;
  f.status = status;
  c.updated = DateTime.now();
  await Cases.I.save();
}

class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({required this.label, required this.options, required this.value, required this.onPick});
  final String label;
  final List<String> options;
  final String value;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Wrap(spacing: Space.x3, runSpacing: Space.x1, crossAxisAlignment: WrapCrossAlignment.center, children: [
      Text(label, style: AppText.microStyle.copyWith(color: p.muted)),
      for (final o in options)
        InkWell(
          borderRadius: Radii.fieldAll,
          onTap: () => onPick(o),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.x1, vertical: Space.x1),
            child: Text(tr(o),
                style: AppText.metaStyle.copyWith(color: o == value ? p.text : p.muted, fontWeight: o == value ? FontWeight.w600 : FontWeight.w400)),
          ),
        ),
    ]);
  }
}
