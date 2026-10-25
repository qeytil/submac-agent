import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../screens/preview_screen.dart' show MediaView;
import 'media_view.dart';
import 'output_cards.dart' show saveToPhone, pictureFor;
import 'video_inline.dart';
import '../theme.dart';
import 'sub_icon.dart';
import '../ui/tokens.dart';

/// The one full-screen view for pictures, video and sound (Hark's lightbox), used by every card in the chat.
///
/// The chat stays behind, frosted and dimmed; the picture or player sits centred with soft corners. A round Close
/// floats at the top start, the file name in the middle, Share and a Download pill at the top end; round chevrons
/// beside the picture page through a set, and a swipe does too. Pictures pinch or double-tap to zoom (a zoomed
/// picture pans instead of turning the page); a tap on a picture hides or shows the controls.
///
/// [sources] are paths on this phone, paths made on another phone (fetched back from the account first) or web
/// links. Save and Share fetch a missing file the same way.
Future<void> openMediaLightbox(BuildContext context, List<String> sources, {int initial = 0}) {
  if (sources.isEmpty) return Future.value();
  return Navigator.of(context).push(PageRouteBuilder<void>(
    opaque: false,
    barrierDismissible: true,
    barrierLabel: 'Close',
    transitionDuration: SubMotion.of(context, SubMotion.page),
    reverseTransitionDuration: SubMotion.of(context, SubMotion.sheetOut),
    pageBuilder: (_, __, ___) => MediaLightbox(paths: sources, initial: initial.clamp(0, sources.length - 1)),
    transitionsBuilder: (_, a, __, child) => FadeTransition(
      opacity: CurvedAnimation(parent: a, curve: SubMotion.settle, reverseCurve: SubMotion.leave),
      child: child,
    ),
  ));
}

bool lightboxIsPicture(String path) =>
    RegExp(r'\.(png|jpe?g|webp|gif|bmp|heic)$', caseSensitive: false).hasMatch(path.split('?').first) ||
    (_remote(path) && !lightboxIsVideo(path) && !lightboxIsSound(path));
bool lightboxIsVideo(String path) => RegExp(r'\.(mp4|webm|mov|m4v|3gp|mkv)$', caseSensitive: false).hasMatch(path.split('?').first);
bool lightboxIsSound(String path) => RegExp(r'\.(mp3|wav|m4a|ogg|aac|flac|opus)$', caseSensitive: false).hasMatch(path.split('?').first);
bool _remote(String s) => s.startsWith('http://') || s.startsWith('https://');

/// Shares a picture or file: a web link as a link, a file (fetched back when needed) as the file itself.
Future<void> shareMedia(BuildContext context, String src) async {
  if (_remote(src)) {
    await SharePlus.instance.share(ShareParams(text: src));
    return;
  }
  await withLocalFile(context, src, (f) => SharePlus.instance.share(ShareParams(files: [XFile(f.path)])));
}

class MediaLightbox extends StatefulWidget {
  const MediaLightbox({super.key, required this.paths, this.initial = 0, this.picture});
  final List<String> paths;
  final int initial;

  /// Draws one picture; tests pass a stand-in. Defaults to [pictureFor] (local, account or web).
  final Widget Function(String src)? picture;

  @override
  State<MediaLightbox> createState() => _MediaLightboxState();
}

class _MediaLightboxState extends State<MediaLightbox> {
  late final PageController _pages = PageController(initialPage: widget.initial);
  late int _at = widget.initial;
  bool _zoomed = false;
  bool _chrome = true;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _go(int d) {
    final to = (_at + d).clamp(0, widget.paths.length - 1);
    if (to == _at) return;
    if (SubMotion.still(context)) {
      _pages.jumpToPage(to);
    } else {
      _pages.animateToPage(to, duration: SubMotion.of(context, SubMotion.base), curve: SubMotion.settle);
    }
  }

  Widget _picture(String src) => (widget.picture ?? (s) => pictureFor(s, fit: BoxFit.contain))(src);

  @override
  Widget build(BuildContext context) {
    final path = widget.paths[_at];
    final many = widget.paths.length > 1;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final ink = Palette.dark;
    return Material(
      type: MaterialType.transparency,
      child: Stack(children: [
        // The chat behind, frosted and dimmed. A tap on it closes.
        Positioned.fill(
          child: GestureDetector(
            onTap: () => Navigator.of(context).maybePop(),
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
              child: ColoredBox(color: ink.bg.withValues(alpha: 0.78)),
            ),
          ),
        ),
        Positioned.fill(
          child: SafeArea(
            child: Padding(
              padding: EdgeInsets.fromLTRB(many ? 64 : Space.x4, 72, many ? 64 : Space.x4, Space.x6),
              child: PageView.builder(
                key: const ValueKey('image-viewer-pages'),
                controller: _pages,
                itemCount: widget.paths.length,
                // While zoomed in, a drag pans the picture instead of turning the page.
                physics: _zoomed ? const NeverScrollableScrollPhysics() : const PageScrollPhysics(),
                onPageChanged: (i) => setState(() {
                  _at = i;
                  _zoomed = false;
                }),
                itemBuilder: (context, i) {
                  final src = widget.paths[i];
                  if (lightboxIsPicture(src) || widget.picture != null) {
                    return ZoomablePicture(
                      key: ValueKey('zoom-$i'),
                      onZoom: (z) {
                        if (z != _zoomed) setState(() => _zoomed = z);
                      },
                      onTap: () => setState(() => _chrome = !_chrome),
                      child: ClipRRect(borderRadius: Radii.rowAll, child: _picture(src)),
                    );
                  }
                  return Center(child: _Player(path: src));
                },
              ),
            ),
          ),
        ),
        if (many && _at > 0)
          PositionedDirectional(
            start: Space.x2,
            top: 0,
            bottom: 0,
            child: Center(child: _fade(_Round(icon: rtl ? 'chevron_right' : 'back', label: 'Previous', onTap: () => _go(-1)))),
          ),
        if (many && _at < widget.paths.length - 1)
          PositionedDirectional(
            end: Space.x2,
            top: 0,
            bottom: 0,
            child: Center(child: _fade(_Round(icon: rtl ? 'back' : 'chevron_right', label: 'Next', onTap: () => _go(1)))),
          ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(Space.x3),
            child: _fade(Row(children: [
              _Round(icon: 'close', label: 'Close', onTap: () => Navigator.of(context).maybePop()),
              Expanded(
                child: Text(
                  _remote(path) ? '' : path.split('/').last,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.metaStyle.copyWith(color: ink.text),
                ),
              ),
              _Round(icon: 'share', label: 'Share', onTap: () => shareMedia(context, path)),
              const SizedBox(width: Space.x2),
              _SavePill(onTap: () => saveToPhone(context, path)),
            ])),
          ),
        ),
      ]),
    );
  }

  Widget _fade(Widget child) => AnimatedOpacity(
        opacity: _chrome ? 1 : 0,
        duration: SubMotion.of(context, SubMotion.quick),
        curve: SubMotion.settle,
        child: IgnorePointer(ignoring: !_chrome, child: child),
      );
}

/// Video in a 16:9 frame with the in-app player; sound in a centred pill with the phone's own player. A file made on
/// another phone is fetched from the account first.
class _Player extends StatelessWidget {
  const _Player({required this.path});
  final String path;
  @override
  Widget build(BuildContext context) {
    final ink = Palette.dark;
    final audio = lightboxIsSound(path);
    Widget frame(Widget child) => ClipRRect(
          borderRadius: audio ? BorderRadius.circular(Radii.pill) : Radii.rowAll,
          child: audio
              ? ConstrainedBox(constraints: const BoxConstraints(maxWidth: 480), child: SizedBox(width: double.infinity, height: 64, child: child))
              : AspectRatio(aspectRatio: 16 / 9, child: child),
        );
    if (_remote(path)) return frame(audio ? MediaView(path: path) : InlineVideo(path: path, autoplay: true, full: true));
    return MediaResolve(
      path: path,
      ready: (c, File f) => frame(audio ? MediaView(path: f.path) : InlineVideo(path: f.path, autoplay: true, full: true)),
      loading: (c) => frame(ColoredBox(color: ink.bubble)),
      gone: (c, retry) => GestureDetector(
        onTap: retry,
        child: Padding(
          padding: const EdgeInsets.all(Space.x6),
          child: Text('This file isn\'t on this phone or in your account any more. Tap to try again.',
              textAlign: TextAlign.center, style: AppText.metaStyle.copyWith(color: ink.muted)),
        ),
      ),
    );
  }
}

/// A round, quiet control on the dark backdrop: dark grey fill, white glyph.
class _Round extends StatelessWidget {
  const _Round({required this.icon, required this.label, required this.onTap});
  final String icon;
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Semantics(
        container: true,
        button: true,
        label: label,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: 48,
            height: 48,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: Palette.dark.bubble, shape: BoxShape.circle),
            child: SubIcon(icon, size: IconSize.md, color: Palette.dark.text),
          ),
        ),
      );
}

class _SavePill extends StatelessWidget {
  const _SavePill({required this.onTap});
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Semantics(
        container: true,
        button: true,
        label: 'Download',
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: Space.x4),
            decoration: BoxDecoration(color: Palette.dark.bubble, borderRadius: BorderRadius.circular(Radii.pill)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              SubIcon('folder', size: IconSize.sm, color: Palette.dark.text),
              const SizedBox(width: Space.x2),
              Text('Download', style: AppText.metaStyle.copyWith(color: Palette.dark.text, fontWeight: FontWeight.w500)),
            ]),
          ),
        ),
      );
}
