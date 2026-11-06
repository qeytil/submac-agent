import 'dart:convert';

import '../ui/i18n.dart' show AppLang;
import 'context_window.dart';

/// CB-30: a message too long for one model call. A huge paste used to be uploaded four times (about 530 KB each) and
/// ended in "This chat got too long". Now a paste over [maxChars] never leaves the phone as it is: the user picks
/// "Attach as a file" or "Summarise in parts", and the text goes as a file the agent reads a part at a time.
class PasteGuard {
  PasteGuard._();

  /// About 120k tokens (4 characters each): the most one message may carry.
  static const int maxChars = 480 * 1000;

  /// Over the limit: stopped before the network.
  static bool tooBig(String text) => text.length > maxChars;

  /// The newest user message is so long that folding the older chat into a summary cannot make the request fit, so a
  /// "too long" answer from the server is final at once (one upload): the message alone is over [maxChars] or fills
  /// more than half of SubMac's window.
  static bool messageAloneTooLong(String text, {int? windowTokens}) {
    final w = windowTokens ?? ContextWindow.tokens;
    return tooBig(text) || text.length ~/ 4 > w ~/ 2;
  }

  /// Size in KB for the user (UTF-8 bytes, as it would be uploaded).
  static int kbOf(String text) => (utf8.encode(text).length / 1024).ceil();

  /// The first words of the paste, so the message still says what the file is.
  static String head(String text, {int n = 240}) {
    final t = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    return t.length > n ? '${t.substring(0, n)}…' : t;
  }

  /// A file name for the paste ('pasted-20261025-1930.txt').
  static String fileName([DateTime? at]) {
    final d = at ?? DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return 'pasted-${d.year}${two(d.month)}${two(d.day)}-${two(d.hour)}${two(d.minute)}${two(d.second)}.txt';
  }

  static String _l(String? lang) {
    final l = lang ?? AppLang.I.code;
    return _title.containsKey(l) ? l : 'en';
  }

  static const _title = {
    'en': 'This message is too long to send',
    'so': 'Fariintani aad bay u dheer tahay in la diro',
    'ar': 'هذه الرسالة أطول من أن تُرسل',
  };
  static const _prompt = {
    'en': 'It is about {kb} KB, more than Telesia can read at once. Send it as a file, or have it summarised a part at a time.',
    'so': 'Waa qiyaastii {kb} KB, in ka badan inta Telesia hal mar akhrin karo. U dir fayl ahaan, ama qayb qayb ha loo soo koobo.',
    'ar': 'حجمها نحو {kb} كيلوبايت، أكثر مما يقرأه Telesia دفعة واحدة. أرسلها كملف، أو اطلب تلخيصها جزءًا جزءًا.',
  };
  static const _attach = {'en': 'Attach as a file', 'so': 'U dir fayl ahaan', 'ar': 'إرفاقها كملف'};
  static const _parts = {'en': 'Summarise in parts', 'so': 'Qayb qayb u soo koob', 'ar': 'تلخيصها على أجزاء'};
  static const _partsAsk = {
    'en': 'Summarise the attached text in parts: read it a section at a time, then give me one summary.',
    'so': 'Qoraalka ku lifaaqan qayb qayb u soo koob: akhri qayb kasta, kadibna ii keen hal soo koobid.',
    'ar': 'لخّص النص المرفق على أجزاء: اقرأه قسمًا قسمًا، ثم أعطني ملخصًا واحدًا.',
  };
  static const _notSent = {
    'en': 'Not sent. Your text is kept as a file ({name}) in your workspace.',
    'so': 'Lama dirin. Qoraalkaaga waxaa loo kaydiyay fayl ({name}) goobtaada shaqada.',
    'ar': 'لم تُرسل. نصك محفوظ كملف ({name}) في مساحة عملك.',
  };
  static const _reply = {
    'en': 'Your message is too long for me to read in one go (about {kb} KB), so I did not send it again. '
        'Paste it as a file (the paperclip), or send it in smaller parts and I will summarise each one.',
    'so': 'Fariintaadu aad bay iigu dheer tahay inaan hal mar akhriyo (qiyaastii {kb} KB), sidaa darteed mar kale ma dirin. '
        'U dir fayl ahaan (biinka), ama qaybo yaryar u dir, mid walbana waan soo koobi doonaa.',
    'ar': 'رسالتك أطول من أن أقرأها دفعة واحدة (نحو {kb} كيلوبايت)، لذلك لم أرسلها مرة أخرى. '
        'أرسلها كملف (مشبك الورق)، أو أرسلها على أجزاء أصغر وسألخص كل جزء.',
  };

  static String title({String? lang}) => _title[_l(lang)]!;
  static String prompt(int kb, {String? lang}) => _prompt[_l(lang)]!.replaceAll('{kb}', '$kb');
  static String attachOption({String? lang}) => _attach[_l(lang)]!;
  static String partsOption({String? lang}) => _parts[_l(lang)]!;
  static String partsAsk({String? lang}) => _partsAsk[_l(lang)]!;
  static String notSent(String name, {String? lang}) => _notSent[_l(lang)]!.replaceAll('{name}', name);

  /// The reply when the server said "too long" and the user's own message is the reason (no retry helps).
  static String tooLongReply(int kb, {String? lang}) => _reply[_l(lang)]!.replaceAll('{kb}', '$kb');
}
