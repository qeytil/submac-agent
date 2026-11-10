import 'package:flutter/material.dart';

import '../../ui/motion.dart';

/// The empty chat's greeting (owner, 2026-10-24): ONE smooth intro. The letters fade in one by one with Telesia's settle
/// curve, and that is all: no loop, no erase, no cursor. It plays once each time an empty chat shows it (the widget is
/// keyed by the chat), and stands still with Remove animations.
///
/// The whole line is laid out from the first frame as one paragraph (each letter only changes its opacity), so nothing
/// around it moves and the frame cost stays one text layout. Scripts whose letters join (Arabic) fade in word by word
/// instead, so the letters keep their shapes.
class TypingText extends StatefulWidget {
  const TypingText(this.text, {super.key, this.style, this.textAlign = TextAlign.center});
  final String text;
  final TextStyle? style;
  final TextAlign textAlign;

  /// The time between one letter and the next starting to appear.
  static const letterStep = Duration(milliseconds: 34);

  /// How long one letter takes to fade in fully.
  static const letterFade = SubMotion.enter;

  /// The whole intro for [text].
  static Duration lengthFor(String text) => letterStep * (units(text).length - 1).clamp(0, 1 << 20) + letterFade;

  static final _joining = RegExp(r'[\u0600-\u06FF\u0750-\u077F\u08A0-\u08FF\uFB50-\uFDFF\uFE70-\uFEFF]');

  /// The pieces that fade in one at a time: letters, or words (with their space) for joined scripts.
  static List<String> units(String text) {
    if (_joining.hasMatch(text)) {
      return [for (final m in RegExp(r'\S+\s*|\s+').allMatches(text)) m.group(0)!];
    }
    return [for (final r in text.runes) String.fromCharCode(r)];
  }

  @override
  State<TypingText> createState() => _TypingTextState();
}

class _TypingTextState extends State<TypingText> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: TypingText.lengthFor(widget.text));
  late List<String> _units = TypingText.units(widget.text);
  bool _still = false;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (_still) {
      _c.value = 1;
    } else if (!_started) {
      _started = true;
      _c.forward(from: 0);
    }
  }

  @override
  void didUpdateWidget(TypingText old) {
    super.didUpdateWidget(old);
    if (old.text == widget.text) return;
    _units = TypingText.units(widget.text);
    _c.duration = TypingText.lengthFor(widget.text);
    if (_still) {
      _c.value = 1;
    } else {
      _c.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Widget _plain() => Text(widget.text, key: const ValueKey('typing-text'), textAlign: widget.textAlign, style: widget.style);

  @override
  Widget build(BuildContext context) {
    final base = widget.style ?? DefaultTextStyle.of(context).style;
    final color = base.color ?? DefaultTextStyle.of(context).style.color ?? Theme.of(context).colorScheme.onSurface;
    return Semantics(
      label: widget.text,
      excludeSemantics: true,
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            if (_still || _c.isCompleted) return _plain();
            final total = _c.duration!.inMicroseconds;
            final now = _c.value * total;
            final step = TypingText.letterStep.inMicroseconds;
            final fade = TypingText.letterFade.inMicroseconds;
            return Text.rich(
              TextSpan(children: [
                for (var i = 0; i < _units.length; i++)
                  TextSpan(
                    text: _units[i],
                    style: TextStyle(
                      color: color.withValues(alpha: 
                          color.a * SubMotion.settle.transform(((now - i * step) / fade).clamp(0.0, 1.0).toDouble())),
                    ),
                  ),
              ]),
              key: const ValueKey('typing-text'),
              textAlign: widget.textAlign,
              style: base,
            );
          },
        ),
      ),
    );
  }
}
