import 'dart:typed_data';

import '../models.dart';
import 'image_once.dart';
import 'photo_prep.dart';

/// CB-23: a follow-up about a photo must still reach a route that can see.
///
/// Each picture goes to the model once ([ImageOnce]); later turns get a one-line note. The server picks its route from
/// what a request carries, so a text-only follow-up ("what colour is it?") went to a route with no vision and the
/// answer was guessed. For [turns] user turns after the latest photo, or later when the user's words point at it,
/// that photo goes along again as a smaller copy ([edge] px, JPEG [quality]).
class VisionFollowUp {
  VisionFollowUp._();

  /// User turns after a photo that still carry it.
  static const turns = 3;

  /// Size of the copy sent again (the model saw the full picture the first time).
  static const edge = 1024, quality = 70;

  static final RegExp _refers = RegExp(
    r'\b(photos?|pictures?|pics?|images?|screenshots?|screen ?shots?|selfies?|scans?|snaps?|sawir\w*|muuqaal\w*)\b'
    r'|صور|الصورة|صورة|لقطة',
    caseSensitive: false,
  );

  /// True when [text] talks about a picture ("in the photo", "sawirka", "الصورة").
  static bool refersToImage(String text) => _refers.hasMatch(text);

  /// The picture keys ([ImageOnce.keyOf]) the request built from [list] should carry again: the last picture of the
  /// latest message with one, when it is 1..[turns] user turns back or the newest user text refers to a picture.
  /// Empty while the photo's own turn runs (it went out on that turn's first step) and when no picture is left.
  static Set<String> again(List<ChatMessage> list, {bool Function(ChatMessage m)? countsAsTurn}) {
    final counts = countsAsTurn ?? (_) => true;
    var turnsAfter = 0;
    ChatMessage? newest;
    for (var i = list.length - 1; i >= 0; i--) {
      final m = list[i];
      if (m.role != 'user') continue;
      newest ??= m;
      final ai = m.attachments.lastIndexWhere((a) => a.isImage && a.bytes != null);
      if (ai >= 0) {
        if (turnsAfter == 0) return const {};
        if (turnsAfter <= turns || refersToImage(newest.content)) return {ImageOnce.keyOf(m.id, ai)};
        return const {};
      }
      if (counts(m)) turnsAfter++;
    }
    return const {};
  }

  static final Map<String, Uint8List> _small = {};

  /// A smaller copy of the picture under [key] (kept for the last few, so each step does not shrink it again).
  /// The original when it is already small or cannot be read.
  static Uint8List smallCopy(String key, Uint8List bytes) {
    final hit = _small.remove(key);
    if (hit != null) return _small[key] = hit;
    final out = PhotoPrep.shrink(bytes, max: edge, quality: quality) ?? bytes;
    _small[key] = out;
    while (_small.length > 4) {
      _small.remove(_small.keys.first);
    }
    return out;
  }

  /// The mime type of [smallCopy]'s result.
  static String mimeOf(Uint8List copy, String original) =>
      copy.length >= 3 && copy[0] == 0xFF && copy[1] == 0xD8 && copy[2] == 0xFF ? 'image/jpeg' : original;
}
