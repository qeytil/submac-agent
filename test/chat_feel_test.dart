import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agent/models.dart';
import 'package:agent/widgets/chat_extras.dart';
import 'package:agent/widgets/chat_logic.dart';
import 'package:agent/widgets/reply_blocks.dart';

Widget _wrap(Widget child, {bool still = false}) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: still),
        child: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    );

void main() {
  group('splitMarkdownChunks: incremental markdown', () {
    test('splits paragraphs and headings at blank lines', () {
      final c = splitMarkdownChunks('# Title\n\nFirst para.\n\nSecond para.');
      expect(c, ['# Title', 'First para.', 'Second para.']);
    });

    test('never splits inside a code fence', () {
      const t = 'Intro\n\n```dart\nvoid a() {}\n\nvoid b() {}\n```\n\nAfter';
      final c = splitMarkdownChunks(t);
      expect(c, ['Intro', '```dart\nvoid a() {}\n\nvoid b() {}\n```', 'After']);
    });

    test('an open fence (still streaming) stays one block', () {
      final c = splitMarkdownChunks('Here:\n\n```py\nx = 1\n\ny = 2');
      expect(c.length, 2);
      expect(c.last, startsWith('```py'));
    });

    test('keeps a loose list and indented continuations together', () {
      const t = '- one\n\n- two\n\n    more about two\n\nDone.';
      final c = splitMarkdownChunks(t);
      expect(c, ['- one\n\n- two\n\n    more about two', 'Done.']);
    });

    test('keeps math blocks together', () {
      final c = splitMarkdownChunks('Sum:\n\n\$\$\na + b\n\n= c\n\$\$\n\nEnd');
      expect(c, ['Sum:', '\$\$\na + b\n\n= c\n\$\$', 'End']);
    });

    test('earlier blocks stay identical as text streams in', () {
      const full = 'Alpha beta.\n\nGamma delta.\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nOmega.';
      List<String>? prev;
      for (var n = 1; n <= full.length; n++) {
        final c = splitMarkdownChunks(full.substring(0, n));
        if (prev != null && prev.length > 1) {
          for (var i = 0; i < prev.length - 1; i++) {
            expect(c[i], prev[i], reason: 'block $i changed at $n');
          }
        }
        prev = c;
      }
      expect(prev, ['Alpha beta.', 'Gamma delta.', '| a | b |\n|---|---|\n| 1 | 2 |', 'Omega.']);
    });

    test('empty text gives no blocks', () => expect(splitMarkdownChunks(''), isEmpty));
  });

  group('revealTarget: streaming fades in whole words (no letter-by-letter typing)', () {
    test('while streaming, only whole words show; a word still being written waits', () {
      expect(revealTarget('Hello wor', streaming: true), 'Hello '.length);
      expect(revealTarget('Hello world ', streaming: true), 'Hello world '.length);
      expect(revealTarget('Line one\nLi', streaming: true), 'Line one\n'.length);
    });

    test('a finished reply shows everything', () => expect(revealTarget('Hello wor', streaming: false), 9));

    test('one long first word shows as it comes, never half an emoji', () {
      expect(revealTarget('Supercalifragilistic', streaming: true), 20);
      const t = 'ab😀';
      final n = revealTarget(t.substring(0, 3), streaming: true);
      final cu = t.codeUnitAt(n - 1);
      expect(cu >= 0xD800 && cu <= 0xDBFF, isFalse);
    });

    test('batches are spaced so each one can fade in', () => expect(revealEvery.inMilliseconds, inInclusiveRange(60, 160)));
  });

  group('suggestFollowUps', () {
    test('an offer gets yes and no', () {
      expect(suggestFollowUps('Here is your plan.\n\nWant me to book the table?'), ['Yes, please', 'No, thanks']);
      expect(suggestFollowUps('Done. Would you like me to send it to Amina?'), ['Yes, please', 'No, thanks']);
    });

    test('a short choice gets both options', () {
      expect(suggestFollowUps('I can do it two ways. Do you want the short version or the full report?'),
          ['Short version', 'Full report']);
    });

    test('a long choice is left to the user', () {
      final r = suggestFollowUps('Do you want me to write a very long formal letter to the council or call them tomorrow morning?');
      expect(r, ['Yes, please', 'No, thanks']);
    });

    test('a plain answer gets nothing', () => expect(suggestFollowUps('The capital of Somalia is Mogadishu.'), isEmpty));

    test('code gets "Explain it simply"', () {
      expect(suggestFollowUps('Here:\n```dart\nprint(1);\n```'), ['Explain it simply']);
    });

    test('a long answer offers a shorter one', () {
      final long = List.filled(260, 'word').join(' ');
      expect(suggestFollowUps('$long.'), ['Make it shorter']);
    });

    test('cards with their own buttons get no chips', () {
      expect(suggestFollowUps('Pick one:\n```choices\n{"options":["a","b"]}\n```\nWant me to go on?'), isEmpty);
    });

    test('never more than three', () {
      final long = List.filled(260, 'word').join(' ');
      expect(suggestFollowUps('$long. Want me to keep going?').length, lessThanOrEqualTo(3));
    });
  });

  group('small helpers', () {
    test('checklistLine', () {
      expect(checklistLine(2, 5), '2 of 5 done');
      expect(checklistLine(5, 5), 'All 5 done');
      expect(checklistLine(0, 0), '');
    });

    test('TurnStep knows a failed step', () {
      expect(const TurnStep('run_shell', '{}', 'exit_code: 1\nboom').failed, isTrue);
      expect(const TurnStep('web_search', '{}', '{"results":[]}').failed, isFalse);
    });
  });

  group('chat widgets', () {
    testWidgets('ChecklistCard shows progress and steps', (t) async {
      await t.pumpWidget(_wrap(const ChecklistCard(steps: ['Plan the pages', 'Write the home page', 'Publish'], done: {0})));
      await t.pumpAndSettle();
      expect(find.text('Plan'), findsOneWidget);
      expect(find.text('1 of 3 done'), findsOneWidget);
      expect(find.text('Write the home page'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
    });

    testWidgets('ChecklistCard folds a long plan and opens it', (t) async {
      final steps = [for (var i = 1; i <= 10; i++) 'Step $i'];
      await t.pumpWidget(_wrap(ChecklistCard(steps: steps, done: const {0, 1, 2})));
      await t.pumpAndSettle();
      expect(find.text('Step 10'), findsNothing);
      await t.tap(find.text('Show all 10'));
      await t.pumpAndSettle();
      expect(find.text('Step 10'), findsOneWidget);
    });

    testWidgets('FollowUpChips send the tapped reply', (t) async {
      String? picked;
      await t.pumpWidget(_wrap(FollowUpChips(options: const ['Yes, please', 'No, thanks'], onPick: (s) => picked = s)));
      await t.pumpAndSettle();
      await t.tap(find.text('No, thanks'));
      expect(picked, 'No, thanks');
    });

    testWidgets('ChoiceRows: one tap answers, ticks it and locks the rest', (t) async {
      final picks = <String>[];
      await t.pumpWidget(_wrap(ChoiceRows(options: const ['Phone', 'Tablet', 'Computer'], onPick: picks.add)));
      await t.pumpAndSettle();
      // Modern rows: no numbers, no tick until something is chosen.
      expect(find.text('1'), findsNothing);
      expect(find.byKey(const ValueKey('choice-check')), findsNothing);
      await t.tap(find.text('Tablet'));
      await t.pumpAndSettle();
      await t.tap(find.text('Computer'));
      await t.pumpAndSettle();
      expect(picks, ['Tablet']);
      expect(find.byKey(const ValueKey('choice-check')), findsOneWidget); // the picked row shows a tick
    });

    testWidgets('ChoiceRows: disabled while busy', (t) async {
      final picks = <String>[];
      await t.pumpWidget(_wrap(ChoiceRows(options: const ['Yes', 'No'], enabled: false, onPick: picks.add)));
      await t.pumpAndSettle();
      await t.tap(find.text('Yes'));
      expect(picks, isEmpty);
    });

    testWidgets('HowIDidIt lists steps in plain words and hides bookkeeping', (t) async {
      await t.pumpWidget(_wrap(const HowIDidIt(steps: [
        TurnStep('web_search', '{"query":"weather Mogadishu"}', '{"results":[]}'),
        TurnStep('todo', '{"steps":["a"]}', 'ok'),
        TurnStep('fetch_url', '{"url":"https://example.com/x"}', 'Error: 404'),
      ])));
      await t.pumpAndSettle();
      expect(find.text('How I did it'), findsOneWidget);
      expect(find.textContaining('2 steps'), findsOneWidget);
      expect(find.textContaining('Searched the web'), findsNothing);
      await t.tap(find.text('How I did it'));
      await t.pumpAndSettle();
      expect(find.textContaining('Searched the web'), findsOneWidget);
      expect(find.textContaining("didn't work"), findsOneWidget);
    });

    testWidgets('JumpToBottom shows New when something arrived', (t) async {
      var taps = 0;
      await t.pumpWidget(_wrap(JumpToBottom(onTap: () => taps++, fresh: true)));
      expect(find.text('New'), findsOneWidget);
      await t.tap(find.byType(JumpToBottom));
      expect(taps, 1);
    });

    testWidgets('StreamingMarkdown renders every block', (t) async {
      await t.pumpWidget(_wrap(const StreamingMarkdown('# Hello\n\nFirst line.\n\nSecond line.')));
      expect(find.textContaining('Hello'), findsOneWidget);
      expect(find.textContaining('Second line.'), findsOneWidget);
    });

    testWidgets('a streaming reply shows whole words that fade in; an old one shows at once', (t) async {
      final m = ChatMessage(id: 'a', role: 'assistant', content: 'Hello there, this is a reply.', streaming: true)..animateIn = true;
      await t.pumpWidget(_wrap(ReplyView(message: m)));
      await t.pump(const Duration(milliseconds: 16));
      // The word still being written waits; no half words, no letter-by-letter typing.
      expect(find.textContaining('this is a reply.'), findsNothing);
      expect(find.textContaining('Hello there, this is a'), findsWidgets);
      // The answer finishes: the last word comes in and fades in where it lands.
      m.streaming = false;
      await t.pumpWidget(_wrap(ReplyView(message: m)));
      for (var i = 0; i < 30; i++) {
        await t.pump(const Duration(milliseconds: 16));
      }
      expect(find.textContaining('this is a reply.'), findsOneWidget);

      final old = ChatMessage(id: 'b', role: 'assistant', content: 'An old reply.');
      await t.pumpWidget(_wrap(ReplyView(message: old)));
      expect(find.textContaining('An old reply.'), findsOneWidget);
    });

    testWidgets('reduced motion shows the whole reply at once', (t) async {
      final m = ChatMessage(id: 'c', role: 'assistant', content: 'All at once please.', streaming: true)..animateIn = true;
      await t.pumpWidget(_wrap(ReplyView(message: m), still: true));
      expect(find.textContaining('All at once please.'), findsOneWidget);
    });
  });
}
