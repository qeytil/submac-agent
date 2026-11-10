import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Telesia's own icon set (assets/icons): fine ink strokes and softly squared corners, no dots. Takes its colour and size from the
/// surrounding IconTheme (IconButton, ListTile...) unless given.
class SubIcon extends StatelessWidget {
  final String name;
  final double? size;
  final Color? color;
  const SubIcon(this.name, {super.key, this.size, this.color});

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final s = size ?? theme.size ?? 24;
    final c = color ?? theme.color ?? Theme.of(context).colorScheme.onSurface;
    return SizedBox(
      width: s,
      height: s,
      child: SvgPicture.asset(
        'assets/icons/$name.svg',
        width: s,
        height: s,
        theme: SvgTheme(currentColor: c),
      ),
    );
  }
}
