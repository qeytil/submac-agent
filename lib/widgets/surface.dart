import 'package:flutter/material.dart';

import '../ui/tokens.dart';

/// A group of rows on the page (fix/ui-restyle): no sheet, card or border any more (RESTYLE.md: "no boxes"). The rows
/// stand straight on the paper, separated by air; the sky's paper wash (main.dart) keeps them readable. The name stays
/// so every screen that groups rows keeps working.
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
    return Padding(
      padding: margin,
      child: Material(
        type: MaterialType.transparency,
        child: Padding(
          padding: padding,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
        ),
      ),
    );
  }
}

/// One row standing alone (a file, an inbox message), with a little air around it. No sheet behind it.
class SurfaceRow extends StatelessWidget {
  const SurfaceRow({super.key, required this.child, this.margin = const EdgeInsets.symmetric(horizontal: Space.x3, vertical: 2)});
  final Widget child;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) => SurfaceGroup(margin: margin, padding: EdgeInsets.zero, children: [child]);
}
