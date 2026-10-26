import 'dart:async';

import 'package:audioplayers/audioplayers.dart';

/// The intro's sound: one soft rounded pluck per letter of the wordmark, on the haptic ticks, then a warm two-note bloom
/// as the logo resolves and the dot lands (assets/intro/intro_sound.m4a, 3.3 s, about -17.5 LUFS; synthesized for
/// SubMac by tools/intro_sound.py, no samples).
///
/// It never gets in the way:
/// * an ambient session: it mixes with (and on Android briefly ducks) the user's music, never stops it;
/// * silent when the phone is muted: Android plays it as a sonification sound on the system stream, which follows
///   silent and vibrate mode; iOS uses the ambient category, which follows the mute switch;
/// * any failure to load or play is swallowed, so the intro runs on silently;
/// * [stop] cuts it at once (skip).
abstract class IntroSound {
  Future<void> play();
  Future<void> stop();

  /// The real player. Tests pass their own [IntroSound].
  factory IntroSound.device() => _DeviceIntroSound();
}

class _DeviceIntroSound implements IntroSound {
  static const asset = 'intro/intro_sound.m4a'; // under AudioCache's 'assets/' prefix

  static final context = AudioContext(
    android: const AudioContextAndroid(
      contentType: AndroidContentType.sonification,
      usageType: AndroidUsageType.assistanceSonification,
      audioFocus: AndroidAudioFocus.gainTransientMayDuck,
    ),
    iOS: AudioContextIOS(category: AVAudioSessionCategory.ambient),
  );

  AudioPlayer? _player;
  bool _stopped = false;

  @override
  Future<void> play() async {
    try {
      final p = _player ??= AudioPlayer(playerId: 'submac_intro');
      await p.setAudioContext(context);
      await p.setReleaseMode(ReleaseMode.release);
      if (_stopped) return;
      await p.play(AssetSource(asset), volume: 0.9);
      if (_stopped) await p.stop();
      unawaited(p.onPlayerComplete.first.then((_) => _release()).catchError((_) {}));
    } catch (_) {
      // No sound is fine: the intro carries on.
    }
  }

  @override
  Future<void> stop() async {
    _stopped = true;
    try {
      await _player?.stop();
    } catch (_) {}
    await _release();
  }

  Future<void> _release() async {
    final p = _player;
    _player = null;
    try {
      await p?.dispose();
    } catch (_) {}
  }
}
