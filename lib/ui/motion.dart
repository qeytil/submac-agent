import 'dart:math' as math;

import 'package:flutter/material.dart';

/// SubMac's signature motion (owner, 2026-10-23). Every animation in the app picks a curve and a
/// duration from here, so SubMac moves the same way everywhere. Rules:
///
/// * **Settle, never bounce.** Things arrive fast and then slow right down, like ink coming to rest on
///   paper ([settle]). Nothing overshoots, springs or wobbles.
/// * **Paint, not layout.** Only opacity, a small offset and a tiny scale move. Size and position in the
///   layout never animate, so nothing around a moving element jumps. Each moving element sits in a
///   RepaintBoundary to keep 60 fps.
/// * **Small distances.** A rise is a few pixels, a scale is at most 3 %.
/// * **Reduce motion wins.** With the system's reduce-motion setting on, everything simply appears.
///
/// The set:
/// * [InkText]: words settle in, with letter spacing easing from slightly open to normal while they fade
///   in (the status word, titles that change).
/// * Rise (see `Entrance` in widgets/chat/entrance.dart): outputs and list rows rise [rise] px and
///   settle on [settle], staggered by [stagger] and never more than [maxStagger].
/// * [Breath]: the calm breathing of the plain-text status word ("Thinking", "Working"), opacity only.
/// * [sheet]: the quiet reveal of the tap/hold action sheets.
/// * [SendSettle]: your message lands with a short rise and a 3 % settle when you send it.
/// * [SubPageTransitions]: screens arrive with a fade and a small rise, and leave with a fade.
class SubMotion {
  const SubMotion._();

  // Curves.
  /// The SubMac curve: a quick start that comes softly to rest.
  static const Curve settle = Cubic(0.16, 1.0, 0.3, 1.0);

  /// For words: a slightly slower start, so the eye catches the letters closing in.
  static const Curve ink = Cubic(0.33, 0.0, 0.1, 1.0);

  /// For things leaving: a short, quiet fade.
  static const Curve leave = Cubic(0.4, 0.0, 1.0, 1.0);

  // Durations.
  static const Duration tick = Duration(milliseconds: 120);
  static const Duration quick = Duration(milliseconds: 180);
  static const Duration base = Duration(milliseconds: 280);
  static const Duration enter = Duration(milliseconds: 480);
  static const Duration page = Duration(milliseconds: 420);
  static const Duration sheetIn = Duration(milliseconds: 360);
  static const Duration sheetOut = Duration(milliseconds: 220);

  /// One full breath of the status word.
  static const Duration breath = Duration(milliseconds: 2400);

  /// A finger pressing a button down (and letting go).
  static const Duration press = Duration(milliseconds: 110);

  /// A card sliding away once it is answered, and its space folding closed.
  static const Duration leaveCard = Duration(milliseconds: 320);

  /// One sweep of a loading shimmer (skeleton rows, a card being written).
  static const Duration shimmer = Duration(milliseconds: 1400);

  /// One sweep of the shimmer on a working word.
  static const Duration shimmerText = Duration(milliseconds: 1800);

  /// A chart or diagram drawing itself in.
  static const Duration draw = Duration(milliseconds: 900);
  static const Duration drawLong = Duration(milliseconds: 1100);

  /// A diagram's own draw time, kept between [enter] and [drawLong] (a long timeline took close to three seconds).
  static Duration drawIn(int ms) => Duration(milliseconds: ms.clamp(enter.inMilliseconds, drawLong.inMilliseconds).toInt());

  /// The sky: one slow drift loop, and the cross-fade between day and night (or between the two looks).
  static const Duration skyDrift = Duration(seconds: 40);
  static const Duration skyFade = Duration(seconds: 3);

  /// For slow ambient changes only (the sky crossing from day to night): an even ease in and out.
  static const Curve ambient = Curves.easeInOut;

  /// A long scroll back to the newest message.
  static const Duration scroll = Duration(milliseconds: 380);

  /// Delay between blocks of a reply or rows of a list, and the most any of them waits.
  static const Duration stagger = Duration(milliseconds: 60);
  static const Duration maxStagger = Duration(milliseconds: 360);

  // Distances.
  static const double rise = 8;
  static const double sendRise = 14;
  static const double sendScale = 0.97;

  /// The letter spacing words start from in [InkText] (em of the font size).
  static const double inkOpen = 0.06;

  /// The quiet sheet reveal for the tap / hold action sheets.
  static final AnimationStyle sheet = AnimationStyle(curve: settle, duration: sheetIn, reverseDuration: sheetOut);

  /// True when the system asks for reduced motion.
  static bool still(BuildContext context) => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  /// [d], or no time at all when the system asks for reduced motion. For implicit animations
  /// (AnimatedOpacity, AnimatedSize, ...), so every one of them respects Remove animations the same way.
  static Duration of(BuildContext context, Duration d) => still(context) ? Duration.zero : d;

  /// The cross-fade used by every AnimatedSwitcher: the old child and the new one share one box that takes the
  /// size of the new one, pinned to the top-start corner, so nothing re-centres or jumps while they cross.
  static Widget topStartLayout(Widget? current, List<Widget> previous) => Stack(
        alignment: AlignmentDirectional.topStart,
        children: [...previous, if (current != null) current],
      );

  /// Like [topStartLayout], but both children fill the whole box (screens: loading, empty, list).
  static Widget fillLayout(Widget? current, List<Widget> previous) => Stack(
        fit: StackFit.expand,
        children: [...previous, if (current != null) current],
      );

  /// Capped stagger for item [index].
  static Duration staggerFor(int index) {
    final ms = stagger.inMilliseconds * index;
    return Duration(milliseconds: math.min(ms, maxStagger.inMilliseconds));
  }
}

/// Words that settle in: they fade in while their letter spacing closes from slightly open to normal.
/// Plays when [text] changes. Short text only (a status word, a title): letter spacing relays out the
/// line, which is cheap for a few words and never moves anything around it (the line keeps its height).
class InkText extends StatelessWidget {
  const InkText(this.text, {super.key, required this.style, this.maxLines = 1, this.textAlign});
  final String text;
  final TextStyle style;
  final int maxLines;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    final base = style.letterSpacing ?? 0;
    final size = style.fontSize ?? 14;
    if (SubMotion.still(context)) {
      return Text(text, maxLines: maxLines, overflow: TextOverflow.ellipsis, textAlign: textAlign, style: style);
    }
    return TweenAnimationBuilder<double>(
      key: ValueKey(text),
      tween: Tween(begin: 0, end: 1),
      duration: SubMotion.enter,
      curve: SubMotion.ink,
      builder: (context, v, _) => Opacity(
        opacity: v.clamp(0.0, 1.0),
        child: Text(text,
            maxLines: maxLines,
            overflow: TextOverflow.ellipsis,
            textAlign: textAlign,
            style: style.copyWith(letterSpacing: base + (1 - v) * SubMotion.inkOpen * size)),
      ),
    );
  }
}

/// The calm breathing of the status word: opacity only, between [low] and 1, one breath per
/// [SubMotion.breath]. At rest (full opacity) under reduced motion.
class Breath extends StatefulWidget {
  const Breath({super.key, required this.child, this.low = 0.42, this.on = true});
  final Widget child;
  final double low;
  final bool on;

  @override
  State<Breath> createState() => _BreathState();
}

class _BreathState extends State<Breath> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: SubMotion.breath);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(Breath old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (!widget.on || SubMotion.still(context)) {
      _c.stop();
      _c.value = 0;
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _c,
        child: widget.child,
        builder: (context, child) {
          // A soft cosine: full at the start of a breath, lowest half way through.
          final w = 0.5 + 0.5 * math.cos(2 * math.pi * _c.value);
          return Opacity(opacity: widget.low + (1 - widget.low) * w, child: child);
        },
      ),
    );
  }
}

/// Your message landing after Send: a short rise and a 3 % settle, played once.
class SendSettle extends StatelessWidget {
  const SendSettle({super.key, required this.child, this.enabled = true});
  final Widget child;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (!enabled || SubMotion.still(context)) return child;
    return RepaintBoundary(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: SubMotion.enter,
        curve: SubMotion.settle,
        child: child,
        builder: (context, v, child) => Opacity(
          opacity: (v * 1.6).clamp(0.0, 1.0),
          child: Transform.translate(
            offset: Offset(0, (1 - v) * SubMotion.sendRise),
            child: Transform.scale(
              scale: SubMotion.sendScale + (1 - SubMotion.sendScale) * v,
              alignment: AlignmentDirectional.bottomEnd.resolve(Directionality.maybeOf(context) ?? TextDirection.ltr),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

/// Screens arrive with a fade and a small rise on [SubMotion.settle], and leave with a quiet fade.
class SubPageTransitions extends PageTransitionsBuilder {
  const SubPageTransitions();

  @override
  Widget buildTransitions<T>(PageRoute<T> route, BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation, Widget child) {
    if (SubMotion.still(context)) return child;
    // Driven tweens, not new CurvedAnimations: this runs each time a route rebuilds its transition, and a CurvedAnimation
    // with a reverse curve adds a status listener to the route's animation every time it is made, never removed.
    final a = animation.drive(CurveTween(curve: SubMotion.settle));
    // The screen underneath fades out as the new one comes up. Screens are see-through over the sky, so a page that only
    // dimmed showed its words through the new one (a flicker of two pages at once).
    final back = secondaryAnimation.drive(Tween<double>(begin: 1, end: 0).chain(CurveTween(curve: SubMotion.settle)));
    return FadeTransition(
      opacity: back,
      child: FadeTransition(
        opacity: a,
        child: SlideTransition(
          position: a.drive(Tween(begin: const Offset(0, 0.025), end: Offset.zero)),
          child: child,
        ),
      ),
    );
  }
}

/// AnimatedSize that steps aside under Remove animations: a zero-length AnimatedSize finishes inside its own layout
/// and re-dirties itself ("RenderAnimatedSize was mutated in its own performLayout"), so with reduced motion the child
/// is shown as it is.
class SubSize extends StatelessWidget {
  const SubSize({super.key, required this.child, this.duration = SubMotion.quick, this.alignment = AlignmentDirectional.topStart});
  final Widget child;
  final Duration duration;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) {
    if (SubMotion.still(context)) return child;
    return AnimatedSize(duration: duration, curve: SubMotion.settle, alignment: alignment, child: child);
  }
}

/// The one way a block folds open and closed (details, steps, a checklist, a drawer section): a single controller
/// drives a clipped height and a fade together on [SubMotion.settle]. The content stays built while it folds away
/// (an AnimatedSize around `open ? content : SizedBox()` dropped the content at once, so it vanished first and the
/// gap closed after it: a jump), and when folded it is not built at all. With Remove animations it simply opens or
/// closes.
class SubFold extends StatefulWidget {
  const SubFold({super.key, required this.open, required this.child, this.alignment = AlignmentDirectional.topStart});
  final bool open;
  final Widget child;
  final AlignmentGeometry alignment;

  @override
  State<SubFold> createState() => _SubFoldState();
}

class _SubFoldState extends State<SubFold> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: SubMotion.base, reverseDuration: SubMotion.quick, value: widget.open ? 1 : 0);
  late final Animation<double> _t = CurvedAnimation(parent: _c, curve: SubMotion.settle, reverseCurve: SubMotion.leave);

  @override
  void didUpdateWidget(SubFold old) {
    super.didUpdateWidget(old);
    if (old.open == widget.open) return;
    if (SubMotion.still(context)) {
      _c.value = widget.open ? 1 : 0;
    } else if (widget.open) {
      _c.forward();
    } else {
      _c.reverse();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _t,
      child: widget.child,
      builder: (context, child) {
        if (_c.isDismissed) return const SizedBox(width: double.infinity);
        final v = _t.value.clamp(0.0, 1.0);
        return ClipRect(
          child: Align(alignment: widget.alignment, heightFactor: v, child: Opacity(opacity: v, child: child)),
        );
      },
    );
  }
}

/// The one way a picture arrives (Image.frameBuilder): a picture that was already decoded shows at once, one that is
/// still loading fades in on [SubMotion.settle] when its first frame is ready instead of popping in.
Widget subImageFade(BuildContext context, Widget child, int? frame, bool wasSynchronouslyLoaded) {
  if (wasSynchronouslyLoaded || SubMotion.still(context)) return child;
  return AnimatedOpacity(opacity: frame == null ? 0 : 1, duration: SubMotion.base, curve: SubMotion.settle, child: child);
}
