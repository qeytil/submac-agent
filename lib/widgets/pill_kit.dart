import 'package:flutter/material.dart';

import '../theme.dart';
import 'lux_kit.dart';
import '../ui/i18n.dart';
import '../ui/tokens.dart';

/// Small shared pieces for the calm list pages (Skills, Apps). Restyled with the rest of the app (fix/ui-restyle): the
/// search is the glyph and the words on the paper, categories are words, rows have no card or shadow, and the one
/// action is a word. The app tile ([Monogram] / BrandLogo) stays: it is the app's own icon.

class PillSearch extends StatelessWidget {
  const PillSearch({super.key, required this.hint, required this.onChanged});
  final String hint;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => LuxSearchField(hint: hint, onChanged: (v) => onChanged(v.trim()));
}

class CategoryTabs extends StatelessWidget {
  const CategoryTabs({super.key, required this.tabs, required this.selected, required this.onSelect});
  final List<String> tabs;
  final String selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Space.x3),
        itemCount: tabs.length,
        separatorBuilder: (_, __) => const SizedBox(width: Space.x1),
        itemBuilder: (_, i) {
          final t = tabs[i];
          final on = t == selected;
          return LuxTap(
            selected: on,
            onTap: () => onSelect(t),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.x2),
              child: Center(
                child: AnimatedDefaultTextStyle(
                  duration: SubMotion.of(context, SubMotion.quick),
                  curve: SubMotion.settle,
                  style: AppText.metaStyle.copyWith(color: on ? p.text : p.muted, fontWeight: on ? FontWeight.w700 : FontWeight.w500),
                  child: Text(tr(t)),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// A serif initial on a soft tile: our quiet stand-in for app icons.
class Monogram extends StatelessWidget {
  const Monogram(this.text, {super.key, this.size = 40, this.accent = false});
  final String text;
  final double size;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final ch = text.trim().isEmpty ? '·' : text.trim()[0].toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: accent ? p.accentWash : p.bubble,
        borderRadius: BorderRadius.circular(size * 0.28),
      ),
      child: Text(ch, style: Brand.serif(size: size * 0.52, color: accent ? p.accent : p.text, height: 1.0)),
    );
  }
}

/// The one action on a row ("Add", "Allow", "Open"): a word, bold ink when [strong].
class PillButton extends StatelessWidget {
  const PillButton(this.label, {super.key, required this.onTap, this.strong = false});
  final String label;
  final VoidCallback onTap;
  final bool strong;

  @override
  Widget build(BuildContext context) => LuxWordButton(label, primary: true, onPressed: onTap);
}

/// A row on the calm list pages: the app's tile, its name, one quiet line, and a word at the end (the action, or "On"
/// once it is set up). No card, no shadow.
class CardRow extends StatelessWidget {
  const CardRow({
    super.key,
    required this.title,
    required this.subtitle,
    this.leading,
    this.action,
    this.onAction,
    this.onTap,
    this.done = false,
    this.footnote,
  });
  final String title;
  final String subtitle;
  final Widget? leading;
  final String? action;
  final VoidCallback? onAction;
  final VoidCallback? onTap;
  final bool done;
  final String? footnote;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return LuxTap(
      onTap: onTap ?? onAction,
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(Space.x5, Space.x2 + 2, Space.x3, Space.x2 + 2),
        child: Row(children: [
          leading ?? Monogram(title),
          const SizedBox(width: Space.x3 + 2),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr(title), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.bodyStyle.copyWith(color: p.text, fontWeight: FontWeight.w500)),
              const SizedBox(height: 2),
              Text(tr(subtitle), maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.microStyle.copyWith(color: p.muted)),
              if (footnote != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(footnote!, style: AppText.captionStyle.copyWith(color: p.faint)),
                ),
            ]),
          ),
          const SizedBox(width: Space.x2),
          if (done)
            const Padding(padding: EdgeInsets.symmetric(horizontal: Space.x2), child: LuxStatus('On', strong: true))
          else if (action != null && onAction != null)
            PillButton(action!, onTap: onAction!),
        ]),
      ),
    );
  }
}
