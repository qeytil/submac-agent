import 'package:flutter/material.dart';

import '../../ui/motion.dart';
import '../motion.dart' show reduceMotion;

/// Streaming text that fades in as it arrives (owner 2026-10-24: no letter-by-letter typing).
///
/// Each time [text] grows, the new version is laid on top of the old one and fades in over [SubMotion.quick]. The
/// words both versions share stay fully visible underneath (the older layer is already opaque), so only the newly
/// appended words ramp from clear to full. Layers are the same text laid out in the same box, so nothing moves: the
/// stack is as tall as the newest (longest) version and every layer starts at the top start corner. When a layer has
/// fully faded in, every layer under it is dropped; at most [maxLayers] are kept while text arrives quickly.
///
/// Under reduced motion the newest text simply shows at once.
class FadeAppend extends StatefulWidget {
  const FadeAppend({super.key, required this.text, required this.child, this.fadeFirst = false});

  /// What [child] shows: a change of text starts a new fade layer.
  final String text;
  final Widget child;

  /// The very first version fades in too (a block that starts while the reply streams). Off for finished replies.
  final bool fadeFirst;

  static const int maxLayers = 4;

  @override
  State<FadeAppend> createState() => FadeAppendState();
}

class _Layer {
  _Layer(this.text, this.child, this.fade);
  final String text;
  Widget child;
  final AnimationController? fade; // null: fully shown
}

class FadeAppendState extends State<FadeAppend> with TickerProviderStateMixin {
  final List<_Layer> _layers = [];

  /// How many versions are on screen right now (tests).
  @visibleForTesting
  int get layerCount => _layers.length;

  @override
  void initState() {
    super.initState();
    _layers.add(_Layer(widget.text, widget.child, null));
    if (widget.fadeFirst) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || reduceMotion(context) || _layers.length != 1 || _layers.first.fade != null) return;
        final first = _layers.removeAt(0);
        setState(() => _layers.add(_Layer(first.text, first.child, _start())));
      });
    }
  }

  AnimationController _start() {
    late final AnimationController c;
    c = AnimationController(vsync: this, duration: SubMotion.quick)
      ..addStatusListener((s) {
        if (s == AnimationStatus.completed) _settled(c);
      })
      ..forward();
    return c;
  }

  void _settled(AnimationController c) {
    if (!mounted) return;
    final at = _layers.indexWhere((l) => identical(l.fade, c));
    if (at <= 0) return;
    setState(() {
      for (final l in _layers.sublist(0, at)) {
        l.fade?.dispose();
      }
      _layers.removeRange(0, at);
    });
  }

  @override
  void didUpdateWidget(FadeAppend old) {
    super.didUpdateWidget(old);
    final top = _layers.last;
    if (widget.text == top.text) {
      top.child = widget.child; // same words (a style or size change): no new fade
      return;
    }
    if (reduceMotion(context)) {
      _drop();
      _layers.add(_Layer(widget.text, widget.child, null));
      return;
    }
    _layers.add(_Layer(widget.text, widget.child, _start()));
    // Text arriving faster than the fade: the oldest layers go (the newer ones already cover their words).
    while (_layers.length > FadeAppend.maxLayers) {
      _layers.removeAt(0).fade?.dispose();
    }
  }

  void _drop() {
    for (final l in _layers) {
      l.fade?.dispose();
    }
    _layers.clear();
  }

  @override
  void dispose() {
    _drop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_layers.length == 1 && _layers.first.fade == null) return _layers.first.child;
    return Stack(
      alignment: AlignmentDirectional.topStart,
      children: [
        for (var i = 0; i < _layers.length; i++)
          // Every layer is the same text grown a little: they share one box and one top start corner.
          KeyedSubtree(
            key: ValueKey(_layers[i]),
            child: _layers[i].fade == null
                ? _layers[i].child
                : FadeTransition(opacity: _layers[i].fade!, child: _layers[i].child),
          ),
      ],
    );
  }
}
