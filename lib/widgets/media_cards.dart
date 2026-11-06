import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../screens/preview_screen.dart';
import '../services/ai_models.dart';
import '../theme.dart';
import 'chat/document_tile.dart';
import 'chat/entrance.dart';
import 'chat/message_actions.dart';
import 'media_lightbox.dart';
import 'media_view.dart';
import 'video_inline.dart';
import 'output_cards.dart';
import 'sub_icon.dart';
import '../ui/tokens.dart';

/// Cards for what the user's own AI models made (ai_call): pictures, a set of pictures, sound, video and files.
///
/// Styled after a study of hark.com (2026-10-24): cards float in the reply column with no borders, shadows or chrome;
/// pictures are bare with soft corners, a set of pictures is a fanned stack, sound/video/files sit on the chat's card
/// fill. While the model works, one faded status pill shows a short line that changes in place; then the result
/// crossfades in with the chat's one entrance (fade + small rise). Tap opens a frosted full-screen view
/// (media_lightbox.dart). Reduced motion: everything simply appears. Layout is directional (RTL).
///
/// The card is rebuilt from the tool result (`MEDIA_CARD {json}`) stored with the chat, so it persists, syncs and
/// renders the same in history.

/// The chat's view of one ai_call: placeholder while it runs, the card when it is done, nothing for text or errors.
class AiMediaCall extends StatelessWidget {
  const AiMediaCall({super.key, required this.callId, required this.arguments, this.result});
  final String callId;
  final String arguments;
  final String? result;

  /// True when this call is (or will become) a media card, so the chat draws it instead of a step line.
  static bool shows(String name, String? result) {
    // media_generate (the user's media providers) answers with the same MEDIA_CARD as ai_call.
    if (name != AiModels.call && name != 'media_generate') return false;
    if (result == null) return true;
    return AiModels.readCard(result) != null;
  }

  String get _task {
    try {
      final j = jsonDecode(arguments);
      if (j is! Map) return '';
      final t = '${j['task'] ?? ''}';
      if (t.isNotEmpty) return t;
      // media_generate names a kind instead of a task.
      return switch ('${j['kind'] ?? ''}') { 'audio' => 'music', final k => k };
    } catch (_) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final card = result == null ? null : AiModels.readCard(result!);
    final Widget child = card != null
        ? Entrance(key: const ValueKey('result'), child: GeneratedMediaCard(card: card))
        : (result == null ? MediaSkeleton(key: const ValueKey('wait'), callId: callId, task: _task) : const SizedBox.shrink(key: ValueKey('none')));
    return AnimatedSwitcher(
      duration: SubMotion.of(context, SubMotion.base),
      switchInCurve: SubMotion.settle,
      switchOutCurve: SubMotion.leave,
      layoutBuilder: SubMotion.topStartLayout,
      child: child,
    );
  }
}

/// The card for a finished result. Like Hark's cards it carries no chrome of its own: a picture is just the picture,
/// a set of pictures is a small fanned stack, sound, video and files sit on one soft surface with a single quiet
/// corner action. What was asked lives in the accessibility label; Again / Variations / Save / Share are one hold
/// (or the corner action) away, and Save / Share float in the full-screen view.
class GeneratedMediaCard extends StatelessWidget {
  const GeneratedMediaCard({super.key, required this.card});
  final Map<String, dynamic> card;

  List<String> get files => [for (final f in (card['files'] is List ? card['files'] as List : const [])) '$f'];
  String get kind => '${card['kind'] ?? 'file'}';

  @override
  Widget build(BuildContext context) {
    final fs = files;
    if (fs.isEmpty) return const SizedBox.shrink();
    final Widget body = switch (kind) {
      'image' => MediaPicture(path: fs.first, card: card),
      'images' => MediaPhotoStack(paths: fs, card: card),
      'audio' => MediaSound(path: fs.first, card: card),
      'video' => MediaVideo(path: fs.first, card: card),
      _ => Column(mainAxisSize: MainAxisSize.min, children: [
          for (final f in fs) Padding(padding: const EdgeInsets.only(bottom: Space.x1), child: MediaFile(path: f, card: card)),
        ]),
    };
    return Semantics(container: true, label: describe(card, fs.length), child: body);
  }

  /// "Picture: a calm sea at dawn (my-model)".
  static String describe(Map<String, dynamic> card, int n) {
    final kind = '${card['kind'] ?? ''}';
    final what = switch (kind) {
      'image' => 'Picture',
      'images' => '$n pictures',
      'audio' => 'Sound',
      'video' => 'Video',
      _ => n == 1 ? 'File' : '$n files',
    };
    final prompt = '${card['prompt'] ?? ''}'.trim();
    final model = '${card['model'] ?? ''}'.trim();
    return [what, if (prompt.isNotEmpty) prompt, if (model.isNotEmpty) '($model)'].join(prompt.isEmpty ? ' ' : ': ').replaceFirst(': (', ' (');
  }
}

bool _here(String path) => File(path).existsSync();

/// One action sheet for every media card: open, make again, variations (pictures), save, share. Save and Share fetch
/// a file made on another phone from the account first.
void showMediaActions(BuildContext context, Map<String, dynamic> card, {int at = 0}) {
  final files = [for (final f in (card['files'] is List ? card['files'] as List : const [])) '$f'];
  final kind = '${card['kind'] ?? ''}';
  final pictures = kind == 'image' || kind == 'images';
  final one = files.isEmpty ? '' : files[at.clamp(0, files.length - 1)];
  void ask(String text) {
    try {
      context.read<AppState>().send(text, const []);
    } catch (_) {}
  }

  showMessageActions(context, preview: GeneratedMediaCard.describe(card, files.length), actions: [
    if (files.isNotEmpty) MessageAction(pictures ? 'View' : 'Open', pictures ? 'eye' : 'play', () => _open(context, card, at: at)),
    MessageAction('Make it again', 'refresh', () => ask('Make it again with the same model and prompt.')),
    if (pictures) MessageAction('Variations', 'image', () => ask('Make 3 variations of that with the same model.')),
    if (one.isNotEmpty) MessageAction('Save to phone', 'folder', () => saveToPhone(context, one)),
    if (one.isNotEmpty) MessageAction('Share', 'share', () => shareMedia(context, one)),
  ]);
}

void _open(BuildContext context, Map<String, dynamic> card, {int at = 0}) {
  final files = [for (final f in (card['files'] is List ? card['files'] as List : const [])) '$f'];
  if (files.isEmpty) return;
  final kind = '${card['kind'] ?? ''}';
  if (kind == 'file' || kind == 'files') {
    openPreview(context, files[at.clamp(0, files.length - 1)]);
    return;
  }
  // The one full-screen view; it fetches files made on another phone from the account.
  openMediaLightbox(context, files, initial: at);
}

/// Shown when a synced card's file is neither on this phone nor in the account any more.
class _Away extends StatelessWidget {
  const _Away({this.aspect = 4 / 3, this.retry});
  final double aspect;
  final VoidCallback? retry;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return GestureDetector(
      onTap: retry,
      child: DecoratedBox(
        decoration: BoxDecoration(color: p.bubble, borderRadius: Radii.fieldAll),
        child: AspectRatio(
          aspectRatio: aspect,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(Space.x3),
              child: Text('Not available any more. Tap to try again',
                  textAlign: TextAlign.center, style: AppText.microStyle.copyWith(color: p.muted)),
            ),
          ),
        ),
      ),
    );
  }
}

/// One picture: soft corners, fades in, no frame and no caption. Tap for the full-screen view (pinch to zoom),
/// hold for the actions.
class MediaPicture extends StatelessWidget {
  const MediaPicture({super.key, required this.path, required this.card});
  final String path;
  final Map<String, dynamic> card;
  @override
  Widget build(BuildContext context) {
    return MediaResolve(
      path: path,
      loading: (c) => const Align(alignment: AlignmentDirectional.centerStart, child: MediaPlaceholder(width: 240, height: 240)),
      gone: (c, retry) => SizedBox(width: 240, child: _Away(aspect: 1, retry: retry)),
      ready: (c, f) => _ready(c, f),
    );
  }

  Widget _ready(BuildContext context, File file) {
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: GestureDetector(
        onTap: () => _open(context, card),
        onLongPress: () => showMediaActions(context, card),
        // Narrower than the reply column, as Hark shows a generated picture (about 288 wide, no caption).
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 288),
          child: ClipRRect(borderRadius: Radii.fieldAll, child: TrueShapeImage(FileImage(file), maxHeight: 420)),
        ),
      ),
    );
  }
}

/// A set of pictures as a small fanned stack (Hark's photo stack): each tile turned a few degrees, the next one
/// overlapping the last, no frames, no captions. Tap a tile to page through them full screen.
class MediaPhotoStack extends StatelessWidget {
  const MediaPhotoStack({super.key, required this.paths, required this.card});
  final List<String> paths;
  final Map<String, dynamic> card;

  static const _turns = [-3.0, 3.0, -2.0, 4.0];

  @override
  Widget build(BuildContext context) {
    final shown = paths.take(4).toList();
    return LayoutBuilder(builder: (context, c) {
      final col = c.maxWidth.isFinite ? c.maxWidth : 380.0;
      final w = (col * 0.56).clamp(140.0, 240.0);
      final h = w * 0.78;
      final n = shown.length;
      final step = n <= 1 ? 0.0 : (col - w - Space.x2) / (n - 1);
      final drop = h * 0.32;
      return SizedBox(
        height: h + drop + Space.x4,
        width: col,
        child: Stack(clipBehavior: Clip.none, children: [
          for (var i = 0; i < n; i++)
            PositionedDirectional(
              start: Space.x1 + step * i,
              top: Space.x2 + (i.isOdd ? drop : 0),
              width: w,
              height: h,
              child: Entrance(
                delay: Entrance.staggerFor(i),
                child: Transform.rotate(
                  angle: _turns[i % _turns.length] * 3.14159265 / 180,
                  child: GestureDetector(
                    onTap: () => _open(context, card, at: i),
                    onLongPress: () => showMediaActions(context, card, at: i),
                    child: Semantics(
                      image: true,
                      label: 'Picture ${i + 1}',
                      child: ClipRRect(borderRadius: Radii.fieldAll, child: pictureFor(shown[i], fit: BoxFit.cover, width: w, height: h)),
                    ),
                  ),
                ),
              ),
            ),
        ]),
      );
    });
  }
}

/// The one quiet corner action on a surface card (a small rounded square, like Hark's Reply).
class MediaCornerAction extends StatelessWidget {
  const MediaCornerAction({super.key, required this.onTap});
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Semantics(
      container: true,
      button: true,
      label: 'More',
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: p.composer, borderRadius: Radii.fieldAll),
          child: SubIcon('more', size: IconSize.sm, color: p.text),
        ),
      ),
    );
  }
}

/// Sound (Hark's audio chip): a light rounded chip with a file glyph and the file name; tap to play it in the
/// full-screen view with the phone's own player. No inline waveform, no inline controls.
class MediaSound extends StatelessWidget {
  const MediaSound({super.key, required this.path, required this.card});
  final String path;
  final Map<String, dynamic> card;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final name = path.split('/').last;
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Semantics(
        container: true,
        button: true,
        label: 'Open preview for $name',
        child: GestureDetector(
          onTap: () => _open(context, card),
          onLongPress: () => showMediaActions(context, card),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 260),
            child: DecoratedBox(
              decoration: BoxDecoration(color: p.text, borderRadius: BorderRadius.circular(Radii.pill)),
              child: Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(Space.x4, Space.x3, Space.x5, Space.x3),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  SubIcon('speaker', size: IconSize.md, color: p.bg),
                  const SizedBox(width: Space.x3),
                  Flexible(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                      Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.metaStyle.copyWith(color: p.bg, fontWeight: FontWeight.w500)),
                      Text(_meta(path), style: AppText.captionStyle.copyWith(color: p.bg.withValues(alpha: 0.6))),
                    ]),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Video: plays right in the chat (poster, small outlined play glyph, tap to play, thin scrub bar); the corner opens
/// the full-screen view, a hold opens the actions. A video made on another phone is fetched from the account first.
class MediaVideo extends StatelessWidget {
  const MediaVideo({super.key, required this.path, required this.card});
  final String path;
  final Map<String, dynamic> card;

  String? get _poster {
    final p = card['poster'];
    return p is String && p.isNotEmpty ? p : null;
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPress: () => showMediaActions(context, card),
      child: MediaResolve(
        path: path,
        loading: (c) => const MediaPlaceholder(height: 180),
        gone: (c, retry) => _Away(aspect: 16 / 9, retry: retry),
        ready: (c, f) => InlineVideo(path: f.path, poster: _poster, onExpand: () => _open(context, card)),
      ),
    );
  }
}

/// Any other file: the chat's document tile (type badge, name, size); tap to open.
class MediaFile extends StatelessWidget {
  const MediaFile({super.key, required this.path, required this.card});
  final String path;
  final Map<String, dynamic> card;
  @override
  Widget build(BuildContext context) => GestureDetector(
        onLongPress: () => showMediaActions(context, card),
        child: DocumentTile(
          name: path.split('/').last,
          meta: _here(path) ? _meta(path) : 'Kept in your account',
          onTap: () => openPreview(context, path),
        ),
      );
}

String _meta(String path) {
  final ext = path.contains('.') ? path.split('.').last.toUpperCase() : '';
  try {
    final b = File(path).lengthSync();
    final size = b < 1024 * 1024 ? '${(b / 1024).toStringAsFixed(0)} KB' : '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
    return ext.isEmpty ? size : '$ext · $size';
  } catch (_) {
    return ext;
  }
}

/// The placeholder while the model works (Hark's status pill): one small faded pill in the reply column with a short
/// line that changes in place ("Creating an image", "Waiting in line", "Getting a file ready"). No spinner, no
/// skeleton; the result crossfades in where the pill was.
class MediaSkeleton extends StatelessWidget {
  const MediaSkeleton({super.key, required this.callId, this.task = ''});
  final String callId;
  final String task;

  static String waitingLabel(String task) => AiModels.workingLine(task);

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Semantics(
      liveRegion: true,
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: DecoratedBox(
          decoration: BoxDecoration(color: p.bubble.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(Radii.pill)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.x4, vertical: Space.x2),
            child: ValueListenableBuilder<Map<String, String>>(
              valueListenable: AiModels.progress,
              builder: (context, m, _) {
                final line = m[callId] ?? waitingLabel(task);
                return SubSize(
                  duration: SubMotion.base,
                  alignment: AlignmentDirectional.centerStart,
                  child: AnimatedSwitcher(
                    duration: SubMotion.of(context, SubMotion.quick),
                    layoutBuilder: SubMotion.topStartLayout,
                    child: Text(line, key: ValueKey(line), style: AppText.metaStyle.copyWith(color: p.muted)),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
