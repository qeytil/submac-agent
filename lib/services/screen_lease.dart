/// One driver for the phone's screen at a time (2026-11-03). With opencode, a chat, a bot's wake and team members can
/// all run phone-control steps at once; two of them tapping on one screen would act inside each other's apps. The
/// first one to take a step holds the screen; another gets a plain "in use" answer until the holder has been quiet
/// for [idle]. Pure, so it is tested without the app.
class ScreenLease {
  ScreenLease({this.idle = const Duration(seconds: 90), DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final Duration idle;
  final DateTime Function() _clock;
  String? _holder;
  String _label = '';
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  /// Tools that drive the screen.
  static bool drives(String tool) => tool.startsWith('phone_') || tool == 'whatsapp';

  /// Null: [who] may go ahead (and now holds the screen). Otherwise the answer for the model.
  String? take(String who, {String label = ''}) {
    final now = _clock();
    if (_holder != null && _holder != who && now.difference(_last) < idle) {
      return 'Error: the phone screen is in use by ${_label.isEmpty ? 'another task' : _label} right now. Do not touch it; '
          'do other parts of the job, or try again in a minute.';
    }
    _holder = who;
    _label = label;
    _last = now;
    return null;
  }

  /// [who] is done with the screen (its turn ended).
  void release(String who) {
    if (_holder == who) _holder = null;
  }

  String? get holder => _holder;
}
