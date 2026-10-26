import '../ui/i18n.dart' show AppLang;

/// CB-26: how big the files on one message may be. Checked before a file is read whole, so a huge video cannot fill the
/// phone's memory; pictures are shrunk later (PhotoPrep, 2048 px JPEG 80).
class AttachLimits {
  AttachLimits._();

  static const int mb = 1024 * 1024;

  /// One file.
  static const int perFile = 20 * mb;

  /// All files on one message together.
  static const int perMessage = 25 * mb;

  /// Which of [sizes] (new files, in order) fit next to [already] bytes on the message. A file that does not fit is
  /// left out; the ones after it may still fit. [refused] holds the indexes left out and why.
  static AttachCheck check(List<int> sizes, {int already = 0}) {
    final ok = <int>[];
    final big = <int>[];
    final full = <int>[];
    var total = already;
    for (var i = 0; i < sizes.length; i++) {
      final s = sizes[i];
      if (s > perFile) {
        big.add(i);
      } else if (total + s > perMessage) {
        full.add(i);
      } else {
        ok.add(i);
        total += s;
      }
    }
    return AttachCheck(ok: ok, tooBig: big, overTotal: full);
  }

  static const _tooBig = {
    'en': 'That file is too big. Files can be up to 20 MB.',
    'so': 'Faylkaasi aad buu u weyn yahay. Fayl kasta waa ilaa 20 MB.',
    'ar': 'هذا الملف كبير جدًا. الحد الأقصى للملف 20 ميغابايت.',
  };
  static const _overTotal = {
    'en': 'That is too much for one message. Files on one message can be up to 25 MB together.',
    'so': 'Taasi waa ka badan tahay hal fariin. Faylasha hal fariin waa ilaa 25 MB wadar ahaan.',
    'ar': 'هذا كثير على رسالة واحدة. مجموع ملفات الرسالة الواحدة حتى 25 ميغابايت.',
  };

  /// The notice for a check that left files out, in the app's language ([lang] for tests). Null when all fit.
  static String? notice(AttachCheck c, {String? lang}) {
    if (c.tooBig.isEmpty && c.overTotal.isEmpty) return null;
    final l = lang ?? AppLang.I.code;
    final m = c.tooBig.isNotEmpty ? _tooBig : _overTotal;
    return m[l] ?? m['en']!;
  }
}

class AttachCheck {
  final List<int> ok, tooBig, overTotal;
  const AttachCheck({required this.ok, required this.tooBig, required this.overTotal});
}
