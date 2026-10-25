import 'package:flutter/material.dart';

import '../../theme.dart';
import '../../ui/tokens.dart';
import '../hark_style.dart' show openSummaryReader;
import '../sub_icon.dart';

/// Long texts and results in a calm, expandable container (owner 2026-10-24, the hark.com way): a short preview that
/// fades out at its foot, "Show more" to open it in place, and "Open" for the full reader. Used for long answers in the
/// main chat and bot chats, long team posts and the members' parts of a team answer.
///
/// Short text is shown as it is. Reduced motion: it opens and closes without animating.
class ExpandableText extends StatefulWidget {
  const ExpandableText({
    super.key,
    required this.text,
    required this.child,
    this.startOpen = false,
    this.title = '',
    this.previewHeight = ExpandableText.preview,
  });

  /// The plain text (for the length check and the reader).
  final String text;

  /// How the text is drawn (markdown, a bubble…).
  final Widget child;

  /// Open from the start (a reply that streamed in while you watched stays open; the control folds it).
  final bool startOpen;

  /// The reader's title ('' = none).
  final String title;
  final double previewHeight;

  /// Height of the folded preview.
  static const double preview = 260;

  /// Text longer than this many characters, or with more than [lineLimit] lines, folds.
  static const int charLimit = 1100;
  static const int lineLimit = 16;

  static bool isLong(String text) {
    final t = text.trim();
    return t.length > charLimit || '\n'.allMatches(t).length >= lineLimit;
  }

  @override
  State<ExpandableText> createState() => _ExpandableTextState();
}

class _ExpandableTextState extends State<ExpandableText> {
  late bool _open = widget.startOpen;

  /// Keeps the text's own state (a reply fading in as it streams) when it crosses into "long" and gets the fold around it.
  final _childKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final long = ExpandableText.isLong(widget.text);
    final inner = KeyedSubtree(key: _childKey, child: widget.child);
    if (!long) return inner;
    final p = Palette.of(context);
    final d = SubMotion.of(context, SubMotion.base);
    final folded = ShaderMask(
      key: const ValueKey('long-text-folded'),
      shaderCallback: (r) => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        stops: const [0, 0.62, 1],
        colors: [p.text, p.text, p.text.withValues(alpha: 0)],
      ).createShader(r),
      blendMode: BlendMode.dstIn,
      child: SizedBox(
        height: widget.previewHeight,
        child: ClipRect(
          child: OverflowBox(alignment: AlignmentDirectional.topStart, maxHeight: double.infinity, child: widget.child),
        ),
      ),
    );
    final body = _open ? KeyedSubtree(key: const ValueKey('long-text-open'), child: inner) : folded;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      // Reduced motion: no AnimatedSize at all. A zero-length AnimatedSize finishes inside its own layout and re-dirties
      // itself ("RenderAnimatedSize was mutated in its own performLayout").
      if (d == Duration.zero)
        body
      else
        AnimatedSize(duration: d, curve: SubMotion.settle, alignment: AlignmentDirectional.topStart, child: body),
      Padding(
        padding: const EdgeInsets.only(top: Space.x1),
        child: Wrap(spacing: Space.x2, children: [
          _Pill(
            key: const ValueKey('long-text-toggle'),
            label: _open ? 'Show less' : 'Show more',
            icon: 'chevron_down',
            turned: _open,
            onTap: () => setState(() => _open = !_open),
          ),
          _Pill(
            key: const ValueKey('long-text-open-reader'),
            label: 'Open',
            icon: 'expand',
            onTap: () => openSummaryReader(context, title: widget.title, body: widget.text.trim(), raw: widget.text.trim()),
          ),
        ]),
      ),
    ]);
  }
}

class _Pill extends StatelessWidget {
  const _Pill({super.key, required this.label, required this.icon, required this.onTap, this.turned = false});
  final String label;
  final String icon;
  final VoidCallback onTap;
  final bool turned;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: InkWell(
        borderRadius: const BorderRadius.all(Radius.circular(Radii.pill)),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsetsDirectional.fromSTEB(Space.x3, Space.x1 + 2, Space.x3, Space.x1 + 2),
          decoration: BoxDecoration(color: p.bubble, borderRadius: const BorderRadius.all(Radius.circular(Radii.pill))),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(label, style: AppText.microStyle.copyWith(color: p.text, fontWeight: FontWeight.w500)),
            const SizedBox(width: Space.x1),
            AnimatedRotation(
              turns: turned ? 0.5 : 0,
              duration: SubMotion.of(context, SubMotion.quick),
              curve: SubMotion.settle,
              child: SubIcon(icon, size: IconSize.sm, color: p.muted),
            ),
          ]),
        ),
      ),
    );
  }
}
