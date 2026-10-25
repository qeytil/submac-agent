import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../theme.dart';
import '../ui/tokens.dart';
import 'output_cards.dart' show pictureFor;
import 'sub_icon.dart';

/// A video that plays right where it is: in the chat (poster + a small outlined play glyph, tap to play inline,
/// expand for the full-screen view) or inside the full-screen view itself ([full]).
///
/// While the player gets ready, one faded status pill says so (no spinner). Tap the playing video to pause or play;
/// the thin bar at the bottom scrubs. Reduced motion: controls simply appear. Layout is directional (RTL).
class InlineVideo extends StatefulWidget {
  const InlineVideo({super.key, required this.path, this.poster, this.autoplay = false, this.full = false, this.onExpand});

  /// A file on this phone or a web link.
  final String path;

  /// A still to show before playing (path or link).
  final String? poster;
  final bool autoplay;

  /// Inside the full-screen view: no expand button, fills its frame.
  final bool full;

  /// Opens the full-screen view (the chat passes the shared lightbox).
  final VoidCallback? onExpand;

  /// Tests and previews swap the real player out.
  static VideoPlayerController Function(String path)? debugController;

  static VideoPlayerController controllerFor(String path) {
    final make = debugController;
    if (make != null) return make(path);
    if (path.startsWith('http://') || path.startsWith('https://')) return VideoPlayerController.networkUrl(Uri.parse(path));
    return VideoPlayerController.file(File(path.startsWith('file://') ? Uri.decodeFull(path.substring(7)) : path));
  }

  @override
  State<InlineVideo> createState() => _InlineVideoState();
}

enum _Phase { idle, loading, playing, failed }

class _InlineVideoState extends State<InlineVideo> {
  VideoPlayerController? _c;
  _Phase _phase = _Phase.idle;
  bool _controls = true;

  @override
  void initState() {
    super.initState();
    if (widget.autoplay) WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _c?.removeListener(_tick);
    _c?.dispose();
    super.dispose();
  }

  void _tick() {
    if (mounted) setState(() {});
  }

  Future<void> _start() async {
    if (!mounted || _phase == _Phase.loading) return;
    setState(() => _phase = _Phase.loading);
    try {
      final c = InlineVideo.controllerFor(widget.path);
      _c = c;
      await c.initialize();
      c.addListener(_tick);
      await c.play();
      if (mounted) setState(() => _phase = _Phase.playing);
    } catch (_) {
      if (mounted) setState(() => _phase = _Phase.failed);
    }
  }

  void _toggle() {
    final c = _c;
    if (c == null) return;
    setState(() {
      if (c.value.isPlaying) {
        c.pause();
        _controls = true;
      } else {
        c.play();
        _controls = false;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.full ? Palette.dark : Palette.of(context);
    final name = widget.path.split('/').last.split('?').first;
    final Widget body = switch (_phase) {
      _Phase.playing => _player(p),
      _Phase.failed => _still(p, line: 'This video won\'t play here'),
      _Phase.loading => _still(p, line: 'Getting the video ready'),
      _Phase.idle => _still(p),
    };
    return Semantics(
      container: true,
      button: _phase != _Phase.playing,
      label: _phase == _Phase.playing ? 'Video $name, tap to pause or play' : 'Play video $name',
      child: ClipRRect(
        borderRadius: Radii.sheetAll,
        child: ColoredBox(
          color: widget.full ? Colors.black : p.bubble,
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: AnimatedSwitcher(
              duration: SubMotion.of(context, SubMotion.base),
              switchInCurve: SubMotion.settle,
              switchOutCurve: SubMotion.leave,
              child: KeyedSubtree(key: ValueKey(_phase), child: body),
            ),
          ),
        ),
      ),
    );
  }

  Widget _still(Palette p, {String? line}) {
    final poster = widget.poster;
    return GestureDetector(
      onTap: _phase == _Phase.loading ? null : _start,
      child: Stack(fit: StackFit.expand, children: [
        if (poster != null && poster.isNotEmpty) pictureFor(poster, fit: BoxFit.cover),
        Center(
          child: line == null
              ? Container(
                  width: 52,
                  height: 52,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: poster != null ? p.bg.withValues(alpha: 0.45) : null,
                    border: Border.all(color: p.muted, width: 1.2),
                  ),
                  child: SubIcon('play', size: IconSize.lg, color: p.text),
                )
              : _Pill(text: line, palette: p),
        ),
        if (!widget.full && widget.onExpand != null && line == null)
          PositionedDirectional(top: Space.x3, end: Space.x3, child: _Corner(icon: 'expand', label: 'Full screen', palette: p, onTap: widget.onExpand!)),
      ]),
    );
  }

  Widget _player(Palette p) {
    final c = _c!;
    final v = c.value;
    final ratio = v.aspectRatio > 0 ? v.aspectRatio : 16 / 9;
    return GestureDetector(
      onTap: _toggle,
      child: Stack(fit: StackFit.expand, children: [
        Center(child: AspectRatio(aspectRatio: ratio, child: VideoPlayer(c))),
        if (!v.isPlaying || _controls)
          Center(
            child: Container(
              width: 52,
              height: 52,
              alignment: Alignment.center,
              decoration: BoxDecoration(shape: BoxShape.circle, color: p.bg.withValues(alpha: 0.45), border: Border.all(color: p.muted, width: 1.2)),
              child: SubIcon(v.isPlaying ? 'stop' : 'play', size: IconSize.lg, color: p.text),
            ),
          ),
        PositionedDirectional(
          start: 0,
          end: 0,
          bottom: 0,
          child: VideoProgressIndicator(
            c,
            allowScrubbing: true,
            padding: const EdgeInsets.only(top: Space.x2),
            colors: VideoProgressColors(playedColor: p.text, bufferedColor: p.muted.withValues(alpha: 0.5), backgroundColor: p.faint),
          ),
        ),
        if (!widget.full && widget.onExpand != null)
          PositionedDirectional(
            top: Space.x3,
            end: Space.x3,
            child: _Corner(
              icon: 'expand',
              label: 'Full screen',
              palette: p,
              onTap: () {
                c.pause();
                widget.onExpand!();
              },
            ),
          ),
      ]),
    );
  }
}

/// Hark's status pill: one faded pill with a short line, no spinner.
class _Pill extends StatelessWidget {
  const _Pill({required this.text, required this.palette});
  final String text;
  final Palette palette;
  @override
  Widget build(BuildContext context) => Semantics(
        liveRegion: true,
        child: DecoratedBox(
          decoration: BoxDecoration(color: palette.bg.withValues(alpha: 0.55), borderRadius: BorderRadius.circular(Radii.pill)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.x4, vertical: Space.x2),
            child: Text(text, style: AppText.metaStyle.copyWith(color: palette.muted)),
          ),
        ),
      );
}

class _Corner extends StatelessWidget {
  const _Corner({required this.icon, required this.label, required this.palette, required this.onTap});
  final String icon;
  final String label;
  final Palette palette;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Semantics(
        container: true,
        button: true,
        label: label,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: palette.bg.withValues(alpha: 0.55), borderRadius: Radii.fieldAll),
            child: SubIcon(icon, size: IconSize.sm, color: palette.text),
          ),
        ),
      );
}
