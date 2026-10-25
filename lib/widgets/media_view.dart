import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../services/media_store.dart';
import '../theme.dart';
import '../ui/tokens.dart';

/// Builds a card with the file behind [path]: right away when it is on this phone, after a quiet download when it is
/// only in the account backup (another phone, a reinstall), and with [gone] only when it is in neither place.
/// A file found on this phone is also kept in the account, once, so the user's other phones can show it.
class MediaResolve extends StatefulWidget {
  const MediaResolve({
    super.key,
    required this.path,
    required this.ready,
    required this.loading,
    required this.gone,
  });

  final String path;
  final Widget Function(BuildContext context, File file) ready;
  final WidgetBuilder loading;
  final Widget Function(BuildContext context, VoidCallback retry) gone;

  @override
  State<MediaResolve> createState() => _MediaResolveState();
}

class _MediaResolveState extends State<MediaResolve> {
  File? _file;
  bool _looking = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(MediaResolve old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path) _start();
  }

  void _start({bool retry = false}) {
    final now = MediaStore.I.localNow(widget.path);
    if (now != null) {
      _file = now;
      _looking = false;
      unawaited(MediaStore.I.keep(now.path).catchError((_) => null));
      return;
    }
    _file = null;
    _looking = true;
    MediaStore.I.resolve(widget.path, retry: retry).then((f) {
      if (!mounted) return;
      setState(() {
        _file = f;
        _looking = false;
      });
    }).catchError((_) {
      if (mounted) setState(() => _looking = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final f = _file;
    if (f != null) return widget.ready(context, f);
    if (_looking) return widget.loading(context);
    return widget.gone(context, () => setState(() => _start(retry: true)));
  }
}

/// The soft space a picture takes while it arrives: the shared surface tone, rounded, no outline and no spinner
/// (Hark shows no loading chrome; the picture fades in over it).
class MediaPlaceholder extends StatelessWidget {
  const MediaPlaceholder({super.key, this.height = 200, this.width});
  final double height;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Semantics(
      label: 'Picture loading',
      child: Container(
        width: width ?? double.infinity,
        height: height,
        decoration: BoxDecoration(color: p.bubble, borderRadius: Radii.rowAll),
      ),
    );
  }
}

/// Runs [use] with the file behind [path] (fetched from the account when it is not on this phone), or tells the
/// user once that it is not available any more.
Future<void> withLocalFile(BuildContext context, String path, FutureOr<void> Function(File file) use) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final f = MediaStore.I.localNow(path) ?? await MediaStore.I.resolve(path, retry: true);
  if (f == null) {
    messenger?.showSnackBar(const SnackBar(content: Text('This file isn\'t on this phone or in your account any more.')));
    return;
  }
  await use(f);
}

/// File size in plain words.
String sizeLabel(int b) {
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
  return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
}

/// What kind of file a name is, in a word or two ("PDF", "Picture", "Spreadsheet").
String kindLabel(String name) {
  final e = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  const kinds = {
    'pdf': 'PDF', 'png': 'Picture', 'jpg': 'Picture', 'jpeg': 'Picture', 'webp': 'Picture', 'gif': 'Picture',
    'bmp': 'Picture', 'heic': 'Picture', 'mp4': 'Video', 'webm': 'Video', 'mov': 'Video', 'm4v': 'Video', '3gp': 'Video',
    'mp3': 'Sound', 'wav': 'Sound', 'm4a': 'Sound', 'aac': 'Sound', 'ogg': 'Sound', 'docx': 'Document', 'doc': 'Document',
    'xlsx': 'Spreadsheet', 'xlsm': 'Spreadsheet', 'xls': 'Spreadsheet', 'csv': 'Table', 'tsv': 'Table',
    'pptx': 'Slides', 'ppt': 'Slides', 'html': 'Page', 'htm': 'Page', 'md': 'Text', 'txt': 'Text', 'json': 'Data',
    'zip': 'Archive',
  };
  return kinds[e] ?? (e.isEmpty ? 'File' : e.toUpperCase());
}

/// One picture that zooms: pinch, or double-tap to zoom in where you tapped and again to fit.
class ZoomablePicture extends StatefulWidget {
  const ZoomablePicture({super.key, required this.child, this.onZoom, this.onTap});
  final Widget child;
  final ValueChanged<bool>? onZoom;
  final VoidCallback? onTap;

  @override
  State<ZoomablePicture> createState() => _ZoomablePictureState();
}

class _ZoomablePictureState extends State<ZoomablePicture> with SingleTickerProviderStateMixin {
  final _t = TransformationController();
  late final AnimationController _anim = AnimationController(vsync: this, duration: SubMotion.base);
  Animation<Matrix4>? _tween;
  Offset _tapAt = Offset.zero;

  static const double _doubleTapScale = 2.5;

  @override
  void initState() {
    super.initState();
    _anim.addListener(() {
      final t = _tween;
      if (t != null) _t.value = t.value;
    });
    _t.addListener(_report);
  }

  bool _lastZoom = false;
  void _report() {
    final z = _t.value.getMaxScaleOnAxis() > 1.01;
    if (z != _lastZoom) {
      _lastZoom = z;
      widget.onZoom?.call(z);
    }
  }

  @override
  void dispose() {
    _anim.dispose();
    _t.dispose();
    super.dispose();
  }

  void _toggle() {
    final zoomed = _t.value.getMaxScaleOnAxis() > 1.01;
    final Matrix4 end;
    if (zoomed) {
      end = Matrix4.identity();
    } else {
      final p = _tapAt;
      end = Matrix4.identity()
        ..translateByDouble(-p.dx * (_doubleTapScale - 1), -p.dy * (_doubleTapScale - 1), 0, 1)
        ..scaleByDouble(_doubleTapScale, _doubleTapScale, 1, 1);
    }
    if (SubMotion.still(context)) {
      _t.value = end;
      return;
    }
    _tween = Matrix4Tween(begin: _t.value, end: end).animate(CurvedAnimation(parent: _anim, curve: SubMotion.settle));
    _anim.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onDoubleTapDown: (d) => _tapAt = d.localPosition,
      onDoubleTap: _toggle,
      child: InteractiveViewer(
        transformationController: _t,
        minScale: 1,
        maxScale: 6,
        child: SizedBox.expand(child: Center(child: widget.child)),
      ),
    );
  }
}
