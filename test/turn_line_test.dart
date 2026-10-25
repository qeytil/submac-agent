import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agent/app_state.dart';
import 'package:agent/theme.dart';
import 'package:agent/widgets/composer.dart';
import 'package:agent/widgets/message_view.dart';

/// The task line lives in the chat at the top of SubMac's reply and settles into "Worked for ..." in place.
void main() {
  test('a plain reply takes over from the line only after it has streamed a moment with no step', () {
    final t0 = DateTime(2026, 10, 21, 12);
    // No text yet: the line stays.
    expect(WorkingLine.yields(answerShowing: false, hasSteps: false, textSince: null, now: t0), isFalse);
    // Text just started: the line stays (a task's first line is followed by its first step).
    expect(WorkingLine.yields(answerShowing: true, hasSteps: false, textSince: t0, now: t0.add(const Duration(milliseconds: 300))), isFalse);
    // Text streaming for a while with no step: the answer takes the line's place.
    expect(WorkingLine.yields(answerShowing: true, hasSteps: false, textSince: t0, now: t0.add(WorkingLine.handOver)), isTrue);
    // A task that took steps keeps its line (it becomes "Worked for ..." at the end).
    expect(WorkingLine.yields(answerShowing: true, hasSteps: true, textSince: t0, now: t0.add(const Duration(seconds: 30))), isFalse);
  });

  test('steps are counted from the run', () {
    expect(WorkingLine.stepsOf(null), isFalse);
    final r = AgentRun(convId: 'c', side: false, title: 't');
    expect(WorkingLine.stepsOf(r), isFalse);
    r.step = 1;
    expect(WorkingLine.stepsOf(r), isTrue);
    final b = AgentRun(convId: 'c', side: false, title: 't')..browsing = true;
    expect(WorkingLine.stepsOf(b), isTrue);
  });

  Widget host(Widget child, {TextDirection dir = TextDirection.ltr}) => MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Directionality(textDirection: dir, child: Scaffold(body: Align(alignment: Alignment.topLeft, child: child))),
      );

  testWidgets('the finished line has the live line\'s height and left edge', (tester) async {
    await tester.pumpWidget(host(const WorkingLine(key: ValueKey('live'))));
    await tester.pump(const Duration(milliseconds: 50));
    final live = tester.getSize(find.byKey(const ValueKey('live')));
    final liveText = tester.getTopLeft(find.text('Thinking'));
    await tester.pumpWidget(host(const WorkSummary(key: ValueKey('done'), steps: [StepLine('Searched the web'), StepLine('Read 3 pages')], worked: Duration(seconds: 42), head: true)));
    final done = tester.getSize(find.byKey(const ValueKey('done')));
    final doneText = tester.getTopLeft(find.textContaining('Worked for 42s'));
    expect(done.height, live.height);
    expect(doneText.dx, liveText.dx);
    expect(live.height, turnHeadHeight + turnHeadPad.vertical);
    // Tap opens the steps.
    await tester.tap(find.textContaining('Worked for'));
    await tester.pumpAndSettle();
    expect(find.text('Read 3 pages'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('right to left: the line starts on the right', (tester) async {
    await tester.pumpWidget(host(const SizedBox(width: 400, child: WorkingLine(key: ValueKey('live'))), dir: TextDirection.rtl));
    await tester.pump(const Duration(milliseconds: 50));
    final box = tester.getRect(find.byKey(const ValueKey('live')));
    final text = tester.getRect(find.text('Thinking'));
    // Plain text only (no mark before it): the word starts right at the line's start edge.
    expect((box.right - text.right).abs(), lessThan(turnMarkSize));
    expect(text.left - box.left, greaterThan(100));
    await tester.pumpWidget(const SizedBox());
  });
}
