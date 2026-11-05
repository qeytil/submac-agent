import 'package:flutter/material.dart';

import '../../models.dart';
import '../../theme.dart';
import '../../ui/tokens.dart';
import '../message_view.dart';
import 'activity_groups.dart';

/// The turn's work, expanded: one section per kind (Thinking, Tools run, Notes), each folded to its count until
/// tapped, so even the open view stays quiet (owner, 2026-11-03).
class ActivityPanel extends StatelessWidget {
  const ActivityPanel({super.key, required this.groups, required this.results});
  final ActivityGroups groups;
  final Map<String, ChatMessage> results;

  @override
  Widget build(BuildContext context) {
    final failed = groups.failed(results);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      if (groups.thinking.isNotEmpty)
        _Section(
          title: 'Thinking',
          count: '${groups.thinking.length}',
          children: [for (final m in groups.thinking) ThinkingBlock(key: ValueKey('act-th-${m.id}'), message: m)],
        ),
      if (groups.tools.isNotEmpty)
        _Section(
          title: 'Tools run',
          count: failed > 0 ? '${groups.tools.length} · $failed failed' : '${groups.tools.length}',
          children: [
            for (final (_, c) in groups.tools) ToolCallCard(key: ValueKey('act-tool-${c.id}'), call: c, result: results[c.id]),
          ],
        ),
      if (groups.notes.isNotEmpty)
        _Section(
          title: 'Notes',
          count: '${groups.notes.length}',
          children: [
            for (final m in groups.notes)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Space.x1),
                child: SelectableText(m.content.trim(), style: AppText.metaStyle.copyWith(color: Palette.of(context).muted)),
              ),
          ],
        ),
    ]);
  }
}

class _Section extends StatefulWidget {
  const _Section({required this.title, required this.count, required this.children});
  final String title;
  final String count;
  final List<Widget> children;

  @override
  State<_Section> createState() => _SectionState();
}

class _SectionState extends State<_Section> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      InkWell(
        borderRadius: Radii.smAll,
        onTap: () => setState(() => _open = !_open),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Space.x1),
          child: Row(children: [
            Text(widget.title, style: AppText.metaStyle.copyWith(color: p.text)),
            const SizedBox(width: Space.x1),
            Text(widget.count, style: AppText.microStyle.copyWith(color: p.muted)),
            const Spacer(),
            ActivityChevron(open: _open),
          ]),
        ),
      ),
      SubFold(
        open: _open,
        child: Padding(
          padding: const EdgeInsetsDirectional.only(start: Space.x2, bottom: Space.x1),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: widget.children),
        ),
      ),
    ]);
  }
}

/// The small open/close mark of the activity views.
class ActivityChevron extends StatelessWidget {
  const ActivityChevron({super.key, required this.open});
  final bool open;

  @override
  Widget build(BuildContext context) => AnimatedRotation(
        turns: open ? 0.5 : 0,
        duration: SubMotion.quick,
        child: Icon(Icons.expand_more_rounded, size: IconSize.sm, color: Palette.of(context).muted),
      );
}

/// A finished turn's work, folded to one quiet line ("Worked for 1m 12s · 2 thoughts · 6 tools"). Tap to open the
/// categorized view.
class ActivityFold extends StatefulWidget {
  const ActivityFold({super.key, required this.groups, required this.results, this.worked});
  final ActivityGroups groups;
  final Map<String, ChatMessage> results;
  final Duration? worked;

  static String dur(Duration d) {
    if (d.inSeconds < 60) return '${d.inSeconds < 1 ? 1 : d.inSeconds}s';
    final s = d.inSeconds % 60;
    return s == 0 ? '${d.inMinutes}m' : '${d.inMinutes}m ${s}s';
  }

  /// Just the time (owner 2026-11-03: "just 'Worked for 1m 12s'"); the counts live in the open view's sections.
  static String head(ActivityGroups g, Duration? worked) => worked == null ? 'Worked' : 'Worked for ${dur(worked)}';

  @override
  State<ActivityFold> createState() => _ActivityFoldState();
}

class _ActivityFoldState extends State<ActivityFold> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(Lux.gutter, Space.x1, Lux.gutter, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        InkWell(
          borderRadius: Radii.smAll,
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Space.x1),
            child: Row(children: [
              Expanded(
                child: Text(ActivityFold.head(widget.groups, widget.worked),
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.metaStyle.copyWith(color: p.muted)),
              ),
              ActivityChevron(open: _open),
            ]),
          ),
        ),
        SubFold(open: _open, child: ActivityPanel(groups: widget.groups, results: widget.results)),
      ]),
    );
  }
}
