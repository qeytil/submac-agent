import 'package:flutter/material.dart';

import '../../theme.dart';
import '../../ui/tokens.dart';

/// A document or file SubMac made or found: a thin page outline with its type, the name, and a quiet line
/// under it (kind and size, or "Not available any more"). No card around it. Tap opens it; hold it for Save / Share.
class DocumentTile extends StatelessWidget {
  const DocumentTile({super.key, required this.name, this.meta = '', this.onTap});
  final String name;
  final String meta;
  final VoidCallback? onTap;

  String get _ext {
    final e = name.contains('.') ? name.split('.').last.toUpperCase() : 'FILE';
    return e.length > 4 ? e.substring(0, 4) : e;
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Semantics(
      button: onTap != null,
      label: meta.isEmpty ? name : '$name, $meta',
      excludeSemantics: true,
      child: InkWell(
        borderRadius: Radii.fieldAll,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Space.x2),
          child: Row(children: [
            // No page outline (UI rules): the file type alone, in a bold mono, stands in for the page.
            SizedBox(
              width: 40,
              child: Text(_ext, style: Brand.mono(size: 11, color: p.muted).copyWith(fontWeight: FontWeight.w600)),
            ),
            const SizedBox(width: Space.x4),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.bodyStyle.copyWith(color: p.text, fontWeight: FontWeight.w500)),
                if (meta.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(meta, style: AppText.microStyle.copyWith(color: p.faint)),
                ],
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
