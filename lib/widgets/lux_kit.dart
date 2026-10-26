import 'package:flutter/material.dart';

import '../theme.dart';
import '../ui/haptics.dart';
import '../ui/i18n.dart';
import '../ui/tokens.dart';
import 'sub_icon.dart';

/// The quiet building blocks every screen shares (fix/ui-restyle, owner 2026-10-26: "no screen keeps the old style").
///
/// RESTYLE.md rules, in widgets: no boxes, borders or cards; rows are words on the paper, separated by air; no Material
/// icons (SubMac's own glyphs only, and only where a glyph says more than a word); status is plain text; press feedback
/// and every reveal use the shared SubMac motion ([LuxMotion] / [SubMotion]) and stand still under reduce motion.

/// Press feedback without a ripple or a box: the content dims a little while touched and settles back on the SubMac curve.
class LuxTap extends StatefulWidget {
  const LuxTap({super.key, required this.child, this.onTap, this.onLongPress, this.label, this.selected = false});
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Read out instead of the child's words when given.
  final String? label;
  final bool selected;

  @override
  State<LuxTap> createState() => _LuxTapState();
}

class _LuxTapState extends State<LuxTap> {
  bool _down = false;

  void _set(bool v) {
    if (_down != v && mounted) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null || widget.onLongPress != null;
    return Semantics(
      button: enabled,
      selected: widget.selected,
      label: widget.label,
      excludeSemantics: widget.label != null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => _set(true) : null,
        onTapUp: enabled ? (_) => _set(false) : null,
        onTapCancel: () => _set(false),
        onTap: widget.onTap,
        onLongPress: widget.onLongPress == null
            ? null
            : () {
                _set(false);
                SubHaptics.hold();
                widget.onLongPress!();
              },
        child: AnimatedOpacity(
          opacity: _down ? 0.5 : 1,
          duration: SubMotion.of(context, SubMotion.press),
          curve: LuxMotion.ease,
          child: widget.child,
        ),
      ),
    );
  }
}

/// A section label: sentence case, the faint tone, air above it. Never a line.
class LuxSection extends StatelessWidget {
  const LuxSection(this.title, {super.key, this.trailing, this.padding = const EdgeInsetsDirectional.fromSTEB(Space.x5, Space.x6, Space.x5, Space.x2)});
  final String title;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: padding,
      child: Row(children: [
        Expanded(child: Text(tr(title), style: AppText.sectionStyle.copyWith(color: p.faint))),
        if (trailing != null) trailing!,
      ]),
    );
  }
}

/// One row: a title, an optional quiet line under it, and an optional value word at the end. No leading icon, no
/// chevron, no fill when selected (the selected row is set in the full ink weight; the rest stay calm).
class LuxRow extends StatelessWidget {
  const LuxRow({
    super.key,
    required this.title,
    this.sub,
    this.value,
    this.leading,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.selected = false,
    this.destructive = false,
    this.dense = false,
    this.enabled = true,
    this.padding,
    this.maxLines = 1,
  });
  final String title;
  final String? sub;

  /// A short word at the end ("On", "English", "3").
  final String? value;

  /// A face or a logo only; never a Material icon.
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool selected;
  final bool destructive;

  /// Menu rows (the sidebar) are slimmer than settings rows.
  final bool dense;
  final bool enabled;
  final EdgeInsetsGeometry? padding;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final color = !enabled ? p.faint : (destructive ? p.accent : p.text);
    final titleStyle = (dense ? AppText.bodyStyle : AppText.leadStyle).copyWith(
      color: color,
      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
    );
    final row = Padding(
      padding: padding ?? EdgeInsetsDirectional.symmetric(horizontal: dense ? Space.x3 : Space.x5, vertical: dense ? Space.x2 + 2 : Space.x3 + 2),
      child: Row(children: [
        if (leading != null) ...[leading!, const SizedBox(width: Space.x3)],
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(title, maxLines: maxLines, overflow: TextOverflow.ellipsis, style: titleStyle),
            if (sub != null && sub!.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(sub!, maxLines: 3, overflow: TextOverflow.ellipsis, style: AppText.metaStyle.copyWith(color: p.muted)),
            ],
          ]),
        ),
        if (value != null && value!.isNotEmpty) ...[
          const SizedBox(width: Space.x3),
          Text(value!, style: AppText.metaStyle.copyWith(color: selected ? p.text : p.muted)),
        ],
        if (trailing != null) ...[const SizedBox(width: Space.x3), trailing!],
      ]),
    );
    if (!enabled || (onTap == null && onLongPress == null)) return Semantics(selected: selected, child: row);
    return LuxTap(onTap: onTap, onLongPress: onLongPress, selected: selected, child: row);
  }
}

/// A row with a switch at the end: the whole row flips it.
class LuxSwitchRow extends StatelessWidget {
  const LuxSwitchRow({super.key, required this.title, this.sub, required this.value, required this.onChanged, this.dense = false});
  final String title;
  final String? sub;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: LuxRow(
        title: title,
        sub: sub,
        dense: dense,
        enabled: onChanged != null,
        maxLines: 2,
        onTap: onChanged == null ? null : () => onChanged!(!value),
        trailing: Switch(value: value, onChanged: onChanged),
      ),
    );
  }
}

/// The one search field: the search glyph and the words, straight on the paper (no fill, no outline).
class LuxSearchField extends StatelessWidget {
  const LuxSearchField({super.key, this.controller, this.focusNode, this.onChanged, this.onTap, this.onTapOutside, this.hint = 'Search', this.fieldKey});
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onTap;
  final TapRegionCallback? onTapOutside;
  final String hint;
  final Key? fieldKey;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Row(children: [
      SubIcon('search', size: IconSize.md, color: p.faint),
      const SizedBox(width: Space.x3),
      Expanded(
        child: TextField(
          key: fieldKey,
          controller: controller,
          focusNode: focusNode,
          onTap: onTap,
          onTapOutside: onTapOutside,
          onChanged: onChanged,
          style: AppText.bodyStyle.copyWith(color: p.text),
          decoration: InputDecoration(
            hintText: tr(hint),
            isDense: true,
            filled: false,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(vertical: Space.x3),
          ),
        ),
      ),
    ]);
  }
}

/// The SubMac dialog: the paper rising a few pixels and settling (no Material pop), a display title, quiet words, and
/// the actions as words at the end. Reduce motion: it simply appears.
Future<T?> showLuxDialog<T>(BuildContext context, {required WidgetBuilder builder, bool dismissible = true}) {
  final still = SubMotion.still(context);
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: dismissible,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Palette.of(context).bg.withValues(alpha: 0.72),
    transitionDuration: still ? Duration.zero : SubMotion.base,
    pageBuilder: (ctx, _, __) => SafeArea(child: Center(child: _LuxDialogFrame(child: Builder(builder: builder)))),
    transitionBuilder: (ctx, a, _, child) {
      final c = CurvedAnimation(parent: a, curve: LuxMotion.ease, reverseCurve: SubMotion.leave);
      return FadeTransition(
        opacity: c,
        child: AnimatedBuilder(
          animation: c,
          builder: (_, w) => Transform.translate(offset: Offset(0, (1 - c.value) * LuxMotion.rise), child: w),
          child: child,
        ),
      );
    },
  );
}

class _LuxDialogFrame extends StatelessWidget {
  const _LuxDialogFrame({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(Space.x6, Space.x6, Space.x6, Space.x6 + MediaQuery.of(context).viewInsets.bottom),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Material(
          color: p.sheet,
          borderRadius: Radii.sheetAll,
          clipBehavior: Clip.antiAlias,
          child: Padding(padding: const EdgeInsetsDirectional.fromSTEB(Space.x6, Space.x6, Space.x4, Space.x3), child: child),
        ),
      ),
    );
  }
}

/// The body of a SubMac dialog: title, optional words or content, and the action words.
class LuxDialogBody extends StatelessWidget {
  const LuxDialogBody({super.key, required this.title, this.message, this.content, required this.actions});
  final String title;
  final String? message;
  final Widget? content;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsetsDirectional.only(end: Space.x2),
        child: Text(title, style: Brand.display(size: AppText.display, color: p.text, height: 1.2)),
      ),
      if (message != null && message!.isNotEmpty) ...[
        const SizedBox(height: Space.x3),
        Padding(
          padding: const EdgeInsetsDirectional.only(end: Space.x2),
          child: Text(message!, style: AppText.bodyStyle.copyWith(color: p.muted)),
        ),
      ],
      if (content != null) ...[
        const SizedBox(height: Space.x4),
        Flexible(child: Padding(padding: const EdgeInsetsDirectional.only(end: Space.x2), child: content!)),
      ],
      const SizedBox(height: Space.x4),
      Wrap(alignment: WrapAlignment.end, spacing: Space.x1, children: actions),
    ]);
  }
}

/// An action word in a dialog or a sheet: bold ink for the main one, muted for Cancel, the brand red only for delete.
class LuxWordButton extends StatelessWidget {
  const LuxWordButton(this.label, {super.key, required this.onPressed, this.primary = false, this.destructive = false});
  final String label;
  final VoidCallback? onPressed;
  final bool primary;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final color = onPressed == null ? p.faint : (destructive ? p.accent : (primary ? p.text : p.muted));
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(foregroundColor: color, minimumSize: const Size(64, 44)),
      child: Text(tr(label), style: AppText.bodyStyle.copyWith(color: color, fontWeight: primary || destructive ? FontWeight.w700 : FontWeight.w500)),
    );
  }
}

/// Asks a yes/no question in the SubMac dialog. True only when the action word was tapped.
Future<bool> luxConfirm(BuildContext context, {required String title, String? message, String action = 'OK', String cancel = 'Cancel', bool destructive = false}) async {
  final ok = await showLuxDialog<bool>(
    context,
    builder: (d) => LuxDialogBody(
      title: tr(title),
      message: message == null ? null : tr(message),
      actions: [
        LuxWordButton(cancel, onPressed: () => Navigator.pop(d, false)),
        LuxWordButton(action, primary: !destructive, destructive: destructive, onPressed: () => Navigator.pop(d, true)),
      ],
    ),
  );
  return ok == true;
}

/// Asks for one line of words (a name) in the SubMac dialog. Null when cancelled.
Future<String?> luxPrompt(BuildContext context, {required String title, String initial = '', String? hint, String? message, String action = 'Save', int maxLines = 1, int? maxLength}) async {
  final ctrl = TextEditingController(text: initial);
  final out = await showLuxDialog<String>(
    context,
    builder: (d) {
      final p = Palette.of(d);
      return LuxDialogBody(
        title: tr(title),
        message: message == null ? null : tr(message),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          minLines: 1,
          maxLines: maxLines,
          maxLength: maxLength,
          style: AppText.leadStyle.copyWith(color: p.text),
          decoration: InputDecoration(hintText: hint == null ? null : tr(hint)),
          onSubmitted: maxLines == 1 ? (v) => Navigator.pop(d, v) : null,
        ),
        actions: [
          LuxWordButton('Cancel', onPressed: () => Navigator.pop(d)),
          LuxWordButton(action, primary: true, onPressed: () => Navigator.pop(d, ctrl.text)),
        ],
      );
    },
  );
  // Disposed after the closing motion, which still reads it.
  Future.delayed(const Duration(seconds: 1), ctrl.dispose);
  return out;
}

/// One choice in [showLuxChoices].
class LuxChoice<T> {
  const LuxChoice(this.value, this.label, {this.sub, this.destructive = false});
  final T value;
  final String label;
  final String? sub;
  final bool destructive;
}

/// A quiet sheet of choices (a title, then words; the current one in the full ink weight with SubMac's check).
Future<T?> showLuxChoices<T>(BuildContext context, {String? title, required List<LuxChoice<T>> choices, T? selected}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    sheetAnimationStyle: SubMotion.sheet,
    builder: (ctx) {
      final p = Palette.of(ctx);
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.8),
          child: ListView(shrinkWrap: true, padding: const EdgeInsets.only(top: Space.x4, bottom: Space.x4), children: [
            if (title != null)
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(Space.x5, 0, Space.x5, Space.x2),
                child: Text(tr(title), style: AppText.leadStyle.copyWith(color: p.text, fontWeight: FontWeight.w600)),
              ),
            for (final c in choices)
              LuxRow(
                title: tr(c.label),
                sub: c.sub == null ? null : tr(c.sub!),
                selected: c.value == selected,
                destructive: c.destructive,
                trailing: c.value == selected ? SubIcon('check', size: IconSize.md, color: p.text) : null,
                onTap: () => Navigator.pop(ctx, c.value),
              ),
          ]),
        ),
      );
    },
  );
}

/// A quiet sheet with a title and free content (forms, pickers). The paper rises with the shared sheet motion.
Future<T?> showLuxSheet<T>(BuildContext context, {String? title, required WidgetBuilder builder, bool scrollControlled = true}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: scrollControlled,
    sheetAnimationStyle: SubMotion.sheet,
    builder: (ctx) {
      final p = Palette.of(ctx);
      return SafeArea(
        child: Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (title != null)
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(Space.x5, Space.x5, Space.x5, Space.x2),
                child: Text(tr(title), style: Brand.display(size: AppText.display, color: p.text, height: 1.2)),
              ),
            Flexible(child: Builder(builder: builder)),
          ]),
        ),
      );
    },
  );
}

/// The one status line: plain words in a quiet tone (no dot, no icon, no pill).
class LuxStatus extends StatelessWidget {
  const LuxStatus(this.text, {super.key, this.strong = false, this.error = false});
  final String text;

  /// Something is happening now ("Working"): full ink.
  final bool strong;

  /// Something failed: the brand red.
  final bool error;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Text(tr(text), style: AppText.captionStyle.copyWith(color: error ? p.accent : (strong ? p.text : p.faint), fontWeight: strong ? FontWeight.w600 : FontWeight.w400));
  }
}

/// One word in [LuxWords].
class LuxWord {
  const LuxWord(this.label, {this.selected = false, this.onTap, this.destructive = false, this.key});
  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final bool destructive;
  final Key? key;
}

/// Choices as words in a flowing line (in place of Material chips): the chosen ones in the full ink weight, the rest
/// muted, with no pill, outline or check mark.
class LuxWords extends StatelessWidget {
  const LuxWords(this.words, {super.key});
  final List<LuxWord> words;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Wrap(spacing: Space.x1, runSpacing: 0, children: [
      for (final w in words)
        LuxTap(
          key: w.key,
          selected: w.selected,
          onTap: w.onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.x2, vertical: Space.x2),
            child: AnimatedDefaultTextStyle(
              duration: SubMotion.of(context, LuxMotion.quick),
              curve: LuxMotion.ease,
              style: AppText.bodyStyle.copyWith(
                color: w.destructive ? p.accent : (w.selected ? p.text : p.muted),
                fontWeight: w.selected ? FontWeight.w700 : FontWeight.w500,
              ),
              child: Text(tr(w.label)),
            ),
          ),
        ),
    ]);
  }
}

/// One word in a row of tabs or filters (in place of Material's ChoiceChip and ActionChip, which drew filled pills):
/// the chosen one in the full ink weight, the others muted. Same arguments as the chips it replaces.
class LuxWordTab extends StatelessWidget {
  const LuxWordTab({super.key, required this.label, this.selected = false, this.onSelected, this.onPressed});
  final Widget label;
  final bool selected;
  final ValueChanged<bool>? onSelected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final tap = onPressed ?? (onSelected == null ? null : () => onSelected!(!selected));
    return LuxTap(
      selected: selected,
      onTap: tap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.x2),
        child: Center(
          widthFactor: 1,
          child: AnimatedDefaultTextStyle(
            duration: SubMotion.of(context, LuxMotion.quick),
            curve: LuxMotion.ease,
            style: AppText.metaStyle.copyWith(color: selected ? p.text : p.muted, fontWeight: selected ? FontWeight.w700 : FontWeight.w500),
            child: label,
          ),
        ),
      ),
    );
  }
}
