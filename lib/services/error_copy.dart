import '../ui/i18n.dart' show AppLang;
import 'calm.dart';
import 'llm_client.dart';

/// The error card's words in the app's language (CB-27). A failed run used to store `e.toString()` and show it as is:
/// English only, the server's own sentences, and sometimes a class name ("GenkitException: …").
///
/// Now a failed run stores a short tag with the error's code and status in front of the raw text
/// (`[[err:busy:503]] The model is busy`). The card picks its title and body from the code (or, for older messages
/// and errors without a code, from [Calm.explain]) in English, Somali or Arabic; the raw text shows only under Details,
/// without the tag and without any exception class name.
class ErrorCopy {
  ErrorCopy._();

  static final _tag = RegExp(r'^\[\[err:([a-z0-9_]*):(\d+)\]\]\s?');
  static final _className = RegExp(r'^(?:\w*(?:Exception|Error)\s*:\s*)+');

  /// What a failed run stores on its reply.
  static String store(Object e) {
    if (e is LlmException) {
      final msg = clean(e.message);
      if (e.code.isEmpty && e.status == 0) return msg;
      return '[[err:${e.code.toLowerCase()}:${e.status}]] $msg';
    }
    return clean(e.toString());
  }

  /// The raw text without any exception class name in front ("GenkitException: ", "Exception: ").
  static String clean(String s) => s.trim().replaceFirst(_className, '').trim();

  /// The code and status a stored error carries ('' and 0 when it has none).
  static (String, int) codeOf(String stored) {
    final m = _tag.firstMatch(stored.trim());
    if (m == null) return ('', 0);
    return (m.group(1)!, int.tryParse(m.group(2)!) ?? 0);
  }

  /// The raw text to show under Details (and to match billing notices on): no tag, no class name.
  static String detail(String stored) => clean(stored.trim().replaceFirst(_tag, ''));

  /// Which kind of problem an error code and status mean, or null to work it out from the text.
  static String? kindFor(String code, int status) {
    switch (code) {
      case 'busy':
      case 'server':
        return 'busy';
      case 'limit_daily':
      case 'limit_total':
      case 'no_plan':
      case 'daily_limit':
      case 'payments_pending':
        return 'limit';
      case 'background_paused':
      case 'paused':
        return 'paused';
      case 'blocked':
        return 'blocked';
      case 'auth':
        return 'auth';
      case 'too_long':
      case 'too_large':
        return 'too_long';
      case 'dropped':
        return 'busy';
      case 'timeout':
        return 'timeout';
      case 'offline':
        return 'offline';
    }
    if (status == 401 || status == 403) return 'auth';
    if (status == 413) return 'too_long';
    if (status == 429 || status >= 500) return 'busy';
    return null;
  }

  /// The card for a stored error: (title, body, action) in [lang] (the app's language by default).
  static CalmError explain(String stored, {String? lang}) {
    final l = lang ?? AppLang.I.code;
    final raw = detail(stored);
    final (code, status) = codeOf(stored);
    final kind = kindFor(code, status) ?? Calm.explain(raw).kind;
    final words = _words[l]?[kind] ?? _words['en']![kind] ?? _words['en']!['generic']!;
    return CalmError(words.$1, words.$2, _actions[kind] ?? 'retry', raw, kind: kind);
  }

  /// A button word on the error card in [lang].
  static String button(String en, {String? lang}) {
    final l = lang ?? AppLang.I.code;
    return _buttons[l]?[en] ?? en;
  }

  static const _actions = {
    'limit': 'none',
    'busy_tap': 'retry',
    'auth': 'settings',
    'blocked': 'none',
    'paused': 'retry',
    'too_long': 'newchat',
    'offline': 'retry',
    'timeout': 'retry',
    'busy': 'retry',
    'refused': 'retry',
    'empty': 'retry',
    'not_saved': 'none',
    'generic': 'retry',
  };

  /// Every kind, in every language. Somali and Arabic need a native read before launch.
  static const Map<String, Map<String, (String, String)>> _words = {
    'en': {
      'limit': ('That\'s it for today', 'You\'ve used today\'s allowance. It refreshes tomorrow.'),
      'busy_tap': ('Telesia is busy', 'Tap to try again.'),
      'auth': ('Please sign in again', 'Your session ended. Log out and back in from Settings, then try again.'),
      'blocked': ('Your account needs attention', 'Please contact Telesia support at submac.site.'),
      'paused': ('Telesia is taking a short break', 'Please try again in a few minutes.'),
      'too_long': ('This chat got too long', 'Start a new chat; I\'ll keep what matters in memory.'),
      'offline': ('No connection', 'I couldn\'t reach the internet. Check your data or Wi-Fi, then try again.'),
      'timeout': ('That took too long', 'Try again in a moment.'),
      'busy': ('Telesia is busy', 'Lots of people are using it right now. Try again in a moment.'),
      'refused': ('I couldn\'t answer that', 'Try rewording it.'),
      'empty': ('No answer came back', 'Try again.'),
      'not_saved': ('Not saved yet', 'Your message is here, but it didn\'t sync. It will try again.'),
      'generic': ('That didn\'t go through', 'Something went wrong on the way. Try again.'),
    },
    'so': {
      'limit': ('Maanta intaas ayay ahayd', 'Waad isticmaashay qoondada maanta. Berri ayay cusboonaanaysaa.'),
      'busy_tap': ('Telesia waa mashquul', 'Taabo si aad mar kale isugu dayto.'),
      'auth': ('Fadlan mar kale gal', 'Fadhigaagii wuu dhammaaday. Ka bax oo dib u gal Dejinta, kadib mar kale isku day.'),
      'blocked': ('Akoonkaagu wuxuu u baahan yahay fiiro', 'Fadlan la xiriir taageerada Telesia ee submac.site.'),
      'paused': ('Telesia waxay qaadanaysaa nasasho gaaban', 'Fadlan mar kale isku day dhowr daqiiqo kadib.'),
      'too_long': ('Sheekadani aad bay u dheeraatay', 'Bilow sheeko cusub; waxa muhiimka ah xusuusta ayaan ku hayn doonaa.'),
      'offline': ('Internet ma jiro', 'Internet-ka waan gaari waayay. Hubi xogtaada ama Wi-Fi-ga, kadib mar kale isku day.'),
      'timeout': ('Wakhti badan ayay qaadatay', 'Mar kale isku day daqiiqad kadib.'),
      'busy': ('Telesia waa mashquul', 'Dad badan ayaa hadda isticmaalaya. Mar kale isku day daqiiqad kadib.'),
      'refused': ('Taas kama jawaabi karo', 'Isku day inaad si kale u qorto.'),
      'empty': ('Jawaab ma soo noqon', 'Mar kale isku day.'),
      'not_saved': ('Weli lama kaydin', 'Fariintaadu halkan way taal, laakiin lama isku xirin. Mar kale ayay isku dayi doontaa.'),
      'generic': ('Taasi ma dhicin', 'Wax baa khaldamay. Mar kale isku day.'),
    },
    'ar': {
      'limit': ('هذا كل شيء لليوم', 'استخدمت حصة اليوم. ستتجدد غدًا.'),
      'busy_tap': ('Telesia مشغول', 'انقر للمحاولة مرة أخرى.'),
      'auth': ('يُرجى تسجيل الدخول مرة أخرى', 'انتهت جلستك. سجّل الخروج ثم الدخول من الإعدادات، ثم حاول مرة أخرى.'),
      'blocked': ('حسابك يحتاج إلى مراجعة', 'يُرجى التواصل مع دعم Telesia عبر submac.site.'),
      'paused': ('Telesia في استراحة قصيرة', 'يُرجى المحاولة مرة أخرى بعد بضع دقائق.'),
      'too_long': ('أصبحت هذه المحادثة طويلة جدًا', 'ابدأ محادثة جديدة؛ سأحتفظ بما يهم في الذاكرة.'),
      'offline': ('لا يوجد اتصال', 'تعذّر الوصول إلى الإنترنت. تحقّق من بيانات الهاتف أو شبكة Wi-Fi ثم حاول مرة أخرى.'),
      'timeout': ('استغرق الأمر وقتًا طويلًا', 'حاول مرة أخرى بعد قليل.'),
      'busy': ('Telesia مشغول', 'يستخدمه الكثيرون الآن. حاول مرة أخرى بعد قليل.'),
      'refused': ('لم أستطع الإجابة عن ذلك', 'حاول إعادة الصياغة.'),
      'empty': ('لم تصل أي إجابة', 'حاول مرة أخرى.'),
      'not_saved': ('لم يُحفظ بعد', 'رسالتك هنا، لكنها لم تُزامَن. ستتم المحاولة مرة أخرى.'),
      'generic': ('لم يكتمل ذلك', 'حدث خطأ في الطريق. حاول مرة أخرى.'),
    },
  };

  static const Map<String, Map<String, String>> _buttons = {
    'so': {
      'Try again': 'Isku day mar kale',
      'Open Settings': 'Fur Dejinta',
      'New chat': 'Sheeko cusub',
      'Details': 'Faahfaahin',
      'Hide details': 'Qari faahfaahinta',
    },
    'ar': {
      'Try again': 'حاول مرة أخرى',
      'Open Settings': 'افتح الإعدادات',
      'New chat': 'محادثة جديدة',
      'Details': 'التفاصيل',
      'Hide details': 'إخفاء التفاصيل',
    },
  };

  /// Every kind the card can show (for tests).
  static Iterable<String> get kinds => _words['en']!.keys;

  /// The words of [kind] in [lang] (for tests).
  static (String, String)? wordsFor(String kind, String lang) => _words[lang]?[kind];
}
