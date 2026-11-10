import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../ui/tokens.dart';

/// The one entrance every chat block uses: a soft fade with a small rise, played once.
///
/// * [delay] staggers blocks of one reply (see [Entrance.staggerFor]).
/// * With reduced motion (system setting) the block simply appears.
/// * The child sits in a [RepaintBoundary], so a block that animates never repaints its neighbours.
/// * Layout is never animated: the block takes its full size on the first frame and only its paint fades
///   and rises, so nothing around it jumps.
class Entrance extends StatefulWidget {
  const Entrance({super.key, required this.child, this.delay = Duration.zero, this.enabled = true, this.rise = LuxMotion.rise});
  final Widget child;
  final Duration delay;
  final bool enabled;
  final double rise;

  /// The delay for block [index] of a reply: a short, capped stagger.
  static Duration staggerFor(int index) {
    final ms = LuxMotion.stagger.inMilliseconds * index;
    final cap = LuxMotion.maxStagger.inMilliseconds;
    return Duration(milliseconds: ms > cap ? cap : ms);
  }

  @override
  State<Entrance> createState() => _EntranceState();
}

class _EntranceState extends State<Entrance> with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final Animation<double> _t;
  Timer? _wait;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: LuxMotion.enter, value: widget.enabled ? 0 : 1);
    _t = CurvedAnimation(parent: _c, curve: SubMotion.settle);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (!widget.enabled) return;
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) {
      _c.value = 1;
      return;
    }
    if (widget.delay == Duration.zero) {
      _c.forward();
    } else {
      _wait = Timer(widget.delay, () {
        if (mounted) _c.forward();
      });
    }
  }

  @override
  void dispose() {
    _wait?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _t,
        child: widget.child,
        builder: (context, child) {
          final v = _t.value;
          return Opacity(
            opacity: v,
            child: Transform.translate(offset: Offset(0, (1 - v) * widget.rise), child: child),
          );
        },
      ),
    );
  }
}

/// Telesia's list reveal: each row rises and settles in turn ([SubMotion.staggerFor]), once, when the
/// list first shows (the menu opening, the Bots page arriving). Rows past [maxAnimated] simply appear.
/// An [Expanded] or [Flexible] row keeps its place in the Column and animates its child.
List<Widget> revealRows(List<Widget> rows, {int maxAnimated = 12}) => [
      for (var i = 0; i < rows.length; i++)
        if (i >= maxAnimated)
          rows[i]
        else if (rows[i] is Flexible)
          Flexible(
            flex: (rows[i] as Flexible).flex,
            fit: (rows[i] as Flexible).fit,
            child: Entrance(delay: SubMotion.staggerFor(i), child: (rows[i] as Flexible).child),
          )
        else
          Entrance(delay: SubMotion.staggerFor(i), child: rows[i]),
    ];
