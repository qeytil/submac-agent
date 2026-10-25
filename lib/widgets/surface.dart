import 'package:flutter/material.dart';

import '../theme.dart';
import '../ui/tokens.dart';

/// The one content surface on the sky (restyle): a soft sheet with round corners, no border and no shadow,
/// so words stay readable on the daylight and the night sky alike. Rows inside are separated by space,
/// never by lines. Taps ripple inside the rounded shape.
class SurfaceGroup extends StatelessWidget {
  const SurfaceGroup({
    super.key,
    required this.children,
    this.margin = const EdgeInsets.symmetric(vertical: Space.x1),
    this.padding = const EdgeInsets.symmetric(vertical: Space.x1),
  });
  final List<Widget> children;
  final EdgeInsetsGeometry margin;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: margin,
      child: Material(
        color: p.sheet,
        borderRadius: Radii.rowAll,
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: padding,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
        ),
      ),
    );
  }
}

/// One row on its own surface (a file, an inbox message): the same sheet as [SurfaceGroup], for lists where
/// every row stands alone with a little space between.
class SurfaceRow extends StatelessWidget {
  const SurfaceRow({super.key, required this.child, this.margin = const EdgeInsets.symmetric(horizontal: Space.x3, vertical: 2)});
  final Widget child;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) => SurfaceGroup(margin: margin, padding: EdgeInsets.zero, children: [child]);
}
