import 'i18n.dart' show AppLang;

/// The Feedback screen's words in English, Somali and Arabic, keyed by the English text like [tr].
/// Kept in its own table (like BillingCopy and ErrorCopy) so the feature does not touch the shared Strings table.
/// Somali and Arabic wording should get a native read before launch.
String ft(String en, [Map<String, String> args = const {}]) {
  var s = FeedbackWords.table[AppLang.I.code]?[en] ?? en;
  args.forEach((k, v) => s = s.replaceAll('{$k}', v));
  return s;
}

class FeedbackWords {
  FeedbackWords._();

  /// Every English key the app uses. The test checks that Somali and Arabic cover each one.
  static const keys = <String>[
    'Send feedback',
    'Email us',
    'Tell us what went wrong or what you would like. Screenshots help.',
    'Write your feedback',
    'Write your feedback first.',
    'Problem',
    'Idea',
    'Other',
    'Screenshots',
    '{n} of {max}',
    'Add screenshot',
    'Choose from gallery',
    'Take a photo',
    'Remove screenshot',
    'Send',
    'Sending…',
    'Uploading screenshot {n} of {total}',
    'Saving your feedback',
    'Try again',
    'Thank you',
    'Your feedback reached the Telesia team.',
    'Done',
    'You are offline. Your feedback is kept here; send it when you are back online.',
    'Sign in to send feedback.',
    'You have sent a lot of feedback today. Please try again tomorrow.',
    'That picture is too big. Each screenshot can be up to 5 MB.',
    'Only pictures can be attached (PNG, JPG, WebP, GIF or HEIC).',
    'You can attach up to 5 screenshots.',
    'Something went wrong and your feedback was not sent. It is kept here.',
    'The camera is not available.',
    'Your feedback is too long.',
  ];

  static const Map<String, Map<String, String>> table = {
    'so': {
      'Send feedback': 'Soo dir fikrad',
      'Email us': 'Iimayl noo soo dir',
      'Tell us what went wrong or what you would like. Screenshots help.':
          'Noo sheeg waxa khaldamay ama waxa aad jeclaan lahayd. Sawirrada shaashaddu way caawiyaan.',
      'Write your feedback': 'Qor fikraddaada',
      'Write your feedback first.': 'Marka hore qor fikraddaada.',
      'Problem': 'Dhibaato',
      'Idea': 'Fikrad cusub',
      'Other': 'Kale',
      'Screenshots': 'Sawirrada shaashadda',
      '{n} of {max}': '{n} ka mid ah {max}',
      'Add screenshot': 'Ku dar sawir',
      'Choose from gallery': 'Ka dooro sawirrada',
      'Take a photo': 'Sawir qaado',
      'Remove screenshot': 'Ka saar sawirka',
      'Send': 'Dir',
      'Sending…': 'Waa la dirayaa…',
      'Uploading screenshot {n} of {total}': 'Sawirka {n} ee {total} ayaa la dirayaa',
      'Saving your feedback': 'Fikraddaada ayaa la kaydinayaa',
      'Try again': 'Isku day mar kale',
      'Thank you': 'Mahadsanid',
      'Your feedback reached the Telesia team.': 'Fikraddaadu waxay gaartay kooxda Telesia.',
      'Done': 'Dhammaad',
      'You are offline. Your feedback is kept here; send it when you are back online.':
          'Internet ma haysid. Fikraddaada halkan ayay ku kaydsan tahay; dir marka internetku soo laabto.',
      'Sign in to send feedback.': 'Gal akoonkaaga si aad fikrad u dirto.',
      'You have sent a lot of feedback today. Please try again tomorrow.':
          'Maanta fikrado badan ayaad soo dirtay. Fadlan berri isku day.',
      'That picture is too big. Each screenshot can be up to 5 MB.': 'Sawirkaas aad buu u weyn yahay. Sawir kasta wuxuu noqon karaa ilaa 5 MB.',
      'Only pictures can be attached (PNG, JPG, WebP, GIF or HEIC).': 'Sawirro keliya ayaa lagu dari karaa (PNG, JPG, WebP, GIF ama HEIC).',
      'You can attach up to 5 screenshots.': 'Waxaad ku dari kartaa ilaa 5 sawir.',
      'Something went wrong and your feedback was not sent. It is kept here.':
          'Wax baa khaldamay, fikraddaadana lama dirin. Halkan ayay ku kaydsan tahay.',
      'The camera is not available.': 'Kamaradu lama heli karo.',
      'Your feedback is too long.': 'Fikraddaadu aad bay u dheer tahay.',
    },
    'ar': {
      'Send feedback': 'أرسل ملاحظاتك',
      'Email us': 'راسلنا بالبريد',
      'Tell us what went wrong or what you would like. Screenshots help.': 'أخبرنا بما حدث من خطأ أو بما تودّ أن تراه. لقطات الشاشة تساعدنا.',
      'Write your feedback': 'اكتب ملاحظاتك',
      'Write your feedback first.': 'اكتب ملاحظاتك أولاً.',
      'Problem': 'مشكلة',
      'Idea': 'فكرة',
      'Other': 'أخرى',
      'Screenshots': 'لقطات الشاشة',
      '{n} of {max}': '{n} من {max}',
      'Add screenshot': 'أضف لقطة شاشة',
      'Choose from gallery': 'اختر من المعرض',
      'Take a photo': 'التقط صورة',
      'Remove screenshot': 'أزل لقطة الشاشة',
      'Send': 'إرسال',
      'Sending…': 'جارٍ الإرسال…',
      'Uploading screenshot {n} of {total}': 'جارٍ رفع اللقطة {n} من {total}',
      'Saving your feedback': 'جارٍ حفظ ملاحظاتك',
      'Try again': 'حاول مرة أخرى',
      'Thank you': 'شكراً لك',
      'Your feedback reached the Telesia team.': 'وصلت ملاحظاتك إلى فريق Telesia.',
      'Done': 'تم',
      'You are offline. Your feedback is kept here; send it when you are back online.':
          'أنت غير متصل بالإنترنت. ملاحظاتك محفوظة هنا؛ أرسلها عند عودة الاتصال.',
      'Sign in to send feedback.': 'سجّل الدخول لإرسال الملاحظات.',
      'You have sent a lot of feedback today. Please try again tomorrow.': 'لقد أرسلت ملاحظات كثيرة اليوم. يُرجى المحاولة غداً.',
      'That picture is too big. Each screenshot can be up to 5 MB.': 'هذه الصورة كبيرة جداً. يمكن أن يصل حجم كل لقطة إلى 5 ميغابايت.',
      'Only pictures can be attached (PNG, JPG, WebP, GIF or HEIC).': 'يمكن إرفاق الصور فقط (PNG أو JPG أو WebP أو GIF أو HEIC).',
      'You can attach up to 5 screenshots.': 'يمكنك إرفاق 5 لقطات شاشة كحد أقصى.',
      'Something went wrong and your feedback was not sent. It is kept here.': 'حدث خطأ ولم تُرسل ملاحظاتك. إنها محفوظة هنا.',
      'The camera is not available.': 'الكاميرا غير متاحة.',
      'Your feedback is too long.': 'ملاحظاتك طويلة جداً.',
    },
  };
}
