import 'dart:io';

import 'package:agent/ui/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Motion guard (owner, 2026-10-24: "all the app have many animation glitches"): every animation in the UI takes its
/// timing and curve from SubMac's motion (lib/ui/motion.dart, also exported by lib/ui/tokens.dart as LuxMotion's
/// source). See docs/motion-audit.md for what was found and fixed.
///
/// * No raw `Curves.` in the UI layer.
/// * No raw `Duration(...)` handed to an animation (duration:, delay:, an AnimationController, animateTo).
///   Timeouts, timers and snack bars are not motion and are allowed.
/// * Every bottom sheet uses the shared sheet motion ([SubMotion.sheet]).
///
/// Billing screens are left alone (owner rule: no billing changes from UI work).
void main() {
  List<String> uiFiles() {
    final out = <String>['lib/main.dart', 'lib/theme.dart'];
    for (final dir in ['lib/screens', 'lib/widgets']) {
      for (final e in Directory(dir).listSync(recursive: true)) {
        final path = e.path.replaceAll(Platform.pathSeparator, '/');
        if (e is File && path.endsWith('.dart') && !path.contains('/billing/')) out.add(path);
      }
    }
    return out;
  }

  test('no raw curves or animation durations outside Telesia motion', () {
    final named = RegExp(r'\b(duration|reverseDuration|transitionDuration|reverseTransitionDuration|delay|themeAnimationDuration)\s*:');
    final problems = <String>[];
    for (final f in uiFiles()) {
      final lines = File(f).readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final code = lines[i].split('//').first;
        if (code.contains('Curves.')) problems.add('$f:${i + 1}: raw Curves (use SubMotion.settle / leave / ink / ambient)');
        final animated = named.hasMatch(code) || code.contains('AnimationController') || code.contains('animateTo(');
        if (animated && code.contains('Duration(') && !code.contains('SnackBar')) {
          problems.add('$f:${i + 1}: raw Duration in an animation (use a SubMotion duration)');
        }
      }
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  // CB-12 (PR-7): a zero-length AnimatedSize finishes inside its own layout and re-dirties itself, which throws under
  // "Remove animations" ("RenderAnimatedSize was mutated in its own performLayout"). Anything that can go to zero length
  // uses SubSize (no AnimatedSize at all when motion is off); a plain AnimatedSize takes a fixed SubMotion/LuxMotion time.
  test('no AnimatedSize can be zero-length under reduced motion (use SubSize)', () {
    final fixed = RegExp(r'^(SubMotion|LuxMotion)\.[a-z]\w*$');
    final problems = <String>[];
    for (final f in uiFiles()) {
      final lines = File(f).readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (!lines[i].split('//').first.contains('AnimatedSize(')) continue;
        final call = lines.sublist(i, (i + 6).clamp(0, lines.length)).join(' ');
        final m = RegExp(r'duration:\s*([^,)]+)').firstMatch(call);
        final d = m?.group(1)?.trim() ?? '';
        if (!fixed.hasMatch(d)) problems.add('$f:${i + 1}: AnimatedSize(duration: $d) can be zero-length; use SubSize');
      }
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  test('every bottom sheet uses the shared sheet motion', () {
    final call = RegExp(r'showModalBottomSheet\s*[<(]');
    final problems = <String>[];
    for (final f in uiFiles()) {
      final src = File(f).readAsStringSync();
      final calls = call.allMatches(src).length;
      final styled = 'sheetAnimationStyle: SubMotion.sheet'.allMatches(src).length;
      if (calls > styled) problems.add('$f: $calls sheet(s), $styled with SubMotion.sheet');
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  group('SubFold', () {
    Widget host(bool open, {bool still = false}) => MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(size: const Size(400, 800), disableAnimations: still),
            child: Scaffold(
              body: Column(children: [
                SubFold(open: open, child: const SizedBox(height: 120, child: Text('folded text'))),
                const Text('below'),
              ]),
            ),
          ),
        );

    testWidgets('keeps its content while it folds, then lets it go; the line under it moves smoothly', (t) async {
      await t.pumpWidget(host(true));
      final open = t.getTopLeft(find.text('below')).dy;
      await t.pumpWidget(host(false));
      await t.pump(const Duration(milliseconds: 60));
      expect(find.text('folded text'), findsOneWidget, reason: 'content stays while folding (no vanish-then-close jump)');
      final mid = t.getTopLeft(find.text('below')).dy;
      expect(mid, lessThan(open));
      await t.pumpAndSettle();
      expect(find.text('folded text'), findsNothing);
      final closed = t.getTopLeft(find.text('below')).dy;
      expect(mid, greaterThan(closed));
      await t.pumpWidget(host(true));
      await t.pumpAndSettle();
      expect(t.getTopLeft(find.text('below')).dy, open);
    });

    testWidgets('with reduced motion it opens and closes at once', (t) async {
      await t.pumpWidget(host(false, still: true));
      expect(find.text('folded text'), findsNothing);
      await t.pumpWidget(host(true, still: true));
      expect(find.text('folded text'), findsOneWidget);
      expect(t.hasRunningAnimations, isFalse);
      await t.pumpWidget(host(false, still: true));
      await t.pump();
      expect(find.text('folded text'), findsNothing);
    });
  });

  test('diagram draw time stays between the entrance and the long draw', () {
    expect(SubMotion.drawIn(4000), SubMotion.drawLong);
    expect(SubMotion.drawIn(100), SubMotion.enter);
    expect(SubMotion.drawIn(700), const Duration(milliseconds: 700));
  });

  testWidgets('a picture that is still loading fades in; a ready one shows at once', (t) async {
    late Widget loading, ready, still;
    await t.pumpWidget(MaterialApp(
      home: Builder(builder: (c) {
        loading = subImageFade(c, const SizedBox(), null, false);
        ready = subImageFade(c, const SizedBox(), 0, true);
        return const SizedBox();
      }),
    ));
    expect(loading, isA<AnimatedOpacity>());
    expect((loading as AnimatedOpacity).opacity, 0);
    expect(ready, isA<SizedBox>());
    await t.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: Builder(builder: (c) {
          still = subImageFade(c, const SizedBox(), null, false);
          return const SizedBox();
        }),
      ),
    ));
    expect(still, isA<SizedBox>());
  });
}
