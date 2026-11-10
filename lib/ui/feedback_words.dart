/// The Feedback screen's words (English only; owner 2026-11-08). Kept as a function like `tr` so call sites do not
/// change. `{n}`-style holes are filled from [args].
String ft(String en, [Map<String, String> args = const {}]) {
  var s = en;
  args.forEach((k, v) => s = s.replaceAll('{$k}', v));
  return s;
}

class FeedbackWords {
  FeedbackWords._();

  /// Every English key the feedback screen uses (the test checks the screen never writes a word outside this list).
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
    'Sending...',
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
}