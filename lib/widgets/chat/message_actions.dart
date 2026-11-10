import 'package:flutter/material.dart';

import '../../theme.dart';
import '../../ui/tokens.dart';
import '../sub_icon.dart';
import '../../ui/haptics.dart';

/// One thing you can do with a message: Copy, Share, Try again...
class MessageAction {
  const MessageAction(this.label, this.icon, this.onTap, {this.inline = true});
  final String label;

  /// A SubIcon name.
  final String icon;
  final VoidCallback onTap;

  /// Also shown in the quiet row that fades in on a tap (the sheet always lists everything).
  final bool inline;
}

/// The row that fades in under a message after a tap: small, muted icons, nothing else.
class MessageActionRow extends StatelessWidget {
  const MessageActionRow({super.key, required this.actions, this.onMore, this.end = false});
  final List<MessageAction> actions;

  /// "More" opens the full sheet.
  final VoidCallback? onMore;

  /// Your own message: the row sits on the end side.
  final bool end;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    Widget icon(String name, String tip, VoidCallback onTap) => Semantics(
          button: true,
          label: tip,
          excludeSemantics: true,
          child: Tooltip(
            message: tip,
            child: InkResponse(
              radius: Lux.tap / 2,
              onTap: () {
                onTap();
              },
              child: SizedBox(width: Lux.tap - Space.x1, height: Lux.tap - Space.x2, child: Center(child: SubIcon(name, size: IconSize.md, color: p.muted))),
            ),
          ),
        );
    return Padding(
      padding: const EdgeInsets.only(top: Space.x1),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: end ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          for (final a in actions.where((a) => a.inline)) icon(a.icon, a.label, a.onTap),
          if (onMore != null) icon('more', 'More', onMore!),
        ],
      ),
    );
  }
}

/// The long-press sheet: every action for a message as calm rows, plus any extra content
/// (the steps a task took, suggested replies).
Future<void> showMessageActions(
  BuildContext context, {
  required List<MessageAction> actions,
  String? preview,
  List<Widget> extra = const [],
}) {
  SubHaptics.hold();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    // Telesia motion: the quiet sheet reveal for tap / hold actions.
    sheetAnimationStyle: SubMotion.sheet,
    builder: (ctx) {
      final p = Palette.of(ctx);
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.8),
          child: SingleChildScrollView(
            padding: const EdgeInsetsDirectional.fromSTEB(Space.x2, 0, Space.x2, Space.x4),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (preview != null && preview.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(Space.x4, 0, Space.x4, Space.x3),
                  child: Text(preview.trim(),
                      maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.metaStyle.copyWith(color: p.muted)),
                ),
              for (final a in actions)
                InkWell(
                  borderRadius: Radii.fieldAll,
                  onTap: () {
                    Navigator.pop(ctx);
                    a.onTap();
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Space.x4, vertical: Space.x3 + 2),
                    child: Row(children: [
                      SubIcon(a.icon, size: IconSize.lg, color: p.text),
                      const SizedBox(width: Space.x4),
                      Expanded(child: Text(a.label, style: AppText.bodyStyle.copyWith(color: p.text))),
                    ]),
                  ),
                ),
              ...extra,
            ]),
          ),
        ),
      );
    },
  );
}

/// A sheet with the message as selectable text (selection lives here, so a long-press on a message can
/// open its actions instead of starting a selection).
Future<void> showSelectableText(BuildContext context, String text) => showModalBottomSheet<void>(
      context: context,
      sheetAnimationStyle: SubMotion.sheet,
      isScrollControlled: true,
      builder: (ctx) {
        final p = Palette.of(ctx);
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.85),
            child: SingleChildScrollView(
              padding: const EdgeInsetsDirectional.fromSTEB(Lux.gutter, 0, Lux.gutter, Space.x6),
              child: SelectableText(text,
                  textDirection: _dir(text), style: TextStyle(fontSize: Lux.read, height: Lux.readHeight, color: p.text)),
            ),
          ),
        );
      },
    );

TextDirection _dir(String t) {
  for (final r in t.runes) {
    if ((r >= 0x0590 && r <= 0x08FF) || (r >= 0xFB1D && r <= 0xFDFF) || (r >= 0xFE70 && r <= 0xFEFF)) return TextDirection.rtl;
    if ((r >= 0x41 && r <= 0x5A) || (r >= 0x61 && r <= 0x7A)) return TextDirection.ltr;
  }
  return TextDirection.ltr;
}
