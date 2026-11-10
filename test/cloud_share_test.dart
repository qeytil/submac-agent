import 'package:flutter_test/flutter_test.dart';

import 'package:agent/services/cloud.dart';

/// The engine makes the model calls and consumes its replies, so the native proxy (android_native/LocalProxy.kt)
/// reads `x-telesia-bg` and sends it to Dart. These tests pin the Dart end of that path (bug audit 2026-11-07).
void main() {
  tearDown(() => Cloud.background.value = const BackgroundShare());

  test('the bots\' share from an engine reply updates the same state as a Dart call', () {
    Cloud.noteBackgroundShare('0.4');
    expect(Cloud.background.value.ratio, closeTo(0.4, 0.0001));
    expect(Cloud.background.value.pausedNow, isFalse);
    expect(Cloud.background.value.stale, isFalse);
    expect(Cloud.background.value.line, contains('40%'));

    Cloud.noteBackgroundShare('1');
    expect(Cloud.background.value.pausedNow, isTrue);
    expect(Cloud.background.value.line, contains('paused'));
  });

  test('garbage is ignored and a paused day is not undone by a later reply', () {
    Cloud.noteBackgroundShare('nonsense');
    expect(Cloud.background.value.ratio, 0);
    expect(Cloud.background.value.pausedNow, isFalse);

    Cloud.markBackgroundPaused();
    Cloud.noteBackgroundShare('0.2');
    expect(Cloud.background.value.pausedNow, isTrue, reason: 'the share stays paused for the rest of the day');
    expect(Cloud.background.value.ratio, 1);
  });

  test('a server reply read by Dart takes the same path', () {
    Cloud.readHeaders(const {'x-telesia-bg': '0.25'});
    expect(Cloud.background.value.ratio, closeTo(0.25, 0.0001));
    expect(Cloud.background.value.pausedNow, isFalse);
  });
}