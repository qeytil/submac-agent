import 'package:agent/main.dart' show GateStep, GateSwitch, LaunchGate, gateStep, shouldShowIntro;
import 'package:agent/screens/auth_screen.dart';
import 'package:agent/screens/intro_screen.dart';
import 'package:agent/services/first_launch.dart';
import 'package:agent/services/intro_sound.dart';
import 'package:agent/theme.dart';
import 'package:agent/ui/i18n.dart';
import 'package:agent/ui/intro_motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// First-launch intro, the 18+ agreement on the sign-in screen, and the move from sign-in to chat (2026-10-26).
class FakeSound implements IntroSound {
  FakeSound({this.fail = false});
  final bool fail;
  final calls = <String>[];

  @override
  Future<void> play() async {
    calls.add('play');
    if (fail) throw Exception('no audio');
  }

  @override
  Future<void> stop() async => calls.add('stop');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<String> haptics;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    haptics = [];
    // The haptics go through the platform channel; record them there.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') haptics.add('${call.arguments}'.replaceFirst('HapticFeedbackType.', ''));
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
    ConsentStore.write = (_) async {};
  });

  Widget host(Widget child, {bool still = false}) => MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: still),
            child: child,
          ),
        ),
      );

  int count(String kind) => haptics.where((h) => h == kind).length;

  group('first-launch intro', () {
    test('shows only on the first open, before anyone signs in', () async {
      expect(shouldShowIntro(seen: false, signedIn: false), isTrue);
      expect(shouldShowIntro(seen: true, signedIn: false), isFalse);
      expect(shouldShowIntro(seen: false, signedIn: true), isFalse);

      await IntroFlag.load();
      expect(IntroFlag.seen, isFalse);
      await IntroFlag.markSeen();
      IntroFlag.seen = false;
      await IntroFlag.load(); // the next cold start
      expect(IntroFlag.seen, isTrue);
    });

    testWidgets('plays the draw, ticks per letter, lands the dot, then hands over to sign-in', (tester) async {
      final sound = FakeSound();
      await tester.pumpWidget(host(LaunchGate(showIntro: true, sound: sound, child: const Text('SIGN-IN'))));
      expect(find.byType(IntroScreen), findsOneWidget);
      expect(find.text('SIGN-IN'), findsNothing);
      expect(sound.calls, ['play'], reason: 'the sound starts with the draw');

      // Halfway through the draw: some letters ticked, not all, and no impact yet.
      await tester.pump(const Duration(milliseconds: 750));
      expect(count('selectionClick'), inInclusiveRange(1, 5));
      expect(count('mediumImpact'), 0);

      // The draw is done: one tick per letter of "Telesia", at most six.
      await tester.pump(const Duration(milliseconds: 800)); // 1550 ms
      expect(count('selectionClick'), IntroMotion.word.length);
      expect(IntroMotion.word.length, lessThanOrEqualTo(6));
      expect(count('mediumImpact'), 0, reason: 'the impact waits for the dot');

      // The dot lands (2250 ms): one soft impact.
      await tester.pump(const Duration(milliseconds: 750)); // 2300 ms
      expect(count('mediumImpact'), 1);

      // The end: sign-in fades in, the intro is gone, and it is marked as seen.
      await tester.pump(const Duration(milliseconds: 800)); // 3100 ms
      await tester.pump(IntroMotion.handoff);
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('SIGN-IN'), findsOneWidget);
      expect(find.byType(IntroScreen), findsNothing);
      expect(count('selectionClick'), 6);
      expect(count('mediumImpact'), 1);
      expect(sound.calls, ['play'], reason: 'a finished intro lets the tail ring out');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(IntroFlag.key), isTrue);
    });

    testWidgets('a tap skips it: sound and ticks stop at once', (tester) async {
      final sound = FakeSound();
      await tester.pumpWidget(host(LaunchGate(showIntro: true, sound: sound, child: const Text('SIGN-IN'))));
      await tester.pump(const Duration(milliseconds: 500));
      final ticksBefore = haptics.length;
      expect(ticksBefore, greaterThan(0));

      await tester.tap(find.byType(IntroScreen));
      await tester.pump();
      expect(sound.calls, ['play', 'stop']);

      await tester.pump(const Duration(seconds: 3));
      expect(haptics.length, ticksBefore, reason: 'no tick or impact after a skip');
      expect(find.text('SIGN-IN'), findsOneWidget);
      expect(find.byType(IntroScreen), findsNothing);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(IntroFlag.key), isTrue);
    });

    testWidgets('a sound that fails to load never stops the intro', (tester) async {
      final sound = FakeSound(fail: true);
      await tester.pumpWidget(host(LaunchGate(showIntro: true, sound: sound, child: const Text('SIGN-IN'))));
      await tester.pump(IntroMotion.total);
      await tester.pump(IntroMotion.handoff);
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('SIGN-IN'), findsOneWidget);
      expect(count('mediumImpact'), 1);
    });

    testWidgets('with Remove animations: a quick fade, one light tick, no sound', (tester) async {
      final sound = FakeSound();
      await tester.pumpWidget(host(LaunchGate(showIntro: true, sound: sound, child: const Text('SIGN-IN')), still: true));
      await tester.pump(IntroMotion.still);
      await tester.pump(const Duration(milliseconds: 50));
      expect(haptics, ['selectionClick']);
      expect(sound.calls, isEmpty);
      expect(find.text('SIGN-IN'), findsOneWidget);
    });

    testWidgets('later starts go straight to the app', (tester) async {
      final sound = FakeSound();
      await tester.pumpWidget(host(LaunchGate(showIntro: false, sound: sound, child: const Text('SIGN-IN'))));
      expect(find.text('SIGN-IN'), findsOneWidget);
      expect(find.byType(IntroScreen), findsNothing);
      expect(sound.calls, isEmpty);
      expect(haptics, isEmpty);
    });
  });

  group('agreement on the sign-in screen', () {
    FilledButton filled(WidgetTester t, String label) =>
        t.widget<FilledButton>(find.ancestor(of: find.text(label), matching: find.byType(FilledButton)).first);
    OutlinedButton outlined(WidgetTester t, String label) =>
        t.widget<OutlinedButton>(find.ancestor(of: find.text(label), matching: find.byType(OutlinedButton)).first);
    TextButton textButton(WidgetTester t, String label) =>
        t.widget<TextButton>(find.ancestor(of: find.text(label), matching: find.byType(TextButton)).first);

    testWidgets('Google stays off until the box is ticked', (tester) async {
      await tester.pumpWidget(host(const AuthScreen(google: true)));
      expect(find.byType(ConsentTick), findsOneWidget);
      expect(outlined(tester, 'Continue with Google').onPressed, isNull);
      await tester.tap(find.byType(Checkbox));
      await tester.pump();
      expect(outlined(tester, 'Continue with Google').onPressed, isNotNull);
    });

    testWidgets('log in and the reset code stay off until the box is ticked', (tester) async {
      await tester.pumpWidget(host(const AuthScreen(google: false)));
      await tester.tap(find.text('Log in'));
      await tester.pumpAndSettle();
      expect(find.byType(ConsentTick), findsOneWidget);
      expect(filled(tester, 'Continue').onPressed, isNull);
      expect(textButton(tester, 'Forgot password?').onPressed, isNull);
      await tester.tap(find.byType(Checkbox));
      await tester.pump();
      expect(filled(tester, 'Continue').onPressed, isNotNull);
      expect(textButton(tester, 'Forgot password?').onPressed, isNotNull);
    });

    testWidgets('sign-up stays off until the box is ticked, and the tick carries across', (tester) async {
      await tester.pumpWidget(host(const AuthScreen(google: false)));
      await tester.tap(find.byType(Checkbox)); // ticked on the first page
      await tester.pump();
      await tester.tap(find.text('Create account'));
      await tester.pumpAndSettle();
      expect(filled(tester, 'Continue').onPressed, isNotNull);
      await tester.tap(find.byType(Checkbox)); // untick
      await tester.pump();
      expect(filled(tester, 'Continue').onPressed, isNull);
    });

    test('the sentence keeps both links', () {
      final s = ConsentTick.sentence;
      final parts = ConsentTick.splitHoles(s);
      expect(parts.where((p) => p == '{terms}').length, 1);
      expect(parts.where((p) => p == '{privacy}').length, 1);
      expect(parts.join(), s);
    });
  });

  group('after sign-in', () {
    test('an account that already agreed goes straight in, ticked or not', () {
      expect(gateStep(signedIn: true, needsVerify: false, hasConsent: true, ticked: false), GateStep.home);
      expect(gateStep(signedIn: true, needsVerify: false, hasConsent: true, ticked: true), GateStep.home);
      expect(gateStep(signedIn: false, needsVerify: false, hasConsent: false, ticked: true), GateStep.signIn);
      expect(gateStep(signedIn: true, needsVerify: true, hasConsent: false, ticked: true), GateStep.verify);
    });

    test('a new phone or a Google sign-in with no agreement saved: it is saved, no separate page', () {
      expect(gateStep(signedIn: true, needsVerify: false, hasConsent: false, ticked: true), GateStep.recordConsent);
      // Only a session kept from an older version that never ticked here sees the agreement view.
      expect(gateStep(signedIn: true, needsVerify: false, hasConsent: false, ticked: false), GateStep.confirmConsent);
    });

    testWidgets('the tick is saved on the account with the same fields as before, out of sight', (tester) async {
      final writes = <Map<String, dynamic>>[];
      ConsentStore.write = (d) async => writes.add(d);
      await ConsentPending.mark();
      expect(ConsentPending.active, isTrue);

      await tester.pumpWidget(host(const ConsentRecorder()));
      await tester.pump();
      expect(writes, hasLength(1));
      expect(writes.single.keys.toSet(), {'consent_v', 'age_18', 'consent_at'});
      expect(writes.single['consent_v'], AuthRules.consentVersion);
      expect(writes.single['age_18'], isTrue);
      expect(AuthRules.hasConsent(writes.single), isTrue);
      expect(ConsentPending.active, isFalse);
      // No second page: no tick, no "Agree and continue".
      expect(find.byType(Checkbox), findsNothing);
      expect(find.text('Agree and continue'), findsNothing);
    });

    testWidgets('a failed save offers to try again', (tester) async {
      var tries = 0;
      ConsentStore.write = (d) async {
        tries++;
        if (tries == 1) throw Exception('offline');
      };
      await tester.pumpWidget(host(const ConsentRecorder()));
      await tester.pump();
      expect(find.text('Try again'), findsOneWidget);
      await tester.tap(find.text('Try again'));
      await tester.pump();
      expect(tries, 2);
      expect(find.text('Try again'), findsNothing);
    });

    test('the tick expires after a day', () async {
      await ConsentPending.mark(now: DateTime.now().subtract(const Duration(hours: 25)));
      expect(ConsentPending.active, isFalse);
      await ConsentPending.mark();
      await ConsentPending.load();
      expect(ConsentPending.active, isTrue);
      await ConsentPending.clear();
      expect(ConsentPending.active, isFalse);
    });
  });

  group('sign-in to chat', () {
    Widget gate(String page) => GateSwitch(child: Text(page, key: ValueKey(page)));

    testWidgets('chat fades and settles in instead of a hard cut', (tester) async {
      final key = GlobalKey<State<StatefulWidget>>();
      var page = 'SIGN-IN';
      await tester.pumpWidget(host(StatefulBuilder(key: key, builder: (context, set) => gate(page))));
      expect(find.text('SIGN-IN'), findsOneWidget);

      page = 'CHAT';
      // ignore: invalid_use_of_protected_member
      key.currentState!.setState(() {});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // Mid-way both are on screen and chat is partly faded and slightly scaled.
      expect(find.text('SIGN-IN'), findsOneWidget);
      expect(find.text('CHAT'), findsOneWidget);
      final fade = tester.widget<FadeTransition>(find.ancestor(of: find.text('CHAT'), matching: find.byType(FadeTransition)).first);
      expect(fade.opacity.value, inExclusiveRange(0.0, 1.0));
      final scale = tester.widget<ScaleTransition>(find.ancestor(of: find.text('CHAT'), matching: find.byType(ScaleTransition)).first);
      expect(scale.scale.value, inExclusiveRange(0.97, 1.0));

      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('SIGN-IN'), findsNothing);
      expect(find.text('CHAT'), findsOneWidget);
      expect(IntroMotion.handoff.inMilliseconds, inInclusiveRange(500, 700));
    });

    testWidgets('with Remove animations it simply switches', (tester) async {
      final key = GlobalKey<State<StatefulWidget>>();
      var page = 'SIGN-IN';
      await tester.pumpWidget(host(StatefulBuilder(key: key, builder: (context, set) => gate(page)), still: true));
      page = 'CHAT';
      // ignore: invalid_use_of_protected_member
      key.currentState!.setState(() {});
      await tester.pump();
      await tester.pump();
      expect(find.text('SIGN-IN'), findsNothing);
      expect(find.text('CHAT'), findsOneWidget);
    });
  });

  test('the language table still reads', () => expect(tr('Terms of Use'), isNotEmpty));
}
