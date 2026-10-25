
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import 'page_model.dart';

/// One processed screenshot: a clean picture (the card's thumbnail), the same picture with numbered boxes on every
/// interactive element (set-of-marks, for the model), and a tiny grey signature to tell whether the screen changed.
class ShotSet {
  ShotSet({required this.clean, required this.marked, required this.signature, required this.width, required this.height});
  final Uint8List clean;
  final Uint8List marked;
  final List<int> signature;
  final int width;
  final int height;
}

/// Screenshot work, off the main thread. The page itself is never touched (the old overlay was drawn INTO the page,
/// which users saw flash and which sites could react to).
class Shots {
  /// Model pictures are this wide: small enough to send every step, sharp enough to read buttons.
  static const modelWidth = 720;

  /// Live frames for the card are smaller still.
  static const frameWidth = 420;

  static Future<ShotSet?> process(Uint8List raw, List<PageElement> els) async {
    try {
      return await compute(_process, [raw, [for (final e in els) if (!e.offscreen) [e.id, ...e.box]]]);
    } catch (_) {
      return null;
    }
  }

  static Future<Uint8List?> frame(Uint8List raw) async {
    try {
      return await compute(_frame, raw);
    } catch (_) {
      return null;
    }
  }

  /// Did the screen change between two signatures? (mean grey difference over an 8x8 grid)
  static bool changed(List<int>? a, List<int>? b, {double threshold = 3.0}) {
    if (a == null || b == null || a.length != b.length || a.isEmpty) return true;
    var d = 0;
    for (var i = 0; i < a.length; i++) {
      d += (a[i] - b[i]).abs();
    }
    return d / a.length > threshold;
  }

  @visibleForTesting
  static ShotSet? processSync(Uint8List raw, List<List<num>> boxes) => _process([raw, boxes]);
}

ShotSet? _process(List<dynamic> a) {
  final raw = a[0] as Uint8List;
  final boxes = (a[1] as List).cast<List>();
  final src = img.decodeImage(raw);
  if (src == null) return null;
  final im = src.width > Shots.modelWidth ? img.copyResize(src, width: Shots.modelWidth) : src;
  final clean = Uint8List.fromList(img.encodeJpg(im, quality: 62));
  final sig = _signature(im);
  final marked = im.clone();
  final w = marked.width, h = marked.height;
  // Calm, readable marks: a 2px box and a small label tab; a few colours so neighbours are told apart.
  final colours = [img.ColorRgb8(31, 111, 235), img.ColorRgb8(214, 51, 108), img.ColorRgb8(18, 140, 74), img.ColorRgb8(196, 110, 0)];
  for (var k = 0; k < boxes.length; k++) {
    final b = boxes[k];
    if (b.length < 5) continue;
    final id = (b[0] as num).toInt();
    final x1 = ((b[1] as num) * w).round().clamp(0, w - 1).toInt();
    final y1 = ((b[2] as num) * h).round().clamp(0, h - 1).toInt();
    final x2 = (((b[1] as num) + (b[3] as num)) * w).round().clamp(0, w - 1).toInt();
    final y2 = (((b[2] as num) + (b[4] as num)) * h).round().clamp(0, h - 1).toInt();
    if (x2 - x1 < 2 || y2 - y1 < 2) continue;
    final c = colours[id % colours.length];
    img.drawRect(marked, x1: x1, y1: y1, x2: x2, y2: y2, color: c, thickness: 2);
    final label = '$id';
    final tw = label.length * 8 + 4;
    final ty = y1 >= 16 ? y1 - 16 : y1;
    img.fillRect(marked, x1: x1, y1: ty, x2: (x1 + tw).clamp(0, w - 1).toInt(), y2: (ty + 16).clamp(0, h - 1).toInt(), color: c);
    img.drawString(marked, label, font: img.arial14, x: x1 + 2, y: ty + 1, color: img.ColorRgb8(255, 255, 255));
  }
  return ShotSet(
    clean: clean,
    marked: Uint8List.fromList(img.encodeJpg(marked, quality: 62)),
    signature: sig,
    width: w,
    height: h,
  );
}

Uint8List? _frame(Uint8List raw) {
  final src = img.decodeImage(raw);
  if (src == null) return null;
  final im = src.width > Shots.frameWidth ? img.copyResize(src, width: Shots.frameWidth) : src;
  return Uint8List.fromList(img.encodeJpg(im, quality: 55));
}

List<int> _signature(img.Image im) {
  final small = img.copyResize(im, width: 8, height: 8, interpolation: img.Interpolation.average);
  return [
    for (var y = 0; y < 8; y++)
      for (var x = 0; x < 8; x++) img.getLuminance(small.getPixel(x, y)).toInt(),
  ];
}
