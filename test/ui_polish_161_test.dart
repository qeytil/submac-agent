// UI polish v1.13.94+161 (owner, 2026-10-24): one card per page build, soft chat edges, floating frosted composer,
// Hark-style long answers, streaming that fades in, and a quiet agent that shows only its status line.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:agent/app_state.dart';
import 'package:agent/models.dart';
import 'package:agent/theme.dart';
import 'package:agent/widgets/chat/edge_fade.dart';
import 'package:agent/widgets/chat/fade_append.dart';
import 'package:agent/widgets/chat_logic.dart';
import 'package:agent/widgets/hark_cards.dart';
import 'package:agent/widgets/hark_style.dart';
import 'package:agent/widgets/message_view.dart';
import 'package:agent/widgets/page_cards.dart';
import 'package:agent/widgets/reply_blocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Widget _host(Widget child, {bool still = false, TextDirection dir = TextDirection.ltr, AppState? state}) => ChangeNotifierProvider<AppState>.value(
      value: state ?? AppState(),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        home: MediaQuery(
          data: MediaQueryData(size: const Size(400, 860), disableAnimations: still),
          child: Directionality(textDirection: dir, child: Scaffold(body: SingleChildScrollView(child: child))),
        ),
      ),
    );

ToolCall _write(String id, String path, String content, {String name = 'write_file'}) =>
    ToolCall(id: id, name: name, arguments: jsonEncode({'path': path, 'content': content}));

ChatMessage _tool(String callId, String content) => ChatMessage(id: 'r-$callId', role: 'tool', content: content, toolCallId: callId);

void main() {
  // ───────────────────────────── Fix 1: one card per build
  group('page build: exactly one card per build', () {
    test('a relative and an absolute path of the same page are one page', () {
      expect(samePage('sites/bakery/index.html', '/data/user/0/app/workspace/sites/bakery/index.html'), isTrue);
      expect(samePage('index.html', '/ws/index.html'), isTrue);
      expect(samePage('sites/a/index.html', 'sites/b/index.html'), isFalse);
    });

    test('the first write owns the card; rewrites and appends feed it', () {
      final plan = PageBuildPlan.of([
        _write('w1', 'sites/x/index.html', '<title>X</title>\n<h1>One</h1>'),
        _write('a1', '/ws/sites/x/index.html', '<p>Two</p>', name: 'append_file'),
        _write('css', 'sites/x/style.css', 'body{}'),
        _write('w2', 'sites/x/index.html', '<title>X</title>\n<h1>Fixed</h1>'),
        _write('a2', 'sites/x/index.html', '<p>Three</p>', name: 'append_file'),
      ]);
      expect(plan.builds, hasLength(1));
      final b = plan.ownedBy('w1')!;
      expect(b.last.id, 'a2');
      expect(b.source, contains('Fixed'));
      expect(b.source, contains('Three'));
      expect(b.source, isNot(contains('One')), reason: 'a rewrite starts the page over');
      for (final id in ['a1', 'w2', 'a2']) {
        expect(plan.feeds(id), isTrue, reason: id);
        expect(plan.ownedBy(id), isNull, reason: id);
      }
      expect(plan.feeds('w1'), isFalse);
      expect(plan.built('/somewhere/sites/x/index.html'), isTrue);
    });

    test('while the task runs no page preview shows; afterwards a built page gets no second card', () {
      const reply = 'Your page is ready.\n\n```file\n/ws/sites/x/index.html\n```\n\n```file\n/ws/report.pdf\n```';
      final plan = PageBuildPlan.of([_write('w1', 'sites/x/index.html', '<h1>x</h1>')]);
      final running = hidePageCards(reply, running: true, plan: plan);
      expect(running, isNot(contains('index.html')));
      expect(running, contains('report.pdf'), reason: 'other files keep their cards');
      final done = hidePageCards(reply, running: false, plan: plan);
      expect(done, isNot(contains('index.html')), reason: 'the build card is the page\'s only card');
      expect(done, contains('report.pdf'));
      // A page this turn did not build keeps its card once the task is done.
      expect(hidePageCards(reply, running: false, plan: PageBuildPlan.empty), reply);
      // A half-written inline page never shows while streaming.
      expect(hidePageCards('Here:\n\n```page\n<html><body>half', running: true), 'Here:');
    });

    testWidgets('the card stays in its building state until the whole task has finished', (t) async {
      final c = _write('w1', 'site/index.html', '<title>Golden Crumb</title>');
      await t.pumpWidget(_host(PageBuildCard(call: c, result: 'Wrote /ws/site/index.html', running: true)));
      expect(find.text('Building your page'), findsOneWidget);
      expect(find.text('Open page'), findsNothing, reason: 'no early "done" on the first write');
      await t.pumpWidget(_host(PageBuildCard(call: c, result: 'Wrote /ws/site/index.html', running: false)));
      await t.pump();
      expect(find.text('Page built'), findsOneWidget);
      expect(find.text('Open page'), findsOneWidget);
    });

    testWidgets('a whole build (rewrite, append, final reply with its page card) draws ONE card and no early preview', (t) async {
      final m1 = ChatMessage(id: 'm1', role: 'assistant', toolCalls: [_write('w1', 'sites/x/index.html', '<title>Bakery</title>\n<h1>Hi</h1>')]);
      final m2 = ChatMessage(id: 'm2', role: 'assistant', toolCalls: [_write('w2', '/ws/sites/x/index.html', '<title>Bakery</title>\n<h1>Fixed</h1>')]);
      final m3 = ChatMessage(id: 'm3', role: 'assistant', toolCalls: [_write('a1', 'sites/x/index.html', '<p>More</p>', name: 'append_file')]);
      final fin = ChatMessage(id: 'm4', role: 'assistant', content: 'Your bakery page is ready.\n\n```file\n/ws/sites/x/index.html\n```');
      final results = {for (final id in ['w1', 'w2', 'a1']) id: _tool(id, 'Wrote /ws/sites/x/index.html')};
      final plan = PageBuildPlan.of([...m1.toolCalls!, ...m2.toolCalls!, ...m3.toolCalls!]);
      Widget turn(bool running) => Column(children: [
            for (final m in [m1, m2, m3, fin])
              AssistantMessageView(
                key: ValueKey('${m.id}-$running'),
                message: m,
                toolResults: results,
                showActions: false,
                isLast: false,
                pagePlan: plan,
                turnRunning: running,
              ),
          ]);
      await t.pumpWidget(_host(turn(true), still: true));
      expect(find.byType(PageBuildCard), findsOneWidget);
      expect(find.byType(PageCard), findsNothing, reason: 'no preview while the task runs');
      expect(find.text('Open page'), findsNothing);
      await t.pumpWidget(_host(turn(false), still: true));
      await t.pump();
      expect(find.byType(PageBuildCard), findsOneWidget);
      expect(find.byType(PageCard), findsNothing, reason: 'the build card is the only card');
      expect(find.text('Open page'), findsOneWidget);
      expect(find.textContaining('Your bakery page is ready.'), findsOneWidget);
    });
  });

  // ───────────────────────────── Fixes 2 + 7: soft edges, floating footer
  group('soft chat edges and the floating footer', () {
    test('top fade: clear under the status bar, full just below the controls; bottom fades out at the nav bar', () {
      final (stops, alpha) = ChatEdgeFade.stopsFor(800, top: 80, bottom: 20);
      expect(stops.first, 0);
      expect(stops.last, 1);
      expect(alpha, [0, 0, 1, 1, 0, 0]);
      expect(stops[1], closeTo((80 - ChatEdgeFade.defaultFade) / 800, 1e-9));
      expect(stops[2], closeTo(80 / 800, 1e-9));
      expect(stops[4], closeTo(780 / 800, 1e-9));
      for (var i = 1; i < stops.length; i++) {
        expect(stops[i], greaterThanOrEqualTo(stops[i - 1]));
      }
      // A tiny list never makes the stops go backwards.
      final (tiny, _) = ChatEdgeFade.stopsFor(60, top: 80, bottom: 20);
      for (var i = 1; i < tiny.length; i++) {
        expect(tiny[i], greaterThanOrEqualTo(tiny[i - 1]));
      }
    });

    testWidgets('the body learns the floating footer\'s height, so the newest message rests above it', (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: FloatingChatFrame(
            body: Builder(builder: (c) => Center(child: Text('inset ${ChatFooterInset.of(c).round()}'))),
            footer: const SizedBox(height: 88, child: Text('composer')),
          ),
        ),
      ));
      await t.pump();
      expect(find.text('inset 88'), findsOneWidget);
      expect(t.getBottomLeft(find.byKey(const ValueKey('chat-footer'))).dy, 600, reason: 'the footer sits at the bottom, over the body');
    });

    testWidgets('each frosted control has its own blur, clipped to its shape', (t) async {
      await t.pumpWidget(_host(const FrostedSurface(child: SizedBox(width: 40, height: 40))));
      final blur = find.descendant(of: find.byType(FrostedSurface), matching: find.byType(BackdropFilter));
      expect(blur, findsOneWidget);
      expect(find.descendant(of: find.byType(FrostedSurface), matching: find.byType(ClipRRect)), findsOneWidget);
      final f = t.widget<BackdropFilter>(blur);
      expect(f.filter, isA<ImageFilter>());
    });

    test('main, bots and team chats all use the floating footer and the soft edges', () {
      final home = File('lib/screens/home_screen.dart').readAsStringSync();
      final ws = File('lib/screens/bots_workspace.dart').readAsStringSync();
      final team = File('lib/screens/offices_screen.dart').readAsStringSync();
      final composer = File('lib/widgets/composer.dart').readAsStringSync();
      for (final src in [home, ws, team]) {
        expect(src, contains('FloatingChatFrame('));
      }
      expect(home, contains('ChatEdgeFade('));
      expect(team, contains('ChatEdgeFade('));
      for (final k in ['composer-plus', 'composer-field', 'composer-trailing']) {
        expect(composer, contains("ValueKey('$k')"), reason: k);
      }
    });
  });

  // ───────────────────────────── Fix 4: Hark-style long answers
  group('long answers read like Hark', () {
    final doc = StringBuffer('Here is the plan for your three days.\n\n');
    for (final d in ['Day 1: Old town', 'Day 2: Markets', 'Day 3: The coast']) {
      doc.writeln('## $d\n');
      for (var i = 0; i < 4; i++) {
        doc.writeln('- **Morning:** a long walk past the harbour, coffee at a corner café, and a slow museum visit $i.');
      }
      doc.writeln();
    }

    test('a long structured answer splits into a lead and a summary document', () {
      final split = longReplySplit(doc.toString())!;
      expect(split.$1, 'Here is the plan for your three days.');
      expect(split.$2, startsWith('# Day 1: Old town'));
      expect(longReplySplit('A short answer.'), isNull);
      expect(longReplySplit('# One heading\n\n${'word ' * 300}'), isNull, reason: 'one heading is just text');
      expect(longReplySplit('$doc\n```py\nprint(1)\n```'), isNull, reason: 'code keeps its own card');
    });

    testWidgets('it renders as the lead bubble and a summary card that opens the reader', (t) async {
      final m = ChatMessage(id: 'l', role: 'assistant', content: doc.toString());
      await t.pumpWidget(_host(ReplyView(message: m), still: true));
      expect(find.byType(SummaryCard), findsOneWidget);
      expect(find.textContaining('Here is the plan for your three days.'), findsOneWidget);
      final sem = t.ensureSemantics();
      expect(find.bySemanticsLabel(RegExp('^Open summary')), findsOneWidget);
      sem.dispose();
    });

    testWidgets('an ordinary answer stays plain text', (t) async {
      final m = ChatMessage(id: 'p', role: 'assistant', content: 'Paris is the capital of France.');
      await t.pumpWidget(_host(ReplyView(message: m), still: true));
      expect(find.byType(SummaryCard), findsNothing);
    });
  });

  // ───────────────────────────── Fix 5: streaming fades in
  group('streaming text fades in', () {
    Widget fade(String text, {bool still = false}) => MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: still),
            child: Scaffold(body: FadeAppend(key: const ValueKey('f'), text: text, child: Text(text))),
          ),
        );

    testWidgets('new words fade in over the old text, then the layers settle into one', (t) async {
      await t.pumpWidget(fade('Hello'));
      final st = t.state<FadeAppendState>(find.byType(FadeAppend));
      expect(st.layerCount, 1);
      await t.pumpWidget(fade('Hello there'));
      expect(st.layerCount, 2, reason: 'the grown text fades in on top');
      final top = t.widget<FadeTransition>(find.descendant(of: find.byType(FadeAppend), matching: find.byType(FadeTransition)).last);
      expect(top.opacity.value, lessThan(0.5));
      // The box never shrinks or jumps: same top start corner for every layer.
      expect(t.getTopLeft(find.text('Hello')), t.getTopLeft(find.text('Hello there')));
      await t.pump(const Duration(milliseconds: 400));
      expect(st.layerCount, 1);
      expect(find.text('Hello'), findsNothing);
      expect(find.text('Hello there'), findsOneWidget);
    });

    testWidgets('fast text keeps at most a few layers', (t) async {
      await t.pumpWidget(fade('a'));
      for (final s in ['a b', 'a b c', 'a b c d', 'a b c d e', 'a b c d e f']) {
        await t.pumpWidget(fade(s));
        await t.pump(const Duration(milliseconds: 16));
      }
      expect(t.state<FadeAppendState>(find.byType(FadeAppend)).layerCount, lessThanOrEqualTo(FadeAppend.maxLayers));
      await t.pumpAndSettle();
      expect(t.state<FadeAppendState>(find.byType(FadeAppend)).layerCount, 1);
    });

    testWidgets('reduced motion: new text shows at once', (t) async {
      await t.pumpWidget(fade('Hello', still: true));
      await t.pumpWidget(fade('Hello there', still: true));
      expect(t.state<FadeAppendState>(find.byType(FadeAppend)).layerCount, 1);
      expect(find.text('Hello there'), findsOneWidget);
      expect(t.hasRunningAnimations, isFalse);
    });
  });

  // ───────────────────────────── Fix 6: quiet agent
  group('steps and narration stay out of the chat unless asked', () {
    test('explicit asks are recognised; ordinary requests are not', () {
      for (final s in ['show steps', 'Show me your steps', 'how did you do it?', "what's your plan", 'show your work', 'tallaabooyinka i tus']) {
        expect(asksForSteps(s), isTrue, reason: s);
      }
      for (final s in ['give me a plan for my trip', 'book a table for two', 'write the steps to bake bread']) {
        expect(asksForSteps(s), isFalse, reason: s);
      }
    });

    testWidgets('a line written before a step is hidden; it shows when the user asked for the steps', (t) async {
      final m = ChatMessage(
        id: 'n',
        role: 'assistant',
        content: 'Checking Friday flights to Nairobi.',
        toolCalls: [ToolCall(id: 's1', name: 'web_search', arguments: '{"query":"flights"}')],
      );
      await t.pumpWidget(_host(AssistantMessageView(message: m, toolResults: const {}, showActions: false, isLast: false), still: true));
      expect(find.textContaining('Checking Friday flights'), findsNothing);
      await t.pumpWidget(_host(
          AssistantMessageView(key: const ValueKey('asked'), message: m, toolResults: const {}, showActions: false, isLast: false, stepsAsked: true),
          still: true));
      expect(find.textContaining('Checking Friday flights'), findsOneWidget);
    });

    test('the agent is told to work quietly and narrate only when asked', () {
      final src = File('lib/state/agent_prompt.dart').readAsStringSync();
      expect(src, contains('PromptQuiet.workQuietly'));
      expect(src, isNot(contains('Feel live')));
      expect(PromptQuiet.workQuietly, contains('Do not narrate'));
      expect(PromptQuiet.workQuietly, contains('show steps'));
      expect(PromptQuiet.sayRule, contains('Never for progress'));
    });

    test('the live line only opens the checklist and step list when steps were asked for', () {
      final src = File('lib/widgets/composer.dart').readAsStringSync();
      expect(src, contains('widget.showSteps && t != null && t.todo.isNotEmpty'));
      expect(src, contains('final canOpen = widget.showSteps &&'));
    });
  });
}
