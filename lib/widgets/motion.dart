import 'package:flutter/material.dart';

import '../theme.dart';
import 'chat/entrance.dart';
import 'sub_icon.dart';
import '../ui/tokens.dart';

bool reduceMotion(BuildContext context) => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

/// Fades a block in and lifts it [SubMotion.rise] px on the SubMac settle curve, after [delay]. This is the same
/// entrance as the chat's [Entrance] (one entrance everywhere: it used to be a second copy with its own scale and an
/// uncancelled delay timer).
class FadeSlideIn extends StatelessWidget {
  final Widget child;
  final Duration delay;
  final bool enabled;
  final bool haptic;
  const FadeSlideIn({super.key, required this.child, this.delay = Duration.zero, this.enabled = true, this.haptic = false});

  @override
  Widget build(BuildContext context) => Entrance(delay: delay, enabled: enabled, child: child);
}

/// Presses down slightly while touched.
class Pressable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double scale;
  const Pressable({super.key, required this.child, this.onTap, this.onLongPress, this.scale = 0.97});

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  void _set(bool v) {
    if (_down != v) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final animate = !reduceMotion(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: widget.onTap == null ? null : (_) => _set(true),
      onTapUp: widget.onTap == null ? null : (_) => _set(false),
      onTapCancel: () => _set(false),
      onTap: widget.onTap == null
          ? null
          : () {
              widget.onTap!();
            },
      onLongPress: widget.onLongPress,
      child: AnimatedScale(
        scale: _down && animate ? widget.scale : 1,
        duration: SubMotion.press,
        curve: SubMotion.settle,
        child: widget.child,
      ),
    );
  }
}

/// Soft placeholder shown while a card is still being written.
class CardShimmer extends StatelessWidget {
  final String label;
  const CardShimmer({super.key, this.label = 'Preparing'});

  /// The short line the status pill says while a card of this kind is written ("Writing a summary").
  static String lineFor(String label) {
    final l = label.toLowerCase();
    if (l.contains('summary')) return 'Writing a summary';
    if (l.contains('draft')) return 'Writing a draft';
    if (l.contains('link')) return 'Gathering links';
    if (l.contains('plan')) return 'Making a plan';
    if (l.contains('table')) return 'Building a table';
    if (l.contains('picture') || l.contains('photo')) return 'Getting pictures ready';
    if (l.contains('page')) return 'Building your page';
    if (l.contains('video')) return 'Getting a video ready';
    if (l.contains('chart') || l.contains('graph') || l.contains('diagram')) return 'Drawing a chart';
    if (l.contains('order')) return 'Putting the order together';
    if (l.contains('option')) return 'Laying out options';
    if (l.contains('event') || l.contains('calendar')) return 'Setting up the event';
    return 'Getting it ready';
  }

  /// Hark's status pill: one small faded pill in the reply column with a short line. No skeleton, no shimmer,
  /// no spinner; the finished card crossfades in where it was (reply_blocks.dart).
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Semantics(
        liveRegion: true,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: Space.x2),
          padding: const EdgeInsets.symmetric(horizontal: Space.x4, vertical: Space.x2),
          decoration: BoxDecoration(color: p.bubble.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(Radii.pill)),
          child: Text(lineFor(label), style: AppText.metaStyle.copyWith(color: p.muted)),
        ),
      ),
    );
  }
}

/// Keeps a card small until the user wants more: content past [height] is clipped under a soft fade
/// with a "Show more" pill. Short content shows as is, with no pill.
class Expandable extends StatefulWidget {
  const Expandable({super.key, required this.child, this.height = 200, this.fadeColor});
  final Widget child;
  final double height;
  /// The colour the fade melts into (the card's background).
  final Color? fadeColor;

  @override
  State<Expandable> createState() => _ExpandableState();
}

class _ExpandableState extends State<Expandable> {
  final _key = GlobalKey();
  bool _open = false;
  bool _tall = false;

  void _measure() {
    final box = _key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final tall = box.size.height > widget.height + 24;
    if (tall != _tall && mounted) setState(() => _tall = tall);
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
    final fade = widget.fadeColor ?? Theme.of(context).scaffoldBackgroundColor;
    final clipped = _tall && !_open;
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SubSize(
          duration: SubMotion.base,
          alignment: Alignment.topCenter,
          child: Stack(children: [
            // Folded from the very first frame (a tall card used to show in full for one frame and then
            // snap shut once measured). Short content is shorter than the cap, so the cap changes nothing.
            ConstrainedBox(
              constraints: !_open ? BoxConstraints(maxHeight: widget.height + 24) : const BoxConstraints(),
              child: SingleChildScrollView(
                physics: const NeverScrollableScrollPhysics(),
                primary: false,
                child: KeyedSubtree(key: _key, child: widget.child),
              ),
            ),
            if (clipped)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 56,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [fade.withValues(alpha: 0), fade],
                      ),
                    ),
                  ),
                ),
              ),
          ]),
        ),
        if (_tall)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Pressable(
                onTap: () {
                  setState(() => _open = !_open);
                },
                // A quiet text link, not a pill: the output stays the loudest thing on screen.
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(_open ? 'Show less' : 'Show more',
                        style: TextStyle(color: p.muted, fontSize: AppText.meta, fontWeight: FontWeight.w500)),
                    const SizedBox(width: 4),
                    AnimatedRotation(
                      turns: _open ? 0.5 : 0,
                      duration: reduce ? Duration.zero : SubMotion.base,
                      curve: SubMotion.settle,
                      child: SubIcon('chevron_down', size: 15, color: p.muted),
                    ),
                  ]),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Plan 5.5: a card that slides away once it is answered (approved to the right, set aside to the left),
/// folds its space closed and only then reports back, so the list never jumps.
class Leaving extends StatelessWidget {
  const Leaving({super.key, required this.gone, required this.child, this.toRight = true});
  final bool gone;
  final bool toRight;
  final Widget child;

  static const duration = SubMotion.leaveCard;

  /// Plays the leave, then runs [then]. Without animations it runs at once.
  static Future<void> after(BuildContext context, VoidCallback then) async {
    if (!reduceMotion(context)) await Future<void>.delayed(duration);
    then();
  }

  @override
  Widget build(BuildContext context) {
    final still = reduceMotion(context);
    final d = still ? Duration.zero : duration;
    return ClipRect(
      child: AnimatedAlign(
        duration: d,
        // One curve for the fold, the slide and the fade (they used to run on three different curves, so the card
        // faded out before it had moved and the gap closed on its own beat).
        curve: SubMotion.leave,
        alignment: Alignment.topCenter,
        heightFactor: gone ? 0 : 1,
        child: AnimatedSlide(
          duration: d,
          curve: SubMotion.leave,
          offset: gone ? Offset(toRight ? 0.35 : -0.35, 0) : Offset.zero,
          child: AnimatedOpacity(duration: d, curve: SubMotion.leave, opacity: gone ? 0 : 1, child: child),
        ),
      ),
    );
  }
}

/// Plan 5.5: a small check that draws itself when something is done (task finished, app connected).
class DoneTick extends StatefulWidget {
  const DoneTick({super.key, this.size = 18, this.color});
  final double size;
  final Color? color;

  @override
  State<DoneTick> createState() => _DoneTickState();
}

class _DoneTickState extends State<DoneTick> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: SubMotion.enter);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (reduceMotion(context)) {
      _c.value = 1;
    } else if (_c.value == 0 && !_c.isAnimating) {
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.color ?? Palette.of(context).text;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => CustomPaint(size: Size.square(widget.size), painter: _TickPainter(SubMotion.settle.transform(_c.value), c)),
    );
  }
}

class _TickPainter extends CustomPainter {
  _TickPainter(this.t, this.color);
  final double t;
  final Color color;

  @override
  void paint(Canvas canvas, Size s) {
    final ring = Paint()
      ..color = color.withValues(alpha: 0.16 * t)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(s.center(Offset.zero), s.width / 2 * (0.7 + 0.3 * t), ring);
    final path = Path()
      ..moveTo(s.width * 0.28, s.height * 0.52)
      ..lineTo(s.width * 0.44, s.height * 0.67)
      ..lineTo(s.width * 0.73, s.height * 0.36);
    final m = path.computeMetrics().first;
    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = s.width * 0.1
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(m.extractPath(0, m.length * t), line);
  }

  @override
  bool shouldRepaint(_TickPainter old) => old.t != t || old.color != color;
}

/// Plan 5.5: soft grey rows while a list loads, in place of a spinner.
class SkeletonList extends StatefulWidget {
  const SkeletonList({super.key, this.rows = 4, this.padding = const EdgeInsetsDirectional.fromSTEB(16, 8, 16, 8), this.leading = true});
  final int rows;
  final EdgeInsetsGeometry padding;
  final bool leading;

  @override
  State<SkeletonList> createState() => _SkeletonListState();
}

class _SkeletonListState extends State<SkeletonList> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: SubMotion.shimmer);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (reduceMotion(context)) {
      _c.stop();
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
    final p = Palette.of(context);
    Widget bar(double? w, double h) => Container(
          width: w,
          height: h,
          decoration: BoxDecoration(color: p.bubble, borderRadius: BorderRadius.circular(h / 2)),
        );
    final rows = Column(children: [
      for (var i = 0; i < widget.rows; i++)
        Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: p.sheet, borderRadius: BorderRadius.circular(14)),
          child: Row(children: [
            if (widget.leading) ...[
              Container(width: 40, height: 40, decoration: BoxDecoration(color: p.bubble, borderRadius: BorderRadius.circular(11))),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                bar(i.isEven ? 140 : 110, 11),
                const SizedBox(height: 8),
                bar(i.isEven ? 210 : 170, 9),
              ]),
            ),
          ]),
        ),
    ]);
    return Padding(
      padding: widget.padding,
      child: Semantics(
        label: 'Loading',
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, child) => ShaderMask(
            blendMode: BlendMode.srcATop,
            shaderCallback: (rect) {
              final t = _c.value;
              return LinearGradient(
                begin: Alignment(-1.5 + 3 * t, 0),
                end: Alignment(-0.5 + 3 * t, 0),
                colors: [p.bubble, p.sheet, p.bubble],
              ).createShader(rect);
            },
            child: child,
          ),
          child: rows,
        ),
      ),
    );
  }
}

/// Plan 5.5: an empty screen says one warm line and offers one thing to tap.
class EmptyHint extends StatelessWidget {
  const EmptyHint({super.key, required this.text, this.example, this.onExample, this.padding = const EdgeInsetsDirectional.fromSTEB(28, 28, 28, 20)});
  final String text;

  /// A tappable example ("Try: brief me every morning").
  final String? example;
  final VoidCallback? onExample;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return FadeSlideIn(
      child: Padding(
        padding: padding,
        child: Column(children: [
          Text(text, textAlign: TextAlign.center, style: Brand.serif(size: 21, color: p.muted, height: 1.25)),
          if (example != null && onExample != null) ...[
            const SizedBox(height: 14),
            Pressable(
              onTap: onExample,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(color: p.bubble, borderRadius: BorderRadius.circular(20)),
                child: Text(example!, textAlign: TextAlign.center, style: TextStyle(color: p.text, fontSize: AppText.meta, fontWeight: FontWeight.w500)),
              ),
            ),
          ],
        ]),
      ),
    );
  }
}
