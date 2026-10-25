import 'package:flutter/material.dart';

import '../theme.dart';
import 'motion.dart';
import '../ui/tokens.dart';

/// Small shared pieces for the calm list pages (Skills, Apps): a pill search, category tabs,
/// rounded rows with a monogram tile and one pill button. Paper/ink/red, no stock icons.

class PillSearch extends StatelessWidget {
  const PillSearch({super.key, required this.hint, required this.onChanged});
  final String hint;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      height: 42,
      decoration: BoxDecoration(
        color: p.sheet,
        borderRadius: BorderRadius.circular(21),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      alignment: Alignment.center,
      child: TextField(
        onChanged: (v) => onChanged(v.trim()),
        style: TextStyle(fontSize: AppText.body, color: p.text),
        decoration: InputDecoration(
          isDense: true,
          filled: false,
          hintText: hint,
          hintStyle: TextStyle(color: p.muted, fontSize: AppText.body),
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          contentPadding: EdgeInsets.zero,
        ),
      ),
    );
  }
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
      height: 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: tabs.length,
        separatorBuilder: (_, __) => const SizedBox(width: 4),
        itemBuilder: (_, i) {
          final t = tabs[i];
          final on = t == selected;
          return InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: () {
              onSelect(t);
            },
            child: AnimatedContainer(
              duration: SubMotion.of(context, SubMotion.quick),
              curve: SubMotion.settle,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: on ? p.bubble : Colors.transparent,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Text(t,
                  style: TextStyle(
                      color: on ? p.text : p.muted, fontSize: AppText.meta, fontWeight: on ? FontWeight.w600 : FontWeight.w400)),
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

class PillButton extends StatelessWidget {
  const PillButton(this.label, {super.key, required this.onTap, this.strong = false});
  final String label;
  final VoidCallback onTap;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () {
        onTap();
      },
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: strong ? p.text : p.bubble,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(label,
            style: TextStyle(color: strong ? p.bg : p.text, fontSize: AppText.meta, fontWeight: FontWeight.w600)),
      ),
    );
  }
}

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
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(16, 0, 16, 10),
      // Paper: white rows float on the page with a soft shadow instead of a line. Ink: flat.
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          boxShadow: Theme.of(context).brightness == Brightness.dark
              ? null
              : [BoxShadow(color: const Color(0xFF121110).withValues(alpha: 0.045), blurRadius: 14, offset: const Offset(0, 3))],
        ),
        child: Material(
        color: p.sheet,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap ?? onAction,
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(14, 13, 14, 13),
            child: Row(children: [
              leading ?? Monogram(title),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: p.text, fontSize: AppText.body, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 3),
                  Text(subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: p.muted, fontSize: AppText.micro, height: 1.3)),
                  if (footnote != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(footnote!, style: TextStyle(color: p.muted.withValues(alpha: 0.8), fontSize: AppText.caption)),
                    ),
                ]),
              ),
              const SizedBox(width: 10),
              if (done)
                const Padding(padding: EdgeInsets.all(5), child: DoneTick(size: 20))
              else if (action != null && onAction != null)
                PillButton(action!, onTap: onAction!),
            ]),
          ),
        ),
      ),
      ),
    );
  }
}
