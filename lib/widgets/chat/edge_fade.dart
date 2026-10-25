import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../theme.dart';
import '../../ui/tokens.dart';

/// Soft chat edges (owner, 2026-10-24): older messages fade out as they scroll up under the floating top controls,
/// and the newest ones fade softly at the bottom, where the composer floats over the list. Both edges are one
/// gradient mask over the list ([ShaderMask], no per-frame blur), so scrolling stays cheap. Works the same in
/// right-to-left languages and in both looks (it masks alpha, it never paints a colour).
class ChatEdgeFade extends StatelessWidget {
  const ChatEdgeFade({super.key, required this.child, this.top = 0, this.bottom = 0, this.topFade = defaultFade, this.bottomFade = defaultFade});
  final Widget child;

  /// Where the top fade ends (fully visible below it): the floating controls' bottom edge (safe area included).
  final double top;

  /// Where the bottom fade ends, measured up from the bottom edge (the navigation bar's inset).
  final double bottom;

  /// How tall each fade is.
  final double topFade, bottomFade;

  static const double defaultFade = 56;

  /// The mask's stops for a list [height] tall: (stops, opacities), top to bottom. Pure, so tests can pin it.
  static (List<double>, List<double>) stopsFor(double height, {required double top, required double bottom, double topFade = defaultFade, double bottomFade = defaultFade}) {
    if (height <= 0) return (const [0.0, 1.0], const [1.0, 1.0]);
    double at(double y) => (y / height).clamp(0.0, 1.0).toDouble();
    // Top: hidden under the status bar part, then a ramp that reaches full strength just below the controls.
    final topStart = at((top - topFade).clamp(0.0, double.infinity).toDouble());
    final topEnd = at(top);
    // Bottom: full strength until the ramp, which ends at the navigation bar's edge.
    final bottomEnd = at(height - bottom);
    final bottomStart = at(height - bottom - bottomFade);
    final s0 = topStart, s1 = topEnd < s0 ? s0 : topEnd;
    final s2 = bottomStart < s1 ? s1 : bottomStart;
    final s3 = bottomEnd < s2 ? s2 : bottomEnd;
    return ([0.0, s0, s1, s2, s3, 1.0], [0.0, 0.0, 1.0, 1.0, 0.0, 0.0]);
  }

  @override
  Widget build(BuildContext context) {
    if (top <= 0 && bottom <= 0 && topFade <= 0 && bottomFade <= 0) return child;
    return ShaderMask(
      key: const ValueKey('chat-edge-fade'),
      blendMode: BlendMode.dstIn,
      shaderCallback: (rect) {
        final (stops, alpha) = stopsFor(rect.height, top: top, bottom: bottom, topFade: topFade, bottomFade: bottomFade);
        return LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          stops: stops,
          colors: [for (final a in alpha) Colors.black.withValues(alpha: a)],
        ).createShader(rect);
      },
      child: child,
    );
  }
}

/// The height the floating footer (questions, tasks, the composer) takes over the bottom of a chat, so the list can
/// keep its newest message fully above it. Provided by [FloatingChatFrame]; 0 where there is none.
class ChatFooterInset extends InheritedNotifier<ValueNotifier<double>> {
  const ChatFooterInset({super.key, required ValueNotifier<double> super.notifier, required super.child});

  /// The footer's height (and rebuilds the caller when it changes). 0 outside a [FloatingChatFrame].
  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ChatFooterInset>()?.notifier?.value ?? 0;
}

/// A chat whose footer floats over it (owner, 2026-10-24): no solid strip at the bottom, the messages scroll behind
/// the composer's floating pieces and fade softly at the edge. [body] fills the whole area; [footer] sits at the
/// bottom and its measured height is handed to the body through [ChatFooterInset]. The keyboard is handled by the
/// Scaffold around it (the frame simply gets shorter), so the footer rides on top of the keyboard.
class FloatingChatFrame extends StatefulWidget {
  const FloatingChatFrame({super.key, required this.body, required this.footer});
  final Widget body;
  final Widget footer;

  @override
  State<FloatingChatFrame> createState() => _FloatingChatFrameState();
}

class _FloatingChatFrameState extends State<FloatingChatFrame> {
  final _height = ValueNotifier<double>(0);

  @override
  void dispose() {
    _height.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The composer's frosted pieces share one backdrop read (BackdropGroup + BackdropFilter.grouped): each piece used
    // to copy and blur the screen behind it on its own, every frame the sky or the list moved (v1.13.101).
    return ChatFooterInset(
      notifier: _height,
      child: BackdropGroup(child: Stack(children: [
        Positioned.fill(child: widget.body),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: MeasureSize(
            key: const ValueKey('chat-footer'),
            onHeight: (h) {
              if ((h - _height.value).abs() > 0.5) _height.value = h;
            },
            child: widget.footer,
          ),
        ),
      ])),
    );
  }
}

/// Reports its child's laid-out height after each layout that changes it (after the frame, never during layout).
class MeasureSize extends SingleChildRenderObjectWidget {
  const MeasureSize({super.key, required this.onHeight, required super.child});
  final ValueChanged<double> onHeight;

  @override
  RenderObject createRenderObject(BuildContext context) => _MeasureBox(onHeight);

  @override
  void updateRenderObject(BuildContext context, _MeasureBox renderObject) => renderObject.onHeight = onHeight;
}

class _MeasureBox extends RenderProxyBox {
  _MeasureBox(this.onHeight);
  ValueChanged<double> onHeight;
  double? _last;

  @override
  void performLayout() {
    super.performLayout();
    final h = size.height;
    if (_last == h) return;
    _last = h;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (attached) onHeight(h);
    });
  }
}

/// One floating control of the composer: a light frosted blur behind it (one BackdropFilter, clipped to its own
/// shape) and a faint wash of the page colour, no border, no shadow. Used for the "+" button, the message field and
/// the mic, each on its own, so the chat shows through between them.
class FrostedSurface extends StatelessWidget {
  const FrostedSurface({super.key, required this.child, this.radius = Radii.pill, this.sigma = 14, this.wash = 0.30});
  final Widget child;
  final double radius;
  final double sigma;

  /// How strongly the page colour washes the blur (0..1).
  final double wash;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      // Grouped: inside a FloatingChatFrame all pieces share one backdrop read; elsewhere it is a plain blur.
      child: BackdropFilter.grouped(
        filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: DecoratedBox(
          decoration: BoxDecoration(color: p.composer.withValues(alpha: wash)),
          child: child,
        ),
      ),
    );
  }
}

/// The space a chat list keeps under its newest message: the floating footer plus a little air.
double chatBottomInset(BuildContext context) => ChatFooterInset.of(context) + Space.x3;
