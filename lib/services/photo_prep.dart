import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;

/// Gallery photos are shrunk before they are sent (PLAN 1.4): a phone photo is often 4000 px and 4-8 MB, which is
/// slow to upload from Mogadishu and no clearer to the model than 2048 px. Camera shots are already 2048 px.
class PhotoPrep {
  static const maxSide = 2048;
  /// JPEG quality of a shrunk photo (CB-26: 2048 px, JPEG 80).
  static const quality = 80;

  /// Small enough already (no side over [maxSide] and under this size): sent as it is.
  static const keepBytes = 1500 * 1024;

  /// Image types this can read and re-encode. Others (HEIC, SVG, animated GIF) are sent as they are.
  static bool canShrink(String mime) => const {'image/jpeg', 'image/jpg', 'image/png', 'image/webp', 'image/bmp'}.contains(mime);

  /// A JPEG no larger than [max] on its longest side, or null when the picture is fine as it is (or unreadable).
  static Uint8List? shrink(Uint8List bytes, {int max = maxSide, int quality = PhotoPrep.quality}) {
    try {
      final im = img.decodeImage(bytes);
      if (im == null) return null;
      final big = im.width > max || im.height > max;
      if (!big && bytes.length <= keepBytes) return null;
      final baked = img.bakeOrientation(im);
      final out = big
          ? (baked.width >= baked.height
              ? img.copyResize(baked, width: max, interpolation: img.Interpolation.average)
              : img.copyResize(baked, height: max, interpolation: img.Interpolation.average))
          : baked;
      final jpg = Uint8List.fromList(img.encodeJpg(out, quality: quality));
      // Re-encoding a small, already well-compressed picture can make it bigger: keep the original then.
      if (!big && jpg.length >= bytes.length) return null;
      return jpg;
    } catch (_) {
      return null;
    }
  }

  /// [shrink] off the main thread, so the composer never stutters.
  static Future<Uint8List?> shrinkInBackground(Uint8List bytes) => compute(_shrinkEntry, bytes);

  static Uint8List? _shrinkEntry(Uint8List bytes) => shrink(bytes);

  /// The file name after re-encoding to JPEG ("IMG_1.png" -> "IMG_1.jpg").
  static String jpgName(String name) {
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    return '$base.jpg';
  }
}
